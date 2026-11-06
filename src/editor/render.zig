//! Clay render commands → SDL renderer (in points; the render scale is the pixel density).

const std = @import("std");
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const canvas = @import("layout.zig").canvas;

/// Draws a CUSTOM element (`customData` set in its declaration) into its box.
const Custom = *const fn (ctx: *anyopaque, data: ?*anyopaque, box: c.SDL_FRect) void;

fn rgba(col: ui.Clay_Color) [4]u8 {
    return .{ @intFromFloat(col.r), @intFromFloat(col.g), @intFromFloat(col.b), @intFromFloat(col.a) };
}

/// Sets the draw colour to `col` (RGBA bytes, as `layout.canvas`'s).
pub fn ink(r: *c.SDL_Renderer, col: [4]u8) void {
    _ = c.SDL_SetRenderDrawColor(r, col[0], col[1], col[2], col[3]);
}

/// `col` (RGBA bytes) as a Clay colour.
pub fn clayColor(col: [4]u8) ui.Clay_Color {
    return .{ .r = @floatFromInt(col[0]), .g = @floatFromInt(col[1]), .b = @floatFromInt(col[2]), .a = @floatFromInt(col[3]) };
}

fn setColor(r: *c.SDL_Renderer, col: ui.Clay_Color) void {
    ink(r, rgba(col));
}

/// Points around `rect` with corners rounded by `cr` (clockwise from the top left),
/// `seg` per corner.
fn outline(rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, out: *[n_pts][2]f32) void {
    const radii = [4]f32{ cr.topLeft, cr.topRight, cr.bottomRight, cr.bottomLeft };
    const half = @min(rect.w, rect.h) / 2;
    // Corner centres and the start angle of each arc (screen y down).
    for (0..4) |k| {
        const rr = @min(radii[k], half);
        const cx = if (k == 0 or k == 3) rect.x + rr else rect.x + rect.w - rr;
        const cy = if (k < 2) rect.y + rr else rect.y + rect.h - rr;
        const a0 = std.math.pi * (1.0 + 0.5 * @as(f32, @floatFromInt(k)));
        for (0..seg + 1) |s| {
            const t = a0 + std.math.pi * 0.5 * @as(f32, @floatFromInt(s)) / seg;
            out[k * (seg + 1) + s] = .{ cx + @cos(t) * rr, cy + @sin(t) * rr };
        }
    }
}

const seg = 8;
const n_pts = 4 * (seg + 1);

/// The anti-aliasing fringe (points; a pixel at 2× density): colour fading to clear.
const feather: f32 = 0.6;

/// `userData` of a UI icon image: tinted by its colour.
pub var tinted: u8 = 0;

fn fcolor(col: ui.Clay_Color) c.SDL_FColor {
    return .{ .r = col.r / 255, .g = col.g / 255, .b = col.b / 255, .a = col.a / 255 };
}

/// The outline of `rect` grown by `d` (shrunk when negative), round corners kept
/// concentric, square ones square.
fn outlineBy(rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, d: f32, out: *[n_pts][2]f32) void {
    const grow = struct {
        fn f(v: f32, by: f32) f32 {
            return if (v > 0) @max(0, v + by) else 0;
        }
    }.f;
    outline(.{ .x = rect.x - d, .y = rect.y - d, .w = rect.w + 2 * d, .h = rect.h + 2 * d }, .{ .topLeft = grow(cr.topLeft, d), .topRight = grow(cr.topRight, d), .bottomRight = grow(cr.bottomRight, d), .bottomLeft = grow(cr.bottomLeft, d) }, out);
}

/// Triangles joining two outlines (`a` and `b` vertices from `ia` and `ib`) into `idx`.
fn strip(idx: []c_int, at: *usize, ia: usize, ib: usize) void {
    for (0..n_pts) |k| {
        const k1 = (k + 1) % n_pts;
        for ([_]usize{ ia + k, ia + k1, ib + k1, ia + k, ib + k1, ib + k }) |v| {
            idx[at.*] = @intCast(v);
            at.* += 1;
        }
    }
}

