//! Beams: ion, Medusa's current, Guard lasers, satellite lightning (`Beam`) and the
//! satellite energy beam (`Spin`).

const std = @import("std");
const Object = @import("../script.zig").object.Object;

/// Beam kind (0x4a1600, 0x4a3960, 0x4a4c70, 0x4a7710); all additive, texture frame
/// (T>>1)%n (lightning T%n).
const BeamKind = enum {
    /// Quads along the segment, half a size apart.
    billboards,
    /// Ion rifle: `chains` of segments as a ribbon along `dir` (the ion: two of 25);
    /// fixed length (independent of the target).
    ion,
    /// Guard eye laser: ribbon from the actor's `link` point to `to`.
    laser,
    /// Ribbon between the actor's link points `link` → `link2` (Medusa's current: two
    /// beams, current1→current3 and current2→current4).
    current,
    /// Satellite lightning: a camera-facing vertical strip, 4 parts above `to`.
    lightning,
};

/// Beam (ion 0x4a1600, lightning 0x4a7710): a chain of quads from `from` to `to`, frame
/// (tick / div) % frames, lives `left` ticks.
pub const Beam = struct {
    kind: BeamKind = .billboards,
    effect: []const u8,
    from: [3]f32,
    to: [3]f32,
    /// Half width (in aS units).
    size: f32,
    left: u32,
    div: u32 = 2,
    ticks: u32 = 0,
    /// For `.laser` and `.current`: whose link points.
    actor: ?*Object = null,
    link: []const u8 = "",
    /// For `.current`: the second link point.
    link2: []const u8 = "",
    /// For `.ion`: segment runs along the axis (`n` 0: none).
    chains: [4]Chain = @splat(.{}),
    /// Ticks before it shows and lives.
    delay: u32 = 0,
    /// For `.ion`: horizontal beam direction (unit) at the shot; with `actor` and `link` the
    /// start and direction follow the weapon point every frame.
    dir: [3]f32 = .{ 1, 0, 0 },
    /// For `.ion`: direction rotation around the vertical (−0.09, Slavsky 0.4).
    turn: f32 = 0,
    /// A mod's material (core/effect.zig Material; "": none).
    material: []const u8 = "",

    pub fn tick(b: *Beam, _: void) bool {
        if (b.delay > 0) {
            b.delay -= 1;
            return true;
        }
        b.ticks += 1;
        return b.ticks < b.left;
    }
};

/// One run of an ion beam (0x4a2172, 0x4a2490): `n` segments of `step`·aS from `start`·aS
/// along the axis, each starting where the last ended.
const Chain = struct { start: f32 = 0, step: f32 = 0, n: u32 = 0 };

/// A value stepped each tick (not a function of time: `v += rate` keeps the exe's
/// floats): clamped to `min`…`max`, wrapped by `wrap` (0: not), its rate flipping when
/// the owner's life left reaches `flip_at` (0: never); below `kill_below` it ends the owner.
/// shortcut: one rate flip; a list of keys when an effect needs more.
pub const Track = struct {
    v: f32 = 0,
    rate: f32 = 0,
    min: f32 = -std.math.inf(f32),
    max: f32 = std.math.inf(f32),
    wrap: f32 = 0,
    flip_at: u32 = 0,
    kill_below: ?f32 = null,

    pub fn step(t: *Track) void {
        var x = @max(t.min, @min(t.max, t.v + t.rate));
        if (t.wrap != 0) x = @mod(x, t.wrap);
        t.v = x;
    }

    pub fn key(t: *Track, left: u32) void {
        if (t.flip_at != 0 and left == t.flip_at) t.rate = -t.rate;
    }

    /// The value `n` ticks from its start in an owner living `life` (as Spin steps it:
    /// step, then the key at the life left), for a particle by its age.
    pub fn after(t: Track, n: u32, life: u32) f32 {
        var x = t;
        for (0..n) |i| {
            x.step();
            x.key(life -| @as(u32, @intCast(i + 1)));
        }
        return x.v;
    }

    pub fn dead(t: Track) bool {
        return if (t.kill_below) |k| t.v < k else false;
    }
};

/// Satellite energy beam (0x4a7020): mesh "beam" ×`scale`·aS at a point, additive, turned by
/// `spin` (0.05 rad per tick); brightness `alpha` rises 0.2 per tick to 1, starts falling
/// 60 ticks before the end of its life, and the object vanishes below 0.
pub const Spin = struct {
    mesh: []const u8 = "beam",
    pos: [3]f32 = @splat(0),
    scale: f32 = 8,
    spin: Track = .{ .rate = 0.05, .wrap = 2 * std.math.pi },
    alpha: Track = .{ .rate = 0.2, .max = 1, .flip_at = 60, .kill_below = 0 },
    left: u32 = 200,
    delay: u32 = 0,
    done: bool = false,
    /// Ticks lived (a material's age).
    ticks: u32 = 0,
    /// A mod's material (core/effect.zig Material; "": none).
    material: []const u8 = "",

    pub fn tick(self: *Spin, _: void) bool {
        if (self.delay > 0) {
            self.delay -= 1;
            return true;
        }
        self.ticks += 1;
        self.spin.step();
        self.alpha.step();
        if (self.left > 0) self.left -= 1;
        self.spin.key(self.left);
        self.alpha.key(self.left);
        if (self.alpha.dead() or self.spin.dead() or self.left == 0) self.done = true;
        return !self.done;
    }
};

test "Track.after: a particle's value by its age is the owner's stepped value" {
    var s: Spin = .{};
    for (1..150) |n| {
        _ = s.tick({});
        try std.testing.expectEqual(s.alpha.v, (Spin{}).alpha.after(@intCast(n), 200));
    }
}

test "Spin: the tracks step as the exe's k += dw, phase mod 2π (0x4a7020)" {
    var s: Spin = .{};
    var phase: f32 = 0;
    var k: f32 = 0;
    var dw: f32 = 0.2;
    var left: u32 = 200;
    while (true) {
        phase = @mod(phase + 0.05, 2 * std.math.pi);
        k = @min(1, k + dw);
        left -= 1;
        if (left == 60) dw = -dw;
        const done = k < 0 or left == 0;
        try std.testing.expectEqual(!done, s.tick({}));
        try std.testing.expectEqual(phase, s.spin.v);
        try std.testing.expectEqual(k, s.alpha.v);
        if (done) break;
    }
}
