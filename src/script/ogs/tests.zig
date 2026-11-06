//! OGS run end to end in the runtime: named and optional arguments, components with
//! params on a host, namespaces, the statements and values only OGS has, run-time
//! faults, the examples (their non-battle parts: each handler is called by hand here), Classic code
//! imported, printed as OGS and read back to the same IR, and the whole
//! program linked at once (the data blocks against the schema:
//! `tests/script.zig`).

const std = @import("std");
const testing = std.testing;
const Runtime = @import("../runtime.zig").Runtime;
const object = @import("../object.zig");
const Object = object.Object;
const Value = @import("../value.zig").Value;
const ir = @import("../ir.zig");
const ogs_print = @import("print.zig");
const ogs_parser = @import("parser.zig");

const NoSources = struct {
    fn fetch(_: *anyopaque, _: []const u8) anyerror!?[]const u8 {
        return null;
    }
};

/// A builtin that records its call (`name(args…)`) and returns its first argument.
const Log = struct {
    lines: std.ArrayList(u8) = .empty,

    fn record(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
        _ = rt;
        const log: *Log = @ptrCast(@alignCast(ctx));
        try log.lines.print(testing.allocator, "{s}:", .{self.name});
        for (args) |a| try log.lines.print(testing.allocator, " {f}", .{a});
        try log.lines.append(testing.allocator, '\n');
        return if (args.len > 0) args[0] else .zero;
    }
};

fn setup(rt: *Runtime, log: *Log) !void {
    var dummy: u8 = 0;
    rt.* = .init(testing.allocator, .{ .ctx = &dummy, .fetch = NoSources.fetch });
    try rt.registerBuiltin("Note", log, Log.record);
    try rt.registerBuiltinSig("FighterSetTarget", log, Log.record, .{ .ogs = "fighter::SetTarget" });
    try rt.registerBuiltinSig("BattleAddVar", log, Log.record, .{ .ogs = "battle::AddVar" });
    try rt.registerBuiltinSig("FighterAddState", log, Log.record, .{ .text = "int(fighter f, string state, ?int turns)", .ogs = "fighter::AddState" });
}

/// A Classic-like host object with typed variables.
fn host(rt: *Runtime, name: []const u8, vars: []const struct { []const u8, Value }) !*Object {
    const cls = try rt.arena().create(object.Class);
    cls.* = .{ .name = "host.s", .parent = null };
    const o = try rt.createObject(name, cls);
    // A fighter, as the battle makes them (`x is Fighter`, `param fighter`).
    o.kind = @import("../traits.zig").ofHost("fighter");
    for (vars) |v| try o.declare(rt.arena(), v[0], .{ .type = switch (v[1]) {
        .int => .int,
        .float => .float,
        else => .string,
    }, .value = v[1] });
    return o;
}

fn call(rt: *Runtime, o: *Object, name: []const u8, args: []const Value) !Value {
    return (try rt.callIfExists(o, name, args)).?;
}

test "OGS: named and optional arguments, namespaces, loops, lists, maps, strings" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.loadOgs("lib.ogs",
        \\module lib {
        \\    fn scale(x, by: int = 2, plus = by + 1) { return x * by + plus; }
        \\}
    );
    try rt.loadOgs("main.ogs",
        \\use lib;
        \\component Calc {
        \\    fn run() {
        \\        var total = scale(10) + scale(10, by: 3) + lib::scale(1, plus: 0, by: 5);
        \\        var n = 0;
        \\        while (true) { n += 1; if (n < 5) continue; break; }
        \\        for i in 0..4 { if (i == 3) break; total += i; }
        \\        var words = "";
        \\        for w in ["a", "b"] words = words + w;
        \\        var m = {"k": 7, 2: "two"};
        \\        Note(words, m["k"], m[2], m["none"], [1, 2][1], 7 % 4, nil == nil, 1 == 1.0, "1" == 1);
        \\        return total + n;
        \\    }
        \\    // Comparisons and logic give bool; no `return` gives nil.
        \\    fn bools() { return [(1 < 2) == true, 2 <= 1, nil or 5, not 0, 1 and "", true == 1]; }
        \\    fn none() { var x = 1; }
        \\    fn bare() { return; }
        \\}
    );
    const h = try host(&rt, "h", &.{});
    const c = try rt.attach(h, (try rt.ogs.component(rt.arena(), null, "Calc")).?, &.{});
    // 10*2+3 + 10*3+4 + 1*5+0 + (0+1+2) + 5.
    try testing.expectEqual(Value{ .int = 23 + 34 + 5 + 3 + 5 }, try call(&rt, c, "run", &.{}));
    // Builtins see the host as the caller.
    try testing.expectEqualStrings("h: \"ab\" 7 \"two\" nil 2 3 true true false\n", log.lines.items);
    var bools: std.Io.Writer.Allocating = .init(rt.arena());
    try bools.writer.print("{f}", .{try call(&rt, c, "bools", &.{})});
    try testing.expectEqualStrings("[true, false, true, true, false, false]", bools.written());
    try testing.expectEqual(Value.nil, try call(&rt, c, "none", &.{}));
    try testing.expectEqual(Value.nil, try call(&rt, c, "bare", &.{}));
    // Case-sensitive: `Run` is not `run`.
    try testing.expectEqual(null, try rt.callIfExists(c, "Run", &.{}));
}

