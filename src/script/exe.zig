//! `exe.*`: the original interpreter's quirks the Classic importer keeps where it cannot
//! prove the plain IR node behaves the same. Arguments come in source
//! order; the runtime evaluates them right to left, as the exe does (0x4e3620).

const std = @import("std");
const ir = @import("ir.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub fn call(op: ir.ExeOp, args: []const Value) Value {
    return switch (op) {
        inline .add, .sub, .mul, .div, .eq, .ne, .lt, .le, .gt, .ge, .@"and", .@"or" => |o| value_mod.binary(@field(@import("ast.zig").BinaryOp, @tagName(o)), args[0], args[1]),
        // Unary minus parses a string (`toInt`), unlike arithmetic (0x4c6510 gives 0).
        .neg => switch (args[0]) {
            .float => |f| .{ .float = -f },
            else => .{ .int = -%args[0].toInt() },
        },
        .not => .{ .int = @intFromBool(!args[0].exeTruth()) },
        .truthy => .{ .int = @intFromBool(args[0].exeTruth()) },
    };
}

test "exe quirks: ==, !=, <=, truth, string operands" {
    const t = std.testing;
    // `==` on truncated integers; two strings are always equal.
    try t.expectEqual(Value{ .int = 1 }, call(.eq, &.{ .{ .float = 1.5 }, .{ .int = 1 } }));
    try t.expectEqual(Value{ .int = 1 }, call(.eq, &.{ .{ .string = "a" }, .{ .string = "b" } }));
    // `!=` adds, `<=` is `>=`.
    try t.expectEqual(Value{ .int = 5 }, call(.ne, &.{ .{ .int = 2 }, .{ .int = 3 } }));
    try t.expectEqual(Value{ .int = 0 }, call(.le, &.{ .{ .int = 3 }, .{ .int = 5 } }));
    // Truth: a fraction truncates, a string is false.
    try t.expectEqual(Value{ .int = 0 }, call(.truthy, &.{.{ .float = 0.5 }}));
    try t.expectEqual(Value{ .int = 0 }, call(.truthy, &.{.{ .string = "x" }}));
    try t.expectEqual(Value{ .int = 1 }, call(.not, &.{.{ .float = 0.5 }}));
    // A string is 0 in int arithmetic, parsed in float arithmetic and by unary minus.
    try t.expectEqual(Value{ .int = 1 }, call(.add, &.{ .{ .string = "5" }, .{ .int = 1 } }));
    try t.expectEqual(Value{ .float = 6.5 }, call(.add, &.{ .{ .string = "5" }, .{ .float = 1.5 } }));
    try t.expectEqual(Value{ .int = -5 }, call(.neg, &.{.{ .string = "5" }}));
    // `&&` on the exe's truth.
    try t.expectEqual(Value{ .int = 0 }, call(.@"and", &.{ .{ .float = 0.5 }, .{ .int = 1 } }));
    try t.expectEqual(Value{ .int = 1 }, call(.@"or", &.{ .{ .string = "x" }, .{ .int = 1 } }));
}
