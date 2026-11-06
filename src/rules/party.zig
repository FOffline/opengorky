//! Built-in rules: party.ss (battle/rules.zig, game.zig, inventory/equipment.zig).

const rows = @import("rows.zig");

/// Exp thresholds (table 0x528c3c).
pub const exp_levels = blk: {
    const t = [20]i32{ 0, 220, 450, 705, 1010, 1385, 1910, 2720, 4260, 8745, 17490, 34980, 69960, 139920, 279840, 559680, 1119360, 2238720, 4477440, 8954880 };
    var out: [t.len]rows.ExpLevel = undefined;
    for (&out, t, 0..) |*o, e, i| o.* = .{ .level = i, .exp = e };
    break :blk out;
};

/// Idle lines (0x451110): Sullivan, Ovitz (first plays "medicine"),
/// Trantigne.
pub const idle_chatter = [_]rows.IdleChatter{
    .{ .hero = 20, .dialog = "idle_su_01.dlg", .note = "Sullivan" },
    .{ .hero = 21, .dialog = "idle_ov_01.dlg", .anim = "medicine", .note = "Ovitz" },
    .{ .hero = 22, .dialog = "idle_tr_01.dlg", .note = "Trantigne" },
};

/// Weapons a fighter doesn't draw in hand (table 0x5270a0, 0x481f50).
pub const hidden_weapons = [_]rows.HiddenWeapons{
    .{ .hero = 29, .weapons = &.{ 34, 98, 1022, 1023, 1024, 1025, 1026, 1037, 1028, 1029 }, .note = "Hutchens" },
    .{ .hero = 24, .weapons = &.{ 34, 1022, 1024, 1025, 1026, 1037, 1028, 1029 }, .note = "McFadden" },
};
