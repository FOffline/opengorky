//! Classic exporter: IR changes written back as text of the original's
//! language. The source of truth is each file's original bytes plus the byte ranges the
//! importer keeps on every node (`ir.Span`): a file nothing changed in keeps its bytes;
//! a changed node is re-printed by the Classic printer (`print.zig`) in the file's style
//! (line end, indent of its line, tab or spaces) over its own range only, so comments and
//! layout around it stay. A literal edit rewrites the literal, a new call argument the
//! argument; only a statement list whose length changed inside an `if` branch (a branch
//! may have no braces) re-prints the whole `if`, and a function body with no statement to
//! anchor an insertion re-prints the function.
//!
//! Correctness is checked, not assumed: every changed function is imported again from
//! the written text and must give the new IR exactly (positions aside), else the export
//! fails with `error.NotClassic` and the place in `diag`. Nothing is lost silently.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ast = @import("../ast.zig");
const ir = @import("../ir.zig");
const object = @import("../object.zig");
const parser = @import("../parser.zig");
const import = @import("import.zig");
const print = @import("print.zig");

/// A function as imported (`old`) and as it must be (`new`). No `old`: `new` is added at
/// the end of `new.file`; no `new`: `old` is removed.
pub const Change = struct { old: ?*const ir.Fn, new: ?*const ir.Fn };

pub const Error = error{
    /// The new IR has no text in the original's language that imports back to it.
    NotClassic,
    /// Two changes rewrite the same bytes differently (an included file changed through
    /// two functions that include it).
    Conflict,
} || Allocator.Error;

pub const Diagnostic = parser.Diagnostic;

const Inner = Error || error{
    /// The list cannot take the change in place: the enclosing node is re-printed.
    Reprint,
};

const Splice = struct { file: []const u8, start: u32, end: u32, text: []const u8 };

