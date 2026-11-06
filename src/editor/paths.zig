//! The level edit mode's Paths tool: a location's walk paths (`<level>.ap`: stairs,
//! ladders, footbridges, a route the walk takes between two cells of the walk grid —
//! `link` its start and end cell — through its nodes) drawn on the map, nodes dragged,
//! added by clicks, a path's cells set, paths made and deleted; each path's `.pth` script
//! (NodeResponse: the walk animation at a node) opened or made. The file is written in
//! the game's layout (level_files.encodePaths, every game file round-trips).
//! An OpenGorky project keeps them in the location's `paths.ogs`: each a `path` block
//! (`link`, `points` of PathPoint records, its code `fn OnNode(no, dir, walker)` in it).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const map_io = og.loaders.map;
const core_map = og.core.map;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const ink = @import("render.zig").ink;
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const doctabs = @import("doctabs.zig");
const level = @import("level.zig");
const paint = @import("paint.zig");
const Doc = level.Doc;
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const store_og = @import("store.zig").og_src;

/// The Paths tool (`app.paths`): the picked path, what a click does, a node dragged.
pub const State = struct {
    sel: app_mod.Name(64) = .{},
    mode: Mode = .pick,
    drag: ?struct { node: usize, at: [2]f32 } = null,
};

pub const Mode = enum { pick, add, start, end };

fn apEntry(a: Allocator, d: *Doc) []const u8 {
    return std.fmt.allocPrint(a, "{s}.ap", .{d.name}) catch "";
}

/// OpenGorky: the location's `paths.ogs` (its Store index; null: none yet).
fn ogEntry(a: Allocator, d: *Doc) []const u8 {
    return std.fmt.allocPrint(a, "locations/{s}/paths.ogs", .{d.name}) catch "";
}

fn og_(app: *App) bool {
    return app.store.root != null;
}

/// `paths.ogs` read (null: none, or it does not read).
fn ogUnit(app: *App, a: Allocator, d: *Doc) ?og.script.ogs.parser.Unit {
    const f = app.store.file(store_og, ogEntry(a, d)) catch return null;
    var diag: og.script.ogs.parser.Diagnostic = .{};
    return og.script.ogs.parser.parse(a, app.store.text(f), ogEntry(a, d), &diag) catch null;
}

/// The paths as the Store has them (frame memory; names copied).
pub fn load(app: *App, d: *Doc) []core_map.Path {
    const a = app.frame.allocator();
    if (og_(app)) {
        const u = ogUnit(app, a, d) orelse return &.{};
        return og.loaders.ogs.pathsIn(a, &.{u}, d.name) catch &.{};
    }
    const f = app.store.file(d.level_archive, apEntry(a, d)) catch return &.{};
    const ps = map_io.parsePaths(a, app.store.text(f)) catch return &.{};
    return ps;
}

fn save(app: *App, d: *Doc, ps: []const core_map.Path, what: []const u8) void {
    const a = app.frame.allocator();
    if (og_(app)) return ogSave(app, d, ps, what, null);
    const entry = apEntry(a, d);
    const t = map_io.encodePaths(app.gpa, ps) catch return;
    if (app.store.file(d.level_archive, entry)) |f| {
        app.store.replaceLabeled(f, t, std.fmt.allocPrint(a, "{s}: {s}", .{ entry, what }) catch entry) catch |err| {
            app.gpa.free(t);
            app.failed(err);
        };
    } else |_| {
        _ = app.store.addNew(&.{.{ .archive = d.level_archive, .entry = entry, .text = t }}) catch |err| app.failed(err);
    }
}

/// Another path than `k` has `cell` as its link end `j` (0: start, 2: end).
fn usedBy(ps: []const core_map.Path, k: usize, j: usize, cell: [2]f32) bool {
    for (ps, 0..) |p, i| if (i != k and p.link[j] == cell[0] and p.link[j + 1] == cell[1]) return true;
    return false;
}

fn selIndex(app: *App, ps: []const core_map.Path) ?usize {
    for (ps, 0..) |p, k| if (std.mem.eql(u8, p.name, app.paths.sel.get())) return k;
    return null;
}

