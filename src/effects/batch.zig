//! What world effects draw, enumerated once for every client: billboards of the exe's
//! particle batch (0x45e150: bitmaps, trails, projectile planes), beams and streams as
//! ribbon quads, effect meshes, gas clouds and flame particles. Each enumerator hands them
//! to a sink — the viewer's level renderer, the editor's model preview — with methods
//! `put(Billboard)`, `ribbon(RibbonQuad)`, `mesh(MeshAt)`, `particle(Billboard)` (a flame
//! particle: `half` in screen pixels around the projected point), in the viewer's order
//! and floats. Model points come from `links`: `point(actor, name) ?[3]f32` and
//! `axis(actor, name) ?[2][3]f32` (the point and the horizontal unit axis of its x).

const std = @import("std");
const num = @import("../num.zig");
const vec = @import("../vec.zig");
const rules = @import("../rules.zig");
const bitmap = @import("bitmap.zig");
const projectile = @import("projectile.zig");
const beam = @import("beam.zig");
const flame = @import("flame.zig");

/// One batch billboard: `.dsc` effect `name`, half size `half`, colour `rgb`, alpha;
/// `add`: additive whatever its `.dsc` says (a beam's chain); `blend`: a material's,
/// over both (null: none). `program`, `k`: a material's CPU program (the software layer's; `dress`).
pub const Billboard = struct { name: []const u8, frame: u32, pos: [3]f32, half: f32, alpha: f32 = 1, rgb: [3]f32 = .{ 1, 1, 1 }, add: bool = false, blend: ?Blend = null, program: Program = .none, k: f32 = 0 };

pub const Program = @import("material.zig").Program;
pub const Blend = @import("material.zig").Blend;

/// What a material makes of a draw at its part's age: colour and alpha factors, its blend
/// (null: as drawn), its program.
const Dress = struct { rgb: [3]f32 = .{ 1, 1, 1 }, alpha: f32 = 1, blend: ?Blend = null, program: Program = .none, k: f32 = 0 };

/// Material `name` at `age` of a part living `life` ticks ("" or unknown: none).
fn dress(name: []const u8, age: u32, life: u32) Dress {
    if (name.len == 0) return .{};
    const m = @import("material.zig").lookup(name) orelse return .{};
    var d: Dress = .{ .alpha = m.alpha.after(age, life), .blend = m.blend, .program = m.program, .k = m.k.after(age, life) };
    for (&d.rgb, m.rgb) |*c, t| c.* = t.after(age, life);
    return d;
}

fn dressed(b: Billboard, d: Dress) Billboard {
    var x = b;
    for (&x.rgb, d.rgb) |*c, f| c.* *= f;
    x.alpha *= d.alpha;
    if (d.blend) |bl| x.blend = bl;
    x.program = d.program;
    x.k = d.k;
    return x;
}

/// A strip A→B offset ±`side` across, texture `uv[0]`…`uv[1]` along and 0…1 across,
/// additive, colour `rgb`·`alpha`. `facing`: a camera-facing strip, its side the camera's
/// horizontal right at that point ·`half` (the sink's camera).
pub const RibbonQuad = struct { name: []const u8, frame: u32, a: [3]f32, b: [3]f32, side: [3]f32 = @splat(0), uv: [2]f32 = .{ 0, 1 }, facing: ?[3]f32 = null, half: f32 = 0, alpha: f32 = 1, rgb: [3]f32 = .{ 1, 1, 1 }, program: Program = .none, k: f32 = 0 };

/// Mesh `name` with its own texture, additive at brightness `k`, turned to `dir`, ×`scale`,
/// stretched vertically by `stretch`.
pub const MeshAt = struct { name: []const u8, pos: [3]f32, dir: [3]f32, scale: f32, stretch: f32 = 1, k: f32, program: Program = .none, pk: f32 = 0 };

/// Bitmaps and flashes (0x4cb600, draw 0x4cb8b0); `as` is actorScale.
pub fn bitmaps(items: []const bitmap.Bitmap, as: f32, sink: anytype) !void {
    for (items) |bm| {
        if (bm.delay > 0) continue;
        try sink.put(dressed(.{ .name = bm.effect, .frame = if (bm.flash_rate > 0) 0 else bm.frame(), .pos = bm.pos, .half = as * bm.drawSize(), .alpha = bm.alpha, .rgb = bm.rgb }, dress(bm.material, bm.frame(), bm.frames)));
    }
}