pub const Export = struct {
    /// Arena: texts, trees and IR live until the caller frees it.
    a: Allocator,
    /// The imported project: original texts (`ast.Unit.src`) and builtin facts.
    base: import.Env,
    /// Lower-case file → new text, for the files that changed.
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Parse trees of `files` (what `env` gives for them).
    units: std.StringHashMapUnmanaged(ast.Unit) = .empty,
    splices: std.ArrayList(Splice) = .empty,
    diag: Diagnostic = .{},

    pub fn init(a: Allocator, base: import.Env) Export {
        return .{ .a = a, .base = base };
    }

    /// Writes the changes into `files` and checks every changed function imports back to
    /// its new IR.
    pub fn apply(self: *Export, changes: []const Change) Error!void {
        for (changes) |c| {
            const r = if (c.old) |o|
                (if (c.new) |n| self.function(o, n) else self.remove(o.file, o.span))
            else if (c.new) |n|
                self.append(n)
            else {};
            r catch |err| return switch (err) {
                error.Reprint => unreachable,
                else => |e| e,
            };
        }
        try self.write();
        for (changes) |c| if (c.new) |n| try self.verify(n);
    }

    /// The importer's view of the exported project: new texts over the original ones.
    pub fn env(self: *Export) import.Env {
        return .{ .ctx = self, .unit = envUnit, .callee = envCallee };
    }

    fn envUnit(ctx: *anyopaque, file: []const u8, diag: *parser.Diagnostic) anyerror!import.Loaded {
        const self: *Export = @ptrCast(@alignCast(ctx));
        const key = try std.ascii.allocLowerString(self.a, file);
        if (self.units.get(key)) |u| return .{ .unit = u, .key = key };
        return self.base.unit(self.base.ctx, file, diag);
    }

    fn envCallee(ctx: *anyopaque, id: u32) import.Callee {
        const self: *Export = @ptrCast(@alignCast(ctx));
        return self.base.callee(self.base.ctx, id);
    }

    fn fail(self: *Export, file: []const u8, line: u32, message: []const u8) error{NotClassic} {
        self.diag = .{ .file = file, .line = line, .message = message };
        return error.NotClassic;
    }

    /// Original text of a file.
    fn source(self: *Export, file: []const u8) Error![]const u8 {
        var diag: parser.Diagnostic = .{};
        const l = self.base.unit(self.base.ctx, file, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail(file, diag.line, "the original text cannot be read"),
        };
        return l.unit.src;
    }

    fn splice(self: *Export, file: []const u8, start: u32, end: u32, text: []const u8) Allocator.Error!void {
        try self.splices.append(self.a, .{ .file = file, .start = start, .end = end, .text = text });
    }

    // ---------------------------------------------------------------- functions

    fn function(self: *Export, o: *const ir.Fn, n: *const ir.Fn) Inner!void {
        if (print.same(ir.Fn, o.*, n.*)) return;
        if (o.span.none()) return self.fail(o.file, o.line, "the function has no position");
        // New locals may be added; a renamed one is a new header.
        const header = std.mem.eql(u8, o.name, n.name) and print.same([]const ir.Param, o.params, n.params) and
            n.names.len >= o.names.len and print.same([]const []const u8, o.names, n.names[0..o.names.len]);
        const mark = self.splices.items.len;
        if (header) {
            if (self.list(o.body, n.body, .{ .owner = o.file, .branch = false, .f = n })) return else |err| switch (err) {
                error.Reprint => self.splices.shrinkRetainingCapacity(mark),
                else => |e| return e,
            }
        }
        try self.splice(o.file, o.span.start, o.span.end, try self.printFn(n, o.file));
    }

    fn printFn(self: *Export, f: *const ir.Fn, file: []const u8) Error![]const u8 {
        const src = try self.source(file);
        var style = print.Style.of(src);
        style.src = src;
        var out: Writer.Allocating = .init(self.a);
        print.function(&out.writer, f, style) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            error.NotClassic => self.fail(f.file, f.line, "the function has no Classic text"),
        };
        return out.written();
    }

    /// A new function after the last one in its file.
    fn append(self: *Export, f: *const ir.Fn) Error!void {
        const src = try self.source(f.file);
        const style = print.Style.of(src);
        const end = std.mem.trimEnd(u8, src, " \t\r\n\x1a").len;
        const text = try std.mem.concat(self.a, u8, &.{ style.nl, style.nl, try self.printFn(f, f.file) });
        try self.splice(f.file, @intCast(end), @intCast(end), text);
    }

    /// Removes a node's text, its whole line if nothing else is on it.
    fn remove(self: *Export, file: []const u8, s: ir.Span) Error!void {
        if (s.none()) return self.fail(file, 0, "the removed node has no position");
        const src = try self.source(file);
        var start = s.start;
        var end = s.end;
        const ls = lineStart(src, start);
        const le = lineEnd(src, end);
        if (blank(src[ls..start]) and blank(src[end..le])) {
            start = ls;
            end = if (le < src.len) le + 1 else le;
        }
        try self.splice(file, start, end, "");
    }

    // ---------------------------------------------------------------- statements

    const List = struct {
        /// File holding the list (the `if`'s or the function's).
        owner: []const u8,
        /// An `if` branch: a length change re-prints the `if`.
        branch: bool,
        /// The new function (local names).
        f: *const ir.Fn,
    };

    /// Aligns the lists: unchanged statements first (longest common subsequence), then,
    /// between them, edits of statements of the same kind; the rest is removed or inserted.
    fn list(self: *Export, os: []const ir.Stmt, ns: []const ir.Stmt, ctx: List) Inner!void {
        // The common ends first: an edit leaves a small middle to align.
        const m = @min(os.len, ns.len);
        var p: usize = 0;
        while (p < m and print.same(ir.Stmt, os[p], ns[p])) p += 1;
        var s: usize = 0;
        while (s < m - p and print.same(ir.Stmt, os[os.len - 1 - s], ns[ns.len - 1 - s])) s += 1;
        const mo = os[p .. os.len - s];
        const mn = ns[p .. ns.len - s];
        // Per statement of the middle: what it becomes (null: removed).
        const to = try self.a.alloc(?*const ir.Stmt, mo.len);
        @memset(to, null);
        var inserts: std.ArrayList(Insert) = .empty;
        const kept = try lcs(self.a, mo, mn, sameStmt);
        var pi: usize = 0;
        var pj: usize = 0;
        for (kept) |k| {
            const gap_o = mo[pi..k.i];
            const gap_n = mn[pj..k.j];
            var qi: usize = 0;
            var qj: usize = 0;
            for (try lcs(self.a, gap_o, gap_n, sameKind)) |e| {
                if (e.j > qj) try inserts.append(self.a, .{ .at = p + pi + e.i, .stmts = gap_n[qj..e.j] });
                if (e.i < gap_o.len) to[pi + e.i] = &gap_n[e.j];
                qi = e.i + 1;
                qj = e.j + 1;
            }
            if (k.i < mo.len) to[k.i] = &mn[k.j];
            pi = k.i + 1;
            pj = k.j + 1;
        }
        const removes = std.mem.indexOfScalar(?*const ir.Stmt, to, null) != null;
        if (ctx.branch and (removes or inserts.items.len > 0)) return error.Reprint;
        for (mo, to) |*o, n| if (n) |x| try self.stmt(o, x, ctx.f) else try self.remove(o.file, o.span);
        for (inserts.items) |in| {
            // Anchors: the nearest statements around the place that stay.
            var prev: ?*const ir.Stmt = null;
            var q = in.at;
            while (q > 0) : (q -= 1) if (q - 1 < p or q - 1 >= p + mo.len or to[q - 1 - p] != null) {
                prev = &os[q - 1];
                break;
            };
            var next: ?*const ir.Stmt = null;
            q = in.at;
            while (q < os.len) : (q += 1) if (q < p or q >= p + mo.len or to[q - p] != null) {
                next = &os[q];
                break;
            };
            try self.insert(prev, next, in.stmts, ctx);
        }
    }

    const Insert = struct {
        /// Index in the old list the statements go before.
        at: usize,
        stmts: []const ir.Stmt,
    };

    fn insert(self: *Export, prev: ?*const ir.Stmt, next: ?*const ir.Stmt, new: []const ir.Stmt, ctx: List) Inner!void {
        if (prev) |a| {
            // Between two statements of one include: into the included file.
            const inside = if (next) |b| !a.via.none() and std.meta.eql(a.via, b.via) and std.mem.eql(u8, a.file, b.file) else false;
            if (!a.via.none() and !inside) return self.insertAfter(ctx.owner, a.via, new, ctx.f);
            if (a.span.none()) return self.fail(a.file, a.line, "the statement has no position");
            return self.insertAfter(a.file, a.span, new, ctx.f);
        }
        const b = next orelse return error.Reprint;
        if (!b.via.none()) return self.insertBefore(ctx.owner, b.via, new, ctx.f);
        if (b.span.none()) return self.fail(b.file, b.line, "the statement has no position");
        return self.insertBefore(b.file, b.span, new, ctx.f);
    }

    /// The file's style with the indent of the anchor's line; a directive is mostly
    /// written at column 0, so a statement next to one gets one step (as `vars.set`).
    fn styleAt(src: []const u8, anchor: ir.Span) print.Style {
        var style = print.Style.of(src);
        style.base = indentOf(src, anchor.start);
        if (style.base.len == 0 and src[anchor.start] == '#') style.base = style.unit;
        return style;
    }

    /// New statements on lines of their own after `anchor` (after a comment that ends its line).
    fn insertAfter(self: *Export, file: []const u8, anchor: ir.Span, new: []const ir.Stmt, f: *const ir.Fn) Error!void {
        const src = try self.source(file);
        const style = styleAt(src, anchor);
        var at: u32 = anchor.end;
        const le = lineEnd(src, at);
        const rest = std.mem.trim(u8, src[at..le], " \t\r");
        const moved = rest.len == 0 or std.mem.startsWith(u8, rest, "//");
        if (moved) at = @intCast(if (le > at and src[le - 1] == '\r') le - 1 else le);
        var out: Writer.Allocating = .init(self.a);
        for (new) |*n| {
            out.writer.writeAll(style.nl) catch return error.OutOfMemory;
            out.writer.writeAll(style.base) catch return error.OutOfMemory;
            try self.printStmt(&out.writer, n, f, style);
        }
        // A directive runs to the end of its line.
        if (!moved and new[new.len - 1].kind == .fail) {
            out.writer.writeAll(style.nl) catch return error.OutOfMemory;
            out.writer.writeAll(style.base) catch return error.OutOfMemory;
        }
        try self.splice(file, at, at, out.written());
    }

    /// New statements before `anchor`, each ending its line.
    fn insertBefore(self: *Export, file: []const u8, anchor: ir.Span, new: []const ir.Stmt, f: *const ir.Fn) Error!void {
        const src = try self.source(file);
        const style = styleAt(src, anchor);
        var out: Writer.Allocating = .init(self.a);
        for (new) |*n| {
            try self.printStmt(&out.writer, n, f, style);
            out.writer.writeAll(style.nl) catch return error.OutOfMemory;
            out.writer.writeAll(style.base) catch return error.OutOfMemory;
        }
        try self.splice(file, anchor.start, anchor.start, out.written());
    }

    fn printStmt(self: *Export, w: *Writer, s: *const ir.Stmt, f: *const ir.Fn, style: print.Style) Error!void {
        print.statement(w, s, f, style, 0) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            error.NotClassic => self.fail(s.file, s.line, "the statement has no Classic text"),
        };
    }

    fn stmt(self: *Export, o: *const ir.Stmt, n: *const ir.Stmt, f: *const ir.Fn) Inner!void {
        if (print.same(ir.Stmt, o.*, n.*)) return;
        if (o.span.none()) return self.fail(o.file, o.line, "the statement has no position");
        if (std.meta.activeTag(o.kind) == std.meta.activeTag(n.kind)) switch (o.kind) {
            .expr => |e| return self.expr(o.file, e, n.kind.expr, 0, false, f),
            .@"return" => |e| return self.expr(o.file, e, n.kind.@"return", 0, false, f),
            .assign => |a| if (print.same(ir.Target, a.target, n.kind.assign.target))
                return self.expr(o.file, a.value, n.kind.assign.value, 0, false, f),
            .@"if" => |i| {
                const mark = self.splices.items.len;
                const ni = n.kind.@"if";
                if (self.expr(o.file, i.cond, ni.cond, 0, true, f)) {
                    const branch: List = .{ .owner = o.file, .branch = true, .f = f };
                    if (self.list(i.then, ni.then, branch)) {
                        if (self.list(i.@"else", ni.@"else", branch)) return else |err| if (err != error.Reprint) return err;
                    } else |err| if (err != error.Reprint) return err;
                } else |err| return err;
                self.splices.shrinkRetainingCapacity(mark);
            },
            else => {},
        };
        const src = try self.source(o.file);
        var style = print.Style.of(src);
        style.base = indentOf(src, o.span.start);
        style.src = src;
        var out: Writer.Allocating = .init(self.a);
        try self.printStmt(&out.writer, n, f, style);
        if (n.kind == .fail and !blank(src[o.span.end..lineEnd(src, o.span.end)])) {
            out.writer.writeAll(style.nl) catch return error.OutOfMemory;
            out.writer.writeAll(style.base) catch return error.OutOfMemory;
        }
        try self.splice(o.file, o.span.start, o.span.end, out.written());
    }

    // ---------------------------------------------------------------- expressions

    /// `min`, `truth`: the place of the node (`print.expression`).
    fn expr(self: *Export, file: []const u8, o: *const ir.Expr, n: *const ir.Expr, min: u8, truth: bool, f: *const ir.Fn) Inner!void {
        if (print.same(ir.Expr, o.*, n.*)) return;
        if (o.span.none()) return self.fail(file, o.line, "the expression has no position");
        if (std.meta.activeTag(o.kind) == std.meta.activeTag(n.kind)) switch (o.kind) {
            .call => |c| if (std.mem.eql(u8, c.text, n.kind.call.text) and c.args.len == n.kind.call.args.len) {
                for (c.args, n.kind.call.args) |x, y| try self.expr(file, x, y, 0, false, f);
                return;
            },
            .exe => |x| if (x.op == n.kind.exe.op and x.args.len == n.kind.exe.args.len) {
                const y = n.kind.exe.args;
                switch (x.op) {
                    .truthy => return self.expr(file, x.args[0], y[0], min, truth, f),
                    .neg, .not => return self.expr(file, x.args[0], y[0], 6, false, f),
                    inline else => |op| return self.infix(file, @field(ast.BinaryOp, @tagName(op)), x.args, y, f),
                }
            },
            .unary => |u| if (u.op == n.kind.unary.op) return self.expr(file, u.operand, n.kind.unary.operand, 6, false, f),
            .binary => |b| if (b.op == n.kind.binary.op)
                return self.infix(file, print.astOp(b.op), &.{ b.lhs, b.rhs }, &.{ n.kind.binary.lhs, n.kind.binary.rhs }, f),
            .logic => |l| if (l.op == n.kind.logic.op)
                return self.infix(file, if (l.op == .@"and") .@"and" else .@"or", &.{ l.lhs, l.rhs }, &.{ n.kind.logic.lhs, n.kind.logic.rhs }, f),
            .assign => |a| if (print.same(ir.Target, a.target, n.kind.assign.target))
                return self.expr(file, a.value, n.kind.assign.value, 0, false, f),
            else => {},
        };
        var out: Writer.Allocating = .init(self.a);
        print.expression(&out.writer, n, f, min, truth) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            error.NotClassic => self.fail(file, n.line, "the expression has no Classic text"),
        };
        try self.splice(file, o.span.start, o.span.end, out.written());
    }

    fn infix(self: *Export, file: []const u8, op: ast.BinaryOp, o: []const *const ir.Expr, n: []const *const ir.Expr, f: *const ir.Fn) Inner!void {
        const l = print.opLevel(op);
        try self.expr(file, o[0], n[0], l, l == 1, f);
        try self.expr(file, o[1], n[1], l + 1, l == 1, f);
    }

    // ---------------------------------------------------------------- writing and checking

    fn order(_: void, x: Splice, y: Splice) bool {
        return switch (std.mem.order(u8, x.file, y.file)) {
            .lt => true,
            .gt => false,
            .eq => x.start < y.start or (x.start == y.start and x.end < y.end),
        };
    }

    fn write(self: *Export) Error!void {
        const all = self.splices.items;
        std.sort.block(Splice, all, {}, order);
        var i: usize = 0;
        while (i < all.len) {
            const file = all[i].file;
            const src = try self.source(file);
            var out: std.ArrayList(u8) = .empty;
            var pos: u32 = 0;
            var last: ?Splice = null;
            while (i < all.len and std.mem.eql(u8, all[i].file, file)) : (i += 1) {
                const sp = all[i];
                if (last) |l| {
                    // The same rewrite reached through two includers.
                    if (l.start == sp.start and l.end == sp.end and std.mem.eql(u8, l.text, sp.text)) continue;
                    if (sp.start < l.end or (sp.start == l.start and sp.end == l.end))
                        return self.fail(file, 0, "two changes rewrite the same text");
                }
                try out.appendSlice(self.a, src[pos..sp.start]);
                try out.appendSlice(self.a, sp.text);
                pos = sp.end;
                last = sp;
            }
            try out.appendSlice(self.a, src[pos..]);
            var diag: parser.Diagnostic = .{};
            const unit = parser.parse(self.a, out.items, &diag) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(file, diag.line, "the written text does not parse"),
            };
            const key = try std.ascii.allocLowerString(self.a, file);
            try self.files.put(self.a, key, out.items);
            try self.units.put(self.a, key, unit);
        }
    }

    /// The function imported from the written text must be the new IR.
    fn verify(self: *Export, n: *const ir.Fn) Error!void {
        var diag: parser.Diagnostic = .{};
        const loaded = envUnit(self, n.file, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail(n.file, diag.line, "the file cannot be read back"),
        };
        for (loaded.unit.items) |*it| switch (it.*) {
            .function => |*af| if (std.ascii.eqlIgnoreCase(af.name, n.name)) {
                var func: object.Func = .{ .ast = af, .file = loaded.key };
                const r = try import.function(self.a, self.a, self.env(), &func);
                if (!print.same(ir.Fn, r.ir.*, n.*)) return self.fail(n.file, n.line, "the written text imports to other IR");
                return;
            },
            else => {},
        };
        return self.fail(n.file, n.line, "the function is not in the written text");
    }
};

