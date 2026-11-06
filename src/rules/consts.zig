//! Special IDs and limits the exe keeps in its code (rules `Value(name = …, value = …)`).

pub fn default(c: Const) i32 {
    return switch (c) {
        .idle_ticks => 1800,
        .party_max => 6,
        .kill_exp_pm => 200,
        .level_points => 5,
        .stat_cap => 100,
        .skill_step => 10,
        .crit_pm => 1200,
        .rage_pm => 2000,
        .side_bonus => 2,
        .back_bonus => 4,
        .counter_step => 10,
        .lose_on_hero_death => 1,
    };
}

const rows = @import("rows.zig");
const Const = rows.Const;
const Value = rows.Value;

pub const builtin = blk: {
    const names = @typeInfo(Const).@"enum".field_names;
    var out: [names.len]Value = undefined;
    for (&out, names) |*v, n| v.* = .{ .name = @field(Const, n), .value = default(@field(Const, n)) };
    break :blk out;
};
