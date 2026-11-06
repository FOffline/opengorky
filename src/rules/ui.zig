//! Built-in rules: ui.ss (battle/report.zig, viewer/gui/windows.zig).

const rows = @import("rows.zig");

/// The after-battle report's kill icons (0x523f00).
pub const monster_icons = [_]rows.KillIcon{
    .{ .fighter = 125, .icon = "cripple" },         .{ .fighter = 105, .icon = "cutterpil" },       .{ .fighter = 107, .icon = "fang" },
    .{ .fighter = 124, .icon = "fatman" },          .{ .fighter = 101, .icon = "garcia" },          .{ .fighter = 113, .icon = "grandma" },
    .{ .fighter = 131, .icon = "guard" },           .{ .fighter = 122, .icon = "harvester" },       .{ .fighter = 118, .icon = "headnail" },
    .{ .fighter = 128, .icon = "hornet" },          .{ .fighter = 108, .icon = "hound" },           .{ .fighter = 138, .icon = "incubus" },
    .{ .fighter = 120, .icon = "invisible" },       .{ .fighter = 100, .icon = "jet elmer" },       .{ .fighter = 115, .icon = "judge" },
    .{ .fighter = 116, .icon = "judgeslave" },      .{ .fighter = 129, .icon = "lillith" },         .{ .fighter = 135, .icon = "lillith" },
    .{ .fighter = 137, .icon = "lucy" },            .{ .fighter = 119, .icon = "medusa_rap" },      .{ .fighter = 139, .icon = "messiah" },
    .{ .fighter = 130, .icon = "needle" },          .{ .fighter = 121, .icon = "paingod" },         .{ .fighter = 132, .icon = "puppet" },
    .{ .fighter = 106, .icon = "rc28" },            .{ .fighter = 126, .icon = "reverend insect" }, .{ .fighter = 136, .icon = "schizo family" },
    .{ .fighter = 109, .icon = "sinner" },          .{ .fighter = 123, .icon = "sister of mercy" }, .{ .fighter = 110, .icon = "smoke" },
    .{ .fighter = 102, .icon = "sphinks" },         .{ .fighter = 133, .icon = "squeaker" },        .{ .fighter = 127, .icon = "stinger" },
    .{ .fighter = 114, .icon = "wnuczek" },         .{ .fighter = 27, .icon = "kozow_rap" },        .{ .fighter = 141, .icon = "nato_capitan_rap" },
    .{ .fighter = 25, .icon = "nato_soldier_rap" }, .{ .fighter = 28, .icon = "specnaz_rap" },      .{ .fighter = 142, .icon = "Lamare" },
};

/// The actors' glows (0x42a620: the Incubus 138's).
pub const glows = [_]rows.Glow{.{ .fighter = 138, .note = "Incubus (0x42a620)" }};

/// The weapon skills window's rows: weapons with level above 0 and an icon here
/// (table 0x52a3a8; viewer/gui/windows.zig). The built-in rows (rules ui.ss).
pub const skill_icons = [_]rows.SkillIcon{
    .{ .weapon = 49, .icon = "pistolet" },          .{ .weapon = 98, .icon = "riffle" },         .{ .weapon = 45, .icon = "dartgun" },
    .{ .weapon = 1022, .icon = "Chaingun" },        .{ .weapon = 1023, .icon = "shotgun" },      .{ .weapon = 1024, .icon = "RocketLuncher" },
    .{ .weapon = 1025, .icon = "LiquidThrower" },   .{ .weapon = 1026, .icon = "FlameThrower" }, .{ .weapon = 42, .icon = "axe" },
    .{ .weapon = 76, .icon = "bejsbol" },           .{ .weapon = 44, .icon = "crowbar" },        .{ .weapon = 52, .icon = "shocker" },
    .{ .weapon = 43, .icon = "bagnet" },            .{ .weapon = 70, .icon = "fist" },           .{ .weapon = 35, .icon = "grenade" },
    .{ .weapon = 1027, .icon = "grenade_teargas" }, .{ .weapon = 86, .icon = "Molotov" },        .{ .weapon = 33, .icon = "bomb_stun" },
    .{ .weapon = 40, .icon = "knife_throwing" },    .{ .weapon = 34, .icon = "bomb_time" },      .{ .weapon = 1037, .icon = "blaster" },
    .{ .weapon = 1028, .icon = "NapalmThrower" },   .{ .weapon = 1029, .icon = "IonRifle" },     .{ .weapon = 80, .icon = "matches" },
    .{ .weapon = 1030, .icon = "gasoline" },        .{ .weapon = 1031, .icon = "distractor" },   .{ .weapon = 1032, .icon = "vodka" },
    .{ .weapon = 1020, .icon = "MedusaShort" },     .{ .weapon = 1021, .icon = "MedusaLong" },
};
