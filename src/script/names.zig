//! The script's interned names: each lower-case variable name gets a small id once
//! (object.zig's variables are keyed by it; the parsers resolve identifiers to it).

const std = @import("std");

/// Process-wide table of lower-case variable names: each name gets a small id once, so
/// object lookups compare integers instead of hashing strings (~13% of a playthrough).
/// Only the script thread touches it.
const table = struct {
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    var list: std.ArrayList([]const u8) = .empty;
    const gpa = std.heap.smp_allocator;
};

/// Id of a lower-case name, adding it to the table.
pub fn internName(lower: []const u8) std.mem.Allocator.Error!u32 {
    if (table.ids.get(lower)) |id| return id;
    const copy = try table.gpa.dupe(u8, lower);
    errdefer table.gpa.free(copy);
    const id: u32 = @intCast(table.list.items.len);
    try table.list.append(table.gpa, copy);
    errdefer _ = table.list.pop();
    try table.ids.put(table.gpa, copy, id);
    return id;
}

/// Id of a name in any case, adding it to the table (the parser resolves identifiers once).
pub fn intern(name: []const u8) std.mem.Allocator.Error!u32 {
    var buf: [128]u8 = undefined;
    if (name.len <= buf.len) return internName(std.ascii.lowerString(&buf, name));
    const lower = try table.gpa.alloc(u8, name.len);
    defer table.gpa.free(lower);
    return internName(std.ascii.lowerString(lower, name));
}

/// Id of a lower-case name, or null if no object ever declared it.
pub fn findName(lower: []const u8) ?u32 {
    return table.ids.get(lower);
}

/// Id of a name in any case, or null if none was interned (names over 128 bytes: none).
pub fn findAnyCase(name: []const u8) ?u32 {
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) return null;
    return findName(std.ascii.lowerString(&buf, name));
}

/// Lower-case name of an id.
pub fn nameOf(id: u32) []const u8 {
    return table.list.items[id];
}
