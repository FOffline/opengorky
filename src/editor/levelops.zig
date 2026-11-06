//! New levels and scenes: a location or battle made from the open one (written to
//! disk), a scene made or renamed; heroes brought onto a level or taken off it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const tx = @import("text.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const store_mod = @import("store.zig");
const savelog = @import("savelog.zig");
const common_archive = store_mod.common_archive;
const doctabs = @import("doctabs.zig");
const trigger = @import("trigger.zig");
const newlevel = @import("newlevel.zig");
const App = @import("app.zig").App;

/// A new scene `sceneN`: its script (a template to fill), an empty points file and a
/// dialogue without recordings; selected, the script open. One undo step.
pub fn newScene(app: *App) void {
    var nb: [32]u8 = undefined;
    const name = for (1..1000) |n| {
        const s = std.fmt.bufPrint(&nb, "scene{d}", .{n}) catch unreachable;
        if (app.sceneIndex(s) == null) break s;
    } else return;
    if (app.ogLayout()) return newSceneOg(app, name);
    const a = app.frame.allocator();
    const scr = std.fmt.allocPrint(app.gpa,
        \\// A scene made in the editor. Its points: scriptlets\{s}.pts (level edit
        \\// mode, "Scene points"); its lines: {s}.dlg. Started by StartScriptlet("{s}").
        \\GUI_CUTSCENE
        \\PANORAMA_ON
        \\AUTOCAMERA_OFF
        \\DIALOG_INIT("{s}","{s}.dlg")
        \\// A hero brought to the level joins in the level script before this scene starts,
        \\// as McFadden in 02_serwers.lev: EnableObject("Medusa"); HERO_EnableEnumerate("Medusa",1);
        \\// ACTORSETSTATE("Medusa",0)
        \\// PLACE("Medusa","p1")
        \\// DOLLY("p1",0,130)
        \\// WALKTO("Medusa","p2")
        \\// WAITFORACTOR("Medusa")
        \\DIALOG_DISPLAY(0)
        \\GUI_NORMAL
        \\PANORAMA_OFF
        \\
    , .{ name, name, name, name, name }) catch return;
    const scr_crlf = std.mem.replaceOwned(u8, app.gpa, scr, "\n", "\r\n") catch return;
    app.gpa.free(scr);
    const dlg = std.fmt.allocPrint(app.gpa, "DIALOG {s}\r\n\r\nSullivan:\r\n  ...\r\n", .{name}) catch return;
    const pts = app.gpa.alloc(u8, 0) catch return;
    const f = app.store.addNew(&.{
        .{ .archive = common_archive, .entry = std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{name}) catch return, .text = scr_crlf },
        .{ .archive = common_archive, .entry = std.fmt.allocPrint(a, "scriptlets\\{s}.pts", .{name}) catch return, .text = pts },
        .{ .archive = "common/lang.dat", .entry = std.fmt.allocPrint(a, "{s}.dlg", .{name}) catch return, .text = dlg },
    }) catch |err| return app.failed(err);
    app.catalog.scenes.append(app.catalog.arena.allocator(), .{ .name = app.catalog.arena.allocator().dupe(u8, name) catch return }) catch return;
    doctabs.show(app, .scenes, name);
    doctabs.showCode(app, f, null);
    app.setStatus(tx.st_scene_added, .{name});
}

/// OpenGorky: new scene `name` in the project's `src/` (`scenes/<name>.ogs`, its commands in
/// OG Script's names, core/scene.zig `ogs_names`; its lines `dialogs/<name>.ogs`), as
/// `newScene`.
fn newSceneOg(app: *App, name: []const u8) void {
    const a = app.frame.allocator();
    const scn = std.fmt.allocPrint(app.gpa,
        \\scene "{s}" {{
        \\    gui::Cutscene(true);
        \\    camera::Panorama(true);
        \\    camera::Auto(false);
        \\    dialog::Open(~d"{s}");
        \\    dialog::Say(0);
        \\    gui::Cutscene(false);
        \\    camera::Panorama(false);
        \\}}
        \\
    , .{ name, name }) catch return;
    const dlg = std.fmt.allocPrint(app.gpa, "dialog \"{s}\" {{\n    Line(who = \"Sullivan\", text = \"...\");\n}}\n", .{name}) catch return;
    const f = app.store.addNew(&.{
        .{ .archive = store_mod.og_src, .entry = std.fmt.allocPrint(a, "scenes/{s}.ogs", .{name}) catch return, .text = scn },
        .{ .archive = store_mod.og_src, .entry = std.fmt.allocPrint(a, "dialogs/{s}.ogs", .{name}) catch return, .text = dlg },
    }) catch |err| return app.failed(err);
    app.catalog.scenes.append(app.catalog.arena.allocator(), .{ .name = app.catalog.arena.allocator().dupe(u8, name) catch return }) catch return;
    doctabs.show(app, .scenes, name);
    doctabs.showCode(app, f, null);
    app.setStatus(tx.st_scene_added, .{name});
}