test "OGS components: params over defaults, host fields, self and @refs, faults" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.loadOgs("c.ogs",
        \\module abilities {
        \\    component Counter for fighter {
        \\        param int step = 1 "Шаг";
        \\        param string tag = "x";
        \\        var int count = step * 10;
        \\        fn bump(times = 1) { for i in 0..times count += step; host.hp -= step; return self.count; }
        \\        fn other() { return @rival.hp + host.hp; }
        \\        fn bad() { return host.hp + "s"; }
        \\        fn twice() { return self.bump(times: 2); }
        \\    }
        \\}
    );
    const h = try host(&rt, "hero", &.{.{ "hp", .{ .int = 100 } }});
    _ = try host(&rt, "rival", &.{.{ "hp", .{ .int = 5 } }});
    const comp = (try rt.ogs.component(rt.arena(), null, "abilities::Counter")).?;
    try testing.expectEqualStrings("fighter", comp.hosts[0]);
    try testing.expectEqualStrings("Шаг", comp.fields[0].doc);
    const c = try rt.attach(h, comp, &.{.{ .name = "step", .value = .{ .float = 3.7 } }});
    try testing.expectEqual(c, h.components.items[0]);
    // `step` converts to int 3; `count`'s default sees it.
    try testing.expectEqual(3, c.getInt("step"));
    try testing.expectEqual(30, c.getInt("count"));
    try testing.expectEqual(Value{ .int = 36 }, try call(&rt, c, "bump", &.{.{ .int = 2 }}));
    try testing.expectEqual(97, h.getInt("hp"));
    try testing.expectEqual(Value{ .int = 42 }, try call(&rt, c, "twice", &.{}));
    try testing.expectEqual(94, h.getInt("hp"));
    try testing.expectEqual(Value{ .int = 5 + 94 }, try call(&rt, c, "other", &.{}));
    try testing.expectError(error.ScriptFault, call(&rt, c, "bad", &.{}));
    try testing.expectEqualStrings("c.ogs", rt.fault.file);
    try testing.expectEqual(8, rt.fault.line);
    // A param it lacks.
    try testing.expectError(error.ScriptFault, rt.attach(h, comp, &.{.{ .name = "nope", .value = .zero }}));
    // Link errors name the file and line.
    try testing.expectError(error.LinkError, rt.loadOgs("e.ogs", "fn f() {\n return g(); }"));
    try testing.expectEqualStrings("e.ogs", rt.diag.file);
    try testing.expectEqual(2, rt.diag.line);
}

test "OGS data blocks: fields onto a host, attach with params by namespace" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.loadOgs("examples.ogs", ogs_print.examples);
    try rt.loadOgs("grandma.ogs",
        \\module characters {
        \\    fighter grandma {
        \\        hp = 200; footprint_tiles = 4;
        \\        attach Rage(below_pct = 30);
        \\        attach Avenger(avenger = @kid);
        \\    }
        \\}
    );
    const kid = try host(&rt, "kid", &.{});
    const g = try host(&rt, "grandma", &.{.{ "hp", .{ .int = 1 } }});
    const m = for (rt.ogs.modules.items) |*m| {
        if (std.mem.eql(u8, m.path, "characters")) break m;
    } else unreachable;
    try rt.applyEntity(g, m, m.entities[0]);
    // A declared variable keeps its type; a new one holds what it is given.
    try testing.expectEqual(Value{ .int = 200 }, g.getVar("hp").?.value);
    try testing.expectEqual(Value{ .int = 4 }, g.getVar("footprint_tiles").?.value);
    try testing.expectEqual(2, g.components.items.len);
    try testing.expectEqual(30, g.components.items[0].getInt("below_pct"));
    try testing.expectEqual(kid, Object.of(g.components.items[1].getVar("avenger").?.value.ref));
    // The other param at its default.
    try testing.expectEqualStrings("grandma_kids", g.components.items[1].getString("counter"));
}

