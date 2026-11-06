//! OGS printer: IR back to OGS text that `parser.zig` reads as the
//! same IR (`same`, positions and link results aside). Prints both OGS-parsed IR and the
//! Classic importer's (its quirks as `classic::*` forms), so imported Classic code can be
//! shown and converted as OGS. Four spaces a level; named arguments as `name = value`.

const std = @import("std");
const ir = @import("../ir.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const Value = @import("../value.zig").Value;
const Writer = std.Io.Writer;

/// A node no OGS text gives (a Classic assignment used as a value: none in the games).
pub const Error = Writer.Error || error{Unprintable};

pub fn unit(w: *Writer, u: parser.Unit) Error!void {
    for (u.modules) |m| {
        if (m.path.len == 0) {
            try items(w, m, 0);
            continue;
        }
        try w.print("module {s} {{\n", .{m.path});
        try items(w, m, 1);
        try w.writeAll("}\n");
    }
}

fn items(w: *Writer, m: ir.Module, depth: usize) Error!void {
    for (m.uses) |u| {
        try indent(w, depth);
        try w.print("use {s};\n", .{u});
    }
    for (m.enums) |e| try enumDecl(w, e, depth);
    for (m.structs) |x| try structDecl(w, x, depth);
    for (m.entities) |e| try entity(w, e, depth);
    for (m.traits) |t| try trait(w, t, depth);
    for (m.components) |c| if (!c.own) try component(w, c, depth);
    for (m.fns) |f| try function(w, f, depth);
    for (m.rows) |r| {
        try indent(w, depth);
        try data(w, r, depth, 4 * depth);
        try w.writeAll(";\n");
    }
}

fn indent(w: *Writer, depth: usize) Writer.Error!void {
    try w.splatByteAll(' ', depth * 4);
}

fn typeName(t: ir.Type) []const u8 {
    return if (t == .any) "" else @tagName(t);
}

pub fn component(w: *Writer, c: *const ir.Component, depth: usize) Error!void {
    try indent(w, depth);
    try w.print("component {s}", .{c.name});
    for (c.hosts, 0..) |h, i| try w.print("{s}{s}", .{ if (i == 0) " for " else ", ", h });
    try traitList(w, " : ", c.traits);
    try w.writeAll(" {\n");
    try fields(w, c.fields, depth);
    for (c.methods) |f| try function(w, f, depth + 1);
    try indent(w, depth);
    try w.writeAll("}\n");
}

/// `enum Name {` and a value a line (`hand = 11 "In hand",`), `}`.
pub fn enumDecl(w: *Writer, e: *const ir.Enum, depth: usize) Error!void {
    try indent(w, depth);
    try w.print("enum {s} {{\n", .{e.name});
    for (e.values) |v| {
        try indent(w, depth + 1);
        try w.writeAll(v.name);
        if (v.number) |n| try w.print(" = {d}", .{n});
        if (v.label.len > 0) {
            try w.writeByte(' ');
            try lexer.writeString(w, v.label);
        }
        try w.writeAll(",\n");
    }
    try indent(w, depth);
    try w.writeAll("}\n");
}

/// `struct Name {`, its fields as `Type name [= default] ["Label"];`, `}`.
pub fn structDecl(w: *Writer, s: *const ir.Struct, depth: usize) Error!void {
    try indent(w, depth);
    if (s.host) {
        try w.print("host {s}", .{s.name});
        if (s.parent.len > 0) try w.print(" : {s}", .{s.parent});
        try w.writeAll(" {\n");
    } else try w.print("struct {s} {{\n", .{s.name});
    try fieldsAs(w, s.fields, depth, false);
    try indent(w, depth);
    try w.writeAll("}\n");
}

/// A component's or a block's fields: `param [type] name [= default] ["doc"];`, `var …;`.
fn fields(w: *Writer, list: []const ir.Field, depth: usize) Error!void {
    return fieldsAs(w, list, depth, true);
}

/// `keyword`: with `param`/`var` (a struct's fields have none).
fn fieldsAs(w: *Writer, list: []const ir.Field, depth: usize, keyword: bool) Error!void {
    for (list) |f| {
        try indent(w, depth + 1);
        if (keyword) try w.print("{s} ", .{if (f.kind == .param) "param" else "var"});
        if (f.type_name.len > 0) try w.print("{s} ", .{f.type_name});
        try w.writeAll(f.name);
        if (f.default) |d| {
            try w.writeAll(" = ");
            try expr(w, null, d, 0);
        }
        if (f.doc.len > 0) {
            try w.writeByte(' ');
            try lexer.writeString(w, f.doc);
        }
        try w.writeAll(";\n");
    }
}

/// `: T1, T2` (`trait A: B`, `component C for fighter : B`).
fn traitList(w: *Writer, first: []const u8, list: []const []const u8) Error!void {
    for (list, 0..) |t, i| try w.print("{s}{s}", .{ if (i == 0) first else ", ", t });
}

pub fn trait(w: *Writer, t: *const ir.Trait, depth: usize) Error!void {
    try indent(w, depth);
    try w.print("trait {s}", .{t.name});
    try traitList(w, ": ", t.supers);
    try w.writeAll(" {\n");
    try fields(w, t.params, depth);
    for (t.methods) |m| {
        if (m.body) {
            try function(w, m.f, depth + 1);
            continue;
        }
        try indent(w, depth + 1);
        if (m.native) try w.writeAll("native ");
        try header(w, m.f);
        try w.writeAll(";\n");
    }
    try indent(w, depth);
    try w.writeAll("}\n");
}

/// A data block at `depth` (indented, its `}` and a newline).
pub fn entity(w: *Writer, e: ir.Entity, depth: usize) Error!void {
    try indent(w, depth);
    try w.print("{s} ", .{e.kind});
    try nameOrString(w, e.name);
    if (e.base.len > 0) try w.print(": {s}", .{e.base});
    try w.writeAll(" {\n");
    // Its own code's traits (Component.own).
    if (e.own) |c| if (c.traits.len > 0) {
        try indent(w, depth + 1);
        try w.writeAll("injects ");
        for (c.traits, 0..) |t, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", t });
        try w.writeAll(";\n");
    };
    try fields(w, e.vars, depth);
    for (e.fields) |f| {
        try indent(w, depth + 1);
        try fieldStmtAt(w, f, depth + 1);
        try w.writeAll("\n");
    }
    for (e.attach) |x| {
        try indent(w, depth + 1);
        try attachStmt(w, x);
        try w.writeAll("\n");
    }
    for (e.children) |c| try entity(w, c, depth + 1);
    // Its own code (Component.own).
    if (e.own) |c| for (c.methods) |f| try function(w, f, depth + 1);
    // A scene's or dialog's commands one a line (a dialog's line each its own).
    for (e.rows) |r| {
        try indent(w, depth + 1);
        try expr(w, null, r, 0);
        try w.writeAll(";\n");
    }
    try indent(w, depth);
    try w.writeAll("}\n");
}

/// A block's field statement `name = value;` (no indent, no newline).
/// A block's field statement at indent `depth` (`data`: a value too long for its line on several).
pub fn fieldStmtAt(w: *Writer, f: ir.Named, depth: usize) Error!void {
    // `same_as` is written `import x;` / `import "level/object";` (the parser reads it back so).
    if (std.mem.eql(u8, f.name, "same_as")) {
        if (f.value.kind == .word) return w.print("import {s};", .{f.value.kind.word});
        if (f.value.kind == .lit and f.value.kind.lit == .string) {
            try w.writeAll("import ");
            try @import("lexer.zig").writeString(w, f.value.kind.lit.string);
            return w.writeAll(";");
        }
    }
    try w.print("{s} = ", .{f.name});
    try data(w, f.value, depth, 4 * depth + f.name.len + 3);
    try w.writeAll(";");
}

/// A top-level rules row `x;` and its newline, too long a one on several lines (`data`).
pub fn row(w: *Writer, x: *const ir.Expr) Error!void {
    try data(w, x, 0, 0);
    try w.writeAll(";\n");
}

/// Data value `x` at column `col` of a line indented `depth`: on that line when it fits
/// `max_line`; else a record (`Campaign(level = …, …)`, named fields only) one field a
/// line, a list one record a line or its numbers and names as many as a line holds, each
/// item so in turn.
fn data(w: *Writer, x: *const ir.Expr, depth: usize, col: usize) Error!void {
    var probe: std.Io.Writer.Discarding = .init(&.{});
    try expr(&probe.writer, null, x, 0);
    if (col + probe.fullCount() <= max_line) return expr(w, null, x, 0);
    switch (x.kind) {
        .call => |c| if (c.args.len == 0 and c.named.len > 0 and !c.super) {
            try w.print("{s}(\n", .{c.text});
            for (c.named) |n| {
                try indent(w, depth + 1);
                try w.print("{s} = ", .{n.name});
                try data(w, n.value, depth + 1, 4 * (depth + 1) + n.name.len + 3);
                try w.writeAll(",\n");
            }
            try indent(w, depth);
            return w.writeAll(")");
        } else if (std.mem.eql(u8, c.text, "list") and c.named.len == 0 and c.args.len >= 2 and !c.super) {
            // A list as the rules rows write one (`list(beam(…), beam(…))`).
            return listItems(w, c.args, "list(", ")", depth);
        },
        .list => |l| if (l.len >= 2) return listItems(w, l, "[", "]", depth),
        else => {},
    }
    return expr(w, null, x, 0);
}

/// List items `l` between `open` and `close`, a line each (records) or as many as a line
/// holds (numbers, names), each item so in turn (`data`).
fn listItems(w: *Writer, l: []const *const ir.Expr, open: []const u8, close: []const u8, depth: usize) Error!void {
    try w.print("{s}\n", .{open});
    const records = for (l) |y| {
        if (y.kind != .call or std.mem.eql(u8, y.kind.call.text, "list")) break false;
    } else true;
    var at: usize = 0;
    for (l) |y| {
        var one: std.Io.Writer.Discarding = .init(&.{});
        try expr(&one.writer, null, y, 0);
        const n = one.fullCount() + 1;
        if (at > 0 and (records or at + 1 + n > max_line)) {
            try w.writeAll("\n");
            at = 0;
        }
        if (at == 0) {
            try indent(w, depth + 1);
            at = 4 * (depth + 1);
        } else {
            try w.writeAll(" ");
            at += 1;
        }
        if (records) try data(w, y, depth + 1, at) else try expr(w, null, y, 0);
        try w.writeAll(",");
        at += n;
    }
    try w.writeAll("\n");
    try indent(w, depth);
    try w.writeAll(close);
}

/// The width past which a data value breaks into lines.
const max_line = 100;

/// A block's `attach C(p = v);` (no indent, no newline).
pub fn attachStmt(w: *Writer, x: ir.Attach) Error!void {
    try w.print("attach {s}", .{x.component});
    try args(w, null, &.{}, x.params);
    try w.writeAll(";");
}

/// A name as a word when it is an identifier (`grandma`), else as a string
/// (`"01__port_citadel"`).
fn nameOrString(w: *Writer, n: []const u8) Writer.Error!void {
    if (isName(n)) try w.writeAll(n) else try lexer.writeString(w, n);
}

fn isName(n: []const u8) bool {
    return n.len > 0 and !std.ascii.isDigit(n[0]) and !parser.isKeyword(n) and for (n) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') break false;
    } else true;
}

