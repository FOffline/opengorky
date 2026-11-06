//! The saved game as core records: every visited location's script objects with vars,
//! flags and actor state (captured by `addWorld`, applied by game/save_apply.zig). The
//! file (text, save.zig) is written and read by composition (compose/save.zig).

const std = @import("std");
const state_object = @import("../state.zig").object;
const state_groups = @import("../state.zig").groups;
const snapshot = @import("snapshot.zig");
const Allocator = std.mem.Allocator;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Value = @import("../script.zig").value.Value;
const Object = @import("../script.zig").object.Object;
const immunity = @import("../battle.zig").immunity;

const VarCopy = snapshot.VarCopy;

const ObjState = struct {
    name: []const u8,
    class_file: []const u8,
    kind: state_object.Kind,
    enabled: bool,
    deleted: bool,
    placed: bool,
    hero: bool,
    /// IDLE_OFF (+0x30ec): the exe saves it as the Actor property `disableIdleAnims`
    /// (0x46a020 → 0x45fdc0). Flag 16; older saves lack it (off).
    idle_off: bool = false,
    /// IDLE_ANIMATION (+0x30ed, char[16]): the exe saves it as `idleAnimOverride`
    /// (empty = none). Line `idle`; older saves lack it.
    idle_anim: []const u8 = "",
    map: u1,
    state: u8,
    stat_points: i32,
    /// Item model animation (Item_Animation: an opened box) and its direction.
    anim: []const u8 = "",
    anim_reverse: bool = false,
    vars: []VarCopy,
    skills: []state_object.Skill,
    /// Its OGS component instances' vars (line `comp`), by component name.
    comps: []CompState = &.{},
};

const CompState = snapshot.CompCopy;
const SubState = snapshot.SubCopy;

pub const WorldState = struct {
    level: []const u8,
    objects: []ObjState,
    /// Forbid/AllowWalkInArea areas (0x411fa3), replayed on load.
    walk: []state_groups.WalkArea = &.{},
    /// Its subscriptions in subscription order (who hears an event first).
    subs: []SubState = &.{},
};