test "OGS: the brief's examples run, events called by hand" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.loadOgs("examples.ogs", ogs_print.examples);
    const P = struct {
        fn comp(r: *Runtime, n: []const u8) !*const ir.Component {
            return (try r.ogs.component(r.arena(), null, n)).?;
        }
    };
    const granny = try host(&rt, "grandma", &.{ .{ "hp", .{ .int = 40 } }, .{ "max_hp", .{ .int = 100 } }, .{ "side", .{ .string = "enemy" } }, .{ "alive", .{ .int = 1 } } });
    const kid = try host(&rt, "kid", &.{ .{ "hp", .{ .int = 10 } }, .{ "max_hp", .{ .int = 10 } }, .{ "side", .{ .string = "enemy" } } });

    // Invulnerable: two own turns of no damage.
    const inv = try rt.attach(kid, try P.comp(&rt, "Invulnerable"), &.{});
    _ = try call(&rt, inv, "OnSpawn", &.{});
    try testing.expectEqual(2, inv.getInt("left"));
    _ = try call(&rt, inv, "OnTurnStart", &.{ .{ .string = "hero" }, .{ .int = 1 } });
    try testing.expectEqual(Value{ .int = 0 }, try call(&rt, inv, "OnHit", &.{ .nil, .nil, .{ .int = 9 } }));
    _ = try call(&rt, inv, "OnTurnStart", &.{ .{ .string = "enemy" }, .{ .int = 1 } });
    _ = try call(&rt, inv, "OnTurnStart", &.{ .{ .string = "enemy" }, .{ .int = 2 } });
    try testing.expectEqual(Value{ .int = 9 }, try call(&rt, inv, "OnHit", &.{ .nil, .nil, .{ .int = 9 } }));

    // Rage: below half hp the strike is doubled (a float: the caller truncates it).
    const rage = try rt.attach(granny, try P.comp(&rt, "Rage"), &.{});
    try testing.expectEqual(Value{ .float = 14 }, try call(&rt, rage, "OnStrike", &.{ .nil, .nil, .{ .int = 7 } }));
    granny.getVar("hp").?.value = .{ .int = 60 };
    try testing.expectEqual(Value{ .int = 7 }, try call(&rt, rage, "OnStrike", &.{ .nil, .nil, .{ .int = 7 } }));

    // Avenger: the kid's death sets granny on the killer and counts.
    const av = try rt.attach(kid, try P.comp(&rt, "Avenger"), &.{.{ .name = "avenger", .value = granny.ref() }});
    _ = try call(&rt, av, "OnDeath", &.{.{ .string = "Sullivan" }});
    _ = try call(&rt, av, "OnDeath", &.{.nil});
    // GrandmaRage: the counter reaching 2.
    const gr = try rt.attach(granny, try P.comp(&rt, "GrandmaRage"), &.{});
    _ = try call(&rt, gr, "OnVar", &.{ .{ .string = "grandma_kids" }, .{ .int = 1 } });
    _ = try call(&rt, gr, "OnVar", &.{ .{ .string = "grandma_kids" }, .{ .int = 2 } });
    try testing.expectEqualStrings(
        \\kid: "grandma" "Sullivan"
        \\kid: "grandma_kids" 1
        \\kid: "grandma_kids" 1
        \\grandma: "grandma" "rage" 99
        \\
    , log.lines.items);
}

test "OGS: a builtin takes an object as its name, `any` as it is; a handler error faults" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    const Fails = struct {
        fn f(_: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
            return error.NoSuchThing;
        }
    };
    try rt.registerBuiltinSig("Who", &log, Log.record, .{ .text = "int(string who, any keep)" });
    try rt.registerBuiltinSig("Fails", &log, Fails.f, .{ .text = "int()" });
    try rt.loadOgs("r.ogs",
        \\component R {
        \\    fn names() { Who(host, host); Who(@"h"); Who(self); return Who(host.name); }
        \\    fn fails() { return Fails(); }
        \\}
    );
    const c = try rt.attach(try host(&rt, "h", &.{}), (try rt.ogs.component(rt.arena(), null, "R")).?, &.{});
    _ = try call(&rt, c, "names", &.{});
    // `host`, `@"h"` and the instance (`self`: its host) reach it as `host.name` does.
    try testing.expectEqualStrings("h: \"h\" @h\nh: \"h\"\nh: \"h\"\nh: \"h\"\n", log.lines.items);
    try testing.expectError(error.ScriptFault, call(&rt, c, "fails", &.{}));
    try testing.expectEqualStrings("Fails: NoSuchThing", rt.fault.message);
}

test "OGS: a bool builtin answers bool in OGS, int 1/0 in Classic; OGS true/false reach it as 1/0" {
    const Src = struct {
        fn fetch(_: *anyopaque, name: []const u8) anyerror!?[]const u8 {
            if (std.ascii.eqlIgnoreCase(name, "y.s")) return "function c() { return(Yes(7) + Yes(0)); };";
            return null;
        }
    };
    var dummy: u8 = 0;
    var log: Log = .{};
    var rt: Runtime = .init(testing.allocator, .{ .ctx = &dummy, .fetch = Src.fetch });
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.registerBuiltinSig("Yes", &log, Log.record, .{ .text = "bool(int)" });
    try rt.registerBuiltinSig("Keep", &log, Log.record, .{ .text = "any(any)" });
    try rt.loadOgs("b.ogs",
        \\component B {
        \\    fn o() { return [Yes(7) == true, Yes(0), Yes(true), Keep(true)]; }
        \\}
    );
    const c = try rt.attach(try host(&rt, "h", &.{}), (try rt.ogs.component(rt.arena(), null, "B")).?, &.{});
    var out: std.Io.Writer.Allocating = .init(rt.arena());
    try out.writer.print("{f}", .{try call(&rt, c, "o", &.{})});
    try testing.expectEqualStrings("[true, false, true, true]", out.written());
    try testing.expectEqualStrings("h: 7\nh: 0\nh: 1\nh: true\n", log.lines.items);
    const y = try rt.createObject("y", try rt.loadClass("y.s"));
    try testing.expectEqual(Value{ .int = 1 }, try call(&rt, y, "c", &.{}));
}

