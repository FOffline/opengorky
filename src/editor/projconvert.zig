//! "Convert to OpenGorky…": the open Classic project
//! converted into a new folder by the converter gorky-tool `convert` runs
//! (compose/convert.zig, the same options: the same bytes), then built (`dist/`, as
//! gorky-tool `build`), and the editor started anew on it (main.zig `session`, as a folder
//! picked in the settings). One window, by phase: the folder asked (a new one beside the
//! game; one with anything in it refused), the run's progress (on a thread, Cancel), the
//! failure's report (the step, the error, the log) or, in the new project's session, the
//! summary (the counts, the converter's lines, the build). The Classic project and the
//! installed game are never written.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const convert = og.compose.convert;

const smp = std.heap.smp_allocator;

pub const Phase = enum { ask, running, failed, done };

/// What the window counts: the converter's steps, then the build of `dist/`.
const build_step = std.enums.values(convert.Step).len;
const step_names = [_]tx.Msg{ tx.cv_read, tx.cv_locations, tx.cv_scenes, tx.cv_dialogs, tx.cv_rules, tx.cv_assets, tx.cv_write, tx.cv_build };

comptime {
    std.debug.assert(step_names.len == build_step + 1);
}

pub const Window = struct {
    /// Its texts; while the run goes, only the run's thread allocates in it.
    arena: std.heap.ArenaAllocator,
    phase: Phase = .ask,
    /// The new project's folder.
    out: []const u8 = "",
    /// The folder has something in it: refused.
    full: bool = false,
    /// Closed at the next frame's start (its texts are drawn after the frame that closes it).
    closing: bool = false,
    /// The run's inputs, made on the main thread: the Classic project, the installed game's
    /// real path (the manifest's), the rules in force.
    game: []const u8 = "",
    game_real: []const u8 = "",
    rules: []const og.formats.archive.File = &.{},
    step: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    /// The run's error (failed) and the step it stopped in.
    err: ?anyerror = null,
    /// The progress, a line a step (and a tenth of a counted one), as gorky-tool prints it.
    log: std.ArrayList(u8) = .empty,
    last_tenth: usize = std.math.maxInt(usize),
    /// Done: the counts, the converter's lines, the build's result and problems.
    lines: std.ArrayList([]const u8) = .empty,
    /// Done: the summary on top — the converter's counts, the
    /// package's entries, and the notes and problems counted a line per kind.
    report: convert.Report = .{},
    entries: usize = 0,
    groups: Groups = .{},
    /// The full list (`lines`) unfolded.
    all: bool = false,
};

/// The converter's notes and the build's problems, counted by kind (the summary's lines).
const Groups = struct {
    /// Converter notes: a file it could not convert (left out).
    notes: usize = 0,
    /// A look naming an animation its model's `.ani` lacks (the original game's, harmless).
    anims: usize = 0,
    warnings: usize = 0,
    errors: usize = 0,

    fn add(g: *Groups, p: og.compose.og_build.Problem) void {
        if (!p.warning) g.errors += 1 else if (std.mem.indexOf(u8, p.message, ": no animation ") != null) g.anims += 1 else g.warnings += 1;
    }
};

/// The window that outlives its session: the summary, shown by the new project's (`adopt`).
var carried: ?*Window = null;

/// "Convert to OpenGorky…": the window asking the folder; unsaved edits are saved
/// or undone first (the converter reads the saved project).
pub fn ask(app: *App) void {
    if (app.store.dirty()) return app.setStatus(tx.st_save_first, .{});
    if (app.proj_convert != null or app.game_dir.len == 0) return;
    const w = smp.create(Window) catch return;
    w.* = .{ .arena = .init(smp) };
    w.out = defaultFolder(app.io, w.arena.allocator(), app.game_dir, convert.game_title) catch "";
    app.proj_convert = w;
}