fn sameStmt(a: ir.Stmt, b: ir.Stmt) bool {
    return print.same(ir.Stmt, a, b);
}

fn sameKind(a: ir.Stmt, b: ir.Stmt) bool {
    return std.meta.activeTag(a.kind) == std.meta.activeTag(b.kind);
}

const Match = struct { i: usize, j: usize };

/// Longest common subsequence of `x` and `y` under `eq`, as index pairs, ending with the
/// sentinel `{x.len, y.len}`.
fn lcs(a: Allocator, x: []const ir.Stmt, y: []const ir.Stmt, comptime eq: fn (ir.Stmt, ir.Stmt) bool) Allocator.Error![]const Match {
    const w = y.len + 1;
    // len[i * w + j]: the length for x[i..], y[j..].
    const len = try a.alloc(u32, (x.len + 1) * w);
    @memset(len, 0);
    var i = x.len;
    while (i > 0) {
        i -= 1;
        var j = y.len;
        while (j > 0) {
            j -= 1;
            len[i * w + j] = if (eq(x[i], y[j])) len[(i + 1) * w + j + 1] + 1 else @max(len[(i + 1) * w + j], len[i * w + j + 1]);
        }
    }
    var out: std.ArrayList(Match) = .empty;
    var pi: usize = 0;
    var pj: usize = 0;
    while (pi < x.len and pj < y.len) {
        if (eq(x[pi], y[pj])) {
            try out.append(a, .{ .i = pi, .j = pj });
            pi += 1;
            pj += 1;
        } else if (len[(pi + 1) * w + pj] >= len[pi * w + pj + 1]) pi += 1 else pj += 1;
    }
    try out.append(a, .{ .i = x.len, .j = y.len });
    return out.items;
}

