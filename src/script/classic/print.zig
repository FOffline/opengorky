//! Classic printer: a parse tree (`unit`) or IR (`function`, `statement`, `expression`)
//! back to text of the original's language that reads as the same tree (`same`, positions
//! aside). IR prints as the construct the importer made it from (an `exe` node as the
//! exe's operator, `and` as `&&`); IR the importer could not have made from any text
//! (`exe.truthy` outside a condition, a negative literal, a string with `"`) is
//! `error.NotClassic`. The exporter (`export.zig`) prints changed nodes with it;
//! `gorky-tool roundtrip` steps 1–2 check it.

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir.zig");
const Writer = std.Io.Writer;
const Value = @import("../value.zig").Value;

pub fn unit(w: *Writer, u: ast.Unit) Writer.Error!void {
    for (u.items) |it| switch (it) {
        .inherit => |n| try w.print("#inherit {s}\n", .{n}),
        .include => |n| try w.print("#include {s}\n", .{n}),
        .var_decl => |d| try w.print("{t} {s};\n", .{ d.type, d.name }),
        .function => |f| {
            try w.print("function {s}(", .{f.name});
            for (f.params, 0..) |p, i| try w.print("{s}{t} {s}", .{ if (i > 0) ", " else "", p.type, p.name });
            try w.writeAll(")\n");
            try block(w, f.body, 0);
            try w.writeAll(";\n");
        },
        .stmt => |s| try stmt(w, s, 0),
    };
}

fn indent(w: *Writer, depth: usize) Writer.Error!void {
    try w.splatByteAll('\t', depth);
}

fn block(w: *Writer, body: []const ast.Stmt, depth: usize) Writer.Error!void {
    try indent(w, depth);
    try w.writeAll("{\n");
    for (body) |s| try stmt(w, s, depth + 1);
    try indent(w, depth);
    try w.writeAll("}");
}

fn stmt(w: *Writer, s: ast.Stmt, depth: usize) Writer.Error!void {
    switch (s) {
        // A directive runs to the end of its line.
        .include => |n| return w.print("#include {s}\n", .{n}),
        // `}` is followed by `;` here, so a block is always `{…};`.
        .block => |b| {
            try block(w, b, depth);
            return w.writeAll(";\n");
        },
        else => {},
    }
    try indent(w, depth);
    switch (s) {
        .include, .block => unreachable,
        .empty => try w.writeAll(";"),
        .expr => |e| {
            try expr(w, e, 0);
            try w.writeAll(";");
        },
        .var_decl => |d| try w.print("{t} {s};", .{ d.type, d.name }),
        .@"return" => |v| if (v.value) |e| {
            try w.writeAll("return(");
            try expr(w, e, 0);
            try w.writeAll(");");
        } else try w.writeAll("return;"),
        .@"if" => |i| {
            try w.writeAll("if(");
            try expr(w, i.cond, 0);
            try w.writeAll(")\n");
            try stmt(w, i.then.*, depth + 1);
            if (i.@"else") |e| {
                try indent(w, depth);
                try w.writeAll("else\n");
                try stmt(w, e.*, depth + 1);
            }
            return;
        },
    }
    try w.writeAll("\n");
}

/// Binding strength: assignment 0, `|| &&` 1, `== !=` 2, `< <= > >=` 3, `+ -` 4, `* /` 5, unary 6.
fn level(e: *const ast.Expr) u8 {
    return switch (e.kind) {
        .assign => 0,
        .binary => |b| opLevel(b.op),
        .unary => 6,
        else => 7,
    };
}

/// The Classic operator of an IR binary or `exe` operator (`ir.BinaryOp`, `ir.ExeOp`).
pub fn astOp(op: anytype) ast.BinaryOp {
    return std.meta.stringToEnum(ast.BinaryOp, @tagName(op)).?;
}

