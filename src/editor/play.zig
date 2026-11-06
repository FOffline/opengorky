//! Playing in the port: the open level (or a scene on it) in the viewer, the viewer's
//! program found or asked for; a scene run headless for the Debug view. An OpenGorky
//! project of OG Script is built first (compose/og/build.zig) and played from its
//! package `dist/<id>.ogp`; its errors are listed (checkpanel.zig) and nothing runs.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const og = @import("opengorky");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const FileAsk = app_mod.FileAsk;

/// The open level in the port (the viewer beside the editor, or the game's app on
/// macOS), straight in with the starting party; the edits saved first (it reads
/// the folder).
pub fn playLevel(app: *App) void {
    const d = app.doc orelse return;
    playIn(app, d.name, null);
}

/// Scene `name` run on level `level` to its end without a window (saved first: the
/// run reads the game's files), its report kept for the Debug view.
pub fn testScene(app: *App, level_name: []const u8, name: []const u8) void {
    if (!app.saveFirst()) return;
    var models = og.compose.models.open(app.io, app.gpa, app.dat, null) catch |err| return app.failed(err);
    defer models.deinit();
    const opener: og.loaders.world.Opener = .{ .io = app.io, .dat = app.dat };
    const rep = og.scene_check.run(app.io, app.gpa, opener.factory(), &models, level_name, name) catch |err| return app.failed(err);
    app.dropReport();
    app.scenes.report = .{ .name = app.gpa.dupe(u8, name) catch return, .level = app.gpa.dupe(u8, level_name) catch return, .report = rep };
    app.setStatus(tx.st_scene_run, .{ name, rep.result, rep.ticks });
}

/// Level `level` in the port (saved first), scene `scene` started as it loads
/// (the console's `scene`, Space skips a line there).
pub fn playIn(app: *App, level_name: []const u8, scene: ?[]const u8) void {
    launch(app, level_name, scene, null);
}

/// An OpenGorky project's test room in the port: battle-room `room` built into
/// `dist/play.ogp` (compose/og/build.zig `Start.test_room`).
pub fn playRoom(app: *App, room: og.compose.og_build.Start) void {
    launch(app, "", null, room);
}

fn launch(app: *App, level_name: []const u8, scene: ?[]const u8, room: ?og.compose.og_build.Start) void {
    if (!app.saveFirst()) return;
    var pb: [1200]u8 = undefined;
    // The one chosen in the settings, else the one found beside the editor.
    const viewer = blk: {
        if (app.settings.viewerPath()) |vp| {
            const p = @import("settings.zig").viewerProgram(&pb, vp, exe);
            Io.Dir.cwd().access(app.io, p, .{}) catch {
                app.setStatus(tx.st_viewer_missing, .{p});
                return askViewer(app, level_name, scene);
            };
            break :blk p;
        }
        break :blk nearViewer(app, &pb) orelse {
            app.setStatus(tx.st_no_viewer, .{});
            return askViewer(app, level_name, scene);
        };
    };
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    var game = app.game_dir;
    var level = level_name;
    var built: ?og.compose.og_build.Report = null;
    var ab: [160]u8 = undefined;
    // Classic: the level's archive, straight in; OG Script: the package and its start (the viewer's --start).
    var where: [2][]const u8 = .{ std.fmt.bufPrint(&ab, "{s}/sprite.dat", .{level}) catch return, "--level" };
    if (app.project.format == .ogs) {
        const start = room orelse og.compose.og_build.Start{ .location = .{ .level = level_name } };
        const r = build(app, arena.allocator(), start) orelse return;
        game = std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ app.game_dir, r.package }) catch return;
        level = r.level;
        built = r;
        where = .{ "--start", start.text(&ab) catch return };
    }
    var sb: [96]u8 = undefined;
    const scene_cmd = if (scene) |n| std.fmt.bufPrint(&sb, "playscene {s}", .{n}) catch return else "";
    const base = [_][]const u8{ viewer, game, where[0], where[1], "--heroes", "--play" };
    const with_scene = base ++ [_][]const u8{ "--dev", "--console", scene_cmd, "--console", "close" };
    // shortcut: the child is never waited for (it outlives the editor or ends on its own); keep its handle if the editor ever needs to stop it.
    _ = std.process.spawn(app.io, .{
        .argv = if (scene != null) &with_scene else &base,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return app.setStatus(tx.st_play_failed, .{err});
    if (built) |r| return app.setStatus(tx.st_playing_built, .{ r.package, r.rebuilt, r.entries, level });
    app.setStatus(tx.st_playing, .{level_name});
}

/// The OG build of the open project with start `start` (in `a`); errors: listed in the
/// check window, null.
fn build(app: *App, a: std.mem.Allocator, start_in: ?og.compose.og_build.Start) ?og.compose.og_build.Report {
    // A battle (a test room too): the heroes go in with the test kit (.og/testkit.txt).
    const start = start_in;
    const kit: ?og.compose.og_build.Kit = if (start != null) (@import("testkit.zig").buildKit(app, a) catch |err| return fail(app, err)) else null;
    var dir = Io.Dir.cwd().openDir(app.io, app.game_dir, .{}) catch |err| return fail(app, err);
    defer dir.close(app.io);
    const v = og.formats.manifest.engine_version;
    const engine = std.fmt.allocPrint(a, "{d}.{d}", .{ v[0], v[1] }) catch |err| return fail(app, err);
    const r = og.compose.og_build.build(app.io, a, dir, .{ .engine = engine, .start = start, .kit = kit }) catch |err| return fail(app, err);
    if (r.errors() == 0) return r;
    @import("checkpanel.zig").showBuild(app, r.problems);
    app.setStatus(tx.st_build_errors, .{r.errors()});
    return null;
}

fn fail(app: *App, err: anyerror) ?og.compose.og_build.Report {
    app.setStatus(tx.st_build_failed, .{err});
    return null;
}

/// An OpenGorky project's test room for `character` (`characters::grandma`) built into
/// `dist/play.ogp` (its edits saved first), not played: what "Play" would start
/// (`--test-room` of a script). error.NotBuilt: a save or the build failed (the status says).
pub fn buildRoom(app: *App, character: []const u8) !void {
    if (!app.saveFirst()) return error.NotBuilt;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const r = build(app, arena.allocator(), .{ .test_room = .{ .character = character, .battle = @import("testroom.zig").ogBattle(app) } }) orelse return error.NotBuilt;
    app.setStatus(tx.st_built, .{ r.package, r.rebuilt, r.entries });
}

/// "Build package": the project saved and packed as `dist/<id>.ogp`, what players get (no
/// start, no test kit; not played); its problems in the check window.
pub fn buildPackage(app: *App) void {
    if (!app.saveFirst()) return;
    rebuild(app);
}

/// The project's package (`dist/<id>.ogp`) shown in the system's file manager (Finder,
/// Explorer; Linux: its folder opened).
pub fn revealPackage(app: *App) void {
    var pb: [1200]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/dist/{s}.ogp", .{ app.game_dir, app.project.id() }) catch return;
    var sb: [1220]u8 = undefined;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", "-R", path },
        .windows => &.{ "explorer", std.fmt.bufPrint(&sb, "/select,{s}", .{path}) catch return },
        else => &.{ "xdg-open", std.fs.path.dirname(path) orelse return },
    };
    _ = std.process.spawn(app.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| app.failed(err);
}

/// The project's package is there (built before).
pub fn packageBuilt(app: *App) bool {
    var pb: [1200]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/dist/{s}.ogp", .{ app.game_dir, app.project.id() }) catch return false;
    Io.Dir.cwd().access(app.io, path, .{}) catch return false;
    return true;
}

/// The check window's «again» on a build's problems: the project built again (no start,
/// no play); still failing, its problems listed anew.
pub fn rebuild(app: *App) void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const r = build(app, arena.allocator(), null) orelse return;
    @import("checkpanel.zig").close(app);
    app.setStatus(tx.st_built, .{ r.package, r.rebuilt, r.entries });
}

