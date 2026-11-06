//! What the viewer loads at startup besides the archives: the window icon and
//! adjust.kdt settings (shadows, sound).

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");
const kit = @import("kit");

/// Window (and macOS Dock) icon: the project's own image (assets/icon-256.png),
/// embedded in the binary.
pub fn setWindowIcon(gpa: std.mem.Allocator, window: *c.SDL_Window) void {
    kit.setWindowIcon(gpa, window, @embedFile("icon_png"));
}

/// Shadows are on unless adjust.kdt has disable_shadows != 0 (read by `compose.loadAdjust`).
pub fn loadShadows() bool {
    return og.rules.adjust.int("disable_shadows") == 0;
}

/// Sound settings from adjust.kdt; the defaults without it.
pub fn loadSoundParams() og.audio.sound.Params {
    const adj = og.rules.adjust;
    var p: og.audio.sound.Params = .{};
    p.volume_start = adj.float("sound_volume_start");
    p.volume_falloff = adj.float("sound_volume_falloff");
    p.pan_start = adj.float("sound_pan_start");
    p.pan_factor = adj.float("sound_pan_factor");
    p.dialog_sound = adj.int("dialog_sound_control") != 0;
    return p;
}
