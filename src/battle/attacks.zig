//! Attack tables: heroes by weapon classic_id (branches 0x48bda2), monsters by
//! fighter classic_id (0x4896b0, table 0x48d618). The rows are the Rules' built-ins
//! (src/rules.zig: attacks.ss); waits named after adjust.kdt globals are read from it
//! (the exe's), the shipped values as the fallback.

const rules = @import("../rules.zig");
const entity = @import("../core.zig").entity;
const Object = @import("../script.zig").object.Object;
const Class = @import("fighter.zig").Class;

/// Hero-table strike (0x48bda2): every classic_id without MonsterAttack rows. The exe
/// (0x4896b0): classic_id − 0x64 ≤ 0x27 takes its own branch from table 0x48d618, even
/// for a party hero, Medusa; 103, 104, 111, 112, 134 lead to 0x48bda2 there.
/// The fighter's record says (Enemy.own_attacks: by classic_id, whatever the side).
fn heroTable(who: rules.Who) bool {
    return !entity.enemyOf(who).own_attacks;
}

/// A resolved hero strike (`HeroAttack` rows). `extra` only for the WdelayHero
/// fighters; `then` after `until_end`.
pub const HeroAttack = struct { anim: []const u8, wait: u32, extra: i32 = 0, until_end: bool = false, then: ?[]const u8 = null, after: u32 = 0, pre: ?u32 = null };

pub fn heroAttack(attacker: rules.Who, weapon: rules.Who) HeroAttack {
    const r = rules.heroAttack(weapon, attacker);
    return .{
        .anim = r.anim,
        .wait = r.wait.ticks(),
        .extra = if (entity.heroOf(attacker).wdelay) r.extra.int() else 0,
        .until_end = r.until_end,
        .then = if (r.then.len > 0) r.then else null,
        .after = r.after.ticks(),
        .pre = if (r.pre) |p| p.ticks() else null,
    };
}

pub const Lift = struct { link: []const u8 = "hand", z: f32 = -400, bind_at: u32, release_after: u32 };

/// A resolved monster strike (`MonsterAttack` rows): logical animation, ticks until
/// the hit, wait after it, victim lift.
/// The exe branches pick the strike by weapon classic_id (+0x58), not by longAttack:
/// Fatman, Stinger, Puppet and Messiah don't set it in data.
/// A branch queues the fighter's animation (0x428980), waits (0x428c00) and hit
/// callbacks (0x428b90 → 0x4863c0), ending with 0x425630 (attack over).
/// `wait`: ticks until the damage callback (code 5: weapon +0xf0 with flag 1);
/// `after`: waits after the last callback until 0x425630 (often sf_delay 30 or
/// a constant 30).
/// `react`: that many ticks later the target's reaction repeats without damage
/// (code 7: +0xf0 with flag 0 → 0x490e80 without 0x490f10: hit and blood, 0x491920 and 0x491510).
/// `pre`: flash tick before the hit (0x427ce0 on the "chaingun" point before the callback).
/// `gas`: gas on the aimed tile and around it (Schizo); `linked`: the second linked
/// actor's animation (Smoke Rider).
pub const MonsterAttack = struct { anim: []const u8, wait: u32, after: u32 = 0, lift: ?Lift = null, second: u32 = 0, react: u32 = 0, pre: ?u32 = null, vanish: u32 = 0, gas: bool = false, linked: []const u8 = "" };

/// Only for classic_ids where `heroTable` is false.
fn monsterAttack(id: rules.Who, wpn: rules.Who) MonsterAttack {
    return resolve(rules.monsterAttack(id, wpn).?.*);
}

fn resolve(r: rules.MonsterAttack) MonsterAttack {
    return .{
        .anim = r.anim,
        .wait = r.hit_delay.ticks(),
        .after = r.after_delay.ticks(),
        .second = r.second_delay.ticks(),
        .react = r.react_delay,
        .pre = if (r.flash_delay) |p| p.ticks() else null,
        .vanish = r.vanish_delay,
        .lift = if (r.lift_delay > 0) .{ .bind_at = r.lift_delay, .release_after = r.drop_delay } else null,
        .gas = r.gas,
        .linked = r.linked_anim,
    };
}

/// A strike: the hero table or a monster branch.
pub const Strike = union(enum) { hero: HeroAttack, monster: MonsterAttack };

