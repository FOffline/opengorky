//! A fighter's events at the battle's points (trait Fighter, script/traits.zig) and the
//! battle's variables. OpenGorky: the scripted abilities of a fighter's Abilities
//! row (`scripts`: OGS components `for fighter` of the rules' code, state/hooks.zig loads
//! them) are attached to it as it enters the battle, anew for each battle (`scope`
//! battle: the natives and the data's attachments stay), and the battle
//! calls their handlers through script/dispatch.zig where the event happens: OnSpawn at
//! the entry (roster.addNewcomers), OnTurnStart / OnTurnEnd at each side's turn (every
//! live fighter hears both sides'), OnStrike then OnHit in the damage chain right before
//! the game hooks' OnDamage (strike.hitVictim), OnDeath and the side's OnAllyDeath at a
//! death (strike.hurt; CanDie before it, as the health would reach 0), OnVar at a battle
//! variable's change; CanWalk at each side's turn
//! start (its answer holds for that turn: `Fighter.stuck`), CanBeStruck where a strike
//! asks it (strike.closedTo). Classic attaches only the native components (core/natives.zig,
//! as the object is made): they come first in the list, so a scripted ability's handler
//! sees a death after the Grandma child's Avenger; the damage after the Puppet's Guard
//! (strike.hitVictim) and before the game hooks.

const std = @import("std");
const script = @import("../script.zig");
const Object = script.object.Object;
const Value = script.value.Value;
const traits = script.traits;
const dispatch = script.dispatch;
const battle_mod = @import("../battle.zig").battle;
const Battle = battle_mod.Battle;
const Fighter = @import("../battle.zig").fighter.Fighter;
const Side = @import("../battle.zig").fighter.Side;
const grid = @import("../battle.zig").grid;
const World = @import("../state.zig").world.World;
const rules = @import("../rules.zig");
const core = @import("../core.zig");
const party = @import("../world.zig").party;

/// Fighters `first..` (just entered): their scripted abilities attached in their row's
/// order (a param given converted to its declared type; a `fighter`/`object` param from
/// an object name to that object, nil when there is none; a `for Hero`/`for Enemy` one
/// active only while the fighter has the role), the battle's roles granted, then OnSpawn
/// for each.
pub fn spawn(self: *Battle, w: *World, first: usize) !void {
    if (rules.og) for (self.fighters.items[first..]) |f| try attachScripts(self, w, f.obj, false);
    // Their roles before OnSpawn: a `for Enemy` component hears OnRoleGained.
    try party.syncRolesIn(w, self);
    if (!rules.og) return;
    for (self.fighters.items[first..]) |f| _ = try dispatch.call(&w.rt, f.obj, ev("OnSpawn"), &.{});
}

/// OpenGorky: the scripted abilities of fighter `o`'s Abilities row attached; the last
/// battle's go, natives and the data's stay. `morphed` (after a
/// transformation, combat/states.zig morphDone): only the former class's that the new row
/// lacks go; one in both rows stays as it is (its state: Phoenix's phase), the rest come.
pub fn attachScripts(self: *Battle, w: *World, o: *Object, morphed: bool) !void {
    const row = core.modules.abilityRow(o).scripts;
    var k: usize = 0;
    for (o.components.items) |c| if (c.scope != .battle or (morphed and for (row) |s| {
        if (std.mem.eql(u8, s.component, c.name)) break true;
    } else false)) {
        o.components.items[k] = c;
        k += 1;
    };
    o.components.shrinkRetainingCapacity(k);
    o.refreshImplements();
    for (row) |s| if (!hasBattle(o, s.component)) try attach(self, w, o, s);
    // Its AI scoring's component (AiScoring `script`: its ScoreTile).
    const enemy = if (self.fighterOf(o)) |i| self.fighters.items[i].side == .enemy else false;
    const sc = core.modules.aiScoring(@import("../battle.zig").generic.aiProfile(o, enemy).scoring orelse "generic").script;
    if (sc.len > 0 and !hasBattle(o, sc)) try attach(self, w, o, .{ .component = sc });
}

fn hasBattle(o: *Object, name: []const u8) bool {
    for (o.components.items) |c| if (c.scope == .battle and std.mem.eql(u8, c.name, name)) return true;
    return false;
}