pub fn function(w: *Writer, f: *const ir.Fn, depth: usize) Error!void {
    try indent(w, depth);
    try header(w, f);
    try w.writeByte(' ');
    try block(w, f, f.body, depth);
    try w.writeByte('\n');
}

/// `fn name(a: T, b = 1)`.
fn header(w: *Writer, f: *const ir.Fn) Error!void {
    try w.print("fn {s}(", .{f.name});
    for (f.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(slotName(f, p.slot));
        if (p.type_name.len > 0) try w.print(": {s}", .{p.type_name}) else if (p.type != .any) try w.print(": {s}", .{@tagName(p.type)});
        if (p.default) |d| {
            try w.writeAll(" = ");
            try expr(w, f, d, 0);
        }
    }
    try w.writeByte(')');
}

fn slotName(f: *const ir.Fn, slot: u16) []const u8 {
    return if (slot < f.names.len) f.names[slot] else "_";
}

fn block(w: *Writer, f: *const ir.Fn, body: []const ir.Stmt, depth: usize) Error!void {
    try w.writeAll("{\n");
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        // `var T x;` and `x = e;` right after it: `var T x = e;`.
        const init = if (body[i].kind == .local and i + 1 < body.len) switch (body[i + 1].kind) {
            .assign => |a| if (a.op == .set and a.target == .local and a.target.local == body[i].kind.local.slot) a.value else null,
            else => null,
        } else null;
        try stmt(w, f, &body[i], depth + 1, init);
        if (init != null) i += 1;
    }
    try indent(w, depth);
    try w.writeByte('}');
}

