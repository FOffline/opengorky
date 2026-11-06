//! Built-in rules: actions.ss (inventory/box.zig, world/actions.zig).

const rows = @import("rows.zig");

/// The exe's actions by classic_id (0x4564b0): string.tab names; Take (3) falls back to
/// UniversalTake, Explore (7) opens the box window (inventory/box.zig, 0x4564b0) and,
/// with items, by itself (world/actions.zig, combat/control.zig); Open (1) on an exit
/// runs Open, not LevelSwitch; a left click on a Close (2) area walks there.
pub const actions = blk: {
    const names = [_][]const u8{ "Open", "Close", "Take", "Use", "Cancel", "Ok", "Explore", "TakeAll", "TakeSelected", "TurnOn", "TurnOff", "SwitchOn", "SwitchOff", "PullOn", "PullOff", "Up", "Down", "Heal" };
    var out: [names.len]rows.Action = undefined;
    for (&out, names, 1..) |*o, n, id| o.* = .{ .name = n, .classic_id = id, .kind = switch (id) {
        3 => .take,
        7 => .explore,
        else => .call,
    }, .auto_open = id == 7, .on_exit = id == 1, .walk_click = id == 2 };
    break :blk out;
};
