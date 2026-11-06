//! A level in several texts: a location's or battle's folder holds its
//! block in more than one `.ogs` (the writer's `level.ogs`/`battle.ogs`: the level's own
//! fields; `objects.ogs`: its objects; `logic.ogs`: its code), each a `level "x" { … }` /
//! `battle "x" { … }` of the same name. Before the program is linked they are one block:
//! the parts in their files' path order (any file names, whatever order they were read
//! in), its fields, variables, components, objects and its own code (`fn`s, `injects`:
//! one part's) together. A field, variable, component, object or own code in two parts is
//! an error naming both files. Every reader of a
//! project's texts merges them so (loaders/ogs.zig, the build, the world's program:
//! state/hooks.zig).
//! shortcut: the merged block lives in its first part's text, so a link error of an
//! object of another part names that text with the object's own line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const parser = @import("parser.zig");

/// What went wrong merging (the part with it is left out).
pub const Problem = struct { file: []const u8, line: u32, message: []const u8 };

const Part = struct { unit: usize, module: usize, entity: usize, file: []const u8 };

fn isLevel(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "level") or std.mem.eql(u8, kind, "battle");
}

/// The split level blocks of `units` made one, in place (a unit's modules copied where
/// one changes); the first problem, if any (that part stays out).
pub fn merge(a: Allocator, units: []parser.Unit) Allocator.Error!?Problem {
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(Part)) = .empty;
    for (units, 0..) |u, ui| for (u.modules, 0..) |m, mi| for (m.entities, 0..) |e, ei| {
        if (!isLevel(e.kind)) continue;
        const k = try std.fmt.allocPrint(a, "{s} {s}::{s}", .{ e.kind, m.path, e.name });
        const g = try groups.getOrPut(a, k);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(a, .{ .unit = ui, .module = mi, .entity = ei, .file = u.file });
    };
    var problem: ?Problem = null;
    // Entities to drop: (unit, module) → their indexes.
    var drop: std.AutoHashMapUnmanaged([2]usize, std.ArrayList(usize)) = .empty;
    for (groups.values()) |*parts| {
        if (parts.items.len < 2) continue;
        std.mem.sort(Part, parts.items, {}, struct {
            fn lt(_: void, x: Part, y: Part) bool {
                return std.mem.order(u8, x.file, y.file) == .lt;
            }
        }.lt);
        const first = parts.items[0];
        var e = units[first.unit].modules[first.module].entities[first.entity];
        var fields: std.ArrayList(ir.Named) = .empty;
        var vars: std.ArrayList(ir.Field) = .empty;
        var attach: std.ArrayList(ir.Attach) = .empty;
        var children: std.ArrayList(ir.Entity) = .empty;
        // Where each name came from (its part's file), to name both.
        var from: std.StringHashMapUnmanaged([]const u8) = .empty;
        var own: ?*const ir.Component = null;
        var own_file: []const u8 = "";
        for (parts.items) |p| {
            const x = units[p.unit].modules[p.module].entities[p.entity];
            const clash: ?[]const u8 = blk: {
                if (x.base.len > 0 and e.base.len > 0 and !std.mem.eql(u8, x.base, e.base)) break :blk try std.fmt.allocPrint(a, "{s} {s}: archetype {s} here, {s} in {s}", .{ e.kind, e.name, x.base, e.base, first.file });
                for (x.fields) |f| if (from.get(try std.fmt.allocPrint(a, "f {s}", .{f.name}))) |o| break :blk try std.fmt.allocPrint(a, "{s} {s}: field {s} is in {s} and {s}", .{ e.kind, e.name, f.name, o, p.file });
                for (x.vars) |f| if (from.get(try std.fmt.allocPrint(a, "v {s}", .{f.name}))) |o| break :blk try std.fmt.allocPrint(a, "{s} {s}: var {s} is in {s} and {s}", .{ e.kind, e.name, f.name, o, p.file });
                for (x.attach) |t| if (from.get(try std.fmt.allocPrint(a, "a {s}", .{t.component}))) |o| break :blk try std.fmt.allocPrint(a, "{s} {s}: attach {s} is in {s} and {s}", .{ e.kind, e.name, t.component, o, p.file });
                for (x.children) |c| if (from.get(try std.fmt.allocPrint(a, "c {s}", .{c.name}))) |o| break :blk try std.fmt.allocPrint(a, "{s} {s}: {s} {s} is in {s} and {s}", .{ e.kind, e.name, c.kind, c.name, o, p.file });
                if (x.own != null and own != null) break :blk try std.fmt.allocPrint(a, "{s} {s}: its own code is in {s} and {s}", .{ e.kind, e.name, own_file, p.file });
                break :blk null;
            };
            if (clash) |msg| {
                if (problem == null) problem = .{ .file = p.file, .line = x.line, .message = msg };
            } else {
                if (x.base.len > 0) e.base = x.base;
                try fields.appendSlice(a, x.fields);
                try vars.appendSlice(a, x.vars);
                try attach.appendSlice(a, x.attach);
                try children.appendSlice(a, x.children);
                if (x.own) |o| {
                    own = o;
                    own_file = p.file;
                }
                for (x.fields) |f| try from.put(a, try std.fmt.allocPrint(a, "f {s}", .{f.name}), p.file);
                for (x.vars) |f| try from.put(a, try std.fmt.allocPrint(a, "v {s}", .{f.name}), p.file);
                for (x.attach) |t| try from.put(a, try std.fmt.allocPrint(a, "a {s}", .{t.component}), p.file);
                for (x.children) |c| try from.put(a, try std.fmt.allocPrint(a, "c {s}", .{c.name}), p.file);
            }
            if (p.unit == first.unit and p.module == first.module and p.entity == first.entity) continue;
            const d = try drop.getOrPut(a, .{ p.unit, p.module });
            if (!d.found_existing) d.value_ptr.* = .empty;
            try d.value_ptr.append(a, p.entity);
        }
        e.fields = fields.items;
        e.vars = vars.items;
        e.attach = attach.items;
        e.children = children.items;
        e.own = own;
        try put(a, units, first.unit, first.module, first.entity, e);
    }
    var it = drop.iterator();
    while (it.next()) |d| {
        const ui, const mi = d.key_ptr.*;
        const m = units[ui].modules[mi];
        var keep: std.ArrayList(ir.Entity) = .empty;
        for (m.entities, 0..) |x, i| if (std.mem.indexOfScalar(usize, d.value_ptr.items, i) == null) try keep.append(a, x);
        const ms = try a.dupe(ir.Module, units[ui].modules);
        ms[mi].entities = keep.items;
        units[ui].modules = ms;
    }
    return problem;
}

