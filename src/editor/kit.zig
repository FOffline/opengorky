//! The editor's UI pieces the game's launcher shares (src/viewer/app/launcher.zig): Clay
//! layout, stb_truetype text, drawing the render commands with SDL; the window icon.

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");

pub const clay = @import("clay.zig");
pub const font = @import("font.zig");
pub const render = @import("render.zig");

/// Window (and macOS Dock) icon from picture `png` (embedded in the binary).
pub fn setWindowIcon(gpa: std.mem.Allocator, window: *c.SDL_Window, png: []const u8) void {
    var img = og.formats.jpeg.decode(gpa, png) catch return;
    defer img.deinit(gpa);
    const surf = c.SDL_CreateSurfaceFrom(@intCast(img.width), @intCast(img.height), c.SDL_PIXELFORMAT_ABGR8888, img.pixels.ptr, @intCast(img.width * 4)) orelse return;
    defer c.SDL_DestroySurface(surf);
    _ = c.SDL_SetWindowIcon(window, surf);
}
