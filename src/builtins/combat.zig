//! Script builtins: combat (AI*, Fighter*, PlaceCombatActor, bombs).

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const turns = @import("../combat.zig").turns;
const runtime = @import("../script.zig").runtime;
const rules = @import("../battle.zig").rules;
const grid = @import("../battle.zig").grid;
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const Value = @import("../script.zig").value.Value;
const args_mod = @import("args.zig");
const hooks = @import("../state.zig").hooks;

/// PlaceCombatActor(name, x, y, angle°) (0x4bf240): a battle prop (machine gun,
/// log) at a fractional grid tile, not snapped to the tile centre (0x497a80).
pub fn biPlaceCombatActor(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (World.nativeOf(o).kind != .actor or args.len < 4) return .zero;
    const cm = w.map.combat orelse return .zero;
    const wp = cm.toWorld(args[1].toFloat(), args[2].toFloat());
    fields.setPos(o, .{ wp[0], wp[1], cm.center[2] });
    fields.setAngle(o, args[3].toFloat() * std.math.pi / 180.0);
    world.actorOf(o).placed = true;
    return .{ .int = 1 };
}

/// AIFreeTile(x, y) (0x4bed00): tile inside the grid, open and unoccupied.
pub fn biAIFreeTile(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const b = &(w.battle orelse return .zero);
    if (args.len < 2) return .zero;
    const t: [2]i32 = .{ args[0].toInt(), args[1].toInt() };
    const g = b.grid();
    return .{ .int = @intFromBool(g.open(t) and g.at(t) == grid.Grid.none) };
}

/// PutLargeTimeBomb(x, y) (0x4bea30 → 0x4bda10/0x4bdf70): its Device row's bomb fighter
/// (the exe's `TimeBombLarge<N>` of `ft_time_bomb_large.ss`) on a free tile; after its
/// timer (6 enemy turns) it explodes and everyone dies (museum battle behind the red card).
pub fn biPutLargeTimeBomb(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const cm = w.map.combat orelse return .zero;
    if (args.len < 2) return .zero;
    const x = args[0].toInt();
    const y = args[1].toInt();
    if (x < 0 or y < 0 or x >= cm.width or y >= cm.height) return .zero;
    const d = @import("../core.zig").modules.device(.large_bomb) orelse return .zero;
    w.bombs_placed += 1;
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "{s}{d}", .{ d.prefix, w.bombs_placed });
    const nat: @import("../state.zig").object.Native = .{ .kind = .actor, .fight = .{ .bomb_timer = d.timer } };
    // An OpenGorky project: the archetype block named by it, its creation events as events.
    const og = w.block_item != null;
    const o = if (og) try @import("../inventory.zig").create.objectOf(w, name, d.archetype, nat) orelse return .zero else try w.addObject(name, try rt.loadClass(d.archetype), nat);
    const n = World.nativeOf(o);
    _ = try rt.callIfExists(o, "init", &.{});
    if (og) _ = try hooks.on(w, o, "Object.OnCreate", &.{});
    _ = try rt.callIfExists(o, "post_init", &.{});
    if (og) _ = try hooks.on(w, o, "Actor.OnStart", &.{});
    const wp = cm.toWorld(num.toF32(x) + 0.5, num.toF32(y) + 0.5);
    fields.setPos(o, .{ wp[0], wp[1], cm.center[2] });
    n.actor.placed = true;
    n.actor.pickIdle(w.crt());
    return .{ .int = 1 };
}

/// AIEnemyAppear(name, x0, y0, x1, y1) (0x4bebe0): the enemy stands at (x0, y0)
/// (often outside the grid) and walks to (x1, y1) at battle start.
pub fn biAIEnemyAppear(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world.isActor(o) or args.len < 5) return .zero;
    // 0x4bebe0: the actor is placed at once at the centre of (x0, y0), adjusted for size.
    if (args_mod.worldOf(ctx).map.combat) |cm| {
        const cs = fields.charSize(o);
        const size: u32 = if (cs >= 9) 3 else if (cs >= 4) 2 else 1;
        const p = cm.tileCenter(.{ args[1].toInt(), args[2].toInt() }, size);
        fields.setPos(o, p);
        world.actorOf(o).placed = true;
    }
    World.nativeOf(o).fight.appear = .{
        .from = .{ args[1].toInt(), args[2].toInt() },
        .to = .{ args[3].toInt(), args[4].toInt() },
    };
    return .zero;
}

pub fn biFighterGetHp(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    return .{ .int = fields.hp(o) };
}

