//! Built-in rules: fx.ss (fx/hits.zig).

const rows = @import("rows.zig");

/// Weapon sounds at the hit (0x4327f0 calls in the weapon effects).
pub const weapon_sounds = [_]rows.WeaponSound{
    .{ .weapon = 1037, .sound = "weapons\\energy_blaster", .note = "blaster" },
    .{ .weapon = 1028, .sound = "weapons\\napalm_launcher" },
    .{ .weapon = 1027, .sound = "weapons\\gas_grenade" },
    .{ .weapon = 86, .sound = "weapons\\molotov_expl" },
    // Stone, vodka, petrol: the bottle class (0x49e7c0).
    .{ .weapon = 41, .sound = "weapons\\bottle", .note = "stone, vodka, petrol: the bottle class (0x49e7c0)" },
    .{ .weapon = 1030, .sound = "weapons\\bottle" },
    .{ .weapon = 1032, .sound = "weapons\\bottle" },
    .{ .weapon = 1025, .sound = "weapons\\zamrazacz" },
    .{ .weapon = 1038, .sound = "weapons\\satelite_laser" },
    .{ .weapon = 1039, .sound = "weapons\\satelite_lighting" },
    .{ .weapon = 1040, .sound = "weapons\\satelite_rocket" },
    .{ .weapon = 33, .sound = "grenade_deaf" },
    .{ .weapon = 45, .sound = "dartsgun" },
    .{ .weapon = 1070, .sound = "kula_explo" },
    .{ .weapon = 1072, .sound = "kula_explo" },
};