fn stmt(w: *Writer, f: *const ir.Fn, s: *const ir.Stmt, depth: usize, init: ?*const ir.Expr) Error!void {
    try indent(w, depth);
    switch (s.kind) {
        .expr => |e| {
            try expr(w, f, e, 0);
            try w.writeByte(';');
        },
        .local => |l| {
            try w.writeAll("var ");
            if (l.type != .any) try w.print("{s} ", .{@tagName(l.type)});
            try w.writeAll(slotName(f, l.slot));
            if (init) |e| {
                try w.writeAll(" = ");
                try expr(w, f, e, 0);
            }
            try w.writeByte(';');
        },
        .assign => |a| {
            try target(w, f, a.target);
            try w.writeAll(switch (a.op) {
                .set => " = ",
                .add => " += ",
                .sub => " -= ",
            });
            try expr(w, f, a.value, 0);
            try w.writeByte(';');
        },
        .@"if" => |x| {
            var cur = x;
            while (true) {
                try w.writeAll("if (");
                try expr(w, f, cur.cond, 0);
                try w.writeAll(") ");
                try block(w, f, cur.then, depth);
                if (cur.@"else".len == 0) break;
                try w.writeAll(" else ");
                // `else if`: an else that is one `if`.
                if (cur.@"else".len == 1 and cur.@"else"[0].kind == .@"if") {
                    cur = cur.@"else"[0].kind.@"if";
                    continue;
                }
                try block(w, f, cur.@"else", depth);
                break;
            }
        },
        .@"return" => |e| {
            if (e.kind == .lit and e.kind.lit == .nil) return w.writeAll("return;\n");
            try w.writeAll("return ");
            try expr(w, f, e, 0);
            try w.writeByte(';');
        },
        .@"while" => |x| {
            try w.writeAll("while (");
            try expr(w, f, x.cond, 0);
            try w.writeAll(") ");
            try block(w, f, x.body, depth);
        },
        .for_in => |x| {
            try w.print("for {s} in ", .{slotName(f, x.slot)});
            try expr(w, f, x.iter, 0);
            if (x.to) |t| {
                try w.writeAll("..");
                try expr(w, f, t, 0);
            }
            try w.writeByte(' ');
            try block(w, f, x.body, depth);
        },
        .@"break" => try w.writeAll("break;"),
        .@"continue" => try w.writeAll("continue;"),
        .fail => |x| {
            try w.print("classic::fail(\"{t}\", ", .{x.err});
            try lexer.writeString(w, x.file);
            try w.print(", {d}, ", .{x.line});
            try lexer.writeString(w, x.message);
            try w.writeAll(");");
        },
    }
    try w.writeByte('\n');
}