/// `<game>/../<title>` (the converted game's: `Gorky 17 (OpenGorky)`), else the first of
/// `<title>-2`, `-3`… that is new or empty.
fn defaultFolder(io: Io, a: Allocator, game: []const u8, title: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(game) orelse ".";
    var k: usize = 1;
    while (true) : (k += 1) {
        const p = if (k == 1) try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, title }) else try std.fmt.allocPrint(a, "{s}/{s}-{d}", .{ parent, title, k });
        if (empty(io, p) or k == 99) return p;
    }
}

/// Folder `path` is missing or has nothing in it.
fn empty(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return err == error.FileNotFound;
    defer d.close(io);
    var it = d.iterate();
    return (it.next(io) catch return false) == null;
}

fn onPicked(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    const w = app.proj_convert orelse return;
    if (w.phase != .ask) return;
    w.out = try w.arena.allocator().dupe(u8, path);
    w.full = !empty(app.io, w.out);
}

/// The folder chosen as the new project's (`--convert-to`; the window's Choose): refused
/// (`full`) if it has anything.
pub fn choose(app: *App, path: []const u8) !void {
    try onPicked(app, undefined, path);
}

/// The run started on its thread (the folder refused: `full`, nothing started).
pub fn begin(app: *App) !void {
    const w = app.proj_convert orelse return error.NotAsked;
    if (w.phase != .ask) return;
    w.full = !empty(app.io, w.out);
    if (w.full) return error.FolderNotEmpty;
    const a = w.arena.allocator();
    w.game = try a.dupe(u8, app.game_dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var g = try Io.Dir.cwd().openDir(app.io, app.game_dir, .{});
    defer g.close(app.io);
    w.game_real = try a.dupe(u8, buf[0..try g.realPath(app.io, &buf)]);
    // As gorky-tool (tool/common.zig openDat): the core read, then the rules in force dumped.
    og.loaders.loadCore(app.io, app.dat);
    w.rules = try og.compose.rulesFiles(a);
    w.thread = try std.Thread.spawn(.{}, run, .{ w, app.io });
    w.phase = .running;
}

fn run(w: *Window, io: Io) void {
    work(w, io) catch |err| {
        w.err = err;
    };
    w.finished.store(true, .release);
}

fn work(w: *Window, io: Io) !void {
    const a = w.arena.allocator();
    const cwd = Io.Dir.cwd();
    var root = try cwd.openDir(io, w.game, .{});
    defer root.close(io);
    var dat = try root.openDir(io, "dat", .{ .iterate = true });
    defer dat.close(io);
    try cwd.createDirPath(io, w.out);
    var out = try cwd.openDir(io, w.out, .{ .iterate = true });
    defer out.close(io);
    var pa: std.heap.ArenaAllocator = .init(smp);
    defer pa.deinit();
    const r = convert.run(io, pa.allocator(), dat, out, .{ .id = convert.game_id, .title = convert.game_title, .game = w.game_real, .rules = w.rules }, .{ .ctx = w, .on = tell, .stop = &w.stop }) catch |err| {
        // Nothing half-made stays (the folder was empty: all in it is the run's).
        clear(io, a, out);
        return err;
    };
    var stats: Io.Writer.Allocating = .init(a);
    try convert.statsLine(&stats.writer, &r);
    try w.lines.append(a, stats.written());
    for (r.lines.items) |l| try w.lines.append(a, try a.dupe(u8, l));
    w.report = r;
    // Their texts are the run's arena's (freed below): only the counts are kept.
    w.report.lines = .empty;
    w.report.project = .{ .manifest = .{ .id = "" }, .modules = &.{} };
    w.groups.notes = r.lines.items.len;
    // dist/ built at once (as gorky-tool build).
    w.step.store(build_step, .monotonic);
    w.done.store(0, .monotonic);
    w.total.store(0, .monotonic);
    const v = og.formats.manifest.engine_version;
    const b = try og.compose.og_build.build(io, pa.allocator(), out, .{ .engine = try std.fmt.allocPrint(pa.allocator(), "{d}.{d}", .{ v[0], v[1] }) });
    if (b.errors() > 0) try w.lines.append(a, try std.fmt.allocPrint(a, "FAIL build: {d} errors, no package written", .{b.errors()})) else try w.lines.append(a, try std.fmt.allocPrint(a, "OK   build: {s}, {d} entries, {d} rebuilt", .{ b.package, b.entries, b.rebuilt }));
    w.entries = b.entries;
    for (b.problems) |p| w.groups.add(p);
    for (b.problems) |p| try w.lines.append(a, try std.fmt.allocPrint(a, "{s}:{d}: {s}: {s}", .{ p.file, p.line, if (p.warning) "warning" else "error", p.message }));
}

/// The converter's progress kept for the window (atomics) and logged as gorky-tool prints it.
fn tell(ctx: ?*anyopaque, step: convert.Step, done: usize, total: usize) void {
    const w: *Window = @ptrCast(@alignCast(ctx.?));
    w.step.store(@backingInt(step), .monotonic);
    w.done.store(done, .monotonic);
    w.total.store(total, .monotonic);
    const tenth = if (total > 0) done * 10 / total else done / 25;
    if (tenth == w.last_tenth and done != total) return;
    w.last_tenth = tenth;
    const a = w.arena.allocator();
    if (total > 0) w.log.print(a, "convert: {t} {d}/{d}\n", .{ step, done, total }) catch {} else w.log.print(a, "convert: {t} {d}\n", .{ step, done }) catch {};
}

/// Everything in `out` removed (the run's own: it started empty).
fn clear(io: Io, a: Allocator, out: Io.Dir) void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = out.iterate();
    while (it.next(io) catch null) |e| names.append(a, a.dupe(u8, e.name) catch continue) catch {};
    for (names.items) |n| out.deleteTree(io, n) catch {};
}