/// A rounded box filled with `col`, its edge feathered.
fn fillShape(r: *c.SDL_Renderer, rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, col: c.SDL_FColor) void {
    var in: [n_pts][2]f32 = undefined;
    var out: [n_pts][2]f32 = undefined;
    outlineBy(rect, cr, 0, &in);
    outlineBy(rect, cr, feather, &out);
    const clear: c.SDL_FColor = .{ .r = col.r, .g = col.g, .b = col.b, .a = 0 };
    var verts: [2 * n_pts + 1]c.SDL_Vertex = undefined;
    verts[0] = .{ .position = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 }, .color = col };
    for (0..n_pts) |k| {
        verts[1 + k] = .{ .position = .{ .x = in[k][0], .y = in[k][1] }, .color = col };
        verts[1 + n_pts + k] = .{ .position = .{ .x = out[k][0], .y = out[k][1] }, .color = clear };
    }
    var idx: [n_pts * 3 + n_pts * 6]c_int = undefined;
    for (0..n_pts) |k| {
        idx[k * 3] = 0;
        idx[k * 3 + 1] = @intCast(k + 1);
        idx[k * 3 + 2] = @intCast((k + 1) % n_pts + 1);
    }
    var n: usize = n_pts * 3;
    strip(&idx, &n, 1, 1 + n_pts);
    _ = c.SDL_RenderGeometry(r, null, &verts, verts.len, &idx, @intCast(n));
}

/// A rounded frame `w` points wide inside `rect`, both its edges feathered.
fn strokeShape(r: *c.SDL_Renderer, rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, w: f32, col: ui.Clay_Color) void {
    const fc = fcolor(col);
    const clear: c.SDL_FColor = .{ .r = fc.r, .g = fc.g, .b = fc.b, .a = 0 };
    // From outside in: clear, solid, solid, clear.
    const rings = [4]struct { d: f32, col: c.SDL_FColor }{ .{ .d = feather / 2, .col = clear }, .{ .d = -feather / 2, .col = fc }, .{ .d = -w + feather / 2, .col = fc }, .{ .d = -w - feather / 2, .col = clear } };
    var verts: [4 * n_pts]c.SDL_Vertex = undefined;
    for (rings, 0..) |ring, k| {
        var pts: [n_pts][2]f32 = undefined;
        outlineBy(rect, cr, ring.d, &pts);
        for (pts, 0..) |p, i| verts[k * n_pts + i] = .{ .position = .{ .x = p[0], .y = p[1] }, .color = ring.col };
    }
    var idx: [3 * n_pts * 6]c_int = undefined;
    var n: usize = 0;
    for (0..3) |k| strip(&idx, &n, k * n_pts, (k + 1) * n_pts);
    _ = c.SDL_RenderGeometry(r, null, &verts, verts.len, &idx, @intCast(n));
}

fn rounded(cr: ui.Clay_CornerRadius) bool {
    return cr.topLeft > 0 or cr.topRight > 0 or cr.bottomLeft > 0 or cr.bottomRight > 0;
}

pub fn fillRounded(r: *c.SDL_Renderer, rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, col: ui.Clay_Color) void {
    fillShape(r, rect, cr, fcolor(col));
}

/// `font`: the font set clay measured with (font.zig).
/// Container `id`'s scroll bars (of `all`, clay.bars): a faint track, the thumb brighter
/// while held. Drawn when its clipping ends, so what lies over it (a dialog) hides them.
fn barsOf(r: *c.SDL_Renderer, all: []const clay.Bar, id: u32) void {
    const rad = clay.bar_thick / 2;
    const cr: ui.Clay_CornerRadius = .{ .topLeft = rad, .topRight = rad, .bottomLeft = rad, .bottomRight = rad };
    for (all) |b| if (b.id.id == id) {
        fillRounded(r, .{ .x = b.track.x, .y = b.track.y, .w = b.track.width, .h = b.track.height }, cr, clayColor(canvas.bar_track));
        fillRounded(r, .{ .x = b.thumb.x, .y = b.thumb.y, .w = b.thumb.width, .h = b.thumb.height }, cr, clayColor(if (b.held) canvas.bar_held else canvas.bar_thumb));
    };
}