/// FighterSetHp("fighter", hp) (0x4be8e0): integer hp only, no upper clamp. OpenGorky: an
/// OGS call in a battle is noted in its log (a Classic one not: its logs stay the exe's).
pub fn biFighterSetHp(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (args.len > 1 and args[1] == .int) {
        fields.setHp(o, args[1].int);
        if (rt.ogs_call) if (battleOf(ctx)) |b| @import("../battle.zig").battle.note(b, "  {s}: hp set {d}", .{ o.name, args[1].int });
    }
    return .zero;
}

/// FighterSetLevel(name, level) (0x4be930): level, and exp = that level's
/// threshold (0x48f9c0). Heroes who join come at level five.
pub fn biFighterSetLevel(_: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args.len < 2) return .zero;
    const o = rt.findObject(args_mod.argString(args, 0)) orelse return .zero;
    const level = args[1].toInt();
    fields.setExperience(o, rules.levelThreshold(level));
    o.setInt("level", level);
    return .zero;
}

/// HERO_EnableEnumerate(name, on) (0x4c1970): a hero from the global list joins
/// or leaves the party (`avoidEnumerate` = !on). Slavsky after the stun grenade,
/// McFadden in the sewers; BT and Medusa leaving.
pub fn biHeroEnableEnumerate(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = rt.findObject(args_mod.argString(args, 0)) orelse return .zero;
    const n = World.nativeOf(o);
    if (!n.hro or args.len < 2) return .zero;
    const on = args[1].toInt() != 0;
    o.setInt("outside_party", @intFromBool(!on));
    n.hero = on;
    try @import("../world.zig").party.syncRoles(args_mod.worldOf(ctx));
    return .zero;
}

/// GUI_IsHero(name): hero is in the party (on the panel).
pub fn biGuiIsHero(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.worldOf(ctx).actorObject(args_mod.argString(args, 0)) orelse return .zero;
    return .{ .int = @intFromBool(World.nativeOf(o).hero and o.enabled) };
}

/// AITargetLock(fighter, target) (0x4beae0): strike only this target (aiMode 1).
pub fn biAITargetLock(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world.isActor(o)) return .zero;
    World.nativeOf(o).fight.target_lock = try rt.arena().dupe(u8, args_mod.argString(args, 1));
    o.setInt("ai_mode", 1);
    return .zero;
}

/// AIGuardPoint(fighter, x, y) (0x4beb60): hold the tile (aiMode 3).
pub fn biAIGuardPoint(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world.isActor(o) or args.len < 3) return .zero;
    World.nativeOf(o).fight.guard_point = .{ args[1].toInt(), args[2].toInt() };
    o.setInt("ai_mode", 3);
    return .zero;
}

pub fn biAIGetTurnNo(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    return .{ .int = if (w.battle) |b| b.turn else 0 };
}

/// BattleNearest(tile, side): the live fighter of `side` ("hero", "enemy"…) nearest to
/// tile [x, y] (dx² + dy²; the first in battle order of a tie), nil: none.
pub fn biBattleNearest(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const b = if (w.battle) |*x| x else return .nil;
    if (args.len < 2 or args[0] != .list or args[0].list.len < 2) return .nil;
    const tx = args[0].list[0].toInt();
    const ty = args[0].list[1].toInt();
    const side = args_mod.argString(args, 1);
    var best: ?*Object = null;
    var dmin: i64 = std.math.maxInt(i64);
    for (b.fighters.items) |f| if (f.alive() and std.ascii.eqlIgnoreCase(@tagName(f.side), side)) {
        const dx: i64 = f.tile[0] - tx;
        const dy: i64 = f.tile[1] - ty;
        if (dx * dx + dy * dy < dmin) {
            dmin = dx * dx + dy * dy;
            best = f.obj;
        }
    };
    return if (best) |o| o.ref() else .nil;
}

/// EndTurnGlobal() (0x4bea10 → 0x45b490): ends the side's turn.
pub fn biEndTurnGlobal(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (w.battle) |*b| try turns.requestEndTurn(b, w);
    return .zero;
}

// ---------------------------------------------------------------- OpenGorky: scripted abilities

// The battle builtins of a fighter's scripted abilities (combat/events.zig): OpenGorky only (the exe has none), a fighter as an object (`host`,
// an event's argument) or its name; outside a battle they do nothing (0, nil, "").

const events = @import("../combat.zig").events;
const Battle = @import("../battle.zig").battle.Battle;

fn battleOf(ctx: *anyopaque) ?*Battle {
    const w = args_mod.worldOf(ctx);
    return if (w.battle) |*b| b else null;
}

