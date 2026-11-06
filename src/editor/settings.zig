//! Editor settings (`editor.cfg` next to the game's `opengorky.cfg`): "key = value"
//! lines, `#` comments. The editor rewrites the whole file when a setting changes.

const std = @import("std");
const text = @import("text.zig");
const PathBuf = @import("config").PathBuf;

pub const file_name = "editor.cfg";

/// Panes the user drags to size, each a share of the window's width (`entry_y`: of its
/// height): list widths, the side panel (and a page's constructor, frame.zig), and on the
/// enemy/hero page the animations' column and the model's row.
pub const Split = enum {
    levels,
    objects,
    entries,
    entry_y,
    history,

    /// Their sizes in the 1680×1050 window the editor was laid out in.
    const defaults = [_]f32{ 280.0 / ref[0], 380.0 / ref[0], 320.0 / ref[0], 460.0 / ref[1], 560.0 / ref[0] };
    /// Older files kept points: shares of this window.
    const ref = [2]f32{ 1680, 1050 };
};

/// The interface scales the settings' slider spans.
pub const ui_scale_min: f32 = 0.75;
pub const ui_scale_max: f32 = 3;

pub const Settings = struct {
    lang: text.Lang = .en,
    /// The game folder last opened from the command line, used when none is given.
    game_path: PathBuf = .{},
    /// The port's program (or on macOS its `.app`) Play runs; none: looked for beside the editor.
    viewer_path: PathBuf = .{},
    splits: [Split.defaults.len]f32 = Split.defaults,
    /// The whole interface's size (text and panes), ui_scale_min…ui_scale_max.
    ui_scale: f32 = 1,

    pub fn split(self: *const Settings, k: Split) f32 {
        return self.splits[@backingInt(k)];
    }

    pub fn gamePath(self: *const Settings) ?[]const u8 {
        return orNull(self.game_path.get());
    }

    pub fn setGamePath(self: *Settings, p: []const u8) void {
        self.game_path.set(p);
    }

    pub fn viewerPath(self: *const Settings) ?[]const u8 {
        return orNull(self.viewer_path.get());
    }

    /// `""` clears it (back to the lookup beside the editor).
    pub fn setViewerPath(self: *Settings, p: []const u8) void {
        self.viewer_path.set(p);
    }

    fn orNull(p: []const u8) ?[]const u8 {
        return if (p.len > 0) p else null;
    }

    /// Unknown keys and bad values are ignored (`target`, before the project manifest held
    /// it; `original_path`, before Package mod read the editor's history).
    pub fn parse(data: []const u8) Settings {
        var s: Settings = .{};
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const key = std.mem.trim(u8, t[0..eq], " \t");
            const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "language")) {
                s.lang = std.meta.stringToEnum(text.Lang, val) orelse s.lang;
            } else if (std.mem.eql(u8, key, "game_path")) {
                s.setGamePath(val);
            } else if (std.mem.eql(u8, key, "viewer_path")) {
                s.setViewerPath(val);
            } else if (std.mem.eql(u8, key, "ui_scale")) {
                const v = std.fmt.parseFloat(f32, val) catch continue;
                if (v >= ui_scale_min and v <= ui_scale_max) s.ui_scale = v;
            } else if (std.mem.startsWith(u8, key, "split.")) {
                const k = std.meta.stringToEnum(Split, key["split.".len..]) orelse continue;
                var v = std.fmt.parseFloat(f32, val) catch continue;
                if (v > 1) v /= Split.ref[@intFromBool(k == .entry_y)];
                if (v > 0 and v <= 1) s.splits[@backingInt(k)] = v;
            }
        }
        return s;
    }

    pub fn format(self: *const Settings, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.print(
            \\# OpenGorky level editor settings.
            \\# Interface language: en, ru
            \\language = {t}
            \\# Game folder used when the editor starts without one (it edits this folder's archives)
            \\game_path = {s}
            \\# The port's program or OpenGorky.app that Play runs (empty: the one beside the editor)
            \\viewer_path = {s}
            \\# Interface scale: text and panes (0.75 to 3)
            \\ui_scale = {d}
            \\# Pane sizes (shares of the window), as dragged
            \\
        , .{ self.lang, self.game_path.get(), self.viewer_path.get(), self.ui_scale });
        for (self.splits, 0..) |v, k| try w.print("split.{t} = {d:.4}\n", .{ @as(Split, @fromBackingInt(@intCast(k))), v });
        return w.buffered();
    }
};

/// The program to run for viewer path `p`: a macOS `.app` bundle's binary inside it, else `p` itself.
pub fn viewerProgram(buf: []u8, p: []const u8, exe: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    if (!std.ascii.endsWithIgnoreCase(t, ".app")) return p;
    return std.fmt.bufPrint(buf, "{s}/Contents/MacOS/{s}", .{ t, exe }) catch p;
}

test "settings: viewer path, .app to its binary" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/A/OpenGorky.app/Contents/MacOS/opengorky-viewer", viewerProgram(&buf, "/A/OpenGorky.app/", "opengorky-viewer"));
    try std.testing.expectEqualStrings("/b/opengorky-viewer", viewerProgram(&buf, "/b/opengorky-viewer", "opengorky-viewer"));
    var s = Settings.parse("viewer_path = /A/OpenGorky.app\n");
    var fb: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("/A/OpenGorky.app", Settings.parse(try s.format(&fb)).viewerPath().?);
    s.setViewerPath("");
    try std.testing.expect(Settings.parse(try s.format(&fb)).viewerPath() == null);
}

test "settings: parse, format back" {
    const s = Settings.parse("# x\nlanguage = ru\ngame_path = /a b/Gorky\noriginal_path = /o\nbad\n");
    try std.testing.expectEqual(text.Lang.ru, s.lang);
    try std.testing.expectEqualStrings("/a b/Gorky", s.gamePath().?);
    var buf: [2048]u8 = undefined;
    const back = Settings.parse(try s.format(&buf));
    try std.testing.expectEqual(s.lang, back.lang);
    try std.testing.expectEqualStrings(s.gamePath().?, back.gamePath().?);
    try std.testing.expectEqual(text.Lang.en, Settings.parse("language = xx\n").lang);
    // The old `original_path` line is read past, not written back.
    try std.testing.expect(std.mem.indexOf(u8, try s.format(&buf), "original") == null);
    // Points (older files) become shares; a share stays; a dropped pane's (`entry_x`, the
    // enemy page's own column before frame.zig) is read past.
    var sp = Settings.parse("split.entry_x = 0.3\nsplit.entries = 840\nsplit.entry_y = 525\nsplit.nope = 3\nsplit.levels = -5\nsplit.history = 0.25\n");
    try std.testing.expectEqual(0.5, sp.split(.entries));
    try std.testing.expectEqual(0.5, sp.split(.entry_y));
    try std.testing.expectEqual(Split.defaults[0], sp.split(.levels));
    sp = Settings.parse(try sp.format(&buf));
    try std.testing.expectEqual(0.5, sp.split(.entries));
    try std.testing.expectEqual(0.25, sp.split(.history));
    try std.testing.expectEqual(1, Settings.parse("ui_scale = 7\n").ui_scale);
    // The old `target` key (now the project manifest's format) is ignored.
    try std.testing.expectEqual(2.75, Settings.parse("target = port\nui_scale = 2.75\n").ui_scale);
    sp = Settings.parse("ui_scale = 2.75\n");
    try std.testing.expectEqual(2.75, Settings.parse(try sp.format(&buf)).ui_scale);
}