pub fn opLevel(op: ast.BinaryOp) u8 {
    return switch (op) {
        .@"or", .@"and" => 1,
        .eq, .ne => 2,
        .lt, .le, .gt, .ge => 3,
        .add, .sub => 4,
        .mul, .div => 5,
    };
}

fn opText(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .@"and" => "&&",
        .@"or" => "||",
    };
}

/// `min`: the weakest binding printed without parentheses.
fn expr(w: *Writer, e: *const ast.Expr, min: u8) Writer.Error!void {
    if (level(e) < min) {
        try w.writeAll("(");
        try expr(w, e, 0);
        return w.writeAll(")");
    }
    switch (e.kind) {
        .int => |v| try w.print("{d}", .{v}),
        .float => |v| {
            // The lexer reads digits with a dot and no exponent.
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try w.writeAll(text);
            if (std.mem.indexOfScalar(u8, text, '.') == null) try w.writeAll(".0");
        },
        .string => |s| try w.print("\"{s}\"", .{s}),
        .ident => |i| try w.writeAll(i.name),
        .call => |c| {
            try w.print("{s}(", .{c.name});
            for (c.args, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                try expr(w, a, 0);
            }
            try w.writeAll(")");
        },
        .unary => |u| {
            try w.writeAll(if (u.op == .neg) "-" else "!");
            try expr(w, u.operand, 6);
        },
        .binary => |b| {
            const l = opLevel(b.op);
            // Left-associative: an equal level needs parentheses on the right only.
            try expr(w, b.lhs, l);
            try w.print(" {s} ", .{opText(b.op)});
            try expr(w, b.rhs, l + 1);
        },
        .assign => |a| {
            try w.print("{s} = ", .{a.name});
            try expr(w, a.value, 0);
        },
    }
}

// ---------------------------------------------------------------- IR

/// How a file lays out its lines: line end and one indent step.
pub const Style = struct {
    nl: []const u8 = "\n",
    unit: []const u8 = "\t",
    /// Indent of the line the printed text starts on (later lines get it too).
    base: []const u8 = "",
    /// Text of the file holding the printed statements: a run of statements one
    /// `#include` brought (`ir.Stmt.via`) prints as that directive. Empty: printed inline.
    src: []const u8 = "",

    /// The style of a file's text: CRLF if it has any; tab indent unless more lines are
    /// indented with spaces.
    pub fn of(src: []const u8) Style {
        var tabs: usize = 0;
        var spaces: usize = 0;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |l| {
            if (l.len == 0) continue;
            if (l[0] == '\t') tabs += 1 else if (l[0] == ' ') spaces += 1;
        }
        return .{ .nl = if (std.mem.indexOf(u8, src, "\r\n") != null) "\r\n" else "\n", .unit = if (spaces > tabs) "    " else "\t" };
    }
};

pub const Error = Writer.Error || error{NotClassic};

const Out = struct {
    w: *Writer,
    style: Style,
    names: []const []const u8,

    fn line(self: Out, depth: usize) Writer.Error!void {
        try self.w.writeAll(self.style.nl);
        try self.w.writeAll(self.style.base);
        for (0..depth) |_| try self.w.writeAll(self.style.unit);
    }

    fn name(self: Out, slot: u16) Error![]const u8 {
        if (slot >= self.names.len) return error.NotClassic;
        return self.names[slot];
    }
};

/// `function f(int a) { … };` from its first byte through `};`.
pub fn function(w: *Writer, f: *const ir.Fn, style: Style) Error!void {
    const o: Out = .{ .w = w, .style = style, .names = f.names };
    try w.print("function {s}(", .{f.name});
    for (f.params, 0..) |p, i| try w.print("{s}{t} {s}", .{ if (i > 0) ", " else "", p.type, try o.name(p.slot) });
    try w.writeAll(")");
    try braced(o, f.body, 0);
}