/// Each frame: a closed window freed, a finished run joined — failed: its report; done:
/// the editor started anew on the new project, the window carried into its session.
pub fn poll(app: *App) void {
    const w = app.proj_convert orelse return;
    if (w.closing) return drop(app);
    if (w.phase != .running or !w.finished.load(.acquire)) return;
    w.thread.join();
    w.phase = if (w.err != null) .failed else .done;
    if (w.err) |err| {
        if (err == error.Canceled) {
            app.setStatus(tx.st_cv_canceled, .{});
            return drop(app);
        }
        app.setStatus(tx.st_cv_failed, .{err});
        return;
    }
    carried = w;
    app.proj_convert = null;
    app.reopen(w.out);
}

/// The run waited for (scripted, the editor closing; the window stays to `poll`).
pub fn wait(app: *App) void {
    const w = app.proj_convert orelse return;
    if (w.phase == .running) {
        while (!w.finished.load(.acquire)) std.Thread.yield() catch {};
        poll(app);
    }
}

/// The new project's session shows the summary carried from the one that converted.
pub fn adopt(app: *App) void {
    const w = carried orelse return;
    carried = null;
    app.proj_convert = w;
    if (w.lines.items.len > 0) app.setStatus(tx.st_cv_done, .{w.lines.items[0]});
}

/// Freed (a running conversion stopped and waited for first: the editor closing).
pub fn drop(app: *App) void {
    const w = app.proj_convert orelse return;
    if (w.phase == .running) {
        w.stop.store(true, .monotonic);
        w.thread.join();
    }
    app.proj_convert = null;
    w.arena.deinit();
    smp.destroy(w);
}

pub fn window(app: *App, a: Allocator, w: *Window) void {
    const title: tx.Msg = switch (w.phase) {
        .ask, .running => tx.cv_title,
        .failed => tx.cv_failed_title,
        .done => tx.cv_done_title,
    };
    const report = w.phase == .failed or w.phase == .done;
    const hit = gui.modal(app, "projconvert", .{ .w = if (report) lay.width.window else lay.width.dialog, .h = if (report) lay.height.window else null, .bg = theme.bg, .title = tx.get(title), .icon = .package, .icon_color = if (w.phase == .failed) theme.warn else theme.accent, .close = report, .shade = true });
    if (hit == .close) w.closing = true;
    gui.modalBody(lay.space.md);
    switch (w.phase) {
        .ask => askBody(app, w),
        .running => runBody(app, a, w),
        .failed, .done => reportBody(app, a, w),
    }
    clay.close();
    clay.close();
}

