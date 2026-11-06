//! Console debug actions: attack, teleport, fighter spawn (also OpenGorky's
//! BattleSpawnEnemy/Hero/Civilian), medicine.

const std = @import("std");
const weapon_class = @import("../battle.zig").weapon_class;
const fields = @import("../fields.zig");
const control = @import("control.zig");
const strike = @import("strike.zig");
const roster = @import("roster.zig");
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const Battle = battle.Battle;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const weaponKind = @import("../core.zig").modules.weaponKind;
const grid = @import("../battle.zig").grid;
const inventory = @import("../inventory.zig");
const Tile = @import("../battle.zig").grid.Tile;

/// Console `win`. The exe has no such cheat, so an honest end: one that `leaves` (the
/// 04__city_mfd Invisible) leaves (0x4985fb → 0x49839f: not a death); every other enemy dies as in
/// a fight (strike.hurt: grid, death, corpse, enemies_killed); the usual victory follows
/// (turns.checkEnd).
pub fn debugWin(self: *Battle, w: *World) !void {
    if (self.leaver()) |i| {
        const f = &self.fighters.items[i];
        if (!self.invisible_leaving) self.grid().remove(f.tile, f.size);
        self.invisible_leaving = false;
        f.dead = true;
        World.nativeOf(f.obj).deleted = true;
        f.obj.enabled = false;
    }
    for (0..self.fighters.items.len) |i| {
        const f = self.fighters.items[i];
        if (f.side == .enemy and f.alive()) try strike.hurt(self, w, @intCast(i), @max(1, f.hp()));
    }
}

/// Player turn forced before the enemies finished appearing (console on the first
/// battle tick): finish the walk-in at once, otherwise an enemy left off-grid is
/// not a fighter yet alive, and the battle never ends.
fn skipAppear(self: *Battle, w: *World) void {
    if (self.phase != .appear) return;
    self.appear_walker = null;
    for (self.fighters.items, 0..) |*f, k| if (f.appear_to) |to| {
        f.tile = to;
        f.appear_to = null;
        self.grid().place(to, f.size, @intCast(k));
        world_mod.actorOf(f.*.obj).placed = true;
        anim.snap(w, f.*);
    };
}

/// Debug (console `attack`): hero `hero` strikes `target` (null = nearest live
/// enemy) with `wpn` as in battle (animation, effects, damage) without turn
/// checks. The hero is moved to a free tile from which the target is hit (the
/// farthest, at most 4 tiles away, so the projectile is visible). false on failure.
pub fn debugAttack(self: *Battle, w: *World, hero: *Object, wpn: *Object, target: ?*Object, here: bool) !bool {
    if (self.pending != .none) return false;
    const me = self.fighterOf(hero) orelse return false;
    const cm = w.map.combat orelse return false;
    const g = self.grid();
    const f0 = self.fighters.items[me];
    var tv: u16 = grid.Grid.none;
    if (target) |t| tv = self.fighterOf(t) orelse return false else {
        var best: i32 = std.math.maxInt(i32);
        for (self.fighters.items, 0..) |o, i| {
            if (o.side != .enemy or !o.alive()) continue;
            const d: i32 = @intCast(@max(@abs(o.tile[0] - f0.tile[0]), @abs(o.tile[1] - f0.tile[1])));
            if (d < best) {
                best = d;
                tv = @intCast(i);
            }
        }
    }
    if (tv == grid.Grid.none) return false;
    const pat = weapon_class.pattern(wpn) orelse return false;
    const tt = self.fighters.items[tv].tile;
    var best_tile: ?Tile = null;
    var best_aim: grid.Target = undefined;
    var best_d: i32 = -1;
    var buf: [256]grid.Target = undefined;
    var y: i32 = tt[1] - 4;
    while (y <= tt[1] + 4) : (y += 1) {
        var x: i32 = tt[0] - 4;
        while (x <= tt[0] + 4) : (x += 1) {
            const t: Tile = .{ x, y };
            // `here`: only from its own tile (no move).
            if (here and (x != f0.tile[0] or y != f0.tile[1])) continue;
            if (!g.fits(t, f0.size, me)) continue;
            const d: i32 = @intCast(@max(@abs(x - tt[0]), @abs(y - tt[1])));
            if (d <= best_d) continue;
            for (grid.targets(g, pat, t, me, true, false, &buf)) |aim| if (aimCovers(g, pat, aim, tv)) {
                best_tile = t;
                best_aim = aim;
                best_d = d;
                break;
            };
        }
    }
    const t = best_tile orelse return false;
    const f = &self.fighters.items[me];
    g.remove(f.tile, f.size);
    f.tile = t;
    g.place(t, f.size, me);
    world_mod.actorOf(f.*.obj).stopWalking(w.crt());
    fields.setPos(f.obj, cm.tileCenter(t, f.size));
    inventory.equipment.toHand(w, hero, wpn);
    World.nativeOf(wpn).fight.recharge = 0;
    f.weapon = wpn;
    f.acted = false;
    // Walk budget spent, so no walk-range highlight after the strike.
    f.used = @floatFromInt(f.walkRange());
    skipAppear(self, w);
    self.phase = .player;
    self.selected = me;
    w.selected_hero = hero.name;
    try strike.startAttack(self, w, me, wpn, best_aim);
    return true;
}

