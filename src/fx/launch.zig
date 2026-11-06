//! Weapon projectiles: launch points and per-weapon flight parameters.

const std = @import("std");
const fields = @import("../fields.zig");
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;
const effects = @import("../effects.zig");
const generic = @import("../battle.zig").generic;
const place = @import("place.zig");
const modules = @import("../core.zig").modules;
const desc = @import("../core.zig").effect;
const rules = @import("../rules.zig");
const adjust = rules.adjust;

/// Weapon projectile (0x49b0a0, 0x49c840, choreography 0x48bda2): rocket,
/// grenades, bottles, knife, flare, napalm. 0 means the weapon has no projectile.
/// Battle speedScale = 0.02·xSize = 7·actorScale (0x4b49f0).
pub fn launch(w: *World, who: *Object, wpn: *Object, target_floor: [3]f32) u32 {
    return launchWith(w, who, generic.fxOf(who, wpn).launch, target_floor, false, rules.who(wpn));
}

/// Jet Elmer's second rocket (callback 2, 0x486599): from attack_jetelmer_rocket2_*.
pub fn launchSecond(w: *World, who: *Object, wpn: *Object, target_floor: [3]f32) u32 {
    return launchWith(w, who, generic.fxOf(who, wpn).launch, target_floor, true, rules.who(wpn));
}

pub fn launchId(w: *World, who: *Object, weapon_id: i32, target_floor: [3]f32, second: bool) u32 {
    return launchWith(w, who, weapon_id, target_floor, second, null);
}

/// `launchId` with weapon `wpn`'s own effect values (null: the game's).
fn launchWith(w: *World, who: *Object, weapon_id: i32, target_floor: [3]f32, second: bool, wpn: ?rules.Who) u32 {
    const d = &((modules.weaponFx(weapon_id, fields.classicId(who)) orelse return 0).launch orelse return 0);
    const as = w.actorScale();
    const start = place.offsetPoint(who, as, .{ 100, 0, 400 });
    const target = [3]f32{ target_floor[0], target_floor[1], target_floor[2] + 300 * as };
    return w.effects.launch(w.gpa, build(w, who, d, .{ .pos = start, .start = start, .target = target, .speed_scale = 7 * as, .floor = target_floor[2] }, second, wpn));
}

/// Projectile `d` over `base`'s place, target and speed scale: the description's launch
/// point, template, adjust.kdt values, then where it starts, its hold, growth and look.
fn build(w: *World, who: *Object, d: *const desc.Launch, base: effects.projectile.Projectile, second: bool, wpn: ?rules.Who) effects.projectile.Projectile {
    const as = w.actorScale();
    var pr = d.pr;
    inline for (.{ "pos", "start", "target", "speed_scale", "floor" }) |f| @field(pr, f) = @field(base, f);
    if (if (second) d.start2 orelse d.start else d.start) |o| pr.start = place.offsetPoint(who, as, .{ o[0].get(), o[1].get(), o[2].get() });
    if (d.rocket_trail) rocketTrail(&pr, wpn);
    if (wpn) |x| {
        pr.angle = rules.weaponFloat("attack_grenade_angle", x);
        pr.ball_ms = rules.weaponFloat("attack_ball_ms", x);
    }
    for (d.set) |st| set(&pr, st);
    if (pr.max_speed == 0) pr.max_speed = pr.speed;
    if (d.trail_rgb) |c| pr.trail_rgb = c.get();
    pr.light_range *= as;
    if (d.start_at) |at| pr.start = place.at(w, who, at, pr.target);
    if (d.hold) |links| {
        pr.owner = who;
        pr.hold_links = links;
    }
    if (d.grow) |g| {
        pr.k = d.grow_from / pr.mesh_scale;
        pr.grow = g.get() / pr.mesh_scale;
    }
    if (d.look == .ball) pr.ball = .{};
    pr.trail_as = as;
    return pr;
}

fn set(pr: *effects.projectile.Projectile, st: desc.Set) void {
    switch (st.f) {
        inline else => |f| {
            const T = @FieldType(effects.projectile.Projectile, @tagName(f));
            if (T == f32) @field(pr, @tagName(f)) = st.v.get();
            if (T == u32) @field(pr, @tagName(f)) = @intCast(@max(0, adjust.getInt(st.v.adj, @intFromFloat(st.v.d))));
        },
    }
}

/// Rocket of the ROCKET scene command (0x476e9f): from pos + aS·attack_rocketl_*
/// (0, 300 forward, 270 up) by the actor's angle to world point `target`
/// (0x49d8d0), scale attack_rocketl_scale 2 (+0x358, 0x47708e). Outside battle
/// speedScale is a level variable, or 1 if it isn't above 0 (0x421911…0x421930).
/// `weapon`: whose launch it is (the command's 5th argument, an OpenGorky scene's
/// `~w"weapons::rocket_launcher"`; null: the exe's, the rocket launcher 1024); none: no rocket.
pub fn sceneRocket(w: *World, who: *Object, target: [3]f32, weapon: ?i32) u32 {
    const as = w.actorScale();
    const fx = modules.weaponFx(weapon orelse 1024, 0) orelse return 0;
    const d = &(fx.launch orelse return 0);
    const start = place.offsetPoint(who, as, .{ 100, 0, 400 });
    const level_scale: f32 = if (w.level) |l| fields.getF(l, "speed_scale") else 0;
    const ss: f32 = if (w.isCombat()) 7 * as else if (level_scale > 0) level_scale else 1;
    return w.effects.launch(w.gpa, build(w, who, d, .{ .pos = start, .start = start, .target = target, .speed_scale = ss }, false, null));
}

/// Trail look rocket1_trail_* (0x49d987): length, size, growth, brightness, jitter,
/// period, point behind.
/// `wpn`: whose rocket (its own values over the game's).
fn rocketTrail(x: *effects.projectile.Projectile, wpn: ?rules.Who) void {
    x.trail_len = @intCast(std.math.clamp(rules.weaponInt("rocket1_trail_len", wpn), 0, 255));
    x.trail_size = rules.weaponFloat("rocket1_trail_size", wpn);
    x.trail_size_fade = rules.weaponFloat("rocket1_trail_size_fade", wpn);
    x.trail_fade = rules.weaponFloat("rocket1_trail_fade_factor", wpn);
    x.trail_disp = rules.weaponFloat("rocket1_trail_disp_factor", wpn);
    x.trail_period = @intCast(@max(1, rules.weaponInt("rocket1_trail_update_speed", wpn)));
    x.trail_back = rules.weaponFloat("rocket1_trail_disp", wpn);
}