fn lineStart(src: []const u8, at: u32) u32 {
    return @intCast(if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |i| i + 1 else 0);
}

/// Index of the `\n` ending the line (or the text's end).
fn lineEnd(src: []const u8, at: u32) u32 {
    return @intCast(if (std.mem.indexOfScalarPos(u8, src, at, '\n')) |i| i else src.len);
}

fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r").len == 0;
}

/// Leading whitespace of the line holding `at`.
fn indentOf(src: []const u8, at: u32) []const u8 {
    const ls = lineStart(src, at);
    var e = ls;
    while (e < at and (src[e] == ' ' or src[e] == '\t')) e += 1;
    return src[ls..e];
}

// ---------------------------------------------------------------- tests

/// Files in memory, parsed on first use; no builtins.
const TestEnv = struct {
    a: Allocator,
    texts: []const [2][]const u8,
    units: std.StringHashMapUnmanaged(ast.Unit) = .empty,

    fn env(self: *TestEnv) import.Env {
        return .{ .ctx = self, .unit = unit, .callee = callee };
    }

    fn unit(ctx: *anyopaque, file: []const u8, diag: *parser.Diagnostic) anyerror!import.Loaded {
        const self: *TestEnv = @ptrCast(@alignCast(ctx));
        const key = try std.ascii.allocLowerString(self.a, file);
        if (self.units.get(key)) |u| return .{ .unit = u, .key = key };
        for (self.texts) |t| if (std.mem.eql(u8, t[0], key)) {
            const u = try parser.parse(self.a, t[1], diag);
            try self.units.put(self.a, key, u);
            return .{ .unit = u, .key = key };
        };
        return error.ScriptNotFound;
    }

    fn callee(_: *anyopaque, _: u32) import.Callee {
        return .{};
    }

    /// IR of the file's function `name`.
    fn function(self: *TestEnv, file: []const u8, name: []const u8) !*const ir.Fn {
        const l = try unit(self, file, undefined);
        for (l.unit.items) |*it| if (it.* == .function and std.mem.eql(u8, it.function.name, name)) {
            const func = try self.a.create(object.Func);
            func.* = .{ .ast = &it.function, .file = l.key };
            return (try import.function(self.a, self.a, self.env(), func)).ir;
        };
        return error.NotFound;
    }
};

