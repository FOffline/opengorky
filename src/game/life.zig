//! World lifecycle: location creation (its source, map, objects, heroes, party,
//! init/restore, battle) and its ticks. Sits above state/world.zig, which holds only data
//! and small helpers, and calls the world, scene, inventory and combat subsystems. The
//! location's files come through a `core.source.Factory` the client gives (composition:
//! loaders/world.zig `Opener`).

const std = @import("std");
const num = @import("../num.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const Value = @import("../script.zig").value.Value;
const fields = @import("../fields.zig");
const core_source = @import("../core.zig").source;
const audio_sound = @import("../audio.zig").sound;
const actor_mod = @import("../actor.zig");
const model_cache = @import("../actor.zig").model_cache;
const motion = @import("../actor/motion.zig");
const popup_mod = @import("../popup.zig");
const immunity_mod = @import("../battle.zig").immunity;
const roster = @import("../combat.zig").roster;
const party_mod = @import("../world.zig").party;
const inventory = @import("../inventory.zig");
const scenes = @import("../scene.zig").scenes;
const sources = @import("../world.zig").sources;
const start = @import("../world.zig").start;
const levels = @import("../world.zig").levels;
const actions = @import("../world.zig").actions;
const spawn = @import("../world.zig").spawn;
const queue = @import("../world.zig").queue;
const bitmap_anim = @import("../world.zig").bitmap_anim;
const hooks = @import("../state.zig").hooks;

/// Longest file name asked of the source (an archive entry name).
const name_max = 112;

pub const Options = struct {
    /// Heroes and their items from the party (coming from another location).
    party: ?*const party_mod.Party = null,
    /// Needed at start already: a factory post_init calls GO_RunFun("04_city", …).
    resolver: ?World.Resolver = null,
    /// Selected hero, already during init/restore (GUI_GetSelectedHero: only he enters
    /// 01_port_worker; DisableHeroes hides the rest).
    hero: ?[]const u8 = null,
    /// The game's discovered immunities (game.Game); null = the world's own (gorky-tool runs).
    immunity: ?*immunity_mod.Known = null,
    /// Creation events run as their lifted model (`Runtime.lift`); false: as code.
    lift: bool = true,
};

/// New world for location `level_name`, its files opened by `worlds`.
pub fn create(io: Io, gpa: Allocator, worlds: core_source.Factory, level_name: []const u8, models: ?*model_cache.Cache, opts: Options) !*World {
    const party = opts.party;
    const w = try gpa.create(World);
    errdefer gpa.destroy(w);
    const source = try worlds.openLevel(gpa, level_name);
    errdefer source.deinit();
    w.* = .{
        .gpa = gpa,
        .io = io,
        .arena_state = .init(gpa),
        .rt = .init(gpa, .{ .ctx = w, .fetch = sources.fetchSource }),
        .level_name = undefined,
        .res = .{ .source = source, .scenes = source.scenes, .models = models },
        .immunity = opts.immunity orelse &w.own_immunity,
    };
    w.rt.lift = opts.lift;
    // The source closes via the errdefer above; free only what follows.
    errdefer w.deinitScripts();
    w.level_name = try w.arena_state.allocator().dupe(u8, level_name);
    // The defaults before a hero is selected: the campaign's leader (the exe's Sullivan).
    w.selected_hero = try w.arena_state.allocator().dupe(u8, @import("../rules.zig").campaign().leader);
    w.scene.last_action_hero = w.selected_hero;
    try @import("../builtins.zig").registerBuiltins(w);
    try hooks.load(w);
    const a = w.arena_state.allocator();
    w.map = try source.loadMap(a);
    w.path_scripts = try a.alloc(?*Object, w.map.paths.len);
    @memset(w.path_scripts, null);
    w.resolver = opts.resolver;
    try start.createObjects(w);
    try start.createHeroes(w);
    if (party) |p| try p.createMissingHeroes(w);
    if (opts.hero) |h| w.setSelectedHero(h);
    // As in the exe (0x431830): party heroes are global objects with current fields
    // already during the new location's restore(); restore() changes to heroes
    // (05__lab_group3: FighterSetHp("Sullivan", hp/2)) persist. So the party is applied
    // between init() and restore().
    try start.startInit(w);
    // The party's roles (Party.apply grants them; a new game's heroes).
    if (party) |p| try p.apply(w, true) else try party_mod.syncRoles(w);
    try start.startRestore(w);
    inventory.equipment.refreshHoldStates(w);
    // The location's models up front (its objects'; one a script names later loads then).
    if (models) |ms| for (w.rt.objects.items) |o| ms.preload(fields.meshFile(o));
    if (w.isCombat() and w.map.combat != null) w.battle = try roster.init(w);
    try levels.afterSelectGui(w);
    w.battle_music = battleMusic(w);
    try hooks.levelEnter(w);
    return w;
}

/// Battle music, drawn at level load like the exe (0x41f9b0…0x41fab3) so every host
/// consumes the same rand(): the level's own `<name>.mp3` or a district's shared music
/// means no draw; a boss level plays ExeMusic `boss`; else one of `battle` by
/// `rand() % count` (the exe's 0 `battle`, 1 `battle2`). (The exe's [0x54c465] flag,
/// never set by the game, forces `battle`.)
fn battleMusic(w: *World) ?[]const u8 {
    var buf: [2][]const u8 = undefined;
    if (!w.isCombat() or audio_sound.musicCandidates(w.level_name, &buf).len > 1) return null;
    own: {
        var name_buf: [name_max]u8 = undefined;
        const file = std.fmt.bufPrint(&name_buf, "{s}.mp3", .{w.level_name}) catch break :own;
        if (w.res.source.hasVoice(file)) return null;
    }
    const m = @import("../core.zig").modules.ui().music;
    if (w.level.?.getInt("boss") != 0) return m.boss;
    var n: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, m.battle, ' ');
    while (it.next()) |_| n += 1;
    if (n == 0) return null;
    var k = w.crt().below(n);
    it.reset();
    while (it.next()) |t| : (k -= 1) if (k == 0) return t;
    unreachable;
}