/// `who`'s strike with `wpn`. classic_id picks the table (0x4896b0), not the side: Medusa
/// (119) uses her branch even in the party. The generic fighter (classType 100) and,
/// in an OpenGorky project, any weapon take the weapon class fields over the row
/// (`overlay`); the exe has no such fields.
pub fn strikeOf(who: *Object, wpn: *Object) Strike {
    if (Class.of(who) == .generic) return .{ .monster = genericAttack(wpn) };
    const id = rules.who(who);
    // A fighter whose rows don't cover this weapon (an OpenGorky row for one weapon
    // only, no weapon = 0 row) strikes with it by the hero table.
    const row = if (heroTable(id)) null else rules.monsterAttack(id, rules.who(wpn));
    if (row == null) {
        const h = heroAttack(id, rules.who(wpn));
        return .{ .hero = if (rules.og) overlayHero(h, wpn) else h };
    }
    const m = resolve(row.?.*);
    return .{ .monster = if (rules.og) overlay(m, wpn) else m };
}

pub fn animOf(s: Strike) []const u8 {
    return switch (s) {
        inline else => |x| x.anim,
    };
}

/// Generic fighter's strike: the weapon fields over long_attack / short_attack (by
/// `longAttack`), `attackEffectDelay` (else 15) and 30 after (the common tail 0x48b864).
pub fn genericAttack(wpn: *Object) MonsterAttack {
    const eff = wpn.getInt("attackEffectDelay");
    return overlay(.{
        .anim = if (wpn.getInt("long_attack") != 0) "long_attack" else "short_attack",
        .wait = if (eff > 0) @intCast(eff) else 15,
        .after = 30,
    }, wpn);
}

/// Weapon class fields over a strike (the generic fighter's; in an OpenGorky project
/// any weapon's, over its MonsterAttack row; rules attacks.ss):
/// - `attack_anim`: logical animation;
/// - `hit_delay`: ticks until the hit;
/// - `after_delay`: wait after the hit until the attack ends (also 0);
/// - `second_delay`: second projectile that many ticks later;
/// - `react_delay`: repeat the target's reaction without damage after that many ticks;
/// - `flash_delay`: muzzle flash before the hit at that tick.
/// Numbers 0 or less (but `after_delay`) keep the row's.
pub fn overlay(base: MonsterAttack, wpn: *Object) MonsterAttack {
    var m = base;
    const anim = wpn.getString("attack_anim");
    if (anim.len > 0) m.anim = anim;
    if (positive(wpn.getInt("hit_delay"))) |v| m.wait = v;
    if (wpn.getVar("after_delay")) |v| m.after = @intCast(@max(0, v.value.toInt()));
    if (positive(wpn.getInt("second_delay"))) |v| m.second = v;
    if (positive(wpn.getInt("react_delay"))) |v| m.react = v;
    if (positive(wpn.getInt("flash_delay"))) |v| m.pre = v;
    return m;
}

/// The same fields over a hero strike (HeroAttack row); `hit_delay` drops the wdelay shift.
fn overlayHero(base: HeroAttack, wpn: *Object) HeroAttack {
    var h = base;
    const anim = wpn.getString("attack_anim");
    if (anim.len > 0) h.anim = anim;
    if (positive(wpn.getInt("hit_delay"))) |v| {
        h.wait = v;
        h.extra = 0;
    }
    if (wpn.getVar("after_delay")) |v| h.after = @intCast(@max(0, v.value.toInt()));
    if (positive(wpn.getInt("flash_delay"))) |v| h.pre = v;
    return h;
}

fn positive(v: i32) ?u32 {
    return if (v > 0) @intCast(v) else null;
}

test "table 0x48d618: hero branches, Guard and Jet Elmer" {
    const t = @import("std").testing;
    for ([_]i32{ 103, 104, 111, 112, 134, 99, 140 }) |id| try t.expect(heroTable(.{ .id = id }));
    // Every classic_id 100…139 outside the hero branches has its own entry (no unreachable).
    for (100..140) |i| if (!heroTable(.{ .id = @intCast(i) })) {
        _ = monsterAttack(.{ .id = @intCast(i) }, .{ .id = 0 });
    };
    // Jet Elmer 56: two hits (36, then 12 later), tail 30 (0x48a152).
    const je = monsterAttack(.{ .id = 100 }, .{ .id = 56 });
    try t.expectEqual(@as(u32, 36), je.wait);
    try t.expectEqual(@as(u32, 12), je.second);
    try t.expectEqual(@as(u32, 30), je.after);
    // Guard: short strike and attack_3 have tail 30 (0x48b864); beam damage at 43 + 5.
    try t.expectEqual(@as(u32, 30), monsterAttack(.{ .id = 131 }, .{ .id = 1062 }).after);
    try t.expectEqual(@as(u32, 30), monsterAttack(.{ .id = 131 }, .{ .id = 1 }).after);
    try t.expectEqual(@as(u32, 48), monsterAttack(.{ .id = 131 }, .{ .id = 1063 }).wait);
    // Lasers (code 0x23) at tick 43, smoke and damage (code 0x24) 5 later.
    try t.expectEqual(@as(?u32, 43), monsterAttack(.{ .id = 131 }, .{ .id = 1063 }).pre);
}
