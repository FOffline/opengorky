//! Field effects: projectiles, beams, flashes, fire, gas, explosions, trails — attached to model points and drawn.

const billboards = @import("billboards.zig");
const place = @import("place.zig");
const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const og = @import("opengorky");
const EffectsView = @import("effects_view.zig").EffectsView;

/// World position of actor link point `link` (current frame), if it has a model.
fn linkWorld(self: *LevelView, o: *og.script.object.Object, link: []const u8) ?[3]f32 {
    const m = (self.models orelse return null).get(og.fields.meshFile(o)) orelse return null;
    const pl = place.placement(self, o, m) orelse return null;
    const lp = og.actor.model_cache.linkPoint(m, @min(pl.frame, m.frames.frames -| 1), link) orelse return null;
    return og.actor.model_cache.toWorld(m, lp, pl.scale * m.unitScale(), pl.pos, @cos(pl.angle), @sin(pl.angle));
}
/// Link point `link` and the horizontal unit axis of its x (0x429ca0: the same
/// point with x + 1; the exe takes p0 − p1 and draws along −(p0 − p1)).
fn ionAxis(self: *LevelView, o: *og.script.object.Object, link: []const u8) ?[2][3]f32 {
    const m = (self.models orelse return null).get(og.fields.meshFile(o)) orelse return null;
    const pl = place.placement(self, o, m) orelse return null;
    const frame = @min(pl.frame, m.frames.frames -| 1);
    const l0 = og.actor.model_cache.linkPoint(m, frame, link) orelse return null;
    const l1 = og.actor.model_cache.linkPointOff(m, frame, link, .{ 1, 0, 0 }) orelse return null;
    const s = pl.scale * m.unitScale();
    const ca = @cos(pl.angle);
    const sa = @sin(pl.angle);
    const p0 = og.actor.model_cache.toWorld(m, l0, s, pl.pos, ca, sa);
    const p1 = og.actor.model_cache.toWorld(m, l1, s, pl.pos, ca, sa);
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const l = @sqrt(dx * dx + dy * dy);
    if (l < 1e-6) return null;
    return .{ p0, .{ dx / l, dy / l, 0 } };
}
/// Batch billboards and the other effect draws (og.effects.batch) on screen (off combat
/// levels: the flush turns the z-test off).
const ViewSink = struct {
    v: *EffectsView,
    ctx: @import("effects_view.zig").Frame,
    pub fn put(s: ViewSink, b: billboards.Billboard) !void {
        try s.v.billboard(s.ctx, b.name, b.frame, b.pos, b.half, sdlAlpha(b.alpha, b.program, b.k), b.rgb, sdlBlend(b));
    }
    pub fn ribbon(s: ViewSink, q: og.effects.batch.RibbonQuad) !void {
        const side = if (q.facing) |at| blk: {
            const r0 = EffectsView.screenRight(s.ctx.cam, at);
            break :blk [3]f32{ r0[0] * q.half, r0[1] * q.half, 0 };
        } else q.side;
        const k = sdlAlpha(q.alpha, q.program, q.k);
        try s.v.ribbon(s.ctx, q.name, q.frame, q.a, q.b, side, q.uv[0], q.uv[1], .{ q.rgb[0] * k, q.rgb[1] * k, q.rgb[2] * k });
    }
    pub fn mesh(s: ViewSink, m: og.effects.batch.MeshAt) !void {
        try s.v.drawMeshAdd(s.ctx, m.name, m.pos, m.dir, m.scale, m.stretch, m.k);
    }
    /// A flame particle: a screen quad around the projected point.
    pub fn particle(s: ViewSink, b: billboards.Billboard) !void {
        const q = s.ctx.cam.project(b.pos);
        try s.v.screenQuad(b.name, b.frame, .{ q.x - s.ctx.scroll[0] - b.half, q.y - s.ctx.scroll[1] - b.half, 2 * b.half, 2 * b.half }, sdlAlpha(b.alpha, b.program, b.k), b.rgb, sdlBlend(b));
    }
};

/// The `.dsc` blend a billboard overrides (null: its own): a material's, else additive.
fn sdlBlend(b: billboards.Billboard) ?og.effects.dsc.Blend {
    if (b.blend) |m| return switch (m) {
        .add => .add,
        .alpha => .alpha,
        .screen => .screen,
    };
    return if (b.add) .add else null;
}

/// A material's program on the SDL pass (no CPU program there): a dissolve fades by k.
fn sdlAlpha(a: f32, p: og.effects.batch.Program, k: f32) f32 {
    return if (p == .dissolve) a * (1 - k) else a;
}

/// Model points of the level's actors (current frame).
const ViewLinks = struct {
    self: *LevelView,
    pub fn point(l: ViewLinks, o: *og.script.object.Object, name: []const u8) ?[3]f32 {
        return linkWorld(l.self, o, name);
    }
    pub fn axis(l: ViewLinks, o: *og.script.object.Object, name: []const u8) ?[2][3]f32 {
        return ionAxis(l.self, o, name);
    }
};

