//! Explosions and one-shot bitmap effects.

const World = @import("../state.zig").world.World;
const effects = @import("../effects.zig");
const adjust = @import("../rules.zig").adjust;

/// Explosion (0x4d0610) at `p`: UiEffects `explosion` (the exe's explosion1), step explosion_speed (1)·0.5, on the
/// next tick (Delayer 0x4cd7b0 with delay 0). On a battle level (0x696ea0) 700·aS
/// higher, size explosion_scale (1000), otherwise ×1.5 without the lift. No smoke
/// or shrapnel: the exe only registers explosion_smoke_*, explosion_shrepnel_*,
/// rocket1_explosion_* and barrel_explosion_* (0x4cfea0…0x4d05d5) and never creates
/// the shrapnel class (0x4d0b30, shrapnel_*).
pub fn explosion(w: *World, p: [3]f32) void {
    const as = w.actorScale();
    const combat = w.isCombat();
    const scale = adjust.float("explosion_scale");
    bitmap(w, .{
        .effect = @import("../core.zig").modules.ui().effects.explosion,
        .pos = .{ p[0], p[1], if (combat) p[2] + 700 * as else p[2] },
        .size = if (combat) scale else scale * 1.5,
        .step = adjust.float("explosion_speed") * 0.5,
        .delay = 1,
    });
}

/// Spawn a one-shot bitmap effect; its frame count comes from the effect's `.dsc` (20 without
/// models, 1 if the effect is missing).
pub fn bitmap(w: *World, b: effects.bitmap.Bitmap) void {
    var x = b;
    if (w.res.models) |m| x.frames = if (m.effect(b.effect)) |d| @intCast(d.frames.len) else 1;
    w.effects.addBitmap(w.gpa, x);
}