/// `{` … `};` on lines of their own at `depth`, the statements one step deeper.
fn braced(o: Out, list: []const ir.Stmt, depth: usize) Error!void {
    try o.line(depth);
    try o.w.writeAll("{");
    var i: usize = 0;
    while (i < list.len) {
        const s = &list[i];
        try o.line(depth + 1);
        if (!s.via.none() and s.via.end <= o.style.src.len) {
            try o.w.writeAll(o.style.src[s.via.start..s.via.end]);
            while (i < list.len and std.meta.eql(list[i].via, s.via)) i += 1;
            continue;
        }
        try stmtAt(o, s, depth + 1);
        i += 1;
    }
    try o.line(depth);
    try o.w.writeAll("};");
}

/// One statement of `f` from its first byte through its `;` (a directive: through the
/// directive; the caller ends the line). Lines after the first: `style.base` and `depth` steps.
pub fn statement(w: *Writer, s: *const ir.Stmt, f: *const ir.Fn, style: Style, depth: usize) Error!void {
    return stmtAt(.{ .w = w, .style = style, .names = f.names }, s, depth);
}

fn stmtAt(o: Out, s: *const ir.Stmt, depth: usize) Error!void {
    switch (s.kind) {
        .expr => |e| {
            try exprAt(o, e, 0, false);
            try o.w.writeAll(";");
        },
        .local => |l| try o.w.print("{t} {s};", .{ l.type, try o.name(l.slot) }),
        .assign => |a| {
            try target(o, a.target);
            try exprAt(o, a.value, 0, false);
            try o.w.writeAll(";");
        },
        .@"if" => |i| {
            try o.w.writeAll("if(");
            try exprAt(o, i.cond, 0, true);
            try o.w.writeAll(")");
            try braced(o, i.then, depth);
            if (i.@"else".len > 0) {
                try o.line(depth);
                try o.w.writeAll("else");
                try braced(o, i.@"else", depth);
            }
        },
        .@"return" => |e| {
            try o.w.writeAll("return(");
            try exprAt(o, e, 0, false);
            try o.w.writeAll(");");
        },
        .fail => |f| try o.w.print("#include {s}", .{f.file}),
        // OGS only (the exporter takes the Classic importer's IR).
        .@"while", .for_in, .@"break", .@"continue" => return error.NotClassic,
    }
}

fn target(o: Out, t: ir.Target) Error!void {
    try o.w.print("{s} = ", .{switch (t) {
        .local => |slot| try o.name(slot),
        .name => |n| n.text,
        .field, .member => return error.NotClassic,
    }});
}

/// An expression where the weakest binding printed bare is `min` (see `level`); `truth`:
/// the place takes the exe's truth of the value (a condition, an operand of `&&`/`||`),
/// where the importer's `exe.truthy` is the bare operand.
pub fn expression(w: *Writer, e: *const ir.Expr, f: *const ir.Fn, min: u8, truth: bool) Error!void {
    return exprAt(.{ .w = w, .style = .{}, .names = f.names }, e, min, truth);
}

/// Binding strength of an IR node printed in Classic, as `level` of the parse tree.
fn irLevel(e: *const ir.Expr, truth: bool) u8 {
    return switch (e.kind) {
        .assign => 0,
        .logic => 1,
        .binary => |b| opLevel(astOp(b.op)),
        .unary => 6,
        .exe => |x| switch (x.op) {
            .neg, .not => 6,
            .truthy => if (truth) irLevel(x.args[0], truth) else 7,
            inline else => |op| opLevel(@field(ast.BinaryOp, @tagName(op))),
        },
        else => 7,
    };
}