test "OGS step 5: Classic code imported, printed as OGS, read back to the same IR" {
    const Src = struct {
        fn fetch(_: *anyopaque, name: []const u8) anyerror!?[]const u8 {
            if (std.ascii.eqlIgnoreCase(name, "x.s")) return
            \\int state; float speed;
            \\function init(string who, int n)
            \\{
            \\    int k; float f;
            \\    if (n > 1.5 && HeroInArea("a")) { int only; only = 2; state = only; };
            \\    else if (!n) state = -n + who; else { speed = speed * 2 / 3 - 0.25; };
            \\    if (n) { int late; } else late = 3;
            \\    late = 4;
            \\    Slavsky = this;
            \\    k = s_stricmp(who, "x") == 0 || n != 2 || n <= 1;
            \\#include missing.ss
            \\    return(PlaySound("a", 800) + k);
            \\};
            ;
            return null;
        }
    };
    var dummy: u8 = 0;
    var rt: Runtime = .init(testing.allocator, .{ .ctx = &dummy, .fetch = Src.fetch });
    defer rt.deinit();
    const cls = try rt.loadClass("x.s");
    const f = try rt.compiled(cls.functions.get(object.findName("init").?).?);
    var aw: std.Io.Writer.Allocating = .init(rt.arena());
    try ogs_print.function(&aw.writer, f, 0);
    var diag: ogs_parser.Diagnostic = .{};
    const u = ogs_parser.parse(rt.arena(), aw.written(), "x.s", &diag) catch |err| {
        std.debug.print("{s}\nline {d}: {s}\n", .{ aw.written(), diag.line, diag.message });
        return err;
    };
    if (!ogs_print.same(ir.Fn, f.*, u.modules[0].fns[0].*)) {
        std.debug.print("{s}\n", .{aw.written()});
        return error.NotSame;
    }
    try testing.expect(std.mem.indexOf(u8, aw.written(), "classic::name(\"late\") = 3;") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "classic::maybe(\"late\") = 4;") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "classic::fail(\"ScriptNotFound\", \"missing.ss\"") != null);
}

test "OGS: all texts parsed, then linked; a text that fails to link is left out whole" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    // The hook calls a function of a text added after it (the engine's order: hooks first).
    try rt.addOgs("hooks.ss", "component Hooks for game { fn OnTurnStart(side, turn) { return abilities::twice(turn); } }");
    // Linked before the text that fails: its warning is given once, not at every retry.
    try rt.addOgs("warn.ss", "component W for fighter { fn OnHitt(attacker, weapon, amount) { return amount; } }");
    // Fails to link; the text after it calls its helper, so it goes too.
    try rt.addOgs("broken.ss", "fn helper() { return 1; } component Broken for game { fn OnTurnStart(side, turn) { return nope(); } }");
    try rt.addOgs("uses_broken.ss", "component AlsoOut for game { fn f() { return helper(); } }");
    try rt.addOgs("abilities.ss", "module abilities { fn twice(x) { return x * 2; } }");
    var dropped: usize = 0;
    while (true) {
        rt.linkOgs() catch {
            dropped += 1;
            continue;
        };
        break;
    }
    try testing.expectEqual(2, dropped);
    try testing.expectEqual(1, rt.ogs.warnings.items.len);
    try testing.expect(rt.ogs.components.get("Broken") == null);
    try testing.expect(rt.ogs.components.get("AlsoOut") == null);
    const hooks = rt.ogs.components.get("Hooks").?;
    const g = try host(&rt, "game", &.{});
    const c = try rt.attach(g, hooks, &.{});
    try testing.expectEqual(Value{ .int = 6 }, try call(&rt, c, "OnTurnStart", &.{ .{ .string = "hero" }, .{ .int = 3 } }));
}

