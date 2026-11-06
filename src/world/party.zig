//! The hero party across locations. In the exe heroes and their items are global objects;
//! here every location recreates heroes (`gamestart\*.hro`), so leaving a location captures
//! the heroes and their items and the next location applies them.
//!
//! Carried over: all hero vars (except position), skills, level points, and every item or
//! weapon owned by a hero (`Owner`). Items that no longer exist (thrown grenade) are removed.
//! An OpenGorky project's also: the vars of their component instances and the instances'
//! subscriptions (`events::Subscribe`), as a save keeps them (world/saved.zig).

const std = @import("std");
const state_object = @import("../state.zig").object;
const fields = @import("../fields.zig");
const walk = @import("walk.zig");
const sources = @import("sources.zig");
const snapshot = @import("snapshot.zig");
const start = @import("start.zig");
const Allocator = std.mem.Allocator;
const world = @import("../state.zig").world;
const inventory = @import("../inventory.zig");
const World = world.World;
const object = @import("../script.zig").object;
const Object = object.Object;

const Battle = @import("../battle.zig").battle.Battle;
const dispatch = @import("../script.zig").dispatch;

const VarCopy = snapshot.VarCopy;

const Entry = struct {
    name: []const u8,
    class_file: []const u8,
    /// Its archetype or block (`items::food`, `01p_grenade1`): an OpenGorky project's
    /// objects are made again from it (world/start.zig recreateBlock); "": Classic.
    ident: []const u8 = "",
    /// Class source when it comes from the location archive rather than common.
    class_src: ?[]const u8 = null,
    kind: state_object.Kind,
    hero: bool,
    /// Known hero (`.hro`) outside the party: carried so later scenes can enable him
    /// (SETHERO).
    hro: bool = false,
    /// Hero deleted (DELETEOBJECT: Medusa after museum-medusa_crazy); exe heroes are global,
    /// so he is gone everywhere.
    deleted: bool = false,
    vars: []VarCopy,
    /// Its component instances' vars.
    comps: []const snapshot.CompCopy = &.{},
    skills: []const state_object.Skill,
    stat_points: i32,
};

/// Hero position vars, kept per location.
const local_vars = [_][]const u8{ "x", "y", "z", "angle", "initok" };