fn target(w: *Writer, f: *const ir.Fn, t: ir.Target) Error!void {
    switch (t) {
        .local => |s| try w.writeAll(slotName(f, s)),
        .name => |n| try name(w, n),
        .field => |x| try w.writeAll(x.text),
        .member => |m| {
            try expr(w, f, m.obj, 8);
            try w.print(".{s}", .{m.text});
        },
    }
}

fn name(w: *Writer, n: ir.Name) Error!void {
    try w.writeAll(if (n.slot != null) "classic::maybe(" else "classic::name(");
    try lexer.writeString(w, n.text);
    try w.writeByte(')');
}

fn args(w: *Writer, f: ?*const ir.Fn, pos: []const *const ir.Expr, named: []const ir.Named) Error!void {
    try w.writeByte('(');
    for (pos, 0..) |a, i| {
        if (i > 0) try w.writeAll(", ");
        try expr(w, f, a, 0);
    }
    for (named, 0..) |n, i| {
        if (i > 0 or pos.len > 0) try w.writeAll(", ");
        try w.print("{s} = ", .{n.name});
        try expr(w, f, n.value, 0);
    }
    try w.writeByte(')');
}

fn binText(op: ir.BinaryOp) struct { []const u8, u8 } {
    return switch (op) {
        .eq => .{ "==", 3 },
        .ne => .{ "!=", 3 },
        .lt => .{ "<", 4 },
        .le => .{ "<=", 4 },
        .gt => .{ ">", 4 },
        .ge => .{ ">=", 4 },
        .add => .{ "+", 5 },
        .sub => .{ "-", 5 },
        .mul => .{ "*", 6 },
        .div => .{ "/", 6 },
        .mod => .{ "%", 6 },
    };
}

