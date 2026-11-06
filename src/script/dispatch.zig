//! A built-in method (traits.zig) called on hosts' attached components
//! (`Object.components`, runtime.attach): within a host its active components in attach
//! order, then the next host (most specific first: weapon, attacker, target, battle or
//! level, game), the results joined by the method's `Combine`. A component without the
//! method is skipped, and so is a nil result (no `return`, `return;`): only a value
//! returned changes anything. A handler that faults (an OGS run-time error) is logged and
//! changes nothing. A host none of whose active components implements the method
//! (`Object.implements`) costs one bit. A native component (an ability in
//! Zig, `Runtime.attachNative`) stands in the same list: it answers the methods its bits
//! name through `Runtime.native_components`, the others pass it by.
//! shortcut: a fault is logged at every call, not once per place; upgrade when a faulting
//! handler in a long battle floods the log.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const traits = @import("traits.zig");

/// Method `m` on `host`'s components with `args` (see chainHosts).
pub fn call(rt: *Runtime, host: *Object, m: *const traits.Method, args: []Value) error{OutOfMemory}!?Value {
    return chainHosts(rt, &.{host}, m, args);
}

/// Grants (`on`) or takes away role `role` of `host` (the engine's
/// points: combat/events.zig syncRoles). Granted: the mask, then OnRoleGained("Hero") to
/// the components active now (a `for Hero` one among them); taken: OnRoleLost to those
/// active still, then the mask. No change: nothing.
pub fn setRole(rt: *Runtime, host: *Object, role: traits.Role, on: bool) error{OutOfMemory}!void {
    if (host.roles.contains(role) == on) return;
    var arg = [_]Value{.{ .string = role.name() }};
    if (!on) _ = try call(rt, host, traits.method("Fighter.OnRoleLost"), &arg);
    host.roles.setPresent(role, on);
    host.refreshImplements();
    if (on) _ = try call(rt, host, traits.method("Fighter.OnRoleGained"), &arg);
}

/// Method `m` on each host's components in turn with `args` (a chain's last argument
/// replaced in place as it goes). The answer: `all` the last handler's result; `chain`
/// the last value; `veto` false at the first false, else true; `first` the first result;
/// `handled` true at the first true, else false; `sum` the ints added. Null when no
/// handler answers (every one returns nil or none is there): the engine's own answer.
pub fn chainHosts(rt: *Runtime, hosts: []const *Object, m: *const traits.Method, args: []Value) error{OutOfMemory}!?Value {
    // Its mask bit (a native has none: nothing implements it).
    const b = m.bit orelse return null;
    var any = false;
    var last: Value = .nil;
    var sum: i32 = 0;
    for (hosts) |host| {
        if (!host.implements.isSet(b)) continue;
        for (host.components.items) |c| {
            if (!c.activeOn(host)) continue;
            const r = if (c.class.native == null) rt.callIfExistsId(c, m.name_id, m.name, args) else if (c.class.marks.isSet(b)) rt.callNative(c, m.name, args) else continue;
            const v = (r catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ScriptFault => {
                    std.log.warn("{f} ({s}.{s})", .{ rt.fault, c.name, m.name });
                    continue;
                },
                else => {
                    std.log.warn("{s}.{s}: {t}", .{ c.name, m.name, err });
                    continue;
                },
            }) orelse continue;
            if (v == .nil) continue;
            any = true;
            switch (m.combine) {
                .all => last = v,
                // Every chain method's value is an int.
                .chain => args[m.valueArg()] = .{ .int = v.toInt() },
                .veto => if (!v.truth()) return .{ .bool = false },
                .first => return v,
                .handled => if (v.truth()) return .{ .bool = true },
                .sum => sum +%= v.toInt(),
            }
        }
    }
    if (!any) return null;
    return switch (m.combine) {
        .all, .first => last,
        .chain => args[m.valueArg()],
        .veto => .{ .bool = true },
        .handled => .{ .bool = false },
        .sum => .{ .int = sum },
    };
}