fn fighterArg(ctx: *anyopaque, args: []const Value, i: usize) ?u16 {
    if (i >= args.len) return null;
    return events.fighterOf(battleOf(ctx) orelse return null, args_mod.worldOf(ctx), args[i]);
}

/// FighterDamage(who, amount, kind = "", from = nil): `amount` damage to `who` now, on
/// behalf of `from` (its killer if it dies), no OnHit.
pub fn biFighterDamage(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    const v = fighterArg(ctx, args, 0) orelse return .zero;
    if (args.len < 2) return .zero;
    try @import("../combat.zig").scriptDamage(b, args_mod.worldOf(ctx), v, args[1].toInt(), args_mod.argString(args, 2), fighterArg(ctx, args, 3));
    return .{ .int = 1 };
}

/// FighterSetTarget(who, target): `who`'s AI strikes `target` above all (as an avenger's
/// Grandma: her target, +0x24af8; another scoring weighs it as AITargetLock's).
pub fn biFighterSetTarget(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    const v = fighterArg(ctx, args, 0) orelse return .zero;
    b.fighters.items[v].grandma_target = fighterArg(ctx, args, 1);
    @import("../battle.zig").battle.note(b, "  {s}: target {s}", .{ b.fighters.items[v].obj.name, if (b.fighters.items[v].grandma_target) |t| b.fighters.items[t].obj.name else "-" });
    return .{ .int = 1 };
}

/// FighterGetLastAttacker(who): the fighter that hit it last, or nil.
pub fn biFighterGetLastAttacker(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .nil;
    const v = fighterArg(ctx, args, 0) orelse return .nil;
    return if (b.fighters.items[v].last_attacker) |k| b.fighters.items[k].obj.ref() else .nil;
}

/// FighterNative(who, name): fighter `who`'s native component `name` ("Guard"), its
/// params its variables (core/natives.zig `params`: `.div = 4` changes its defence from
/// then on), or nil. In and out of battle: the natives live with the object.
pub fn biFighterNative(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args.len < 2) return .nil;
    const o = args_mod.targetObject(ctx, rt, args) orelse return .nil;
    const name = args_mod.argString(args, 1);
    for (o.components.items) |c| if (c.class.native) |n| if (std.mem.eql(u8, n.name, name)) return c.ref();
    return .nil;
}

/// FighterAddState(who, state, turns = 1): "sleep", "freeze", "burn", "gas", "soak",
/// "defend" for `turns` turns, "rage" for `turns` actions; 0: no such state.
pub fn biFighterAddState(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    const v = fighterArg(ctx, args, 0) orelse return .zero;
    const turns_n = if (args.len > 2) args[2].toInt() else 1;
    return .{ .int = @intFromBool(events.addState(b, &b.fighters.items[v], args_mod.argString(args, 1), turns_n)) };
}

/// FighterSide(who): "hero", "enemy", "neutral" (an obstacle), "civilian", "" (not fighting).
pub fn biFighterSide(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = args_mod.targetObject(ctx, rt, args) orelse return .{ .string = "" };
    return events.hostField(w, o, "side") orelse .{ .string = "" };
}

/// FighterAlive(who): 1 while it fights on.
pub fn biFighterAlive(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    const v = fighterArg(ctx, args, 0) orelse return .zero;
    return .{ .int = @intFromBool(b.fighters.items[v].alive()) };
}

/// FighterPopup(who, text): `text` rising over the fighter (as "Miss").
pub fn biFighterPopup(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    const v = fighterArg(ctx, args, 0) orelse return .zero;
    try @import("../battle.zig").battle.popup(b, b.fighters.items[v], args_mod.argString(args, 1), .info);
    return .{ .int = 1 };
}

/// BattleGetVar(name): the battle variable, nil when unset.
pub fn biBattleGetVar(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .nil;
    return events.getVar(b, args_mod.argString(args, 0));
}

/// BattleSetVar(name, value): sets it; every fighter's OnVar(name, value).
pub fn biBattleSetVar(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    if (args.len < 2) return .zero;
    try events.setVar(b, args_mod.worldOf(ctx), args_mod.argString(args, 0), args[1]);
    return args[1];
}

/// BattleAddVar(name, delta): the variable (unset: 0) plus `delta`, set as BattleSetVar.
pub fn biBattleAddVar(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    if (args.len < 2) return .zero;
    const name = args_mod.argString(args, 0);
    const cur = events.getVar(b, name);
    const sum = @import("../script.zig").value.binary(.add, if (cur == .nil) .zero else cur, args[1]);
    try events.setVar(b, args_mod.worldOf(ctx), name, sum);
    return sum;
}

