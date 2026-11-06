//! Save files (save.zig, text) as the core's records (world/saved.zig): what the
//! game launcher, gorky-tool and the tests write and load.

const std = @import("std");
const Allocator = std.mem.Allocator;
const file = @import("../save.zig");
const Save = @import("../world.zig").saved.Save;
const immunity = @import("../battle.zig").immunity;

/// The monster ids of the `imm` masks, in the core's table order.
const fighters = blk: {
    var ids: [immunity.table.len]i32 = undefined;
    for (&ids, immunity.table) |*id, e| id.* = e.fighter;
    break :blk ids;
};

pub fn write(sv: *const Save, out: *std.Io.Writer) !void {
    return file.write(sv, &fighters, out);
}

/// A save file's records; hero items an old save lost from the current location are
/// brought back (`Save.recoverPartyItems`). error.BadSave: not a save, or cut short.
pub fn parse(gpa: Allocator, text: []const u8) !Save {
    var s = try file.parse(Save, gpa, text, &fighters);
    errdefer s.deinit();
    try s.recoverPartyItems();
    return s;
}

fn findObj(ws: *@import("../world.zig").saved.WorldState, name: []const u8) ?*Save.Obj {
    for (ws.objects) |*o| if (std.ascii.eqlIgnoreCase(o.name, name)) return o;
    return null;
}

test "save round trip" {
    const gpa = std.testing.allocator;
    var s: Save = .init(gpa);
    defer s.deinit();
    s.current = "01_port";
    const a = s.arena.allocator();
    const vars = try a.dupe(Save.Var, &.{
        .{ .name = "hp", .value = .{ .int = 42 } },
        .{ .name = "accuracy", .value = .{ .float = 90.5 } },
        .{ .name = "owner", .value = .{ .string = "Sul livan\\x\n" } },
        // An OpenGorky `var bool` (an editor's trigger switch `ready_x`).
        .{ .name = "ready_x", .value = .{ .bool = true } },
    });
    const objs = try a.dupe(Save.Obj, &.{.{ .name = "sullivan", .class_file = "sullivan.hro", .kind = .actor, .enabled = true, .deleted = false, .placed = true, .hero = true, .idle_off = true, .idle_anim = "deliriumA", .map = 1, .state = 0, .stat_points = 5, .vars = vars, .skills = try a.dupe(Save.Skill, &.{.{ .id = 49, .level = 3 }}) }});
    try s.worlds.append(a, .{ .level = "01_port", .objects = objs });
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try write(&s, &buf.writer);
    var back = try parse(gpa, buf.written());
    defer back.deinit();
    try std.testing.expectEqualStrings("01_port", back.current);
    const o = back.worlds.items[0].objects[0];
    try std.testing.expectEqual(1, o.map);
    try std.testing.expect(o.idle_off and o.hero);
    try std.testing.expectEqualStrings("deliriumA", o.idle_anim);
    try std.testing.expectEqual(5, o.stat_points);
    try std.testing.expectEqual(42, o.vars[0].value.int);
    try std.testing.expectEqualStrings("Sul livan\\x\n", o.vars[2].value.string);
    try std.testing.expect(o.vars[3].value.bool);
    try std.testing.expectEqual(49, o.skills[0].id);
}

