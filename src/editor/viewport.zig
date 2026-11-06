//! The centre's canvas: the level view and the game's picture of it (made once per
//! load, finer where zoomed in).

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");
const font_mod = @import("font.zig");
const level = @import("level.zig");
const tx = @import("text.zig");
const sprview = @import("sprview.zig");
const paint = @import("paint.zig");
const scenepage = @import("scenepage.zig");
const levelanims = @import("levelanims.zig");
const logicview = @import("logicview.zig");
const codeview = @import("codeview.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

/// The centre's custom element drawn: a page's canvas, else the open level (the editor's
/// view, the edit mode's, or the game's picture).
pub fn drawViewport(ctx: *anyopaque, data: ?*anyopaque, rect: c.SDL_FRect) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    // The sprite page's canvas carries its Edit, the code editor's text area its View.
    if (data) |p| if (app.spr) |e| if (p == @as(*anyopaque, e)) return sprview.draw(app, e, rect);
    if (data) |p| if (p == @as(*anyopaque, &app.scenes.preview)) return scenepage.drawPreview(app, rect);
    if (data) |p| if (p == @as(*anyopaque, &app.video)) return @import("videopage.zig").draw(app, rect);
    if (data) |p| if (p != ctx) return codeview.draw(app, @ptrCast(@alignCast(p)), rect);
    const d = app.doc orelse {
        const msg = tx.get(tx.no_level);
        const w = app.font.measure(msg, font_mod.regular, 18)[0];
        app.font.draw(app.r, msg, font_mod.regular, 18, rect.x + (rect.w - w) / 2, rect.y + rect.h / 2 - 10, .{ 120, 124, 132, 255 });
        return;
    };
    d.view_hidden = &app.view_hidden;
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    if (app.paint) |p| paint.draw(app, p, d, rect) else {
        // Made before the clip: it draws into textures of its own.
        const game_look = if (app.rendered.on) renderedLevel(app, d) else null;
        _ = c.SDL_SetRenderClipRect(app.r, &clip);
        if (game_look) |t| {
            // The preview: the game's picture alone.
            if (!d.fitted) d.fit(rect);
            const o = d.toScreen(rect, .{ 0, 0 });
            _ = c.SDL_RenderTexture(app.r, t, null, &.{ .x = o[0], .y = o[1], .w = d.bg_size[0] * d.zoom, .h = d.bg_size[1] * d.zoom });
            if (renderedDetail(app, d, rect)) |dt| {
                const p = d.toScreen(rect, .{ @floatFromInt(dt.key[0]), @floatFromInt(dt.key[1]) });
                _ = c.SDL_RenderTexture(app.r, dt.tex, null, &.{ .x = p[0], .y = p[1], .w = @as(f32, @floatFromInt(dt.key[2])) * d.zoom, .h = @as(f32, @floatFromInt(dt.key[3])) * d.zoom });
            }
            _ = c.SDL_SetRenderClipRect(app.r, null);
            return;
        }
        d.grid_hidden = false;
        // The background with the level's post-processing, the editor's marks over it.
        const post = @import("postpage.zig").stageTexture(app, d);
        if (post) |t| {
            if (!d.fitted) d.fit(rect);
            const o = d.toScreen(rect, .{ 0, 0 });
            _ = c.SDL_RenderTexture(app.r, t, null, &.{ .x = o[0], .y = o[1], .w = d.bg_size[0] * d.zoom, .h = d.bg_size[1] * d.zoom });
        }
        d.draw(app.r, app.font, rect, app.selected, app.show_walk, post == null);
        if (logicview.of(app)) |v| logicview.draw(app, d, v, rect);
    }
    // The bitmap animations over it (outlines, the picked one's frame).
    _ = c.SDL_SetRenderClipRect(app.r, &clip);
    levelanims.draw(app, d, rect);
    _ = c.SDL_SetRenderClipRect(app.r, null);
}

