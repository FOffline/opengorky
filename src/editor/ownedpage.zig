//! The engine's settings where they live (rules/adjust_owners.zig): a record of the
//! interface (`PopupColors(…)`, a row of ui.ogs) or of the game block (`blood = Blood(…)`)
//! edited as its fields — each the value in force, the engine's default beside it; a
//! record keeps only the fields that differ from the engine's (none: no record).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const doc = @import("adjustdoc.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const owners = og.rules.adjust_owners;
const adjust = og.rules.adjust;
const og_src = @import("store.zig").og_src;

/// Record `record`'s fields on the open form, under subhead `title` ("" none).
pub fn fields(app: *App, a: Allocator, record: []const u8, title: []const u8) void {
    if (title.len > 0) gui.subhead(title);
    for (owners.table, 0..) |f, i| {
        if (!std.mem.eql(u8, f.record, record)) continue;
        const d = adjust.defaultOf(f.name) orelse continue;
        const cur = valueText(a, current(f.name, d));
        const def = valueText(a, d);
        gui.fieldRow(f.field);
        if (gui.textField(app, std.fmt.allocPrint(a, "own_{s}", .{f.name}) catch "own", cur, gui.cellWidth(2, true), "—")) |t| set(app, a, f, t) catch |err| app.failed(err);
        if (d == .rgba) {
            const c = current(f.name, d).rgba;
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.small), .height = clay.fixed(lay.height.small) } }, .backgroundColor = .{ .r = @floatFromInt(c[0]), .g = @floatFromInt(c[1]), .b = @floatFromInt(c[2]), .a = 255 }, .cornerRadius = clay.radius(lay.radius.sm) });
        }
        if (!std.mem.eql(u8, cur, def)) {
            if (gui.smallButton(app, clay.idi("own_reset", @intCast(i)), tx.get(tx.aip_reset))) set(app, a, f, def) catch |err| app.failed(err);
        }
        gui.txtClip(if (doc.get(f.name)) |m| tx.get(m) else f.name, .caption, theme.dim, font_mod.regular);
        clay.close();
    }
}

fn current(name: []const u8, d: adjust.Value) adjust.Value {
    return switch (d) {
        .int => |x| .{ .int = adjust.getInt(name, x) },
        .float => |x| .{ .float = adjust.getFloat(name, x) },
        .rgba => |x| .{ .rgba = adjust.getRgb(name, x) },
    };
}

/// A value as OG Script writes it: `8`, `1.3`, `[200, 60, 20]`.
fn valueText(a: Allocator, v: adjust.Value) []const u8 {
    return switch (v) {
        .int => |x| std.fmt.allocPrint(a, "{d}", .{x}) catch "",
        .float => |x| blk: {
            const t = std.fmt.allocPrint(a, "{d}", .{x}) catch break :blk "";
            break :blk if (std.mem.indexOfAny(u8, t, ".e") == null) std.fmt.allocPrint(a, "{s}.0", .{t}) catch t else t;
        },
        .rgba => |x| std.fmt.allocPrint(a, "[{d}, {d}, {d}]", .{ x[0], x[1], x[2] }) catch "",
    };
}

/// `text` read as a value of `d`'s kind (`8`, `1.3`, `200 60 20` or `[200, 60, 20]`).
fn parse(text: []const u8, d: adjust.Value) !adjust.Value {
    const t = std.mem.trim(u8, text, " []");
    return switch (d) {
        .int => .{ .int = try std.fmt.parseInt(i32, t, 10) },
        .float => .{ .float = try std.fmt.parseFloat(f32, t) },
        .rgba => blk: {
            var c: [3]u8 = undefined;
            var it = std.mem.tokenizeAny(u8, t, " ,");
            for (&c) |*ch| ch.* = try std.fmt.parseInt(u8, it.next() orelse return error.BadValue, 10);
            break :blk .{ .rgba = c };
        },
    };
}

/// Field `f` made `text`: its record written anew with every field other than the engine's.
fn set(app: *App, a: Allocator, f: owners.Field, text: []const u8) !void {
    const d = adjust.defaultOf(f.name) orelse return error.NoSuchValue;
    const v = try parse(text, d);
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("{s}(", .{f.record});
    var n: usize = 0;
    for (owners.table) |x| {
        if (!std.mem.eql(u8, x.record, f.record)) continue;
        const xd = adjust.defaultOf(x.name) orelse continue;
        const xv = if (std.mem.eql(u8, x.name, f.name)) v else current(x.name, xd);
        const t = valueText(a, xv);
        if (std.mem.eql(u8, t, valueText(a, xd))) continue;
        try w.writer.print("{s}{s} = {s}", .{ if (n > 0) ", " else "", x.field, t });
        n += 1;
    }
    try w.writer.writeByte(')');
    switch (f.owner) {
        .game => {
            const file = try app.store.file(og_src, "game.ogs");
            const mo = @import("model_og.zig");
            if (n == 0) try mo.unset(app, file, &.{f.slot}) else try mo.set(app, file, &.{f.slot}, w.written());
        },
        .ui => try setRow(app, f.record, if (n == 0) "" else w.written()),
    }
    @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_camp_set, .{ f.field, valueText(a, v) });
}

/// ui.ogs's row `record(…);` made `row` ("" taken out; none: added at the end).
fn setRow(app: *App, record: []const u8, row: []const u8) !void {
    const a = app.frame.allocator();
    const file = "ui.ogs";
    const f = app.store.file(og_src, file) catch {
        if (row.len == 0) return;
        _ = try app.store.addNew(&.{.{ .archive = og_src, .entry = file, .text = try std.fmt.allocPrint(app.gpa, "{s};\n", .{row}) }});
        return;
    };
    const t = app.store.text(f);
    const head = try std.fmt.allocPrint(a, "{s}(", .{record});
    var start: ?usize = null;
    var it = std.mem.splitScalar(u8, t, '\n');
    var pos: usize = 0;
    while (it.next()) |line| : (pos += line.len + 1) if (std.mem.startsWith(u8, line, head)) {
        start = pos;
        break;
    };
    const new = if (start) |s0| blk: {
        // Its end: the `);` closing it (a long row spans lines).
        const e = std.mem.indexOfPos(u8, t, s0, ");") orelse return error.BadRow;
        var end = e + 2;
        if (end < t.len and t[end] == '\n') end += 1;
        break :blk try std.mem.concat(app.gpa, u8, &.{ t[0..s0], if (row.len > 0) try std.fmt.allocPrint(a, "{s};\n", .{row}) else "", t[end..] });
    } else if (row.len == 0) return else try std.mem.concat(app.gpa, u8, &.{ t, if (t.len > 0 and t[t.len - 1] != '\n') "\n" else "", try std.fmt.allocPrint(a, "{s};\n", .{row}) });
    try app.store.replace(f, new);
}
