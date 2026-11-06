//! A project's frame post-processing (OpenGorky rules `PostChain`, core/effect.zig `Post`):
//! built-in CPU programs over an RGBA picture, in order. Classic has none.

const std = @import("std");
const num = @import("../num.zig");
const Post = @import("../effects.zig").material.Post;

/// `steps` over `px` (`w`×`h` RGBA, rows `pitch` bytes apart).
/// shortcut: one thread, a few ms a step at 4K; split rows over the raster pool if chains grow.
pub fn apply(steps: []const Post, px: []u8, w: usize, h: usize, pitch: usize) void {
    const fw = num.toF32(w);
    const fh = num.toF32(h);
    for (steps) |s| for (0..h) |y| {
        const row = px[y * pitch ..][0 .. w * 4];
        const fy = (num.toF32(y) + 0.5) / fh * 2 - 1;
        // A 480-line screen's odd lines, whatever the detail.
        const odd = (y * 480 / h) % 2 == 1;
        for (0..w) |x| {
            const p = row[x * 4 ..][0..3];
            var c = [3]f32{ num.toF32(p[0]), num.toF32(p[1]), num.toF32(p[2]) };
            switch (s.program) {
                // Colour ×rgb, then saturation ×k around the luminance.
                .grade => {
                    for (&c, s.rgb) |*ch, g| ch.* *= g;
                    const l = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
                    for (&c) |*ch| ch.* = l + (ch.* - l) * s.k;
                },
                // Darker by k toward the corners (the square of the distance from the centre).
                .vignette => {
                    const fx = (num.toF32(x) + 0.5) / fw * 2 - 1;
                    const d = 1 - s.k * (fx * fx + fy * fy) / 2;
                    for (&c) |*ch| ch.* *= d;
                },
                .scanlines => if (odd) for (&c) |*ch| {
                    ch.* *= 1 - s.k;
                },
            }
            for (p, c) |*o, v| o.* = @intFromFloat(std.math.clamp(@round(v), 0, 255));
        }
    };
}

test "grade, vignette and scanlines" {
    var px: [2 * 4 * 4]u8 = @splat(200);
    // Grade: red ×0.5, saturation unchanged (k = 1).
    apply(&.{.{ .program = .grade, .rgb = .{ 0.5, 1, 1 } }}, &px, 2, 4, 8);
    try std.testing.expectEqual(@as(u8, 100), px[0]);
    try std.testing.expectEqual(@as(u8, 200), px[1]);
    // Saturation 0: grey.
    apply(&.{.{ .program = .grade, .k = 0 }}, &px, 2, 4, 8);
    try std.testing.expectEqual(px[1], px[0]);
    // Scanlines: screen line 1 darker by half, line 0 kept.
    var tall: [1 * 480 * 4]u8 = @splat(200);
    apply(&.{.{ .program = .scanlines, .k = 0.5 }}, &tall, 1, 480, 4);
    try std.testing.expectEqual(@as(u8, 200), tall[0]);
    try std.testing.expectEqual(@as(u8, 100), tall[4]);
    // Vignette: the corners darker than the centre.
    var sq: [9 * 9 * 4]u8 = @splat(200);
    apply(&.{.{ .program = .vignette, .k = 0.8 }}, &sq, 9, 9, 36);
    try std.testing.expect(sq[0] < sq[(4 * 9 + 4) * 4]);
    try std.testing.expectEqual(@as(u8, 200), sq[3]);
}
