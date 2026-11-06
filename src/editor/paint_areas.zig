//! The Area and Exit tools of the level edit mode: an outline drawn and finished as a
//! trigger area or a level exit (its target and label chosen), areas' panel.

const std = @import("std");
const screen = @import("paint.zig").screen;
const Paint = @import("paint.zig").Paint;
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const ink = @import("render.zig").ink;
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const areas = @import("areas.zig");
const theme = app_mod.theme;
const Doc = @import("level.zig").Doc;
const scenes_mod = @import("scenes.zig");
const trigger = @import("trigger.zig");

/// The area being drawn: its edges, to the pointer, the first point larger (a click
/// there closes it).
pub fn drawPoly(r: *c.SDL_Renderer, p: *const Paint, d: *const Doc, rect: c.SDL_FRect) void {
    const pts = p.poly.items;
    if (pts.len == 0) return;
    ink(r, lay.canvas.poly);
    var prev = screen(d, rect, .{ @floatFromInt(pts[0][0]), @floatFromInt(pts[0][1]) });
    for (pts, 0..) |pt, k| {
        const s = screen(d, rect, .{ @floatFromInt(pt[0]), @floatFromInt(pt[1]) });
        if (k > 0) _ = c.SDL_RenderLine(r, prev[0], prev[1], s[0], s[1]);
        const h: f32 = if (k == 0) 6 else 3;
        _ = c.SDL_RenderFillRect(r, &.{ .x = s[0] - h, .y = s[1] - h, .w = 2 * h, .h = 2 * h });
        prev = s;
    }
    const to = if (p.poly_closed) screen(d, rect, .{ @floatFromInt(pts[0][0]), @floatFromInt(pts[0][1]) }) else screen(d, rect, p.hover orelse return);
    _ = c.SDL_RenderLine(r, prev[0], prev[1], to[0], to[1]);
}

/// A click of the area tool at `b`: a point, or (on the first point, 3 and more) the
/// area done.
pub fn areaClick(app: *App, p: *Paint, d: *const Doc, b: [2]f32) void {
    if (p.poly_closed) return;
    if (p.poly.items.len >= 3) {
        const f = p.poly.items[0];
        const dx = (@as(f32, @floatFromInt(f[0])) - b[0]) * d.zoom;
        const dy = (@as(f32, @floatFromInt(f[1])) - b[1]) * d.zoom;
        if (dx * dx + dy * dy < 100) return finishArea(app, p);
    }
    p.poly.append(app.gpa, .{ @intFromFloat(@round(b[0])), @intFromFloat(@round(b[1])) }) catch {};
}

/// The drawn polygon as a new trigger, or with the exit tool an exit (3 points at
/// least; the level reloads after, this Paint with it).
pub fn finishArea(app: *App, p: *Paint) void {
    if (p.poly.items.len < 3) return;
    // An exit closed first, its hint and level picked after (the panel's button).
    if (p.tool == .exit and p.exit_to_len == 0) {
        p.poly_closed = true;
        return;
    }
    const pts = app.gpa.dupe([2]i32, p.poly.items) catch return;
    defer app.gpa.free(pts);
    // Corners on the picture: a part outside it can be neither clicked nor walked to.
    if (app.doc) |d| clampTo(pts, d.bg_size);
    p.poly.clearRetainingCapacity();
    p.poly_closed = false;
    if (p.tool != .exit) return areas.addTriggerArea(app, pts);
    var tb: [64]u8 = undefined;
    const to = tb[0..p.exit_to_len];
    @memcpy(to, p.exit_to[0..p.exit_to_len]);
    areas.addExitArea(app, pts, to, p.exit_label);
}

/// `pts` moved inside a `size` picture (0…size−1 on each axis).
fn clampTo(pts: [][2]i32, size: [2]f32) void {
    const max: [2]i32 = .{ @max(0, @as(i32, @intFromFloat(size[0])) - 1), @max(0, @as(i32, @intFromFloat(size[1])) - 1) };
    for (pts) |*pt| inline for (0..2) |k| {
        pt[k] = std.math.clamp(pt[k], 0, max[k]);
    };
}

test clampTo {
    var pts = [_][2]i32{ .{ -5, 10 }, .{ 900, 700 }, .{ 20, 30 } };
    clampTo(&pts, .{ 800, 600 });
    try std.testing.expectEqualSlices([2]i32, &.{ .{ 0, 10 }, .{ 799, 599 }, .{ 20, 30 } }, &pts);
}

