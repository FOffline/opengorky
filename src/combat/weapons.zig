//! Fighter weapons: available list, ammo, default weapon, skill.

const std = @import("std");
const weapon_class = @import("../battle.zig").weapon_class;
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const inventory = @import("../inventory.zig");
const rules = @import("../battle.zig").rules;
const Fighter = @import("../battle.zig").fighter.Fighter;
const Battle = @import("../battle.zig").battle.Battle;
const Value = @import("../script.zig").value.Value;
const events = @import("events.zig");

/// Fighter weapons: `.wpn`/Weapon_New objects with `Owner` = name; every hero
/// also has the fist (`place` 200, no owner).
pub fn weaponsOf(w: *World, f: Fighter, out: []*Object) []*Object {
    var n: usize = 0;
    for (w.rt.objects.items) |o| {
        if (World.nativeOf(o).kind != .weapon or World.nativeOf(o).deleted) continue;
        if (weapon_class.pattern(o) == null) continue;
        // Cheap owner check first, then ammo (scans every item).
        const owner = fields.owner(o);
        const mine = std.ascii.eqlIgnoreCase(owner, f.obj.name) or
            (f.side == .hero and owner.len == 0 and inventory.item.placeOf(o) == .party);
        if (!mine or n == out.len) continue;
        if (!hasAmmo(w, f, o)) continue;
        out[n] = o;
        n += 1;
    }
    return out[0..n];
}

/// Fighter weapons for the threat map (0x49af80, 0x49aff4…0x49b053): every enabled
/// weapon object (+0x6c) owned by exactly this fighter (+0x354, by name), wherever
/// it lies. The exe checks neither ammo nor recharge here, and the party's shared
/// fist (no owner, place 200) is not included.
pub fn threatWeaponsOf(w: *World, f: Fighter, out: []*Object) []*Object {
    var n: usize = 0;
    for (w.rt.objects.items) |o| {
        if (World.nativeOf(o).kind != .weapon or World.nativeOf(o).deleted) continue;
        if (weapon_class.pattern(o) == null) continue;
        if (!std.ascii.eqlIgnoreCase(fields.owner(o), f.obj.name) or n == out.len) continue;
        out[n] = o;
        n += 1;
    }
    return out[0..n];
}

/// Ammo (0x4ce250): `ammo` 0 = none needed, −1 = thrown (the weapon itself is
/// spent), else the sum of `counter` of the owner's items with `classic_id = ammo`.
pub fn ammoLeft(w: *World, f: Fighter, wpn: *Object) ?i32 {
    const id = wpn.getInt("ammo");
    if (id == 0 or id == -1) return null;
    return inventory.ammo.ammoCount(w, f.obj.name, id);
}

pub fn hasAmmo(w: *World, f: Fighter, wpn: *Object) bool {
    if (World.nativeOf(wpn).fight.recharge > 0) return false;
    return (ammoLeft(w, f, wpn) orelse 1) > 0;
}

/// Turns a strike recharges `wpn` for (0: none): its class's (0x4cf778) or, in an
/// OpenGorky project, the attack's own (rules MonsterAttack `recharge_turns`). One source for
/// the strike (consumeAmmo) and the panel's battery.
pub fn rechargeOf(who: *Object, wpn: *Object) i32 {
    if (@import("../battle.zig").generic.rowOf(who, wpn)) |r| if (r.recharge_turns > 0) return r.recharge_turns;
    return rules.rechargeTurns(wpn.getInt("class"));
}

/// Shot (0x4ce2c0): −1 round from the first pack; a thrown weapon disappears and
/// an identical one from the backpack takes its place.
pub fn consumeAmmo(b: *Battle, w: *World, f: *Fighter, wpn: *Object) !void {
    // Recharging weapons (0x4b7640 etc.) count turns instead of ammo. A strike
    // (0x4cf210, call +0xc8 at 0x4cf778) sets the full N; −1 only at the enemy turn
    // start (0x49844c), so a weapon fired on turn T is ready again on turn T+N and
    // the panel shows N, N−1 … 1.
    var rt = rechargeOf(f.obj, wpn);
    // OpenGorky: the weapon's RechargeTurns(user, turns).
    if (wpn.implementsC("RechargeTurns")) rt = try events.chain(b, w, wpn, "Weapon.RechargeTurns", .{ f.obj.ref(), Value{ .int = rt } });
    if (rt > 0) World.nativeOf(wpn).fight.recharge = rt;
    const id = wpn.getInt("ammo");
    if (id == 0) return;
    if (id == -1) {
        World.nativeOf(wpn).deleted = true;
        wpn.enabled = false;
        f.weapon = null;
        for (w.rt.objects.items) |o| {
            const nat = World.nativeOf(o);
            if (nat.kind != .weapon or nat.deleted or o == wpn) continue;
            if (fields.classicId(o) == fields.classicId(wpn) and fields.ownerIs(o, f.obj.name)) {
                f.weapon = o;
                if (f.side == .hero) inventory.equipment.equip(w, f.obj, o);
                return;
            }
        }
        f.weapon = defaultWeapon(w, f.*);
        return;
    }
    for (w.rt.objects.items) |o| {
        if (!world.isItem(o)) continue;
        if (fields.classicId(o) != id or !fields.ownerIs(o, f.obj.name)) continue;
        if (fields.counter(o) <= 0) continue;
        fields.setCounter(o, fields.counter(o) - 1);
        return;
    }
}