/// Trails (0x4cd4a0): separate objects that outlive the projectile; size and
/// brightness fall toward the tail.
pub fn trails(items: []const projectile.Trail, as: f32, sink: anytype) !void {
    for (items) |t| {
        var s: f32 = 1;
        var a: f32 = 1;
        var idx: usize = t.head;
        for (0..t.count) |k| {
            if (s <= 0.01 or a <= 0.01) break;
            if (k >= t.eaten) try sink.put(.{ .name = t.effect, .frame = @intCast(k), .pos = t.pts[idx], .half = as * s * t.size, .alpha = a, .rgb = t.rgb });
            s -= t.size_fade;
            a *= t.fade;
            idx = (idx + 1) % projectile.Trail.ring;
        }
    }
}

/// Projectile planes (0x49bab0): a projectile without a body mesh, bullet or rocket.
pub fn projectilePlanes(items: []const projectile.Projectile, as: f32, sink: anytype) !void {
    for (items) |pr| {
        if (pr.done or pr.bullet or pr.rocket or pr.effect.len == 0) continue;
        if (pr.ball) |b| {
            // Ball (0x4a6280): two "kula" frames cross-fading by wave a, sizes ±40·b,
            // then "poswiata" 400 tinted (0.2 + 0.08a, 0.2, 0.4); scale / attack_ball_ms.
            const s = pr.k * pr.mesh_scale / (pr.ball_ms orelse projectile.attackBallMs());
            const fade = 2.5 * b.a + 0.5;
            try sink.put(.{ .name = "kula", .frame = b.f1, .pos = pr.pos, .half = as * (130 * s + 40 * b.b), .alpha = fade });
            try sink.put(.{ .name = "kula", .frame = b.f2, .pos = pr.pos, .half = as * (130 * s + 8 - 40 * b.b), .alpha = 1 - fade });
            try sink.put(.{ .name = "poswiata", .frame = 0, .pos = pr.pos, .half = as * 400 * s, .rgb = .{ 0.2 + 0.08 * b.a, 0.2, 0.4 } });
            continue;
        }
        try sink.put(.{ .name = pr.effect, .frame = pr.ticks, .pos = pr.pos, .half = as * pr.size * pr.k });
    }
}

/// A sink's ribbons dressed by a material (colour, alpha, program).
fn Ribbons(comptime S: type) type {
    return struct {
        sink: S,
        d: Dress,
        fn ribbon(r: @This(), q: RibbonQuad) !void {
            var x = q;
            x.alpha = r.d.alpha;
            x.rgb = r.d.rgb;
            x.program = r.d.program;
            x.k = r.d.k;
            try r.sink.ribbon(x);
        }
    };
}

/// Offset across ribbon A→B (0x4a3c30): the direction rotated 90° in XY, ·`half`; for a
/// vertical ribbon — right along X.
fn sideOf(a: [3]f32, b: [3]f32, half: f32) [3]f32 {
    const d = vec.sub(b, a);
    const l = vec.len2(d);
    if (l < 1e-4) return .{ half, 0, 0 };
    return .{ -d[1] / l * half, d[0] / l * half, 0 };
}