pub fn draw(r: *c.SDL_Renderer, font: anytype, cmds: clay.Commands, custom: Custom, ctx: *anyopaque) void {
    var clips: [8]c.SDL_Rect = undefined;
    var clip_ids: [8]u32 = undefined;
    var depth: usize = 0;
    var bar_buf: [256]clay.Bar = undefined;
    const all_bars = clay.bars(&bar_buf);
    for (cmds) |*cmd| {
        const bb = cmd.boundingBox;
        const rect: c.SDL_FRect = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
        switch (cmd.commandType) {
            ui.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                const rd = cmd.renderData.rectangle;
                if (rounded(rd.cornerRadius)) {
                    fillRounded(r, rect, rd.cornerRadius, rd.backgroundColor);
                    continue;
                }
                setColor(r, rd.backgroundColor);
                _ = c.SDL_RenderFillRect(r, &rect);
            },
            ui.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                const b = cmd.renderData.border;
                setColor(r, b.color);
                const w = b.width;
                // A rounded frame all round (fields, buttons): a one-point outline. A
                // single edge (a tab's accent) stays a straight bar.
                if (rounded(b.cornerRadius) and w.left > 0 and w.left == w.right and w.left == w.top and w.left == w.bottom) {
                    strokeShape(r, rect, b.cornerRadius, @floatFromInt(w.left), b.color);
                    continue;
                }
                const edges = [_]c.SDL_FRect{
                    .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @floatFromInt(w.top) },
                    .{ .x = rect.x, .y = rect.y + rect.h - @as(f32, @floatFromInt(w.bottom)), .w = rect.w, .h = @floatFromInt(w.bottom) },
                    .{ .x = rect.x, .y = rect.y, .w = @floatFromInt(w.left), .h = rect.h },
                    .{ .x = rect.x + rect.w - @as(f32, @floatFromInt(w.right)), .y = rect.y, .w = @floatFromInt(w.right), .h = rect.h },
                };
                _ = c.SDL_RenderFillRects(r, &edges, edges.len);
            },
            ui.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                const t = cmd.renderData.text;
                font.draw(r, t.stringContents.chars[0..@intCast(t.stringContents.length)], t.fontId, t.fontSize, rect.x, rect.y, rgba(t.textColor));
            },
            ui.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                // In render coordinates: SDL applies the render scale to the clip rectangle.
                var clip: c.SDL_Rect = .{
                    .x = @intFromFloat(@floor(rect.x)),
                    .y = @intFromFloat(@floor(rect.y)),
                    .w = @intFromFloat(@ceil(rect.w)),
                    .h = @intFromFloat(@ceil(rect.h)),
                };
                // Nested in another clipping element: within it too, and its own restored at the end.
                if (depth > 0 and !c.SDL_GetRectIntersection(&clip, &clips[depth - 1], &clip)) clip = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                if (depth < clips.len) {
                    clips[depth] = clip;
                    clip_ids[depth] = cmd.id;
                    depth += 1;
                }
                _ = c.SDL_SetRenderClipRect(r, &clip);
            },
            ui.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => {
                if (depth == 0) continue;
                depth -= 1;
                _ = c.SDL_SetRenderClipRect(r, if (depth > 0) &clips[depth - 1] else null);
                barsOf(r, all_bars, clip_ids[depth]);
            },
            ui.CLAY_RENDER_COMMAND_TYPE_CUSTOM => custom(ctx, cmd.renderData.custom.customData, rect),
            // `imageData` is an SDL texture; it fills the box keeping its aspect.
            ui.CLAY_RENDER_COMMAND_TYPE_IMAGE => if (cmd.renderData.image.imageData) |p| {
                const t: *c.SDL_Texture = @ptrCast(@alignCast(p));
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                const k = @min(rect.w / tw, rect.h / th);
                // A UI icon (`userData` = `tinted`): white, drawn in its element's colour.
                const tint = cmd.renderData.image.backgroundColor;
                const tinted_icon = cmd.userData == @as(?*anyopaque, &tinted);
                if (tinted_icon) _ = c.SDL_SetTextureColorModFloat(t, tint.r / 255, tint.g / 255, tint.b / 255);
                defer if (tinted_icon) {
                    _ = c.SDL_SetTextureColorModFloat(t, 1, 1, 1);
                };
                _ = c.SDL_RenderTexture(r, t, null, &.{ .x = rect.x + (rect.w - tw * k) / 2, .y = rect.y + (rect.h - th * k) / 2, .w = tw * k, .h = th * k });
            },
            else => {},
        }
    }
}