/// Debug (console `put`): move a fighter to tile `t` if it is free.
pub fn debugPut(self: *Battle, w: *World, o: *Object, t: Tile) bool {
    const cm = w.map.combat orelse return false;
    const who = self.fighterOf(o) orelse return false;
    const g = self.grid();
    const f = &self.fighters.items[who];
    if (!g.fits(t, f.size, who)) return false;
    g.remove(f.tile, f.size);
    f.tile = t;
    g.place(t, f.size, who);
    world_mod.actorOf(f.*.obj).stopWalking(w.crt());
    fields.setPos(f.obj, cm.tileCenter(t, f.size));
    return true;
}

/// A fighter created mid-battle (console `spawn`, `spawnFile`): at the centre of
/// tile `t`, into the battle and the grid, facing the nearest opponent (+0xd0).
/// false if the tile is outside the grid or taken.
fn spawnFighter(self: *Battle, w: *World, o: *Object, t: Tile) !bool {
    const cm = w.map.combat orelse return false;
    const size = roster.fighterSize(o);
    if (!self.grid().fits(t, size, grid.Grid.none)) return false;
    fields.setPos(o, cm.tileCenter(t, size));
    world_mod.actorOf(o).placed = true;
    const first = self.fighters.items.len;
    _ = try roster.addNewcomers(self, w);
    for (self.fighters.items[first..], first..) |_, i| control.faceDefault(self, w, i, false);
    return self.fighterOf(o) != null;
}