/// A runtime with `src` loaded and a host object of no class (the tests').
const Fixture = struct {
    rt: Runtime,
    cls: *@import("object.zig").Class,

    fn fetch(_: *anyopaque, _: []const u8) anyerror!?[]const u8 {
        return null;
    }

    fn init(f: *Fixture, src: []const u8) !void {
        f.rt = .init(std.testing.allocator, .{ .ctx = f, .fetch = fetch });
        try f.rt.loadOgs("t.ogs", src);
        f.cls = try f.rt.arena().create(@import("object.zig").Class);
        f.cls.* = .{ .name = "f.s", .parent = null };
    }

    /// A host with components `names` attached in order.
    fn host(f: *Fixture, names: []const []const u8) !*Object {
        const h = try f.rt.createObject("h", f.cls);
        for (names) |n| _ = try f.rt.attach(h, (try f.rt.ogs.component(f.rt.arena(), null, n)).?, &.{});
        return h;
    }
};

test "dispatch: in order, values chained, queries stop at false, faults and nil skipped" {
    // The script faults (and missing rows) this test makes on purpose log warnings: not
    // shown, as `zig build test` prints a test binary's stderr under "failed command".
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const testing = std.testing;
    var fx: Fixture = undefined;
    try fx.init(
        \\component Half for fighter { fn OnHit(a, w, amount) { return amount / 2; } fn CanWalk() { return true; } }
        \\component Plus for fighter { param int by = 1; fn OnHit(a, w, amount) { return amount + by; } fn CanWalk() { return false; } }
        \\component Bad for fighter { fn OnHit(a, w, amount) { return amount + "x"; } }
        \\component Quiet for fighter { var int n = 0; fn OnSpawn() { n += 1; } fn OnHit(a, w, amount) { if (amount > 100) return 0; } fn CanWalk() { } }
    );
    defer fx.rt.deinit();
    const rt = &fx.rt;
    const on_hit = traits.method("Fighter.OnHit");
    const can_walk = traits.method("Fighter.CanWalk");
    const h = try fx.host(&.{});
    var args = [_]Value{ .nil, .nil, .{ .int = 9 } };
    try testing.expectEqual(null, try call(rt, h, on_hit, &args));
    for ([_][]const u8{ "Half", "Bad", "Plus", "Quiet" }) |n| _ = try rt.attach(h, (try rt.ogs.component(rt.arena(), null, n)).?, if (std.mem.eql(u8, n, "Plus")) &.{.{ .name = "by", .value = .{ .int = 3 } }} else &.{});
    try testing.expect(h.implementsC("OnHit") and h.implementsC("OnSpawn") and !h.implementsC("OnDeath"));
    // 9 / 2 = 4, Bad faults (skipped), + 3.
    try testing.expectEqual(Value{ .int = 7 }, (try call(rt, h, on_hit, &args)).?);
    try testing.expectEqual(Value{ .int = 7 }, args[2]);
    try testing.expectEqual(Value{ .bool = false }, (try call(rt, h, can_walk, &.{})).?);
    _ = try call(rt, h, traits.method("Fighter.OnSpawn"), &.{});
    try testing.expectEqual(1, h.components.items[3].getInt("n"));
    try testing.expectEqual(null, try call(rt, h, traits.method("Fighter.CanBeStruck"), &args));
    // Quiet alone: its OnHit and CanWalk return nil, so nothing changes and nobody answers.
    const q = try fx.host(&.{"Quiet"});
    args[2] = .{ .int = 9 };
    try testing.expectEqual(null, try call(rt, q, on_hit, &args));
    try testing.expectEqual(Value{ .int = 9 }, args[2]);
    try testing.expectEqual(null, try call(rt, q, can_walk, &.{}));
}