fn attach(self: *Battle, w: *World, o: *Object, s: core.behaviour.Script) !void {
    const comp = try w.rt.ogs.component(w.rt.arena(), null, s.component) orelse {
        battle_mod.note(self, "  {s}: no component {s}", .{ o.name, s.component });
        return;
    };
    const hosts_fighter = comp.hosts.len == 0 or for (comp.hosts) |h| {
        if (std.mem.eql(u8, h, "fighter") or traits.Role.of(h) != null) break true;
    } else false;
    if (!hosts_fighter) return battle_mod.note(self, "  {s}: {s} is not for fighter", .{ o.name, s.component });
    var params: [16]script.runtime.Runtime.NamedValue = undefined;
    const n = @min(s.params.len, params.len);
    for (s.params[0..n], params[0..n]) |p, *out| {
        var v: Value = switch (p.value) {
            .int => |x| .{ .int = x },
            .float => |x| .{ .float = x },
            .bool => |x| .{ .bool = x },
            .string => |x| .{ .string = x },
        };
        for (w.rt.ogs.fieldsOf(comp)) |fd| if (std.mem.eql(u8, fd.name, p.name) and v == .string and isRef(fd.type_name)) {
            v = if (w.rt.findObject(v.string)) |x| x.ref() else .nil;
        };
        out.* = .{ .name = p.name, .value = v };
    }
    const inst = w.rt.attach(o, comp, params[0..n]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return std.log.warn("{s}:{d}: {s} ({s} on {s})", .{ w.rt.fault.file, w.rt.fault.line, w.rt.fault.message, s.component, o.name }),
    };
    inst.scope = .battle;
}

/// A param type that refers to an object.
fn isRef(t: []const u8) bool {
    for ([_][]const u8{ "fighter", "object", "item", "weapon" }) |k| if (std.mem.eql(u8, t, k)) return true;
    return false;
}

/// Fighter event `name` (comptime-checked against the table).
fn ev(comptime name: []const u8) *const traits.Method {
    return traits.method("Fighter." ++ name);
}

fn sideName(s: Side) []const u8 {
    return switch (s) {
        .hero => "hero",
        .enemy => "enemy",
        .neutral => "neutral",
        .civilian => "civilian",
    };
}

/// Side `side`'s turn begins: OnTurnStart(side, turn) for every live fighter, then CanWalk
/// (its answer for this turn: `stuck`) and WalkRange (`walk_range`). Before the turn's reset (turns.resetTurn reads it).
pub fn turnStart(self: *Battle, w: *World, side: Side) !void {
    for (self.fighters.items) |*f| {
        if (f.side == .neutral or !f.alive() or !f.obj.implementsC("OnTurnStart")) continue;
        var args = [_]Value{ .{ .string = sideName(side) }, .{ .int = self.turn } };
        _ = try dispatch.call(&w.rt, f.obj, ev("OnTurnStart"), &args);
    }
    for (self.fighters.items) |*f| {
        if (!f.obj.implementsC("CanWalk")) continue;
        const v = try dispatch.call(&w.rt, f.obj, ev("CanWalk"), &.{});
        f.stuck = v != null and !v.?.truth();
        if (f.stuck) battle_mod.note(self, "  {s}: CanWalk false", .{f.obj.name});
    }
    // WalkRange(range): its walk range this turn (Fighter.walk_range; nobody: walk_range).
    for (self.fighters.items) |*f| {
        f.walk_range = null;
        if (!f.obj.implementsC("WalkRange")) continue;
        const own = f.walkRange();
        const v = try chain(self, w, f.obj, "Fighter.WalkRange", .{Value{ .int = own }});
        if (v != own) f.walk_range = v;
    }
}

/// Side `side`'s turn ends: OnTurnEnd(side, turn) for every live fighter.
pub fn turnEnd(self: *Battle, w: *World, side: Side) !void {
    for (self.fighters.items) |*f| {
        if (f.side == .neutral or !f.alive() or !f.obj.implementsC("OnTurnEnd")) continue;
        var args = [_]Value{ .{ .string = sideName(side) }, .{ .int = self.turn } };
        _ = try dispatch.call(&w.rt, f.obj, ev("OnTurnEnd"), &args);
    }
}