/// Location `name` made from the open one and opened: written to disk at once
/// (the level list and the world read levels from there); undo deletes it (levelMade).
pub fn newLevel(app: *App, name: []const u8) void {
    app.level_naming = false;
    // The mode's strokes into the Store first (it may reload the level).
    _ = app.endPaint();
    const d = app.doc orelse return;
    const battle = d.isBattle();
    (if (app.store.root != null) makeLevelOg(app, d, name) else makeLevel(app, d, name)) catch |err| return if (battle) app.setStatus(tx.st_battle_failed, .{ name, err }) else app.setStatus(tx.st_location_failed, .{ name, err });
    added(app, name, battle, d.name, &.{});
}

/// A blank location or battle `name` (a battle by its name: `NN__…`), made from no level
/// (newlevel.blank): a grey picture of `app.blank_size`, its camera and `.cfg`, a free
/// grid, one light, the entry area, its script.
pub fn blankLevel(app: *App, name: []const u8) void {
    app.level_naming = false;
    _ = app.endPaint();
    const battle = name.len > 5 and std.mem.eql(u8, name[2..4], "__");
    makeBlank(app, name, battle) catch |err| return if (battle) app.setStatus(tx.st_battle_failed, .{ name, err }) else app.setStatus(tx.st_location_failed, .{ name, err });
    added(app, name, battle, "—", &.{});
}

fn makeBlank(app: *App, name: []const u8, battle: bool) !void {
    if (!newlevel.validName(name, battle)) return error.BadName;
    const dat = app.store.dat;
    if (dat.access(app.io, name, .{})) |_| return error.LevelExists else |_| {}
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The size typed in (0: the kind's own), within the project's limits.
    const size: [2]u32 = if (app.blank_size[0] > 0) app.blank_size else newlevel.blankSize(battle);
    try newlevel.checkBlankSize(size, app.ogLayout());
    const l = try newlevel.blank(a, name, battle, size);
    if (app.store.root == null) return writeLevel(app, a, name, l.sprites, l.other);
    // OpenGorky: its block from the blank's script, its files as the project's own assets.
    var files: std.ArrayList(OgFile) = .empty;
    const lev = l.other[l.other.len - 1].data;
    try files.append(a, .{ .path = try blockPath(a, name, battle), .data = try newlevel.ogLevelBlock(a, name, battle, lev) });
    for ([_]struct { []const u8, []const og.formats.archive.File }{ .{ "sprite.dat", l.sprites }, .{ "other.dat", l.other } }) |part| for (part[1]) |f| {
        var lb: [og.loaders.assets.max_path]u8 = undefined;
        const logical = og.loaders.assets.fromEntry(&lb, try std.fmt.allocPrint(a, "{s}/{s}", .{ name, part[0] }), f.name) orelse continue;
        if (std.mem.startsWith(u8, logical, "levels/") and !std.ascii.endsWithIgnoreCase(f.name, ".lev")) try files.append(a, .{ .path = try std.fmt.allocPrint(a, "assets/{s}", .{logical}), .data = f.data });
    };
    _ = try writeLevelOg(app, a, name, battle, files.items);
}

// ---------------------------------------------------------------- OpenGorky

/// A file of a new OpenGorky level: `path` under the project's `src/`.
const OgFile = struct { path: []const u8, data: []const u8 };

/// The level's own top folder of `src/` (`locations`, `battles`).
fn topOf(battle: bool) []const u8 {
    return if (battle) "battles" else "locations";
}

/// Its block's file, as the writer lays a level out (`locations/<l>/level.ogs`,
/// `battles/<b>/battle.ogs`).
fn blockPath(a: Allocator, name: []const u8, battle: bool) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ topOf(battle), name, if (battle) "battle.ogs" else "level.ogs" });
}

