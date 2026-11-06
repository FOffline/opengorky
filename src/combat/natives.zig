//! The engine's code of the native components (core/natives.zig): what
//! each one answers at the built-in method the battle asks (`Runtime.native_components`,
//! script/dispatch.zig), exactly what the battle did by its Abilities row field there.
//! Each method gets the world (the runtime's) and its instance (its host the fighter,
//! its parameters its variables, core/natives.zig `params`: read at each call, so a
//! script that changes one changes what it does).

const std = @import("std");
const script = @import("../script.zig");
const Object = script.object.Object;
const Runtime = script.runtime.Runtime;
const Value = script.value.Value;
const World = @import("../state.zig").world.World;
const fields = @import("../fields.zig");
const natives = @import("../core.zig").natives;
const modules = @import("../core.zig").modules;
const battle = @import("../battle.zig").battle;
const world = @import("../state.zig").world;
const grid = @import("../battle.zig").grid;
const Fighter = @import("../battle.zig").fighter.Fighter;
const behaviour = @import("../core.zig").behaviour;
const Battle = battle.Battle;

/// Built-in method `path` ("Fighter.CanPush") asked of `o`'s components with `args` (a
/// tuple of values): its natives' and scripted abilities' answer, null when none answers.
pub fn ask(w: *World, o: *Object, comptime path: []const u8, args: anytype) error{OutOfMemory}!?Value {
    var a: [args.len]Value = args;
    return script.dispatch.call(&w.rt, o, script.traits.method(path), &a);
}

/// Its ExtraAction: a second action this turn (native DoubleTurn).
pub fn extraAction(w: *World, o: *Object) error{OutOfMemory}!bool {
    return if (try ask(w, o, "Fighter.ExtraAction", .{})) |v| v.truth() else false;
}

/// Its CanPush (native NoPush: Medusa); the engine's: may (the gender is the caller's).
pub fn canPush(w: *World, o: *Object) error{OutOfMemory}!bool {
    return if (try ask(w, o, "Fighter.CanPush", .{})) |v| v.truth() else true;
}

/// Where it faces, at the start (`after_move` false) or after its own move: its StandAngle
/// (native Stand: Puppet −1.57, Messiah 3.14), null: the engine's (the nearest opponent;
/// after its move nothing).
/// shortcut: out of memory reads as no answer (the callers are no error paths: the
/// facing, the AI's aiming); upgrade if this ever allocates more.
pub fn standAngle(w: *World, o: *Object, after_move: bool) ?f32 {
    const v = (ask(w, o, "Fighter.StandAngle", .{Value{ .bool = after_move }}) catch return null) orelse return null;
    return v.toFloat();
}

/// Tile `rel` of fighter `f`'s abilities (core/behaviour.zig `Rel`: to its right, ahead)
/// on the battle grid: from its tile by its facing — its StandAngle when it has one (it
/// turns to strike and back; the Messiah's arms are by his stance), else its angle now.
fn relTile(w: *World, f: Fighter, rel: grid.Tile) grid.Tile {
    const rot = if (w.map.combat) |cm| cm.rotation else 0;
    const angle = standAngle(w, f.obj, false) orelse fields.angle(f.obj);
    return behaviour.relTile(f.tile, behaviour.ahead(angle, rot), rel);
}

/// An `.obs` obstacle stands on the tile (type 4, not an item box).
fn obstacleAt(b: *Battle, t: grid.Tile) bool {
    const o = b.grid().at(t);
    if (o == grid.Grid.none) return false;
    const f = b.fighters.items[o];
    return f.side == .neutral and f.obj.getVar("cnt_itm") == null;
}

