//! Music: the game's tracks in common/voice.dat (`<name>.mp3`, MP3 44100 Hz stereo
//! 128 kbit/s). A location plays `<level>.mp3`, else its district's (01_port, 03_museum);
//! a battle without its own plays battle / battle2 / battle3 and `_enemy` in the enemies'
//! turn; scenes start one with MP3_PLAY("name"). A file imported is converted to the
//! game's format (ffmpeg), so the original plays it too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const frame = @import("frame.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const voices = @import("voices.zig");
const convert = @import("convert.zig");
const info = @import("info.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

/// The Music tab's state (`app.music`): the chosen track, the tracks (owned; read again
/// after a change), the name an import takes (a level's own track; empty: the file's).
pub const State = struct {
    sel: app_mod.Name(64) = .{},
    list: std.ArrayList([]u8) = .empty,
    read: bool = false,
    target: app_mod.Name(64) = .{},
};

/// The tracks (`.mp3` of voice.dat and new ones), read once and after a change.
pub fn names(app: *App) []const []u8 {
    if (!app.music.read) {
        app.music.read = true;
        for (app.music.list.items) |n| app.gpa.free(n);
        app.music.list.clearRetainingCapacity();
        for (app.store.listing(app.frame.allocator(), voices.archive_path, isMp3, true)) |n| app.music.list.append(app.gpa, app.gpa.dupe(u8, n) catch continue) catch {};
    }
    return app.music.list.items;
}

pub fn page(app: *App, a: Allocator) void {
    const name = app.music.sel.get();
    if (name.len > 0) frame.stage(app);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.lg), .childGap = lay.space.md } });
    if (name.len == 0) {
        if (gui.toolButton(app, "mus_import", .plus, tx.get(tx.mus_import), false, true)) app.askMusic(null);
        gui.txtWrap(tx.get(tx.mus_hint), .body, theme.dim, font_mod.regular);
        return clay.close();
    }
    gui.rowFit(lay.space.sm);
    gui.icon(app, .volume_2, lay.icon.lg, theme.accent_hover);
    gui.txt(name, .heading, theme.text, font_mod.bold);
    clay.close();
    gui.rowFit(lay.space.sm);
    if (gui.toolButton(app, "mus_play", .play, tx.get(tx.vo_play), false, true)) voices.play(app, name);
    if (gui.toolButton(app, "mus_stop", .pause, tx.get(tx.mus_stop), false, false)) app.player.stopAll();
    clay.close();
    const pos = app.player.trackPos(name);
    gui.timeBar(a, if (pos) |p| p[0] else 0, if (pos) |p| p[1] else null);
    clay.close();
    frame.props(app, "mus_props");
    gui.groupTitle(tx.get(tx.props), true);
    // The name typed anew: the track renamed (where it plays follows its name).
    gui.fieldRow(tx.get(tx.p_name));
    if (gui.textField(app, "mus_name", name, 0, "")) |v| rename(app, name, v);
    clay.close();
    if (voices.bytesOf(app, a, name)) |bytes| gui.propRow(tx.get(tx.p_size), tx.alloc(a, tx.vid_size, .{bytes.len / 1024}));
    gui.groupTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "music:{s}", .{name}) catch name, name, musicInfo));
    gui.groupTitle(tx.get(tx.p_new), false);
    if (gui.toolButton(app, "mus_import", .plus, tx.get(tx.mus_import), false, false)) app.askMusic(null);
    gui.note(tx.get(tx.mus_hint));
    gui.propsEnd();
}

/// The track's Info: its file; where it plays: a level of that name or its district,
/// the battles, scenes naming it.
fn musicInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, voices.archive_path, name, false);
    const n = list.rows.items.len;
    const stem = std.fs.path.stem(name);
    for (app.levels) |lv| {
        var cb: [2][]const u8 = undefined;
        const cands = og.audio.sound.musicCandidates(lv.name, &cb);
        for (cands, 0..) |cn, k| if (std.ascii.eqlIgnoreCase(cn, stem)) {
            list.add(.{ .group = .used, .text = list.fmt("{s}{s}", .{ lv.name, if (k > 0) tx.get(tx.mus_district) else "" }), .to = .{ .level = .{ .name = lv.name } }, .icon = if (lv.battle) .swords else .map_pin });
            break;
        };
    }
    if (std.ascii.startsWithIgnoreCase(stem, "battle")) list.add(.{ .group = .used, .text = tx.get(if (std.ascii.endsWithIgnoreCase(stem, "_enemy")) tx.lm_music_enemy else tx.mus_battles) });
    info.scenesNaming(app, list, list.fmt("\"{s}\"", .{stem}), "");
    info.usedNone(list, n, tx.mus_unused);
}

fn rename(app: *App, old: []const u8, typed: []const u8) void {
    var nb: [64]u8 = undefined;
    const new = musicName(&nb, typed) orelse return app.setStatus(tx.st_scene_bad_name, .{typed});
    if (std.ascii.eqlIgnoreCase(new, old)) return;
    if (voices.has(app, new)) return app.setStatus(tx.st_text_taken_name, .{new});
    voices.copyTo(app, old, new) catch |err| return app.failed(err);
    voices.remove(app, old) catch {};
    app.music.read = false;
    app.music.sel.set(new);
}

/// `typed` as a track name: letters, digits, `_`, `.mp3` after (null: nothing left).
fn musicName(buf: []u8, typed: []const u8) ?[]const u8 {
    const stem = if (std.ascii.endsWithIgnoreCase(typed, ".mp3")) typed[0 .. typed.len - 4] else typed;
    var n: usize = 0;
    for (std.mem.trim(u8, stem, " ")) |ch| {
        if (n + 4 >= buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_';
        n += 1;
    }
    if (n == 0) return null;
    @memcpy(buf[n..][0..4], ".mp3");
    return buf[0 .. n + 4];
}

/// A file chosen: converted (in the background, `convert.zig`) to the game's MP3 into
/// voice.dat as `target` (a level's own track) or its file name; one undo step.
pub fn import(app: *App, path: []const u8, target: ?[]const u8) !void {
    var nb: [64]u8 = undefined;
    const name = musicName(&nb, target orelse std.fs.path.stem(path)) orelse return error.BadName;
    try convert.start(app, .music, path, name, "", converted);
}

/// The run done (main thread): the track into voice.dat and picked.
fn converted(app: *App, job: *convert.Job) void {
    const mp3 = job.result catch |err| return convert.failed(app, job, err);
    const data = app.gpa.dupe(u8, mp3) catch |err| return app.setStatus(tx.st_video_failed, .{err});
    voices.put(app, job.name, data) catch |err| return app.setStatus(tx.st_video_failed, .{err});
    app.music.read = false;
    app.music.sel.set(job.name);
    app.setStatus(tx.st_music_added, .{job.name});
}

test musicName {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("my_song.mp3", musicName(&b, "My Song").?);
    try std.testing.expectEqualStrings("01_port.mp3", musicName(&b, "01_port.mp3").?);
}

/// File dialog answer (app.askFile): named `app.music.target` if set.
pub fn onMusicIn(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    import(app, path, if (app.music.target.len > 0) app.music.target.get() else null) catch |err| app.setStatus(tx.st_video_failed, .{err});
}

fn isMp3(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".mp3");
}