/// OpenGorky: level `name` made from level `d` as on Classic (newLevel): its block with the
/// template block's own fields (camera, character size, grid…), no objects, variables or
/// code; a location's party at a new entry area `capt_start`, a battle's heroes where the
/// template places them (its fighters left out); its assets (the template's own over the
/// installed game's): the picture, a location's walk maps and lights, a battle's grid,
/// lights and areas.
fn makeLevelOg(app: *App, d: *Doc, name: []const u8) !void {
    const battle = d.isBattle();
    if (!newlevel.validName(name, battle)) return error.BadName;
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const model_og = @import("model_og.zig");
    const bf = @import("level_og.zig").blockFile(d) orelse return error.NoBlock;
    const b = model_og.blockOf(app, a, bf) orelse return error.NoBlock;
    var block: std.ArrayList(u8) = .empty;
    try block.print(a, "{s} \"{s}\" {{\n", .{ b.e.kind, name });
    const objs = model_og.levelObjects(app, a, bf);
    for (b.e.fields) |f| {
        if (std.mem.eql(u8, f.name, "entry") or std.mem.eql(u8, f.name, "boss")) continue;
        var v = f.value;
        if (std.mem.eql(u8, f.name, "placement")) {
            // A location's party walks in at `entry`; a battle keeps its heroes' places.
            if (!battle or v.kind != .list) continue;
            var keep: std.ArrayList(*const og.script.ir.Expr) = .empty;
            for (v.kind.list) |p| {
                const who = if (p.kind == .call) og.core.schema.recordField(p.kind.call, "who") else null;
                const wn = if (who) |w| std.mem.trim(u8, std.mem.trimStart(u8, model_og.exprText(a, w), "@"), "\"") else "";
                for (objs) |o| {
                    if (std.ascii.eqlIgnoreCase(o.name, wn)) break;
                } else try keep.append(a, p);
            }
            if (keep.items.len == 0) continue;
            const l = try a.create(og.script.ir.Expr);
            l.* = .{ .line = 0, .kind = .{ .list = keep.items } };
            v = l;
        }
        try block.print(a, "    {s} = {s};\n", .{ f.name, model_og.exprText(a, v) });
    }
    if (!battle) try block.appendSlice(a, "    entry = \"capt_start\";\n");
    try block.appendSlice(a, "}\n");
    var files: std.ArrayList(OgFile) = .empty;
    try files.append(a, .{ .path = try blockPath(a, name, battle), .data = block.items });
    const keep: []const []const u8 = if (battle) &.{ "grid.cm", "lights.lts", "areas.ar" } else &.{ "walk.wm", "walk2.wm2", "lights.lts" };
    for (try levelAssets(app, a, d.name)) |x| {
        const wanted = std.mem.startsWith(u8, x.path, "background.") or std.mem.eql(u8, x.path, "sprites/1.bin") or for (keep) |k| {
            if (std.mem.eql(u8, x.path, k)) break true;
        } else false;
        if (wanted) try files.append(a, .{ .path = try std.fmt.allocPrint(a, "assets/levels/{s}/{s}", .{ name, x.path }), .data = if (std.mem.eql(u8, x.path, "background.cfg")) try newlevel.cfgFor(a, x.data, name) else x.data });
    }
    if (!battle) {
        const start = d.nearestWalkable(.{ d.bg_size[0] / 2, d.bg_size[1] / 2 }) orelse return error.NoWalkable;
        try files.append(a, .{ .path = try std.fmt.allocPrint(a, "assets/levels/{s}/areas.ar", .{name}), .data = try newlevel.arText(a, start) });
        try files.append(a, .{ .path = try std.fmt.allocPrint(a, "assets/levels/{s}/paths.ap", .{name}), .data = "pathCnt=0\r\n" });
    }
    _ = try writeLevelOg(app, a, name, battle, files.items);
}

/// OpenGorky: level `from` of the project copied whole as `name` (the tree's Duplicate):
/// each text of its folder (its block's name, module and the paths into it the copy's,
/// newlevel.ogCopyText), a battle's dialog (`dialogs/<from>.ogs`, the one it shows by its
/// name) and all its assets; its objects named as the copy's (newlevel.ogObjectNames,
/// `<name>_x`: no name twice across levels) in each of them, and each scene it starts that
/// names them copied as `<name>_<scene>` with them; opened. One undo step (its folders and
/// files deleted).
pub fn copyLevel(app: *App, from: []const u8, name: []const u8) !void {
    if (app.store.root == null) return copyLevelClassic(app, from, name);
    const i = app.levelIndex(from) orelse return error.NotFound;
    const battle = app.levels[i].battle;
    if (!newlevel.validName(name, battle)) return error.BadName;
    _ = app.endPaint();
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const og_src = store_mod.og_src;
    var files: std.ArrayList(OgFile) = .empty;
    const dir = try std.fmt.allocPrint(a, "{s}/{s}/", .{ topOf(battle), from });
    for (app.store.listing(a, og_src, null, true)) |p| {
        if (!std.ascii.startsWithIgnoreCase(p, dir)) continue;
        const f = try app.store.file(og_src, p);
        try files.append(a, .{ .path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ topOf(battle), name, p[dir.len..] }), .data = try newlevel.ogCopyText(a, app.store.text(f), topOf(battle), from, name) });
    }
    if (files.items.len == 0) return error.NoBlock;
    if (app.store.file(og_src, try std.fmt.allocPrint(a, "dialogs/{s}.ogs", .{from}))) |f| {
        try files.append(a, .{ .path = try std.fmt.allocPrint(a, "dialogs/{s}.ogs", .{name}), .data = try newlevel.ogCopyText(a, app.store.text(f), topOf(battle), from, name) });
    } else |_| {}
    var texts: std.ArrayList([]const u8) = .empty;
    for (files.items) |x| try texts.append(a, x.data);
    const names = try newlevel.ogObjectNames(a, texts.items);
    for (files.items) |*x| x.data = try newlevel.ogRenameObjects(a, x.data, names, from, name);
    var scenes: std.ArrayList([]const u8) = .empty;
    const level_files = files.items.len;
    for (0..level_files) |k| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, files.items[k].data, at, "~e\"")) |s| : (at = s + 1) {
            const q = std.mem.indexOfScalarPos(u8, files.items[k].data, s + 3, '"') orelse break;
            const sc = files.items[k].data[s + 3 .. q];
            const new_sc = try std.fmt.allocPrint(a, "{s}_{s}", .{ name, sc });
            for (scenes.items) |x| {
                if (std.ascii.eqlIgnoreCase(x, new_sc)) break;
            } else {
                const f = app.store.file(og_src, try std.fmt.allocPrint(a, "scenes/{s}.ogs", .{sc})) catch continue;
                const st = try newlevel.ogRenameObjects(a, app.store.text(f), names, from, name);
                if (std.mem.eql(u8, st, app.store.text(f))) continue;
                try files.append(a, .{ .path = try std.fmt.allocPrint(a, "scenes/{s}.ogs", .{new_sc}), .data = try sceneNamed(a, st, sc, new_sc) });
                try scenes.append(a, new_sc);
            }
        }
    }
    // The copy starts its own scenes.
    for (scenes.items) |new_sc| {
        const sc = new_sc[name.len + 1 ..];
        for (files.items[0..level_files]) |*x| x.data = try std.mem.replaceOwned(u8, a, x.data, try std.fmt.allocPrint(a, "~e\"{s}\"", .{sc}), try std.fmt.allocPrint(a, "~e\"{s}\"", .{new_sc}));
    }
    for (try levelAssets(app, a, from)) |x| try files.append(a, .{ .path = try std.fmt.allocPrint(a, "assets/levels/{s}/{s}", .{ name, x.path }), .data = if (std.mem.eql(u8, x.path, "background.cfg")) try newlevel.cfgFor(a, x.data, name) else x.data });
    const extra = try writeLevelOg(app, a, name, battle, files.items);
    const ca = app.catalog.arena.allocator();
    for (scenes.items) |sc| app.catalog.scenes.append(ca, .{ .name = ca.dupe(u8, sc) catch continue }) catch {};
    added(app, name, battle, from, extra);
}

