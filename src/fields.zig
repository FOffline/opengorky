//! Typed access to common script-object variables (`.ftr`, `.hro`, `.itm`, `.wpn`).
//! Variable names are spelled once here: `fields.hp(o)` instead of `o.getInt("hp")`.

const std = @import("std");
const Object = @import("script.zig").object.Object;
const rules = @import("rules.zig");

/// `string.tab` row and object kind (heroes 1–39, monsters 100–139, items…).
pub fn classicId(o: *Object) i32 {
    return o.getInt("classic_id");
}

/// OpenGorky: an obstacle's own `explodable` (1: a barrel whatever its class, its blast
/// shown whatever its blast weapon; 0: never explodes); null: the exe's (`explosive`, the
/// blast shown only for weapon classic_id 1002).
pub fn explodable(o: *Object) ?bool {
    if (!rules.og or o.getVar("explodable") == null) return null;
    return o.getInt("explodable") != 0;
}

pub fn setClassicId(o: *Object, v: i32) void {
    o.setInt("classic_id", v);
}

pub fn hp(o: *Object) i32 {
    return o.getInt("hp");
}

pub fn setHp(o: *Object, v: i32) void {
    o.setInt("hp", v);
}

pub fn maxHp(o: *Object) i32 {
    return o.getInt("max_hp");
}

/// Count of an ammo pack (`type` 10) or other stackable item.
pub fn counter(o: *Object) i32 {
    return o.getInt("count");
}

pub fn setCounter(o: *Object, v: i32) void {
    o.setInt("count", v);
}

/// The exe's one `type` of an item (+0x368): an item's `kind`, a weapon's `damage_kind`
/// (Item_GetType gives a weapon's damage kind).
pub fn itemType(o: *Object) i32 {
    if (o.getVar("kind")) |v| return v.value.toInt();
    return o.getInt("damage_kind");
}

/// Item owner name (`owner`); empty = nobody's.
pub fn owner(o: *Object) []const u8 {
    return o.getString("owner");
}

/// Sets `Owner` if the object has it; the caller owns the string's lifetime.
pub fn setOwner(o: *Object, name: []const u8) void {
    if (o.getVar("owner")) |v| v.value = .{ .string = name };
}

/// Walk cells per round.
pub fn walkRange(o: *Object) i32 {
    return o.getInt("walk_range");
}

/// Battle fighter: the object declares `walk_range`.
pub fn isFighter(o: *Object) bool {
    return o.getVar("walk_range") != null;
}

/// Actor facing angle (`angle`).
pub fn angle(o: *Object) f32 {
    return getF(o, "angle");
}

pub fn setAngle(o: *Object, v: f32) void {
    setF(o, "angle", v);
}

/// Held-item model (`meshFile`); empty for model-less monster weapons.
pub fn meshFile(o: *Object) []const u8 {
    return o.getString("mesh");
}

/// Fighter size (affects hit chance, 0x4cedc2).
pub fn charSize(o: *Object) i32 {
    return o.getInt("footprint_tiles");
}

/// Fighter can't move (wall bosses).
pub fn moveLock(o: *Object) bool {
    return o.getInt("move_locked") != 0;
}

pub fn clearMoveLock(o: *Object) void {
    o.setInt("move_locked", 0);
}

pub fn experience(o: *Object) i32 {
    return o.getInt("experience");
}

pub fn setExperience(o: *Object, v: i32) void {
    o.setInt("experience", v);
}

/// Position (`x`, `y`, `z`) and float variables.
pub fn pos(o: *Object) [3]f32 {
    return .{ getF(o, "x"), getF(o, "y"), getF(o, "z") };
}

pub fn setPos(o: *Object, p: [3]f32) void {
    setF(o, "x", p[0]);
    setF(o, "y", p[1]);
    setF(o, "z", p[2]);
}

pub fn getF(o: *Object, comptime name: []const u8) f32 {
    const v = o.getVar(name) orelse return 0;
    return v.value.toFloat();
}

pub fn setF(o: *Object, comptime name: []const u8, v: f32) void {
    const p = o.getVar(name) orelse return;
    p.value = switch (p.type) {
        .int => .{ .int = @import("script.zig").value.floatToInt(v) },
        else => .{ .float = v },
    };
}

/// Actor `angle` per the exe: 0 is along world +X; walking turns to atan2(dy, dx)
/// (0x424bfd, 0x4238e3).
pub fn facing(dx: f32, dy: f32) f32 {
    return std.math.atan2(dy, dx);
}

/// Model rotation at draw time (0x44edb0): Rz(−π/2) on top of the actor angle so the
/// mesh's forward (+Z) points along it.
pub fn modelAngle(a: f32) f32 {
    return a - std.math.pi / 2.0;
}

/// Unit forward vector for an actor angle.
pub fn forwardOf(a: f32) [2]f32 {
    return .{ @cos(a), @sin(a) };
}

pub fn angleDiff(a: f32, b: f32) f32 {
    return std.math.atan2(@sin(a - b), @cos(a - b));
}

test facing {
    // Angle 0 is world +X; the model is rotated by −π/2.
    try std.testing.expectApproxEqAbs(@as(f32, 0), facing(1, 0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), facing(0, 1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), modelAngle(facing(0, 1)), 1e-6);
}

/// Item owner check (`Owner`, case-insensitive).
pub fn ownerIs(o: *Object, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(owner(o), name);
}

test explodable {
    const gpa = std.testing.allocator;
    var o: Object = .{ .name = "o", .class = undefined };
    defer o.vars.deinit(gpa);
    defer rules.og = false;
    rules.og = true;
    try std.testing.expect(explodable(&o) == null);
    try o.declare(gpa, "explodable", .{ .type = .int, .value = .{ .int = 1 } });
    try std.testing.expect(explodable(&o).?);
    // Classic: the exe's, whatever the object says.
    rules.og = false;
    try std.testing.expect(explodable(&o) == null);
}
