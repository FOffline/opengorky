//! Object snapshot for moving the party between locations (world/party.zig) and for
//! saves (save.zig): vars, skills, level points; recreating an object from its class.

const std = @import("std");
const state_object = @import("../state.zig").object;
const Allocator = std.mem.Allocator;
const world = @import("../state.zig").world;
const World = world.World;
const start = @import("start.zig");
const object = @import("../script.zig").object;
const Object = object.Object;
const Value = @import("../script.zig").value.Value;
const Runtime = @import("../script.zig").runtime.Runtime;
const fields = @import("../fields.zig");
const inventory = @import("../inventory.zig");

pub const VarCopy = struct { name: []const u8, value: Value };

/// Copies of the object's vars in `a` (`o` of the world `from` tells), except names in
/// `skip` (case-insensitive).
pub fn copyVars(a: Allocator, from: From, o: *Object, skip: []const []const u8) ![]VarCopy {
    var vars: std.ArrayList(VarCopy) = .empty;
    var it = o.vars.iterator();
    outer: while (it.next()) |e| {
        const name = object.nameOf(e.key_ptr.*);
        for (skip) |s| if (std.ascii.eqlIgnoreCase(s, name)) continue :outer;
        try vars.append(a, .{ .name = try a.dupe(u8, name), .value = try detach(a, e.value_ptr.value, from) });
    }
    return vars.items;
}

/// Apply vars (only those the object has), skills and level points.
pub fn restore(w: *World, o: *Object, vars: []const VarCopy, skills: []const state_object.Skill, stat_points: i32) !void {
    try restoreVars(&w.rt, w.level_name, o, vars);
    const nat = World.nativeOf(o);
    nat.growth.skills.clearRetainingCapacity();
    try nat.growth.skills.appendSlice(w.gpa, skills);
    nat.growth.stat_points = stat_points;
}

/// Apply vars to `o` (an object or a component instance of location `here`'s `rt`), only
/// those it has.
fn restoreVars(rt: *Runtime, here: []const u8, o: *Object, vars: []const VarCopy) Allocator.Error!void {
    for (vars) |v| {
        const dst = o.getVarDyn(v.name) orelse continue;
        dst.value = try attach(rt, rt.arena(), v.value, here);
    }
}

/// A component instance's vars (`name`: the component; a save's line `comp`).
pub const CompCopy = struct { name: []const u8, vars: []VarCopy };

/// Copies of the vars of `o`'s component instances that have any. A battle's (a row's
/// scripted abilities) are not kept: they are attached anew in each battle.
pub fn copyComps(a: Allocator, from: From, o: *Object) ![]CompCopy {
    var comps: std.ArrayList(CompCopy) = .empty;
    for (o.components.items) |c| if (c.scope != .battle and c.vars.count() > 0) {
        try comps.append(a, .{ .name = try a.dupe(u8, c.name), .vars = try copyVars(a, from, c, &.{}) });
    };
    return comps.items;
}

/// `copyComps`' vars applied to `o`'s instance of each component (the first of the name);
/// one `o` lacks now is dropped, with a warning when `who` (a save: the code changed) is
/// given (null: as `restoreVars`, quietly: the party, whose objects are made anew in each
/// location from their blocks).
pub fn restoreComps(rt: *Runtime, here: []const u8, o: *Object, comps: []const CompCopy, comptime who: ?[]const u8) Allocator.Error!void {
    for (comps) |sc| for (o.components.items) |c| {
        if (c.scope != .battle and std.mem.eql(u8, c.name, sc.name)) break try restoreVars(rt, here, c, sc.vars);
    } else if (who) |wh| std.log.warn(wh ++ ": {s} has no component {s} (its values are dropped)", .{ o.name, sc.name });
}

/// An `events::Subscribe` (Runtime.subs; a save's line `sub`): instance `inst`
/// (`host#Component`) hears `event` with its method `handler`.
pub const SubCopy = struct { inst: []const u8, event: []const u8, handler: []const u8 };

/// `sb` by names, null: it does not outlive its world: its instance left its host (as
/// Runtime.emit), a battle's, the `game` object's (made with every world: state/hooks.zig).
pub fn copySub(a: Allocator, sb: Runtime.Sub) Allocator.Error!?SubCopy {
    const host = sb.inst.owner.?;
    if (host.host == null or sb.inst.scope == .battle or std.mem.indexOfScalar(*Object, host.components.items, sb.inst) == null) return null;
    const f = sb.inst.class.findFunctionId(sb.handler) orelse return null;
    return .{ .inst = try instanceName(a, sb.inst), .event = try a.dupe(u8, sb.event), .handler = try a.dupe(u8, f.ir.?.name) };
}