pub const Save = struct {
    // The records' parts, as the save format (save.zig) reads and writes them.
    pub const Obj = ObjState;
    pub const Var = VarCopy;
    pub const Skill = state_object.Skill;
    pub const Walk = state_groups.WalkArea;
    pub const Comp = CompState;
    pub const Sub = SubState;
    /// `obj` lines with a larger actor state are broken (it indexes the idle tables).
    pub const max_states = @import("../actor.zig").max_states;

    arena: std.heap.ArenaAllocator,
    current: []const u8 = "",
    /// The selected hero (a save without one: the campaign's leader, `init`).
    hero: []const u8 = "",
    /// Save name typed on the save screen (up to 15 chars, case as typed).
    name: []const u8 = "",
    worlds: std.ArrayList(WorldState) = .empty,
    /// Discovered immunities (`imm`), written from the game and applied on load (game.Game)
    /// only after a successful parse.
    imm: [immunity.table.len]u16 = @splat(0),

    pub fn init(gpa: Allocator) Save {
        return .{ .arena = .init(gpa), .hero = @import("../rules.zig").campaign().leader };
    }

    pub fn deinit(self: *Save) void {
        self.arena.deinit();
    }

    pub fn find(self: *Save, level: []const u8) ?*WorldState {
        for (self.worlds.items) |*ws| if (std.ascii.eqlIgnoreCase(ws.level, level)) return ws;
        return null;
    }

    /// Capture a world's state (appended to the save).
    pub fn addWorld(self: *Save, w: *World) !void {
        const a = self.arena.allocator();
        var objs: std.ArrayList(ObjState) = .empty;
        const from: snapshot.From = .{ .level = w.level_name, .w = w };
        for (w.rt.objects.items) |o| {
            const n = World.nativeOf(o);
            if (n.kind == .ambient) continue; // scripts repeat Ambient_New
            const vars = try snapshot.copyVars(a, from, o, &.{});
            try objs.append(a, .{
                .name = try a.dupe(u8, o.name),
                // An OpenGorky project's object: its archetype or block (world/start.zig
                // recreateBlock makes it again on load), not the shared class name `og`.
                .class_file = try a.dupe(u8, o.class.ident orelse o.class.name),
                .kind = n.kind,
                .enabled = o.enabled,
                .deleted = n.deleted,
                .placed = n.actor.placed,
                .hero = n.hero,
                .idle_off = n.actor.idle_off,
                .idle_anim = try a.dupe(u8, n.actor.forced_idle orelse ""),
                .map = n.actor.map,
                .state = n.actor.state,
                .stat_points = n.growth.stat_points,
                .anim = if (n.kind == .item or n.kind == .weapon) try a.dupe(u8, n.actor.anim) else "",
                .anim_reverse = n.actor.reverse,
                .vars = vars,
                .skills = try a.dupe(state_object.Skill, n.growth.skills.items),
                .comps = try snapshot.copyComps(a, from, o),
            });
        }
        var subs: std.ArrayList(SubState) = .empty;
        for (w.rt.subs.items) |sb| if (try snapshot.copySub(a, sb)) |c| try subs.append(a, c);
        const walk = try a.alloc(state_groups.WalkArea, w.walk_areas.items.len);
        for (w.walk_areas.items, walk) |src, *dst| dst.* = .{ .name = try a.dupe(u8, src.name), .allow = src.allow, .floor = src.floor };
        try self.worlds.append(a, .{ .level = try a.dupe(u8, w.level_name), .objects = objs.items, .walk = walk, .subs = subs.items });
    }

    /// A copy of `self` (in `gpa`) as the save file would give it back (`recoverPartyItems`).
    pub fn clone(self: *const Save, gpa: Allocator) !Save {
        var s: Save = .init(gpa);
        errdefer s.deinit();
        const a = s.arena.allocator();
        s.current = try a.dupe(u8, self.current);
        s.hero = try a.dupe(u8, self.hero);
        s.name = try a.dupe(u8, self.name);
        s.imm = self.imm;
        for (self.worlds.items) |ws| try s.addState(ws);
        try s.recoverPartyItems();
        return s;
    }

    /// Copy another location's state from another save.
    pub fn addState(self: *Save, ws: WorldState) !void {
        const a = self.arena.allocator();
        const objs = try a.alloc(ObjState, ws.objects.len);
        for (ws.objects, objs) |src, *dst| {
            dst.* = src;
            dst.name = try a.dupe(u8, src.name);
            dst.class_file = try a.dupe(u8, src.class_file);
            dst.anim = try a.dupe(u8, src.anim);
            dst.idle_anim = try a.dupe(u8, src.idle_anim);
            dst.vars = try copyAll(a, src.vars);
            dst.comps = try a.alloc(CompState, src.comps.len);
            for (src.comps, dst.comps) |c, *d| d.* = .{ .name = try a.dupe(u8, c.name), .vars = try copyAll(a, c.vars) };
            dst.skills = try a.dupe(state_object.Skill, src.skills);
        }
        const walk = try a.alloc(state_groups.WalkArea, ws.walk.len);
        for (ws.walk, walk) |src, *dst| dst.* = .{ .name = try a.dupe(u8, src.name), .allow = src.allow, .floor = src.floor };
        const subs = try a.alloc(SubState, ws.subs.len);
        for (ws.subs, subs) |src, *dst| dst.* = .{ .inst = try a.dupe(u8, src.inst), .event = try a.dupe(u8, src.event), .handler = try a.dupe(u8, src.handler) };
        try self.worlds.append(a, .{ .level = try a.dupe(u8, ws.level), .objects = objs, .walk = walk, .subs = subs });
    }

    /// Hero items lost from the current location in old saves (a class from another
    /// location's archive failed to load). Exe items are global, so a hero's item found in
    /// another location's section moves to the current one if it is missing there and no
    /// section says it was used up or isn't the hero's.
    pub fn recoverPartyItems(self: *Save) !void {
        const cur = self.find(self.current) orelse return;
        const a = self.arena.allocator();
        var add: std.ArrayList(ObjState) = .empty;
        for (self.worlds.items) |*ws| {
            if (ws == cur) continue;
            for (ws.objects) |e| {
                if (e.kind != .item and e.kind != .weapon) continue;
                if (findObj(cur.objects, e.name) != null or findObj(add.items, e.name) != null) continue;
                if (!heldByHero(cur, e)) continue;
                const agreed = for (self.worlds.items) |*other| {
                    const o = findObj(other.objects, e.name) orelse continue;
                    if (o.deleted or !heldByHero(cur, o.*)) break false;
                } else true;
                if (agreed) try add.append(a, e);
            }
        }
        if (add.items.len == 0) return;
        try add.insertSlice(a, 0, cur.objects);
        cur.objects = add.items;
    }
};

fn copyAll(a: Allocator, vars: []const VarCopy) ![]VarCopy {
    const out = try a.alloc(VarCopy, vars.len);
    for (vars, out) |v, *d| d.* = .{ .name = try a.dupe(u8, v.name), .value = try snapshot.detach(a, v.value, null) };
    return out;
}

fn findObj(objs: []ObjState, name: []const u8) ?*ObjState {
    for (objs) |*o| if (std.ascii.eqlIgnoreCase(o.name, name)) return o;
    return null;
}

fn varOf(e: ObjState, name: []const u8) ?Value {
    for (e.vars) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return v.value;
    return null;
}

/// Item in the backpack, hand or worn by a party hero of the current location.
fn heldByHero(cur: *const WorldState, e: ObjState) bool {
    if (e.deleted) return false;
    const owner = varOf(e, "owner") orelse return false;
    const place = varOf(e, "place") orelse return false;
    if (owner != .string or owner.string.len == 0) return false;
    const p: i64 = switch (place) {
        .int => |i| i,
        .float => |f| @import("../script.zig").value.floatToInt(f),
        else => return false,
    };
    if (p <= 0) return false;
    const h = findObj(cur.objects, owner.string) orelse return false;
    return h.hero;
}