const test_lev =
    "#inherit Level\r\n" ++
    "int a;\r\n" ++
    "function init()\r\n" ++
    "{\r\n" ++
    "\ta = 1; // one\r\n" ++
    "#include x.ss\r\n" ++
    "\tif(a)\r\n" ++
    "\t\tStart(\"s\", a + 2);\r\n" ++
    "\t/* keep */ Stop(a);\r\n" ++
    "};\r\n" ++
    "function e()\r\n" ++
    "{\r\n" ++
    "};\r\n";
const test_ss = "hp = 30;\r\nmax = 5;\r\n";

fn testExport(a: Allocator, te: *TestEnv, old: *const ir.Fn, new: *const ir.Fn) !Export {
    var ex: Export = .init(a, te.env());
    ex.apply(&.{.{ .old = old, .new = new }}) catch |err| {
        std.debug.print("{f}\n", .{ex.diag});
        return err;
    };
    return ex;
}

fn dupe(a: Allocator, f: *const ir.Fn) !*ir.Fn {
    const p = try a.create(ir.Fn);
    p.* = f.*;
    p.body = try a.dupe(ir.Stmt, f.body);
    return p;
}

fn lit(a: Allocator, v: @import("../value.zig").Value) !*const ir.Expr {
    const p = try a.create(ir.Expr);
    p.* = .{ .line = 0, .kind = .{ .lit = v } };
    return p;
}