/// `subs` subscribed again in their order (after those `rt` has); one of an instance not
/// there, or of a method it lacks now, is dropped with a warning (`who`: a save, the party).
pub fn attachSubs(rt: *Runtime, subs: []const SubCopy, comptime who: []const u8) Allocator.Error!void {
    for (subs) |sb| {
        const inst = findInstance(rt, sb.inst) orelse {
            std.log.warn(who ++ ": no {s} to hear {s} (dropped)", .{ sb.inst, sb.event });
            continue;
        };
        _ = rt.subscribe(inst, sb.event, sb.handler) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.log.warn(who ++ ": {s} cannot hear {s} with {s}: {t} (dropped)", .{ sb.inst, sb.event, sb.handler, err }),
        };
    }
}

/// An object's name, a component instance's `host#Component`.
fn instanceName(a: Allocator, o: *const Object) Allocator.Error![]const u8 {
    const host = o.owner orelse return a.dupe(u8, o.name);
    return std.fmt.allocPrint(a, "{s}#{s}", .{ host.name, o.name });
}

/// The object `instanceName` gave `name` in `rt`: the object of that name (a deleted one
/// too: it is still there), else the first component of that name of the host before `#`.
fn findInstance(rt: *Runtime, name: []const u8) ?*Object {
    if (rt.findObject(name)) |o| return o;
    const at = std.mem.lastIndexOfScalar(u8, name, '#') orelse return null;
    const host = rt.findObject(name[0..at]) orelse return null;
    for (host.components.items) |c| if (std.mem.eql(u8, c.name, name[at + 1 ..])) return c;
    return null;
}

/// The world live references of a value come from (`detach`): its location, and the world
/// itself to tell the objects that go with the party (`w` null: none do).
pub const From = struct { level: []const u8, w: ?*World = null };

/// A copy of `v` in `a` that outlives its world (the party carried, a save): as `Value.dupe`,
/// and a reference keeps only the name of what it refers to (`instanceName`), with its
/// location before `::` (`01_port::ovitz`, a stand-in's `Handle.far` too); a hero's, a
/// hero's item's without one (they are where the party is). `attach` finds it again.
/// `from` null: the references in `v` are names `detach` made.
pub fn detach(a: Allocator, v: Value, from: ?From) Allocator.Error!Value {
    return switch (v) {
        .ref => |h| blk: {
            const c = try a.create(Value.Handle);
            c.* = .{ .name = name: {
                const f = from orelse break :name try a.dupe(u8, h.name);
                if (h.far.len > 0) break :name try std.fmt.allocPrint(a, "{s}::{s}", .{ h.far, h.name });
                const o = Object.of(h);
                const n = try instanceName(a, o);
                if (f.w) |w| if (travels(w, o.owner orelse o)) break :name n;
                break :name try std.fmt.allocPrint(a, "{s}::{s}", .{ f.level, n });
            } };
            break :blk .{ .ref = c };
        },
        .list => |l| .{ .list = try detachAll(a, l, from) },
        .map => |m| blk: {
            const c = try a.create(Value.Map);
            c.* = .{ .keys = try detachAll(a, m.keys, from), .values = try detachAll(a, m.values, from) };
            break :blk .{ .map = c };
        },
        else => v.dupe(a),
    };
}

/// A hero or a hero's item: every location has it (world/party.zig carries it).
pub fn travels(w: *World, o: *Object) bool {
    if (o.host == null) return false; // the `game` object
    const n = World.nativeOf(o);
    return n.hero or n.hro or ownedByHero(w, o);
}

/// Item that travels with the party (0x4adcd0, vtable +0x80): `place > 0` and owned by a
/// hero (flag +0x2cd, 0x4ad2b6), or `place == 200`. Items put on the ground (the gas tank
/// at the rubble, place 0) stay on their location.
pub fn ownedByHero(w: *World, o: *Object) bool {
    const nat = World.nativeOf(o);
    if (nat.kind != .item and nat.kind != .weapon) return false;
    const place = inventory.item.placeOf(o);
    if (place == .party) return true;
    if (@backingInt(place) <= 0) return false;
    const owner = fields.owner(o);
    if (owner.len == 0) return false;
    const h = w.rt.findObject(owner) orelse return false;
    return World.nativeOf(h).hero or World.nativeOf(h).hro;
}

fn detachAll(a: Allocator, xs: []const Value, from: ?From) Allocator.Error![]const Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *d| d.* = try detach(a, x, from);
    return out;
}