test "OGS traits: method tables, virtual calls in defaults, super, T::f, is/as/get/all" {
    // The script faults (and missing rows) this test makes on purpose log warnings: not
    // shown, as `zig build test` prints a test binary's stderr under "failed command".
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.registerBuiltinSig("FighterDamage", &log, Log.record, .{ .text = "int(string who, int amount, ?string kind, ?string from)", .ogs = "fighter::Damage" });
    try rt.registerBuiltinSig("FighterPopup", &log, Log.record, .{ .text = "int(string who, string text)", .ogs = "fighter::Popup" });
    try rt.loadOgs("abilities.ogs", ogs_print.traits_example);
    const P = struct {
        fn comp(r: *Runtime, n: []const u8) !*const ir.Component {
            return (try r.ogs.component(r.arena(), null, n)).?;
        }
    };
    const hero = try host(&rt, "hero", &.{ .{ "hp", .{ .int = 40 } }, .{ "side", .{ .string = "hero" } } });
    const foe = try host(&rt, "foe", &.{});
    // The default `absorb` asks the component's `capacity` and `spend` (virtual).
    const es = try rt.attach(hero, try P.comp(&rt, "abilities::EnergyShield"), &.{});
    try testing.expectEqual(Value{ .int = 0 }, try call(&rt, es, "absorb", &.{.{ .int = 15 }}));
    try testing.expectEqual(5, es.getInt("charge"));
    try testing.expectEqual(Value{ .int = 5 }, try call(&rt, es, "OnHit", &.{ .nil, .nil, .{ .int = 10 } }));
    // Reflective.OnHit: super.OnHit is Shielded's, the reflected part goes to the attacker.
    const ms = try rt.attach(hero, try P.comp(&rt, "abilities::MirrorShield"), &.{});
    try testing.expectEqual(Value{ .int = 2 }, try call(&rt, ms, "OnHit", &.{ foe.ref(), .nil, .{ .int = 12 } }));
    try testing.expectEqualStrings("hero: \"foe\" 5 \"reflect\" \"hero\"\n", log.lines.items);
    // Two defaults: the component's own absorb calls both by their path.
    const bw = try rt.attach(hero, try P.comp(&rt, "abilities::Bulwark"), &.{});
    try testing.expectEqual(Value{ .int = 0 }, try call(&rt, bw, "absorb", &.{.{ .int = 10 }}));
    try testing.expectEqual(Value{ .int = 3 }, try call(&rt, bw, "absorb", &.{.{ .int = 10 }}));
    // The table: own methods, then the defaults taken (with their trait).
    const t = rt.ogs.tables.get(try P.comp(&rt, "abilities::MirrorShield")).?;
    try testing.expectEqual(5, t.methods.len);
    try testing.expectEqualStrings("Reflective", t.methods[3].from.?.name);
    try testing.expect(rt.ogs.tables.get(try P.comp(&rt, "abilities::Medic")).?.roles.contains(.hero));
    // Queries: the instances implementing a trait, in attachment order.
    const bg = try rt.attach(foe, try P.comp(&rt, "abilities::Bodyguard"), &.{.{ .name = "ward", .value = hero.ref() }});
    try testing.expectEqual(hero, Object.of(bg.getVar("ward").?.value.ref));
    try testing.expectEqual(Value{ .int = 0 }, try call(&rt, bg, "guard", &.{hero.ref()}));
    _ = try call(&rt, bg, "OnTurnStart", &.{ .{ .string = "hero" }, .{ .int = 1 } });
    // Every shield of the ward is spent; it has no Hero role.
    try testing.expectEqualStrings("hero: \"foe\" 5 \"reflect\" \"hero\"\n" ++ "foe: \"hero\" \"empty\"\n" ++ "foe: \"hero\" \"empty\"\n" ++ "foe: \"hero\" \"empty\"\n", log.lines.items);
    try testing.expect(rt.isTrait(hero.ref(), .{ .script = rt.ogs.traits.get("abilities::Armored").? }));
    try testing.expect(!rt.isTrait(foe.ref(), .{ .script = rt.ogs.traits.get("abilities::Armored").? }));
    // A param of a trait: an object that is not it gives nil; a parameter faults.
    const bg2 = try rt.attach(hero, try P.comp(&rt, "abilities::Bodyguard"), &.{.{ .name = "ward", .value = foe.ref() }});
    try testing.expectEqual(Value.nil, bg2.getVar("ward").?.value);
    try testing.expectError(error.ScriptFault, call(&rt, bg2, "guard", &.{foe.ref()}));
    try testing.expectEqualStrings("guard: x is not Shielded", rt.fault.message);
    try testing.expectError(error.ScriptFault, call(&rt, bg2, "wrong", &.{}));
    try testing.expectEqualStrings("Shielded::absorb: self is not Shielded", rt.fault.message);
    // A role: the host's own (the engine grants it); `for Hero` is active only meanwhile.
    const med = try rt.attach(foe, try P.comp(&rt, "abilities::Medic"), &.{});
    try testing.expect(med.for_roles.contains(.hero) and !med.activeOn(foe));
    try testing.expect(!rt.isTrait(foe.ref(), .{ .engine = "Hero" }));
    foe.roles = .initOne(.hero);
    try testing.expect(rt.isTrait(foe.ref(), .{ .engine = "Hero" }) and rt.isTrait(med.ref(), .{ .engine = "Hero" }));
    // The engine's traits are the program's first text.
    try testing.expectEqualStrings("engine.ogs", rt.ogs.texts.items[0].file);
}