fn askBody(app: *App, w: *Window) void {
    gui.txtWrap(tx.get(tx.cv_intro), .body, theme.text, font_mod.regular);
    gui.txt(tx.get(tx.cv_folder), .label, theme.dim, font_mod.bold);
    gui.row(lay.space.sm);
    gui.txtClip(w.out, .label, if (w.full) theme.warn else theme.text, font_mod.regular);
    gui.spacer();
    if (gui.smallButton(app, clay.id("cv_pick"), tx.get(tx.s_pick_game))) app.askFile(.{ .kind = .folder, .run = onPicked });
    clay.close();
    if (w.full) gui.warning(tx.get(tx.cv_not_empty)) else gui.note(tx.get(tx.cv_folder_hint));
    gui.row(lay.space.sm);
    gui.spacer();
    if (gui.toolButton(app, "cv_no", .x, tx.get(tx.cancel), false, false)) w.closing = true;
    if (gui.toolButton(app, "cv_yes", .package, tx.get(tx.cv_go), false, true)) begin(app) catch |err| if (err != error.FolderNotEmpty) app.setStatus(tx.st_cv_failed, .{err});
    clay.close();
}

fn runBody(app: *App, a: Allocator, w: *Window) void {
    const k: usize = @min(w.step.load(.monotonic), build_step);
    const done = w.done.load(.monotonic);
    const total = w.total.load(.monotonic);
    gui.txt(tx.alloc(a, tx.cv_step, .{ k + 1, build_step + 1, tx.get(step_names[k]) }), .label, theme.text, font_mod.bold);
    // The whole run's share: the steps before, and this one's (an uncounted step: none).
    const part: f32 = if (total > 0) @as(f32, @floatFromInt(@min(done, total))) / @as(f32, @floatFromInt(total)) else 0;
    const share = (@as(f32, @floatFromInt(k)) + part) / @as(f32, @floatFromInt(build_step + 1));
    const track = lay.space.sm;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(track) } }, .backgroundColor = theme.field_border, .cornerRadius = clay.radius(track / 2) });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = .{ .type = ui.CLAY__SIZING_TYPE_PERCENT, .size = .{ .percent = std.math.clamp(share, 0, 1) } }, .height = clay.fixed(track) } }, .backgroundColor = theme.accent, .cornerRadius = clay.radius(track / 2) });
    clay.close();
    gui.row(lay.space.sm);
    if (total > 0) gui.txt(tx.alloc(a, tx.cv_count, .{ done, total }), .caption, theme.dim, font_mod.regular) else if (done > 0) gui.txt(tx.alloc(a, tx.cv_count_open, .{done}), .caption, theme.dim, font_mod.regular);
    gui.spacer();
    if (w.stop.load(.monotonic)) {
        gui.txt(tx.get(tx.cv_canceling), .caption, theme.warn, font_mod.regular);
    } else if (gui.toolButton(app, "cv_cancel", .x, tx.get(tx.cancel), false, false)) w.stop.store(true, .monotonic);
    clay.close();
    gui.note(tx.get(tx.cv_running_hint));
}

fn reportBody(app: *App, a: Allocator, w: *Window) void {
    if (w.phase == .failed) {
        const k: usize = @min(w.step.load(.monotonic), build_step);
        gui.txtWrap(tx.alloc(a, tx.cv_failed_at, .{ tx.get(step_names[k]), w.err orelse error.Unknown }), .body, theme.warn, font_mod.bold);
        gui.note(tx.get(tx.cv_failed_hint));
    } else {
        gui.txtWrap(tx.alloc(a, tx.cv_done_at, .{w.out}), .body, theme.text, font_mod.bold);
        gui.note(tx.get(tx.cv_done_hint));
        summary(a, w);
        if (gui.folderRow(app, clay.id("cv_all"), 0, w.all, .file_text, false, tx.get(tx.cv_all), false, w.lines.items.len, a)) w.all = !w.all;
        clay.close();
        if (!w.all) return;
    }
    clay.openScroll(.{ .id = clay.id("cv_log"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.md, lay.space.sm), .childGap = lay.space.xs }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(lay.radius.md) });
    if (w.phase == .failed) {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, w.log.items, "\n"), '\n');
        while (it.next()) |l| gui.txtWrap(l, .caption, theme.dim, font_mod.regular);
    } else for (w.lines.items, 0..) |l, i| gui.txtWrap(l, .caption, if (i == 0) theme.text else theme.dim, font_mod.regular);
    clay.close();
}