test "dispatch: each rule — nil changes nothing, a fault is skipped, the stop rules stop" {
    // The script faults (and missing rows) this test makes on purpose log warnings: not
    // shown, as `zig build test` prints a test binary's stderr under "failed command".
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const testing = std.testing;
    var fx: Fixture = undefined;
    // Per rule: Nil answers nothing, Bad faults, then the answers.
    try fx.init(
        \\component Nil for fighter, item { var int n = 0; fn OnSpawn() { n += 1; } fn ExtraAction() { } fn CanWalk() { } fn OnUse(u, t) { } fn TurnPriority(s) { } fn OnHit(a, w, x) { } }
        \\component Bad for fighter, item { fn OnSpawn() { return 1 + "x"; } fn ExtraAction() { return 1 + "x"; } fn CanWalk() { return 1 + "x"; } fn OnUse(u, t) { return 1 + "x"; } fn TurnPriority(s) { return 1 + "x"; } fn OnHit(a, w, x) { return 1 + "x"; } }
        \\component One for fighter, item { var int n = 0; fn OnSpawn() { n += 1; return 5; } fn ExtraAction() { return 0; } fn CanWalk() { return 1; } fn OnUse(u, t) { return 0; } fn TurnPriority(s) { return 2; } fn OnHit(a, w, x) { return x * 3; } }
        \\component Two for fighter, item { var int n = 0; fn OnSpawn() { n += 1; } fn ExtraAction() { return true; } fn CanWalk() { return false; } fn OnUse(u, t) { n += 1; return true; } fn TurnPriority(s) { return 3; } fn OnHit(a, w, x) { return x + 1; } }
        \\component Three for fighter, item { var int n = 0; fn ExtraAction() { n += 1; } fn CanWalk() { n += 1; return 1; } fn OnUse(u, t) { n += 1; } }
    );
    defer fx.rt.deinit();
    const rt = &fx.rt;
    const quiet = try fx.host(&.{ "Nil", "Bad" });
    const h = try fx.host(&.{ "Nil", "Bad", "One", "Two", "Three" });
    var no: [2]Value = .{ .nil, .nil };
    // all: every handler runs; the last answer.
    try testing.expectEqual(null, try call(rt, quiet, traits.method("Fighter.OnSpawn"), &.{}));
    try testing.expectEqual(Value{ .int = 5 }, (try call(rt, h, traits.method("Fighter.OnSpawn"), &.{})).?);
    try testing.expectEqual(1, h.components.items[0].getInt("n"));
    try testing.expectEqual(1, h.components.items[3].getInt("n"));
    // chain: 4 * 3 + 1, the argument replaced; nil and the fault leave 4.
    var hit = [_]Value{ .nil, .nil, .{ .int = 4 } };
    try testing.expectEqual(null, try call(rt, quiet, traits.method("Fighter.OnHit"), &hit));
    try testing.expectEqual(Value{ .int = 4 }, hit[2]);
    try testing.expectEqual(Value{ .int = 13 }, (try call(rt, h, traits.method("Fighter.OnHit"), &hit)).?);
    // veto: One's 1 is a yes, Two's false stops (Three not asked).
    try testing.expectEqual(null, try call(rt, quiet, traits.method("Fighter.CanWalk"), &.{}));
    try testing.expectEqual(Value{ .bool = false }, (try call(rt, h, traits.method("Fighter.CanWalk"), &.{})).?);
    try testing.expectEqual(0, h.components.items[4].getInt("n"));
    // first: One's 0 is an answer (not nil): it stops.
    try testing.expectEqual(null, try call(rt, quiet, traits.method("Fighter.ExtraAction"), &.{}));
    try testing.expectEqual(Value{ .int = 0 }, (try call(rt, h, traits.method("Fighter.ExtraAction"), &.{})).?);
    try testing.expectEqual(0, h.components.items[4].getInt("n"));
    // handled: One's 0 is not done, Two's true is (Three not called); nobody true: false.
    try testing.expectEqual(null, try call(rt, quiet, traits.method("Item.OnUse"), &no));
    try testing.expectEqual(Value{ .bool = true }, (try call(rt, h, traits.method("Item.OnUse"), &no)).?);
    try testing.expectEqual(2, h.components.items[3].getInt("n"));
    try testing.expectEqual(0, h.components.items[4].getInt("n"));
    const zero = try fx.host(&.{ "Nil", "One" });
    try testing.expectEqual(Value{ .bool = false }, (try call(rt, zero, traits.method("Item.OnUse"), &no)).?);
    // sum: 2 + 3.
    var side = [_]Value{.nil};
    try testing.expectEqual(null, try call(rt, quiet, traits.method("Fighter.TurnPriority"), &side));
    try testing.expectEqual(Value{ .int = 5 }, (try call(rt, h, traits.method("Fighter.TurnPriority"), &side)).?);
}