/// `level`: the binding of the context (0 none, 1 or, 2 and, 3 ==, 4 <, 5 +, 6 *, 7
/// unary, 8 postfix); a looser node gets parentheses.
/// An expression outside a function (a param's default) as OGS text.
pub fn expression(w: *Writer, e: *const ir.Expr) Error!void {
    return expr(w, null, e, 0);
}

fn expr(w: *Writer, f: ?*const ir.Fn, e: *const ir.Expr, level: u8) Error!void {
    const own: u8 = switch (e.kind) {
        .logic => |l| if (l.op == .@"or") 1 else 2,
        .binary => |b| binText(b.op)[1],
        .trait_op => |t| if (t.op == .is) 4 else 9,
        .unary => 7,
        else => 9,
    };
    if (own < level) try w.writeByte('(');
    switch (e.kind) {
        .lit => |v| {
            if (e.sigil != .none) try w.print("~{c}", .{e.sigil.letter()});
            try literal(w, v);
        },
        .local => |s| try w.writeAll(slotName(f orelse return error.Unprintable, s)),
        .name => |n| try name(w, n),
        .call => |c| {
            if (c.super) try w.writeAll("super.");
            try w.writeAll(c.text);
            try args(w, f, c.args, c.named);
        },
        .exe => |x| {
            try w.print("classic::{t}", .{x.op});
            try args(w, f, x.args, &.{});
        },
        .unary => |u| {
            try w.writeAll(if (u.op == .neg) "-" else "!");
            try expr(w, f, u.operand, 7);
        },
        .binary => |b| {
            const t = binText(b.op);
            // Left-associative: an equal level needs parentheses on the right only.
            try expr(w, f, b.lhs, t[1]);
            try w.print(" {s} ", .{t[0]});
            try expr(w, f, b.rhs, t[1] + 1);
        },
        .logic => |l| {
            try expr(w, f, l.lhs, own);
            try w.writeAll(if (l.op == .@"or") " or " else " and ");
            try expr(w, f, l.rhs, own + 1);
        },
        .assign => return error.Unprintable,
        .field => |x| try w.writeAll(x.text),
        .host => try w.writeAll("host"),
        .self => try w.writeAll("self"),
        .member => |m| {
            try expr(w, f, m.obj, 8);
            try w.print(".{s}", .{m.text});
        },
        .index => |x| {
            try expr(w, f, x.obj, 8);
            try w.writeByte('[');
            try expr(w, f, x.key, 0);
            try w.writeByte(']');
        },
        .list => |l| {
            try w.writeByte('[');
            for (l, 0..) |x, i| {
                if (i > 0) try w.writeAll(", ");
                try expr(w, f, x, 0);
            }
            try w.writeByte(']');
        },
        .map => |m| {
            try w.writeByte('{');
            for (m.keys, m.values, 0..) |k, v, i| {
                if (i > 0) try w.writeAll(", ");
                try expr(w, f, k, 0);
                try w.writeAll(": ");
                try expr(w, f, v, 0);
            }
            try w.writeByte('}');
        },
        .ref => |n| {
            try w.writeByte('@');
            // `@hero::selected`: a path of names as the parser reads it.
            var it = std.mem.splitSequence(u8, n, "::");
            const path = std.mem.indexOf(u8, n, "::") != null and while (it.next()) |x| {
                if (!isName(x)) break false;
            } else true;
            if (path) try w.writeAll(n) else try nameOrString(w, n);
        },
        .method => |m| {
            try expr(w, f, m.obj, 8);
            try w.print(".{s}", .{m.text});
            try args(w, f, m.args, m.named);
        },
        .word => |x| try w.writeAll(x),
        .trait_op => |t| if (t.op == .is) {
            try expr(w, f, t.obj, 5);
            try w.print(" is {s}", .{t.name});
        } else {
            try expr(w, f, t.obj, 8);
            try w.print(".{t}({s})", .{ t.op, t.name });
        },
    }
    if (own < level) try w.writeByte(')');
}