/// Scene text `t` (block `scene "old"` or `scene old`) as scene `new`'s.
fn sceneNamed(a: Allocator, t: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const r = try trigger.renameQuoted(a, t, old, new);
    if (!std.mem.eql(u8, r, t)) return r;
    const head = try std.fmt.allocPrint(a, "scene {s} ", .{old});
    const k = std.mem.indexOf(u8, t, head) orelse return t;
    return std.fmt.allocPrint(a, "{s}scene \"{s}\" {s}", .{ t[0..k], new, t[k + head.len ..] });
}

/// Level `from`'s assets as the project has them (`path` under `levels/<from>/`): the
/// installed game's level archives' assets (store.ownAsset: no scripts), each its own one
/// of `src/assets/levels/<from>/` where there is one (unsaved edits too), and the project's
/// own the game has none of.
fn levelAssets(app: *App, a: Allocator, from: []const u8) ![]const OgFile {
    var out: std.ArrayList(OgFile) = .empty;
    const own_dir = try std.fmt.allocPrint(a, "{s}/assets/levels/{s}/", .{ store_mod.og_src, from });
    for ([_][]const u8{ "sprite.dat", "other.dat" }) |part| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ from, part });
        var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.store.dat, path) catch continue;
        defer ar.close(app.io, app.gpa);
        for (ar.entries) |e| {
            var ab: [512]u8 = undefined;
            const sub = store_mod.ownAsset(&ab, app.store.root, path, e.name) orelse continue;
            if (!std.ascii.startsWithIgnoreCase(sub, own_dir) or std.ascii.endsWithIgnoreCase(sub, "vssver.scc")) continue;
            const f = app.store.file(path, e.name) catch continue;
            if (app.store.gone(f)) continue;
            try out.append(a, .{ .path = try a.dupe(u8, sub[own_dir.len..]), .data = app.store.text(f) });
        }
    }
    const root = app.store.root.?;
    var dir = root.openDir(app.io, own_dir, .{ .iterate = true }) catch return out.items;
    defer dir.close(app.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(app.io)) |e| {
        if (e.kind != .file) continue;
        const p = try a.dupe(u8, e.path);
        std.mem.replaceScalar(u8, p, '\\', '/');
        for (out.items) |x| {
            if (std.ascii.eqlIgnoreCase(x.path, p)) break;
        } else try out.append(a, .{ .path = p, .data = try dir.readFileAlloc(app.io, e.path, a, .limited(64 << 20)) });
    }
    return out.items;
}

/// OpenGorky: new level `name`'s files written into the project's `src/` at once (the
/// level list and the worlds read levels from there; the installed game is never written),
/// kept in the history as a save of their own; nothing left on failure. Undo deletes its
/// folders and its files outside them (Store.levelMade: the ones returned, new ones only).
fn writeLevelOg(app: *App, a: Allocator, name: []const u8, battle: bool, files: []const OgFile) ![]const []const u8 {
    const root = app.store.root orelse return error.NotOg;
    const io = app.io;
    if (app.levelIndex(name) != null) return error.LevelExists;
    const block_dir = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ store_mod.og_src, topOf(battle), name });
    const asset_dir = try std.fmt.allocPrint(a, "{s}/assets/levels/{s}", .{ store_mod.og_src, name });
    for ([_][]const u8{ block_dir, asset_dir }) |p| if (root.access(io, p, .{})) |_| return error.LevelExists else |_| {};
    // Its files beside its folders (a scene, a dialog): new ones.
    var extra: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        const sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ store_mod.og_src, f.path });
        if (std.mem.startsWith(u8, sub, block_dir) or std.mem.startsWith(u8, sub, asset_dir)) continue;
        if (root.access(io, sub, .{})) |_| return error.FileExists else |_| {}
        try extra.append(a, f.path);
    }
    errdefer for ([_][]const u8{ block_dir, asset_dir }) |p| root.deleteTree(io, p) catch {};
    errdefer for (extra.items) |p| root.deleteFile(io, std.fmt.allocPrint(a, "{s}/{s}", .{ store_mod.og_src, p }) catch continue) catch {};
    var made: std.ArrayList(savelog.File) = .empty;
    for (files) |f| {
        const sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ store_mod.og_src, f.path });
        if (std.fs.path.dirname(sub)) |dn| try root.createDirPath(io, dn);
        try root.writeFile(io, .{ .sub_path = sub, .data = f.data });
        try made.append(a, .{ .archive = store_mod.og_src, .entry = f.path, .before = null, .after = f.data });
    }
    app.store.logWritten(tx.alloc(a, tx.st_level_step, .{name}), made.items);
    return extra.items;
}

