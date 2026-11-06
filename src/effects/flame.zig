//! Fire and gas: flamethrower streams (`Flame`) and Schizo's gas cloud (`Cloud`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Object = @import("../script.zig").object.Object;
const retain = @import("retain.zig");
const Rand = @import("../crt_rand.zig").Rand;
const Track = @import("beam.zig").Track;

/// Schizo's gas cloud (0x4a95d0 "gas2", kind 49): lasts while its cell has gas (cleared by
/// combat), frames loop (tick / 2); alpha rises over `fade_in` ticks.
pub const Cloud = struct {
    /// Classic's: "gas2" (core/classic.zig cloud_parts).
    effect: []const u8 = "",
    pos: [3]f32 = @splat(0),
    /// Half size (·aS): 1.3 · 600.
    size: f32 = 780,
    fade_in: u32 = 15,
    /// Ticks of the fade once the cell's gas ended.
    fade_out: u32 = 30,
    ticks: u32 = 0,
    /// Fading out (the cell's gas ended): alpha drops over `fade_out` ticks.
    fading: u32 = 0,
    /// A mod's material (core/effect.zig Material; "": none).
    material: []const u8 = "",

    pub fn tick(cl: *Cloud, _: void) bool {
        cl.ticks += 1;
        if (cl.fading == 0) return true;
        cl.fading -= 1;
        return cl.fading != 0;
    }
};

const FlameParticle = struct {
    pos: [3]f32,
    vel: [3]f32,
    age: u32,

    /// Straight flight; a mod's `gravity` pulls it down, `drag` slows it (both 0 in the exe's).
    pub fn tick(p: *FlameParticle, fl: *const Flame) bool {
        for (0..3) |k| p.pos[k] += p.vel[k];
        if (fl.gravity != 0) p.vel[2] -= fl.gravity;
        if (fl.drag != 0) for (&p.vel) |*v| {
            v.* *= 1 - fl.drag;
        };
        p.age += 1;
        return p.age < fl.life;
    }
};

/// A particle's look over its age (a mod's; null: the fire look, attack_flame_*): frames
/// of `sprite` (`frames` of them, random), half size, colour and alpha as tracks stepped
/// from its birth (`Track.after`).
pub const Look = struct {
    sprite: []const u8 = "flame2",
    frames: u32 = 15,
    size: Track = .{ .v = 8, .rate = 1.6, .max = 160 },
    rgb: [3]Track = @splat(.{ .v = 1 }),
    alpha: Track = .{ .v = 1 },
    add: bool = true,
};

/// What a stream's tick needs: its particles' memory, the game's shared rand() (`spread`).
pub const Ctx = struct { gpa: Allocator, rand: *Rand };

/// The exe's flame particle look (attack_flame_*): growth, size limit, colours old/new.
pub const Tune = struct { scale: f32, add: f32, range: f32, old: [3]f32, new: [3]f32 };