/// World effects: planes, flashes on link points, blood, flamethrower, fire.
pub fn drawEffects(self: *LevelView, scroll: [2]f32) !void {
    const v = self.fx_view orelse return;
    const w = self.world;
    const e = &w.effects;
    const cam = w.cam;
    const as = w.actorScale();
    const ticks = e.ticks;
    const ctx: @import("effects_view.zig").Frame = .{ .arena = self.frame_arena.allocator(), .cam = cam, .scroll = scroll };
    // Batch billboards (billboards.zig) go to the actor layer on combat levels.
    const combat = w.isCombat();
    const view: ViewSink = .{ .v = v, .ctx = ctx };
    if (!combat) try billboards.fireCells(self, view);
    if (w.battle) |*b| {
        // Burning fighter (0x4dc700): "Flame" additive over the model's screen box
        // (+0x64…+0x70) raised by height/8, brightness alpha·fighter_fire_intensity.
        for (b.fighters.items, 0..) |f, i| {
            if (!f.alive() or f.burning <= 0) continue;
            const a = og.state.world.actorOf(f.obj);
            const box = a.screen_box orelse continue;
            const h = box[3] - box[1];
            const k = og.num.toF32(a.alpha) / 255 * og.rules.adjust.float("fighter_fire_intensity");
            try v.screenQuad("flame", @intCast((ticks + i * 5) % 15), .{ box[0] - scroll[0], box[1] - @trunc(h / 8) - scroll[1], box[2] - box[0], h }, k, .{ 1, 1, 1 }, .add);
        }
    }
    _ = self.frame_arena.reset(.retain_capacity);
    // Effects on link points go into the model layer with depth testing
    // (actors_view.attachedEffects).
    if (!combat) try billboards.incubusGlow(self, view);
    // Morph (0x4260a0): mesh "nowy" ×(3, 3, 4)·aS additive at brightness 0.5·p.
    {
        // Glow ×(morf_scale, morf_scale, morf_scale_z)·aS at morf_a·p (0x426140, 0x426179).
        const adj = og.rules.adjust;
        const ms = adj.float("morf_scale");
        const mz = adj.float("morf_scale_z");
        const ma = adj.float("morf_a");
        for (e.morphs.items) |mo| try v.drawMeshAdd(ctx, "nowy", mo.pos, .{ 0, 1, 0 }, as * ms, mz / ms, ma * mo.p);
    }
    if (!combat) try billboards.morphSparks(self, view);
    // Schizo gas cloud (0x4a95d0): "gas2" in a circle, fades over 30 ticks.
    try og.effects.batch.clouds(e.clouds.items, as, view);
    if (!combat) {
        try billboards.bitmaps(self, view);
        try billboards.blood(self, view);
    }
    try og.effects.batch.beams(e.beams.items, ticks, as, ViewLinks{ .self = self }, view);
    try og.effects.batch.streams(e.streams.items, ticks, as, view);
    try og.effects.batch.spins(e.spins.items, as, view);
    // Projectiles: mesh or plane; a rocket is "Rocket1" with exhaust "Rocket" behind
    // (220·aS); molotov flame.
    if (!combat) try billboards.trails(self, view);
    for (e.projectiles.items) |pr| try drawProjectile(v, ctx, pr, ticks, as);
    if (!combat) try billboards.projectilePlanes(self, view);
    try og.effects.batch.flames(e.flames.items, ticks, as, view);
}

/// One projectile: mesh or plane, Cutter Pill bullet, rocket with exhaust, molotov flame.
fn drawProjectile(v: *EffectsView, ctx: @import("effects_view.zig").Frame, pr: og.effects.projectile.Projectile, ticks: u64, as: f32) !void {
    const cam = ctx.cam;
    const scroll = ctx.scroll;
    if (pr.done) return;
    // The projectile nose in the exe is the −Y axis of its frame (0x49b0a0: basis
    // S, U, d and Rx(−π/2)); ours is the mesh's −Z, so draw reversed or the
    // orbital rocket (pocisk) falls tail first.
    if (pr.mesh.len > 0) try v.drawMesh(ctx, pr.mesh, pr.pos, .{ -pr.dir[0], -pr.dir[1], -pr.dir[2] }, pr.roll, as * pr.mesh_scale * pr.k);
    if (pr.bullet) {
        // Cutter Pill bullet (0x49df20): chaingun.msh with "arrows" (mode 2) along
        // the direction, at pos − dir·240·aS, scale 0.6·aS.
        const at = [3]f32{ pr.pos[0] - pr.dir[0] * 240 * as, pr.pos[1] - pr.dir[1] * 240 * as, pr.pos[2] - pr.dir[2] * 240 * as };
        try v.drawEffectMesh(ctx, pr.effect, 0, at, pr.dir, pr.mesh_scale * as, .alpha);
        return;
    }
    if (pr.rocket) {
        // Rocket (0x49bfb0): body chaingun.msh with "Rocket1" (mode 2) ×0.3·aS·scale
        // along the flight; exhaust "Rocket" (frame (t/2)%2, mode 4) ×0.4·aS
        // 220·aS behind.
        const back = [3]f32{ pr.pos[0] - pr.dir[0] * 220 * as, pr.pos[1] - pr.dir[1] * 220 * as, pr.pos[2] - pr.dir[2] * 220 * as };
        try v.drawEffectMesh(ctx, "Rocket", @intCast((pr.ticks / 2) % 2), back, pr.dir, 0.4 * as, .screen);
        try v.drawEffectMesh(ctx, pr.effect, 0, pr.pos, pr.dir, 0.3 * as * pr.mesh_scale, .alpha);
    }
    if (pr.flame) {
        // Flame (0x49d440): point (25, 45, 45) in bottle axes (tumble +0x320 and
        // flight matrix +0x2f8), a 10×14 screen quad with its corner at the point
        // − (5, 6) (0x49d6a4…0x49d74b), "flame" frame (tick/2) cycling.
        const d = [3]f32{ -pr.dir[0], -pr.dir[1], -pr.dir[2] };
        const at = v.meshPoint(pr.mesh, pr.pos, d, pr.roll, as * pr.mesh_scale * pr.k, .{ 25, 45, 45 }) orelse pr.pos;
        const q = cam.project(at);
        try v.screenQuad("flame", @intCast((ticks / 2) % 15), .{ q.x - scroll[0] - 5, q.y - scroll[1] - 6, 10, 14 }, 1, .{ 1, 1, 1 }, null);
    }
}