/// Method `method` of native instance `inst` of kind `tag` with `args` (null: no answer).
pub fn call(rt: *Runtime, inst: *Object, tag: u8, method: []const u8, args: []Value) anyerror!?Value {
    const w: *World = @fieldParentPtr("rt", rt);
    const eq = std.mem.eql;
    const host = inst.owner.?;
    const v = struct {
        fn of(o: *Object, comptime n: []const u8) Value {
            return if (o.getVar(n)) |x| x.value else .nil;
        }
    }.of;
    switch (natives.kindOf(tag)) {
        // ExtraAction: a second action this turn (Incubus, Cripple +0x24908).
        .double_turn => return .{ .bool = true },
        // TurnPriority(side): 1 on a level of levelMode `level_mode` (Grandma in the
        // citadel: 2, 0x498288).
        .goes_first => if (w.level) |l| if (l.getInt("mode") == inst.getInt("level_mode")) return .{ .int = 1 },
        // StandAngle(after_move): "stand properly" (+0xd0) at `angle` (Puppet 0x4e1b80,
        // Messiah 0x4df8d0), after its own move too with `after_move` (0x4e17b0,
        // 0x4dfdd4).
        .stand => if (!args[0].truth() or v(inst, "after_move").truth()) return .{ .float = v(inst, "angle").toFloat() },
        // GuardDamage(attacker, weapon, amount): struck from the front and sides (under
        // `cone` from its gaze) amount /div, at least min (Puppet +0xcc 0x4e1bb0).
        .guard => {
            const a = Object.of(args[0].ref);
            const want = fields.facing(fields.pos(a)[0] - fields.pos(host)[0], fields.pos(a)[1] - fields.pos(host)[1]);
            if (@abs(fields.angleDiff(want, fields.angle(host))) >= v(inst, "cone").toFloat()) return null;
            // A script may have set div 0: no answer rather than a division by zero.
            const div = inst.getInt("div");
            if (div == 0) return null;
            return .{ .int = @max(@divTrunc(args[2].toInt(), div), inst.getInt("min")) };
        },
        // Struck only from its tile (`right`, `ahead` of it; CanBeStruck(from_tile):
        // elsewhere a miss, 0x4cee33); closed to the attacker's tile it dodges before the
        // shot (OnDodge: `dodge`, 0x47c4c0). The Messiah.
        .open_from => if (eq(u8, method, "OnDodge")) {
            world.actorOf(host).play(inst.getString("dodge"), false, true);
        } else {
            const f = fighterOf(w, host) orelse return null;
            const from = args[0].list;
            if (!std.meta.eql(grid.Tile{ from[0].toInt(), from[1].toInt() }, relTile(w, f, .{ inst.getInt("right"), inst.getInt("ahead") }))) return .{ .bool = false };
        },
        // Arms on tiles a box can block (the Messiah's, 0x4dfdd4): CanUse(weapon) no with
        // the arm (weapon kind messiah_left/right) a box blocks; OnMoveEnd: both blocked,
        // it does `blocked` ("atakB").
        .arms => {
            const arms = .{ .left = grid.Tile{ inst.getInt("left_right"), inst.getInt("left_ahead") }, .right = grid.Tile{ inst.getInt("right_right"), inst.getInt("right_ahead") } };
            const b = if (w.battle) |*b| b else return null;
            const f = fighterOf(w, host) orelse return null;
            if (eq(u8, method, "OnMoveEnd")) {
                if (obstacleAt(b, relTile(w, f, arms.right)) and obstacleAt(b, relTile(w, f, arms.left))) world.actorOf(host).play(inst.getString("blocked"), false, true);
                return null;
            }
            const kind = modules.weaponKind(Object.of(args[0].ref).getInt("class"));
            if ((kind == .messiah_left and obstacleAt(b, relTile(w, f, arms.left))) or (kind == .messiah_right and obstacleAt(b, relTile(w, f, arms.right)))) return .{ .bool = false };
        },
        // CanPush: no (Medusa: the push button 0x4b1907).
        .no_push => return .{ .bool = false },
        // CanSelect: no (Medusa: fights in battles only; the callers ask outside one,
        // 0x481ce0, 0x4b2761, 0x4b1df1).
        .battle_only => return .{ .bool = false },
        // OnDamageDealt(target, weapon, lost): the live fighter named `who` gains
        // `lost` up to its max_hp, a heal popup (the Judge's child 0x4dd010).
        .heals => {
            const b = if (w.battle) |*b| b else return null;
            const dealt = args[2].toInt();
            if (dealt <= 0) return null;
            for (b.fighters.items) |*j| {
                if (!j.alive() or !std.ascii.eqlIgnoreCase(j.obj.name, inst.getString("who"))) continue;
                const add = @min(dealt, fields.maxHp(j.obj) - j.hp());
                if (add <= 0) return null;
                fields.setHp(j.obj, j.hp() + add);
                var buf: [16]u8 = undefined;
                battle.popup(b, j.*, std.fmt.bufPrint(&buf, "{d}", .{add}) catch "", .heal) catch {};
                return null;
            }
        },
        // OnDeath(killer): the fighter named `avenger` targets whoever hit it last
        // (+0x24af8; Grandma's child 0x4e08d0). Burning and gas (0x4903d0) strike without
        // an attacker (0x490e9a), so after a death by fire it's the one who set it alight;
        // walked into fire on its own, nobody.
        .avenger => {
            const b = if (w.battle) |*b| b else return null;
            const last = b.fighters.items[b.fighterOf(host) orelse return null].last_attacker;
            for (b.fighters.items) |*g| if (std.ascii.eqlIgnoreCase(g.obj.name, inst.getString("avenger"))) {
                g.grandma_target = last;
            };
        },
        // Marks: the battle checks their bit.
        .immobile, .monitor, .no_kill_credit, .pairs, .invisible, .leaves, .no_hands => {},
    }
    return null;
}

/// Fighter `o` of the battle (null: none, or not in it).
fn fighterOf(w: *World, o: *Object) ?Fighter {
    const b = if (w.battle) |*b| b else return null;
    return b.fighters.items[b.fighterOf(o) orelse return null];
}
