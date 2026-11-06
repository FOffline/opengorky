//! Videos tab: the game's `avi\*.asf` (scripts play them as `AVI_Play("name.avi",x,y,1)`),
//! the call to paste, the scripts playing each, and import of new ones — converted by
//! ffmpeg to the game's own format so the original exe plays them too; in an OpenGorky
//! project a video the port plays (Video.playable) is kept as it is. A video the exe
//! shows itself has its placement (rules ui.ss ExeVideo: x, y, doubled lines; OpenGorky
//! edits it, one undo step each), the preview shows it on the 640×480 screen.

const std = @import("std");
const freename = @import("freename.zig");
const Io = std.Io;
const og = @import("opengorky");
const c = @import("sdl");
const Video = @import("viewer").Video;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const frame = @import("frame.zig");
const lay = @import("layout.zig");
const ink = @import("render.zig").ink;
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const uses = @import("uses.zig");
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;
const video_dir = @import("store.zig").video_dir;
const savelog = @import("savelog.zig");
const convert = @import("convert.zig");
const rules_rows = @import("rules_rows.zig");

/// The Videos tab's state (`app.video`): the selected video (`gradma.asf`), the avi
/// folder's videos (owned).
pub const State = struct {
    sel: app_mod.Name(64) = .{},
    list: std.ArrayList([]u8) = .empty,
    read: bool = false,
    /// The centre player: the video open (`for` names it), playing or on its frame.
    player: ?*Video = null,
    @"for": app_mod.Name(64) = .{},
    playing: bool = false,
};

/// The player on video `name`'s first frame (null: no decoder or no file).
fn load(app: *App, name: []const u8) void {
    stop(app);
    app.video.@"for".set(name);
    var pb: [1024]u8 = undefined;
    // As the port finds it (an OpenGorky project's layer first).
    var path: []const u8 = Video.find(&pb, app.io, app.game_dir, name) orelse "";
    // Imported, not saved yet: the player reads it from a copy in the history folder.
    if (staged(app, name)) |i| {
        path = std.fmt.bufPrint(&pb, "{s}/{s}/preview.asf", .{ app.game_dir, savelog.dir_name }) catch return;
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = app.store.text(i) }) catch return;
    }
    if (path.len == 0) return;
    app.video.player = Video.open(app.gpa, app.io, app.r, path, 0, 0, false);
    if (app.video.player) |v| v.seek(0);
}

/// The player closed (its sound too).
pub fn stop(app: *App) void {
    if (app.video.playing) app.player.stopAll();
    app.video.playing = false;
    if (app.video.player) |v| v.close(null);
    app.video.player = null;
}

/// The viewport callback: the frame fitted into `rect`, black around it; a video with a
/// placement (ExeVideo) at its place on the 640×480 screen fitted there, cut at its edges.
pub fn draw(app: *App, rect: c.SDL_FRect) void {
    ink(app.r, lay.canvas.black);
    _ = c.SDL_RenderFillRect(app.r, &rect);
    const v = app.video.player orelse return;
    if (placeOf(app.video.@"for".get())) |p| {
        const k = @min(rect.w / 640, rect.h / 480);
        const sx = rect.x + (rect.w - 640 * k) / 2;
        const sy = rect.y + (rect.h - 480 * k) / 2;
        ink(app.r, lay.canvas.inactive);
        _ = c.SDL_RenderRect(app.r, &.{ .x = sx - 1, .y = sy - 1, .w = 640 * k + 2, .h = 480 * k + 2 });
        if (v.shown == 0) return;
        v.x = @floatFromInt(p.x);
        v.y = @floatFromInt(p.y);
        v.double = p.double;
        const at = v.rect();
        const x0 = @max(at.x, 0);
        const y0 = @max(at.y, 0);
        const x1 = @min(at.x + at.w, 640);
        const y1 = @min(at.y + at.h, 480);
        // Off the screen (logo1: x −1000): nothing shown, as the exe.
        if (x1 <= x0 or y1 <= y0) return;
        const tw: f32 = @floatFromInt(v.w);
        const th: f32 = @floatFromInt(v.h);
        const src: c.SDL_FRect = .{ .x = (x0 - at.x) / at.w * tw, .y = (y0 - at.y) / at.h * th, .w = (x1 - x0) / at.w * tw, .h = (y1 - y0) / at.h * th };
        _ = c.SDL_RenderTexture(app.r, v.tex, &src, &.{ .x = sx + x0 * k, .y = sy + y0 * k, .w = (x1 - x0) * k, .h = (y1 - y0) * k });
        return;
    }
    if (v.shown == 0) return;
    // As the game shows it with the call above (its last argument 1: doubled lines).
    v.double = true;
    const at = v.rect();
    const w = at.w;
    const h = at.h;
    const k = @min(rect.w / w, rect.h / h);
    _ = c.SDL_RenderTexture(app.r, v.tex, null, &.{ .x = rect.x + (rect.w - w * k) / 2, .y = rect.y + (rect.h - h * k) / 2, .w = w * k, .h = h * k });
}