test "dispatch: hosts in order, one chain through them; a role's component only while the host has it" {
    const testing = std.testing;
    var fx: Fixture = undefined;
    try fx.init(
        \\component Double for battle, game { fn OnDamage(a, t, w, x) { return x * 2; } fn OnItemUse(u, i, t) { return true; } }
        \\component Plus for battle, game { fn OnDamage(a, t, w, x) { return x + 1; } fn OnItemUse(u, i, t) { return 0; } }
    );
    defer fx.rt.deinit();
    const rt = &fx.rt;
    const battle = try fx.host(&.{"Double"});
    const game = try fx.host(&.{"Plus"});
    var args = [_]Value{ .nil, .nil, .nil, .{ .int = 5 } };
    try testing.expectEqual(Value{ .int = 11 }, (try chainHosts(rt, &.{ battle, game }, traits.method("Battle.OnDamage"), &args)).?);
    args[3] = .{ .int = 5 };
    try testing.expectEqual(Value{ .int = 12 }, (try chainHosts(rt, &.{ game, battle }, traits.method("Battle.OnDamage"), &args)).?);
    var use = [_]Value{ .nil, .nil, .nil };
    try testing.expectEqual(Value{ .bool = true }, (try chainHosts(rt, &.{ game, battle }, traits.method("Game.OnItemUse"), &use)).?);
    // Double for Hero: silent until the host is a hero, then the mask counts it.
    battle.components.items[0].for_roles = .initOne(.hero);
    battle.refreshImplements();
    try testing.expect(!battle.implementsC("OnDamage"));
    args[3] = .{ .int = 5 };
    try testing.expectEqual(Value{ .int = 6 }, (try chainHosts(rt, &.{ battle, game }, traits.method("Battle.OnDamage"), &args)).?);
    battle.roles = .initOne(.hero);
    battle.refreshImplements();
    args[3] = .{ .int = 5 };
    try testing.expectEqual(Value{ .int = 11 }, (try chainHosts(rt, &.{ battle, game }, traits.method("Battle.OnDamage"), &args)).?);
}

test "dispatch: a role granted and taken — its components wake and sleep, each told" {
    const testing = std.testing;
    var fx: Fixture = undefined;
    try fx.init(
        \\component Log for fighter { var string got = ""; fn OnRoleGained(role) { got += "+" + role; } fn OnRoleLost(role) { got += "-" + role; } }
        \\component Medic for Hero { var string got = ""; fn OnRoleGained(role) { got += "+" + role; } fn OnRoleLost(role) { got += "-" + role; } fn OnSpawn() { got += "s"; } }
        \\component Drone for fighter : foundation::Monitor { }
    );
    defer fx.rt.deinit();
    const rt = &fx.rt;
    const h = try fx.host(&.{ "Log", "Medic", "Drone" });
    const spawn = traits.method("Fighter.OnSpawn");
    // A component declaring a mark sets its bit; `for Hero` is silent without the role.
    try testing.expect(h.implementsC("Monitor") and h.implementsC("OnRoleGained"));
    _ = try call(rt, h, spawn, &.{});
    try setRole(rt, h, .enemy, true);
    try setRole(rt, h, .hero, true);
    try setRole(rt, h, .hero, true);
    _ = try call(rt, h, spawn, &.{});
    try setRole(rt, h, .hero, false);
    _ = try call(rt, h, spawn, &.{});
    try testing.expectEqualStrings("+Enemy+Hero-Hero", h.components.items[0].getString("got"));
    try testing.expectEqualStrings("+Heros-Hero", h.components.items[1].getString("got"));
    try testing.expect(h.roles.contains(.enemy) and !h.roles.contains(.hero));
}