/// Subscribe(event, handler): the calling component instance's method `handler` hears
/// `event` (Runtime.subscribe, og-script.md §14.1); false: it already did.
pub fn biSubscribe(_: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const inst = rt.caller orelse return error.NotInComponent;
    return .{ .int = @intFromBool(try rt.subscribe(inst, args_mod.argString(args, 0), args_mod.argString(args, 1))) };
}

/// Unsubscribe(event, handler = all): the calling instance's subscriptions taken back; how many.
pub fn biUnsubscribe(_: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const inst = rt.caller orelse return error.NotInComponent;
    return .{ .int = @intCast(rt.unsubscribe(inst, args_mod.argString(args, 0), if (args.len > 1) args_mod.argString(args, 1) else null)) };
}

/// Emit(event, args...): every subscriber's handler called with `args` (Runtime.emit); how
/// many. In battle the log gets `emit event n=<handlers>`.
pub fn biEmit(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const event = args_mod.argString(args, 0);
    const n = try rt.emit(event, if (args.len > 1) args[1..] else &.{});
    if (battleOf(ctx)) |b| @import("../battle.zig").battle.note(b, "  emit {s} n={d}", .{ event, n });
    return .{ .int = @intCast(n) };
}

/// BattleSpawnEnemy(fighter, x, y): a new fighter at tile (x, y), its top left, on the
/// enemies' side (combat/debug.zig spawnFile: `fighter` a class key `ft_x` or a `.ftr` file;
/// its natives, scripted abilities and OnSpawn as any newcomer's). Its object name; nil: no
/// battle, no such fighter, the tile out of the grid or taken.
pub fn biBattleSpawnEnemy(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return spawnOn(ctx, args, .enemy, false);
}

/// BattleSpawnHero(fighter, x, y): as BattleSpawnEnemy, on the heroes' side, the player's.
pub fn biBattleSpawnHero(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return spawnOn(ctx, args, .hero, false);
}

/// BattleSpawnCivilian(fighter, x, y, ai = "dummy"): as BattleSpawnEnemy, on neither side;
/// `ai` "dummy" stands still (aiMode 2), "normal" its class's AI; another: nil.
pub fn biBattleSpawnCivilian(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const ai = args_mod.argString(args, 3);
    const dummy = ai.len == 0 or std.mem.eql(u8, ai, "dummy");
    if (!dummy and !std.mem.eql(u8, ai, "normal")) return .nil;
    return spawnOn(ctx, args, .civilian, dummy);
}

fn spawnOn(ctx: *anyopaque, args: []const Value, side: @FieldType(@import("../battle.zig").obj.Fight, "spawned"), dummy: bool) !Value {
    _ = battleOf(ctx) orelse return .nil;
    if (args.len < 3) return .nil;
    const debug = @import("../combat.zig").debug;
    const o = try debug.spawnFile(args_mod.worldOf(ctx), args_mod.argString(args, 0), .{ args[1].toInt(), args[2].toInt() }, side, dummy) orelse return .nil;
    // OpenGorky only (no Classic script calls it): the log shows when it came.
    if (battleOf(ctx)) |b| @import("../battle.zig").battle.note(b, "  spawn {s} {t} at {d},{d} on turn {d}", .{ o.name, side, args[1].toInt(), args[2].toInt(), b.turn });
    return .{ .string = o.name };
}

/// BattleWin() / BattleLose(): the battle ends won / lost at its next end check, as the
/// engine's own end (combat/turns.zig ended: the victory unlock, OnBattleEnd, the jingle).
/// 1; 0 outside a battle.
pub fn biBattleWin(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    b.declared = true;
    return .{ .int = 1 };
}

pub fn biBattleLose(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    b.declared = false;
    return .{ .int = 1 };
}

/// FighterTransform(who, into, anim = "", idle = "", sound = ""): `who` turns into class
/// `into` (a class key `ft_x` or a class file; an OpenGorky project's archetype path
/// `characters::x`, world/spawn.zig applyMorph) as the Transform row's fighter does
/// (combat/states.zig transform: model `anim`, "" the class's; then the animation `idle`
/// once); its natives come from the new class's row. 0: no battle, no such fighter or class.
pub fn biFighterTransform(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const b = battleOf(ctx) orelse return .zero;
    const v = fighterArg(ctx, args, 0) orelse return .zero;
    const w = args_mod.worldOf(ctx);
    const into = args_mod.argString(args, 1);
    if (into.len == 0) return .zero;
    const archetype = std.mem.indexOf(u8, into, "::") != null;
    const file = if (archetype or std.fs.path.extension(into).len > 0) into else try @import("../combat.zig").debug.classFile(w, into) orelse return .zero;
    if (!archetype) _ = w.rt.loadClass(file) catch return .zero;
    try @import("../combat.zig").states.transform(b, w, b.fighters.items[v].obj, file, args_mod.argString(args, 2), args_mod.argString(args, 3), args_mod.argString(args, 4), true);
    return .{ .int = 1 };
}

