//! Built-in rules: the exe's fighter classes (`classType`, factory 0x4bc6c0) by name — a
//! Classic piece. A Classic fighter's `classType` is one of these numbers; an OpenGorky
//! project names its classes itself (`battle_class = smokerider`, rows' `class_name`) and
//! the rules number them (rules.zig fighterClassId); the converter writes these names.

const std = @import("std");

/// The exe's classes: number and name; `generic` (100) is the port's own fighter of fields.
pub const names = [_]struct { i32, []const u8 }{
    .{ 1, "garcia" },  .{ 2, "hero" },       .{ 3, "hero3" },    .{ 4, "hero4" },
    .{ 5, "monitor" }, .{ 6, "smokerider" }, .{ 7, "grandma" },  .{ 8, "grandma_child" },
    .{ 9, "stinger" }, .{ 10, "fatman" },    .{ 11, "incubus" }, .{ 12, "cripple" },
    .{ 13, "puppet" }, .{ 14, "guard" },     .{ 15, "judge" },   .{ 16, "judge_child" },
    .{ 17, "schizo" }, .{ 18, "messiah" },   .{ 19, "lamare" },  .{ 100, "generic" },
};

/// The name of exe class `n` (null: none).
pub fn nameOf(n: i32) ?[]const u8 {
    for (names) |x| if (x[0] == n) return x[1];
    return null;
}

/// The exe's number of class `name`, any case (null: none).
pub fn idOf(name: []const u8) ?i32 {
    for (names) |x| if (std.ascii.eqlIgnoreCase(x[1], name)) return x[0];
    return null;
}

test "the exe's classes by name" {
    try std.testing.expectEqual(@as(?i32, 6), idOf("SmokeRider"));
    try std.testing.expectEqualStrings("generic", nameOf(100).?);
}