/// Level `name` made (from `from`; OpenGorky: `extra` its files of `src/` outside its
/// folders): in the list, one undo step, shown.
fn added(app: *App, name: []const u8, battle: bool, from: []const u8, extra: []const []const u8) void {
    // The old names stay alive (templates point into them); only the list grows.
    const more = app.gpa.alloc(level.LevelEntry, app.levels.len + 1) catch return;
    @memcpy(more[0..app.levels.len], app.levels);
    more[app.levels.len] = .{ .name = app.gpa.dupe(u8, name) catch return app.gpa.free(more), .battle = battle };
    std.mem.sort(level.LevelEntry, more, {}, struct {
        fn lt(_: void, x: level.LevelEntry, y: level.LevelEntry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    app.gpa.free(app.levels);
    app.levels = more;
    app.current = null;
    app.store.levelMade(name, tx.both(app.frame.allocator(), tx.st_level_step, .{name}), extra) catch {};
    // OpenGorky: the worlds open it by its block (the project's texts read again).
    @import("entry_rules.zig").sync(app);
    if (battle) app.setStatus(tx.st_battle_made, .{ name, from, name }) else app.setStatus(tx.st_location_made, .{ name, from, name });
    app.showLevel(name, if (battle) null else "capt_start");
}

/// Scene `old` named `new`: its `.scr` and `.pts` under the new name, every
/// `"old"` in the scripts starting scenes and in the other scenes as `"new"`.
pub fn renameScene(app: *App, old_in: []const u8, new: []const u8) void {
    const a = app.frame.allocator();
    const old = a.dupe(u8, old_in) catch return;
    if (new.len == 0 or new.len > 40) return app.setStatus(tx.st_scene_bad_name, .{new});
    for (new) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return app.setStatus(tx.st_scene_bad_name, .{new});
    if (std.ascii.eqlIgnoreCase(old, new)) return;
    if (app.sceneIndex(new) != null) return app.setStatus(tx.st_scene_taken, .{new});
    const idx = app.sceneIndex(old);
    if (app.ogLayout()) return renameSceneOg(app, old, new, idx);
    // The files: copies under the new name, the old ones deleted; one undo step.
    app.store.group();
    defer app.store.endGroup("{s} → {s}", .{ old, new });
    var news: std.ArrayList(store_mod.NewFile) = .empty;
    var gone: std.ArrayList(usize) = .empty;
    for ([_][]const u8{ "scr", "pts" }) |ext| {
        const f = app.store.file(common_archive, std.fmt.allocPrint(a, "scriptlets\\{s}.{s}", .{ old, ext }) catch return) catch continue;
        const t = app.gpa.dupe(u8, app.store.text(f)) catch return;
        news.append(a, .{ .archive = common_archive, .entry = std.fmt.allocPrint(a, "scriptlets\\{s}.{s}", .{ new, ext }) catch return, .text = t }) catch return;
        gone.append(a, f) catch return;
    }
    if (news.items.len == 0) return app.failed(error.NoScene);
    _ = app.store.addNew(news.items) catch |err| return app.failed(err);
    app.store.delete(gone.items) catch |err| return app.failed(err);
    // The names in the scripts: level ones starting scenes, then the scenes.
    var files: std.ArrayList(usize) = .empty;
    for (app.catalog.scene_files.items) |sf| files.append(a, app.store.file(sf.archive, sf.entry) catch continue) catch {};
    for (app.catalog.scenes.items) |sc| files.append(a, app.store.file(common_archive, std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{if (std.ascii.eqlIgnoreCase(sc.name, old)) new else sc.name}) catch continue) catch continue) catch {};
    var n: usize = 0;
    for (files.items) |f| {
        const t = trigger.renameQuoted(app.gpa, app.store.text(f), old, new) catch continue;
        if (std.mem.eql(u8, t, app.store.text(f))) {
            app.gpa.free(t);
            continue;
        }
        app.store.replace(f, t) catch {
            app.gpa.free(t);
            continue;
        };
        n += 1;
    }
    if (idx) |i| app.catalog.scenes.items[i].name = app.catalog.arena.allocator().dupe(u8, new) catch return;
    // The scene shown keeps showing it (it is kept by name).
    if (std.ascii.eqlIgnoreCase(app.scene.get(), old)) app.scene.set(new);
    app.setStatus(tx.st_scene_renamed, .{ old, new, n });
}

/// OpenGorky: scene `old`'s block text as `src/scenes/<new>.ogs` (its block named `new`),
/// the old file deleted, every `"old"` of the project's texts (`scene::Start(~e"old")`) as
/// `"new"`; one undo step.
fn renameSceneOg(app: *App, old: []const u8, new: []const u8, idx: ?usize) void {
    const a = app.frame.allocator();
    const og_src = store_mod.og_src;
    const f = app.store.file(og_src, std.fmt.allocPrint(a, "scenes/{s}.ogs", .{old}) catch return) catch |err| return app.failed(err);
    app.store.group();
    defer app.store.endGroup("{s} → {s}", .{ old, new });
    // Its own name: `scene "old"` (or `scene old`) as written.
    var t = trigger.renameQuoted(app.gpa, app.store.text(f), old, new) catch |err| return app.failed(err);
    if (std.mem.eql(u8, t, app.store.text(f))) {
        const head = std.fmt.allocPrint(a, "scene {s} ", .{old}) catch return;
        if (std.mem.indexOf(u8, t, head)) |k| {
            const r = std.fmt.allocPrint(app.gpa, "{s}scene \"{s}\" {s}", .{ t[0..k], new, t[k + head.len ..] }) catch return;
            app.gpa.free(t);
            t = r;
        }
    }
    _ = app.store.addNew(&.{.{ .archive = og_src, .entry = std.fmt.allocPrint(a, "scenes/{s}.ogs", .{new}) catch return, .text = t }}) catch |err| {
        app.gpa.free(t);
        return app.failed(err);
    };
    app.store.delete(&.{f}) catch |err| return app.failed(err);
    var n: usize = 0;
    const own = std.fmt.allocPrint(a, "scenes/{s}.ogs", .{old}) catch return;
    for (app.store.listing(a, og_src, null, true)) |p| {
        if (std.mem.eql(u8, p, own)) continue;
        const g = app.store.file(og_src, p) catch continue;
        const r = trigger.renameQuoted(app.gpa, app.store.text(g), old, new) catch continue;
        if (std.mem.eql(u8, r, app.store.text(g))) {
            app.gpa.free(r);
            continue;
        }
        app.store.replace(g, r) catch {
            app.gpa.free(r);
            continue;
        };
        n += 1;
    }
    if (idx) |i| app.catalog.scenes.items[i].name = app.catalog.arena.allocator().dupe(u8, new) catch return;
    if (std.ascii.eqlIgnoreCase(app.scene.get(), old)) app.scene.set(new);
    @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_scene_renamed, .{ old, new, n });
}

/// Party hero `name` on the open battle at grid point `g` (PlaceActor in restore()).
pub fn addOwn(app: *App, name: []const u8, g: [2]f32) void {
    const d = app.doc orelse return;
    const i = d.addOwn(name, g) catch |err| return switch (err) {
        error.TileNotFree => app.setStatus(tx.st_no_tile, .{}),
        error.HeroThere => app.setStatus(tx.st_hero_there, .{name}),
        else => app.setStatus(tx.st_add_failed, .{ name, err }),
    };
    app.selected = i;
    app.setStatus(tx.st_own_added, .{name});
}

/// Hero entry `e` (catalog) brought onto the open location at `bg`, hidden.
pub fn addHero(app: *App, e: usize, bg: [2]f32) void {
    const d = app.doc orelse return;
    const en = app.catalog.entries.items[e];
    const name = d.addHero(en.archive, en.entry, bg) catch |err| return switch (err) {
        error.NotWalkable => app.setStatus(tx.st_not_walkable, .{}),
        error.HeroThere => app.setStatus(tx.st_hero_there, .{en.id}),
        else => app.setStatus(tx.st_add_failed, .{ en.id, err }),
    };
    app.setStatus(tx.st_hero_added, .{name});
}

/// Hero `name` of the open location deleted with its weapons and the script lines
/// calling it (Ctrl+Z brings them back); the scenes this level starts that still
/// name it are reported (they are shared: not touched).
pub fn removeHero(app: *App, name_in: []const u8) void {
    const d = app.doc orelse return;
    const a = app.frame.allocator();
    const name = a.dupe(u8, name_in) catch return;
    d.removeHero(name) catch |err| return if (err == error.Referenced) app.setStatus(tx.st_hero_referenced, .{ name, d.refFile() }) else app.setStatus(tx.st_remove_failed, .{err});
    app.selected = null;
    // A scene of this level still placing it (PLACE("Medusa",…)): it would play without it.
    const q = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return;
    var scene: ?[]const u8 = null;
    for (app.catalog.scenes.items) |sc| {
        const f = app.store.file(common_archive, std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{sc.name}) catch continue) catch continue;
        if (std.ascii.findIgnoreCase(app.store.text(f), q) == null) continue;
        const sq = std.fmt.allocPrint(a, "\"{s}\"", .{sc.name}) catch continue;
        for (d.levelFiles(a) catch &.{}) |lf_| if (std.ascii.findIgnoreCase(app.store.text(lf_), sq) != null) {
            scene = sc.name;
        };
    }
    if (scene) |sc| app.setStatus(tx.st_hero_removed_scene, .{ name, sc }) else app.setStatus(tx.st_hero_removed, .{name});
    app.reloadLevel();
}