/// The item's animation (box lid) reached its last frame.
fn itemAnimDone(self: *World, o: *Object) bool {
    const a = world_mod.actorOf(o);
    const ms = self.res.models orelse return true;
    const m = ms.get(fields.meshFile(o)) orelse return true;
    const an = m.anims.find(a.anim) orelse return true;
    return a.anim_ticks >= num.toF32(an.last - an.first + 1);
}

/// Object tick, after battle and scenes (whole tick: game.tick).
pub fn tickObjects(self: *World) !void {
    if (self.act.pending_explore) |*pe| {
        if (pe.ticks > 0) pe.ticks -= 1 else if (itemAnimDone(self, pe.box)) {
            const box = pe.box;
            const hero = pe.hero;
            self.act.pending_explore = null;
            if (box.enabled and !World.nativeOf(box).deleted and self.act.exploring == null) try inventory.box.exploreBox(self, box, hero);
        }
    }
    spawn.aimFlames(self);
    spawn.releaseRemoved(self);
    spawn.aimBalls(self);
    self.effects.tick(self.gpa, self.crt());
    // EARTHQUAKE (0x4205b0, 0x420b62): screen offset 0..5 px when strength > 10, else 0..3;
    // strength drops by 1 per frame.
    if (self.out.earthquake > 0) {
        const r = self.crt();
        const m: u32 = if (self.out.earthquake > 10) 6 else 4;
        self.out.shake = .{ @floatFromInt(r.below(m)), @floatFromInt(r.below(m)) };
        self.out.earthquake -= 1;
    } else self.out.shake = .{ 0, 0 };
    var i: usize = 0;
    var watch = false;
    while (i < self.rt.objects.items.len) : (i += 1) {
        const o = self.rt.objects.items[i];
        const n = World.nativeOf(o);
        if (!o.enabled or n.deleted) continue;
        switch (n.kind) {
            .animation => bitmap_anim.updateAnimation(self, o, n),
            .active_animation => bitmap_anim.updateActiveAnimation(self, o, n),
            .actor => {
                const model = if (self.res.models) |m| m.get(fields.meshFile(o)) else null;
                // Frozen: animation stops (0x48e940 → +0x245bc, 0x44fae0).
                n.actor.anim_paused = if (self.battle) |*b| b.isFrozen(o) else false;
                motion.tick(&n.actor, o, model, self.actorScale() * if (model) |m| m.unitScale() else 24, self.crt());
                if (model) |m| if (n.actor.placed) try queue.animCues(self, o, &n.actor, m);
                if (n.actor.bind) |*bd| try spawn.tickBind(self, o, &n.actor, bd, model);
                // An idle hero outside scenes doesn't step in place (paths are reset by floor
                // changes, path nodes and stops).
                if (n.hero and !self.scene.cutscene and self.scene.runner == null and self.battle == null and !n.actor.busy() and
                    n.actor.loop and n.actor.anim.len > 0 and std.mem.eql(u8, n.actor.anim, n.actor.resolve(n.actor.walk_anim)))
                    n.actor.stopWalking(self.crt());
                if (n.actor.morph_due) {
                    n.actor.morph_due = false;
                    try @import("../combat.zig").states.morphDone(self, o);
                }
                if (n.actor.fx_sound) |snd| {
                    n.actor.fx_sound = null;
                    self.out.sound(self.gpa, snd, self.screenPos(o));
                }
                if (n.actor.node_event) |ev| {
                    n.actor.node_event = null;
                    try nodeEvent(self, o, ev);
                }
                try queue.runQueue(self, o, &n.actor);
            },
            else => {},
        }
        if (n.kind.hooks().update) {
            _ = try self.rt.callIfExistsC(o, "update", &.{});
            _ = try hooks.on(self, o, "Level.OnUpdate", &.{});
        }
        try start.updateVisibility(self, o);
        if (n.kind == .area and (o.implementsC("OnEnter") or o.implementsC("OnLeave"))) watch = true;
    }
    // OpenGorky: after every object moved, the areas' OnEnter/OnLeave (only when some
    // area has one).
    if (watch) for (self.rt.objects.items) |o| {
        if (World.nativeOf(o).kind == .area and o.enabled and (o.implementsC("OnEnter") or o.implementsC("OnLeave"))) try areaEvents(self, o);
    };
}

