//! Native abilities as built-in components: each set part of a fighter's
//! Abilities row (core/behaviour.zig, the parameter schema) is a component in its
//! `components`, attached as the object is made and living with it, which implements
//! built-in methods (the engine's code: combat/natives.zig) and marks. The battle asks
//! the traits (script/dispatch.zig, `Object.implementsC`) where it read the row, so a
//! scripted ability answers at the same points, after the natives (they come first).
//! The row is the Classic reader's (core/classic.zig) or a project's rules; it is read
//! once, here (modules.abilityRow).

const std = @import("std");
const script = @import("../script.zig");
const Object = script.object.Object;
const Runtime = script.runtime.Runtime;
const Value = script.value.Value;
const traits = script.traits;
const behaviour = @import("behaviour.zig");
const Abilities = behaviour.Abilities;
const modules = @import("modules.zig");

/// The native components, in the Abilities fields' order (their order in `components`).
pub const Kind = enum(u8) {
    double_turn,
    goes_first,
    immobile,
    stand,
    guard,
    open_from,
    arms,
    monitor,
    no_kill_credit,
    pairs,
    heals,
    avenger,
    invisible,
    leaves,
    no_push,
    no_hands,
    battle_only,
};

const Def = struct {
    name: []const u8,
    /// Built-in methods and marks it implements.
    implements: []const []const u8,
};

/// Each kind's component (`Guard(div, min, cone)`: its row's fields).
fn def(k: Kind) Def {
    return switch (k) {
        .double_turn => .{ .name = "DoubleTurn", .implements = &.{"ExtraAction"} },
        .goes_first => .{ .name = "GoesFirst", .implements = &.{"TurnPriority"} },
        .immobile => .{ .name = "Immobile", .implements = &.{"Immobile"} },
        .stand => .{ .name = "Stand", .implements = &.{"StandAngle"} },
        .guard => .{ .name = "Guard", .implements = &.{"GuardDamage"} },
        .open_from => .{ .name = "OpenFrom", .implements = &.{ "CanBeStruck", "OnDodge" } },
        .arms => .{ .name = "Arms", .implements = &.{ "CanUse", "OnMoveEnd" } },
        .monitor => .{ .name = "Monitor", .implements = &.{"Monitor"} },
        .no_kill_credit => .{ .name = "NoKillCredit", .implements = &.{"NoKillCredit"} },
        .pairs => .{ .name = "Pairs", .implements = &.{"DoubleStrike"} },
        .heals => .{ .name = "Heals", .implements = &.{"OnDamageDealt"} },
        .avenger => .{ .name = "Avenger", .implements = &.{"OnDeath"} },
        .invisible => .{ .name = "Invisible", .implements = &.{"StartsUnseen"} },
        .leaves => .{ .name = "Leaves", .implements = &.{"Leaves"} },
        .no_push => .{ .name = "NoPush", .implements = &.{"CanPush"} },
        .no_hands => .{ .name = "NoHands", .implements = &.{"NoHands"} },
        .battle_only => .{ .name = "BattleOnly", .implements = &.{"CanSelect"} },
    };
}

/// Whether row `r` sets kind `k`'s part.
pub fn has(r: *const Abilities, k: Kind) bool {
    return switch (k) {
        .double_turn => r.double_turn,
        .goes_first => r.first_in_mode != 0,
        .immobile => r.immobile,
        .stand => r.stand != null,
        .guard => r.guard != null,
        .open_from => r.open_from != null,
        .arms => r.arms != null,
        .monitor => r.monitor,
        .no_kill_credit => !r.kill_credit,
        .pairs => r.double_strike,
        .heals => r.heals.len > 0,
        .avenger => r.avenger.len > 0,
        .invisible => r.invisible,
        .leaves => r.leaves,
        .no_push => r.no_push,
        .no_hands => r.no_hands,
        .battle_only => r.battle_only,
    };
}

const kinds = std.enums.values(Kind);

/// Each kind's `Object.Class.native` (its name, the bits of what it implements), in
/// `Kind` order (the editor lists them: who implements a trait).
pub fn components() *const [kinds.len]script.object.Native {
    const S = struct {
        var out: ?[kinds.len]script.object.Native = null;
    };
    if (S.out == null) {
        var out: [kinds.len]script.object.Native = undefined;
        for (kinds, &out) |k, *n| {
            var bits: traits.Mask = .empty;
            for (def(k).implements) |m| bits.set(traits.bitOf(m) orelse std.debug.panic("foundation/traits.ogs has no {s} (core/natives.zig)", .{m}));
            n.* = .{ .name = def(k).name, .tag = @backingInt(k), .bits = bits };
        }
        S.out = out;
    }
    return &S.out.?;
}