/// Paths over the map: each a line through its nodes, the picked one bright with its
/// nodes numbered and its start and end cells marked.
pub fn draw(app: *App, d: *Doc, rect: c.SDL_FRect) void {
    const ps = load(app, d);
    const cs = core_map.WalkMap.cell_size;
    for (ps, 0..) |p, k| {
        const sel = selIndex(app, ps) == k;
        const a: u8 = if (sel) 255 else 120;
        ink(app.r, lay.canvas.alpha(lay.canvas.path, a));
        var prev: ?[2]f32 = null;
        for (p.points, 0..) |pt0, i| {
            var pt: [2]f32 = .{ pt0[0], pt0[1] };
            if (app.paths.drag) |dr| if (sel and dr.node == i) {
                pt = dr.at;
            };
            const s = d.toScreen(rect, pt);
            if (prev) |q| _ = c.SDL_RenderLine(app.r, q[0], q[1], s[0], s[1]);
            const r: f32 = if (sel) 5 else 3;
            _ = c.SDL_RenderFillRect(app.r, &.{ .x = s[0] - r, .y = s[1] - r, .w = r * 2, .h = r * 2 });
            if (sel) app.font.draw(app.r, std.fmt.allocPrint(app.frame.allocator(), "{d}", .{i}) catch "", font_mod.regular, lay.Type.body.pt(), s[0] + 7, s[1] - 8, lay.canvas.alpha(lay.canvas.path_text, 255));
            prev = s;
        }
        if (p.points.len > 0) {
            const s = d.toScreen(rect, .{ p.points[0][0], p.points[0][1] });
            app.font.draw(app.r, p.name, font_mod.bold, lay.Type.body.pt(), s[0] + 7, s[1] + 6, lay.canvas.alpha(lay.canvas.path_text, a));
        }
        if (!sel) continue;
        // The start (green) and end (orange) cells of the walk grid.
        for ([_][2]f32{ .{ p.link[0], p.link[1] }, .{ p.link[2], p.link[3] } }, 0..) |cell, i| {
            const s = d.toScreen(rect, .{ cell[0] * cs, cell[1] * cs });
            ink(app.r, if (i == 0) lay.canvas.path_start else lay.canvas.path_end);
            _ = c.SDL_RenderRect(app.r, &.{ .x = s[0], .y = s[1], .w = cs * d.zoom, .h = cs * d.zoom });
            _ = c.SDL_RenderRect(app.r, &.{ .x = s[0] - 1, .y = s[1] - 1, .w = cs * d.zoom + 2, .h = cs * d.zoom + 2 });
        }
    }
}

/// Pressed on the map: a node added or a cell set (the panel's mode), else a node of the
/// picked path (or any) taken to drag, a path picked.
pub fn press(app: *App, d: *Doc, rect: c.SDL_FRect, m: [2]f32) void {
    const ps = load(app, d);
    const bg = d.onPicture(d.toBackground(rect, m));
    if (selIndex(app, ps)) |k| switch (app.paths.mode) {
        .add => {
            const a = app.frame.allocator();
            var more = a.alloc([4]f32, ps[k].points.len + 1) catch return;
            @memcpy(more[0..ps[k].points.len], ps[k].points);
            more[ps[k].points.len] = .{ @round(bg[0]), @round(bg[1]), 0, 0 };
            ps[k].points = more;
            return save(app, d, ps, "node");
        },
        .start, .end => {
            const cs = core_map.WalkMap.cell_size;
            const cell: [2]f32 = .{ @floor(bg[0] / cs), @floor(bg[1] / cs) };
            const j: usize = if (app.paths.mode == .start) 0 else 2;
            const old: [2]f32 = .{ ps[k].link[j], ps[k].link[j + 1] };
            ps[k].link[j] = cell[0];
            ps[k].link[j + 1] = cell[1];
            if (app.paint) |p| paint.linkMark(app, p, if (j == 0) 2 else 4, old, usedBy(ps, k, j, old), cell);
            app.paths.mode = .pick;
            return save(app, d, ps, "link");
        },
        .pick => {},
    };
    // A node within 8 points: the picked path's first.
    var best: ?struct { path: usize, node: usize } = null;
    const sk = selIndex(app, ps);
    for (ps, 0..) |p, k| for (p.points, 0..) |pt, i| {
        const s = d.toScreen(rect, .{ pt[0], pt[1] });
        if (@abs(s[0] - m[0]) > 8 or @abs(s[1] - m[1]) > 8) continue;
        if (best == null or k == sk) best = .{ .path = k, .node = i };
    };
    if (best) |b| {
        app.paths.sel.set(ps[b.path].name);
        app.paths.drag = .{ .node = b.node, .at = .{ ps[b.path].points[b.node][0], ps[b.path].points[b.node][1] } };
        return;
    }
    app.pan = m;
}

pub fn drag(app: *App, d: *Doc, rect: c.SDL_FRect, m: [2]f32) void {
    const dr = &(app.paths.drag orelse return);
    const bg = d.onPicture(d.toBackground(rect, m));
    dr.at = .{ @round(bg[0]), @round(bg[1]) };
}

pub fn release(app: *App, d: *Doc) void {
    const dr = app.paths.drag orelse return;
    app.paths.drag = null;
    const ps = load(app, d);
    const k = selIndex(app, ps) orelse return;
    if (dr.node >= ps[k].points.len) return;
    if (ps[k].points[dr.node][0] == dr.at[0] and ps[k].points[dr.node][1] == dr.at[1]) return;
    ps[k].points[dr.node][0] = dr.at[0];
    ps[k].points[dr.node][1] = dr.at[1];
    save(app, d, ps, "node moved");
}