test "dispatch: a native component answers in the list's order, only its own methods" {
    // The script faults (and missing rows) this test makes on purpose log warnings: not
    // shown, as `zig build test` prints a test binary's stderr under "failed command".
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const testing = std.testing;
    var fx: Fixture = undefined;
    try fx.init(
        \\component Plus for fighter { fn OnHit(a, w, amount) { return amount + 1; } fn CanWalk() { return true; } }
    );
    defer fx.rt.deinit();
    const rt = &fx.rt;
    const S = struct {
        fn call(_: *Runtime, _: *Object, tag: u8, method: []const u8, args: []Value) anyerror!?Value {
            if (tag == 1) return error.Broken;
            if (std.mem.eql(u8, method, "OnHit")) return .{ .int = args[2].toInt() * 10 };
            return .{ .bool = false };
        }
    };
    var bits: traits.Mask = .empty;
    bits.set(traits.bit("OnHit"));
    bits.set(traits.bit("Monitor"));
    const tenfold: @import("object.zig").Native = .{ .name = "Tenfold", .tag = 0, .bits = bits };
    const broken: @import("object.zig").Native = .{ .name = "Broken", .tag = 1, .bits = bits };
    const on_hit = traits.method("Fighter.OnHit");
    const h = try fx.host(&.{});
    _ = try rt.attachNative(h, &tenfold, null);
    try testing.expect(h.implementsC("Monitor") and h.implementsC("OnHit") and !h.implementsC("CanWalk"));
    var args = [_]Value{ .nil, .nil, .{ .int = 2 } };
    // Without the engine's code it answers nothing.
    try testing.expectEqual(null, try call(rt, h, on_hit, &args));
    rt.native_components = S.call;
    _ = try rt.attachNative(h, &broken, null);
    _ = try rt.attach(h, (try rt.ogs.component(rt.arena(), null, "Plus")).?, &.{});
    // 2 × 10, the broken one skipped, + 1; CanWalk is not the natives' (their false unasked).
    try testing.expectEqual(Value{ .int = 21 }, (try call(rt, h, on_hit, &args)).?);
    try testing.expectEqual(Value{ .bool = true }, (try call(rt, h, traits.method("Fighter.CanWalk"), &.{})).?);
}

test "dispatch: the traits' templates parse, define no method, and are ASCII" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parser = @import("ogs/parser.zig");
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(arena.allocator(), try traits.template(arena.allocator(), "NewAbility"), "abilities.ss", &diag);
    const c = u.modules[0].components[0];
    try std.testing.expectEqualStrings("NewAbility", c.name);
    try std.testing.expectEqual(0, c.methods.len);
    try std.testing.expectEqual(1, c.fields.len);
    for (try traits.template(arena.allocator(), "X")) |ch| try std.testing.expect(ch < 0x80);
    const hooks_template = try traits.hooksTemplate(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, hooks_template, "\n    fn") == null);
    try std.testing.expect(std.mem.indexOf(u8, hooks_template, "// fn OnDamage(attacker, target, weapon, amount) {") != null);
    const h = try parser.parse(arena.allocator(), hooks_template, "hooks.ss", &diag);
    try std.testing.expectEqual(0, h.modules[0].components[0].methods.len);
}