test "export: nothing changed keeps every byte; a literal changes only its bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var te: TestEnv = .{ .a = a, .texts = &.{ .{ "t.lev", test_lev }, .{ "x.ss", test_ss } } };
    const f = try te.function("t.lev", "init");
    // Statements: a = 1, hp = 30, max = 5 (x.ss), if, Stop.
    try std.testing.expectEqual(5, f.body.len);
    var ex = try testExport(a, &te, f, f);
    try std.testing.expectEqual(0, ex.files.count());

    // `a + 2` → `a + 7` in the call of the `if` branch; `max = 5` → `max = 6` in x.ss.
    const g = try dupe(a, f);
    const call = g.body[3].kind.@"if".then[0].kind.expr.kind.call;
    const sum = call.args[1].kind.exe;
    const new_sum = try a.create(ir.Expr);
    new_sum.* = .{ .line = 0, .kind = .{ .exe = .{ .op = sum.op, .args = &.{ sum.args[0], try lit(a, .{ .int = 7 }) } } } };
    const new_call = try a.create(ir.Expr);
    new_call.* = .{ .line = 0, .kind = .{ .call = .{ .id = call.id, .text = call.text, .args = &.{ call.args[0], new_sum } } } };
    var then = try a.dupe(ir.Stmt, g.body[3].kind.@"if".then);
    then[0].kind = .{ .expr = new_call };
    @constCast(g.body)[3].kind = .{ .@"if" = .{ .cond = f.body[3].kind.@"if".cond, .then = then, .@"else" = &.{} } };
    @constCast(g.body)[2].kind = .{ .assign = .{ .target = g.body[2].kind.assign.target, .value = try lit(a, .{ .int = 6 }) } };
    ex = try testExport(a, &te, f, g);
    try std.testing.expectEqual(2, ex.files.count());
    try std.testing.expectEqualStrings(std.mem.replaceOwned(u8, a, test_lev, "a + 2", "a + 7") catch unreachable, ex.files.get("t.lev").?);
    try std.testing.expectEqualStrings("hp = 30;\r\nmax = 6;\r\n", ex.files.get("x.ss").?);
}