/// The damage `d` fighter `who` deals `v` with `wpn` after the attacker's OnStrike and the
/// target's OnHit (each chained through its components); noted when it changed.
pub fn hit(self: *Battle, w: *World, who: u16, v: u16, wpn: *Object, d: i32) !i32 {
    const a = self.fighters.items[who].obj;
    const t = self.fighters.items[v].obj;
    if (!a.implementsC("OnStrike") and !t.implementsC("OnHit")) return d;
    var sa = [_]Value{ t.ref(), wpn.ref(), .{ .int = d } };
    const s = if (try dispatch.call(&w.rt, a, ev("OnStrike"), &sa)) |x| x.toInt() else d;
    var ha = [_]Value{ a.ref(), wpn.ref(), .{ .int = s } };
    const h = if (try dispatch.call(&w.rt, t, ev("OnHit"), &ha)) |x| x.toInt() else s;
    if (s != d) battle_mod.note(self, "  OnStrike {s} -> {s}: {d} -> {d}", .{ a.name, t.name, d, s });
    if (h != s) battle_mod.note(self, "  OnHit {s} <- {s}: {d} -> {d}", .{ t.name, a.name, s, h });
    return h;
}

/// Chain method `path` ("Fighter.Armor") of `o` with `args` (a tuple of values, the
/// engine's int last): the answer as an int, the engine's when none answers; a change
/// noted (`  Armor kid: 0 -> 2`). The caller checks `o`'s bit before making `args`.
pub fn chain(self: *Battle, w: *World, o: *Object, comptime path: []const u8, args: anytype) !i32 {
    const m = traits.method(path);
    std.debug.assert(m.combine == .chain);
    var a: [args.len]Value = args;
    const was = a[a.len - 1].int;
    const v = (try dispatch.call(&w.rt, o, m, &a) orelse return was).toInt();
    if (v != was) battle_mod.note(self, "  {s} {s}: {d} -> {d}", .{ m.name, o.name, was, v });
    return v;
}

/// Method `path` of `o` with `args` (a tuple of values; `all`: its result unused). The
/// caller checks `o`'s bit before making `args`.
pub fn tell(w: *World, o: *Object, comptime path: []const u8, args: anytype) !void {
    var a: [args.len]Value = args;
    _ = try dispatch.call(&w.rt, o, traits.method(path), &a);
}

/// Fighter `v` died: its OnDeath(killer: its last attacker or nil), then OnAllyDeath(dead,
/// killer) of every live fighter of its side.
pub fn death(self: *Battle, w: *World, v: u16) !void {
    const t = self.fighters.items[v];
    const killer: Value = if (t.last_attacker) |k| self.fighters.items[k].obj.ref() else .nil;
    var args = [_]Value{killer};
    _ = try dispatch.call(&w.rt, t.obj, ev("OnDeath"), &args);
    for (self.fighters.items, 0..) |g, i| {
        if (i == v or g.side != t.side or !g.alive() or !g.obj.implementsC("OnAllyDeath")) continue;
        var aa = [_]Value{ t.obj.ref(), killer };
        _ = try dispatch.call(&w.rt, g.obj, ev("OnAllyDeath"), &aa);
    }
}

/// CanDie(killer: its last attacker or nil) of fighter `v`, as a blow would bring its
/// health to 0 (strike.hurt): false keeps it alive (noted); nil or true: it dies. The caller
/// checks its bit.
pub fn canDie(self: *Battle, w: *World, v: u16) !bool {
    const t = self.fighters.items[v];
    var args = [_]Value{if (t.last_attacker) |k| self.fighters.items[k].obj.ref() else .nil};
    const ans = try dispatch.call(&w.rt, t.obj, ev("CanDie"), &args) orelse return true;
    if (ans.truth()) return true;
    battle_mod.note(self, "  {s}: CanDie false", .{t.obj.name});
    return false;
}

/// Tile `t` as the scripts' `[x, y]`: the battle's one list per tile (the AI asks CanAim and
/// CanBeStruck thousands of times a plan), a new one off the grid or out of a battle.
pub fn tileList(w: *World, t: grid.Tile) error{OutOfMemory}![]const Value {
    const b = if (w.battle) |*b| b else return w.rt.strings().dupe(Value, &t2v(t));
    if (t[0] < 0 or t[1] < 0 or t[0] >= b.width or t[1] >= b.height) return w.rt.strings().dupe(Value, &t2v(t));
    if (b.tile_lists.len == 0) {
        const l = try w.rt.strings().alloc([2]Value, b.width * b.height);
        for (l, 0..) |*e, i| e.* = t2v(.{ @intCast(i % b.width), @intCast(i / b.width) });
        b.tile_lists = l;
    }
    return &b.tile_lists[@as(usize, @intCast(t[1])) * b.width + @as(usize, @intCast(t[0]))];
}