/// Level `name` in `dat/<name>/` from level `d` (its unsaved edits included):
/// `background\<d>.*` and the pixel format under the new name; a location's walk
/// grids and lights, no paths, the entry area and a clean script; a battle's grid
/// (`.cm`), lights and areas, its heroes' places, no enemies (newlevel.zig).
fn makeLevel(app: *App, d: *Doc, name: []const u8) !void {
    const battle = d.isBattle();
    if (!newlevel.validName(name, battle)) return error.BadName;
    const io = app.io;
    const dat = app.store.dat;
    if (dat.access(io, name, .{})) |_| return error.LevelExists else |_| {}
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sprites = try copySprites(app, a, d.name, name);
    var other: std.ArrayList(og.formats.archive.File) = .empty;
    // other.dat: a location's walk grids and lights (no paths, a new entry area); a
    // battle's grid, lights and areas; a clean script.
    const copied: []const []const u8 = if (battle) &.{ "cm", "lts", "ar" } else &.{ "wm", "wm2", "lts" };
    for (copied) |ext| {
        const f = app.store.file(d.level_archive, try std.fmt.allocPrint(a, "{s}.{s}", .{ d.name, ext })) catch continue;
        try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.{s}", .{ name, ext }), .data = app.store.text(f) });
    }
    const lev = try app.store.file(d.level_archive, try std.fmt.allocPrint(a, "{s}.lev", .{d.name}));
    if (battle) {
        // Its fighters (each `.ftr` an enemy object) stay out of the new one.
        var enemies: std.ArrayList([]const u8) = .empty;
        for (try d.levelFiles(a)) |f| {
            const e = app.store.files.items[f].entry;
            if (std.ascii.endsWithIgnoreCase(e, ".ftr")) try enemies.append(a, e[0 .. e.len - 4]);
        }
        try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.lev", .{name}), .data = try newlevel.battleLevText(a, app.store.text(lev), enemies.items) });
        return writeLevel(app, a, name, sprites, other.items);
    }
    const centre: [2]f32 = .{ d.bg_size[0] / 2, d.bg_size[1] / 2 };
    const start = d.nearestWalkable(centre) orelse return error.NoWalkable;
    var lev_text = try newlevel.levText(a, app.store.text(lev), d.name);
    // The template's character size and walk speed from its `.var` (not copied), into
    // initCamera(), which the exe reads them after (0x4218e9); one set there stays.
    if (app.store.file(common_archive, try std.fmt.allocPrint(a, "variables\\{s}.var", .{d.name}))) |vf| {
        for ([_][]const u8{ "actor_scale", "speed_scale" }) |k| {
            if (newlevel.cameraVar(lev_text, k) != null) continue;
            const v = newlevel.varValue(app.store.text(vf), k) orelse continue;
            lev_text = try newlevel.setCameraVar(a, lev_text, k, v);
        }
    } else |_| {}
    try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.lev", .{name}), .data = lev_text });
    try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.ar", .{name}), .data = try newlevel.arText(a, start) });
    try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.ap", .{name}), .data = "pathCnt=0\r\n" });
    return writeLevel(app, a, name, sprites, other.items);
}