test "export: insert after an include, remove a line, re-print an if, add a function" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var te: TestEnv = .{ .a = a, .texts = &.{ .{ "t.lev", test_lev }, .{ "x.ss", test_ss } } };
    const f = try te.function("t.lev", "init");
    const g = try dupe(a, f);
    // A copy of `a = 1` after the include, `Stop(a)` gone, `a = 1` added to the if branch.
    var then = try a.dupe(ir.Stmt, g.body[3].kind.@"if".then);
    then = try std.mem.concat(a, ir.Stmt, &.{ then, &.{f.body[0]} });
    g.body = try std.mem.concat(a, ir.Stmt, &.{ f.body[0..3], &.{f.body[0]}, &.{.{
        .file = f.body[3].file,
        .line = 0,
        .span = f.body[3].span,
        .kind = .{ .@"if" = .{ .cond = f.body[3].kind.@"if".cond, .then = then, .@"else" = &.{} } },
    }} });
    const ex = try testExport(a, &te, f, g);
    try std.testing.expectEqualStrings(
        "#inherit Level\r\n" ++
            "int a;\r\n" ++
            "function init()\r\n" ++
            "{\r\n" ++
            "\ta = 1; // one\r\n" ++
            "#include x.ss\r\n" ++
            "\ta = 1;\r\n" ++
            "\tif(a)\r\n" ++
            "\t{\r\n" ++
            "\t\tStart(\"s\", a + 2);\r\n" ++
            "\t\ta = 1;\r\n" ++
            "\t};\r\n" ++
            "\t/* keep */ \r\n" ++
            "};\r\n" ++
            "function e()\r\n" ++
            "{\r\n" ++
            "};\r\n",
        ex.files.get("t.lev").?,
    );

    // An empty body takes a statement by re-printing the function; a new one goes last.
    const e = try te.function("t.lev", "e");
    const e2 = try dupe(a, e);
    e2.body = f.body[0..1];
    e2.names = f.names;
    const added = try dupe(a, e);
    added.name = "added";
    var ex2: Export = .init(a, te.env());
    try ex2.apply(&.{ .{ .old = e, .new = e2 }, .{ .old = null, .new = added } });
    try std.testing.expect(std.mem.endsWith(u8, ex2.files.get("t.lev").?, "function e()\r\n{\r\n\ta = 1;\r\n};\r\n\r\nfunction added()\r\n{\r\n};\r\n"));
}