/// Entity `ei` of module `mi` of unit `ui` replaced by `e` (the unit's modules copied).
fn put(a: Allocator, units: []parser.Unit, ui: usize, mi: usize, ei: usize, e: ir.Entity) Allocator.Error!void {
    const ms = try a.dupe(ir.Module, units[ui].modules);
    const es = try a.dupe(ir.Entity, ms[mi].entities);
    es[ei] = e;
    ms[mi].entities = es;
    units[ui].modules = ms;
}

test "a level in several texts: one block, its parts in path order; a clash names both files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: parser.Diagnostic = .{};
    var units = [_]parser.Unit{
        try parser.parse(a, "battle \"b\" {\n    fighter x {\n        hp = 1;\n    }\n}\n", "battles/b/objects.ogs", &d),
        try parser.parse(a, "battle \"b\" {\n    turn = 2;\n}\nmodule battles::b { fn f() { return 1; } }\n", "battles/b/battle.ogs", &d),
    };
    try std.testing.expect(try merge(a, &units) == null);
    // The first file by path holds it: battle.ogs, with the object of objects.ogs.
    const e = units[1].modules[0].entities[0];
    try std.testing.expectEqual(1, e.fields.len);
    try std.testing.expectEqualStrings("x", e.children[0].name);
    try std.testing.expectEqual(0, units[0].modules[0].entities.len);
    var twice = [_]parser.Unit{
        try parser.parse(a, "battle \"b\" {\n    fighter x { }\n}\n", "battles/b/a.ogs", &d),
        try parser.parse(a, "battle \"b\" {\n    fighter x { }\n}\n", "battles/b/z.ogs", &d),
    };
    const p = (try merge(a, &twice)).?;
    try std.testing.expectEqualStrings("battles/b/z.ogs", p.file);
    try std.testing.expectEqualStrings("battle b: fighter x is in battles/b/a.ogs and battles/b/z.ogs", p.message);
    try std.testing.expectEqual(1, twice[0].modules[0].entities[0].children.len);
    // Its own code in one part (logic.ogs) is the merged block's; in two, an error.
    var code = [_]parser.Unit{
        try parser.parse(a, "battle \"b\" {\n    turn = 2;\n}\n", "battles/b/battle.ogs", &d),
        try parser.parse(a, "battle \"b\" {\n    fn OnShown() { return 1; }\n}\n", "battles/b/logic.ogs", &d),
    };
    try std.testing.expect(try merge(a, &code) == null);
    try std.testing.expectEqualStrings("OnShown", code[0].modules[0].entities[0].own.?.methods[0].name);
    var code2 = [_]parser.Unit{
        try parser.parse(a, "battle \"b\" {\n    fn f() { return 1; }\n}\n", "battles/b/a.ogs", &d),
        try parser.parse(a, "battle \"b\" {\n    fn g() { return 1; }\n}\n", "battles/b/z.ogs", &d),
    };
    try std.testing.expectEqualStrings("battle b: its own code is in battles/b/a.ogs and battles/b/z.ogs", (try merge(a, &code2)).?.message);
}
