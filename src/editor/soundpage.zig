//! Sounds tab: the effects of `common/sound.dat` with search, listening, where models'
//! animations use each (frame sounds, `.ani`), export to WAV and import of new ones —
//! converted to the game's own format (PCM 16-bit mono 22050 Hz, as 775 of its 797).

const std = @import("std");
const freename = @import("freename.zig");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const frame = @import("frame.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;

pub const archive_path = "common/sound.dat";
const rate = 22050;
/// Larger files are not sounds for the game (its longest effect is about 1 MB).
const max_import = 32 << 20;

/// A sound (picked in the asset tree): import, its format, play, export, where used.
pub fn page(app: *App, a: Allocator) void {
    const name = app.sound_sel.get();
    if (!gui.mediaPage(app, name, "snd_import", tx.get(tx.snd_import), tx.get(if (app.ogLayout()) tx.snd_import_hint_og else tx.snd_import_hint), .{ .kind = .sound, .run = onSoundIn })) return;
    gui.txt(name, .heading, theme.text, font_mod.bold);
    gui.rowFit(lay.space.sm);
    if (gui.toolButton(app, "snd_play_sel", .play, tx.get(tx.snd_play), false, true)) app.player.playEffect(app, name, true);
    if (gui.toolButton(app, "snd_stop", .pause, tx.get(tx.mus_stop), false, false)) app.player.stopAll();
    clay.close();
    const pos = app.player.trackPos(name);
    gui.timeBar(a, if (pos) |p| p[0] else 0, if (pos) |p| p[1] else null);
    clay.close();
    props(app, a, name);
}

/// The right column: the format, where it sounds, export; importing another.
fn props(app: *App, a: Allocator, name: []const u8) void {
    frame.props(app, "snd_props");
    gui.groupTitle(tx.get(tx.props), true);
    gui.propRow(tx.get(tx.p_name), name);
    if (bytesOf(app, a, name)) |bytes| if (og.formats.sound.decode(a, bytes)) |s| {
        const secs = @as(f32, @floatFromInt(s.frames())) / @as(f32, @floatFromInt(s.rate));
        gui.propRow(tx.get(tx.p_format), tx.alloc(a, tx.snd_format, .{ s.channels, s.rate, secs, bytes.len / 1024 }));
    } else |_| {};
    if (gui.button(app, "snd_export", tx.get(tx.snd_export), false)) app.askFile(.{ .kind = .wav_out, .run = onSoundOut, .name = name });
    gui.groupTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "sound:{s}", .{name}) catch name, name, soundInfo));
    gui.groupTitle(tx.get(tx.p_new), false);
    if (gui.button(app, "snd_import", tx.get(tx.snd_import), false)) app.askFile(.{ .kind = .sound, .run = onSoundIn });
    gui.note(tx.get(if (app.ogLayout()) tx.snd_import_hint_og else tx.snd_import_hint));
    gui.propsEnd();
}

/// The file of sound `name`: an imported one (unsaved) or the archive's.
pub fn bytesOf(app: *App, a: Allocator, name: []const u8) ?[]const u8 {
    return @import("refs.zig").read(app, a, archive_path, name);
}

/// The sound's Info: its file; "model.ani: anim, frame N" for each frame sound naming
/// it (the edited `.ani` files as they are now), each opening that list.
fn soundInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, archive_path, name, false);
    const n = list.rows.items.len;
    const stem = std.fs.path.stem(name);
    for (@import("uses.zig").get(app).cues) |cue| {
        if (!std.ascii.eqlIgnoreCase(std.fs.path.stem(cue.sound), stem)) continue;
        list.add(.{ .group = .used, .text = list.fmt("{s}: {s}, {s} {d}", .{ cue.file["gfx_3d\\".len..], cue.anim, tx.get(tx.snd_frame_word), cue.frame }), .to = .{ .code = .{ .archive = common_archive, .entry = list.fmt("{s}", .{cue.file}) } }, .icon = .code });
    }
    info.usedNone(list, n, tx.snd_unused);
}

/// A sound file chosen to import (WAV or MP3): converted to the game's format under
/// a free name from its file name; one undo step.
pub fn import(app: *App, path: []const u8) ![]const u8 {
    const a = app.frame.allocator();
    const data = try std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(max_import));
    var s = try og.formats.sound.decode(app.gpa, data);
    defer s.deinit(app.gpa);
    const wav = try og.formats.sound.toPcmWav(app.gpa, s, rate);
    errdefer app.gpa.free(wav);
    var sb: [40]u8 = undefined;
    var nb: [64]u8 = undefined;
    const name = try freename.freeName(&nb, freename.fileStem(&sb, std.fs.path.stem(path), 's'), .{ .ext = ".wav" }, app, soundTaken);
    _ = try app.store.addNew(&.{.{ .archive = archive_path, .entry = name, .text = wav }});
    app.sound_sel.set(name);
    return name;
}

/// Sound `name` is the game's or imported (any case).
pub fn soundTaken(app: *App, name: []const u8) bool {
    for (app.player.names(app, app.frame.allocator())) |x| if (std.ascii.eqlIgnoreCase(x, name)) return true;
    return false;
}

fn exportTo(app: *App, name: []const u8, path: []const u8) !void {
    const bytes = bytesOf(app, app.frame.allocator(), name) orelse return error.NoSound;
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = bytes });
}

// File dialog answers (app.askFile).
pub fn onSoundIn(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    app.setStatus(tx.st_sound_added, .{try import(app, path)});
}
pub fn onSoundOut(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    try exportTo(app, app.sound_sel.get(), path);
    app.setStatus(tx.st_sound_saved, .{path});
}