test "save round trip of component instances' vars and subscriptions" {
    const gpa = std.testing.allocator;
    var s: Save = .init(gpa);
    defer s.deinit();
    s.current = "01_port";
    const a = s.arena.allocator();
    const comps = try a.dupe(Save.Comp, &.{
        .{ .name = "Rage", .vars = try a.dupe(Save.Var, &.{ .{ .name = "n", .value = .{ .int = 3 } }, .{ .name = "who", .value = .{ .ref = &.{ .name = "02_sewers::rat" } } } }) },
        .{ .name = "Calm", .vars = &.{} },
    });
    const own = try a.dupe(Save.Var, &.{.{ .name = "hp", .value = .{ .int = 9 } }});
    const objs = try a.dupe(Save.Obj, &.{
        .{ .name = "grandma", .class_file = "characters::grandma", .kind = .actor, .enabled = true, .deleted = false, .placed = false, .hero = false, .map = 0, .state = 0, .stat_points = 0, .vars = own, .skills = &.{}, .comps = comps },
        .{ .name = "kid", .class_file = "characters::kid", .kind = .actor, .enabled = true, .deleted = false, .placed = false, .hero = false, .map = 0, .state = 0, .stat_points = 0, .vars = own, .skills = &.{} },
    });
    const subs = try a.dupe(Save.Sub, &.{ .{ .inst = "grandma#Rage", .event = "child died\n", .handler = "OnChildDied" }, .{ .inst = "kid#Avenger", .event = "", .handler = "heard" } });
    try s.worlds.append(a, .{ .level = "01_port", .objects = objs, .subs = subs });
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try write(&s, &buf.writer);
    try std.testing.expect(std.mem.startsWith(u8, buf.written(), "OGSAVE 2\n"));
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "var hp i:9\ncomp Rage\nvar n i:3\nvar who v:@\"02_sewers::rat\"\ncomp Calm\nobj kid") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "sub grandma#Rage OnChildDied child died\\n\nsub kid#Avenger heard \nend\n") != null);
    var back = try parse(gpa, buf.written());
    defer back.deinit();
    const ws = back.worlds.items[0];
    const g = ws.objects[0];
    try std.testing.expectEqual(1, g.vars.len);
    try std.testing.expectEqual(2, g.comps.len);
    try std.testing.expectEqualStrings("Rage", g.comps[0].name);
    try std.testing.expectEqual(3, g.comps[0].vars[0].value.int);
    try std.testing.expectEqualStrings("02_sewers::rat", g.comps[0].vars[1].value.ref.name);
    try std.testing.expectEqual(0, g.comps[1].vars.len);
    try std.testing.expectEqual(0, ws.objects[1].comps.len);
    try std.testing.expectEqual(1, ws.objects[1].vars.len);
    try std.testing.expectEqualStrings("child died\n", ws.subs[0].event);
    try std.testing.expectEqualStrings("OnChildDied", ws.subs[0].handler);
    try std.testing.expectEqualStrings("kid#Avenger", ws.subs[1].inst);
    // A copy (the "battle" save) keeps them; written again, the same text.
    var copy = try back.clone(gpa);
    defer copy.deinit();
    var again: std.Io.Writer.Allocating = .init(gpa);
    defer again.deinit();
    try write(&copy, &again.writer);
    try std.testing.expectEqualStrings(buf.written(), again.written());
    // A `comp` before any `obj` is a broken save.
    try std.testing.expectError(error.BadSave, parse(gpa, "OGSAVE 2\ncurrent l\nworld l\ncomp X\nend\n"));
}

test "save round trip of OpenGorky lists, records, references, nil" {
    const gpa = std.testing.allocator;
    var s: Save = .init(gpa);
    defer s.deinit();
    s.current = "01_port";
    const a = s.arena.allocator();
    const Value = @TypeOf(@as(Save.Var, undefined).value);
    const grandma = try a.create(Value.Handle);
    grandma.* = .{ .name = "grand \"ma\"#Rage" };
    // list<Wave>: Wave(turn = 3, spawn = [Spawn(who = …, tile = [5, 2])]), floats, a ref.
    const spawn = try a.create(Value.Map);
    spawn.* = .{ .keys = try a.dupe(Value, &.{ .{ .string = "who" }, .{ .string = "tile" } }), .values = try a.dupe(Value, &.{ .{ .string = "characters::grandma_child" }, .{ .list = try a.dupe(Value, &.{ .{ .int = 5 }, .{ .int = -2 } }) } }) };
    const wave = try a.create(Value.Map);
    wave.* = .{ .keys = try a.dupe(Value, &.{ .{ .string = "turn" }, .{ .string = "spawn" }, .{ .int = 7 } }), .values = try a.dupe(Value, &.{ .{ .float = 3 }, .{ .list = try a.dupe(Value, &.{.{ .map = spawn }}) }, .{ .list = &.{} } }) };
    const vars = try a.dupe(Save.Var, &.{
        .{ .name = "waves", .value = .{ .list = try a.dupe(Value, &.{ .{ .map = wave }, .nil, .{ .bool = false }, .{ .float = -0.25 }, .{ .string = "a, b]\n" } }) } },
        .{ .name = "target", .value = .{ .ref = grandma } },
        .{ .name = "none", .value = .nil },
        .{ .name = "hp", .value = .{ .int = 3 } },
    });
    const objs = try a.dupe(Save.Obj, &.{.{ .name = "level", .class_file = "locations::_01_port", .kind = .other, .enabled = true, .deleted = false, .placed = false, .hero = false, .map = 0, .state = 0, .stat_points = 0, .vars = vars, .skills = &.{} }});
    try s.worlds.append(a, .{ .level = "01_port", .objects = objs });
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try write(&s, &buf.writer);
    try std.testing.expect(std.mem.startsWith(u8, buf.written(), "OGSAVE 2\n"));
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "var waves v:[{\"turn\": 3.0, \"spawn\": [{\"who\": \"characters::grandma_child\", \"tile\": [5, -2]}], 7: []}, nil, false, -0.25, \"a, b]\\n\"]\n") != null);
    var back = try parse(gpa, buf.written());
    defer back.deinit();
    const v = back.worlds.items[0].objects[0].vars;
    // Written again, the same text: every kind and its nesting came back.
    var again: std.Io.Writer.Allocating = .init(gpa);
    defer again.deinit();
    try write(&back, &again.writer);
    try std.testing.expectEqualStrings(buf.written(), again.written());
    const w0 = v[0].value.list[0].map;
    try std.testing.expectEqual(@as(f32, 3), w0.values[0].float);
    try std.testing.expectEqualStrings("characters::grandma_child", w0.values[1].list[0].map.values[0].string);
    try std.testing.expectEqual(-2, w0.values[1].list[0].map.values[1].list[1].int);
    try std.testing.expectEqual(7, w0.keys[2].int);
    try std.testing.expectEqualStrings("a, b]\n", v[0].value.list[4].string);
    try std.testing.expectEqualStrings("grand \"ma\"#Rage", v[1].value.ref.name);
    try std.testing.expectEqual(.nil, std.meta.activeTag(v[2].value));
    try std.testing.expectEqual(3, v[3].value.int);
    // Broken literals are a broken save.
    for ([_][]const u8{ "v:[1, 2", "v:{\"a\" 1}", "v:@grandma", "v:[1] x", "v:\"open" }) |bad| {
        const text = try std.fmt.allocPrint(gpa, "OGSAVE 2\ncurrent l\nworld l\nobj o c other 1 0 0 0\nvar x {s}\nend\n", .{bad});
        defer gpa.free(text);
        try std.testing.expectError(error.BadSave, parse(gpa, text));
    }
}

