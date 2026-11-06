//! Fighter states: sleep, gas, fire, freeze, rage, poison; hazard tiles.

const ut = @import("../core.zig").ui_text;
const fields = @import("../fields.zig");
const inventory = @import("../inventory.zig");
const scenes = @import("../scene.zig").scenes;
const spawn = @import("../world.zig").spawn;
const battle = @import("../battle.zig").battle;
const Battle = battle.Battle;
const rules = @import("../battle.zig").rules;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const immunity = @import("../battle.zig").immunity;
const grid = @import("../battle.zig").grid;
const Tile = grid.Tile;
const Fighter = @import("../battle.zig").fighter.Fighter;
const modules = @import("../core.zig").modules;
const Object = @import("../script.zig").object.Object;

/// Apply a state (0x4900f0). Resistance: monsters by table, heroes by worn armour
/// (`pr*` of the item). Applied during the enemy turn (`[0x6c4e88]`) it lasts one turn longer.
pub fn applyEffect(self: *Battle, w: *World, f: *Fighter, kind: rules.Effect) void {
    // Obstacles take no states, except fire on a barrel (0x4900f0).
    if (f.side == .neutral and !(f.explosive and kind == .burn)) return;
    if (immunity.effectCode(kind)) |code| {
        if (resistsDiscover(self, w, f.*, code)) return;
    }
    // Applied during the enemy turn (`[0x6c4e88]`): one turn longer, so the
    // end-of-turn countdown does not eat the victim's turn.
    // How long: rules StateEffect (the exe: burn 3, freeze 2, gas 3, soak 3, sleep 2).
    const extra: i32 = @intFromBool(self.enemy_period);
    const turns = modules.stateEffect(kind).turns;
    switch (kind) {
        .burn => {
            f.burning = turns + extra;
            f.frozen = 0;
        },
        .freeze => {
            f.burning = 0;
            f.soaked = 0;
            f.frozen = turns + extra;
        },
        .gas => f.gassed = turns + extra,
        .soak => if (f.burning > 0) {
            f.burning = modules.stateEffect(.burn).turns;
        } else {
            f.soaked = turns + extra;
        },
        .defend => f.defending = true,
        // Sleep (0x49036f): unless defending, stance 6 (sleep) and the weapon leaves the
        // hand (+0x30d0 = 0, 0x490397); when defending nothing changes.
        .sleep => {
            f.asleep = turns + extra;
            // The turn is lost at once (0x49037d…0x49038b): walked = whole walk_range,
            // acted, turn over (+0x2460c…+0x24614).
            f.used = @floatFromInt(f.walkRange());
            f.acted = true;
            if (!f.defending) {
                const a = world_mod.actorOf(f.*.obj);
                a.state = 6;
                a.weapon_detached = true;
            }
        },
        .bite => f.bitten = true,
    }
    battle.note(self, "  {s}: state {d}", .{ f.obj.name, @backingInt(kind) });
}

/// Tranquilizer antidote (0x49006d): sleep removed, the turn restarts (walked 0,
/// not acted, +0x2460c…+0x24614); stance 0x42b450: 4 when defending (idle,
/// 0x422f90), else 0 (7 in battle).
pub fn wake(w: *World, f: *Fighter) void {
    f.asleep = 0;
    f.used = 0;
    f.acted = false;
    const a = world_mod.actorOf(f.*.obj);
    a.setState(if (f.defending) 4 else 0, true);
    if (f.defending) a.pickIdle(w.crt());
}

pub fn setHazard(self: *Battle, layer: []u8, t: Tile, v: u8) void {
    if (!self.grid().inside(t)) return;
    const i = grid.tileIndex(self.width, t);
    layer[i] = @max(layer[i], v);
}

pub fn hazardAt(self: *Battle, layer: []const u8, t: Tile) u8 {
    if (!self.grid().inside(t)) return 0;
    return layer[grid.tileIndex(self.width, t)];
}

