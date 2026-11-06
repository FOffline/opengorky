//! Classic import, pass 3: the provable data of a creation event (`init`,
//! `postinit`, `post_init`, `initCamera`, `restore`) lifted out of its IR into the object's
//! model, each value with its origin (file, bytes of the literal, layer); the rest of the
//! body stays the event's code. Lifted are:
//! - the leading run of foldable statements: a literal assigned to a variable the class
//!   declares, a declarative builtin (`Runtime.Sig.data`) with literal arguments, local
//!   constants (`float spd; spd = 1.2; ActorSetWalkSpeed("x", spd);`) and the class's
//!   variables the run has set so (`spd = 1.2; ActorSetWalkSpeed("x", spd);`, a `.hro`'s);
//! - after it, a literal assigned to a declared variable that no statement before it in the
//!   rest names, as long as none before it calls, returns or fails (any call may read the
//!   object's variables).
//! A local's statements stay in the rest (they only touch the call's slots).
//!
//! Running the model (`Runtime.runLifted`) is the items in order, then the rest: the same
//! effects in the same order as the whole body, so it equals the exe's `init()`. `.var`
//! (`varFields`) comes before the event, as in the exe (0x431886): an init literal wins.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const ir = @import("../ir.zig");
const import = @import("import.zig");
const object = @import("../object.zig");
const fields = @import("names.zig");
const Value = @import("../value.zig").Value;

/// The creation events whose data is lifted (`world/start.zig`, `inventory/create.zig`).
const events = [_][]const u8{ "init", "postinit", "post_init", "initCamera", "restore" };

pub fn isEvent(name: []const u8) bool {
    for (events) |e| if (std.ascii.eqlIgnoreCase(name, e)) return true;
    return false;
}

/// Where a value of the model comes from: a schema default (`core/schema.zig`), an
/// archetype's snippet (`ft_x.ss` an object's file includes), the object's own file, its
/// `.var`.
pub const Layer = enum { base, archetype, instance, vars };

const Origin = struct {
    /// Lower-case file of the value's text.
    file: []const u8,
    layer: Layer,
    /// The value's bytes in `file` (the literal; a call: the whole call).
    span: ir.Span = .{},
    /// Index of its statement in the event's body (none for `.var`).
    at: u32 = 0,
};

/// A variable's value.
pub const Field = struct { id: u32, name: []const u8, value: Value, origin: Origin };
/// A declarative builtin and its arguments.
pub const Call = struct { id: u32, name: []const u8, args: []const Value, origin: Origin };
pub const Item = union(enum) { field: Field, call: Call };

pub const Lifted = struct {
    /// In the order they run (the body's).
    items: []const Item,
    /// The body without the items, under the event's header: the event's code (OnCreate).
    rest: *const ir.Fn,
};

/// What the editor's model (editor/model.zig) lifts beyond what runs: it shows and edits
/// the data, it does not run it, so the leading run may go on past code the runtime must
/// keep in place.
pub const Opts = struct {
    /// A call that is not lifted passes in the leading run as code (`class_init();`
    /// before an item's own values, `FighterSetLevel(…)` before a hero's inventory).
    calls_pass: bool = false,
    /// A declarative call with an argument that is no literal or constant (`spd`, a class
    /// variable; an expression) is lifted with that argument `nil`, which stays its code.
    opaque_args: bool = false,
};

/// Pass 3 of `f`, a function of class `cls` (layers by its file; fields it declares).
/// A function with parameters or nothing to lift gives no items and `rest` = `f`.
pub fn lift(a: Allocator, env: import.Env, f: *const ir.Fn, cls: *const object.Class) Allocator.Error!Lifted {
    return liftWith(a, env, f, cls, .{});
}