/// A native component's parameter: an object variable of its instance,
/// set from its part of the Abilities row as it is attached. The engine's code reads it
/// there (combat/natives.zig), so a change to it changes what the native does from then
/// on; the editor lists them (its component page).
pub const Param = struct { name: []const u8, type: script.value.Type, doc: traits.Doc };

/// Kind `k`'s parameters (none: a mark, DoubleTurn, NoPush, BattleOnly).
pub fn params(k: Kind) []const Param {
    return switch (k) {
        .goes_first => &.{.{ .name = "level_mode", .type = .int, .doc = .{ .en = "first in the enemy turn on a level of this mode", .ru = "первым в ходе врагов на уровне с этим mode" } }},
        .stand => &.{
            .{ .name = "angle", .type = .float, .doc = .{ .en = "the angle it stands at, rad", .ru = "угол, под которым стоит, рад" } },
            .{ .name = "after_move", .type = .bool, .doc = .{ .en = "after its own move too", .ru = "и после своего хода" } },
        },
        .guard => &.{
            .{ .name = "div", .type = .int, .doc = .{ .en = "the damage from the front is divided by it", .ru = "урон спереди делится на него" } },
            .{ .name = "min", .type = .int, .doc = .{ .en = "at least this damage", .ru = "урон не меньше" } },
            .{ .name = "cone", .type = .float, .doc = .{ .en = "the front cone from its gaze, rad", .ru = "конус спереди от взгляда, рад" } },
        },
        .open_from => &.{
            .{ .name = "right", .type = .int, .doc = .{ .en = "the tile it is struck from: to its right", .ru = "клетка, с которой по нему попадают: вправо от него" } },
            .{ .name = "ahead", .type = .int, .doc = .{ .en = "that tile: ahead of it", .ru = "та клетка: вперёд от него" } },
            .{ .name = "dodge", .type = .string, .doc = .{ .en = "its dodge animation", .ru = "его анимация уклонения" } },
        },
        .arms => &.{
            .{ .name = "left_right", .type = .int, .doc = .{ .en = "its left arm's tile: to its right", .ru = "клетка левой руки: вправо от него" } },
            .{ .name = "left_ahead", .type = .int, .doc = .{ .en = "its left arm's tile: ahead", .ru = "клетка левой руки: вперёд" } },
            .{ .name = "right_right", .type = .int, .doc = .{ .en = "its right arm's tile: to its right", .ru = "клетка правой руки: вправо от него" } },
            .{ .name = "right_ahead", .type = .int, .doc = .{ .en = "its right arm's tile: ahead", .ru = "клетка правой руки: вперёд" } },
            .{ .name = "blocked", .type = .string, .doc = .{ .en = "its animation when both are blocked", .ru = "анимация, когда обе закрыты" } },
        },
        .pairs => &.{.{ .name = "pairs", .type = .any, .doc = .{ .en = "the weapon pairs by classic_id, [[a, b], …], by its counter", .ru = "пары оружия по classic_id, [[a, b], …], по его счётчику" } }},
        .heals => &.{.{ .name = "who", .type = .string, .doc = .{ .en = "the object name of the fighter it heals", .ru = "имя объекта бойца, которого лечит" } }},
        .avenger => &.{.{ .name = "avenger", .type = .string, .doc = .{ .en = "the object name of the fighter that avenges it", .ru = "имя объекта бойца, который за него мстит" } }},
        else => &.{},
    };
}