/// Default weapon: for a hero the one in hand or the fist; otherwise the one with the longest ray.
pub fn defaultWeapon(w: *World, f: Fighter) ?*Object {
    var list: [16]*Object = undefined;
    const ws = weaponsOf(w, f, &list);
    // Hero: the weapon in hand (place 11) if it has ammo; empty hand (or a non-weapon)
    // means the fist `gs_fist_all` (place 200). Nothing is put in the hand here: only
    // the inventory and the quick list change it.
    if (f.side == .hero) {
        if (inventory.equipment.equipped(w, f.obj, .hand)) |o| {
            if (std.mem.indexOfScalar(*Object, ws, o) != null) return o;
            // Recharging or out of ammo: stays in hand and the strike says "recharging" or
            // "No ammo" (0x47c2a2…0x47c3e5); the fist is not substituted.
            if (World.nativeOf(o).kind == .weapon and weapon_class.pattern(o) != null) return o;
        }
        for (ws) |o| if (inventory.item.placeOf(o) == .party and fields.owner(o).len == 0) return o;
    }
    var best: ?*Object = null;
    var best_len: usize = 0;
    for (ws) |o| {
        const pat = weapon_class.pattern(o).?;
        if (best == null or pat.rays.items.len > best_len) {
            best = o;
            best_len = pat.rays.items.len;
        }
    }
    return best;
}

/// Uses until the next skill level (0x528c8c, levels 0..10).
const skill_thresholds = [_]i32{ 0, 2, 4, 6, 9, 12, 15, 19, 23, 28, 1000000 };

/// A hero uses a weapon (0x48fea0): no entry means level 1, count 0; then count
/// +1, and reaching the level threshold gives level +1 (true).
pub fn growSkill(w: *World, hero: *Object, id: i32) !bool {
    const skills = &World.nativeOf(hero).growth.skills;
    const sk = for (skills.items) |*s| {
        if (s.id == id) break s;
    } else blk: {
        try skills.append(w.gpa, .{ .id = id, .level = 1 });
        break :blk &skills.items[skills.items.len - 1];
    };
    if (sk.level <= 0) return false;
    sk.count += 1;
    const lvl: usize = @intCast(@min(sk.level, skill_thresholds.len - 1));
    if (sk.count < skill_thresholds[lvl]) return false;
    sk.level += 1;
    return true;
}

/// Hero `hero`'s skill level with weapon classic_id `id` (no entry: 1).
pub fn skillLevel(hero: *Object, id: i32) i32 {
    for (World.nativeOf(hero).growth.skills.items) |s| if (s.id == id) return s.level;
    return 1;
}

/// Weapon skill in percent (0x48fe10): level × 10, 100 without a skill.
pub fn skillOf(f: Fighter, wpn: *Object) i32 {
    const id = fields.classicId(wpn);
    if (f.side != .hero) return rules.skillPercent(null, false);
    for (World.nativeOf(f.obj).growth.skills.items) |s| if (s.id == id) return rules.skillPercent(s.level, true);
    return rules.skillPercent(null, true);
}

test "rechargeOf: the class's turns, an OpenGorky attack row's over them" {
    const gpa = std.testing.allocator;
    const top = @import("../rules.zig");
    defer top.reset();
    var cls: @import("../script.zig").object.Class = .{ .name = "ft_x", .parent = null, .ident = "ft_x" };
    var who: Object = .{ .name = "x", .class = &cls };
    var wpn: Object = .{ .name = "gun", .class = &cls };
    defer who.vars.deinit(gpa);
    defer wpn.vars.deinit(gpa);
    try wpn.declare(gpa, "class", .{ .type = .int, .value = .{ .int = 124 } });
    try std.testing.expectEqual(0, rechargeOf(&who, &wpn));
    var set = top.builtin;
    set.monster_attacks = &.{.{ .fighter = 0, .fighter_class = "ft_x", .anim = "a", .hit_delay = .{}, .recharge_turns = 3 }};
    top.active = &set;
    // Classic ignores the row; an OpenGorky project takes it (the panel shows its battery).
    try std.testing.expectEqual(0, rechargeOf(&who, &wpn));
    top.og = true;
    try std.testing.expectEqual(3, rechargeOf(&who, &wpn));
}