pub const Flame = struct {
    /// Particle spawn point and velocity (world units per tick); with `actor` the world
    /// recomputes them every tick (`spawn.aimFlames`).
    src: [3]f32,
    dir: [3]f32,
    /// Stream behind a weapon (0x49fdc0): `base` is a fixed point at the fighter (position +
    /// start_level·aS up). Without `link2` the direction is normal(link point − base) rotated
    /// by `rot` around the vertical; particles spawn at base + dir·`ahead`. With `link2`
    /// (Sting: t1 → t2) base is the `link` point and the direction goes to `link2`.
    actor: ?*Object = null,
    link: []const u8 = "",
    link2: []const u8 = "",
    base: [3]f32 = .{ 0, 0, 0 },
    rot: f32 = 0,
    ahead: f32 = 0,
    speed: f32 = 0,
    timer: i32,
    spawned: u32 = 0,
    max: u32,
    life: u32 = 16,
    /// The stream ends its fighter's attack (+0x3198 − 1 when the object dies, 0x49fd70 →
    /// 0x425610): set for the flamethrower, whose queue (0x48cdd6) has no attack-end
    /// command 6. Stinger's stream ends the same way, but its command 6 comes earlier
    /// (0x48b750, after stinger_s_delay2) and ends the attack first.
    ends_attack: bool = false,
    /// Ticks before it starts.
    delay: u32 = 0,
    /// A mod's (0 in the exe's): each particle's direction scattered by up to this much
    /// of its speed per axis (3 draws of the shared rand()), its fall per tick (world
    /// units), the share of its speed it loses per tick.
    spread: f32 = 0,
    gravity: f32 = 0,
    drag: f32 = 0,
    look: ?Look = null,
    /// Its weapon's own flame values (the weapon block's `flame = Flame(…)`); null: the game's.
    tune: ?Tune = null,
    /// A mod's material (core/effect.zig Material; "": none).
    material: []const u8 = "",
    parts: std.ArrayList(FlameParticle) = .empty,

    /// 0x49faa0: one particle per tick until `max`; object timer.
    pub fn tick(fl: *Flame, c: Ctx) bool {
        const a = c.gpa;
        if (fl.delay > 0) {
            fl.delay -= 1;
            return true;
        }
        fl.timer -= 1;
        if (fl.timer > 0 and fl.spawned < fl.max) {
            var vel = fl.dir;
            if (fl.spread != 0) {
                const sp = @import("../vec.zig").len(fl.dir) * fl.spread;
                for (&vel) |*v| v.* += (@as(f32, @floatFromInt(c.rand.below(2001))) / 1000 - 1) * sp;
            }
            fl.parts.append(a, .{ .pos = fl.src, .vel = vel, .age = 0 }) catch {};
            fl.spawned += 1;
        }
        retain.retain(&fl.parts, @as(*const Flame, fl));
        if (fl.timer > 0 or fl.parts.items.len > 0) return true;
        fl.parts.deinit(a);
        return false;
    }

    /// Orders stay locked (0x454fb0 → 0x422590) until the object dies: its timer drops
    /// below 0 (0x4a01fa), particles still in the air don't count.
    pub fn holdsAttack(fl: Flame) bool {
        return fl.ends_attack and fl.timer >= 0;
    }
};

test "flamethrower stream holds its attacker's attack until the timer drops below 0 (0x4a01fa)" {
    var fl: Flame = .{ .src = .{ 0, 0, 0 }, .dir = .{ 0, 0, 0 }, .timer = 90, .max = 90, .ends_attack = true };
    defer fl.parts.deinit(std.testing.allocator);
    var r: Rand = .{};
    const c: Ctx = .{ .gpa = std.testing.allocator, .rand = &r };
    for (0..90) |_| _ = fl.tick(c);
    try std.testing.expect(fl.holdsAttack());
    _ = fl.tick(c);
    try std.testing.expect(!fl.holdsAttack());
    // Particles still fly, but the attack is over.
    try std.testing.expect(fl.parts.items.len > 0);
    // Other streams (Stinger, Pain God) leave the attack end to the queue.
    fl.ends_attack = false;
    fl.timer = 10;
    try std.testing.expect(!fl.holdsAttack());
}

test "a mod's stream: spread draws the shared rand() 3 times a particle, gravity and drag bend it" {
    const a = std.testing.allocator;
    var fl: Flame = .{ .src = .{ 0, 0, 0 }, .dir = .{ 10, 0, 0 }, .timer = 3, .max = 3 };
    defer fl.parts.deinit(a);
    var r: Rand = .{};
    var plain = r;
    _ = fl.tick(.{ .gpa = a, .rand = &r });
    // Without spread the exe's stream draws nothing.
    try std.testing.expectEqual(plain, r);
    fl.spread = 0.5;
    fl.gravity = 2;
    fl.drag = 0.5;
    _ = fl.tick(.{ .gpa = a, .rand = &r });
    for (0..3) |_| _ = plain.next();
    try std.testing.expectEqual(plain, r);
    const v = fl.parts.items[1].vel;
    try std.testing.expect(v[0] != 10 or v[1] != 0 or v[2] != 0);
    _ = fl.tick(.{ .gpa = a, .rand = &r });
    // The first particle: moved by (10, 0, 0) twice, then by its speed pulled down 2 and halved.
    try std.testing.expectEqual([3]f32{ 25, 0, -1 }, fl.parts.items[0].pos);
    try std.testing.expectEqual([3]f32{ 2.5, 0, -1.5 }, fl.parts.items[0].vel);
}