test "recover party items from other levels" {
    // Gloves only in the worker room's section (lost from 01_port), the knife used up on
    // 01_port, the key on the ground: only the gloves move.
    const text =
        \\OGSAVE 1
        \\current 01_port
        \\world 01_port
        \\obj sullivan sullivan.hro actor 13 0 0 0
        \\obj knife knife.itm item 2 0 0 0
        \\var owner s:sullivan
        \\var place i:1
        \\end
        \\world 01_port_worker
        \\obj sullivan sullivan.hro actor 13 0 0 0
        \\obj gloves gloves.itm item 1 0 0 0
        \\var owner s:sullivan
        \\var place i:1
        \\obj knife knife.itm item 1 0 0 0
        \\var owner s:sullivan
        \\var place i:1
        \\obj key key.itm item 1 0 0 0
        \\var owner s:
        \\var place i:0
        \\end
        \\
    ;
    var s = try parse(std.testing.allocator, text);
    defer s.deinit();
    const cur = s.find("01_port").?;
    try std.testing.expect(findObj(cur, "gloves") != null);
    try std.testing.expect(findObj(cur, "key") == null);
    try std.testing.expect(findObj(cur, "knife").?.deleted);
}

test "truncated save is rejected" {
    const id = immunity.table[0].fighter;
    var hb: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&hb, "OGSAVE 1\ncurrent 01_port\nimm {d} 3\n", .{id});
    const ok = "world 01_port\nobj sullivan sullivan.hro actor 13 0 0 0\nend\n";
    var tb: [512]u8 = undefined;
    // Cut mid-section, a section without "end" before the next, no current location.
    for ([_][]const u8{ "world 01_port\nobj sullivan sullivan.hro actor 13 0 0 0\n", "world 01_port\nworld 01_port_worker\nend\n", "world 01_port_worker\nend\n" }) |tail| {
        const t = try std.fmt.bufPrint(&tb, "{s}{s}", .{ head, tail });
        try std.testing.expectError(error.BadSave, parse(std.testing.allocator, t));
    }
    // Actor state outside the idle tables.
    try std.testing.expectError(error.BadSave, parse(std.testing.allocator, try std.fmt.bufPrint(&tb, "{s}world 01_port\nobj sullivan sullivan.hro actor 13 0 12 0\nend\n", .{head})));
    var s = try parse(std.testing.allocator, try std.fmt.bufPrint(&tb, "{s}{s}", .{ head, ok }));
    defer s.deinit();
    try std.testing.expectEqual(3, s.imm[0]);
}
