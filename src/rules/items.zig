//! Built-in rules: items.ss (inventory/medicine.zig).

const rows = @import("rows.zig");

/// Medicine (0x48ff50): 1043 Drugs = rage + heal, 83 Painkiller = calm + heal, 1044 =
/// cure gas only, 1047 = wake only, others heal. Unknown drugs (1049) act as one of
/// {1045, 1047, 1044, 1043} (0x48ff76: rand & 3).
pub const table = [_]rows.Medicine{
    .{ .item = 1043, .kind = .rage, .note = "Drugs" },
    .{ .item = 83, .kind = .calm, .note = "Painkiller" },
    .{ .item = 1044, .kind = .ungas, .note = "gas antidote" },
    .{ .item = 1047, .kind = .wake },
    .{ .item = 1049, .random = &.{ 1045, 1047, 1044, 1043 }, .note = "unknown drugs (0x48ff76)" },
};

/// McFadden (classic_id 24) heals ⌊hp × 0.15⌋ more (0x48ffee, 0x50a218).
pub const heal_bonus = [_]rows.HealBonus{.{ .healer = 24, .pct = 15, .note = "McFadden" }};