/// The open level as the game draws it a second after it starts (its world read from
/// the saved files): made once per load of the level; null if it can't be.
fn renderedLevel(app: *App, d: *level.Doc) ?*c.SDL_Texture {
    const rd = &app.rendered;
    if (rd.of == d.serial) return rd.tex;
    dropRendered(app);
    rd.of = d.serial;
    if (rd.models == null) rd.models = og.compose.models.open(app.io, app.gpa, app.dat, null) catch |err| {
        app.setStatus(tx.st_render_failed, .{err});
        return null;
    };
    if (rd.textures == null) rd.textures = og.compose.models.textures(app.gpa, &rd.models.?);
    const sc = @import("viewer").Scene.init(app.io, app.gpa, app.r, app.dat, &rd.models.?, &rd.textures.?, d.name, 30) catch |err| {
        app.setStatus(tx.st_render_failed, .{err});
        return null;
    };
    rd.scene = sc;
    const bs = sc.size();
    rd.tex = sc.draw(app.r, 0, 0, bs[0], bs[1], 1) catch |err| {
        app.setStatus(tx.st_render_failed, .{err});
        return null;
    };
    return rd.tex;
}

/// The preview's pictures and scene gone (another level, the editor closing).
pub fn dropRendered(app: *App) void {
    const rd = &app.rendered;
    if (rd.tex) |t| c.SDL_DestroyTexture(t);
    if (rd.detail) |t| c.SDL_DestroyTexture(t);
    if (rd.scene) |sc| sc.deinit();
    rd.tex = null;
    rd.detail = null;
    rd.scene = null;
    rd.detail_key = .{ 0, 0, 0, 0, 0 };
}

/// Zoomed in past the whole picture's pixels: the visible part drawn again with the
/// models at the window's pixels (once the view has rested: a pan or zoom in progress
/// shows the whole picture scaled). Its texture and background rectangle, or null.
fn renderedDetail(app: *App, d: *level.Doc, rect: c.SDL_FRect) ?struct { tex: *c.SDL_Texture, key: [5]u32 } {
    const rd = &app.rendered;
    const sc = rd.scene orelse return null;
    var sx: f32 = 1;
    var sy: f32 = 1;
    _ = c.SDL_GetRenderScale(app.r, &sx, &sy);
    // Window pixels per background pixel; the layer's detail is a whole number (≤ 4, the viewer's).
    const k: u32 = @intFromFloat(std.math.clamp(@ceil(d.zoom * sx - 0.05), 1, 4));
    if (k <= 1) return null;
    const bs = sc.size();
    const a = d.toBackground(rect, .{ rect.x, rect.y });
    const b = d.toBackground(rect, .{ rect.x + rect.w, rect.y + rect.h });
    const clampTo = struct {
        fn f(v: f32, hi: u32) u32 {
            return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(hi))));
        }
    }.f;
    const x0 = clampTo(@floor(a[0]), bs[0]);
    const y0 = clampTo(@floor(a[1]), bs[1]);
    const x1 = clampTo(@ceil(b[0]), bs[0]);
    const y1 = clampTo(@ceil(b[1]), bs[1]);
    if (x1 <= x0 or y1 <= y0) return null;
    const key: [5]u32 = .{ x0, y0, x1 - x0, y1 - y0, k };
    const now = c.SDL_GetTicks();
    if (!std.mem.eql(u32, &key, &rd.view_key)) {
        rd.view_key = key;
        rd.moved_ms = now;
        rd.still_frames = 0;
    } else rd.still_frames +|= 1;
    // Rested: 150 ms, or 30 frames (a scripted run's frames take no time).
    if (!std.mem.eql(u32, &key, &rd.detail_key) and (now - rd.moved_ms > 150 or rd.still_frames >= 30)) {
        if (rd.detail) |t| c.SDL_DestroyTexture(t);
        rd.detail = sc.draw(app.r, key[0], key[1], key[2], key[3], k) catch null;
        rd.detail_key = key;
    }
    // A finer picture made for another detail is not shown (zoomed out since).
    if (rd.detail_key[4] != k) return null;
    return .{ .tex = rd.detail orelse return null, .key = rd.detail_key };
}