/// The tool's panel: the paths (one picked), its nodes (typed: x, y, angle, the last
/// number), the click modes, its script, a new path, delete.
pub fn panel(app: *App, a: Allocator, d: *Doc) void {
    gui.note(tx.get(tx.pa_hint));
    const ps = load(app, d);
    for (ps, 0..) |p, k| {
        const sel = selIndex(app, ps) == k;
        const rid = clay.idi("path_row", @intCast(k));
        if (gui.listRow(app, rid, .{ .selected = sel })) {
            app.paths.sel.set(p.name);
            app.paths.mode = .pick;
        }
        gui.txt(p.name, .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.txt(tx.alloc(a, tx.pa_nodes, .{p.points.len}), .caption, theme.dim, font_mod.regular);
        clay.close();
    }
    if (gui.footer(app, "path_new", &.{tx.get(tx.pa_new)}, null) != null) newPath(app, d, ps);
    const k = selIndex(app, ps) orelse return;
    const p = ps[k];
    gui.subhead(p.name);
    // The click modes, wrapped in a narrow panel.
    const modes = [_]gui.Item{
        .{ .id = clay.id("path_add"), .b = .{ .icon = .plus, .label = tx.get(tx.pa_add), .on = app.paths.mode == .add, .size = .tool } },
        .{ .id = clay.id("path_start"), .b = .{ .icon = .crosshair, .label = tx.get(tx.pa_start), .on = app.paths.mode == .start, .size = .tool } },
        .{ .id = clay.id("path_end"), .b = .{ .icon = .crosshair, .label = tx.get(tx.pa_end), .on = app.paths.mode == .end, .size = .tool } },
    };
    if (gui.buttonRow(app, clay.id("path_modes"), &modes)) |m| app.paths.mode = switch (m) {
        0 => if (app.paths.mode == .add) .pick else .add,
        1 => .start,
        else => .end,
    };
    gui.txt(tx.alloc(a, tx.pa_link, .{ p.link[0], p.link[1], p.link[2], p.link[3] }), .caption, theme.dim, font_mod.regular);
    for (p.points, 0..) |pt, i| {
        gui.row(lay.space.xs);
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.small) } } });
        gui.txt(std.fmt.allocPrint(a, "{d}", .{i}) catch "", .caption, theme.dim, font_mod.regular);
        clay.close();
        inline for (0..4) |j| {
            const shown = if (j == 2) std.fmt.allocPrint(a, "{d:.2}", .{pt[j]}) catch "" else std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(pt[j]))}) catch "";
            if (gui.textField(app, std.fmt.allocPrint(a, "pn{d}_{d}_{d}", .{ k, i, j }) catch "pn", shown, lay.width.number, "")) |v| {
                if (std.fmt.parseFloat(f32, std.mem.trim(u8, v, " "))) |num| {
                    ps[k].points[i][j] = num;
                    save(app, d, ps, "node");
                } else |_| {}
            }
        }
        if (gui.toolButton(app, std.fmt.allocPrint(a, "pn_del{d}", .{i}) catch "pd", .trash_2, "", false, false)) {
            var fewer = a.alloc([4]f32, p.points.len - 1) catch return clay.close();
            @memcpy(fewer[0..i], p.points[0..i]);
            @memcpy(fewer[i..], p.points[i + 1 ..]);
            ps[k].points = fewer;
            save(app, d, ps, "node deleted");
        }
        clay.close();
    }
    if (gui.footer(app, "path_acts", &.{ tx.get(tx.pa_script), tx.get(tx.cm_delete) }, null)) |m| if (m == 0) openScript(app, d, p.name) else app.askDelete(.path, 0, p.name);
}

pub fn newPath(app: *App, d: *Doc, ps: []core_map.Path) void {
    const a = app.frame.allocator();
    const name = for (1..1000) |n| {
        const s = std.fmt.allocPrint(a, "path{d}", .{n}) catch return;
        for (ps) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, s)) break;
        } else break s;
    } else return;
    var more = a.alloc(core_map.Path, ps.len + 1) catch return;
    @memcpy(more[0..ps.len], ps);
    more[ps.len] = .{ .name = name, .link = .{ 0, 0, 0, 0 }, .points = &.{} };
    save(app, d, more, "new path");
    app.paths.sel.set(name);
    app.paths.mode = .add;
    app.setStatus(tx.st_path_added, .{name});
}