fn literal(w: *Writer, v: Value) Error!void {
    switch (v) {
        .int => |i| try w.print("{d}", .{i}),
        .float => |x| {
            if (!std.math.isFinite(x)) return error.Unprintable;
            var buf: [64]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return error.Unprintable;
            try w.writeAll(t);
            // A float stays a float when read back.
            if (std.mem.indexOfAny(u8, t, ".e") == null) try w.writeAll(".0");
        },
        .string => |s| try lexer.writeString(w, s),
        .nil => try w.writeAll("nil"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .ref, .list, .map => return error.Unprintable,
    }
}

/// Two IR trees are the same apart from positions, interned ids and link results.
pub fn same(comptime T: type, a: T, b: T) bool {
    return ir.sameSkipping(T, a, b, &.{ "line", "id", "file", "target", "component", "ogs", "resolved" });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn roundTrip(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var diag: parser.Diagnostic = .{};
    const u = parser.parse(a, src, "t.ogs", &diag) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    var out: Writer.Allocating = .init(a);
    try unit(&out.writer, u);
    const again = parser.parse(a, out.written(), "t.ogs", &diag) catch |err| {
        std.debug.print("printed:\n{s}\nline {d}: {s}\n", .{ out.written(), diag.line, diag.message });
        return err;
    };
    try testing.expect(same(parser.Unit, u, again));
    var out2: Writer.Allocating = .init(a);
    try unit(&out2.writer, again);
    try testing.expectEqualStrings(out.written(), out2.written());
    return out.written();
}

test "OGS round trip: modules, components, data, statements" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const printed = try roundTrip(a,
        \\// Rules rows are calls at the top level.
        \\Resist(fighter = 125, resist = "fire gas", note = "a\\b");
        \\use abilities;
        \\module abilities {
        \\    fn half(x, by: int = 2) { return x / by; }
        \\    module deep { fn f() { return [1, 2.5, "s", nil, true][0] + {"k": 1}["k"] % 3; } }
        \\}
        \\component Reflect for fighter, item {
        \\    param int pct = 30 "Percent to return";
        \\    param bool melee_only = false;
        \\    var left;
        \\    fn OnHit(attacker, weapon, amount) {
        \\        if (attacker != nil and attacker != host and (not melee_only or weapon.melee)) {
        \\            fighter::Damage(attacker, amount * pct / 100, from: host, kind: "reflect");
        \\        } else if (left > 0) left -= 1; else { left = -(1 - 2) * 3; }
        \\        var int n = 0;
        \\        while (n < 3) { n += 1; if (n == 2) continue; break; }
        \\        for i in 0..n { self.left = i; }
        \\        for x in [1, 2] host.hp = x;
        \\        return abilities::half(amount, by: 1) + @grandma.hp;
        \\    }
        \\}
        \\fighter grandma {
        \\    classic_id = 107; immunity = Resist(resist = [gas]); ai = AiProfile("grandma");
        \\    attach FirstInMode(mode = 2);
        \\    attach abilities::Rage(at = -1);
        \\}
    );
    try testing.expect(std.mem.indexOf(u8, printed, "module abilities::deep {") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "} else if (left > 0) {") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "var int n = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "(not melee_only or weapon.melee)") == null);
    try testing.expect(std.mem.indexOf(u8, printed, "(!melee_only or weapon.melee)") != null);
}

test "OGS round trip: the data language (string names, archetypes, nested blocks, commands, sigils)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const printed = try roundTrip(arena.allocator(), data_example);
    for ([_][]const u8{ "battle \"01__port_citadel\" {", "    fighter grandma_child1: characters::grandma {", "        weapon gun: weapons::pistol {", "place = hand;", "CALL(@\"01pr_garcia1\", \"Arrived\");", "level::Load(~l\"01__port_citadel\")", "voice = ~s\"01__port_citadel_hq2\"" }) |x| {
        if (std.mem.indexOf(u8, printed, x) == null) std.debug.print("missing {s} in\n{s}\n", .{ x, printed });
        try testing.expect(std.mem.indexOf(u8, printed, x) != null);
    }
}

test "OGS: the brief's examples parse and print back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try roundTrip(arena.allocator(), examples);
}

