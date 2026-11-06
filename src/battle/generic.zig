//! Generic fighter (`classType = 100` in `.ftr`; no such class in the exe) for
//! custom fighters. Everything the exe hard-codes by classic_id and
//! class (attack branches 0x4896b0, move scoring +0xe0, resistance table
//! 0x6d2070) comes from the fighter's and weapon's script fields here. Game
//! fighters don't use this code and behave as in the exe.

const std = @import("std");
const Object = @import("../script.zig").object.Object;
const Class = @import("fighter.zig").Class;
const immunity = @import("immunity.zig");
const rules = @import("../rules.zig");
const entity = @import("../core.zig").entity;

pub fn is(o: *Object) bool {
    return Class.of(o) == .generic;
}

/// Whose effects the weapon uses (projectile, flash, hit trail; src/fx.zig picks
/// them by weapon classic_id): `fx_as` is a game weapon's classic_id, `projectile` a
/// projectile name; otherwise its own classic_id (game weapons lack these fields) through
/// the rules' FxAs (fx.ss; Classic: an OpenGorky project has none, its `effects_from` instead).
pub fn fxId(wpn: *Object) i32 {
    const as = wpn.getInt("effects_from");
    // −1 (none; FxAs `as = -1` converted): OpenGorky's only, Classic as before.
    if (as > 0 or (as < 0 and rules.og)) return as;
    // A projectile by name (Classic's generic weapons: the game weapons' numbers; an
    // OpenGorky project names the weapon, `effects_from = ~w"weapons::rocket_launcher"`).
    const p = if (rules.og) "" else wpn.getString("projectile");
    if (p.len > 0) if (projectileId(p)) |id| return id;
    return entity.weaponOf(rules.who(wpn)).fx_as;
}

/// A strike's effects, each stage by the game weapon classic_id whose effects it is (the
/// exe's code by classic_id, fx/hits.zig, fx/launch.zig): the muzzle flash or beam before the
/// hit, the projectile, the hit; `special`: the fighter classic_id whose own effects come
/// with it (Medusa's beam, the Guard's lasers, Headnail's saws; 0: none); `sound`: the
/// hit's (null: WeaponSound of `hit`).
pub const Fx = struct {
    flash: i32,
    launch: i32,
    hit: i32,
    special: i32,
    sound: ?[]const u8 = null,
    /// The striking weapon (null: by id only): its own effect values (rules.weaponFloat).
    weapon: ?*Object = null,

    pub fn same(id: i32, special: i32) Fx {
        return .{ .flash = id, .launch = id, .hit = id, .special = special };
    }

    /// Rule stages over these: 0 keeps one, -1 none; a non-empty `sound` replaces.
    fn over(self: *Fx, flash: i32, launch: i32, hit: i32, sound: []const u8) void {
        inline for (.{ "flash", "launch", "hit" }, .{ flash, launch, hit }) |n, v| {
            if (v != 0) @field(self, n) = @max(0, v);
        }
        if (sound.len > 0) self.sound = sound;
    }
};

/// `who`'s strike effects with `wpn`: the weapon's (fxId), its classic_id's specials. In an
/// OpenGorky project over them the weapon's stage fields (`flash_from`, `launch_from`,
/// `hit_from`, `hit_sound`; in Classic only FxAs `as` counts, fxId) and
/// class WeaponSound, then the fighter's MonsterAttack row (fx: all stages, flash, launch,
/// hit, sound, special).
pub fn fxOf(who: *Object, wpn: *Object) Fx {
    var f = Fx.same(fxId(wpn), who.getInt("classic_id"));
    f.weapon = wpn;
    if (!rules.og) return f;
    f.over(wpn.getInt("flash_from"), wpn.getInt("launch_from"), wpn.getInt("hit_from"), wpn.getString("hit_sound"));
    if (f.sound == null) f.sound = entity.weaponOf(rules.who(wpn)).class_sound;
    const m = rowOf(who, wpn) orelse return f;
    const from = entity.refId(m.effects_from, m.effects_from_class);
    if (from != 0) f.over(from, from, from, "");
    f.over(entity.refId(m.flash_from, m.flash_from_class), entity.refId(m.launch_from, m.launch_from_class), entity.refId(m.hit_from, m.hit_from_class), m.sound);
    const strike = entity.refId(m.strike, m.strike_class);
    if (strike != 0) f.special = @max(0, strike);
    return f;
}

/// The fighter's MonsterAttack row for `wpn` in an OpenGorky project (its OpenGorky
/// fields: recharge, range…); null in Classic, for the generic fighter or without one.
pub fn rowOf(who: *Object, wpn: *Object) ?*const rules.MonsterAttack {
    if (!rules.og or is(who)) return null;
    return rules.monsterAttack(rules.who(who), rules.who(wpn));
}