/// `detach`'s value as a value of `rt`, the world of location `here` (in `a`): a reference
/// without a location or with `here` is `findInstance` of its name, nothing of that name
/// (the object is not in this world): `nil`; one of another location is its stand-in
/// (`Runtime.farRef`) until the value comes back there.
pub fn attach(rt: *Runtime, a: Allocator, v: Value, here: []const u8) Allocator.Error!Value {
    return switch (v) {
        .ref => |h| blk: {
            const k = std.mem.indexOf(u8, h.name, "::");
            const name = if (k) |i| h.name[i + 2 ..] else h.name;
            if (k) |i| if (!std.ascii.eqlIgnoreCase(h.name[0..i], here)) break :blk try rt.farRef(h.name[0..i], name);
            break :blk if (findInstance(rt, name)) |o| o.ref() else .nil;
        },
        .list => |l| .{ .list = try attachAll(rt, a, l, here) },
        .map => |m| blk: {
            const c = try a.create(Value.Map);
            c.* = .{ .keys = try attachAll(rt, a, m.keys, here), .values = try attachAll(rt, a, m.values, here) };
            break :blk .{ .map = c };
        },
        else => v.dupe(a),
    };
}

fn attachAll(rt: *Runtime, a: Allocator, xs: []const Value, here: []const u8) Allocator.Error![]const Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *d| d.* = try attach(rt, a, x, here);
    return out;
}

/// Recreate a missing object from its class. Actors also get init() and actor hooks as on
/// location start, which registers their animations (otherwise no idle; they step in place).
pub fn recreate(w: *World, name: []const u8, cls: *object.Class, nat: state_object.Native, actor: bool) !*Object {
    const o = try w.addObject(name, cls, nat);
    if (actor) try created(w, o);
    return o;
}

/// A recreated actor's creation events: init() (an OpenGorky object's OnCreate), then its
/// actor hooks.
pub fn created(w: *World, o: *Object) !void {
    _ = try w.rt.callIfExists(o, "init", &.{});
    if (w.block_item != null) _ = try @import("../state.zig").hooks.on(w, o, "Object.OnCreate", &.{});
    try start.actorHooks(w, o);
}

test "references outlive their world: by location and name, nil when gone, far elsewhere" {
    const Src = struct {
        fn fetch(_: *anyopaque, name: []const u8) anyerror!?[]const u8 {
            return if (std.mem.eql(u8, name, "o.s")) "int hp;" else null;
        }
    };
    const gpa = std.testing.allocator;
    var ctx: u8 = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const port: From = .{ .level = "01_port" };
    var old: Runtime = .init(gpa, .{ .ctx = &ctx, .fetch = Src.fetch });
    const grandma = try old.createObject("grandma", try old.loadClass("o.s"));
    _ = try old.createObject("kid", try old.loadClass("o.s"));
    const rage = try old.arena().create(Object);
    rage.* = .{ .name = "Rage", .class = grandma.class, .owner = grandma };
    try grandma.components.append(old.arena(), rage);
    // [{who: @grandma, kids: [@kid]}, @grandma#Rage, nil]
    const rec = try a.create(Value.Map);
    const kids = try a.dupe(Value, &.{old.findObject("kid").?.ref()});
    rec.* = .{ .keys = try a.dupe(Value, &.{ .{ .string = "who" }, .{ .string = "kids" } }), .values = try a.dupe(Value, &.{ grandma.ref(), .{ .list = kids } }) };
    const live: Value = .{ .list = try a.dupe(Value, &.{ .{ .map = rec }, rage.ref(), .nil }) };
    const kept = try detach(a, try detach(a, live, port), null);
    old.deinit(); // the world is gone; the copy holds names only
    const l = kept.list;
    try std.testing.expectEqualStrings("01_port::kid", l[0].map.values[1].list[0].ref.name);
    try std.testing.expectEqualStrings("01_port::grandma#Rage", l[1].ref.name);

    // The location again (a load): grandma (with Rage) is there, the kid is not.
    var rt: Runtime = .init(gpa, .{ .ctx = &ctx, .fetch = Src.fetch });
    defer rt.deinit();
    const g2 = try rt.createObject("Grandma", try rt.loadClass("o.s"));
    const r2 = try rt.arena().create(Object);
    r2.* = .{ .name = "Rage", .class = g2.class, .owner = g2 };
    try g2.components.append(rt.arena(), r2);
    const back = (try attach(&rt, a, kept, "01_Port")).list;
    try std.testing.expectEqual(g2, Object.of(back[0].map.values[0].ref));
    try std.testing.expectEqual(Value.nil, back[0].map.values[1].list[0]);
    try std.testing.expectEqual(r2, Object.of(back[1].ref));
    try std.testing.expectEqual(Value.nil, back[2]);
    // A name without a location (a hero's, an older save's): the object of that name here.
    try std.testing.expectEqual(g2, Object.of((try attach(&rt, a, .{ .ref = &.{ .name = "grandma" } }, "01_port")).ref));

    // Another location (the party carried it on): stand-ins, one per object, though a
    // `grandma` of its own is there; they keep the location through another trip.
    var far: Runtime = .init(gpa, .{ .ctx = &ctx, .fetch = Src.fetch });
    defer far.deinit();
    _ = try far.createObject("grandma", try far.loadClass("o.s"));
    const f1 = try attach(&far, a, kept, "02_sewers");
    const f2 = try attach(&far, a, kept, "02_sewers");
    const fg = f1.list[0].map.values[0].ref;
    try std.testing.expectEqualStrings("01_port", fg.far);
    try std.testing.expect(fg == f2.list[0].map.values[0].ref and Object.of(fg).vars.count() == 0);
    try std.testing.expectEqualStrings("grandma#Rage", f1.list[1].ref.name);
    try std.testing.expect(f1.list[0].map.values[1].list[0] != .nil); // the kid: not known gone
    const again = try detach(a, f1, .{ .level = "02_sewers" });
    try std.testing.expectEqualStrings("01_port::grandma", again.list[0].map.values[0].ref.name);
    // Back home: live again.
    const home = (try attach(&rt, a, again, "01_port")).list;
    try std.testing.expectEqual(g2, Object.of(home[0].map.values[0].ref));
    try std.testing.expectEqual(r2, Object.of(home[1].ref));
}