test "OGS traits: link errors, one per message" {
    const two = "trait Shielded: foundation::Fighter { fn absorb(amount) { return amount; } } trait Armored: foundation::Fighter { fn absorb(amount) { return 0; } } ";
    const bad = [_]struct { []const u8, []const u8 }{
        .{ "trait Shielded: foundation::Fighter { fn capacity(); } component EnergyShield for fighter : Shielded { }", "EnergyShield: no capacity() (required by Shielded)" },
        .{ "trait Shielded: foundation::Fighter { fn absorb(amount); } component EnergyShield for fighter : Shielded { fn absorb(a, b) { return a; } }", "EnergyShield.absorb takes 1 parameter (as Shielded.absorb), not 2" },
        .{ two ++ "component Bulwark for fighter : Shielded, Armored { }", "Bulwark: absorb has defaults in Shielded and Armored: define it" },
        .{ two ++ "component Bulwark for fighter : Shielded, Armored { fn absorb(amount) { return super.absorb(amount); } }", "super.absorb: defaults in Shielded and Armored: write Shielded::absorb(self, …)" },
        .{ two ++ "component C for fighter : Shielded { fn other(amount) { return super.absorb(amount); } }", "super.absorb outside a method that overrides absorb" },
        .{ "component C for fighter { fn OnHit(attacker, weapon) { return 0; } }", "OnHit takes 3 parameters (attacker, weapon, amount), not 2" },
        .{ "trait Explodes { fn OnDeath(killer) { } }", "trait Explodes: OnDeath is an engine event: name the host (trait Explodes: foundation::Fighter)" },
        .{ "component Lexemes { fn OnHit(attacker, weapon, amount) { return amount; } }", "Lexemes: OnHit is an engine event: name the host (for fighter)" },
        .{ "trait T { var x; }", "a trait has no state (var): only param and fn" },
        .{ "trait T: foundation::Fighter { fn f() { return charge; } }", "a trait has no fields: charge (add fn charge(); and define it in the component)" },
        .{ "component C : foundation::Hero { }", "Hero is a role the engine grants: write for Hero" },
        .{ "trait Shielded: foundation::Fighter { } component EnergyShield for level : Shielded { }", "EnergyShield for level: Shielded is for fighter" },
        .{ "component C for Hero { fn inventory() { return []; } }", "inventory is the engine's (Hero): a component can't define it" },
        .{ "component Greedy for fighter { fn OnSpawn() { var xs = host.inventory(); } }", "host.inventory(): host is fighter, inventory is Hero's (if (host is foundation::Hero) host.as(foundation::Hero).inventory())" },
        .{ "module Shielded { fn f() { return 1; } } trait Shielded { }", "Shielded is both a trait and a module" },
        .{ "module abilities { trait Shielded { } trait Shielded { } }", "trait abilities::Shielded is defined twice" },
        .{ "trait A: B { } trait B: A { }", "trait A: a trait can't be its own supertrait (A: B: A)" },
        .{ "component Rage for fighter { } component C for fighter { fn f() { return host.get(Rage); } }", "get(Rage): Rage is a component, not a trait" },
        .{ "native fn f();", "native is the engine's (engine.ogs)" },
        // The engine's names (foundation's), a role's host, `get` of a role.
        .{ "component C for fighter : Fighter { }", "no trait Fighter (Fighter is foundation's: write foundation::Fighter, or use foundation;)" },
        .{ "component C for fighter { fn f() { return host is Hero; } }", "no trait Hero (Hero is foundation's: write foundation::Hero, or use foundation;)" },
        .{ "module foundation { fn f() { return 1; } }", "foundation: reserved package" },
        .{ "component C for fighter, Hero { }", "Hero already means fighter" },
        .{ "component C for fighter { fn f() { return host.all(foundation::Hero); } }", "all(foundation::Hero): a role is not a component trait (host.as(foundation::Hero))" },
    };
    for (bad) |b| {
        var rt: Runtime = undefined;
        var log: Log = .{};
        try setup(&rt, &log);
        defer rt.deinit();
        if (rt.loadOgs("t.ogs", b[0])) |_| {
            std.debug.print("loaded: {s}\n", .{b[0]});
            return error.TestExpectedError;
        } else |_| {}
        try testing.expectEqualStrings(b[1], rt.diag.message);
    }
    // 7: a warning, the text loads.
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    try rt.loadOgs("w.ogs", "component C for fighter { fn OnHitt(attacker, weapon, amount) { return amount; } fn OnHelper() { } }");
    try testing.expectEqual(1, rt.ogs.warnings.items.len);
    try testing.expectEqualStrings("OnHitt: no event of fighter (OnHit?)", rt.ogs.warnings.items[0].message);
    // Its parts, for the editor's own words.
    try testing.expectEqualStrings("OnHitt fighter OnHit", try std.mem.join(rt.arena(), " ", &rt.ogs.warnings.items[0].parts));
}

