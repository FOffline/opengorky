//! Built-in rules: weapon_classes.ss (battle/rules.zig), and the weapon classes' names
//! (`Class`).

const std = @import("std");
const rows = @import("rows.zig");

/// The exe's weapon classes (`classType`; factory 0x4b4c00: tables 0x4b5d24 for 1…25,
/// 0x4b5d84 for 101…, 0x4b5dec for 1001…). The tags are the classes' names: OpenGorky keys
/// the WeaponClass and Pattern rows by them, a weapon writes `class = pistol`. The one table of the names.
pub const Class = enum(i32) {
    // Hero weapons (0x4b5d24).
    pistol = 1,
    rifle = 2,
    dartgun = 3,
    flame_thrower = 4,
    rocket_launcher = 5,
    ion_rifle = 6,
    /// Blaster; Grandma's and the NATO captain's weapons share this subclass.
    blaster = 7,
    /// Satellite: beam, lightning, rocket (1038–1040); any tile of the field.
    satellite = 8,
    time_bomb = 9,
    /// Melee: axe, bat, bayonet, crowbar, hammer, knuckles, stiletto.
    melee = 10,
    /// Grenade, explosives.
    grenade = 11,
    throwing_knife = 12,
    chaingun = 13,
    shotgun = 14,
    molotov = 15,
    napalm_launcher = 16,
    /// Barrel blast (wp_barrel_explode).
    barrel_blast = 17,
    /// Decoy (attracting device, distractor).
    decoy = 18,
    nitrogen_thrower = 19,
    /// Petrol and vodka.
    bottle = 20,
    matches = 21,
    stun_bomb = 22,
    gas_grenade = 23,
    shocker = 24,
    // Monster weapons (0x4b5d84).
    garcia_short = 101,
    garcia_long = 102,
    hound = 103,
    invisible = 104,
    jetelmer_short = 105,
    jetelmer_long = 106,
    needle = 107,
    rc28 = 108,
    sphinx = 109,
    siner = 110,
    squeaker = 111,
    cutter = 112,
    fang = 113,
    harvester = 114,
    headnail = 115,
    hornet = 116,
    lilith = 117,
    lucy_short = 118,
    lucy_long = 119,
    paingod = 120,
    reverend_insect = 121,
    sister_of_mercy = 122,
    medusa_short = 123,
    medusa_long = 124,
    /// Invisible's bite in 04__city_mfd (04mf_invisible1_a): incurable poison.
    invisible_bite = 125,
    /// Allies' pistol (Kozov, Lamar).
    ally_pistol = 126,
    /// NATO and special forces rifle.
    ally_rifle = 127,
    // Special fighters' weapons (0x4b5dec).
    smoke_rider = 1001,
    grandma_mad = 1002,
    grandma_child = 1003,
    stinger_short = 1004,
    stinger_long = 1005,
    fatman_short = 1006,
    fatman_long = 1007,
    incubus = 1008,
    cripple = 1009,
    puppet = 1010,
    guard_short_right = 1011,
    guard_short_left = 1012,
    guard_long = 1013,
    judge = 1014,
    judge_child = 1015,
    schizo_first = 1016,
    schizo_second = 1017,
    schizo_third = 1018,
    messiah_left = 1019,
    messiah_right = 1020,
    _,

    pub fn from(class: i32) Class {
        return @fromBackingInt(@intCast(class));
    }
};

/// The name of exe classType `n` ("" none): its `Class` tag.
pub fn nameOf(n: i32) []const u8 {
    return std.enums.tagName(Class, @fromBackingInt(@intCast(n))) orelse "";
}

/// Every named class: number and name.
pub const names = blk: {
    const f = @typeInfo(Class).@"enum".field_names;
    const v = @typeInfo(Class).@"enum".field_values;
    var out: [f.len]struct { i32, []const u8 } = undefined;
    for (&out, f, v) |*o, n, x| o.* = .{ x, n };
    break :blk out;
};