/// Path `name` deleted (its `.pth` stays: a script nothing names is harmless).
pub fn remove(app: *App, d: *Doc, name: []const u8) void {
    const ps = load(app, d);
    var out: std.ArrayList(core_map.Path) = .empty;
    for (ps, 0..) |p, k| {
        if (!std.ascii.eqlIgnoreCase(p.name, name)) {
            out.append(app.frame.allocator(), p) catch return;
            continue;
        }
        // Its cells' marks go too (another path's on the same cell stay).
        if (app.paint) |pt| for ([_]usize{ 0, 2 }) |j| {
            const cell: [2]f32 = .{ p.link[j], p.link[j + 1] };
            paint.linkMark(app, pt, if (j == 0) 2 else 4, cell, usedBy(ps, k, j, cell), null);
        };
    }
    save(app, d, out.items, "path deleted");
    app.paths.sel.set("");
}

/// OpenGorky: `paths.ogs` written anew from `ps`, each block keeping its code (`stub`: that
/// path gets an empty OnNode when it has none). One undo step.
fn ogSave(app: *App, d: *Doc, ps: []const core_map.Path, what: []const u8, stub: ?[]const u8) void {
    const a = app.frame.allocator();
    const print = og.script.ogs.print;
    const old = ogUnit(app, a, d);
    var w: std.Io.Writer.Allocating = .init(a);
    const out = &w.writer;
    out.print("level \"{s}\" {{\n", .{d.name}) catch return;
    for (ps) |p| {
        out.print("    path {s} {{\n        link = [{d}, {d}, {d}, {d}];\n        points = [", .{ p.name, p.link[0], p.link[1], p.link[2], p.link[3] }) catch return;
        for (p.points, 0..) |pt, i| {
            out.print("{s}PathPoint(x = {d}, y = {d}, angle = {d}", .{ if (i > 0) ", " else "", @round(pt[0]), @round(pt[1]), pt[2] }) catch return;
            if (@floor(pt[2]) == pt[2]) out.writeAll(".0") catch return;
            out.print(", z = {d})", .{@round(pt[3])}) catch return;
        }
        out.writeAll("];\n") catch return;
        // Its code as it was.
        var code = false;
        if (old) |u| for (u.modules) |m| for (m.entities) |lv| for (lv.children) |ch| if (std.mem.eql(u8, ch.kind, "path") and std.ascii.eqlIgnoreCase(ch.name, p.name)) if (ch.own) |o| {
            for (o.methods) |f| print.function(out, f, 2) catch return;
            code = true;
        };
        if (!code) if (stub) |n| if (std.ascii.eqlIgnoreCase(n, p.name)) out.writeAll("        // An actor passed point `no` of this path (`dir` 1 forward, 0 back).\n        fn OnNode(no, dir, walker) {\n        }\n") catch return;
        out.writeAll("    }\n") catch return;
    }
    out.writeAll("}\n") catch return;
    const entry = ogEntry(a, d);
    // As the OG printer lays it out (a long list of points one a line).
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(a, w.written(), entry, &diag) catch return app.setStatus(tx.st_og_bad_value, .{diag.message});
    var pw: std.Io.Writer.Allocating = .init(a);
    print.unit(&pw.writer, u) catch return;
    const t = app.gpa.dupe(u8, pw.written()) catch return;
    if (app.store.file(store_og, entry)) |f| {
        app.store.replaceLabeled(f, t, std.fmt.allocPrint(a, "{s}: {s}", .{ entry, what }) catch entry) catch |err| {
            app.gpa.free(t);
            app.failed(err);
        };
    } else |_| {
        _ = app.store.addNew(&.{.{ .archive = store_og, .entry = entry, .text = t }}) catch |err| app.failed(err);
    }
}

/// Path `name`'s `.pth` in the code editor (made first with NodeResponse if missing);
/// OpenGorky: its block in `paths.ogs` (an empty OnNode added if it has no code).
fn openScript(app: *App, d: *Doc, name: []const u8) void {
    const a = app.frame.allocator();
    if (og_(app)) {
        ogSave(app, d, load(app, d), "path script", name);
        const f = app.store.file(store_og, ogEntry(a, d)) catch return;
        const t = app.store.text(f);
        const at = std.mem.indexOf(u8, t, std.fmt.allocPrint(a, "path {s} {{", .{name}) catch return) orelse 0;
        return doctabs.showCode(app, f, @intCast(at));
    }
    const entry = std.fmt.allocPrint(a, "{s}.pth", .{name}) catch return;
    if (app.store.file(d.level_archive, entry)) |f| return doctabs.showCode(app, f, null) else |_| {}
    const t = app.gpa.dupe(u8, "// The walk along this path: node `no` reached, `dir` 1 forward, 0 back.\r\nfunction NodeResponse(int no, int dir)\r\n{\r\n};\r\n") catch return;
    const f = app.store.addNew(&.{.{ .archive = d.level_archive, .entry = entry, .text = t }}) catch |err| return app.failed(err);
    doctabs.showCode(app, f, null);
}