fn exprAt(o: Out, e: *const ir.Expr, min: u8, truth: bool) Error!void {
    if (irLevel(e, truth) < min) {
        try o.w.writeAll("(");
        try exprAt(o, e, 0, truth);
        return o.w.writeAll(")");
    }
    switch (e.kind) {
        .lit => |v| switch (v) {
            // The parser reads a minus as an operator: a negative literal has no text.
            .int => |i| if (i < 0) return error.NotClassic else try o.w.print("{d}", .{i}),
            .float => |x| {
                if (!std.math.isFinite(x) or std.math.signbit(x)) return error.NotClassic;
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return error.NotClassic;
                try o.w.writeAll(text);
                if (std.mem.indexOfScalar(u8, text, '.') == null) try o.w.writeAll(".0");
            },
            // No escapes in the language.
            .string => |str| {
                if (std.mem.indexOfAny(u8, str, "\"\r\n") != null) return error.NotClassic;
                try o.w.print("\"{s}\"", .{str});
            },
            else => return error.NotClassic,
        },
        .local => |slot| try o.w.writeAll(try o.name(slot)),
        .name => |n| try o.w.writeAll(n.text),
        .call => |c| {
            // A call OGS linked to something (a component's method, a namespace's
            // function) has no Classic text; an unlinked one is a call by name.
            if (c.named.len > 0 or (c.target != null and c.target.?.* != .unresolved)) return error.NotClassic;
            try o.w.print("{s}(", .{c.text});
            for (c.args, 0..) |a, i| {
                if (i > 0) try o.w.writeAll(", ");
                try exprAt(o, a, 0, false);
            }
            try o.w.writeAll(")");
        },
        .exe => |x| switch (x.op) {
            .truthy => if (truth) try exprAt(o, x.args[0], min, truth) else return error.NotClassic,
            .neg, .not => {
                try o.w.writeAll(if (x.op == .neg) "-" else "!");
                try exprAt(o, x.args[0], 6, false);
            },
            inline else => |op| try infix(o, @field(ast.BinaryOp, @tagName(op)), x.args[0], x.args[1]),
        },
        .unary => |u| {
            try o.w.writeAll(if (u.op == .neg) "-" else "!");
            try exprAt(o, u.operand, 6, false);
        },
        .binary => |b| try infix(o, astOp(b.op), b.lhs, b.rhs),
        .logic => |l| try infix(o, if (l.op == .@"and") .@"and" else .@"or", l.lhs, l.rhs),
        .assign => |a| {
            try target(o, a.target);
            try exprAt(o, a.value, 0, false);
        },
        .field, .host, .self, .member, .index, .list, .map, .ref, .method, .word, .trait_op => return error.NotClassic,
    }
}

fn infix(o: Out, op: ast.BinaryOp, lhs: *const ir.Expr, rhs: *const ir.Expr) Error!void {
    const l = opLevel(op);
    const logic = l == 1;
    try exprAt(o, lhs, l, logic);
    try o.w.print(" {s} ", .{opText(op)});
    try exprAt(o, rhs, l + 1, logic);
}

/// Two trees (parse trees or IR) are the same apart from positions and interned ids.
/// A sigil is OGS only: its string is the Classic literal (`~l"01_port"` writes `"01_port"`).
pub fn same(comptime T: type, a: T, b: T) bool {
    return ir.sameSkipping(T, a, b, &.{"sigil"});
}

test "printed text parses back to the same tree" {
    const parser = @import("../parser.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\#inherit ActiveBitmapAnimation
        \\int state;
        \\function f(string hero, int n)
        \\{
        \\  if(a == 0 && !b) { x = -1.5; }; else if (c) return; else { };
        \\  y = (1 + 2) * 3 - (4 - 5) / -(6 * x);
        \\  z = (a || b) && (c == (d != e));
        \\  w = q = 0.1;
        \\  { float t; };;
        \\#include wp_barrel_explode.ss
        \\  Call(1, "s", n = 2);
        \\  return(3);
        \\};
        \\x = 1;
    ;
    var diag: parser.Diagnostic = .{};
    const tree = try parser.parse(a, src, &diag);
    var out: Writer.Allocating = .init(a);
    try unit(&out.writer, tree);
    const again = try parser.parse(a, out.written(), &diag);
    try std.testing.expect(same(ast.Unit, tree, again));
    try std.testing.expect(!same(ast.Unit, tree, try parser.parse(a, "x = 2;", &diag)));
}