/// Play / Stop, the frame, where it is.
fn playerPane(app: *App, a: Allocator, name: []const u8) void {
    if (!std.mem.eql(u8, app.video.@"for".get(), name)) load(app, name);
    gui.rowFit(lay.space.sm);
    if (gui.toolButton(app, "vid_play", .play, tx.get(tx.vid_play), false, true)) {
        load(app, name);
        if (app.video.player) |v| {
            app.video.playing = true;
            if (v.sound) |*snd| app.player.playSound(app, name, snd);
            v.start_ms = c.SDL_GetTicks();
        }
    }
    if (gui.toolButton(app, "vid_stop", .pause, tx.get(tx.mus_stop), false, false)) load(app, name);
    clay.close();
    if (app.video.player) |v| {
        if (app.video.playing) {
            v.update();
            if (v.done) app.video.playing = false;
        }
        const len: ?f32 = if (v.sound) |snd| @as(f32, @floatFromInt(snd.frames())) / @as(f32, @floatFromInt(snd.rate)) else null;
        const at: f32 = if (app.video.playing) v.seconds() else if (v.done) len orelse 0 else 0;
        gui.timeBar(a, if (len) |l| @min(at, l) else at, len);
    } else gui.note(tx.get(tx.vid_no_player));
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .cornerRadius = clay.radius(lay.radius.md), .custom = .{ .customData = &app.video } });
}

/// Store file of video `name` imported and not saved (in no avi folder yet).
fn staged(app: *App, name: []const u8) ?usize {
    const i = app.store.find(video_dir, name) orelse return null;
    return if (app.store.files.items[i].on_disk or app.store.gone(i)) null else i;
}

/// Video names (`gradma.asf`) of the game's avi folder (read once), as the Store has
/// it: imports not saved yet in, removed ones out.
pub fn names(app: *App) []const []const u8 {
    if (!app.video.read) {
        app.video.read = true;
        read(app) catch |err| std.log.warn("avi: {t}", .{err});
    }
    return app.store.listingOver(app.frame.allocator(), video_dir, app.video.list.items, null, true);
}

fn read(app: *App) !void {
    for (app.video.list.items) |s| app.gpa.free(s);
    app.video.list.clearRetainingCapacity();
    // Beside the game's archives, as the Store reads them (store.zig videoPath): an OpenGorky
    // project's folder has none, its installed game's has.
    var dir = try app.dat.openDir(app.io, "../avi", .{ .iterate = true });
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |e| {
        if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".asf")) continue;
        const low = try std.ascii.allocLowerString(app.gpa, e.name);
        app.video.list.append(app.gpa, low) catch |err| {
            app.gpa.free(low);
            return err;
        };
    }
    std.mem.sort([]u8, app.video.list.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
}