pub fn liftWith(a: Allocator, env: import.Env, f: *const ir.Fn, cls: *const object.Class, o: Opts) Allocator.Error!Lifted {
    if (f.params.len > 0) return .{ .items = &.{}, .rest = f };
    var items: std.ArrayList(Item) = .empty;
    var rest: std.ArrayList(ir.Stmt) = .empty;
    // Locals of the leading run: type and value (null: not a constant).
    const types = try a.alloc(?ir.Type, f.slots);
    @memset(types, null);
    const consts = try a.alloc(?Value, f.slots);
    @memset(consts, null);
    // The class's variables the leading run has set to a literal (`spd = 1.2;`): their value then.
    var set: std.AutoHashMapUnmanaged(u32, Value) = .empty;
    var leading = true;
    var blocked = false;
    var named: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (f.body, 0..) |*s, k| {
        const at: u32 = @intCast(k);
        if (leading) {
            switch (s.kind) {
                .local => |l| {
                    types[l.slot] = l.type;
                    consts[l.slot] = .initial(l.type);
                    try rest.append(a, s.*);
                    continue;
                },
                .assign => |x| if (x.target == .local and x.op == .set) if (literal(x.value)) |v| {
                    const slot = x.target.local;
                    if (types[slot]) |t| {
                        consts[slot] = try v.convert(t, a);
                        try rest.append(a, s.*);
                        continue;
                    }
                },
                else => {},
            }
            if (try fieldOf(s, cls, at)) |x| {
                try items.append(a, .{ .field = x });
                try set.put(a, x.id, try x.value.convert(try declaredType(cls, x.id), a));
                continue;
            }
            if (try callOf(a, env, s, cls, consts, &set, at, o.opaque_args)) |x| {
                try items.append(a, .{ .call = x });
                continue;
            }
            if (o.calls_pass and s.kind == .expr and s.kind.expr.kind == .call) {
                try rest.append(a, s.*);
                continue;
            }
            leading = false;
        }
        if (!blocked) if (try fieldOf(s, cls, at)) |x| if (!named.contains(x.id)) {
            try items.append(a, .{ .field = x });
            continue;
        };
        try rest.append(a, s.*);
        if (!blocked) blocked = try names(a, &named, &.{s.*});
    }
    if (items.items.len == 0) return .{ .items = &.{}, .rest = f };
    const r = try a.create(ir.Fn);
    r.* = f.*;
    r.body = rest.items;
    return .{ .items = items.items, .rest = r };
}

fn layerOf(file: []const u8, cls: *const object.Class) Layer {
    return if (std.mem.eql(u8, file, cls.name)) .instance else .archetype;
}

/// The type the class declares variable `id` of (`any` when it does not).
fn declaredType(cls: *const object.Class, id: u32) Allocator.Error!ir.Type {
    for (cls.vars.items) |d| if (try cls.varId(d) == id) return d.type;
    return .any;
}

fn declares(cls: *const object.Class, id: u32) Allocator.Error!bool {
    for (cls.vars.items) |d| if (try cls.varId(d) == id) return true;
    return false;
}

/// `name = literal;` for a variable the class declares (every object of it has it).
fn fieldOf(s: *const ir.Stmt, cls: *const object.Class, at: u32) Allocator.Error!?Field {
    if (s.kind != .assign) return null;
    const x = s.kind.assign;
    if (x.op != .set or x.target != .name or x.target.name.slot != null) return null;
    const v = literal(x.value) orelse return null;
    const n = x.target.name;
    if (!try declares(cls, n.id)) return null;
    return .{ .id = n.id, .name = import.fieldName(n), .value = v, .origin = .{ .file = s.file, .layer = layerOf(s.file, cls), .span = x.value.span, .at = at } };
}

/// `Builtin(literals or constants);` of a declarative builtin no script function shadows;
/// `opaque_args`: any other argument is `nil` (Opts.opaque_args).
fn callOf(a: Allocator, env: import.Env, s: *const ir.Stmt, cls: *const object.Class, consts: []const ?Value, set: *const std.AutoHashMapUnmanaged(u32, Value), at: u32, opaque_args: bool) Allocator.Error!?Call {
    if (s.kind != .expr or s.kind.expr.kind != .call) return null;
    const c = s.kind.expr.kind.call;
    if (c.target != null or c.args.len > 32 or c.text.len > 128 or !env.callee(env.ctx, c.id).data) return null;
    const args = try a.alloc(Value, c.args.len);
    for (c.args, args) |e, *v| v.* = literal(e) orelse switch (e.kind) {
        .local => |slot| consts[slot] orelse if (opaque_args) .nil else return null,
        .name => |n| set.get(n.id) orelse if (opaque_args) .nil else return null,
        else => if (opaque_args) .nil else return null,
    };
    return .{ .id = c.id, .name = c.text, .args = args, .origin = .{ .file = s.file, .layer = layerOf(s.file, cls), .span = s.kind.expr.span, .at = at } };
}