/// Classic: level `from` copied whole as `name` (the tree's Duplicate): both its archives
/// (its objects with their names, scripts, walk maps, areas, paths, lights, sprites), its
/// own files `<from>.*` and `background\\<from>.*` named as the copy's (the `.cfg` naming
/// its picture), and, as the Store's new files (written by Save), its variables
/// (`variables\\<from>.var`), its dialogue `<from>.dlg` (a battle's, shown by the level's
/// name) and that one's recordings (`<from>_xx_nn.wav`); unsaved edits included. The
/// game's other files untouched. Opened; one undo step.
fn copyLevelClassic(app: *App, from: []const u8, name: []const u8) !void {
    const i = app.levelIndex(from) orelse return error.NotFound;
    const battle = app.levels[i].battle;
    if (!newlevel.validName(name, battle)) return error.BadName;
    if (app.store.dat.access(app.io, name, .{})) |_| return error.LevelExists else |_| {}
    _ = app.endPaint();
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var parts: [2]std.ArrayList(og.formats.archive.File) = .{ .empty, .empty };
    for ([_][]const u8{ "sprite.dat", "other.dat" }, &parts) |part, *out| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ from, part });
        var ar = try og.formats.archive.Archive.open(app.io, app.gpa, app.store.dat, path);
        defer ar.close(app.io, app.gpa);
        for (ar.entries) |e| {
            if (e.name.len == 0 or std.ascii.endsWithIgnoreCase(e.name, "vssver.scc")) continue;
            const f = app.store.file(path, e.name) catch continue;
            if (app.store.gone(f)) continue;
            const dir = if (std.ascii.startsWithIgnoreCase(e.name, "background\\")) "background\\" else "";
            const own = e.name.len > dir.len + from.len and std.ascii.startsWithIgnoreCase(e.name[dir.len..], from) and e.name[dir.len + from.len] == '.';
            const new_name = if (own) try std.fmt.allocPrint(a, "{s}{s}{s}", .{ dir, name, e.name[dir.len + from.len ..] }) else try a.dupe(u8, e.name);
            const cfg = dir.len > 0 and std.ascii.endsWithIgnoreCase(e.name, ".cfg");
            try out.append(a, .{ .name = new_name, .data = if (cfg) try newlevel.cfgFor(a, app.store.text(f), name) else app.store.text(f) });
        }
    }
    // The common archives' files of the level, under the copy's name.
    var news: std.ArrayList(store_mod.NewFile) = .empty;
    const own_files = [_]struct { []const u8, []const u8 }{ .{ common_archive, "variables\\{s}.var" }, .{ "common/lang.dat", "{s}.dlg" } };
    inline for (own_files) |o| if (app.store.file(o[0], try std.fmt.allocPrint(a, o[1], .{from}))) |f| {
        if (!app.store.gone(f)) try news.append(a, .{ .archive = o[0], .entry = try std.fmt.allocPrint(a, o[1], .{name}), .text = try app.gpa.dupe(u8, app.store.text(f)) });
    } else |_| {};
    if (news.items.len > 0 and std.ascii.endsWithIgnoreCase(news.items[news.items.len - 1].entry, ".dlg")) {
        const voices = @import("voices.zig");
        var pb: [80]u8 = undefined;
        const old_prefix = try a.dupe(u8, try og.formats.dialog.voicePrefix(&pb, from));
        const new_prefix = try og.formats.dialog.voicePrefix(&pb, name);
        // `<prefix>xx_nn.wav` only (not another dialogue's with a longer name).
        for (voices.names(app, a, old_prefix)) |v| if (v.len == old_prefix.len + "xx_nn.wav".len) {
            const bytes = voices.bytesOf(app, a, v) orelse continue;
            try news.append(a, .{ .archive = voices.archive_path, .entry = try std.fmt.allocPrint(a, "{s}{s}", .{ new_prefix, v[old_prefix.len..] }), .text = try app.gpa.dupe(u8, bytes) });
        };
    }
    try writeLevel(app, a, name, parts[0].items, parts[1].items);
    app.store.group();
    defer app.store.endGroup("{s}", .{tx.alloc(a, tx.st_level_step, .{name})});
    if (news.items.len > 0) _ = app.store.addNew(news.items) catch |err| {
        for (news.items) |n| app.gpa.free(n.text);
        return err;
    };
    added(app, name, battle, from, &.{});
}