/// A video (picked in the asset tree): import, its size, the script call, where played.
pub fn page(app: *App, a: Allocator) void {
    const name = app.video.sel.get();
    if (!gui.mediaPage(app, name, "vid_import", tx.get(tx.vid_import), tx.get(tx.vid_import_hint), .{ .kind = .video, .run = onVideoIn })) return;
    gui.txt(name, .heading, theme.text, font_mod.bold);
    // How scripts play it: level scripts call AVI_Play, scenes PLAYAVI (the exe plays
    // avi\<name>.asf for "<name>.avi").
    gui.txt(tx.get(tx.vid_call), .body, theme.dim, font_mod.regular);
    gui.txt(std.fmt.allocPrint(a, "AVI_Play(\"{s}.avi\",0,60,1);   // .lev", .{std.fs.path.stem(name)}) catch "", .label, theme.text, font_mod.regular);
    gui.txt(std.fmt.allocPrint(a, "PLAYAVI(\"{s}.avi\",0,60,1)   // scene .scr", .{std.fs.path.stem(name)}) catch "", .label, theme.text, font_mod.regular);
    playerPane(app, a, name);
    clay.close();
    frame.props(app, "vid_props");
    gui.groupTitle(tx.get(tx.props), true);
    gui.propRow(tx.get(tx.p_name), name);
    var pb: [1024]u8 = undefined;
    if (staged(app, name)) |i| {
        gui.propRow(tx.get(tx.p_size), tx.alloc(a, tx.vid_size, .{app.store.text(i).len / 1024}));
    } else if (Video.find(&pb, app.io, app.game_dir, name)) |p| if (Io.Dir.cwd().statFile(app.io, p, .{})) |st| {
        gui.propRow(tx.get(tx.p_size), tx.alloc(a, tx.vid_size, .{st.size / 1024}));
    } else |_| {};
    placement(app, a, name);
    gui.groupTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "video:{s}", .{name}) catch name, name, videoInfo));
    gui.groupTitle(tx.get(tx.p_new), false);
    if (gui.button(app, "vid_import", tx.get(tx.vid_import), false)) app.askFile(.{ .kind = .video, .run = onVideoIn });
    gui.note(tx.get(tx.vid_import_hint));
    if (gui.button(app, "vid_replace", tx.get(tx.vid_replace), false)) app.askFile(.{ .kind = .video, .run = onVideoReplace });
    gui.note(tx.get(tx.vid_replace_hint));
    gui.propsEnd();
}

// ---------------------------------------------------------------- placement (ExeVideo)

const Place = og.core.ui.Video;

/// The placement in force of video `name` (`intro.asf`): the row of its stem (`intro.avi`).
fn placeOf(name: []const u8) ?Place {
    for (og.core.modules.ui().videos) |v| if (std.ascii.eqlIgnoreCase(std.fs.path.stem(v.name), std.fs.path.stem(name))) return v;
    return null;
}

fn builtinPlace(name: []const u8) ?Place {
    for (og.core.modules.builtin_tables.videos) |v| if (std.ascii.eqlIgnoreCase(std.fs.path.stem(v.name), std.fs.path.stem(name))) return v;
    return null;
}

/// Video `name`'s placement field `field` (x, y, double) made `text`; `add`: a new one
/// (at 0, 0, as `<stem>.avi`); `remove`: the project's row dropped (a built-in one: the
/// exe's again).
pub fn setPlace(app: *App, name: []const u8, field: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const cur = placeOf(name);
    if (std.mem.eql(u8, field, "remove")) {
        if (!try rules_rows.drop(app, Place, cur orelse return error.NoPlacement)) return error.NoOwnRow;
        return app.setStatus(tx.st_rules_row, .{Place.call});
    }
    if (std.mem.eql(u8, field, "add")) {
        if (cur != null) return error.PlacementExists;
        try rules_rows.put(app, Place, .{ .name = try std.fmt.allocPrint(app.frame.allocator(), "{s}.avi", .{std.fs.path.stem(name)}), .x = 0, .y = 0, .double = false });
    } else try rules_rows.putField(app, Place, cur orelse return error.NoPlacement, field, text);
    app.setStatus(tx.st_rules_row, .{Place.call});
}