pub const Party = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},
    /// Subscriptions of the carried objects' component instances, in subscription order.
    subs: []const snapshot.SubCopy = &.{},

    pub fn deinit(self: *Party) void {
        self.arena.deinit();
    }

    /// Capture heroes and their items from the world.
    pub fn capture(gpa: Allocator, w: *World) !Party {
        var p: Party = .{ .arena = .init(gpa) };
        errdefer p.deinit();
        const a = p.arena.allocator();
        var list: std.ArrayList(Entry) = .empty;
        for (w.rt.objects.items) |o| {
            const nat = World.nativeOf(o);
            if (nat.deleted) {
                if (nat.kind == .actor and (nat.hero or nat.hro)) try list.append(a, .{
                    .name = try a.dupe(u8, o.name),
                    .class_file = try a.dupe(u8, o.class.name),
                    .kind = nat.kind,
                    .hero = false,
                    .hro = true,
                    .deleted = true,
                    .vars = &.{},
                    .skills = &.{},
                    .stat_points = 0,
                });
                continue;
            }
            const hero = nat.hero;
            if (!hero and !nat.hro and !snapshot.ownedByHero(w, o)) continue;
            const from: snapshot.From = .{ .level = w.level_name, .w = w };
            const vars = try snapshot.copyVars(a, from, o, if (hero) &local_vars else local_vars[0..0]);
            const skills = try a.dupe(state_object.Skill, nat.growth.skills.items);
            try list.append(a, .{
                .name = try a.dupe(u8, o.name),
                .class_file = try a.dupe(u8, o.class.name),
                .ident = try a.dupe(u8, o.class.ident orelse ""),
                .class_src = if (sources.localSource(w, o.class.name)) |src| try a.dupe(u8, src) else null,
                .kind = nat.kind,
                .hero = hero,
                .hro = nat.hro,
                .vars = vars,
                .comps = try snapshot.copyComps(a, from, o),
                .skills = skills,
                .stat_points = nat.growth.stat_points,
            });
        }
        p.entries = list.items;
        var subs: std.ArrayList(snapshot.SubCopy) = .empty;
        for (w.rt.subs.items) |sb| {
            const host = sb.inst.owner.?;
            if (World.nativeOf(host).deleted or !snapshot.travels(w, host)) continue;
            if (try snapshot.copySub(a, sb)) |c| try subs.append(a, c);
        }
        p.subs = subs.items;
        return p;
    }

    /// Before the location starts: create heroes it lacks (BT, Medusa) so init()/restore()
    /// see them (PlaceActor in battles). A party hero is of the hero class (`hro`; the exe's
    /// type 6, 0x481d18), so HERO_EnableEnumerate works on him here (0x4c199a).
    pub fn createMissingHeroes(self: *const Party, w: *World) !void {
        for (self.entries) |e| {
            if (!e.hero or w.rt.findObject(e.name) != null) continue;
            const nat: state_object.Native = .{ .kind = .actor, .hero = true, .hro = true, .fighter = true };
            if (w.block_item != null) {
                if (try start.recreateBlock(w, e.name, e.ident, nat) == null) try w.countMissing("class ", e.ident);
                continue;
            }
            if (e.class_src) |src| try sources.addSource(w, e.class_file, src);
            const cls = w.rt.loadClass(e.class_file) catch |err| {
                try w.classMissing(e.class_file, err);
                continue;
            };
            _ = try w.addObject(e.name, cls, nat);
        }
    }

    fn has(self: *const Party, name: []const u8) bool {
        for (self.entries) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return true;
        return false;
    }

    /// Apply the party to the world (after start or on return). `keep_level_disabled`
    /// (fresh load): don't enable a hero the level's init/restore disabled (he appears
    /// later via AIEnemyAppear).
    pub fn apply(self: *const Party, w: *World, keep_level_disabled: bool) !void {
        var joined: [World.party_cap]*Object = undefined;
        var n_joined: usize = 0;
        var carried: std.ArrayList(*Object) = .empty;
        defer carried.deinit(w.gpa);
        for (self.entries) |e| {
            var obj = w.rt.findObject(e.name);
            const existed = obj != null;
            // Not in the party: the location's own copy wins; without one, create it disabled.
            // If that copy is still in the party (stored before he left or was deleted), take
            // him out: in the exe a hero is one object for the whole game (Medusa, deleted in
            // the observatory, used to come back in 03_museum).
            if (!e.hero and e.hro and obj != null) {
                const nat = World.nativeOf(obj.?);
                if (nat.hero) {
                    nat.hero = false;
                    obj.?.enabled = false;
                    if (e.deleted) nat.deleted = true;
                }
                continue;
            }
            if (e.deleted) continue;
            if (obj == null) {
                // A hero who joined during the game (BT), from his class source.
                const nat: state_object.Native = .{ .kind = e.kind, .hero = e.hero, .hro = e.hro, .fighter = e.hero or e.hro };
                const o = if (w.block_item != null) try start.recreateBlock(w, e.name, e.ident, nat) orelse {
                    try w.countMissing("class ", e.ident);
                    continue;
                } else blk: {
                    if (e.class_src) |src| try sources.addSource(w, e.class_file, src);
                    const cls = w.rt.loadClass(e.class_file) catch |err| {
                        try w.classMissing(e.class_file, err);
                        continue;
                    };
                    break :blk try w.addObject(e.name, cls, nat);
                };
                // As Classic's snapshot.recreate: an actor's creation events.
                if (e.hero or e.hro) try snapshot.created(w, o);
                obj = o;
                if (e.hero and e.kind == .actor and n_joined < joined.len) {
                    joined[n_joined] = o;
                    n_joined += 1;
                }
            }
            const o = obj.?;
            const nat = World.nativeOf(o);
            nat.from_party = true;
            nat.deleted = false;
            nat.hero = e.hero;
            if (!(keep_level_disabled and existed and e.hero and !o.enabled)) o.enabled = e.hero or !e.hro;
            try snapshot.restore(w, o, e.vars, e.skills, e.stat_points);
            try snapshot.restoreComps(&w.rt, w.level_name, o, e.comps, null);
            try carried.append(w.gpa, o);
        }
        // The carried objects' subscriptions replace those they have here (made as the
        // location was made, or left from the last visit), after the location's own; a
        // battle's scripted abilities' stay (they are not carried).
        var kept: usize = 0;
        for (w.rt.subs.items) |sb| if (sb.inst.scope == .battle or std.mem.indexOfScalar(*Object, carried.items, sb.inst.owner.?) == null) {
            w.rt.subs.items[kept] = sb;
            kept += 1;
        };
        w.rt.subs.shrinkRetainingCapacity(kept);
        try snapshot.attachSubs(&w.rt, self.subs, "party");
        for (joined[0..n_joined]) |o| if (o.enabled) walk.placeBesideLead(w, o);
        try syncRoles(w);
        // Remove items of carried heroes that the party no longer has (thrown grenade).
        // Items of heroes first met here (Medusa) are untouched.
        for (w.rt.objects.items) |o| {
            const nat = World.nativeOf(o);
            if (nat.hero or nat.deleted or !snapshot.ownedByHero(w, o)) continue;
            if (!self.has(fields.owner(o))) continue;
            const known = self.has(o.name);
            if (!known) {
                nat.deleted = true;
                o.enabled = false;
            }
        }
    }
};

/// The engine's roles granted or taken (dispatch.setRole) to match the
/// party and the world's battle as they are now: after a hero joins or leaves the party
/// (HERO_EnableEnumerate, SETHERO), the party is applied (a new location, a return), a
/// save is applied, a battle's fighters enter or it ends. Every object in world order,
/// losses before grants.
pub fn syncRoles(w: *World) !void {
    try syncRolesIn(w, if (w.battle) |*b| b else null);
}

/// `syncRoles` with battle `battle` (the roster's, before it is the world's; null: none).
/// Hero: a hero of the party (World.party), or a fighter on the heroes' side of a battle
/// not over yet (an ally outside the party: the singer on the barge, only while it lasts).
/// Enemy: a fighter on the enemies' side of such a battle. Classic: bits nobody reads (it
/// attaches no component to tell).
pub fn syncRolesIn(w: *World, battle: ?*Battle) !void {
    const b = if (battle) |x| if (x.phase == .won or x.phase == .lost) null else x else null;
    const party = w.party();
    for (w.rt.objects.items) |o| {
        const side = if (b) |x| if (x.fighterOf(o)) |i| x.fighters.items[i].side else null else null;
        const hero = std.mem.indexOfScalar(*Object, party.slice(), o) != null or side == .hero;
        const enemy = side == .enemy;
        inline for (.{ false, true }) |on| {
            if (hero == on) try dispatch.setRole(&w.rt, o, .hero, on);
            if (enemy == on) try dispatch.setRole(&w.rt, o, .enemy, on);
        }
    }
}