test "OGS types: struct values, enums, list<T>, trait params; the test project's Reinforcements spawn on turns 3 and 5" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.registerBuiltinSig("BattleSpawnEnemy", &log, Log.record, .{ .text = "any(character fighter, int x, int y)", .ogs = "battle::SpawnEnemy" });
    try rt.addOgs("base.ogs", @embedFile("../../tests/og/port/src/components/base.ogs"));
    try rt.addOgs("Reinforcements.ogs", @embedFile("../../tests/og/port/src/components/Reinforcements.ogs"));
    try rt.addOgs("t.ogs",
        \\use foundation;
        \\module characters { fighter grandma_child { } }
        \\battle b {
        \\    attach Reinforcements(waves = [Wave(turn = 3, spawn = [Spawn(who = ~c"characters::grandma_child", tile = [5, 2])]), Wave(turn = 5, side = enemy, spawn = [Spawn(who = ~c"characters::grandma_child", tile = [4, 2]), Spawn(who = ~c"characters::grandma_child", tile = [3, 2])]), Wave(when = turn_end, turn = 1, side = hero, spawn = [])]);
        \\}
        \\trait Paced { param int every = 2 "Every"; fn due(n) { return n % every == 0; } }
        \\component Slow : Paced { param int every = 3; }
        \\component Fast : Paced { }
        \\component Values {
        \\    param Side side = Side::hero;
        \\    fn run() {
        \\        var w = Wave(turn = 2, spawn = []);
        \\        return [Side::enemy, Side::from("hero"), Side::from("nobody"), w.turn, w.side, w.when, side == Side::hero, Side::civilian != w.side];
        \\    }
        \\}
    );
    try rt.linkOgs();
    const lv = try host(&rt, "b", &.{});
    const m = for (rt.ogs.modules.items) |*x| {
        if (x.entities.len > 0 and std.mem.eql(u8, x.entities[0].name, "b")) break x;
    } else return error.NoBlock;
    try rt.applyEntity(lv, m, m.entities[0]);
    const r = lv.components.items[0];
    for (1..7) |turn| for ([_][]const u8{ "hero", "enemy" }) |side| {
        _ = try call(&rt, r, "OnTurnStart", &.{ .{ .string = side }, .{ .int = @intCast(turn) } });
    };
    try testing.expectEqualStrings(
        \\b: "characters::grandma_child" 5 2
        \\b: "characters::grandma_child" 4 2
        \\b: "characters::grandma_child" 3 2
        \\
    , log.lines.items);
    // A struct's value, an enum's: its name.
    const v = try rt.attach(lv, rt.ogs.components.get("Values").?, &.{});
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{f}", .{try call(&rt, v, "run", &.{})});
    try testing.expectEqualStrings("[\"enemy\", \"hero\", nil, 2, \"enemy\", \"turn_start\", true, true]", aw.written());
    // A trait's param: its implementers', the default overridden by one.
    const slow = try rt.attach(lv, rt.ogs.components.get("Slow").?, &.{});
    const fast = try rt.attach(lv, rt.ogs.components.get("Fast").?, &.{.{ .name = "every", .value = .{ .int = 5 } }});
    try testing.expectEqual(Value{ .int = 3 }, slow.getVar("every").?.value);
    try testing.expectEqual(Value{ .bool = true }, try call(&rt, fast, "due", &.{.{ .int = 10 }}));
    try testing.expectEqual(Value{ .bool = false }, try call(&rt, slow, "due", &.{.{ .int = 10 }}));
}

test "OGS foundation: the engine's names by their prefix or `use foundation;`, a project's own beside them" {
    var rt: Runtime = undefined;
    var log: Log = .{};
    try setup(&rt, &log);
    defer rt.deinit();
    defer log.lines.deinit(testing.allocator);
    try rt.loadOgs("t.ogs",
        \\enum Side { left, right }
        \\trait Enemy { fn threat(); }
        \\module own {
        \\    use foundation;
        \\    component U for fighter : Monitor { param Side s = Side::enemy; fn f() { return [s, Side::hero, host is Fighter, Place(who = "a").who]; } }
        \\}
        \\component P for fighter : foundation::Monitor, Enemy {
        \\    param foundation::Side side = foundation::Side::hero;
        \\    fn threat() { return 1; }
        \\    fn f() { return [Side::left, side, foundation::Side::from("civilian"), host is foundation::Fighter, host is Enemy, foundation::Place(who = "b").who]; }
        \\}
        \\level l { attach own::U(s = civilian); attach P(side = enemy); }
    );
    const h = try host(&rt, "h", &.{});
    const u = try rt.attach(h, rt.ogs.components.get("own::U").?, &.{.{ .name = "s", .value = .{ .string = "civilian" } }});
    const pc = try rt.attach(h, rt.ogs.components.get("P").?, &.{});
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{f} {f}", .{ try call(&rt, u, "f", &.{}), try call(&rt, pc, "f", &.{}) });
    try testing.expectEqualStrings("[\"civilian\", \"hero\", true, \"a\"] [\"left\", \"hero\", \"civilian\", true, true, \"b\"]", aw.written());
    // The engine's mark and the project's trait of the engine's role's name.
    const t = rt.ogs.tables.get(rt.ogs.components.get("P").?).?;
    try testing.expect(for (t.traits) |r| {
        if (r == .engine and std.mem.eql(u8, r.engine, "Monitor")) break true;
    } else false);
    const own = for (t.traits) |r| {
        if (r == .script) break r.script;
    } else null;
    try testing.expectEqual(rt.ogs.traits.get("Enemy").?, own.?);
}