/// The game's locations to pick from (the open one left out), `current` marked;
/// the one clicked, if any.
fn levelChoice(app: *App, id: []const u8, current: []const u8) ?[]const u8 {
    var hit: ?[]const u8 = null;
    clay.openScroll(.{ .id = clay.id(id), .layout = .{ .sizing = .{ .width = clay.grow(), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 8 * lay.height.small } } } }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.levels, 0..) |lv, i| {
        if (lv.battle) continue;
        if (app.doc) |d| if (std.ascii.eqlIgnoreCase(d.name, lv.name)) continue;
        const sel = std.ascii.eqlIgnoreCase(lv.name, current);
        const rid = clay.idi(id, @intCast(i + 1));
        if (gui.listRow(app, rid, .{ .selected = sel, .h = lay.height.small, .rounded = false, .bg = theme.field })) hit = lv.name;
        gui.txt(lv.name, .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.close();
    return hit;
}

/// The hint choice: the game's own texts for exits; the one clicked, if any.
fn labelChoice(app: *App, a: Allocator, current: u16) ?u16 {
    var items: [trigger.exit_labels.len]gui.Item = undefined;
    for (trigger.exit_labels, 0..) |id, k| {
        const t = app.catalog.exit_labels[k];
        items[k] = .{ .id = clay.id(std.fmt.allocPrint(a, "lp_lbl{d}", .{k}) catch "l"), .b = .{ .label = if (t.len > 0) t else std.fmt.allocPrint(a, "#{d}", .{id}) catch "?", .style = if (id == current) .primary else .secondary, .size = .small } };
    }
    // Wrapped as the value column allows.
    const k = gui.buttonRow(app, clay.id("lp_lbls"), &items) orelse return null;
    return trigger.exit_labels[k];
}

/// The exit tool's panel: the hint over it and the level it loads.
pub fn exitPanel(app: *App, a: Allocator, p: *Paint) void {
    gui.note(tx.get(tx.lp_exit_hint));
    gui.fieldRow(tx.get(tx.lp_exit_label));
    if (labelChoice(app, a, p.exit_label)) |id| p.exit_label = id;
    clay.close();
    const to = p.exit_to[0..p.exit_to_len];
    gui.fieldRow(tx.get(tx.lp_exit_where));
    gui.txtWrap(if (to.len > 0) to else tx.get(tx.lp_exit_pick), .label, if (to.len > 0) theme.text else theme.warn, font_mod.regular);
    clay.close();
    if (levelChoice(app, "lp_exit_lv", to)) |name| {
        p.exit_to_len = @min(name.len, p.exit_to.len);
        @memcpy(p.exit_to[0..p.exit_to_len], name[0..p.exit_to_len]);
    }
    if (p.poly_closed and p.exit_to_len == 0) gui.warning(tx.get(tx.lp_exit_closed));
    if (p.poly.items.len >= 3 and p.exit_to_len > 0) if (gui.footer(app, "lp_exit_done", &.{tx.get(tx.lp_exit_make)}, 0) != null) {
        p.pending = .finish;
    };
}

/// The picked area: its name (click to type a new one), rename, delete (asked twice).
pub fn areaPanel(app: *App, a: Allocator, p: *Paint) void {
    gui.subhead(tx.alloc(a, tx.lp_area_picked, .{p.area[0..p.area_len]}));
    gui.fieldRow(tx.get(tx.p_name));
    const given = gui.nameField(app, a, clay.id("lp_area_name"), p.area[0..p.area_len], @import("search.zig").keep.areaName, null);
    const button = gui.smallButton(app, clay.id("lp_area_rename"), tx.get(tx.lp_area_rename));
    // Enter or Rename (its click gives the typing): renamed at the next frame.
    if (given) |g| if (g.entered or button) {
        p.name_len = @min(g.text().len, p.name.len);
        @memcpy(p.name[0..p.name_len], g.text()[0..p.name_len]);
        p.pending = .rename;
    };
    clay.close();
    // An exit: where it leads (open it, or pick another level).
    var go: []const u8 = "";
    if (app.doc) |d| if (areas.exitTo(app, d, p.area[0..p.area_len])) |to| {
        go = to;
        gui.fieldRow(tx.get(tx.lp_exit_where));
        gui.txtWrap(to, .label, theme.text, font_mod.regular);
        clay.close();
        if (d.areaControl(p.area[0..p.area_len])) |cp| if (!d.reachable(cp)) {
            gui.fieldNote(tx.get(tx.lp_exit_unreachable), theme.warn);
        };
        if (levelChoice(app, "lp_exit_re", to)) |name| areas.setExitTo(app, d, p.area[0..p.area_len], name);
    };
    // What entering it starts (the blocks of the level's scripts naming it), each opened.
    var scenes: std.ArrayList([]const u8) = .empty;
    if (app.doc) |d| for (areas.levelTexts(app, d, a)) |f| {
        const text = app.store.text(f);
        for (scenes_mod.refs(a, text, p.area[0..p.area_len]) catch &.{}) |call| for (scenes_mod.startedIn(a, text, call.at)) |sc| scenes.append(a, sc) catch {};
    };
    gui.fieldRow(tx.get(tx.lp_scene));
    if (scenes.items.len == 0) gui.txtWrap(tx.get(tx.lp_area_no_scene), .caption, theme.dim, font_mod.regular);
    clay.close();
    if (scenes.items.len > 0) {
        var labels: std.ArrayList([]const u8) = .empty;
        for (scenes.items) |sc| labels.append(a, tx.alloc(a, tx.ln_scene, .{sc})) catch {};
        if (gui.footer(app, "lp_area_sc", labels.items, null)) |k| app.link(true, scenes.items[k], null);
    }
    // The exit's level opened, the area deleted (asked twice).
    const labels = [_][]const u8{ tx.get(tx.lp_area_delete), if (go.len > 0) tx.alloc(a, tx.lp_exit_go, .{go}) else "" };
    if (gui.footer(app, "lp_area_acts", labels[0..if (go.len > 0) 2 else 1], null)) |k| {
        if (k == 0) app.askDelete(.area, 0, p.area[0..p.area_len]) else app.link(false, go, null);
    }
}
