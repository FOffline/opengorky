//! Built-in rules: resist.ss (battle/immunity.zig).

const rows = @import("rows.zig");

/// Monster resistances (table 0x6d2070, extracted by emulating 0x4c91c0: 35 entries);
/// the saves keep discovered bits in this order.
pub const table = [_]rows.Resist{
    .{ .fighter = 125, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 1, 1, 0 } }, .armor = -2, .note = "Cripple" },
    .{ .fighter = 105, .resist = .{ .bits = .{ 1, 0, 0, 0, 0, 0, 0, 0 } }, .armor = -2, .note = "Cutter Pill" },
    .{ .fighter = 107, .resist = .{ .bits = .{ 0, 0, 0, 0, 0, 0, 0, 0 } }, .armor = -3, .note = "Fang" },
    .{ .fighter = 124, .resist = .{ .bits = .{ 0, 1, 1, 1, 1, 0, 1, 1 } }, .armor = -3, .note = "Fatman" },
    .{ .fighter = 101, .resist = .{ .bits = .{ 0, 0, 0, 0, 0, 0, 0, 0 } }, .armor = -2, .note = "Garcia" },
    .{ .fighter = 113, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 0, 1, 0 } }, .armor = -2, .note = "Grandma" },
    .{ .fighter = 114, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 0, 0, 0 } }, .armor = -1, .note = "Grandson" },
    .{ .fighter = 131, .resist = .{ .bits = .{ 0, 0, 1, 1, 0, 1, 0, 0 } }, .armor = -3, .note = "Guard" },
    .{ .fighter = 122, .resist = .{ .bits = .{ 0, 0, 1, 1, 0, 1, 0, 0 } }, .armor = -3, .note = "Harvester" },
    .{ .fighter = 118, .resist = .{ .bits = .{ 0, 0, 0, 0, 0, 0, 0, 0 } }, .armor = -2, .note = "Headnail" },
    .{ .fighter = 128, .resist = .{ .bits = .{ 0, 0, 0, 0, 0, 0, 1, 0 } }, .armor = -2, .note = "Hornet" },
    .{ .fighter = 108, .resist = .{ .bits = .{ 0, 0, 0, 1, 0, 0, 0, 0 } }, .armor = -1, .note = "Hound" },
    .{ .fighter = 138, .resist = .{ .bits = .{ 0, 0, 1, 1, 0, 1, 1, 0 } }, .armor = -3, .note = "Incubus" },
    .{ .fighter = 120, .resist = .{ .bits = .{ 1, 1, 1, 1, 1, 1, 1, 1 } }, .armor = -2, .note = "Invisible" },
    .{ .fighter = 100, .resist = .{ .bits = .{ 1, 0, 0, 1, 0, 0, 0, 0 } }, .armor = -2, .note = "Jet Elmer" },
    .{ .fighter = 115, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 0, 0, 0 } }, .armor = -2, .note = "Judge" },
    .{ .fighter = 116, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 0, 0, 0 } }, .armor = -1, .note = "Judge's child" },
    .{ .fighter = 129, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 1, 0, 0 } }, .armor = -2, .note = "Lilith" },
    .{ .fighter = 135, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 1, 0, 0 } }, .armor = -2, .note = "Lilith's child" },
    .{ .fighter = 137, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 1, 0, 0 } }, .armor = -2, .note = "Lucy" },
    .{ .fighter = 119, .resist = .{ .bits = .{ 0, 0, 1, 1, 0, 1, 0, 0 } }, .armor = -2, .note = "Medusa" },
    .{ .fighter = 139, .resist = .{ .bits = .{ 1, 0, 1, 0, 1, 1, 1, 0 } }, .armor = -2, .note = "Messiah" },
    .{ .fighter = 130, .resist = .{ .bits = .{ 0, 1, 0, 1, 0, 0, 0, 0 } }, .armor = -2, .note = "Needle" },
    .{ .fighter = 121, .resist = .{ .bits = .{ 1, 0, 0, 0, 1, 0, 1, 1 } }, .armor = -1, .note = "Pain God" },
    .{ .fighter = 132, .resist = .{ .bits = .{ 1, 0, 1, 0, 0, 0, 0, 0 } }, .armor = -3, .note = "Puppet" },
    .{ .fighter = 106, .resist = .{ .bits = .{ 0, 1, 0, 0, 0, 0, 0, 0 } }, .armor = -1, .note = "RC-28" },
    .{ .fighter = 126, .resist = .{ .bits = .{ 0, 0, 0, 1, 1, 1, 0, 0 } }, .armor = -3, .note = "Reverend Insect" },
    .{ .fighter = 136, .resist = .{ .bits = .{ 0, 0, 1, 0, 1, 0, 1, 1 } }, .armor = -3, .note = "Schizo" },
    .{ .fighter = 117, .resist = .{ .bits = .{ 0, 0, 0, 0, 0, 0, 0, 0 } }, .armor = -2, .note = "Shoggoth" },
    .{ .fighter = 109, .resist = .{ .bits = .{ 0, 1, 0, 0, 0, 0, 0, 0 } }, .armor = -1, .note = "Siner" },
    .{ .fighter = 123, .resist = .{ .bits = .{ 1, 1, 0, 0, 0, 0, 0, 1 } }, .armor = -3, .note = "Sister of Mercy" },
    .{ .fighter = 110, .resist = .{ .bits = .{ 1, 1, 1, 1, 1, 0, 1, 1 } }, .armor = -2, .note = "Smoke Rider" },
    .{ .fighter = 102, .resist = .{ .bits = .{ 0, 0, 0, 0, 0, 0, 0, 0 } }, .armor = -1, .note = "Sphinx" },
    .{ .fighter = 133, .resist = .{ .bits = .{ 0, 0, 1, 0, 0, 1, 1, 0 } }, .armor = -3, .note = "Squeaker" },
    .{ .fighter = 127, .resist = .{ .bits = .{ 1, 0, 1, 1, 0, 0, 0, 0 } }, .armor = -2, .note = "Stinger" },
};
