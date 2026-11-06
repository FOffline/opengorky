//! The exe's tuning globals (adjust.kdt, loader 0x418120) by name, as core data: 600 of
//! them (sound, effects, combat). Classic: the composition layer fills them from the file
//! (compose.loadAdjust); OpenGorky: from the rules' Setting rows (rules\adjust.ss,
//! rules.use). A name they lack, or none, is the caller's default — the one in the
//! shipped file.

const std = @import("std");
const value = @import("../script.zig").value;

pub const Value = @import("adjust_defaults.zig").Value;

/// Name → value in the order put (the file's: the rules dump keeps it); see `put`.
pub var values: std.StringArrayHashMapUnmanaged(Value) = .empty;
var names: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// No values: every one its caller's default.
pub fn clear() void {
    values.clearRetainingCapacity();
    _ = names.reset(.retain_capacity);
}

/// `name` = `v` (the name copied).
pub fn put(name: []const u8, v: Value) std.mem.Allocator.Error!void {
    const gop = try values.getOrPut(std.heap.page_allocator, name);
    if (!gop.found_existing) gop.key_ptr.* = try names.allocator().dupe(u8, name);
    gop.value_ptr.* = v;
}

/// The names asked for since tracing began (gorky-tool's OPENGORKY_ADJUST_TRACE: which
/// ones a project reads); null: not traced.
pub var traced: ?std.StringArrayHashMapUnmanaged(void) = null;

fn note(name: []const u8) void {
    const t = &(traced orelse return);
    if (t.contains(name)) return;
    t.put(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, name) catch return, {}) catch {};
    traced = t.*;
}

/// The engine's settings and their defaults (rules/adjust_defaults.zig).
pub const defaults = @import("adjust_defaults.zig").table;

/// Setting `name`'s default (null: no code of the engine reads it).
pub fn defaultOf(name: []const u8) ?Value {
    for (defaults) |d| if (std.mem.eql(u8, d[0], name)) return d[1];
    return null;
}

fn defaultFor(comptime name: []const u8) Value {
    comptime {
        @setEvalBranchQuota(100_000);
        for (defaults) |d| if (std.mem.eql(u8, d[0], name)) return d[1];
        @compileError("adjust: no setting " ++ name ++ " in rules/adjust_defaults.zig");
    }
}

/// Setting `name` (the engine's own, rules/adjust_defaults.zig) as an int.
pub fn int(comptime name: []const u8) i32 {
    return getInt(name, comptime defaultFor(name).int);
}

pub fn float(comptime name: []const u8) f32 {
    return getFloat(name, comptime defaultFor(name).float);
}

pub fn rgb(comptime name: []const u8) [3]u8 {
    return getRgb(name, comptime defaultFor(name).rgba);
}

/// A name and default of a Classic table (`adj("attack_grandma_delay", 70)` in a row);
/// the engine's own: `int`, `float`, `rgb`.
pub fn getFloat(name: []const u8, default: f32) f32 {
    note(name);
    return switch (values.get(name) orelse return default) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .rgba => default,
    };
}

pub fn getInt(name: []const u8, default: i32) i32 {
    note(name);
    return switch (values.get(name) orelse return default) {
        .int => |v| v,
        .float => |v| value.floatToInt(v),
        .rgba => default,
    };
}

pub fn getRgb(name: []const u8, default: [3]u8) [3]u8 {
    note(name);
    return switch (values.get(name) orelse return default) {
        .rgba => |v| v,
        else => default,
    };
}

test "lookups: a float read as int goes through _ftol, a missing name is the default" {
    defer clear();
    try put("f", .{ .float = 0.004 });
    try put("bad", .{ .float = std.math.nan(f32) });
    try put("c", .{ .rgba = .{ 200, 60, 20 } });
    try std.testing.expectEqual(0.004, getFloat("f", 0));
    try std.testing.expectEqual(0, getInt("bad", 7));
    try std.testing.expectEqual(7, getInt("missing", 7));
    try std.testing.expectEqual([3]u8{ 200, 60, 20 }, getRgb("c", .{ 0, 0, 0 }));
    try std.testing.expectEqual(1, getFloat("c", 1));
}
