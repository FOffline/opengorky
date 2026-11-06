//! A weapon class's damage zone edited on its page (OpenGorky projects: the exe has the
//! patterns in its code): the Pattern row's rays as tiles around the shooter, a click
//! picking one; the picked tile's membership, kind, hit set and percent beside them; the hit sets around the
//! target, each edit written by key `class` (rules_rows.put, one undo step). Classic:
//! the exe's zone read-only (entry_weapons.reachMap) and the editor locked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const classLabel = @import("item_page.zig").classLabel;
const ew = @import("entry_weapons.zig");
const zone = @import("zone.zig");
const rr = @import("rules_rows.zig");
const Pattern = og.rules.Pattern;

/// The tile picked on the rays' grid (of class `picked_class`) and the hit set shown.
var picked: ?[2]i8 = null;
var picked_class: i32 = 0;
var shown_set: usize = 0;

/// shortcut: the grids show at most this far from the shooter (Clay's element budget);
/// tiles past it stay in the row, edited as text. Upgrade with a scrolled, culled grid.
const view = 31;

/// The zone of weapon class `class_f` (the page's centre): editable in an OpenGorky
/// project, else read-only.
pub fn page(app: *App, a: Allocator, class_f: ?f32) void {
    if (!app.ogLayout()) return ew.reachMap(app, a, class_f, 0);
    const class: i32 = @intFromFloat(class_f orelse 0);
    const p = current(class);
    gui.form(clay.id("zone"), lay.width.label_sm, lay.block.pad_x);
    _ = gui.block(app, null, tx.alloc(a, tx.reach_title, .{classLabel(a, class_f)}), .{});
    // The edit is written after the frame's last read of the rules in force.
    var next: ?Pattern = null;
    switch (og.core.modules.weaponKind(class)) {
        .satellite => gui.txtWrap(tx.get(tx.reach_satellite), .caption, theme.warn, font_mod.regular),
        .time_bomb => gui.txtWrap(tx.get(tx.reach_bomb), .caption, theme.warn, font_mod.regular),
        else => {},
    }
    gui.txtWrap(tx.get(tx.zn_hint), .caption, theme.dim, font_mod.regular);
    if (gui.check(app, clay.id("zone_wide"), p.wide, tx.get(tx.zn_wide))) {
        var q = p;
        q.wide = !p.wide;
        next = q;
    }
    gui.txtWrap(tx.get(tx.zn_axes), .caption, theme.text, font_mod.regular);
    // The rays' grid; beside it (room left for a dialog's width) or under it the picked
    // tile's values and the hit sets.
    const room = if (clay.box(clay.id("zone"))) |z| if (clay.box(clay.id("zone_rays"))) |r| z.width - r.width else 0 else 0;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = lay.space.xl, .layoutDirection = if (room > lay.width.dialog) ui.CLAY_LEFT_TO_RIGHT else ui.CLAY_TOP_TO_BOTTOM } });
    if (rayGrid(app, a, p)) |t| select(p, t);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.block.row_gap } });
    if (tileControls(app, a, p)) |q| next = q;
    gui.subhead(tx.get(tx.zn_set));
    gui.txtWrap(tx.get(tx.zn_sets), .caption, theme.dim, font_mod.regular);
    var labels: [4][]const u8 = undefined;
    for (&labels, p.effects.sets, 0..) |*l, s, k| l.* = std.fmt.allocPrint(a, "{d} · {d}", .{ k + 1, s.len }) catch "?";
    if (gui.segmented(app, "zone_sets", &labels, shown_set)) |k| shown_set = k;
    if (hitGrid(app, p.effects.sets[shown_set])) |d| next = zone.toggleHit(a, p, shown_set, d) catch null;
    ew.legend();
    clay.close();
    clay.close();
    gui.blockEnd();
    if (next) |q| apply(app, q);
}

/// The row in force for `class` (none: an empty one).
fn current(class: i32) Pattern {
    return if (og.rules.pattern(class)) |w| w.* else .{ .name = og.rules.weaponClassName(class) orelse "", .classic_id = class };
}

/// A click on tile `t` of `p`'s grid: only picks it (in the zone or not).
fn select(p: Pattern, t: [2]i8) void {
    picked_class = p.classic_id;
    picked = t;
}

/// `p` written as its class's row, unless past the limits (zone.check).
fn apply(app: *App, p: Pattern) void {
    zone.check(p) catch |err| return switch (err) {
        error.TooManyRays => app.setStatus(tx.st_zn_rays, .{ zone.max_targets, zone.max_entries }),
        error.TooManyHits => app.setStatus(tx.st_zn_hits, .{zone.max_hits}),
        error.TooHighPct => app.setStatus(tx.st_zn_pct, .{zone.max_pct}),
    };
    rr.put(app, Pattern, p) catch |err| return app.failed(err);
    app.setStatus(tx.st_rule_set, .{ "Pattern", classLabel(app.frame.allocator(), @floatFromInt(p.classic_id)) });
}