pub fn onViewer(app: *App, _: FileAsk, path: []const u8) !void {
    app.settings.setViewerPath(path);
    app.saveSettings();
}

/// The port's file asked for at once, the play run after it's chosen.
fn askViewer(app: *App, level_name: []const u8, scene: ?[]const u8) void {
    var pp: @TypeOf(app.play_pending.?) = .{};
    const sc = scene orelse "";
    if (level_name.len + sc.len > pp.buf.len) return;
    @memcpy(pp.buf[0..level_name.len], level_name);
    @memcpy(pp.buf[level_name.len..][0..sc.len], sc);
    pp.level = level_name.len;
    if (scene != null) pp.scene = sc.len;
    app.play_pending = pp;
    app.askFile(.{ .kind = .program, .run = onViewerPlay });
}

fn onViewerPlay(app: *App, ask: FileAsk, path: []const u8) !void {
    try onViewer(app, ask, path);
    var pp = app.play_pending orelse return;
    app.play_pending = null;
    playIn(app, pp.buf[0..pp.level], if (pp.scene) |n| pp.buf[pp.level..][0..n] else null);
}

const exe = if (builtin.os.tag == .windows) "opengorky-viewer.exe" else "opengorky-viewer";

/// The port beside the editor: in its folder (zig-out/bin), in the folder `opengorky`
/// next to the editor's (the Windows and Linux packages; Windows names it OpenGorky.exe),
/// else the macOS game app next to the editor's; null: none there.
pub fn nearViewer(app: *App, pb: []u8) ?[]const u8 {
    var db: [1024]u8 = undefined;
    const dir = db[0 .. std.process.executableDirPath(app.io, &db) catch return null];
    const near = if (builtin.os.tag == .windows)
        .{ "{s}/opengorky-viewer.exe", "{s}/OpenGorky.exe", "{s}/../opengorky/OpenGorky.exe" }
    else
        .{ "{s}/opengorky-viewer", "{s}/../opengorky/opengorky-viewer", "{s}/../../../OpenGorky.app/Contents/MacOS/opengorky-viewer" };
    inline for (near) |fmt| {
        if (std.fmt.bufPrint(pb, fmt, .{dir})) |p| {
            if (Io.Dir.cwd().access(app.io, p, .{})) return p else |_| {}
        } else |_| {}
    }
    return null;
}