/// Projectile name → classic_id of the game weapon with that projectile.
fn projectileId(name: []const u8) ?i32 {
    const names = [_]struct { []const u8, i32 }{
        .{ "rocket", 1024 }, .{ "grenade", 35 }, .{ "stun_grenade", 33 }, .{ "gas_grenade", 1027 },
        .{ "molotov", 86 },  .{ "knife", 40 },   .{ "stone", 41 },        .{ "napalm", 1028 },
        .{ "bullet", 89 },   .{ "ball", 1072 },  .{ "small_ball", 1070 },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n[0])) return n[1];
    return null;
}

/// Register the fighter's resistances and armour by its classic_id on battle entry: the
/// Classic generic fighter's by its fields `resist`, `armor_class` (the exe's); in an
/// OpenGorky project its Resist row by its class (its `immunity`), the one place they are.
pub fn registerFighter(k: *immunity.Known, o: *Object) void {
    if (!rules.og) {
        if (is(o)) k.register(rules.who(o), o.getString("resist"), o.getInt("armor_class"), false);
        return;
    }
    const w = rules.who(o);
    const by_class = if (entity.enemyOf(w).resist) |e| e.fighter_class.len > 0 else false;
    if (!by_class and !is(o)) return;
    k.register(w, null, null, true);
}

/// The AI profile (rules ai.ss) of fighter `o`, an enemy or not: its classType's (the
/// generic fighter's by its `ai` field: the class row of that `generic_ai`, Classic's the
/// Stinger's and the Guard's), a row by the fighter over it. A non-enemy has class 0's alone: a row by
/// the fighter (an OpenGorky archetype's, the converter's of a class row) is an enemy's
/// only, as its class's row (the game has none, Classic as the exe).
pub fn aiProfile(o: *Object, enemy: bool) rules.AiProfile {
    const cls = Class.of(o);
    const ai = aiOf(o);
    const base: i32 = if (!enemy) 0 else if (cls == .generic) switch (ai) {
        .standard, .stationary => 0,
        .focused, .sleep_hunter => rules.genericAiClass(@tagName(ai)),
    } else @backingInt(cls);
    return rules.aiProfile(if (enemy) rules.who(o) else null, base);
}

/// AI strategy from the `ai` field:
/// - `standard`: an ordinary exe monster (default scoring: damage to the enemy,
///   tile threat, distance; attracted by decoys);
/// - `focused`: "scoring A" of special fighters (0x4dcb40): damage only, no decoys;
/// - `sleep_hunter`: like the Guard (0x4e2260): melee (`secondaryWeapon`) only on
///   sleepers, the other weapon on those awake;
/// - `stationary`: an ordinary one that never walks (the ability `immobile`,
///   core/classic.zig fromFields), strikes from its tile.
const Ai = enum { standard, focused, sleep_hunter, stationary };

pub fn aiOf(o: *Object) Ai {
    const v = o.getString("ai");
    var buf: [32]u8 = undefined;
    if (v.len > buf.len) return .standard;
    return std.meta.stringToEnum(Ai, std.ascii.lowerString(&buf, v)) orelse .standard;
}

test "fxOf: an OpenGorky weapon's stage fields over its effects_from; Classic: none" {
    const gpa = std.testing.allocator;
    var cls: @import("../script.zig").object.Class = .{ .name = "", .parent = null, .ident = "weapons::x" };
    var w: Object = .{ .name = "", .class = &cls };
    defer w.vars.deinit(gpa);
    var h: Object = .{ .name = "", .class = &cls };
    defer h.vars.deinit(gpa);
    try w.declare(gpa, "classic_id", .{ .type = .int, .value = .{ .int = 2001 } });
    try w.declare(gpa, "effects_from", .{ .type = .int, .value = .{ .int = 98 } });
    try w.declare(gpa, "launch_from", .{ .type = .int, .value = .{ .int = 1024 } });
    try w.declare(gpa, "flash_from", .{ .type = .int, .value = .{ .int = -1 } });
    try w.declare(gpa, "hit_sound", .{ .type = .string, .value = .{ .string = "s_expl1" } });
    const classic = fxOf(&h, &w);
    try std.testing.expect(classic.flash == 98 and classic.launch == 98 and classic.hit == 98 and classic.sound == null);
    rules.og = true;
    defer rules.og = false;
    const f = fxOf(&h, &w);
    try std.testing.expect(f.flash == 0 and f.launch == 1024 and f.hit == 98);
    try std.testing.expectEqualStrings("s_expl1", f.sound.?);
}
