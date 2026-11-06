//! The Points tool of the level edit mode: a scene's points (`<scene>.pnt`) placed,
//! dragged and taken out on the map, the scene chosen.

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
const theme = app_mod.theme;
const Doc = @import("level.zig").Doc;
const common_archive = @import("store.zig").common_archive;
const scenes_mod = @import("scenes.zig");
const og_ir = @import("opengorky").script.ir;

/// The scene whose points are placed: the points tool's pick (without the edit mode, as
/// a scripted `--scene-point`: the Scenes tab's scene); null: none, or not in the catalog.
fn pointsScene(app: *App) ?[]const u8 {
    const p = app.paint orelse return app.sceneName();
    const i = app.sceneIndex(p.scene.get()) orelse return null;
    return app.catalog.scenes.items[i].name;
}

/// The points file of the scene picked (Store index).
fn pointsFile(app: *App) ?usize {
    const name = pointsScene(app) orelse return null;
    var eb: [96]u8 = undefined;
    return app.store.file(common_archive, std.fmt.bufPrint(&eb, "scriptlets\\{s}.pts", .{name}) catch return null) catch null;
}

pub const Point = struct { name: []const u8, x: f32, y: f32 };

/// OpenGorky: the picked scene's block file (`src/scenes/<name>.ogs`: its points are its
/// `points = [Point(…)]`); null: a Classic project or none.
fn ogScene(app: *App) ?usize {
    if (!app.ogLayout()) return null;
    return @import("og_page.zig").sceneFile(app, pointsScene(app) orelse return null);
}

/// The `Point(…)` records of OG scene block file `f`'s `points`.
fn ogPointExprs(app: *App, f: usize) []const *const og_ir.Expr {
    const e = @import("model.zig").field(app, f, "points").og_expr orelse return &.{};
    return if (e.kind == .list) e.kind.list else &.{};
}

/// The picked scene's points: its `.pts`, on OpenGorky its block's `points`.
fn scenePoints(app: *App, a: Allocator) ?[]Point {
    const schema = @import("opengorky").core.schema;
    if (ogScene(app)) |f| {
        var out: std.ArrayList(Point) = .empty;
        for (ogPointExprs(app, f)) |x| if (x.kind == .call) {
            const r = x.kind.call;
            const n = schema.text(schema.recordField(r, "name") orelse continue) orelse continue;
            out.append(a, .{ .name = n, .x = schema.number(schema.recordField(r, "x") orelse continue) orelse 0, .y = schema.number(schema.recordField(r, "y") orelse continue) orelse 0 }) catch {};
        };
        return out.items;
    }
    const f = pointsFile(app) orelse return null;
    return points(a, app.store.text(f));
}

/// OpenGorky: the picked scene's `points` as `items` (OG Script records), one undo step.
fn setOgPoints(app: *App, f: usize, items: []const []const u8) !void {
    const a = app.frame.allocator();
    const list = try std.mem.join(a, ", ", items);
    return @import("model_og.zig").set(app, f, &.{"points"}, try std.fmt.allocPrint(a, "[{s}]", .{list}));
}

/// `name,x,y,angle` lines of a `.pts` (background pixels).
pub fn points(a: Allocator, text: []const u8) []Point {
    var out: std.ArrayList(Point) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var f = std.mem.splitScalar(u8, std.mem.trim(u8, raw, " \t\r"), ',');
        const n = f.next() orelse continue;
        const x = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
        const y = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
        out.append(a, .{ .name = n, .x = x, .y = y }) catch {};
    }
    return out.items;
}

pub fn drawPoints(app: *App, d: *const Doc, rect: c.SDL_FRect) void {
    for (scenePoints(app, app.frame.allocator()) orelse return) |pt| {
        const s = screen(d, rect, .{ pt.x, pt.y });
        ink(app.r, lay.canvas.point);
        _ = c.SDL_RenderLine(app.r, s[0] - 7, s[1], s[0] + 7, s[1]);
        _ = c.SDL_RenderLine(app.r, s[0], s[1] - 7, s[0], s[1] + 7);
        const w = app.font.measure(pt.name, font_mod.bold, lay.Type.body.pt())[0];
        ink(app.r, lay.canvas.point_label_bg);
        _ = c.SDL_RenderFillRect(app.r, &.{ .x = s[0] + 8, .y = s[1] - 20, .w = w + 6, .h = 18 });
        app.font.draw(app.r, pt.name, font_mod.bold, lay.Type.body.pt(), s[0] + 11, s[1] - 20, lay.canvas.point);
    }
}