/// The scripted-ability examples (Invulnerable and the rest), as the docs give them.
pub const examples =
    \\component Invulnerable for fighter {
    \\    param int turns = 2 "Invulnerable turns";
    \\    var int left;
    \\    fn OnSpawn() { left = turns; }
    \\    fn OnTurnStart(side, turn) { if (side == host.side and left > 0) left -= 1; }
    \\    fn OnHit(attacker, weapon, amount) { if (left > 0) return 0; return amount; }
    \\}
    \\
    \\component Rage for fighter {
    \\    param int below_pct = 50; param float factor = 2.0;
    \\    fn OnStrike(target, weapon, amount) {
    \\        if (host.hp * 100 < host.max_hp * below_pct) return amount * factor;   // → int via _ftol
    \\        return amount;
    \\    }
    \\}
    \\
    \\// Grandma: the children report their deaths, grandma takes revenge.
    \\component Avenger for fighter {
    \\    param fighter avenger "Who avenges me";
    \\    param string counter = "grandma_kids";
    \\    fn OnDeath(killer) {
    \\        if (avenger != nil and avenger.alive and killer != nil) fighter::SetTarget(avenger, killer);
    \\        battle::AddVar(counter, 1);
    \\    }
    \\}
    \\component GrandmaRage for fighter {
    \\    param string kids_counter = "grandma_kids"; param int rage_at = 2;
    \\    fn OnVar(name, value) {
    \\        if (name == kids_counter and value >= rage_at) fighter::AddState(host, "rage", turns: 99);
    \\    }
    \\}
;

/// The language's part (`FighterDamage` and `FighterPopup` record their call).
pub const traits_example =
    \\module abilities {
    \\    trait Shielded: foundation::Fighter {
    \\        fn capacity();
    \\        fn spend(amount);
    \\        fn absorb(amount) {
    \\            var taken = amount;
    \\            if (taken > capacity()) taken = capacity();
    \\            spend(taken);
    \\            return amount - taken;
    \\        }
    \\        fn OnHit(attacker, weapon, amount) { return absorb(amount); }
    \\    }
    \\    trait Reflective: Shielded {
    \\        fn reflect_pct();
    \\        fn OnHit(attacker, weapon, amount) {
    \\            var rest = super.OnHit(attacker, weapon, amount);
    \\            if (attacker != nil and attacker != host)
    \\                fighter::Damage(attacker, (amount - rest) * reflect_pct() / 100, kind: "reflect", from: host);
    \\            return rest;
    \\        }
    \\    }
    \\    trait Armored: foundation::Fighter {
    \\        fn absorb(amount) { if (amount > 2) return amount - 2; return 0; }
    \\    }
    \\    component EnergyShield for fighter : Shielded {
    \\        param int charge = 20 "Shield charge";
    \\        fn capacity() { return charge; }
    \\        fn spend(amount) { charge -= amount; }
    \\    }
    \\    component MirrorShield : Reflective {
    \\        param int charge = 10; param int pct = 50;
    \\        fn capacity() { return charge; }
    \\        fn spend(amount) { charge -= amount; }
    \\        fn reflect_pct() { return pct; }
    \\    }
    \\    component Bulwark for fighter : Shielded, Armored {
    \\        var int charge = 15;
    \\        fn capacity() { return charge; }
    \\        fn spend(amount) { charge -= amount; }
    \\        fn absorb(amount) { return Armored::absorb(self, Shielded::absorb(self, amount)); }
    \\    }
    \\    component Medic for Hero {
    \\        param int heal = 5;
    \\        fn OnTurnStart(side, turn) { if (side == host.side) host.hp += heal; }
    \\        fn OnLevelUp(level) { heal += 1; }
    \\    }
    \\    component Bodyguard for fighter {
    \\        param Shielded ward;
    \\        fn OnTurnStart(side, turn) {
    \\            if (ward == nil) return;
    \\            for s in ward.all(Shielded) if (s.capacity() == 0) fighter::Popup(ward, "empty");
    \\            if (ward is foundation::Hero and ward.as(foundation::Hero).party_slot() == 0) fighter::Popup(host, "leader");
    \\        }
    \\        fn guard(x: Shielded) { return x.get(Shielded).capacity() + x.as(Shielded).capacity(); }
    \\        fn wrong() { return Shielded::absorb(host, 1); }
    \\    }
    \\}
;