/// A fighter's computed fields for OGS (Runtime.host_fields): `side`, `alive`, `tile`.
pub fn hostField(ctx: *anyopaque, _: *Runtime, o: *Object, name: []const u8) ?Value {
    return events.hostField(args_mod.worldOf(ctx), o, name);
}

/// The roles' engine methods for OGS (`native fn`; Runtime.natives) on
/// fighter `o`, read-only. Hero: `inventory()` the items it owns (not on the ground) in
/// world order; `equipped("hand" | "armor")` the one there or nil; `party_slot()` its place
/// on the panel from 0, nil outside the party (an ally in a battle); `skill(weapon)` its
/// skill level with the weapon, nil without one. Enemy: `ai_profile()` its AI's scoring
/// (rules AiProfile `scoring`); `forced_target()` the fighter its AI is held to
/// (AITargetLock, FighterSetTarget, the Grandma child's avenger) or nil; `reward()` the
/// experience bonus for killing it (kill_exp_pm x max_hp; 0 without kill credit).
pub fn native(ctx: *anyopaque, _: *Runtime, o: *Object, name: []const u8, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const a = w.rt.strings();
    // The runtime asks only for traits' `native` methods (the test below keeps this in step).
    const m = std.meta.stringToEnum(Native, name) orelse return error.NoSuchNative;
    switch (m) {
        .inventory => {
            var out: std.ArrayList(Value) = .empty;
            for (w.rt.objects.items) |x| if (world.isItem(x) and fields.ownerIs(x, o.name) and @import("../inventory.zig").item.placeOf(x) != .ground) try out.append(a, x.ref());
            return .{ .list = out.items };
        },
        .equipped => {
            const place = std.meta.stringToEnum(enum { hand, armor }, if (args[0] == .string) args[0].string else "") orelse return error.NoSuchPlace;
            const x = @import("../inventory.zig").equipment.equipped(w, o, if (place == .hand) .hand else .armor) orelse return .nil;
            return x.ref();
        },
        .party_slot => {
            const i = std.mem.indexOfScalar(*Object, w.party().slice(), o) orelse return .nil;
            return .{ .int = @intCast(i) };
        },
        .skill => {
            if (args[0] != .ref) return error.NotAWeapon;
            const id = fields.classicId(Object.of(args[0].ref));
            for (World.nativeOf(o).growth.skills.items) |s| if (s.id == id) return .{ .int = s.level };
            return .nil;
        },
        .ai_profile, .forced_target, .reward => {},
    }
    const b = if (w.battle) |*x| x else return .nil;
    const f = b.fighters.items[b.fighterOf(o) orelse return .nil];
    return switch (m) {
        .ai_profile => .{ .string = @import("../battle.zig").generic.aiProfile(o, f.side == .enemy).scoring orelse "generic" },
        .forced_target => blk: {
            const lock = World.nativeOf(o).fight.target_lock;
            if (lock.len > 0) break :blk if (w.rt.findObject(lock)) |x| x.ref() else .nil;
            break :blk if (f.grandma_target) |t| b.fighters.items[t].obj.ref() else .nil;
        },
        .reward => if (!@import("../combat.zig").killCredit(f)) .{ .int = 0 } else .{ .int = @import("../script.zig").value.scaleInt(fields.maxHp(o), rules.perMille(.kill_exp_pm)) },
        else => unreachable,
    };
}

/// The roles' `native` methods (script/traits.zig), each answered by `native`.
const Native = enum { inventory, equipped, party_slot, skill, ai_profile, forced_target, reward };

test "role natives: one per traits' native method" {
    var n: usize = 0;
    for (@import("../script.zig").traits.all()) |t| for (t.methods) |me| if (me.native) {
        n += 1;
        if (std.meta.stringToEnum(Native, me.name) == null) {
            std.debug.print("{s}.{s} has no engine answer\n", .{ t.name, me.name });
            return error.TestUnexpectedResult;
        }
    };
    try std.testing.expectEqual(std.enums.values(Native).len, n);
}