/// The Placement group: where the exe shows it (OpenGorky: edited, added, removed; Classic:
/// read-only).
fn placement(app: *App, a: Allocator, name: []const u8) void {
    const p = placeOf(name);
    if (!app.ogLayout() and p == null) return;
    gui.groupTitle(tx.get(tx.vid_place), false);
    if (!app.ogLayout()) {
        const v = p.?;
        return gui.propRow(tx.get(tx.vid_place_at), tx.alloc(a, tx.vid_place_val, .{ v.x, v.y, tx.get(if (v.double) tx.vid_place_dbl else tx.vid_place_single) }));
    }
    const v = p orelse {
        gui.note(tx.get(tx.vid_place_none));
        if (gui.button(app, "vid_place_add", tx.get(tx.vid_place_add), false)) setPlace(app, name, "add", "") catch |err| app.failed(err);
        return;
    };
    gui.fieldRow(tx.get(tx.vid_place_at));
    for ([_][]const u8{ "x", "y" }, [_]i32{ v.x, v.y }, [_][]const u8{ "X", "Y" }) |f, cur, pre| {
        if (gui.numberField(app, a, if (f[0] == 'x') "vid_place_x" else "vid_place_y", pre, @floatFromInt(cur), gui.cellWidth(2, false))) |n| setPlace(app, name, f, std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(@round(n)))}) catch "") catch |err| app.failed(err);
    }
    clay.close();
    gui.fieldRow("");
    if (gui.check(app, clay.id("vid_place_double"), v.double, tx.get(tx.vid_place_dbl))) setPlace(app, name, "double", if (v.double) "0" else "1") catch |err| app.failed(err);
    clay.close();
    gui.note(tx.get(tx.vid_place_note));
    const builtin = builtinPlace(name);
    // A built-in placement left as the exe has it: nothing to bring back.
    if (builtin) |b| if (!rules_rows.has(app, Place, v) or og.loaders.codec.same(Place, b, v)) return;
    if (gui.button(app, "vid_place_remove", tx.get(if (builtin != null) tx.vid_place_reset else tx.vid_place_remove), false)) setPlace(app, name, "remove", "") catch |err| app.failed(err);
}

/// The video's Info: its file; the scripts naming `<stem>.avi`: levels' (by level) and
/// common's (scenes, classes), as edited.
fn videoInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, "avi", name, false);
    const n = list.rows.items.len;
    const needle = list.fmt("\"{s}.avi\"", .{std.fs.path.stem(name)});
    info.levelsNaming(app, list, needle);
    for (uses.naming(list.a, uses.get(app).scripts, needle)) |e| list.add(.{ .group = .used, .text = e, .to = .{ .code = .{ .archive = common_archive, .entry = e } }, .icon = .code });
    info.usedNone(list, n, tx.vid_unused);
}

/// A video file chosen to import: converted (in the background, `convert.zig`) into the
/// history folder, then into the Store as `avi\<name>.asf` under a free name from its
/// file name: one undo step, written into the avi folder on Save. In an OpenGorky project
/// a video the port plays goes in as it is (`avi\<name>.mp4`…).
pub fn import(app: *App, path: []const u8) !void {
    const a = app.frame.allocator();
    var nb: [48]u8 = undefined;
    if (app.ogLayout() and Video.playable(app.gpa, app.io, path)) {
        const name = try freeName(app, std.fs.path.stem(path), std.fs.path.extension(path), &nb);
        const bytes = try Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .unlimited);
        errdefer app.gpa.free(bytes);
        _ = try app.store.addNew(&.{.{ .archive = video_dir, .entry = name, .text = bytes }});
        app.video.sel.set(name);
        return app.setStatusPort(tx.st_video_added, .{name}, tx.st_og_video);
    }
    const name = try freeName(app, std.fs.path.stem(path), ".asf", &nb);
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ app.game_dir, savelog.dir_name });
    try Io.Dir.cwd().createDirPath(app.io, dir);
    const out = try std.fmt.allocPrint(a, "{s}/import.asf", .{dir});
    // The game's own format (transcode.video).
    try convert.start(app, .video, path, name, out, converted);
}