/// The rays' tiles around the shooter, two tiles past the farthest; the one clicked.
fn rayGrid(app: *App, a: Allocator, p: Pattern) ?[2]i8 {
    var z = zone.build(a, &p) catch return null;
    defer z.cells.deinit(a);
    const lo: [2]i32 = .{ @max(-view, @min(-4, z.lo[0] - 2)), @max(-view, @min(-4, z.lo[1] - 2)) };
    const hi: [2]i32 = .{ @min(view, @max(z.size + 3, z.hi[0] + 2)), @min(view, @max(z.size + 3, z.hi[1] + 2)) };
    var sets: usize = 0;
    for (z.used) |u| sets += @intFromBool(u);
    const pick: ?[2]i8 = if (picked_class == p.classic_id) picked else null;
    var hit: ?[2]i8 = null;
    clay.open(.{ .id = clay.id("zone_rays"), .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.border.line } });
    var y = lo[1];
    while (y <= hi[1]) : (y += 1) {
        clay.open(.{ .layout = .{ .childGap = lay.border.line } });
        var x = lo[0];
        while (x <= hi[0]) : (x += 1) {
            const t: [2]i8 = .{ @intCast(x), @intCast(y) };
            if (x >= 0 and y >= 0 and x < z.size and y < z.size) {
                _ = cell(app, null, ew.shooter_col, false, false, "", "");
                continue;
            }
            const sel = if (pick) |k| k[0] == t[0] and k[1] == t[1] else false;
            const v = z.cells.get(.{ x, y }) orelse {
                if (cell(app, cellId("zone_t", t), theme.viewport, false, sel, "", "")) hit = t;
                continue;
            };
            const shade = 90 + @as(f32, @floatFromInt(v.pct)) * 1.2;
            const bg: clay.Color = if (v.side) .{ .r = 40, .g = shade * 0.6, .b = 60, .a = 255 } else .{ .r = 40, .g = @min(255, shade), .b = 70, .a = 255 };
            if (cell(app, cellId("zone_t", t), bg, !v.chain and !v.side, sel, std.fmt.allocPrint(a, "{d}", .{v.pct}) catch "", if (sets > 1) std.fmt.allocPrint(a, "{d}", .{v.effect + 1}) catch "" else "")) hit = t;
        }
        clay.close();
    }
    clay.close();
    return hit;
}

/// The picked tile's membership ("in the zone": zone.toggleTile), then, when in, its
/// kind, wide side, hit set and percent; the row they make.
fn tileControls(app: *App, a: Allocator, p: Pattern) ?Pattern {
    const t = (if (picked_class == p.classic_id) picked else null) orelse return pickNote();
    const found = zone.find(p.rays.items, t);
    gui.subhead(if (found) |i| tx.alloc(a, tx.zn_tile, .{ t[0], t[1], i + 1, p.rays.items.len }) else tx.alloc(a, tx.zn_tile_out, .{ t[0], t[1] }));
    if (gui.check(app, clay.id("zone_in"), found != null, tx.get(tx.zn_in))) return zone.toggleTile(a, p, t) catch null;
    const i = found orelse {
        gui.txtWrap(tx.get(tx.zn_in_note), .caption, theme.dim, font_mod.regular);
        return null;
    };
    const r = p.rays.items[i];
    var nr = r;
    gui.fieldRow(tx.get(tx.zn_kind));
    if (gui.segmented(app, "zone_kind", &.{ tx.get(tx.zn_start), tx.get(tx.zn_chain) }, @intFromBool(r.kind == .chain))) |k| nr.kind = if (k == 0) .start else .chain;
    clay.close();
    var out: ?Pattern = null;
    if (p.wide) {
        const side = zone.sideAt(p.rays.items, i);
        gui.fieldRow(tx.get(tx.zn_side));
        if (gui.segmented(app, "zone_side", &.{ tx.get(tx.zn_side_x), tx.get(tx.zn_side_y) }, if (side[0] == 1) 0 else if (side[1] == 1) 1 else 2)) |k|
            out = zone.setSide(a, p, t, if (k == 0) .x else .y) catch null;
        clay.close();
        gui.fieldNote(tx.get(if (side[0] == 0 and side[1] == 0) tx.zn_side_none else tx.zn_side_note), theme.dim);
    }
    gui.fieldRow(tx.get(tx.zn_set));
    if (gui.segmented(app, "zone_set", &.{ "1", "2", "3", "4" }, r.effect)) |k| nr.effect = @intCast(k);
    clay.close();
    const d = gui.stepper(app, a, "zone_pct", tx.alloc(a, tx.zn_pct, .{r.pct}), @floatFromInt(r.pct), 5);
    if (d != 0) nr.pct = @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(r.pct)) + d), 0, zone.max_pct));
    if (out != null) return out;
    if (std.meta.eql(nr, r)) return null;
    return zone.setRay(a, p, t, nr) catch null;
}