/// The value of a literal as the runtime evaluates it (`-5` is a minus over 5).
fn literal(e: *const ir.Expr) ?Value {
    return switch (e.kind) {
        .lit => |v| switch (v) {
            .int, .float, .string => v,
            else => null,
        },
        .unary => |u| if (u.op == .neg and u.operand.kind == .lit and ir.numeric(u.operand.kind.lit)) ir.neg(u.operand.kind.lit) else null,
        else => null,
    };
}

/// Adds the variable names `list` reads or writes to `out`; true if it calls, returns or
/// fails (what follows cannot move before it).
fn names(a: Allocator, out: *std.AutoHashMapUnmanaged(u32, void), list: []const ir.Stmt) Allocator.Error!bool {
    for (list) |s| switch (s.kind) {
        .expr => |e| if (try exprNames(a, out, e)) return true,
        .local => {},
        .assign => |x| {
            if (x.target == .name) try out.put(a, x.target.name.id, {}) else if (x.target != .local) return true;
            if (try exprNames(a, out, x.value)) return true;
        },
        .@"if" => |i| if (try exprNames(a, out, i.cond) or try names(a, out, i.then) or try names(a, out, i.@"else")) return true,
        else => return true,
    };
    return false;
}

fn exprNames(a: Allocator, out: *std.AutoHashMapUnmanaged(u32, void), e: *const ir.Expr) Allocator.Error!bool {
    switch (e.kind) {
        .lit, .local => {},
        .name => |n| try out.put(a, n.id, {}),
        .exe => |x| for (x.args) |arg| if (try exprNames(a, out, arg)) return true,
        .unary => |u| return exprNames(a, out, u.operand),
        .binary => |b| return try exprNames(a, out, b.lhs) or try exprNames(a, out, b.rhs),
        .logic => |l| return try exprNames(a, out, l.lhs) or try exprNames(a, out, l.rhs),
        .assign => |x| {
            if (x.target == .name) try out.put(a, x.target.name.id, {}) else if (x.target != .local) return true;
            return exprNames(a, out, x.value);
        },
        else => return true,
    }
    return false;
}

/// `f` (what `l` was lifted from) with the items' current values in their statements:
/// a changed value becomes a new literal over the old one's bytes, so the exporter
/// writes it there (export by origin). error.NotClassic: a call argument read from a
/// local constant changed (its literal is another statement's).
pub fn unlift(a: Allocator, f: *const ir.Fn, l: Lifted) (Allocator.Error || error{NotClassic})!*const ir.Fn {
    if (l.items.len == 0) return f;
    const body = try a.dupe(ir.Stmt, f.body);
    for (l.items) |it| switch (it) {
        .field => |x| {
            const s = &body[x.origin.at];
            var asg = s.kind.assign;
            asg.value = try put(a, asg.value, x.value);
            s.kind = .{ .assign = asg };
        },
        .call => |x| {
            const s = &body[x.origin.at];
            const old = s.kind.expr;
            const args = try a.dupe(*const ir.Expr, old.kind.call.args);
            for (args, x.args) |*e, v| {
                if (literal(e.*) != null) {
                    e.* = try put(a, e.*, v);
                } else if (v == .nil) {
                    // An opaque argument (Opts.opaque_args): its code.
                } else if (e.*.kind == .name) {
                    // The class's variable the run set before it: the call reads that item's value.
                    if (!sameNumber(v, setBefore(l, e.*.kind.name.id, x.origin.at) orelse return error.NotClassic)) return error.NotClassic;
                } else if (e.*.kind != .local or !same(v, try constantOf(a, f, e.*, x.origin.at))) return error.NotClassic;
            }
            const e = try a.create(ir.Expr);
            e.* = old.*;
            e.kind.call.args = args;
            s.kind = .{ .expr = e };
        },
    };
    const g = try a.create(ir.Fn);
    g.* = f.*;
    g.body = body;
    return g;
}