test "export: IR with no Classic text is an error, not a guess" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var te: TestEnv = .{ .a = a, .texts = &.{ .{ "t.lev", test_lev }, .{ "x.ss", test_ss } } };
    const f = try te.function("t.lev", "init");
    const g = try dupe(a, f);
    // A plain `+` over a variable of unknown type: Classic text gives `exe.add`.
    const sum = try a.create(ir.Expr);
    const name = g.body[0].kind.assign.target.name;
    const read = try a.create(ir.Expr);
    read.* = .{ .line = 0, .kind = .{ .name = name } };
    sum.* = .{ .line = 0, .kind = .{ .binary = .{ .op = .add, .lhs = read, .rhs = try lit(a, .{ .int = 1 }) } } };
    @constCast(g.body)[0].kind = .{ .assign = .{ .target = g.body[0].kind.assign.target, .value = sum } };
    var ex: Export = .init(a, te.env());
    try std.testing.expectError(error.NotClassic, ex.apply(&.{.{ .old = f, .new = g }}));
    try std.testing.expectEqualStrings("the written text imports to other IR", ex.diag.message);
    // A negative literal has no text.
    @constCast(g.body)[0].kind = .{ .assign = .{ .target = g.body[0].kind.assign.target, .value = try lit(a, .{ .int = -1 }) } };
    ex = .init(a, te.env());
    try std.testing.expectError(error.NotClassic, ex.apply(&.{.{ .old = f, .new = g }}));
}
