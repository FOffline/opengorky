//! Script functions the engine calls by name (not the scripts): the exe's callbacks of
//! level, object, area, item, path and battle scripts (their call sites in src/world,
//! src/game, src/combat, src/inventory) and the OpenGorky hooks of `rules\hooks.ss`
//! (state/hooks.zig), for the code editor: who calls each, when, and what each parameter
//! is (English, Russian). Both tables are script/traits.zig's (`classic`, trait Game).

const std = @import("std");
const og = @import("opengorky");

pub const Doc = og.script.traits.Doc;
pub const Param = og.script.traits.Param;
pub const Callback = og.script.traits.Classic;

const hero: Param = .{ .decl = "string hero", .doc = .{ .en = "the name of the hero who does it (his object, \"Sullivan\")", .ru = "имя героя, который это делает (его объект, \"Sullivan\")" } };

/// An action of the rules' Action table (an area's or item's `action`).
fn action(comptime name: []const u8, comptime func: usize) Callback {
    return .{ .name = name, .params = &.{hero}, .doc = .{
        .en = std.fmt.comptimePrint("The object's action {s} (classic_id {d}, rules Action) chosen by a hero who walked up to it: an area's (world/actions.zig areaOperation) or an item's (inventory/box.zig itemOperation).", .{ name, func }),
        .ru = std.fmt.comptimePrint("Действие объекта {s} (classic_id {d}, rules Action), выбранное героем, подошедшим к нему: у области (world/actions.zig areaOperation) или предмета (inventory/box.zig itemOperation).", .{ name, func }),
    } };
}

/// The exe's callbacks (script/traits.zig `classic`: the docs and the method each becomes).
pub const exe = og.script.traits.classic;

/// The rules' built-in actions as callbacks (all but Explore on a box, which opens its
/// window; an area's Explore is called).
/// shortcut: the built-in Action names only; a project's own actions.ss rows are not
/// listed (upgrade: read rules.actions in force).
pub const actions = blk: {
    const acts = og.rules.builtin.actions;
    var out: [acts.len]Callback = undefined;
    for (acts, &out) |x, *o| o.* = action(x.name, x.classic_id);
    break :blk out;
};

/// Exe callback `name` (case aside: the engine looks names up so).
pub fn find(name: []const u8) ?*const Callback {
    for (&exe) |*c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    for (&actions) |*c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    return null;
}

/// Hook `name` of rules\hooks.ss as a callback (its parameters split, their docs).
pub fn hook(buf: []Param, name: []const u8) ?Callback {
    const h = og.script.traits.hook(name) orelse return null;
    var it = std.mem.splitSequence(u8, h.params, ", ");
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n == buf.len or n == h.param_docs.len) break;
        buf[n] = .{ .decl = p, .doc = h.param_docs[n] };
    }
    return .{ .name = h.name, .params = buf[0..n], .doc = h.when };
}

test "callbacks: every exe callback and hook has its doc and every parameter's, in both languages" {
    for (exe ++ actions) |c| {
        try std.testing.expect(c.doc.en.len > 0 and c.doc.ru.len > 0);
        for (c.params) |p| try std.testing.expect(p.decl.len > 0 and p.doc.en.len > 0 and p.doc.ru.len > 0);
    }
    var buf: [8]Param = undefined;
    for (og.script.traits.hooks()) |h| {
        const c = hook(&buf, h.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(h.arity(), c.params.len);
        try std.testing.expect(c.doc.en.len > 0 and c.doc.ru.len > 0);
        for (c.params) |p| try std.testing.expect(p.doc.en.len > 0 and p.doc.ru.len > 0);
    }
    try std.testing.expectEqualStrings("UseItem", find("useitem").?.name);
    try std.testing.expectEqual(1, find("Take").?.params.len);
}