/// The counts in tiles, four a row; then the notes and problems, a line per kind.
fn summary(a: Allocator, w: *Window) void {
    const r = &w.report;
    const tiles = [_]struct { tx.Msg, usize }{
        .{ tx.cv_n_objects, r.objects }, .{ tx.cv_n_components, r.components }, .{ tx.cv_n_looks, r.looks },                                           .{ tx.cv_n_fields, r.fields },
        .{ tx.cv_n_vars, r.vars },       .{ tx.cv_n_scenes, r.scenes },         .{ tx.cv_n_dialogs, r.dialogs },                                       .{ tx.cv_n_texts, r.texts },
        .{ tx.cv_n_rows, r.rows },       .{ tx.cv_n_assets, r.assets },         .{ tx.cv_n_placed, r.placed_data + r.loc_placed_data + r.entry_data }, .{ tx.cv_n_entries, w.entries },
    };
    var i: usize = 0;
    while (i < tiles.len) : (i += 4) {
        gui.row(lay.space.sm);
        for (tiles[i..@min(i + 4, tiles.len)]) |t| {
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.md, lay.space.sm), .childGap = lay.space.xs }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(lay.radius.md) });
            gui.txt(std.fmt.allocPrint(a, "{d}", .{t[1]}) catch "", .heading, theme.text, font_mod.bold);
            gui.txtClip(tx.get(t[0]), .caption, theme.dim, font_mod.regular);
            clay.close();
        }
        clay.close();
    }
    const g = w.groups;
    const kinds = .{
        .{ tx.cv_g_errors, g.errors, theme.removed },
        .{ tx.cv_g_notes, g.notes, theme.warn },
        .{ tx.cv_g_warnings, g.warnings, theme.warn },
        .{ tx.cv_g_anims, g.anims, theme.dim },
    };
    var any = false;
    inline for (kinds) |k| if (k[1] > 0) {
        any = true;
        gui.row(lay.space.sm);
        gui.dot(k[2]);
        gui.txtWrap(tx.alloc(a, k[0], .{k[1]}), .body, theme.text, font_mod.regular);
        clay.close();
    };
    if (!any) gui.txt(tx.get(tx.cv_g_none), .body, theme.ok, font_mod.regular);
}

test Groups {
    var g: Groups = .{};
    g.add(.{ .file = "src/looks/a.ogs", .line = 8, .message = "look a: no animation x in models/a.ani", .warning = true });
    g.add(.{ .file = "src/a.ogs", .line = 1, .message = "unused", .warning = true });
    g.add(.{ .file = "src/a.ogs", .line = 2, .message = "bad", .warning = false });
    try std.testing.expectEqual(Groups{ .anims = 1, .warnings = 1, .errors = 1 }, g);
}

test defaultFolder {
    const testing = std.testing;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const game = try std.fmt.allocPrint(a, "{s}/Gorky", .{root});
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/Gorky 17 (OpenGorky)", .{root}), try defaultFolder(io, a, game, convert.game_title));
    // An empty folder is taken, one with anything in it is not.
    try tmp.dir.createDirPath(io, "Gorky 17 (OpenGorky)");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/Gorky 17 (OpenGorky)", .{root}), try defaultFolder(io, a, game, convert.game_title));
    try tmp.dir.writeFile(io, .{ .sub_path = "Gorky 17 (OpenGorky)/x", .data = "x" });
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/Gorky 17 (OpenGorky)-2", .{root}), try defaultFolder(io, a, game, convert.game_title));
}