/// Beams (texture frame (T / div) % n), additive: a billboard chain, the ion's runs along
/// its axis, a laser from a link point, a current between two, a lightning strip.
pub fn beams(items: []const beam.Beam, ticks: u64, as: f32, links: anytype, sink: anytype) !void {
    for (items) |bm| {
        if (bm.delay > 0) continue;
        const frame: u32 = @intCast((ticks / bm.div) % 4096);
        const half = as * bm.size;
        const dr = dress(bm.material, bm.ticks, bm.left);
        const rs = Ribbons(@TypeOf(sink)){ .sink = sink, .d = dr };
        switch (bm.kind) {
            // Planes along the segment at half-size steps.
            .billboards => {
                const d = vec.sub(bm.to, bm.from);
                const len = vec.len(d);
                const n: usize = @intFromFloat(@min(200, @max(1, len / @max(1, half))));
                for (0..n + 1) |k| {
                    const t = num.toF32(k) / num.toF32(n);
                    const p = [3]f32{ bm.from[0] + d[0] * t, bm.from[1] + d[1] * t, bm.from[2] + d[2] * t };
                    try sink.put(dressed(.{ .name = bm.effect, .frame = frame, .pos = p, .half = half, .add = true }, dr));
                }
            },
            // Ion (0x4a18d0): runs of segments both ways from the shooter, like the hit
            // area (class 6 sets: a line of −40…40 cells, 0x4b8192). The exe recomputes
            // start and direction each frame (0x4a1919): the actor's link point and its x
            // axis (0x429ca0); the height is the one stored at the shot (+0x2ec); the axis
            // turns by `turn` (0x4a19c3/0x4a19e4). So the beam leaves the muzzle and behind
            // the stock and sways with the rifle's recoil.
            .ion => {
                var o = bm.from;
                var d = bm.dir;
                if (bm.actor) |a| if (links.axis(a, bm.link)) |ax| {
                    o = .{ ax[0][0], ax[0][1], bm.from[2] };
                    const tc = @cos(bm.turn);
                    const ts = @sin(bm.turn);
                    d = .{ ax[1][0] * tc - ax[1][1] * ts, ax[1][0] * ts + ax[1][1] * tc, 0 };
                };
                const side = [3]f32{ -d[1] * half, d[0] * half, 0 };
                for (bm.chains) |c| {
                    var p = [3]f32{ o[0] + d[0] * c.start * as, o[1] + d[1] * c.start * as, o[2] };
                    for (0..c.n) |_| {
                        const q = [3]f32{ p[0] + d[0] * c.step * as, p[1] + d[1] * c.step * as, p[2] };
                        try rs.ribbon(.{ .name = bm.effect, .frame = frame, .a = p, .b = q, .side = side });
                        p = q;
                    }
                }
            },
            // Guard laser (0x4a4f80): from the eye (recomputed each frame) to the target.
            .laser => {
                const a = links.point(bm.actor orelse continue, bm.link) orelse continue;
                try rs.ribbon(.{ .name = bm.effect, .frame = frame, .a = a, .b = bm.to, .side = sideOf(a, bm.to, half) });
            },
            // Medusa current (0x4a3c30): between two link points.
            .current => {
                const o = bm.actor orelse continue;
                const a = links.point(o, bm.link) orelse continue;
                const b = links.point(o, bm.link2) orelse continue;
                try rs.ribbon(.{ .name = bm.effect, .frame = frame, .a = a, .b = b, .side = sideOf(a, b, half) });
            },
            // Lightning (0x4a7ac0): 4 parts of 1400·aS upward from the target, facing the camera.
            .lightning => for (0..4) |k| {
                const z0 = num.toF32(k) * 1400 * as;
                const a = [3]f32{ bm.to[0], bm.to[1], bm.to[2] + z0 };
                const b = [3]f32{ bm.to[0], bm.to[1], bm.to[2] + z0 + 1400 * as };
                try rs.ribbon(.{ .name = bm.effect, .frame = frame, .a = a, .b = b, .facing = bm.to, .half = half });
            },
        }
    }
}

/// Streams (0x4a3000): point i moved along v by (n − i)·step·aS; a segment draws until its
/// point reaches the target; half-width `width`·aS, the texture shifts by `uv_step` per
/// segment, the last `taper_n` segments narrow.
pub fn streams(items: []const projectile.Stream, ticks: u64, as: f32, sink: anytype) !void {
    for (items) |st| {
        if (st.n < 2 or st.delay > 0) continue;
        const lk = st.look;
        const frame: u32 = @intCast((ticks / 2) % 4096);
        const rs = Ribbons(@TypeOf(sink)){ .sink = sink, .d = dress(lk.material, lk.life -| st.left, lk.life) };
        var acc: f32 = 0;
        var i: u32 = 0;
        while (i + 1 < st.n) : (i += 1) {
            const d0 = st.dist(i);
            if (d0 >= st.len) continue;
            const d1 = @min(st.dist(i + 1), st.len);
            const a = [3]f32{ st.pts[i][0] + st.v[0] * d0, st.pts[i][1] + st.v[1] * d0, st.pts[i][2] + st.v[2] * d0 };
            const b = [3]f32{ st.pts[i + 1][0] + st.v[0] * d1, st.pts[i + 1][1] + st.v[1] * d1, st.pts[i + 1][2] + st.v[2] * d1 };
            const tail = st.n - 1 - i;
            const taper: f32 = if (tail <= lk.taper_n) @max(0.1, 1 - lk.taper * num.toF32(lk.taper_n - tail + 1)) else 1;
            try rs.ribbon(.{ .name = lk.effect, .frame = frame, .a = a, .b = b, .side = sideOf(a, b, as * lk.width * taper), .uv = .{ acc, acc + lk.uv_step } });
            acc = @mod(acc + lk.uv_step, 1);
        }
    }
}