/// A fighter on a burning tile catches fire (0x48f820), in gas gets poisoned (0x48f8c0).
pub fn hazardCheck(self: *Battle, w: *World, f: *Fighter) void {
    if (!f.alive() or f.appear_to != null) return;
    var on_fire = false;
    var in_gas = false;
    for (0..f.size) |dy| for (0..f.size) |dx| {
        const t: Tile = .{ f.tile[0] + @as(i32, @intCast(dx)), f.tile[1] + @as(i32, @intCast(dy)) };
        if (hazardAt(self, self.fire, t) > 0) on_fire = true;
        if (hazardAt(self, self.gas, t) > 0) in_gas = true;
    };
    // In the exe this is the fighter's turn start (0x48f6f0 via vtable +0xc0), before
    // the enemy-turn flag (0x498448 before 0x498460): fire and gas underfoot last the
    // usual 3 turns with damage that turn (else 4 turns and no damage: napalm didn't burn).
    const period = self.enemy_period;
    self.enemy_period = false;
    defer self.enemy_period = period;
    if (on_fire) applyEffect(self, w, f, .burn);
    if (in_gas) applyEffect(self, w, f, .gas);
}

/// The battle's transformation (rules Transform by levelMode; the exe's girl → Lilith):
/// its clock armed by the first hero strike (combat/strike.zig), then the morph and the dialog.
pub fn tickTransform(self: *Battle, w: *World) !void {
    if (self.transform_ticks <= 0 and self.transform_dialog_ticks <= 0) return;
    const t = modules.transform((w.level orelse return).getInt("mode")) orelse return;
    if (self.transform_ticks > 0) {
        self.transform_ticks -= 1;
        if (self.transform_ticks == 0) {
            self.transform_dialog_ticks = t.dialog_delay;
            if (w.rt.findObject(t.who)) |o| try transform(self, w, o, t.into, t.anim, t.idle, t.sound, false);
        }
    }
    if (self.transform_dialog_ticks > 0) {
        self.transform_dialog_ticks -= 1;
        if (self.transform_dialog_ticks == 0 and t.dialog.len > 0) try scenes.startDialog(w, t.dialog, if (t.dialog_file.len > 0) t.dialog_file else t.dialog);
    }
}

/// A fighter's transformation (the Transform row's, OpenGorky's FighterTransform): `o`
/// freed (moveLock, attackLock) and morphing into class `into` (model `anim`, then the
/// animation `idle` once; world/spawn.zig morphActor) with `sound` ("": none). `keep_hp`
/// (FighterTransform): the health it has when the class changes stays (morphDone).
pub fn transform(self: *Battle, w: *World, o: *Object, into: []const u8, anim: []const u8, idle: []const u8, sound: []const u8, keep_hp: bool) !void {
    fields.clearMoveLock(o);
    o.setInt("attack_locked", 0);
    try spawn.morphActor(w, o, into, anim, idle);
    world_mod.actorOf(o).morph.?.keep_hp = keep_hp;
    if (sound.len > 0) w.out.sound(w.gpa, sound, null);
    battle.note(self, "  {s}: transform", .{o.name});
}

/// A morph's end (the world calls it `morf_life2` ticks after ACTOR_MORPH or a transform):
/// the class changes (world/spawn.zig applyMorph: its init() sets its values). One with
/// `keep_hp` keeps the health it had (a script's FighterSetHp after FighterTransform; the
/// Transform row's takes the new class's). OpenGorky: a fighter in the battle has its
/// former class's scripted abilities swapped for the new class's row's (its natives already
/// were, by applyMorph).
pub fn morphDone(w: *World, o: *Object) !void {
    const a = world_mod.actorOf(o);
    const mp = a.morph orelse return;
    a.morph = null;
    const hp = fields.hp(o);
    try spawn.applyMorph(w, o, mp.class, mp.mesh, mp.idle);
    if (mp.keep_hp) fields.setHp(o, hp);
    if (!@import("../rules.zig").og) return;
    const b = &(w.battle orelse return);
    if (b.fighterOf(o) != null) try @import("events.zig").attachScripts(b, w, o, true);
}

/// Monster resistance by table: on first trigger a popup over it (string.tab
/// 801–808) and the "known" mark (0x4caa80: 1 → 2).
pub fn resistsDiscover(self: *Battle, w: *World, f: Fighter, code: immunity.Resist) bool {
    if (w.immunity.immune(@import("../rules.zig").who(f.obj), code)) {
        if (w.immunity.discover(@import("../rules.zig").who(f.obj), code)) {
            battle.popup(self, f, w.stringOr(ut.of(.resist_fire, code.index()), immunity.protection_text[code.index()]), .info) catch {};
            battle.note(self, "  {s}: {s}", .{ f.obj.name, immunity.protection_text[code.index()] });
        }
        return true;
    }
    return f.side == .hero and inventory.equipment.armorProtects(w, f.obj, code);
}
