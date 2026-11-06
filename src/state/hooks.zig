//! OpenGorky script events of the world, the battle and the game (script/traits.zig:
//! Object, Level, Battle, Area, Item, Anim, Path, Actor, Game) called through
//! script/dispatch.zig on the attached components (`on`). An OpenGorky project's
//! components declared `for game` (its `game.ogs`) are attached, in
//! order, to the world's game object (`w.hooks`, outside the location's objects). Classic
//! attaches no component and has no game object: every call here costs a bit and returns
//! the built-in value.
//!
//! A point both the level (Battle, Level) and the game hear goes through both hosts as
//! one chain, the level first (dispatch.chainHosts): OnDamage, OnResist (each gets the
//! result before it as `amount`), OnTurnStart, OnTurnEnd, OnBattleEnd; OnItemUse is the
//! game's alone (`handled`: the first true result stops there, the built-in use skipped).
//! Objects come as refs, `won` as a bool.
//! A method returning nil (no `return`, `return;`) is as one not defined: no change.
//! A method that faults (an OGS run-time error) is logged and changes nothing.

const std = @import("std");
const World = @import("world.zig").World;
const script = @import("../script.zig");
const Object = script.object.Object;
const Value = script.value.Value;
const rules = @import("../rules.zig");
const traits = script.traits;
const dispatch = script.dispatch;
const schema = @import("../core.zig").schema;
const natives = @import("../core.zig").natives;

/// The game object of `w` with the game components of the project's code (`rules.scripts`:
/// its texts, loaders/ogs.zig; the scripted abilities a battle attaches, combat/events.zig,
/// are among them): all texts parsed, then linked as one program. A text that doesn't parse or link is warned about and left out whole (none of
/// its components attaches).
pub fn load(w: *World) !void {
    if (!rules.og) return;
    w.rt.schema = schema.blockField;
    w.rt.natives_known = natives.components();
    // Parsed first: a level's block in several texts is one (script/ogs/levels.zig).
    const a = w.arena_state.allocator();
    var units: std.ArrayList(script.ogs.parser.Unit) = .empty;
    for (rules.scripts) |t| {
        var pd: script.ogs.parser.Diagnostic = .{};
        const name = try a.dupe(u8, t.name);
        try units.append(a, script.ogs.parser.parse(w.rt.arena(), try a.dupe(u8, t.data), name, &pd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("{s}:{d}: {s} ({t})", .{ name, pd.line, pd.message, err });
                continue;
            },
        });
    }
    if (try script.ogs.levels.merge(w.rt.arena(), units.items)) |x| std.log.warn("{s}:{d}: {s}", .{ x.file, x.line, x.message });
    for (units.items) |u| w.rt.addOgsUnit(u) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.log.warn("{f} ({t})", .{ w.rt.diag, err }),
    };
    // The whole program links at once (a hook may call a function of any text); a text
    // that fails is dropped and the rest link again without it.
    while (true) {
        w.rt.linkOgs() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("{f} ({t})", .{ w.rt.diag, err });
                continue;
            },
        };
        break;
    }
    const cls = try w.rt.arena().create(script.object.Class);
    cls.* = .{ .name = "game", .parent = null };
    const game = try w.rt.createDetached("game", cls);
    for (w.rt.ogs.modules.items) |m| for (m.components) |c| {
        for (c.hosts) |h| {
            if (std.mem.eql(u8, h, "game")) break;
        } else continue;
        _ = w.rt.attach(game, c, &.{}) catch |err| switch (err) {
            error.ScriptFault => std.log.warn("{f}", .{w.rt.fault}),
            else => return err,
        };
    };
    // No game component (the prelude or the abilities' texts alone): no game object.
    if (game.components.items.len > 0) w.hooks = game;
}

/// Built-in method `path` ("Level.OnRestore") on `o`'s components: a world event. The
/// dispatcher goes by the method's name and rule, the same at every trait that has it
/// (`Level.OnUpdate` is also Actor's and Anim's).
pub fn on(w: *World, o: *Object, comptime path: []const u8, args: []Value) !?Value {
    return dispatch.call(&w.rt, o, traits.method(path), args);
}

/// Method `name` on the level's components (Battle's), then on the game's (Game's): one
/// chain through both hosts.
fn levelThenGame(w: *World, comptime name: []const u8, args: []Value) !?Value {
    // Battle's of the name combines as Game's (traits.zig's test).
    const m = traits.method("Game." ++ name);
    var hosts: [2]*Object = undefined;
    var n: usize = 0;
    for ([_]?*Object{ w.level, w.hooks }) |h| if (h) |o| {
        hosts[n] = o;
        n += 1;
    };
    return dispatch.chainHosts(&w.rt, hosts[0..n], m, args);
}

fn ref(o: ?*Object) Value {
    return if (o) |x| x.ref() else .nil;
}

/// OnDamage(attacker, target, weapon, amount): the damage a strike deals.
pub fn damage(w: *World, attacker: *Object, target: *Object, weapon: *Object, amount: i32) !i32 {
    var args = [_]Value{ attacker.ref(), target.ref(), weapon.ref(), .{ .int = amount } };
    const v = try levelThenGame(w, "OnDamage", &args) orelse return amount;
    return v.toInt();
}

/// OnResist(target, kind, amount): damage a target resisting `kind` takes (built-in 0).
pub fn resist(w: *World, target: *Object, kind: []const u8, amount: i32) !i32 {
    var args = [_]Value{ target.ref(), .{ .string = kind }, .{ .int = amount } };
    const v = try levelThenGame(w, "OnResist", &args) orelse return 0;
    return v.toInt();
}

/// OnTurnStart(side, turn): after the fighters' (combat/events.zig turnStart).
pub fn turnStart(w: *World, side: []const u8, turn: i32) !void {
    var args = [_]Value{ .{ .string = side }, .{ .int = turn } };
    _ = try levelThenGame(w, "OnTurnStart", &args);
}

/// OnTurnEnd(side, turn): after the fighters' (combat/events.zig turnEnd).
pub fn turnEnd(w: *World, side: []const u8, turn: i32) !void {
    var args = [_]Value{ .{ .string = side }, .{ .int = turn } };
    _ = try levelThenGame(w, "OnTurnEnd", &args);
}

pub fn battleEnd(w: *World, won: bool) !void {
    var args = [_]Value{.{ .bool = won }};
    _ = try levelThenGame(w, "OnBattleEnd", &args);
}

/// OnItemUse(user, item, target): true when the hook did the use itself. The item's own
/// Item.OnUse(user, target) first (`handled` too), then the game's.
pub fn itemUse(w: *World, user: *Object, item: *Object, target: ?*Object) !bool {
    if (item.implementsC("OnUse")) {
        var own = [_]Value{ user.ref(), ref(target) };
        if (try on(w, item, "Item.OnUse", &own)) |v| if (v.truth()) return true;
    }
    const g = w.hooks orelse return false;
    var args = [_]Value{ user.ref(), item.ref(), ref(target) };
    const v = try dispatch.call(&w.rt, g, traits.method("Game.OnItemUse"), &args) orelse return false;
    return v.truth();
}

/// The party arrived: the level's Level.OnEnter, then Game.OnLevelEnter(level).
pub fn levelEnter(w: *World) !void {
    if (w.level) |l| _ = try on(w, l, "Level.OnEnter", &.{});
    const g = w.hooks orelse return;
    var args = [_]Value{ref(w.level)};
    _ = try dispatch.call(&w.rt, g, traits.method("Game.OnLevelEnter"), &args);
}