/// The constant a local read before statement `at` holds (as `lift` folded it).
fn constantOf(a: Allocator, f: *const ir.Fn, e: *const ir.Expr, at: u32) Allocator.Error!Value {
    const slot = e.kind.local;
    var t: ir.Type = .any;
    var v: Value = .nil;
    for (f.body[0..at]) |s| switch (s.kind) {
        .local => |x| if (x.slot == slot) {
            t = x.type;
            v = .initial(x.type);
        },
        .assign => |x| if (x.target == .local and x.target.local == slot) {
            v = try literal(x.value).?.convert(t, a);
        },
        else => {},
    };
    return v;
}

/// The value of the last field item of `l` setting variable `id` before statement `at`.
fn setBefore(l: Lifted, id: u32, at: u32) ?Value {
    var v: ?Value = null;
    for (l.items) |it| if (it == .field and it.field.id == id and it.field.origin.at < at) {
        v = it.field.value;
    };
    return v;
}

/// `x` and `y` the same, a number of either kind by its value (`2` and `2.0`).
fn sameNumber(x: Value, y: Value) bool {
    if (ir.numeric(x) and ir.numeric(y)) return x.toFloat() == y.toFloat();
    return same(x, y);
}

fn same(x: Value, y: Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .int => |i| i == y.int,
        .float => |q| @as(u32, @bitCast(q)) == @as(u32, @bitCast(y.float)),
        .string => |s| std.mem.eql(u8, s, y.string),
        else => false,
    };
}

/// `old` if it already evaluates to `v`, else a literal of `v` (a minus over the
/// magnitude when negative) at `old`'s bytes.
fn put(a: Allocator, old: *const ir.Expr, v: Value) Allocator.Error!*const ir.Expr {
    if (literal(old)) |o| if (same(o, v)) return old;
    const neg = switch (v) {
        .int => |i| i < 0 and i != std.math.minInt(i32),
        .float => |q| std.math.signbit(q),
        else => false,
    };
    const lit = try a.create(ir.Expr);
    lit.* = .{ .line = old.line, .span = old.span, .kind = .{ .lit = if (neg) ir.neg(v) else v } };
    if (!neg) return lit;
    const e = try a.create(ir.Expr);
    e.* = .{ .line = old.line, .span = old.span, .kind = .{ .unary = .{ .op = .neg, .operand = lit } } };
    return e;
}

/// The `.var` layer of an object of class `cls`: each entry of a variable the class
/// declares as int or float (`Runtime.applyVar`: the exe reads no other), with its bytes
/// in `text` (`entries`' keys and values are slices of it).
pub fn varFields(a: Allocator, cls: *const object.Class, file: []const u8, text: []const u8, entries: anytype) Allocator.Error![]const Field {
    var out: std.ArrayList(Field) = .empty;
    for (entries) |e| {
        const name = fields.engine(cls.host, e.key);
        const id = try object.intern(name);
        const t = for (cls.vars.items) |d| {
            if (try cls.varId(d) == id) break d.type;
        } else continue;
        const v = Value.parse(e.value, t) orelse continue;
        const start: u32 = @intCast(@intFromPtr(e.value.ptr) - @intFromPtr(text.ptr));
        try out.append(a, .{ .id = id, .name = name, .value = v, .origin = .{ .file = file, .layer = .vars, .span = .{ .start = start, .end = start + @as(u32, @intCast(e.value.len)) } } });
    }
    return out.items;
}

