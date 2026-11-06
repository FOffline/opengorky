//! Logical animation slots of the exe (0x4280e0): per-state animation and walk speed tables.

const std = @import("std");

/// OpenGorky's own slot, not in the exe's table (kept by name): the pose of a fighter
/// lifted by an enemy (combat/attack.zig). Unbound, and always in Classic, the exe's raw
/// name instead (core module Heroes `liftPose`: "delirium", "deliriumA" for 24 and 29).
pub const lifted = "lifted";

/// Logical animation slots (the constructor fills 0x43 speeds, 0x42261b).
pub const logical_count = 0x43;

/// The slot of logical name `name` (the exe's table, core/classic.zig); 0: none. OpenGorky
/// has no slots: 0 for every name (animations and speeds by name).
pub fn logicalIndex(name: []const u8) u8 {
    if (@import("../rules.zig").og) return 0;
    for (@import("../core.zig").classic.look_slots) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return if (e.slot < logical_count) e.slot else 0;
    return 0;
}