test "OGS types: link errors" {
    const types = "enum Side2 { a, b } enum Trigger { start \"Start\", } struct Wave { Trigger when = Trigger::start; int turn; list<int> tile = [] \"Tile\"; } ";
    const bad = [_]struct { []const u8, []const u8 }{
        .{ "fn f() { return Wave(turn = 1, nope = 2); }", "Wave takes when, turn, tile" },
        .{ "fn f() { return Wave(); }", "Wave needs turn" },
        .{ "fn f() { return Wave(1); }", "Wave: a struct takes named fields (f = v)" },
        .{ "fn f() { return Wave(turn = \"x\"); }", "Wave.turn: expected int" },
        .{ "fn f() { return Wave(turn = 1, tile = [1, \"a\"]); }", "Wave.tile: expected int" },
        .{ "fn f() { return Wave(turn = 1, when = Side2::a); }", "Wave.when: expected Trigger, not Side2::a" },
        .{ "fn f() { return Side2::a == Trigger::start; }", "comparing Side2 with Trigger" },
        .{ "fn f() { return Side2::a == 1; }", "comparing Side2 with a number" },
        .{ "fn f() { return Side2::a < Side2::b; }", "Side2: an enum compares with == and != only" },
        .{ "fn f() { return Side2::a == \"a\"; }", "comparing Side2 with a string" },
        .{ "fn f(x: string) { return x != Side2::b; }", "comparing Side2 with a string" },
        .{ "component C { param Side2 s = Side2::a; param string n = \"\"; fn f() { return s == n; } }", "comparing Side2 with a string" },
        .{ "component C for Battle { }", "C for Battle: a host kind is lowercase: write for battle" },
        .{ "component C for Fighter { }", "C for Fighter: a host kind is lowercase: write for fighter" },
        .{ "struct S { character who; } fn f() { return S(who = \"grandma\"); }", "S.who: expected character (~c\"…\")" },
        .{ "struct S { character who; } fn f() { return S(who = ~l\"x\"); }", "S.who: expected character (~c\"…\")" },
        .{ "struct S { character who; } fn f() { return S(who = 3); }", "S.who: expected character (~c\"…\")" },
        .{ "component R for level { param character c; } level l { attach R(c = nope::x); }", "c: expected character (~c\"…\"), not nope::x" },
        .{ "fn f() { return Side2::c; }", "Side2 has no value c" },
        .{ "fn f() { return Nope::c; }", "no enum Nope (write Nope::c(…) to call)" },
        // The engine's types are foundation's: code names them so, or uses it.
        .{ "fn f() { return Side::enemy; }", "no enum Side (Side is foundation's: write foundation::Side, or use foundation;)" },
        .{ "component C { param Side s; }", "no type Side (Side is foundation's: write foundation::Side, or use foundation;)" },
        .{ "fn f() { return Place(who = \"a\"); }", "unknown function Place (Place is foundation's: write foundation::Place, or use foundation;)" },
        .{ "fn f() { return Side2::from(); }", "Side2::from takes one argument (the value's name)" },
        .{ "component C { fn f() { return Wave(turn = 1, when = start); } }", "Wave.when: write Trigger::start" },
        .{ "component C { param list<Wave> ws = [Wave(turn = 1), 2]; }", "C.ws: expected Wave" },
        .{ "component R for level { param Wave w; } level l { attach R(w = Wave(turn = 1, when = stop)); }", "w: Wave.when: Trigger has no value stop" },
        .{ "struct S { int x; int x; }", "field x declared twice" },
        .{ "struct S { x; }", "expected the field's type and name" },
        .{ "struct S { fn f() { } }", "a struct is data: no fn" },
        .{ "enum E { a, a }", "value a declared twice" },
        .{ "struct Side2 { int x; }", "Side2 is defined twice" },
        .{ "trait T { param int n = 1; } component C : T { var n; }", "C: n is a param of T" },
    };
    for (bad) |b| {
        var rt: Runtime = undefined;
        var log: Log = .{};
        try setup(&rt, &log);
        defer rt.deinit();
        const src = try std.mem.concat(rt.arena(), u8, &.{ types, b[0] });
        if (rt.loadOgs("t.ogs", src)) |_| {
            std.debug.print("loaded: {s}\n", .{b[0]});
            return error.TestExpectedError;
        } else |_| {}
        testing.expectEqualStrings(b[1], rt.diag.message) catch |err| {
            std.debug.print("{s}\n", .{b[0]});
            return err;
        };
    }
}