/// The data language's example program.
pub const data_example =
    \\module weapons { weapon pistol { place = hand; max_damage = 10; } }
    \\module characters {
    \\    fighter grandma { hp = 200; accuracy = 90; blast_weapon = weapons::pistol; attach Calm(by = -1); }
    \\}
    \\component Calm for fighter { param int by = 0; }
    \\battle "01__port_citadel" {
    \\    grid_columns = 10;
    \\    fighter grandma_child1: characters::grandma {
    \\        hp = 50;
    \\        weapon gun: weapons::pistol { place = hand; }
    \\    }
    \\}
    \\scene "port-arriv_at_port" {
    \\    points = [Point(name = "suliv_p1", x = 512, y = 388, angle = 1.57)];
    \\    WALKTO(@Sullivan, "suliv_p1");
    \\    CALL(@"01pr_garcia1", "Arrived");
    \\}
    \\dialog "01__port_citadel" { Line(text = "Over.", voice = ~s"01__port_citadel_hq2"); }
    \\component Go { fn run() { return level::Load(~l"01__port_citadel"); } }
;

test "OGS round trip: traits, super, T::f, is/as/get/all, typed parameters, native" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const printed = try roundTrip(a, traits_example);
    for ([_][]const u8{ "    trait Reflective: Shielded {", "        fn reflect_pct();", "    component Bulwark for fighter : Shielded, Armored {", "var rest = super.OnHit(attacker, weapon, amount);", "Armored::absorb(self, Shielded::absorb(self, amount))", "for s in ward.all(Shielded)", "if (ward is foundation::Hero and ward.as(foundation::Hero).party_slot() == 0)", "fn guard(x: Shielded)", "param Shielded ward;" }) |x| {
        if (std.mem.indexOf(u8, printed, x) == null) std.debug.print("missing {s} in\n{s}\n", .{ x, printed });
        try testing.expect(std.mem.indexOf(u8, printed, x) != null);
    }
    var diag: parser.Diagnostic = .{};
    var out: Writer.Allocating = .init(a);
    try unit(&out.writer, try parser.parse(a, "trait Hero: Fighter { native fn inventory(); fn CanSelect(); }", "engine.ogs", &diag));
    try testing.expectEqualStrings("trait Hero: Fighter {\n    native fn inventory();\n    fn CanSelect();\n}\n", out.written());
}

test "OGS parse errors: unknown names outside components, positional after named, keywords" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: parser.Diagnostic = .{};
    try testing.expectError(error.ParseError, parser.parse(a, "fn f() { return x; }", "t", &diag));
    try testing.expectEqualStrings("unknown name x", diag.message);
    try testing.expectError(error.ParseError, parser.parse(a, "fn f() { g(a: 1, 2); }", "t", &diag));
    try testing.expectError(error.ParseError, parser.parse(a, "fn f() { var if = 1; }", "t", &diag));
    try testing.expectError(error.ParseError, parser.parse(a, "component C { var a; var A; }", "t", &diag));
    try testing.expectError(error.ParseError, parser.parse(a, "fn f() { host.hp = 1; }", "t", &diag));
    // Case-sensitive: `X` is not the local `x`.
    try testing.expectError(error.ParseError, parser.parse(a, "fn f(x) { return X; }", "t", &diag));
}

test "print: a block's fn is its own component, of its name and kind, printed back in it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "module characters {\n    hero x {\n        hp = 1;\n        fn OnCreate() {\n            hp = 2;\n        }\n    }\n}\n";
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, src, "x.ogs", &diag);
    const m = for (u.modules) |x| {
        if (std.mem.eql(u8, x.path, "characters")) break x;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), m.components.len);
    const c = m.components[0];
    try std.testing.expect(c.own and m.entities[0].own == c);
    try std.testing.expectEqualStrings("x", c.name);
    try std.testing.expectEqualStrings("characters", c.module);
    try std.testing.expectEqualStrings("fighter", c.hosts[0]);
    var w: std.Io.Writer.Allocating = .init(a);
    try unit(&w.writer, u);
    try std.testing.expectEqualStrings(src, w.written());
}

test "print: a block's `injects` are its own component's traits, `import` its same_as, printed back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "module weapons {\n    weapon pistol {\n        injects items::ItemClass;\n        import weapons::c_kozov;\n        max_damage = 15;\n    }\n}\n";
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, src, "p.ogs", &diag);
    const e = for (u.modules) |m| {
        if (m.entities.len > 0) break m.entities[0];
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("items::ItemClass", e.own.?.traits[0]);
    try std.testing.expectEqual(@as(usize, 0), e.own.?.methods.len);
    var w: std.Io.Writer.Allocating = .init(a);
    try unit(&w.writer, u);
    try std.testing.expectEqualStrings(src, w.written());
}