/// Weapon classes from the subclass methods (factory 0x4b4c00):
/// - +0xc4 roll to hit: firearms (1, 2, 3, 12, 14, 126, 127);
/// - +0xf0 → 0x4900f0 state: the flamethrower (0x4b76a0) always ignites, damage only if
///   the fire took; molotov (+0xdc 0x4bb6e0) and napalm launcher (0x4b8120) ignite any
///   hit target by the strike flag (6th argument of +0xf0, 1 for hits and projectiles,
///   0x49b93e), not by soaking; matches (21) only a soaked one;
/// - +0xc8 recharge: 0x4b7640 flamethrower 3, 0x4b8490 ion rifle 4, 0x4b89e0 blaster 3,
///   0x4b9ca0 shocker 4, 0x4bbc50 nitrogen gun 3; Medusa's short strike (wp_medusashort,
///   class 123: +0xc8 0x4d6570, check 0x4d6560) 4, the long one (124) none;
/// - ignites a soaked target;
/// - kind: the class's own battle code (rows.WeaponKind; satellite 8, decoy 18 and the
///   Messiah's arms 1019/1020 have only that, every other property off).
pub const weapon_classes = blk: {
    const t = [_]struct { i32, bool, ?rows.Effect, i32, bool, rows.WeaponKind }{
        .{ 1, true, null, 0, true, .plain },
        .{ 2, true, null, 0, true, .plain },
        .{ 3, true, .sleep, 0, false, .plain },
        .{ 4, false, .burn, 3, true, .plain },
        .{ 5, false, null, 0, true, .plain },
        .{ 6, false, null, 4, false, .energy },
        .{ 7, false, null, 3, false, .energy },
        .{ 8, false, null, 0, false, .satellite },
        .{ 9, false, null, 0, true, .time_bomb },
        .{ 11, false, null, 0, true, .plain },
        .{ 12, true, null, 0, false, .plain },
        .{ 13, false, null, 0, true, .plain },
        .{ 14, true, null, 0, true, .plain },
        .{ 15, false, .burn, 0, true, .plain },
        .{ 16, false, .burn, 0, true, .napalm },
        .{ 17, false, null, 0, true, .barrel },
        .{ 18, false, null, 0, false, .decoy },
        .{ 19, false, .freeze, 3, false, .nitrogen },
        .{ 20, false, .soak, 0, false, .plain },
        .{ 21, false, null, 0, true, .plain },
        .{ 22, false, .sleep, 0, false, .plain },
        .{ 23, false, .gas, 0, false, .plain },
        .{ 24, false, .sleep, 4, false, .plain },
        .{ 102, false, null, 0, true, .plain },
        .{ 104, false, .gas, 0, false, .plain },
        .{ 107, false, .sleep, 0, false, .plain },
        .{ 115, false, null, 0, true, .plain },
        .{ 116, false, .soak, 0, false, .plain },
        .{ 121, false, .freeze, 0, false, .plain },
        .{ 123, false, .sleep, 4, false, .plain },
        .{ 125, false, .bite, 0, false, .plain },
        .{ 126, true, null, 0, true, .plain },
        .{ 127, true, null, 0, true, .plain },
        .{ 1005, false, .sleep, 0, false, .sleep_ball },
        .{ 1013, false, .sleep, 0, false, .plain },
        .{ 1016, false, .sleep, 0, false, .plain },
        .{ 1019, false, null, 0, false, .messiah_left },
        .{ 1020, false, null, 0, false, .messiah_right },
    };
    var out: [t.len]rows.WeaponClass = undefined;
    @setEvalBranchQuota(100_000);
    for (&out, t) |*o, r| o.* = .{ .name = nameOf(r[0]), .classic_id = r[0], .rolls_to_hit = r[1], .effect = r[2], .recharge = r[3], .ignites_soaked = r[4], .kind = r[5] };
    break :blk out;
};

/// What the exe's battle code does by weapon classic_id (combat/strike.zig, combat/anim.zig).
pub const weapon_flags = [_]rows.WeaponFlags{
    // Counter-attack exclusion list (0x491444…0x4914d0): the decoy, stun grenade,
    // dartgun, nitrogen gun, shockers, time bomb.
    .{ .weapon = 1031, .no_counter = true, .note = "decoy: no counter-attack from the hand (0x491444...0x4914d0)" },
    .{ .weapon = 33, .no_counter = true, .note = "stun grenade" },
    .{ .weapon = 45, .no_counter = true, .silent_frames = true, .note = "dartgun: its strike mutes the frame sounds (0x48c1cb)" },
    .{ .weapon = 1025, .no_counter = true, .note = "nitrogen gun" },
    .{ .weapon = 52, .no_counter = true, .shock = true, .note = "shocker: \"current\" on the target (0x491c91)" },
    .{ .weapon = 34, .no_counter = true, .note = "time bomb" },
    .{ .weapon = 55, .no_counter = true, .shock = true, .note = "shocker" },
    .{ .weapon = 92, .shock = true, .note = "RC-28's discharger" },
    .{ .weapon = 46, .sparks = true, .note = "flare gun: sparks on the target (0x491e5e)" },
};
