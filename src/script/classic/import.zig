//! Classic import, passes 1–2: a class function's parse tree (pass 1,
//! `parser.zig`) → IR (pass 2): `#include`s inside the body inlined, locals bound to
//! slots, every expression typed (int, float, string or unknown) and marked pure or not.
//! A construct becomes a plain IR node only where it provably behaves as in the exe;
//! everything else becomes an `exe` node (`exe.zig`) or a run-time `name`. Pass 3 (data
//! out of the creation events) is `lift.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const ir = @import("../ir.zig");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const object = @import("../object.zig");
const names = @import("names.zig");

/// The engine's name of a name of imported code: a field the importer renamed has the new
/// name's id and the file's text (`names.zig`).
pub fn fieldName(n: ir.Name) []const u8 {
    if (object.findAnyCase(n.text)) |id| if (id == n.id) return n.text;
    return object.nameOf(n.id);
}

/// What the importer needs from its host (the runtime, a tool): included files and what
/// is known of a call target.
pub const Env = struct {
    ctx: *anyopaque,
    /// Parse tree of a file; a parse error fills `diag`.
    unit: *const fn (ctx: *anyopaque, file: []const u8, diag: *parser.Diagnostic) anyerror!Loaded,
    callee: *const fn (ctx: *anyopaque, id: u32) Callee,
};

pub const Loaded = struct {
    unit: ast.Unit,
    /// Lower-case file name.
    key: []const u8,
};

/// A call by name: a builtin's facts, or nothing known (a script function, a missing builtin).
/// `data`: a declarative builtin (`Runtime.Sig.data`).
pub const Callee = struct { int: bool = false, pure: bool = false, data: bool = false };

pub const Result = struct {
    ir: *const ir.Fn,
    /// False when an include was not found: the IR must not be cached.
    complete: bool,
};