/// The model's value of variable `id` after the `.var` layer and the event: the last
/// lifted assignment, else the `.var` entry; null: neither sets it (the schema default,
/// or code does).
pub fn fieldValue(vars: []const Field, l: Lifted, id: u32) ?Field {
    var i = l.items.len;
    while (i > 0) {
        i -= 1;
        if (l.items[i] == .field and l.items[i].field.id == id) return l.items[i].field;
    }
    for (vars) |v| if (v.id == id) return v;
    return null;
}

test "lift: literals, data calls and constants out of init, the rest stays code" {
    const parser = @import("../parser.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Src = struct {
        a: Allocator,
        fn unit(ctx: *anyopaque, file: []const u8, diag: *parser.Diagnostic) anyerror!import.Loaded {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const text = if (std.mem.eql(u8, file, "ft_x.ss"))
                "hp = 100; float spd; spd = 1.5; ActorSetWalkSpeed(\"walk\", spd);"
            else
                return error.ScriptNotFound;
            return .{ .unit = try parser.parse(self.a, text, diag), .key = file };
        }
        fn callee(_: *anyopaque, id: u32) import.Callee {
            return .{ .data = id == (object.intern("ActorSetWalkSpeed") catch unreachable) };
        }
    };
    var src: Src = .{ .a = a };
    const env: import.Env = .{ .ctx = &src, .unit = Src.unit, .callee = Src.callee };
    const text =
        \\int hp; float x; int rage; int lvl; float sp;
        \\function init()
        \\{
        \\#include ft_x.ss
        \\  hp = 30;
        \\  x = -2.5;
        \\  sp = 2;
        \\  ActorSetWalkSpeed("run", sp);
        \\  if (rage) x = 3;
        \\  rage = 5;
        \\  lvl = 7;
        \\  Go();
        \\  lvl = 1;
        \\};
    ;
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, text, &diag);
    var cls: object.Class = .{ .name = "x.ftr", .parent = null };
    for (u.items) |it| if (it == .var_decl) try cls.vars.append(a, it.var_decl);
    var func: object.Func = .{ .ast = &u.items[5].function, .file = "x.ftr" };
    const f = (try import.function(a, a, env, &func)).ir;
    const l = try lift(a, env, f, &cls);
    // hp=100 (archetype), the walk speed, hp=30, x=-2.5, sp=2 and the run speed by it (the
    // class's variable the run has set: 2.0, its float), then lvl=7 (nothing before it in
    // the rest names lvl); `rage = 5` follows a read of rage, `lvl = 1` a call.
    try std.testing.expectEqual(7, l.items.len);
    try std.testing.expectEqual(Value{ .float = 2 }, l.items[5].call.args[1]);
    try std.testing.expectEqual(Layer.archetype, l.items[0].field.origin.layer);
    try std.testing.expectEqualStrings("ft_x.ss", l.items[1].call.origin.file);
    try std.testing.expectEqual(Value{ .float = 1.5 }, l.items[1].call.args[1]);
    try std.testing.expectEqual(Layer.instance, l.items[2].field.origin.layer);
    try std.testing.expectEqual(Value{ .float = -2.5 }, l.items[3].field.value);
    // The local's two statements, the if, rage = 5, Go(), lvl = 1.
    try std.testing.expectEqual(6, l.rest.body.len);
    try std.testing.expectEqual(30, fieldValue(&.{}, l, try object.intern("hp")).?.value.int);
    try std.testing.expectEqual(7, fieldValue(&.{}, l, try object.intern("lvl")).?.value.int);
    // Unchanged it is the same function; a changed value is a literal at the old bytes.
    try std.testing.expect(@import("print.zig").same(ir.Fn, f.*, (try unlift(a, f, l)).*));
    var items = try a.dupe(Item, l.items);
    items[3].field.value = .{ .float = 4 };
    const g = try unlift(a, f, .{ .items = items, .rest = l.rest });
    try std.testing.expectEqual(Value{ .float = 4 }, g.body[l.items[3].field.origin.at].kind.assign.value.kind.lit);
    items[1].call.args = &.{ .{ .string = "walk" }, .{ .float = 2 } };
    try std.testing.expectError(error.NotClassic, unlift(a, f, .{ .items = items, .rest = l.rest }));
}