/// Area `o`'s Area.OnEnter(hero) / OnLeave(hero) for each party hero (in panel order) who
/// walked into or out of its polygon since the last tick (placed heroes, as HeroInArea).
/// shortcut: one who left the party while inside is forgotten without OnLeave; upgrade if
/// a script needs it.
fn areaEvents(self: *World, o: *Object) !void {
    const n = World.nativeOf(o);
    const poly = @import("../world.zig").areas.findArea(self, o.getString("areaName"));
    const p = self.party();
    var now: [12]?*Object = @splat(null);
    for (p.slice(), 0..) |h, i| {
        if (!h.enabled or !world_mod.actorOf(h).placed) continue;
        const at = self.screenPos(h);
        if (poly) |a| if (@import("../core.zig").map.areaContains(a, at[0], at[1])) {
            now[i] = h;
        };
    }
    const was = n.inside;
    n.inside = now;
    for (p.slice(), 0..) |h, i| {
        const before = std.mem.indexOfScalar(?*Object, &was, h) != null;
        if (before == (now[i] != null)) continue;
        var args = [_]Value{h.ref()};
        _ = try if (before) hooks.on(self, o, "Area.OnLeave", &args) else hooks.on(self, o, "Area.OnEnter", &args);
    }
}

/// Scene, fade, subtitles, attached actors — after the object tick.
pub fn tickPresentation(self: *World) !void {
    for (self.actorObjects()) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor) continue;
        if (n.actor.vibrato[0] != 0) {
            n.actor.render_offset[2] = @sin(n.actor.vibrato_phase) * n.actor.vibrato[0];
            n.actor.vibrato_phase += n.actor.vibrato[1];
        }
    }
    for (self.actorObjects()) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor) continue;
        const parent = n.actor.attached_to orelse continue;
        const pm = if (self.res.models) |m| m.get(fields.meshFile(parent)) else null;
        motion.followParent(&n.actor, o, self.actorScale() * if (pm) |m| m.unitScale() else 24, world_mod.actorOf(parent).angle_offset);
        // Attached actors sway with their parent (0x4cdbd0: + parent offset).
        n.actor.render_offset = world_mod.actorOf(parent).render_offset;
    }
    try actions.runInteraction(self);
    // Item animations (Item_Animation).
    for (self.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if ((n.kind == .item or n.kind == .weapon) and n.actor.anim.len > 0) n.actor.anim_ticks += 1;
    }
    self.scene.tickLine();
    {
        var i: usize = 0;
        while (i < self.out.delayed_sounds.items.len) {
            const d = &self.out.delayed_sounds.items[i];
            if (d.ticks > 0) {
                d.ticks -= 1;
                i += 1;
                continue;
            }
            self.out.sound(self.gpa, d.name, d.pos);
            _ = self.out.delayed_sounds.orderedRemove(i);
        }
    }
    popup_mod.tickAll(&self.popups);
    try scenes.tickRockets(self);
}

/// Path script `<name>.pth`, loaded at the first node.
fn pathScript(self: *World, index: u16) !?*Object {
    if (index >= self.map.paths.len) return null;
    if (self.path_scripts[index]) |o| return o;
    // OpenGorky: the level block's `path <name>` (world/start.zig pathBlock).
    if (self.res.source.level_block.len > 0) {
        const o = try @import("../world.zig").start.pathBlock(self, self.map.paths[index].name) orelse return null;
        self.path_scripts[index] = o;
        return o;
    }
    var buf: [name_max]u8 = undefined;
    const file = std.fmt.bufPrint(&buf, "{s}.pth", .{self.map.paths[index].name}) catch return null;
    if (!self.res.source.levelHas(file)) return null;
    const cls = self.rt.loadClass(file) catch |err| {
        try self.classMissing(file, err);
        return null;
    };
    const o = try self.addObject(file, cls, .{ .kind = .other });
    self.path_scripts[index] = o;
    return o;
}

/// A path node was passed: NodeResponse(no, dir) with this actor.
fn nodeEvent(self: *World, o: *Object, ev: actor_mod.command.NodeEvent) !void {
    const script = try pathScript(self, ev.path) orelse return;
    self.node_actor = o;
    self.node_cur = ev;
    defer self.node_actor = null;
    defer self.node_cur = null;
    _ = try self.rt.callIfExists(script, "NodeResponse", &.{ .{ .int = ev.no }, .{ .int = ev.dir } });
    var args = [_]Value{ .{ .int = ev.no }, .{ .int = ev.dir }, o.ref() };
    _ = try hooks.on(self, script, "Path.OnNode", &args);
}