/// Spinning meshes (satellite beam 0x4a7350): Rz(spin), ×scale·aS, colour = brightness.
pub fn spins(items: []const beam.Spin, as: f32, sink: anytype) !void {
    for (items) |sp| {
        if (sp.delay > 0 or sp.alpha.v <= 0) continue;
        const d = dress(sp.material, sp.ticks, 0);
        try sink.mesh(.{ .name = sp.mesh, .pos = sp.pos, .dir = .{ @cos(sp.spin.v), @sin(sp.spin.v), 0 }, .scale = as * sp.scale, .k = sp.alpha.v * d.alpha, .program = d.program, .pk = d.k });
    }
}

/// Gas clouds (0x4a95d0): frames loop (tick / 2), fading in and out.
pub fn clouds(items: []const flame.Cloud, as: f32, sink: anytype) !void {
    for (items) |cl| {
        const a: f32 = if (cl.fading > 0) num.toF32(cl.fading) / num.toF32(cl.fade_out) else @min(1, num.toF32(cl.ticks) / num.toF32(cl.fade_in));
        try sink.put(dressed(.{ .name = cl.effect, .frame = cl.ticks / 2, .pos = cl.pos, .half = as * cl.size, .alpha = a }, dress(cl.material, cl.ticks, 0)));
    }
}

/// Flame particles (0x4a0270): a particle is an additive screen quad with half-size
/// min(age·attack_flame_scale 1.6 + attack_flame_add 8, attack_flame_range 160); colour
/// from attack_flame_col2 (60,60,255) when new to attack_flame_col (255,160,0) when old
/// (t = remaining life / life); "flame2" frame and ±5·aS jitter on x, y.
/// shortcut: frame and jitter from a hash of the tick, not the exe's rand() (drawing only).
pub fn flames(items: []const flame.Flame, ticks: u64, as: f32, sink: anytype) !void {
    const game = flameTune(null);
    for (items, 0..) |fl, fi| for (fl.parts.items, 0..) |p, i| {
        const look = fl.tune orelse game;
        const h = std.hash.Murmur2_32.hashUint64(ticks *% 2654435761 +% i *% 40503 +% fi);
        const jx = (num.toF32(h % 10) - 5) * as;
        const jy = (num.toF32((h / 10) % 10) - 5) * as;
        if (fl.look) |lk| {
            // A mod's look: its tracks at the particle's age.
            var rgb: [3]f32 = undefined;
            for (&rgb, lk.rgb) |*c, tr| c.* = tr.after(p.age, fl.life);
            try sink.particle(dressed(.{ .name = lk.sprite, .frame = if (lk.frames > 0) (h / 100) % lk.frames else 0, .pos = .{ p.pos[0] + jx, p.pos[1] + jy, p.pos[2] }, .half = lk.size.after(p.age, fl.life), .alpha = lk.alpha.after(p.age, fl.life), .rgb = rgb, .add = lk.add }, dress(fl.material, p.age, fl.life)));
            continue;
        }
        const t = 1 - num.toF32(p.age) / num.toF32(fl.life);
        const half = @min(num.toF32(p.age) * look.scale + look.add, look.range);
        var rgb: [3]f32 = undefined;
        for (&rgb, look.old, look.new) |*c, o, n| c.* = (o + (n - o) * t) / 255;
        try sink.particle(dressed(.{ .name = "flame2", .frame = @intCast((h / 100) % 15), .pos = .{ p.pos[0] + jx, p.pos[1] + jy, p.pos[2] }, .half = half, .rgb = rgb, .add = true }, dress(fl.material, p.age, fl.life)));
    };
}

/// Flame particle look of weapon `w`'s flames (attack_flame_*: its own, else the game's).
pub fn flameTune(w: ?rules.Who) flame.Tune {
    const old = rules.weaponRgb("attack_flame_col", w);
    const new = rules.weaponRgb("attack_flame_col2", w);
    var o: [3]f32 = undefined;
    var n: [3]f32 = undefined;
    for (&o, &n, old, new) |*a, *b, x, y| {
        a.* = @floatFromInt(x);
        b.* = @floatFromInt(y);
    }
    return .{ .scale = rules.weaponFloat("attack_flame_scale", w), .add = @floatFromInt(rules.weaponInt("attack_flame_add", w)), .range = @floatFromInt(rules.weaponInt("attack_flame_range", w)), .old = o, .new = n };
}