/// Debug (console `medicine`): hero `hero` gives `item` to `target` as in battle
/// (`useItemOn`) without turn checks; if not adjacent, it is moved to a free
/// neighbouring tile.
pub fn debugMedicine(self: *Battle, w: *World, hero: *Object, item: *Object, target: *Object) !bool {
    if (self.pending != .none) return false;
    const me = self.fighterOf(hero) orelse return false;
    const tv = self.fighterOf(target) orelse return false;
    const tt = self.fighters.items[tv].tile;
    const f = &self.fighters.items[me];
    if (me != tv and (@abs(f.tile[0] - tt[0]) + @abs(f.tile[1] - tt[1]) > 1)) {
        for ([_]Tile{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
            if (debugPut(self, w, hero, .{ tt[0] + d[0], tt[1] + d[1] })) break;
        } else return false;
    }
    f.acted = false;
    skipAppear(self, w);
    self.phase = .player;
    self.selected = me;
    w.selected_hero = hero.name;
    return try control.useItemOn(self, w, item, tt) == .used;
}

/// Put a fighter from file `file` (`.ftr`, usually a mod) into the battle at
/// `tile` (console `spawn`; OpenGorky's BattleSpawnEnemy/Hero/Civilian). OpenGorky: `file` without an
/// extension is a class key as the rules name it (`ft_x`: a fighter including that script,
/// as a level's `.ftr` does; classFile). The object is named after the file (numbered if
/// taken). Weapons are the files listed in the fighter's `weapons` field ("a.wpn, b.wpn"),
/// owned by the new fighter, the first in hand; none listed: copies of those a fighter of
/// its class in the world holds. `side`: `.hero` on the heroes' side, the player's to select
/// and give turns as a hero (not in the party: it stays behind after the battle);
/// `.civilian` on neither side, by AI on the enemies' turn, `dummy` its AI standing still
/// (aiMode 2); `.enemy` as its data says. Returns the fighter or null (no file or class, no
/// battle, tile taken). An OpenGorky project's fighter archetype (`characters::grandma`, a
/// `~c` sigil's): an object of its block named by its last part, its nested weapons too.
pub fn spawnFile(self: *World, file_or_class: []const u8, tile: [2]i32, side: @FieldType(@import("../battle.zig").obj.Fight, "spawned"), dummy: bool) !?*Object {
    const b = &(self.battle orelse return null);
    // shortcut: a fighter bigger than 1×1 that doesn't fit stays made (disabled, deleted:
    // the world has no removal); checked here for one tile only, its size comes from init().
    if (!b.grid().fits(tile, 1, grid.Grid.none)) return null;
    const ext = std.fs.path.extension(file_or_class);
    const og_block = self.res.source.level_block.len > 0 and ext.len == 0 and std.mem.indexOf(u8, file_or_class, "::") != null;
    const stem = if (og_block) file_or_class[std.mem.lastIndexOf(u8, file_or_class, "::").? + 2 ..] else file_or_class[0 .. file_or_class.len - ext.len];
    const file = if (ext.len > 0 or og_block) file_or_class else try classFile(self, stem) orelse return null;
    var name_buf: [64]u8 = undefined;
    var name: []const u8 = stem;
    var k: u32 = 2;
    while (self.rt.findObject(name) != null) : (k += 1) {
        name = std.fmt.bufPrint(&name_buf, "{s}_{d}", .{ stem, k }) catch return null;
    }
    const start = @import("../world.zig").start;
    const o = if (og_block) try start.spawnBlock(self, name, file) orelse return null else o: {
        const cls = self.rt.loadClass(file) catch |err| {
            std.log.warn("spawn {s}: {t}", .{ file, err });
            return null;
        };
        break :o try self.addObject(name, cls, @import("../state.zig").object.nativeFor(".ftr"));
    };
    _ = try self.rt.callIfExists(o, "init", &.{});
    try start.actorHooks(self, o);
    // The archetype's own weapons came with its block.
    var first = !og_block;
    var it = std.mem.tokenizeAny(u8, o.getString("weapons"), ", ;\t");
    while (it.next()) |wf| {
        const wext = std.fs.path.extension(wf);
        var wname_buf: [96]u8 = undefined;
        const wname = std.fmt.bufPrint(&wname_buf, "{s}_{s}", .{ name, wf[0 .. wf.len - wext.len] }) catch continue;
        if (self.rt.findObject(wname) != null) continue;
        const wcls = self.rt.loadClass(wf) catch |err| {
            std.log.warn("spawn {s}: {s}: {t}", .{ name, wf, err });
            continue;
        };
        _ = try newWeapon(self, wname, wcls, o.name, if (first) 11 else 10);
        first = false;
    }
    if (first and !og_block) try copyWeapons(self, o);
    _ = try self.rt.callIfExists(o, "post_init", &.{});
    World.nativeOf(o).fight.spawned = side;
    if (dummy) {
        try o.declare(self.rt.arena(), "ai_mode", .{ .type = .int, .value = .{ .int = 0 } });
        o.setInt("ai_mode", 2);
    }
    if (!try spawnFighter(b, self, o, tile)) {
        o.enabled = false;
        World.nativeOf(o).deleted = true;
        return null;
    }
    return o;
}

/// OpenGorky: the class file of fighter class `key` (`ft_x`): `og_spawn_<key>.ftr`, made
/// once, including `<key>.ss` as a level's fighter does; null when the project has no such
/// script.
pub fn classFile(self: *World, key: []const u8) !?[]const u8 {
    const a = self.rt.arena();
    const script = try std.fmt.allocPrint(a, "{s}.ss", .{key});
    if ((self.rt.source.fetch(self.rt.source.ctx, script) catch null) == null) return null;
    const file = try std.fmt.allocPrint(a, "og_spawn_{s}.ftr", .{key});
    try @import("../world.zig").sources.addSource(self, file, try std.fmt.allocPrint(a,
        \\#include Fighter.s
        \\
        \\function init()
        \\{{
        \\#include {s}
        \\}};
        \\
    , .{script}));
    return file;
}

/// Weapon `name` of class `cls` made for `owner` at place `place` (11: in hand).
fn newWeapon(self: *World, name: []const u8, cls: *@import("../script.zig").object.Class, owner: []const u8, place: i32) !*Object {
    const wo = try self.addObject(name, cls, .{ .kind = .weapon });
    _ = try self.rt.callIfExists(wo, "class_init", &.{});
    _ = try self.rt.callIfExists(wo, "init", &.{});
    fields.setOwner(wo, try self.rt.arena().dupe(u8, owner));
    wo.setInt("place", place);
    return wo;
}

/// Copies for `o` of the weapons the first other fighter of its class (rules.classOf)
/// holds, each at its place.
fn copyWeapons(self: *World, o: *Object) !void {
    const classOf = @import("../rules.zig").classOf;
    const twin = for (self.rt.objects.items) |x| {
        if (x != o and fields.isFighter(x) and !World.nativeOf(x).deleted and std.ascii.eqlIgnoreCase(classOf(x.class), classOf(o.class))) break x;
    } else return;
    // Gathered first: making one adds to the objects.
    var held: [8]*Object = undefined;
    var n: usize = 0;
    for (self.rt.objects.items) |x| if (n < held.len and World.nativeOf(x).kind == .weapon and !World.nativeOf(x).deleted and fields.ownerIs(x, twin.name)) {
        held[n] = x;
        n += 1;
    };
    for (held[0..n]) |x| {
        var buf: [96]u8 = undefined;
        const wname = std.fmt.bufPrint(&buf, "{s}_{s}", .{ o.name, x.name }) catch continue;
        if (self.rt.findObject(wname) == null) _ = try newWeapon(self, wname, x.class, o.name, x.getInt("place"));
    }
}

/// The aim hits fighter `tv`: it stands on it, or for a bomb (class 9, placed on
/// an empty tile) the effect area covers it.
fn aimCovers(g: grid.Grid, pat: *const @import("../rules.zig").Pattern, aim: grid.Target, tv: u16) bool {
    // Bomb and wide ray (Jet Elmer, two tiles wide): the target is in the effect area.
    if (weaponKind(pat.classic_id) != .time_bomb and !pat.wide) return g.at(aim.tile) == tv;
    var eff: [128]Tile = undefined;
    for (grid.effectTiles(g, pat, aim, &eff)) |t| if (g.at(t) == tv) return true;
    return false;
}
