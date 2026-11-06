//! Actor model placement for drawing: position, angle, scale and frame.

const og = @import("opengorky");
const level = @import("../level.zig");
const LevelView = level.LevelView;
const PoseKey = level.PoseKey;
const World = og.state.world.World;

/// Actor model placement for drawing (as in drawActors).
pub fn placement(self: *LevelView, o: *og.script.object.Object, model: *const og.actor.model_cache.Model) ?og.render.layer.Layer.Placement {
    const n = World.nativeOf(o);
    const angle = og.fields.modelAngle((o.getVar("angle") orelse return null).value.toFloat()) + n.actor.angle_offset;
    return .{
        .pos = og.vec.add(og.fields.pos(o), n.actor.render_offset),
        .angle = angle,
        .scale = self.world.actorScale() * n.actor.scale_mul * self.debug.scale_tweak,
        .frame = n.actor.drawFrame(model),
    };
}

const actor_slot = 4;

/// The model in the pose drawn this tick: during a transition one blended frame (with the
/// placement's frame set to it), otherwise the model itself. The pose is kept in the
/// actor's buffer not being blended from (0x44fe00), for a transition that interrupts it
/// (LevelView.poses, `level.Poses`).
pub fn posed(self: *LevelView, o: *og.script.object.Object, model: *const og.actor.model_cache.Model, pl: *og.render.layer.Layer.Placement) !*const og.actor.model_cache.Model {
    const a = &World.nativeOf(o).actor;
    return posedState(self, .{ .o = o, .slot = actor_slot }, null, a, a.blendWeight(), a.drawFrame(model), model, pl);
}

/// `posed` for a player state `st` (the actor or an extra body: `blend_from`, `plays`,
/// `from_drawn`) whose poses are `key`'s (`mesh`: the extra body's), weight `w` and
/// target frame `to`.
pub fn posedState(self: *LevelView, key: PoseKey, mesh: ?[*]const u8, st: anytype, w: ?f32, to: u32, model: *const og.actor.model_cache.Model, pl: *og.render.layer.Layer.Placement) !*const og.actor.model_cache.Model {
    const gop = try self.poses.getOrPut(self.gpa, key);
    const p = gop.value_ptr;
    if (!gop.found_existing or p.mesh != mesh) {
        if (gop.found_existing) p.deinit(self.gpa);
        p.* = .{ .plays = st.plays, .mesh = mesh };
    }
    // The start pose is the one drawn when the `play` came (no draw between: still so).
    if (p.plays != st.plays) {
        p.plays = st.plays;
        p.from = if (st.from_drawn and p.bufs[p.drawn].items.len > 0) p.drawn else null;
    }
    const out: *const og.actor.model_cache.Model = if (w) |wt|
        try og.actor.model_cache.blended(self.frame_arena.allocator(), model, if (@hasField(@TypeOf(st.*), "draw_from")) st.draw_from else st.blend_from, if (p.from) |f| p.bufs[f].items else null, if (@hasField(@TypeOf(st.*), "blend_shift")) st.blend_shift else @splat(0), to, wt)
    else
        model;
    const fr = out.frames;
    const i: u1 = if (p.from) |f| 1 - f else p.drawn;
    const buf = &p.bufs[i];
    buf.clearRetainingCapacity();
    if (fr.bones > 0 and fr.frames > 0) {
        const f = if (out == model) @min(pl.frame, fr.frames - 1) else 0;
        try buf.appendSlice(self.gpa, fr.matrices[@as(usize, f) * fr.bones ..][0..fr.bones]);
    }
    p.drawn = i;
    if (out != model) pl.frame = 0;
    return out;
}