/// Kind `k`'s parameter values from row `r`, in `params` order (texts and lists in `a`:
/// the rules may be read again while the world lives).
fn values(a: std.mem.Allocator, k: Kind, r: *const Abilities) std.mem.Allocator.Error![]const Value {
    const str = struct {
        fn f(al: std.mem.Allocator, t: []const u8) std.mem.Allocator.Error!Value {
            return .{ .string = try al.dupe(u8, t) };
        }
    }.f;
    return switch (k) {
        .goes_first => try a.dupe(Value, &.{.{ .int = r.first_in_mode }}),
        .stand => try a.dupe(Value, &.{ .{ .float = r.stand.? }, .{ .bool = r.stand_after_move } }),
        .guard => try a.dupe(Value, &.{ .{ .int = r.guard.?.div }, .{ .int = r.guard.?.min }, .{ .float = r.guard.?.cone } }),
        .open_from => try a.dupe(Value, &.{ .{ .int = r.open_from.?[0] }, .{ .int = r.open_from.?[1] }, try str(a, r.dodge) }),
        .arms => try a.dupe(Value, &.{ .{ .int = r.arms.?.left[0] }, .{ .int = r.arms.?.left[1] }, .{ .int = r.arms.?.right[0] }, .{ .int = r.arms.?.right[1] }, try str(a, r.arms.?.blocked) }),
        .pairs => blk: {
            const list = try a.alloc(Value, r.pairs.len);
            for (r.pairs, list, 0..) |p, *v, pi| {
                var ids = p;
                for (&ids, 0..) |*id, j| if (2 * pi + j < r.pairs_class.len and r.pairs_class[2 * pi + j].len > 0) {
                    id.* = @import("entity.zig").idOf(r.pairs_class[2 * pi + j]) orelse -1;
                };
                v.* = .{ .list = try a.dupe(Value, &.{ .{ .int = ids[0] }, .{ .int = ids[1] } }) };
            }
            break :blk try a.dupe(Value, &.{.{ .list = list }});
        },
        .heals => try a.dupe(Value, &.{try str(a, r.heals)}),
        .avenger => try a.dupe(Value, &.{try str(a, r.avenger)}),
        else => &.{},
    };
}

/// Fighter `o`'s native components attached from its row (modules.abilityRow), in
/// `Kind` order, unless it has them already (made, or entered a battle before); each
/// with its parameters as its instance's variables (`params`).
pub fn attach(rt: *Runtime, o: *Object) std.mem.Allocator.Error!void {
    for (o.components.items) |c| if (c.class.native != null) return;
    const r = modules.abilityRow(o);
    for (kinds, components()) |k, *n| if (has(r, k)) {
        const inst = try rt.attachNative(o, n, null);
        for (params(k), try values(rt.arena(), k, r)) |p, v| try inst.declare(rt.arena(), p.name, .{ .type = p.type, .value = v });
    };
}

/// Actor `o`'s native components read again from its row (the rules were read again,
/// or its class, classic_id or fields changed): the old ones go, the new ones come first and
/// its scripted and data's components stay after them, in their order.
pub fn reattach(rt: *Runtime, o: *Object) std.mem.Allocator.Error!void {
    const rest = try rt.arena().alloc(*Object, o.components.items.len);
    var k: usize = 0;
    for (o.components.items) |c| if (c.class.native == null) {
        rest[k] = c;
        k += 1;
    };
    o.components.clearRetainingCapacity();
    try attach(rt, o);
    try o.components.appendSlice(rt.arena(), rest[0..k]);
    o.refreshImplements();
}

/// `o`'s native component instance of kind `k` (its parameters are its variables), null:
/// it has none.
pub fn find(o: *const Object, k: Kind) ?*Object {
    for (o.components.items) |c| if (c.class.native) |n| if (n.tag == @backingInt(k)) return c;
    return null;
}

/// The kind of a native component's `tag` (`Object.Class.native`).
pub fn kindOf(tag: u8) Kind {
    return @fromBackingInt(@intCast(tag));
}

test "natives: each kind is one component with a bit per method or mark" {
    for (components()) |n| try std.testing.expect(n.bits.count() > 0);
}

test "natives: each kind's params have a value from a row setting it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = behaviour.plain;
    r.stand = 1.5;
    r.guard = .{ .div = 2, .min = 1, .cone = 0.5 };
    r.open_from = .{ 0, 1 };
    r.arms = .{ .left = .{ -1, 1 }, .right = .{ 1, 1 }, .blocked = "atakB" };
    r.pairs = &.{.{ 1077, 1078 }};
    for (kinds) |k| {
        const vs = try values(arena.allocator(), k, &r);
        try std.testing.expectEqual(params(k).len, vs.len);
        for (params(k)) |p| try std.testing.expect(p.doc.en.len > 0 and p.doc.ru.len > 0);
    }
    try std.testing.expectEqual(@as(f32, 0.5), (try values(arena.allocator(), .guard, &r))[2].float);
    try std.testing.expectEqual(1078, (try values(arena.allocator(), .pairs, &r))[0].list[0].list[1].int);
}