/// A click of the points tool: a new point `p<n>` of the picked scene at `b`.
pub fn pointClick(app: *App, at: [2]f32) void {
    const og_f = ogScene(app);
    const f = og_f orelse pointsFile(app) orelse return app.setStatus(tx.st_no_scene, .{});
    const b = if (app.doc) |d| d.onPicture(at) else at;
    const a = app.frame.allocator();
    const text = app.store.text(f);
    const have = scenePoints(app, a) orelse return;
    var nb: [16]u8 = undefined;
    const name = for (1..1000) |n| {
        const s = std.fmt.bufPrint(&nb, "p{d}", .{n}) catch unreachable;
        for (have) |pt| {
            if (std.ascii.eqlIgnoreCase(pt.name, s)) break;
        } else break s;
    } else return;
    if (og_f) |sf| {
        // OpenGorky: one more `Point(…)` in the block's `points`.
        var items: std.ArrayList([]const u8) = .empty;
        for (ogPointExprs(app, sf)) |x| items.append(a, @import("model_og.zig").exprText(a, x)) catch return;
        items.append(a, std.fmt.allocPrint(a, "Point(name = \"{s}\", x = {d:.1}, y = {d:.1}, angle = 0.0)", .{ name, @round(b[0]), @round(b[1]) }) catch return) catch return;
        setOgPoints(app, sf, items.items) catch |err| return app.failed(err);
        return app.setStatus(tx.st_point_added, .{ name, pointsScene(app).? });
    }
    const sep = if (text.len > 0 and text[text.len - 1] != '\n') "\r\n" else "";
    const t = std.fmt.allocPrint(app.gpa, "{s}{s}{s},{d},{d},0.000000\r\n", .{ text, sep, name, @round(b[0]), @round(b[1]) }) catch return;
    app.store.replaceLabeled(f, t, std.fmt.allocPrint(a, "+ {s} ({s}.pts)", .{ name, pointsScene(app).? }) catch null) catch |err| {
        app.gpa.free(t);
        return app.failed(err);
    };
    app.setStatus(tx.st_point_added, .{ name, pointsScene(app).? });
}

/// Point `name` taken out of the picked scene's `.pts`.
pub fn dropPoint(app: *App, name: []const u8) void {
    if (ogScene(app)) |sf| {
        const a = app.frame.allocator();
        const schema = @import("opengorky").core.schema;
        var items: std.ArrayList([]const u8) = .empty;
        for (ogPointExprs(app, sf)) |x| {
            if (x.kind == .call) if (schema.recordField(x.kind.call, "name")) |n| if (schema.text(n)) |t| if (std.ascii.eqlIgnoreCase(t, name)) continue;
            items.append(a, @import("model_og.zig").exprText(a, x)) catch return;
        }
        return setOgPoints(app, sf, items.items) catch |err| app.failed(err);
    }
    const f = pointsFile(app) orelse return;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, app.store.text(f), '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        var fl = std.mem.splitScalar(u8, std.mem.trim(u8, raw, " \t\r"), ',');
        if (std.ascii.eqlIgnoreCase(fl.next() orelse "", name)) continue;
        out.appendSlice(app.gpa, raw) catch return;
        out.append(app.gpa, '\n') catch return;
    }
    const t = out.toOwnedSlice(app.gpa) catch return;
    app.store.replaceLabeled(f, t, std.fmt.allocPrint(app.frame.allocator(), "- {s}", .{name}) catch null) catch app.gpa.free(t);
}

/// Scene `name` started by a script of level `level` (StartScriptlet/SetAddonScriptlet).
fn sceneOfLevel(app: *App, a: Allocator, name: []const u8, level: []const u8) bool {
    // OpenGorky: the level's texts start it (`~e"<name>"`).
    if (app.ogLayout()) if (app.doc) |d| {
        const q = std.fmt.allocPrint(a, "~e\"{s}\"", .{name}) catch return false;
        if (!std.ascii.eqlIgnoreCase(d.name, level)) return false;
        for (@import("areas.zig").levelTexts(app, d, a)) |f| if (std.ascii.findIgnoreCase(app.store.text(f), q) != null) return true;
        return false;
    };
    for (app.catalog.scene_files.items) |sf| {
        if (!std.ascii.eqlIgnoreCase(sf.level, level)) continue;
        const f = app.store.file(sf.archive, sf.entry) catch continue;
        const cs = scenes_mod.calls(a, app.store.text(f), name) catch continue;
        if (cs.len > 0) return true;
    }
    return false;
}

/// The scenes to pick from: this level's (its scripts start them), or all.
fn sceneChoice(app: *App, a: Allocator, p: *Paint) void {
    const d = app.doc orelse return;
    clay.openScroll(.{ .id = clay.id("lp_scenes"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 8 * lay.height.small } } } }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.catalog.scenes.items, 0..) |sc, i| {
        if (!p.all_scenes and !sceneOfLevel(app, a, sc.name, d.name)) continue;
        const sel = std.ascii.eqlIgnoreCase(p.scene.get(), sc.name);
        const rid = clay.idi("lp_scene", @intCast(i));
        if (gui.listRow(app, rid, .{ .selected = sel, .h = lay.height.small, .rounded = false, .bg = theme.field })) p.scene.set(sc.name);
        gui.txt(sc.name, .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.close();
    if (gui.footer(app, "lp_all_scenes", &.{tx.get(if (p.all_scenes) tx.lp_scenes_level else tx.lp_scenes_all)}, null) != null) p.all_scenes = !p.all_scenes;
}

/// The points tool's panel: the scene (picked here), its points (delete each).
pub fn pointsPanel(app: *App, a: Allocator, p: *Paint) void {
    sceneChoice(app, a, p);
    const name = pointsScene(app) orelse return gui.warning(tx.get(tx.lp_points_none));
    gui.subhead(tx.alloc(a, tx.lp_points_of, .{name}));
    gui.note(tx.get(tx.lp_points_hint));
    for (scenePoints(app, a) orelse return, 0..) |pt, k| {
        gui.fieldRow(pt.name);
        gui.txt(std.fmt.allocPrint(a, "{d}, {d}", .{ pt.x, pt.y }) catch "", .body, theme.text, font_mod.regular);
        gui.spacer();
        if (gui.smallButton(app, clay.id(std.fmt.allocPrint(a, "lp_pt_del{d}", .{k}) catch "p"), tx.get(tx.vo_remove))) app.askDelete(.point, 0, pt.name);
        clay.close();
    }
}