fn t2v(t: grid.Tile) [2]Value {
    return .{ .{ .int = t[0] }, .{ .int = t[1] } };
}

/// CanBeStruck(from_tile [x, y]) of `f`'s components: false when one says it can't be hit
/// from `tile` (null: none answers).
pub fn struckFrom(w: *World, f: Fighter, tile: grid.Tile) ?bool {
    if (!f.obj.implementsC("CanBeStruck")) return null;
    // shortcut: out of memory for the two-number list reads as "no answer" (the caller is
    // no error path: the AI's aiming); upgrade if this ever allocates more.
    const xy = tileList(w, tile) catch return null;
    var args = [_]Value{.{ .list = xy }};
    const v = (dispatch.call(&w.rt, f.obj, ev("CanBeStruck"), &args) catch return null) orelse return null;
    return v.truth();
}

// ---------------------------------------------------------------- the battle's variables

/// Battle variable `name` made `v` (a string kept by the runtime), then OnVar(name, v) for
/// every live fighter in the roster's order.
pub fn setVar(self: *Battle, w: *World, name: []const u8, v: Value) !void {
    const gop = try self.vars.getOrPut(self.gpa, name);
    if (!gop.found_existing) gop.key_ptr.* = try w.rt.arena().dupe(u8, name);
    gop.value_ptr.* = try v.dupe(w.rt.strings());
    battle_mod.note(self, "  var {s} = {f}", .{ name, v });
    for (self.fighters.items) |f| {
        if (f.side == .neutral or !f.alive() or !f.obj.implementsC("OnVar")) continue;
        var args = [_]Value{ .{ .string = gop.key_ptr.* }, v };
        _ = try dispatch.call(&w.rt, f.obj, ev("OnVar"), &args);
    }
    // Then the battle's (its level's components).
    const l = w.level orelse return;
    var args = [_]Value{ .{ .string = gop.key_ptr.* }, v };
    _ = try dispatch.call(&w.rt, l, traits.method("Battle.OnVar"), &args);
}

pub fn getVar(self: *const Battle, name: []const u8) Value {
    return self.vars.get(name) orelse .nil;
}

// ---------------------------------------------------------------- the builtins' battle side

/// Fighter index of `v` (an object or its name) in battle `self`.
pub fn fighterOf(self: *Battle, w: *World, v: Value) ?u16 {
    const o = switch (v) {
        .ref => |h| Object.of(h),
        .string => |s| w.rt.findObject(s) orelse return null,
        else => return null,
    };
    return self.fighterOf(o);
}

/// Fighter `f` given state `state` for `turns` turns (rage: actions); false: no such state.
/// shortcut: the counter only (no stance, sound or popup of the weapon effect: states.zig
/// applyEffect); upgrade when a script needs the effect's look.
pub fn addState(self: *Battle, f: *Fighter, state: []const u8, turns: i32) bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(state, "sleep")) f.asleep = turns else if (eq(state, "freeze")) f.frozen = turns else if (eq(state, "burn")) {
        f.burning = turns;
    } else if (eq(state, "gas")) f.gassed = turns else if (eq(state, "soak")) f.soaked = turns else if (eq(state, "rage")) {
        f.berserk = turns;
    } else if (eq(state, "defend")) f.defending = turns > 0 else return false;
    battle_mod.note(self, "  {s}: {s} {d}", .{ f.obj.name, state, turns });
    return true;
}

/// A fighter's computed fields for OGS (`host.side`, `alive`, `tile`; Runtime.host_fields).
pub fn hostField(w: *World, o: *Object, name: []const u8) ?Value {
    const b = if (w.battle) |*x| x else return null;
    const f = b.fighters.items[b.fighterOf(o) orelse return null];
    if (std.mem.eql(u8, name, "side")) return .{ .string = sideName(f.side) };
    if (std.mem.eql(u8, name, "alive")) return .{ .bool = f.alive() };
    if (std.mem.eql(u8, name, "tile")) return .{ .list = tileList(w, f.tile) catch return null };
    if (std.mem.eql(u8, name, "asleep")) return .{ .bool = f.asleep > 0 };
    // Its second activation this turn (Abilities double_turn).
    if (std.mem.eql(u8, name, "second_turn")) return .{ .bool = f.second };
    // The fighter it avenges (Abilities avenger: Grandma's child's killer), else nil.
    if (std.mem.eql(u8, name, "avenging")) return if (f.grandma_target) |t| b.fighters.items[t].obj.ref() else .nil;
    return null;
}