/// The run done (main thread): the video into the Store, listed and picked; the
/// converted file dropped.
fn converted(app: *App, job: *convert.Job) void {
    defer Io.Dir.cwd().deleteFile(app.io, job.out) catch {};
    _ = job.result catch |err| return convert.failed(app, job, err);
    const bytes = Io.Dir.cwd().readFileAlloc(app.io, job.out, app.gpa, .unlimited) catch |err| return convert.failed(app, job, err);
    _ = app.store.addNew(&.{.{ .archive = video_dir, .entry = job.name, .text = bytes }}) catch |err| {
        app.gpa.free(bytes);
        return convert.failed(app, job, err);
    };
    app.video.sel.set(job.name);
    app.setStatus(tx.st_video_added, .{job.name});
}

/// `stem` as a video name: lowercase letters, digits and `_`, then `ext` (`.asf`); no
/// video has its stem (the port finds videos by stem).
fn freeName(app: *App, stem: []const u8, ext: []const u8, buf: *[48]u8) ![]const u8 {
    var eb: [8]u8 = undefined;
    var sb: [32]u8 = undefined;
    return freename.freeName(buf, freename.fileStem(&sb, stem, 'v'), .{ .ext = std.ascii.lowerString(&eb, ext[0..@min(ext.len, eb.len)]) }, app, stemTaken);
}

/// A video has the stem of `name` (any case).
fn stemTaken(app: *App, name: []const u8) bool {
    for (names(app)) |x| if (std.ascii.eqlIgnoreCase(std.fs.path.stem(x), std.fs.path.stem(name))) return true;
    return false;
}

/// Game video `name` (`intro.asf`) replaced by the file at `path`, under its name (the
/// scripts and the exe find it so): converted to the game's format (transcode.video:
/// ASF ≤640×480, as the exe plays), in an OpenGorky project a video the port plays kept
/// as it is beside it (the layer's, found first by its stem). One undo step; written on Save.
pub fn replace(app: *App, name: []const u8, path: []const u8) !void {
    const a = app.frame.allocator();
    // A game video's (read here: Undo gives it back).
    const f = try app.store.file(video_dir, name);
    if (app.ogLayout() and Video.playable(app.gpa, app.io, path)) {
        const bytes = try Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .unlimited);
        errdefer app.gpa.free(bytes);
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, std.fs.path.extension(name))) return app.store.replace(f, bytes);
        var eb: [8]u8 = undefined;
        const own = try std.fmt.allocPrint(a, "{s}{s}", .{ std.fs.path.stem(name), std.ascii.lowerString(&eb, ext[0..@min(ext.len, eb.len)]) });
        _ = try app.store.addNew(&.{.{ .archive = video_dir, .entry = own, .text = bytes }});
        return app.setStatusPort(tx.st_video_replaced, .{name}, tx.st_og_video);
    }
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".asf")) return error.NotAnAsf;
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ app.game_dir, savelog.dir_name });
    try Io.Dir.cwd().createDirPath(app.io, dir);
    try convert.start(app, .video, path, name, try std.fmt.allocPrint(a, "{s}/replace.asf", .{dir}), replaced);
}

fn replaced(app: *App, job: *convert.Job) void {
    defer Io.Dir.cwd().deleteFile(app.io, job.out) catch {};
    _ = job.result catch |err| return convert.failed(app, job, err);
    const bytes = Io.Dir.cwd().readFileAlloc(app.io, job.out, app.gpa, .unlimited) catch |err| return convert.failed(app, job, err);
    const f = app.store.file(video_dir, job.name) catch |err| {
        app.gpa.free(bytes);
        return convert.failed(app, job, err);
    };
    app.store.replace(f, bytes) catch |err| {
        app.gpa.free(bytes);
        return convert.failed(app, job, err);
    };
    if (std.mem.eql(u8, app.video.@"for".get(), job.name)) load(app, job.name);
    app.setStatus(tx.st_video_replaced, .{job.name});
}

fn onVideoReplace(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    replace(app, app.video.sel.get(), path) catch |err| app.setStatus(tx.st_video_failed, .{err});
}

/// File dialog answer (app.askFile).
pub fn onVideoIn(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    import(app, path) catch |err| app.setStatus(tx.st_video_failed, .{err});
}