/// Level `from`'s `sprite.dat` for level `name`: the pixel format and every
/// `background\<from>.*` renamed (its unsaved edits included).
pub fn copySprites(app: *App, a: Allocator, from: []const u8, name: []const u8) ![]og.formats.archive.File {
    const io = app.io;
    var sprites: std.ArrayList(og.formats.archive.File) = .empty;
    const tpl_sprites = try std.fmt.allocPrint(a, "{s}/sprite.dat", .{from});
    {
        var ar = try og.formats.archive.Archive.open(io, app.gpa, app.store.dat, tpl_sprites);
        defer ar.close(io, app.gpa);
        const prefix = try std.fmt.allocPrint(a, "background\\{s}.", .{from});
        for (ar.entries) |*e| {
            const ext = if (std.ascii.startsWithIgnoreCase(e.name, prefix)) e.name[prefix.len..] else if (std.ascii.eqlIgnoreCase(e.name, "1.bin")) "" else continue;
            const f = try app.store.file(tpl_sprites, e.name);
            try sprites.append(a, .{
                .name = if (ext.len == 0) "1.bin" else try std.fmt.allocPrint(a, "background\\{s}.{s}", .{ name, ext }),
                // A location's `.cfg` names its picture (`bkg`, `krz`): the copy's own.
                .data = if (std.ascii.eqlIgnoreCase(ext, "cfg")) try newlevel.cfgFor(a, app.store.text(f), name) else app.store.text(f),
            });
        }
    }
    if (sprites.items.len < 2) return error.NoTemplate;
    return sprites.items;
}

/// `dat/<name>/sprite.dat` and `other.dat` with these files: empty archives (their closing empty entry) filled as the
/// editor's saves are; nothing left on failure.
fn writeLevel(app: *App, a: Allocator, level_name: []const u8, sprites: []const og.formats.archive.File, other: []const og.formats.archive.File) !void {
    try writeArchives(app, a, level_name, sprites, other);
    // In the history as saved: Package mod takes the new archives.
    var made: std.ArrayList(savelog.File) = .empty;
    for ([_]struct { []const u8, []const og.formats.archive.File }{ .{ "sprite.dat", sprites }, .{ "other.dat", other } }) |part| {
        const ar = try std.fmt.allocPrint(a, "{s}/{s}", .{ level_name, part[0] });
        for (part[1]) |f| if (f.name.len > 0) try made.append(a, .{ .archive = ar, .entry = f.name, .before = null, .after = f.data });
    }
    app.store.logWritten(tx.alloc(a, tx.st_level_step, .{level_name}), made.items);
}

/// `writeLevel`'s archives alone (not in the history: the test room's).
pub fn writeArchives(app: *App, a: Allocator, level_name: []const u8, sprites: []const og.formats.archive.File, other: []const og.formats.archive.File) !void {
    // An OpenGorky project's `dat` is the installed game's: never written (its levels: writeLevelOg).
    if (app.store.root != null) return error.InstalledGame;
    const io = app.io;
    const dat = app.store.dat;
    const name = level_name;
    try dat.createDirPath(io, name);
    errdefer dat.deleteTree(io, name) catch {};
    const empty = try og.formats.archive.build(a, &.{.{ .name = "", .data = "" }});
    for ([_]struct { []const u8, []const og.formats.archive.File }{ .{ "sprite.dat", sprites }, .{ "other.dat", other } }) |part| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ name, part[0] });
        try dat.writeFile(io, .{ .sub_path = path, .data = empty });
        try og.formats.archive.rewrite(io, app.gpa, dat, path, part[1]);
    }
}
