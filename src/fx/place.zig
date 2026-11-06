//! Points relative to an actor (position + aS·offset by its angle) and the points effect
//! parts name (core/effect.zig `At`).

const std = @import("std");
const vec = @import("../vec.zig");
const fields = @import("../fields.zig");
const Object = @import("../script.zig").object.Object;
const World = @import("../state.zig").world.World;
const At = @import("../core.zig").effect.At;
const grid = @import("../battle.zig").grid;
const weapon_class = @import("../battle.zig").weapon_class;

/// Point pos + aS·(forward, right, up) by the actor's angle.
pub fn offsetPoint(o: *Object, as: f32, d: [3]f32) [3]f32 {
    const p = fields.pos(o);
    const f = fields.forwardOf(fields.angle(o)); // forward by the exe convention (fields.facing)
    const side = [2]f32{ f[1], -f[0] };
    return .{ p[0] + (d[0] * f[0] + d[1] * side[0]) * as, p[1] + (d[0] * f[1] + d[1] * side[1]) * as, p[2] + d[2] * as };
}

/// Floor direction from `from` to `to`; if equal, forward by the actor's angle.
pub fn dirTo(who: *Object, from: [3]f32, to: [3]f32) [2]f32 {
    const d = [2]f32{ to[0] - from[0], to[1] - from[1] };
    const l = @sqrt(d[0] * d[0] + d[1] * d[1]);
    return if (l > 0) .{ d[0] / l, d[1] / l } else fields.forwardOf(fields.angle(who));
}

pub fn lifted(target: [3]f32, lift: f32, as: f32) [3]f32 {
    return if (lift == 0) target else .{ target[0], target[1], target[2] + lift * as };
}

/// Point `a` of a part `who` strikes at `target` (the aim tile centre on the floor; a
/// launch's: its target). `each_hit`: the target itself (`points` lists the fighters).
pub fn at(w: *World, who: *Object, a: At, target: [3]f32) [3]f32 {
    const as = w.actorScale();
    return switch (a) {
        .self => |o| offsetPoint(who, as, .{ o[0].get(), o[1].get(), o[2].get() }),
        .toward => |t| {
            const pp = fields.pos(who);
            const fd = dirTo(who, pp, .{ target[0], target[1], target[2] + 250 * as });
            const r = t.r.get();
            return .{ pp[0] + fd[0] * r * as, pp[1] + fd[1] * r * as, pp[2] + t.up.get() * as };
        },
        .target, .each_hit => |l| lifted(target, l, as),
        .chain => |c| lifted(target, c.lift, as),
        .sky => |s| {
            const p = fields.pos(who);
            var v = [3]f32{ p[0] - target[0] + 0.1 * as, p[1] - target[1], s.h.get() * as - target[2] };
            const vl = vec.len(v);
            const dist = s.dist.get();
            if (vl > 0) for (&v) |*c| {
                c.* *= dist * as / vl;
            };
            return .{ target[0] + v[0], target[1] + v[1], target[2] + v[2] };
        },
    };
}

/// The points of `a` into `out`: one, or for `each_hit` each fighter on the hit tiles of
/// the pending strike (its weapon's pattern at its aim: `grid.effectTiles` order, a
/// fighter once), `lift`·aS above it; none without a strike (the editor's preview,
/// `World.fx_alone`: the target).
pub fn points(w: *World, who: *Object, a: At, target: [3]f32, out: *[128][3]f32) [][3]f32 {
    const lift = switch (a) {
        .each_hit => |l| l,
        .chain => |c| c.lift,
        else => {
            out[0] = at(w, who, a, target);
            return out[0..1];
        },
    };
    const as = w.actorScale();
    if (w.fx_alone) {
        out[0] = lifted(target, lift, as);
        return out[0..1];
    }
    const b = &(w.battle orelse return out[0..0]);
    const st = switch (b.pending) {
        .attack => |s| s,
        else => return out[0..0],
    };
    const pat = weapon_class.pattern(st.weapon) orelse return out[0..0];
    const g = b.grid();
    var tiles: [128]grid.Tile = undefined;
    var seen: [128]u16 = undefined;
    var n: usize = 0;
    for (grid.effectTiles(g, pat, st.aim, &tiles)) |t| {
        const k = g.at(t);
        if (k == grid.Grid.none) continue;
        if (std.mem.indexOfScalar(u16, seen[0..n], k) != null) continue;
        seen[n] = k;
        const p = fields.pos(b.fighters.items[k].obj);
        out[n] = .{ p[0], p[1], p[2] + lift * as };
        n += 1;
    }
    return out[0..n];
}

/// `pts` as a chain from `from` (core/effect.zig `At.chain`): each the nearest of the rest
/// to the one before (ties: the first listed), at most `n` (0: all).
pub fn chainOrder(from: [3]f32, pts: [][3]f32, n: u32) [][3]f32 {
    var prev = from;
    const len = if (n == 0) pts.len else @min(pts.len, n);
    for (0..len) |i| {
        var best = i;
        for (i + 1..pts.len) |j| {
            if (vec.len(vec.sub(pts[j], prev)) < vec.len(vec.sub(pts[best], prev))) best = j;
        }
        std.mem.swap([3]f32, &pts[i], &pts[best]);
        prev = pts[i];
    }
    return pts[0..len];
}

test chainOrder {
    var pts = [_][3]f32{ .{ 10, 0, 0 }, .{ 1, 0, 0 }, .{ 5, 0, 0 }, .{ 2, 0, 0 } };
    const got = chainOrder(.{ 0, 0, 0 }, &pts, 3);
    try std.testing.expectEqualSlices([3]f32, &.{ .{ 1, 0, 0 }, .{ 2, 0, 0 }, .{ 5, 0, 0 } }, got);
}