test "component instances' vars and subscriptions outlive their world by names (the party, a save)" {
    std.testing.log_level = .err; // the dropped component's warning, on purpose
    defer std.testing.log_level = .warn;
    const Src = struct {
        fn fetch(_: *anyopaque, _: []const u8) anyerror!?[]const u8 {
            return null;
        }
    };
    const gpa = std.testing.allocator;
    var ctx: u8 = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const code = "component Pal for fighter { var int n = 0; var who; fn heard() { n += 100; } }";
    var old: Runtime = .init(gpa, .{ .ctx = &ctx, .fetch = Src.fetch });
    const cls = try old.arena().create(object.Class);
    cls.* = .{ .name = "h.s", .parent = null };
    try old.loadOgs("p.ogs", code);
    const hero = try old.createObject("sullivan", cls);
    hero.host = &ctx; // a world object (not the `game` object)
    const pal = try old.attach(hero, old.ogs.components.get("Pal").?, &.{});
    pal.getVar("n").?.value = .{ .int = 3 };
    pal.getVar("who").?.value = hero.ref();
    _ = try old.subscribe(pal, "ping", "heard");
    const comps = try copyComps(a, .{ .level = "01_port" }, hero);
    var subs: std.ArrayList(SubCopy) = .empty;
    for (old.subs.items) |sb| if (try copySub(a, sb)) |c| try subs.append(a, c);
    // A battle's instance (a row's scripted ability) is not kept.
    pal.scope = .battle;
    try std.testing.expectEqual(0, (try copyComps(a, .{ .level = "01_port" }, hero)).len);
    try std.testing.expect(try copySub(a, old.subs.items[0]) == null);
    old.deinit();
    try std.testing.expectEqualStrings("sullivan#Pal", subs.items[0].inst);
    try std.testing.expectEqualStrings("heard", subs.items[0].handler);

    // The next world: the hero with his component again, at its defaults; a component he
    // lacks now is dropped.
    var rt: Runtime = .init(gpa, .{ .ctx = &ctx, .fetch = Src.fetch });
    defer rt.deinit();
    const cls2 = try rt.arena().create(object.Class);
    cls2.* = .{ .name = "h.s", .parent = null };
    try rt.loadOgs("p.ogs", code);
    const h2 = try rt.createObject("Sullivan", cls2);
    h2.host = &ctx;
    const p2 = try rt.attach(h2, rt.ogs.components.get("Pal").?, &.{});
    const more = try a.dupe(CompCopy, &.{ comps[0], .{ .name = "Nope", .vars = &.{} } });
    try restoreComps(&rt, "01_port", h2, more, "test");
    try subs.append(a, .{ .inst = "nobody#Pal", .event = "ping", .handler = "heard" });
    try attachSubs(&rt, subs.items, "test");
    try std.testing.expectEqual(h2, Object.of(p2.getVar("who").?.value.ref));
    try std.testing.expectEqual(1, try rt.emit("ping", &.{}));
    try std.testing.expectEqual(103, p2.getInt("n"));
}