/// IR of a class function in `a` (`gpa`: scratch).
pub fn function(a: Allocator, gpa: Allocator, env: Env, func: *const object.Func) Allocator.Error!Result {
    var im: Importer = .{ .env = env, .a = a, .gpa = gpa, .file = func.file, .host = if (func.class) |c| c.host else null };
    defer im.slots.deinit(gpa);
    defer im.state.deinit(gpa);
    // The defining file's text, for the byte ranges (none if it cannot be loaded again).
    var diag: parser.Diagnostic = .{};
    if (env.unit(env.ctx, func.file, &diag)) |l| {
        im.src = l.unit.src;
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    const f = func.ast.?;
    const params = try im.a.alloc(ir.Param, f.params.len);
    for (f.params, params) |p, *out| {
        const slot = try im.slotOf(p.id, p.name);
        im.state.items[slot] = .{ .definite = tyOf(p.type) };
        out.* = .{ .slot = slot, .type = p.type, .name = p.name };
    }
    var body: std.ArrayList(ir.Stmt) = .empty;
    try im.stmts(&body, f.body);
    const out = try im.a.create(ir.Fn);
    out.* = .{
        .name = f.name,
        .file = func.file,
        .line = f.line,
        .params = params,
        .slots = @intCast(im.state.items.len),
        .body = body.items,
        .span = im.span(f.start, f.end),
        .names = try im.names.toOwnedSlice(a),
    };
    return .{ .ir = out, .complete = !im.missing };
}

/// Static type: what the value's tag is on every run (`any`: not known).
const Ty = enum { int, float, string, any };

fn tyOf(t: ir.Type) Ty {
    return switch (t) {
        .int => .int,
        .float => .float,
        .string, .object => .string,
        .bool, .any => .any,
    };
}

fn numeric(t: Ty) bool {
    return t == .int or t == .float;
}

/// Whether a slot's declaration has run at this point of the body.
const SlotState = union(enum) { none, maybe, definite: Ty };

const Typed = struct {
    e: *const ir.Expr,
    ty: Ty,
    /// No effects: may be skipped or moved past another pure expression.
    pure: bool,
    /// A literal: its place in the evaluation order never matters.
    stable: bool = false,
};

const Importer = struct {
    env: Env,
    a: Allocator,
    gpa: Allocator,
    file: []const u8,
    /// Text of `file` ("" if unknown: no byte ranges).
    src: []const u8 = "",
    /// The `#include` the statements come from (`ir.Stmt.via`).
    via: ir.Span = .{},
    /// Name id → slot.
    slots: std.AutoHashMapUnmanaged(u32, u16) = .empty,
    state: std.ArrayList(SlotState) = .empty,
    /// Slot → name as first declared (in `a`).
    names: std.ArrayList([]const u8) = .empty,
    /// The host of the defining class: a name of its code that is no local is the
    /// engine's name of the field (`names.zig`), its text the file's.
    host: ?names.Host = null,
    /// `#include` nesting inside the body (no deeper than 16, like `Runtime.addItems`).
    depth: u32 = 0,
    missing: bool = false,

    fn slotOf(self: *Importer, id: u32, name: []const u8) Allocator.Error!u16 {
        const gop = try self.slots.getOrPut(self.gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.state.items.len);
            try self.state.append(self.gpa, .none);
            try self.names.append(self.a, name);
        }
        return gop.value_ptr.*;
    }

    /// A range of the current file (none without its text).
    fn span(self: *const Importer, start: u32, end: u32) ir.Span {
        if (self.src.len == 0 or end == 0 or end > self.src.len) return .{};
        return .{ .start = start, .end = end };
    }

    /// An expression statement: the expression and the `;` after it.
    fn stmtSpan(self: *const Importer, e: *const ast.Expr) ir.Span {
        const s = self.span(e.start, e.end);
        if (s.none()) return s;
        var lx: lexer.Lexer = .init(self.src[s.end..]);
        const t = lx.next() catch return s;
        if (t.tag != .semicolon) return s;
        return .{ .start = s.start, .end = s.end + @as(u32, @intCast(lx.pos)) };
    }

    /// `#include name` in the current file: `name` is a slice of its text.
    fn directiveSpan(self: *const Importer, name: []const u8) ir.Span {
        const base = @intFromPtr(self.src.ptr);
        const p = @intFromPtr(name.ptr);
        if (name.len == 0 or p < base or p + name.len > base + self.src.len) return .{};
        const off = p - base;
        const hash = std.mem.lastIndexOfScalar(u8, self.src[0..off], '#') orelse return .{};
        return self.span(@intCast(hash), @intCast(off + name.len));
    }

    const Pos = struct { line: u32, span: ir.Span };

    fn at(self: *const Importer, e: *const ast.Expr) Pos {
        return .{ .line = e.line, .span = self.span(e.start, e.end) };
    }

    fn node(self: *Importer, pos: Pos, kind: ir.Expr.Kind) Allocator.Error!*const ir.Expr {
        const p = try self.a.create(ir.Expr);
        p.* = .{ .line = pos.line, .kind = kind, .span = pos.span };
        return p;
    }

    fn push(self: *Importer, out: *std.ArrayList(ir.Stmt), line: u32, s: ir.Span, kind: ir.Stmt.Kind) Allocator.Error!void {
        try out.append(self.a, .{ .file = self.file, .line = line, .kind = kind, .span = s, .via = self.via });
    }

    // ---------------------------------------------------------------- statements

    fn stmts(self: *Importer, out: *std.ArrayList(ir.Stmt), list: []const ast.Stmt) Allocator.Error!void {
        for (list) |*s| try self.stmt(out, s);
    }

    fn stmt(self: *Importer, out: *std.ArrayList(ir.Stmt), s: *const ast.Stmt) Allocator.Error!void {
        switch (s.*) {
            .empty => {},
            .expr => |e| switch (e.kind) {
                .assign => |a| {
                    const v = try self.expr(a.value);
                    try self.push(out, e.line, self.stmtSpan(e), .{ .assign = .{ .target = (try self.target(a.id, a.name)).t, .value = v.e } });
                },
                else => try self.push(out, e.line, self.stmtSpan(e), .{ .expr = (try self.expr(e)).e }),
            },
            .var_decl => |d| try self.declare(out, d),
            // Blocks don't scope: a local declared inside stays declared.
            .block => |b| try self.stmts(out, b),
            .@"if" => |i| {
                const c = try self.cond(i.cond);
                // The branches are statement lists of this file.
                const via = self.via;
                self.via = .{};
                var before = try self.state.clone(self.gpa);
                defer before.deinit(self.gpa);
                var then: std.ArrayList(ir.Stmt) = .empty;
                try self.stmt(&then, i.then);
                var after_then = try self.state.clone(self.gpa);
                defer after_then.deinit(self.gpa);
                @memcpy(self.state.items[0..before.items.len], before.items);
                @memset(self.state.items[before.items.len..], .none);
                var els: std.ArrayList(ir.Stmt) = .empty;
                if (i.@"else") |e| try self.stmt(&els, e);
                for (self.state.items, 0..) |*st, k| st.* = merge(if (k < after_then.items.len) after_then.items[k] else .none, st.*);
                self.via = via;
                try self.push(out, c.line, self.span(i.start, i.end), .{ .@"if" = .{ .cond = c, .then = then.items, .@"else" = els.items } });
            },
            .@"return" => |r| {
                // `return;` without a value gives type 0 in the exe and doesn't return (0x4e3eaa).
                const e = r.value orelse return;
                try self.push(out, e.line, self.span(r.start, r.end), .{ .@"return" = (try self.expr(e)).e });
            },
            .include => |name| try self.include(out, name),
        }
    }

    fn merge(a: SlotState, b: SlotState) SlotState {
        if (a == .definite and b == .definite) return .{ .definite = if (a.definite == b.definite) a.definite else .any };
        if (a == .none and b == .none) return .none;
        return .maybe;
    }

    fn declare(self: *Importer, out: *std.ArrayList(ir.Stmt), d: ast.VarDecl) Allocator.Error!void {
        const slot = try self.slotOf(d.id orelse try object.intern(d.name), d.name);
        self.state.items[slot] = .{ .definite = tyOf(d.type) };
        try self.push(out, d.line, self.span(d.start, d.end), .{ .local = .{ .slot = slot, .type = d.type } });
    }

    /// `#include` inside a function: the file's statements and declarations in place
    /// (its functions and `#inherit` are ignored, as the old interpreter did).
    fn include(self: *Importer, out: *std.ArrayList(ir.Stmt), name: []const u8) Allocator.Error!void {
        if (self.depth > 16) return self.fail(out, error.IncludeCycle, name, .{});
        var diag: parser.Diagnostic = .{};
        const loaded = self.env.unit(self.env.ctx, name, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (err == error.ScriptNotFound) self.missing = true;
                return self.fail(out, err, name, diag);
            },
        };
        self.depth += 1;
        defer self.depth -= 1;
        const outer = self.file;
        const outer_src = self.src;
        const outer_via = self.via;
        if (self.via.none()) self.via = self.directiveSpan(name);
        self.file = loaded.key;
        self.src = loaded.unit.src;
        defer {
            self.file = outer;
            self.src = outer_src;
            self.via = outer_via;
        }
        for (loaded.unit.items) |*it| switch (it.*) {
            .stmt => |*s| try self.stmt(out, s),
            .include => |inner| try self.include(out, inner),
            .var_decl => |d| try self.declare(out, d),
            .function, .inherit => {},
        };
    }

    fn fail(self: *Importer, out: *std.ArrayList(ir.Stmt), err: anyerror, name: []const u8, diag: parser.Diagnostic) Allocator.Error!void {
        const f = try self.a.create(ir.Fail);
        f.* = .{ .err = err, .file = try std.ascii.allocLowerString(self.a, name), .line = diag.line, .message = diag.message };
        try self.push(out, 0, self.directiveSpan(name), .{ .fail = f });
    }

    // ---------------------------------------------------------------- expressions

    /// A condition: the exe's truth unless the value is an int.
    fn cond(self: *Importer, e: *const ast.Expr) Allocator.Error!*const ir.Expr {
        return (try self.truth(try self.expr(e))).e;
    }

    fn truth(self: *Importer, t: Typed) Allocator.Error!Typed {
        if (t.ty == .int) return t;
        return .{ .e = try self.exe(.{ .line = t.e.line, .span = t.e.span }, .truthy, &.{t.e}), .ty = .int, .pure = t.pure };
    }

    fn exe(self: *Importer, pos: Pos, op: ir.ExeOp, args: []const *const ir.Expr) Allocator.Error!*const ir.Expr {
        return self.node(pos, .{ .exe = .{ .op = op, .args = try self.a.dupe(*const ir.Expr, args) } });
    }

    const Bound = struct { t: ir.Target, ty: Ty };

    fn target(self: *Importer, id: u32, text: []const u8) Allocator.Error!Bound {
        const field = if (names.toNew(self.host, text)) |n| try object.intern(n) else id;
        const name: ir.Name = .{ .id = field, .text = text, .this = std.ascii.eqlIgnoreCase(text, "this") };
        const slot = self.slots.get(id) orelse return .{ .t = .{ .name = name }, .ty = .any };
        return switch (self.state.items[slot]) {
            .definite => |ty| .{ .t = .{ .local = slot }, .ty = ty },
            .maybe => .{ .t = .{ .name = blk: {
                var n = name;
                n.slot = slot;
                break :blk n;
            } }, .ty = .any },
            .none => .{ .t = .{ .name = name }, .ty = .any },
        };
    }

    fn expr(self: *Importer, e: *const ast.Expr) Allocator.Error!Typed {
        const line = self.at(e);
        switch (e.kind) {
            .int => |v| return .{ .e = try self.node(line, .{ .lit = .{ .int = v } }), .ty = .int, .pure = true, .stable = true },
            .float => |v| return .{ .e = try self.node(line, .{ .lit = .{ .float = v } }), .ty = .float, .pure = true, .stable = true },
            .string => |v| return .{ .e = try self.node(line, .{ .lit = .{ .string = v } }), .ty = .string, .pure = true, .stable = true },
            .ident => |id| {
                const b = try self.target(id.id, id.name);
                return .{ .e = try self.node(line, switch (b.t) {
                    .local => |s| .{ .local = s },
                    .name => |n| .{ .name = n },
                    .field, .member => unreachable,
                }), .ty = b.ty, .pure = true };
            },
            .call => |c| {
                const args = try self.a.alloc(*const ir.Expr, c.args.len);
                var pure = true;
                for (c.args, args) |a, *out| {
                    const t = try self.expr(a);
                    out.* = t.e;
                    pure = pure and t.pure;
                }
                const n = try self.node(line, .{ .call = .{ .id = c.id, .text = c.name, .args = args } });
                // Over 32 arguments: 0 without evaluating them (`Runtime.call`).
                if (c.args.len > 32) return .{ .e = n, .ty = .int, .pure = true };
                const k = self.env.callee(self.env.ctx, c.id);
                return .{ .e = n, .ty = if (k.int) .int else .any, .pure = pure and k.pure };
            },
            .unary => |u| {
                const o = try self.expr(u.operand);
                return switch (u.op) {
                    .neg => if (numeric(o.ty))
                        .{ .e = try self.node(line, .{ .unary = .{ .op = .neg, .operand = o.e } }), .ty = o.ty, .pure = o.pure }
                    else
                        .{ .e = try self.exe(line, .neg, &.{o.e}), .ty = if (o.ty == .string) .int else .any, .pure = o.pure },
                    .not => if (o.ty == .int)
                        .{ .e = try self.node(line, .{ .unary = .{ .op = .not, .operand = o.e } }), .ty = .int, .pure = o.pure }
                    else
                        .{ .e = try self.exe(line, .not, &.{o.e}), .ty = .int, .pure = o.pure },
                };
            },
            .binary => |b| return self.binary(line, b.op, try self.expr(b.lhs), try self.expr(b.rhs)),
            .assign => |a| {
                const v = try self.expr(a.value);
                const b = try self.target(a.id, a.name);
                const p = try self.a.create(ir.Assign);
                p.* = .{ .target = b.t, .value = v.e };
                return .{ .e = try self.node(line, .{ .assign = p }), .ty = b.ty, .pure = false };
            },
        }
    }

    fn binary(self: *Importer, line: Pos, op: ast.BinaryOp, l: Typed, r: Typed) Allocator.Error!Typed {
        const pure = l.pure and r.pure;
        // The exe evaluates the right operand first; a plain node goes left first.
        const order_free = pure or l.stable or r.stable;
        const both_num = numeric(l.ty) and numeric(r.ty);
        const arith: Ty = if (!both_num) .any else if (l.ty == .float or r.ty == .float) .float else .int;
        const ty: Ty = switch (op) {
            .add, .sub, .mul, .div, .ne => arith,
            else => .int,
        };
        const plain: ?ir.BinaryOp = switch (op) {
            inline .add, .sub, .mul, .div, .lt, .gt, .ge => |o| @field(ir.BinaryOp, @tagName(o)),
            // `==` truncates floats and calls strings equal: plain only for two ints.
            .eq => if (l.ty == .int and r.ty == .int) .eq else null,
            // `!=` adds and `<=` is `>=` in the exe: never plain.
            .ne, .le => null,
            .@"and", .@"or" => return self.logic(line, op, l, r),
        };
        if (plain) |p| if (order_free and both_num)
            return .{ .e = try self.node(line, .{ .binary = .{ .op = p, .lhs = l.e, .rhs = r.e } }), .ty = ty, .pure = pure };
        return .{ .e = try self.exe(line, ir.ExeOp.binary(op), &.{ l.e, r.e }), .ty = ty, .pure = pure };
    }

    /// `&&`/`||` evaluate both sides, right first: short-circuit is the same when the right
    /// side is pure and either the left one is pure too or the right one is a literal.
    fn logic(self: *Importer, line: Pos, op: ast.BinaryOp, l: Typed, r: Typed) Allocator.Error!Typed {
        const pure = l.pure and r.pure;
        if (!(r.pure and (l.pure or r.stable)))
            return .{ .e = try self.exe(line, ir.ExeOp.binary(op), &.{ l.e, r.e }), .ty = .int, .pure = pure };
        const lhs = (try self.truth(l)).e;
        const rhs = (try self.truth(r)).e;
        const lop: ir.LogicOp = if (op == .@"and") .@"and" else .@"or";
        return .{ .e = try self.node(line, .{ .logic = .{ .op = lop, .lhs = lhs, .rhs = rhs } }), .ty = .int, .pure = pure };
    }
};