fn pickNote() ?Pattern {
    gui.note(tx.get(tx.zn_pick));
    return null;
}

/// Hit set `set` around the target (red), a tile past its farthest; the one clicked.
fn hitGrid(app: *App, set: []const [2]i8) ?[2]i8 {
    const b = zone.setBounds(set);
    var r: i32 = 2;
    for (b) |c| for (c) |v| {
        r = @max(r, @as(i32, @intCast(@abs(v))) + 1);
    };
    r = @min(r, view);
    var hit: ?[2]i8 = null;
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.border.line } });
    var y = -r;
    while (y <= r) : (y += 1) {
        clay.open(.{ .layout = .{ .childGap = lay.border.line } });
        var x = -r;
        while (x <= r) : (x += 1) {
            const d: [2]i8 = .{ @intCast(x), @intCast(y) };
            const on = for (set) |s| {
                if (s[0] == d[0] and s[1] == d[1]) break true;
            } else false;
            const target = x == 0 and y == 0;
            const bg = if (on) (if (target) ew.target_col else ew.hit_col) else if (target) clay.Color{ .r = 110, .g = 45, .b = 45, .a = 255 } else theme.viewport;
            if (cell(app, cellId("zone_h", d), bg, false, false, "", "")) hit = d;
        }
        clay.close();
    }
    clay.close();
    return hit;
}

fn cellId(name: []const u8, t: [2]i8) ui.Clay_ElementId {
    return clay.idi(name, @as(u32, @intCast(@as(i32, t[1]) + 128)) * 256 + @as(u32, @intCast(@as(i32, t[0]) + 128)));
}

/// A grid tile (`id` null: not clickable): `pct` over `set`; `edge` outlines it, `sel`
/// in the accent. True when clicked.
fn cell(app: *const App, id: ?ui.Clay_ElementId, bg: clay.Color, edge: bool, sel: bool, pct: []const u8, set: []const u8) bool {
    const over = if (id) |i| clay.pointerOver(i) else false;
    clay.open(.{
        .id = id orelse .{},
        .layout = .{ .sizing = .{ .width = clay.fixed(ew.tile), .height = clay.fixed(ew.tile) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = bg,
        .border = if (sel or over) .{ .color = theme.accent, .width = gui.edges(lay.border.mark) } else if (edge) .{ .color = theme.text, .width = gui.edges(lay.border.mark) } else .{},
    });
    const hit = id != null and clay.hovered() and app.clicked;
    if (pct.len > 0) gui.txt(pct, .caption, theme.text, font_mod.regular);
    if (set.len > 0) gui.txt(set, .caption, theme.warn, font_mod.regular);
    clay.close();
    return hit;
}

/// `--zone-edit CLASS WHAT VALUE`: WHAT `tile` "dx,dy" that ray tile picked and its
/// "in the zone" toggled, `hit`
/// "k:dx,dy" one on hit set k's (1-based), or a field (`rays`, `effects`, `wide`) set
/// from its rules text; the weapon page then shows the zone.
pub fn scripted(app: *App, class: i32, what: []const u8, value: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const a = app.frame.allocator();
    const p = current(class);
    app.entry_view = .zone;
    if (std.mem.eql(u8, what, "tile")) {
        const t = try pair(value);
        select(p, t);
        return apply(app, try zone.toggleTile(a, p, t));
    }
    if (std.mem.eql(u8, what, "hit")) {
        const k = std.mem.indexOfScalar(u8, value, ':') orelse return error.BadValue;
        shown_set = try std.fmt.parseInt(u8, value[0..k], 10) -| 1;
        if (shown_set >= 4) return error.BadValue;
        return apply(app, try zone.toggleHit(a, p, shown_set, try pair(value[k + 1 ..])));
    }
    if (!std.mem.eql(u8, what, "rays") and !std.mem.eql(u8, what, "effects") and !std.mem.eql(u8, what, "wide")) return error.BadField;
    const text = if (what[0] == 'w') value else try std.fmt.allocPrint(a, "\"{s}\"", .{value});
    apply(app, try og.loaders.rules_text.withField(a, Pattern, p, what, text, &app.rule_why));
}

fn pair(s: []const u8) ![2]i8 {
    const k = std.mem.indexOfScalar(u8, s, ',') orelse return error.BadValue;
    return .{ try std.fmt.parseInt(i8, s[0..k], 10), try std.fmt.parseInt(i8, s[k + 1 ..], 10) };
}
