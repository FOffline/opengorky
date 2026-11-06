//! A character's "Extra abilities" (extra abilities) block, a hero's and an enemy's alike:
//! the abilities it has over the ordinary fighter (its Abilities row in force,
//! core/behaviour.zig: its own or its classType's), each with its parameters, "+ ability"
//! to add one, "Remove" to take one away. OpenGorky: every change writes the character's
//! own row (by its classic_id or class: rules_rows.ownKey), a copy of its classType's at first;
//! each ability says where it comes from (its classType's row or its own). Classic: what
//! the exe gives it (core/classic.zig), read only.
//! Scripted abilities (OpenGorky, the row's `scripts`): the project's OGS components `for
//! fighter` (its rules code, `rules.scripts`) listed after the native ones, each with its
//! params as fields (int/float steppers, a bool tick, a fighter picked, a string typed);
//! "+ ability" offers them too, "+ new ability" makes one from the template
//! (trait Fighter, script/traits.zig) in `src/components/<Name>.ogs` and opens it in the code
//! editor (attaching it is "+ ability"'s).

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const tx = @import("text.zig");
const rules_rows = @import("rules_rows.zig");
const preview = @import("preview.zig");
const picker = @import("picker.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;
const behaviour = og.core.behaviour;
const modules = og.core.modules;
const Abilities = behaviour.Abilities;
const Script = behaviour.Script;
const plain = behaviour.plain;
const ir = og.script.ir;
const rules_text = og.loaders.rules_text;
const traitinfo = @import("traitinfo.zig");
const doctabs = @import("doctabs.zig");

/// What an ability's parameters are edited with.
const Kind = enum { flag, level_mode, stand, guard, open_from, arms, pairs, fighter };

/// An ability: its row field (present: not the ordinary fighter's value), label, what it
/// does, the native component it attaches (core/natives.zig).
const Def = struct { field: []const u8, label: tx.Msg, note: tx.Msg, kind: Kind = .flag, native: []const u8 };

const defs = [_]Def{
    .{ .field = "double_turn", .label = tx.ab_double_turn, .note = tx.ab_double_turn_n, .native = "DoubleTurn" },
    .{ .field = "immobile", .label = tx.ab_immobile, .note = tx.ab_immobile_n, .native = "Immobile" },
    .{ .field = "first_in_mode", .label = tx.ab_first, .note = tx.ab_first_n, .kind = .level_mode, .native = "GoesFirst" },
    .{ .field = "stand", .label = tx.ab_stand, .note = tx.ab_stand_n, .kind = .stand, .native = "Stand" },
    .{ .field = "guard", .label = tx.ab_guard, .note = tx.ab_guard_n, .kind = .guard, .native = "Guard" },
    .{ .field = "open_from", .label = tx.ab_open, .note = tx.ab_open_n, .kind = .open_from, .native = "OpenFrom" },
    .{ .field = "arms", .label = tx.ab_arms, .note = tx.ab_arms_n, .kind = .arms, .native = "Arms" },
    .{ .field = "monitor", .label = tx.ab_monitor, .note = tx.ab_monitor_n, .native = "Monitor" },
    .{ .field = "kill_credit", .label = tx.ab_no_credit, .note = tx.ab_no_credit_n, .native = "NoKillCredit" },
    .{ .field = "double_strike", .label = tx.ab_double_strike, .note = tx.ab_double_strike_n, .kind = .pairs, .native = "Pairs" },
    .{ .field = "heals", .label = tx.ab_heals, .note = tx.ab_heals_n, .kind = .fighter, .native = "Heals" },
    .{ .field = "avenger", .label = tx.ab_avenger, .note = tx.ab_avenger_n, .kind = .fighter, .native = "Avenger" },
    .{ .field = "invisible", .label = tx.ab_invisible, .note = tx.ab_invisible_n, .native = "Invisible" },
    .{ .field = "leaves", .label = tx.ab_leaves, .note = tx.ab_leaves_n, .native = "Leaves" },
    .{ .field = "no_push", .label = tx.ab_no_push, .note = tx.ab_no_push_n, .native = "NoPush" },
    .{ .field = "no_hands", .label = tx.ab_no_hands, .note = tx.ab_no_hands_n, .native = "NoHands" },
    .{ .field = "battle_only", .label = tx.ab_battle_only, .note = tx.ab_battle_only_n, .native = "BattleOnly" },
};

/// Row `r` has ability field `n` (not the ordinary fighter's value).
fn has(r: Abilities, comptime n: []const u8) bool {
    const v = @field(r, n);
    return switch (@typeInfo(@TypeOf(v))) {
        .optional => v != null,
        .pointer => v.len > 0,
        else => v != @field(plain, n),
    };
}

/// `r` with ability `n` given its first parameters (`first`: a fighter's object name).
fn added(r: Abilities, comptime n: []const u8, first: []const u8) Abilities {
    var o = r;
    const eq = std.mem.eql;
    if (comptime eq(u8, n, "first_in_mode")) o.first_in_mode = 1 else if (comptime eq(u8, n, "stand")) {
        o.stand = 0;
    } else if (comptime eq(u8, n, "guard")) {
        o.guard = .{ .div = 2, .min = 1, .cone = 0.5 * std.math.pi };
    } else if (comptime eq(u8, n, "open_from")) {
        o.open_from = .{ 0, 1 };
    } else if (comptime eq(u8, n, "arms")) {
        o.arms = .{ .left = .{ -1, 1 }, .right = .{ 1, 1 }, .blocked = "" };
    } else if (comptime eq(u8, n, "heals") or eq(u8, n, "avenger")) {
        @field(o, n) = first;
    } else @field(o, n) = !@field(plain, n);
    return o;
}

/// `r` without ability `n` (the ordinary fighter's value; its parts' too).
fn removed(r: Abilities, comptime n: []const u8) Abilities {
    var o = r;
    @field(o, n) = @field(plain, n);
    if (comptime std.mem.eql(u8, n, "stand")) o.stand_after_move = false;
    if (comptime std.mem.eql(u8, n, "open_from")) o.dodge = "";
    if (comptime std.mem.eql(u8, n, "double_strike")) o.pairs = &.{};
    return o;
}

/// Fighter `w`'s (classType `class`) abilities in force.
fn inForce(w: rules.Who, class: i32) Abilities {
    return modules.abilities(w, class).*;
}

/// The row is one fighter's own (not its classType's).
fn isOwn(r: Abilities) bool {
    return r.fighter != 0 or r.fighter_class.len > 0;
}

/// `r` written as fighter `w`'s own row (one undo step); its classType kept in it.
fn write(app: *App, w: rules.Who, class: i32, r: Abilities) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    var x = rules_rows.ownKey(app, Abilities, "fighter", r, w);
    x.class = class;
    // A row over a built-in one of its key keeps the game's value of a field it leaves out.
    for (modules.builtin_tables.classes) |b| if (og.loaders.codec.sameKey(Abilities, b, x)) inline for (.{ "stand", "guard", "open_from", "arms" }) |n| {
        if (@field(x, n) == null and @field(b, n) != null) return error.GameValueKept;
    };
    try rules_rows.put(app, Abilities, x);
    app.setStatus(tx.st_rule_set, .{ Abilities.call, if (w.class.len > 0) w.class else "?" });
}

/// Character class `class`'s own row, cloned from `r` (a new character from a template).
pub fn ownRow(app: *App, r: Abilities, class: []const u8) !void {
    var x = r;
    x.fighter = 0;
    x.fighter_class = class;
    try rules_rows.put(app, Abilities, x);
}

/// Field `field` of `w`'s own row made `text` (as the rules write it: `--row ENTRY
/// Abilities FIELD VALUE`).
pub fn setField(app: *App, w: rules.Who, class: i32, field: []const u8, text: []const u8) !void {
    try write(app, w, class, try og.loaders.rules_text.withField(app.frame.allocator(), Abilities, inForce(w, class), field, text, &app.rule_why));
}

/// `--ability ENTRY NAME VALUE`: ability NAME (its row field) added (`+`), taken away (`-`)
/// or its field made VALUE (as the rules write it). A scripted one: NAME its component
/// (`+`, `-`), `NAME.param` its param made VALUE (a number, true/false or a "string").
pub fn setAbility(app: *App, w: rules.Who, class: i32, name: []const u8, value: []const u8) !void {
    const cur = inForce(w, class);
    inline for (defs) |d| if (std.mem.eql(u8, name, d.field)) {
        if (std.mem.eql(u8, value, "+")) return write(app, w, class, added(cur, d.field, ""));
        if (std.mem.eql(u8, value, "-")) return write(app, w, class, removed(cur, d.field));
        return setField(app, w, class, name, value);
    };
    const a = app.frame.allocator();
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const comp = try app.catalog.arena.allocator().dupe(u8, name[0 .. dot orelse name.len]);
    if (findComp(components(a), comp) == null) return error.NoSuchAbility;
    const k = for (cur.scripts, 0..) |s, i| {
        if (std.mem.eql(u8, s.component, comp)) break i;
    } else null;
    if (dot) |d| {
        // The value as a param's literal (codec reads it: `Name(param = VALUE)`).
        const lit = try og.loaders.codec.readText(Script, app.catalog.arena.allocator(), try std.fmt.allocPrint(a, "{s}(v = {s})", .{ comp, value }), &app.rule_why);
        return write(app, w, class, try withParam(a, cur, k orelse return error.NoSuchAbility, try app.catalog.arena.allocator().dupe(u8, name[d + 1 ..]), lit.params[0].value));
    }
    if (std.mem.eql(u8, value, "+")) return write(app, w, class, withScripts(cur, try std.mem.concat(a, Script, &.{ cur.scripts, &.{.{ .component = comp }} })));
    if (std.mem.eql(u8, value, "-")) return write(app, w, class, withScripts(cur, try std.mem.concat(a, Script, &.{ cur.scripts[0 .. k orelse return error.NoSuchAbility], cur.scripts[k.? + 1 ..] })));
    return error.NoSuchAbility;
}

/// The placed fighters' object names (the battles' `.ftr`), each once.
fn fighterNames(app: *App, a: Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (app.levels) |lvl| {
        if (!lvl.battle) continue;
        const path = std.fmt.allocPrint(a, "{s}/other.dat", .{lvl.name}) catch continue;
        for (app.store.listing(a, path, null, false)) |fe| {
            if (!std.ascii.endsWithIgnoreCase(fe, ".ftr")) continue;
            const n = fe[0 .. fe.len - 4];
            for (out.items) |x| {
                if (std.ascii.eqlIgnoreCase(x, n)) break;
            } else out.append(a, n) catch {};
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.f);
    return out.items;
}

/// Where ability `n` of row `r` in force comes from: the exe (Classic: its key), the
/// classType's row (`cls`) or the character's own.
fn source(a: Allocator, og_project: bool, r: Abilities, cls: Abilities, comptime n: []const u8) []const u8 {
    if (!og_project or !isOwn(r)) {
        if (r.fighter != 0) return tx.alloc(a, tx.ab_by_id, .{r.fighter});
        if (r.fighter_class.len > 0) return r.fighter_class;
        return tx.alloc(a, tx.ab_by_class, .{r.class});
    }
    const same = has(cls, n) and std.mem.eql(u8, rules_rows.fieldText(a, Abilities, r, n), rules_rows.fieldText(a, Abilities, cls, n));
    return if (same) tx.alloc(a, tx.ab_by_class, .{cls.class}) else tx.get(tx.ab_own);
}

/// The block. `w`: the character (OpenGorky: its class), `class` its classType, `act` its
/// look's script (its animations for a dodge).
pub fn block(app: *App, a: Allocator, w: rules.Who, class: i32, act: ?[]const u8) void {
    const og_project = app.ogLayout();
    const r = inForce(w, class);
    var n: usize = r.scripts.len;
    inline for (defs) |d| n += @intFromBool(has(r, d.field));
    const sum = if (n == 0) tx.get(tx.ab_none_sum) else tx.alloc(a, tx.ab_sum, .{n});
    if (!gui.block(app, "abilities", tx.get(tx.sec_abilities), .{ .summary = sum })) return;
    defer gui.blockEnd();
    gui.note(tx.get(if (og_project) tx.ab_note else tx.ab_note_classic));
    // Its classType's row (no fighter has that classic_id).
    const cls = modules.abilities(.{ .id = std.math.minInt(i32) }, class).*;
    var k: u32 = 0;
    // Native components first (they answer first in the battle), then the scripted ones.
    if (n > r.scripts.len) gui.subhead(tx.get(tx.ab_natives));
    inline for (defs) |d| if (has(r, d.field)) {
        k += 1;
        gui.fieldRow(tx.get(d.label));
        gui.chip(source(a, og_project, r, cls, d.field));
        if (isMark(d.native)) gui.chip(tx.get(tx.ab_mark));
        gui.spacer();
        if (og_project and gui.smallButton(app, clay.idi("ab_rm", k), tx.get(tx.ab_remove))) write(app, w, class, removed(r, d.field)) catch |err| app.failed(err);
        if (og_project and gui.goButton(app, clay.idi("ab_go", k))) doctabs.show(app, .components, d.native);
        clay.close();
        gui.fieldNote(tx.get(d.note), theme.dim);
        if (og_project) params(app, a, w, class, r, d, act) else if (d.kind != .flag) gui.propRow("", rules_rows.fieldText(a, Abilities, r, d.field));
    };
    const comps = components(a);
    if (r.scripts.len > 0) gui.subhead(tx.get(tx.ab_scripted));
    for (r.scripts, 0..) |s, si| {
        gui.fieldRow(s.component);
        gui.chip(scriptSource(a, og_project, r, cls, s));
        if (findComp(comps, s.component)) |cp| for (cp.c.hosts) |h| if (og.script.traits.Role.of(h)) |role| gui.chip(tx.get(if (role == .hero) tx.ab_hero_only else tx.ab_enemy_only));
        gui.spacer();
        if (og_project and gui.smallButton(app, clay.idi("ab_srm", @intCast(si)), tx.get(tx.ab_remove))) write(app, w, class, withScripts(r, std.mem.concat(a, Script, &.{ r.scripts[0..si], r.scripts[si + 1 ..] }) catch return)) catch |err| app.failed(err);
        if (og_project and gui.goButton(app, clay.idi("ab_sgo", @intCast(si)))) doctabs.show(app, .components, s.component);
        clay.close();
        const cp = findComp(comps, s.component) orelse {
            gui.fieldNote(tx.alloc(a, tx.ab_script_missing, .{s.component}), theme.warn);
            continue;
        };
        gui.fieldNote(tx.alloc(a, tx.ab_script_n, .{baseName(cp.file)}), theme.dim);
        if (og_project) scriptParams(app, a, w, class, r, si, cp);
    }
    if (n == 0) gui.fieldNote(tx.get(tx.ab_none), theme.dim);
    if (!og_project) return;
    // "+ component": the ones it hasn't, native and scripted (found by a trait they
    // implement too: «Shielded» lists every scripted one that is).
    gui.fieldRow("");
    const open = picker.field(app, clay.id("ab_add"), tx.get(tx.ab_add), false);
    clay.close();
    if (gui.footer(app, "ab_new", &.{tx.get(tx.ab_new)}, null) != null) newAbility(app, w) catch |err| app.failed(err);
    gui.fieldNote(tx.get(tx.ab_new_note), theme.dim);
    if (!open) return;
    var opts: std.ArrayList(picker.Opt) = .empty;
    var which: std.ArrayList(usize) = .empty;
    inline for (defs, 0..) |d, j| if (!has(r, d.field)) {
        opts.append(a, .{ .label = tx.get(d.label), .note = tx.get(d.note) }) catch {};
        which.append(a, j) catch {};
    };
    for (comps, 0..) |cp, j| if (!hasScript(r, cp.path)) {
        const note = tx.alloc(a, tx.ab_script_pick_n, .{baseName(cp.file)});
        opts.append(a, .{ .label = cp.path, .note = if (cp.c.traits.len > 0) tx.alloc(a, tx.ab_by_trait, .{ note, std.mem.join(a, ", ", cp.c.traits) catch "" }) else note, .key = cp.traits }) catch {};
        which.append(a, defs.len + j) catch {};
    };
    const pick = picker.list(app, a, opts.items) orelse return;
    if (which.items[pick] >= defs.len) return write(app, w, class, withScripts(r, std.mem.concat(a, Script, &.{ r.scripts, &.{.{ .component = comps[which.items[pick] - defs.len].path }} }) catch return)) catch |err| app.failed(err);
    const names = fighterNames(app, a);
    const first = if (names.len > 0) names[0] else "";
    inline for (defs, 0..) |d, j| if (which.items[pick] == j) write(app, w, class, added(r, d.field, first)) catch |err| app.failed(err);
}

// ---------------------------------------------------------------- scripted abilities

/// A component of the project's code a fighter may have, by the path a row names it with;
/// `traits`: the names of all it implements (the list's search finds it by one).
const Comp = struct { path: []const u8, c: *const ir.Component, file: []const u8, traits: []const u8 = "" };

/// The project's scripted abilities: the components of its rules code (`rules.scripts`,
/// traitinfo.zig) a fighter may have — `for fighter`, `for Hero`/`Enemy`, a trait of a
/// fighter's, or bound to no host at all —, in file order.
pub fn components(a: Allocator) []const Comp {
    var out: std.ArrayList(Comp) = .empty;
    const p = traitinfo.load(a);
    for (p.comps) |*c| {
        const cl = p.closure(a, c);
        var kinds: usize = 0;
        var fighter = false;
        var names: std.ArrayList(u8) = .empty;
        for (cl) |t| {
            names.print(a, "{s} ", .{t.name()}) catch {};
            if (t != .engine) continue;
            kinds += @intFromBool(t.engine.kind == .host);
            fighter = fighter or std.mem.eql(u8, t.engine.name, "Fighter");
        }
        if (kinds == 0 or fighter) out.append(a, .{ .path = c.path, .c = c.it, .file = c.file, .traits = names.items }) catch {};
    }
    return out.items;
}

/// The trait param type `t` of component `cp` names (`Shielded`, `Hero`), null: none
/// (a host kind written lower case is no trait here: `fighter` is picked as any fighter).
fn traitOf(a: Allocator, cp: Comp, t: []const u8) ?traitinfo.Ref {
    if (t.len == 0 or !std.ascii.isUpper(t[0])) return null;
    const p = traitinfo.load(a);
    const c = p.comp(cp.path) orelse return null;
    return p.resolve(a, c.it.module, c.uses, t);
}

/// The battles' fighters a component implementing `tr` is attached to by their own rows
/// (a script one in `scripts`, a native one by its part); a role: every fighter; none
/// found: every fighter (the param is still checked when attached).
/// shortcut: rows keyed by class or classic_id are not matched to the objects (their
/// archetypes come with the OG reader); match them then.
fn traitFighters(app: *App, a: Allocator, tr: traitinfo.Ref) []const []const u8 {
    const all = fighterNames(app, a);
    if (tr == .engine and tr.engine.kind == .role) return all;
    const p = traitinfo.load(a);
    const natives: []const []const u8 = if (tr == .engine) traitinfo.nativesOf(a, tr.engine) else &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |nm| for (modules.tables().classes) |r| {
        if (!std.ascii.eqlIgnoreCase(r.fighter_class, nm)) continue;
        const yes = for (r.scripts) |sc| {
            const c = p.comp(sc.component) orelse continue;
            if (for (p.closure(a, c)) |x| {
                if (std.mem.eql(u8, x.name(), tr.name())) break true;
            } else false) break true;
        } else inline for (defs) |d| {
            if (has(r, d.field) and for (natives) |n| {
                if (std.mem.eql(u8, n, d.native)) break true;
            } else false) break true;
        } else false;
        if (yes) out.append(a, nm) catch {};
        break;
    };
    return if (out.items.len > 0) out.items else all;
}

/// Whether native component `name` is a mark (its trait has no methods: `Monitor`).
fn isMark(name: []const u8) bool {
    const t = og.script.traits.find(name) orelse return false;
    return t.kind == .mark;
}

fn findComp(comps: []const Comp, path: []const u8) ?Comp {
    for (comps) |c| if (std.mem.eql(u8, c.path, path)) return c;
    return null;
}

fn hasScript(r: Abilities, path: []const u8) bool {
    for (r.scripts) |s| if (std.mem.eql(u8, s.component, path)) return true;
    return false;
}

fn withScripts(r: Abilities, scripts: []const Script) Abilities {
    var x = r;
    x.scripts = scripts;
    return x;
}

/// Where scripted ability `s` of row `r` comes from (as `source`).
fn scriptSource(a: Allocator, og_project: bool, r: Abilities, cls: Abilities, s: Script) []const u8 {
    if (!og_project or !isOwn(r)) return tx.alloc(a, tx.ab_by_class, .{r.class});
    for (cls.scripts) |c| if (og.loaders.codec.same(Script, c, s)) return tx.alloc(a, tx.ab_by_class, .{cls.class});
    return tx.get(tx.ab_own);
}

/// Param `f`'s value in `s`: given, else its default literal (null: none written).
fn paramValue(s: Script, f: ir.Field) ?Script.Lit {
    if (s.param(f.name)) |v| return v;
    const d = f.default orelse return null;
    return switch (d.kind) {
        .lit => |v| switch (v) {
            .int => |x| .{ .int = x },
            .float => |x| .{ .float = x },
            .bool => |x| .{ .bool = x },
            .string => |x| .{ .string = x },
            else => null,
        },
        .unary => |u| if (u.op == .neg and u.operand.kind == .lit) switch (u.operand.kind.lit) {
            .int => |x| .{ .int = -%x },
            .float => |x| .{ .float = -x },
            else => null,
        } else null,
        // An enum's value (`Side::enemy`): its name.
        .word => |w| .{ .string = w[if (std.mem.lastIndexOf(u8, w, "::")) |k| k + 2 else 0..] },
        else => null,
    };
}

/// The enum param type `t` of component `cp` names (`Side`), if it is one.
fn enumOf(a: Allocator, cp: Comp, t: []const u8) ?*const ir.Enum {
    if (t.len == 0 or !std.ascii.isUpper(t[0])) return null;
    const p = traitinfo.load(a);
    const c = p.comp(cp.path) orelse return null;
    return p.enumNamed(a, c.it.module, c.uses, t);
}

/// Value `x` of enum `en` as shown: a prelude type's in the interface language
/// (text.zig `prelude`), a project's label as written, else its name.
fn valueLabel(en: *const ir.Enum, x: ir.EnumValue) []const u8 {
    if (std.mem.eql(u8, en.file, "engine.ogs")) if (tx.preludeLabel(en.name, x.name)) |l| return l;
    return if (x.label.len > 0) x.label else x.name;
}

fn litFloat(v: ?Script.Lit) f32 {
    return switch (v orelse return 0) {
        .int => |x| @floatFromInt(x),
        .float => |x| x,
        .bool => |x| @floatFromInt(@intFromBool(x)),
        .string => 0,
    };
}

/// A param type that names an object (picked from the battles' fighters).
fn isRef(t: []const u8) bool {
    for ([_][]const u8{ "fighter", "object", "item", "weapon" }) |k| if (std.mem.eql(u8, t, k)) return true;
    return false;
}

/// Scripted ability `k`'s (component `cp`) params as fields; a change writes the row.
fn scriptParams(app: *App, a: Allocator, w: rules.Who, class: i32, r: Abilities, k: usize, cp: Comp) void {
    const s = r.scripts[k];
    const tp = traitinfo.load(a);
    const fields = if (tp.comp(cp.path)) |c| tp.fields(a, c) else cp.c.fields;
    for (fields) |f| {
        if (f.kind != .param) continue;
        const id = std.fmt.allocPrint(a, "ab_s{d}_{s}", .{ k, f.name }) catch continue;
        const label = if (f.doc.len > 0) f.doc else f.name;
        const cur = paramValue(s, f);
        const t = f.type_name;
        var nv: ?Script.Lit = null;
        if (std.mem.eql(u8, t, "int")) {
            const x: i32 = @intFromFloat(litFloat(cur));
            const st = step(app, a, id, std.fmt.allocPrint(a, "{s}: {d}", .{ label, x }) catch label, x);
            if (st != 0) nv = .{ .int = x +% st };
        } else if (std.mem.eql(u8, t, "float")) {
            const x = litFloat(cur);
            const st = gui.stepper(app, a, id, std.fmt.allocPrint(a, "{s}: {d:.2}", .{ label, x }) catch label, x, 0.1);
            if (st != 0) nv = .{ .float = x + st };
        } else if (std.mem.eql(u8, t, "bool")) {
            const on = litFloat(cur) != 0;
            gui.fieldRow("");
            if (gui.check(app, clay.id(id), on, label)) nv = .{ .bool = !on };
            clay.close();
        } else if (enumOf(a, cp, t)) |en| {
            // A dropdown of its values by label; the row stores the value's name.
            const name: []const u8 = if (cur) |v| (if (v == .string) v.string else "") else "";
            const shown = if (en.value(name)) |x| valueLabel(en, x.*) else if (name.len > 0) name else "—";
            gui.fieldRow(label);
            const open = picker.field(app, clay.id(id), shown, en.value(name) == null);
            clay.close();
            if (open) {
                const rows = a.alloc(picker.Opt, en.values.len) catch return;
                for (en.values, rows) |x, *o| o.* = .{ .label = valueLabel(en, x), .note = x.name, .selected = std.mem.eql(u8, x.name, name) };
                if (picker.list(app, a, rows)) |j| nv = .{ .string = app.catalog.arena.allocator().dupe(u8, en.values[j].name) catch return };
            }
        } else if (std.mem.eql(u8, t, "character")) {
            // An archetype: picked from the characters, stored as its path (`characters::grandma`).
            const name: []const u8 = if (cur) |v| (if (v == .string) v.string else "") else "";
            gui.fieldRow(label);
            const open = picker.field(app, clay.id(id), if (name.len > 0) name else "—", false);
            clay.close();
            gui.fieldNote(tx.get(tx.ab_pick_character), theme.dim);
            if (open) {
                var rows: std.ArrayList(picker.Opt) = .empty;
                var paths: std.ArrayList([]const u8) = .empty;
                for (app.catalog.entries.items) |e| if (e.kind == .hero or e.kind == .enemy) {
                    const path = std.fmt.allocPrint(a, "characters::{s}", .{e.id}) catch continue;
                    paths.append(a, path) catch continue;
                    rows.append(a, .{ .label = if (e.title.len > 0) e.title else e.id, .note = path, .selected = std.mem.eql(u8, path, name) }) catch continue;
                };
                if (picker.list(app, a, rows.items)) |j| nv = .{ .string = app.catalog.arena.allocator().dupe(u8, paths.items[j]) catch return };
            }
        } else if (isRef(t) or traitOf(a, cp, t) != null) {
            const name: []const u8 = if (cur) |v| (if (v == .string) v.string else "") else "";
            gui.fieldRow(label);
            const open = picker.field(app, clay.id(id), if (name.len > 0) name else "—", false);
            clay.close();
            // A trait (`param Shielded ward`): the fighters a component implementing it is
            // attached to; a role (`param Hero h`): any, the game checks it.
            const tr = traitOf(a, cp, t);
            if (tr) |x| if (x == .engine and x.engine.kind == .role) gui.fieldNote(tx.get(tx.ab_pick_role), theme.dim) else gui.fieldNote(tx.alloc(a, tx.ab_pick_trait, .{x.name()}), theme.dim);
            if (open) {
                const names = if (tr) |x| traitFighters(app, a, x) else fighterNames(app, a);
                const rows = a.alloc(picker.Opt, names.len) catch return;
                for (names, rows) |nm, *o| o.* = .{ .label = nm, .selected = std.ascii.eqlIgnoreCase(nm, name) };
                if (picker.list(app, a, rows)) |j| nv = .{ .string = app.catalog.arena.allocator().dupe(u8, names[j]) catch return };
            }
        } else {
            const text: []const u8 = if (cur) |v| (if (v == .string) v.string else "") else "";
            gui.fieldRow(label);
            if (gui.textField(app, id, text, 0, "—")) |typed| nv = .{ .string = app.catalog.arena.allocator().dupe(u8, typed) catch return };
            clay.close();
        }
        if (nv) |v| return write(app, w, class, withParam(a, r, k, f.name, v) catch return) catch |err| app.failed(err);
    }
}

/// `r` with param `name` of scripted ability `k` made `v`.
fn withParam(a: Allocator, r: Abilities, k: usize, name: []const u8, v: Script.Lit) !Abilities {
    const s = r.scripts[k];
    var ps: std.ArrayList(Script.Param) = .empty;
    try ps.appendSlice(a, s.params);
    for (ps.items) |*p| if (std.mem.eql(u8, p.name, name)) {
        p.value = v;
    };
    if (s.param(name) == null) try ps.append(a, .{ .name = name, .value = v });
    const scripts = try a.dupe(Script, r.scripts);
    scripts[k] = .{ .component = s.component, .params = ps.items };
    return withScripts(r, scripts);
}

/// A new scripted ability: a component from the template (`NewAbility<N>`, the first name
/// free) added to rules\abilities.ss (made when missing), the file opened in the code editor
/// at it. Not attached to `w`: the abilities list (+) offers it from now on. One undo step.
fn newAbility(app: *App, w: rules.Who) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const a = app.frame.allocator();
    const comps = components(a);
    var name: []const u8 = undefined;
    var i: usize = 1;
    while (true) : (i += 1) {
        name = try std.fmt.allocPrint(a, "NewAbility{d}", .{i});
        if (findComp(comps, name) == null) break;
    }
    return addAbility(app, w, name);
}

/// Component `name` (OGS, from the template) in a file of its own, `src/components/<name>.ogs`
/// (the OG writer's layout of a root component), made on `w`'s page (the undo step's name);
/// attaching it is the abilities list's (+).
pub fn addAbility(app: *App, w: rules.Who, name: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const a = app.frame.allocator();
    const og_src = @import("store.zig").og_src;
    const entry = try std.fmt.allocPrint(a, "components/{s}.ogs", .{name});
    if (app.store.file(og_src, entry)) |_| return error.PathAlreadyExists else |_| {}
    const text = try og.script.traits.template(a, name);
    app.store.group();
    defer app.store.endGroup("{s}: + {s}", .{ w.class, name });
    const f = try app.store.addNew(&.{.{ .archive = og_src, .entry = entry, .text = try app.gpa.dupe(u8, text[1..]) }});
    @import("entry_rules.zig").sync(app);
    @import("doctabs.zig").showCode(app, f, 0);
}

/// Ability `d`'s parameters (OpenGorky): steppers, angles, animations and fighters picked.
fn params(app: *App, a: Allocator, w: rules.Who, class: i32, r: Abilities, comptime d: Def, act: ?[]const u8) void {
    const put = struct {
        fn f(ap: *App, ww: rules.Who, c: i32, x: Abilities) void {
            write(ap, ww, c, x) catch |err| ap.failed(err);
        }
    }.f;
    var x = r;
    switch (d.kind) {
        .flag => {},
        .level_mode => {
            const s = gui.stepper(app, a, "ab_mode", tx.alloc(a, tx.ab_level_mode, .{r.first_in_mode}), @floatFromInt(r.first_in_mode), 1);
            if (s != 0) {
                x.first_in_mode = @max(1, r.first_in_mode + @as(i32, @intFromFloat(@round(s))));
                put(app, w, class, x);
            }
        },
        .stand => {
            const angles = [_]f32{ 0, 1.57, 3.14, -1.57 };
            gui.fieldRow(tx.get(tx.ab_angle));
            const open = picker.field(app, clay.id("ab_angle"), angleLabel(a, r.stand.?), false);
            clay.close();
            if (open) {
                var rows: [angles.len]picker.Opt = undefined;
                for (angles, &rows) |v, *o| o.* = .{ .label = angleLabel(a, v), .selected = v == r.stand.? };
                if (picker.list(app, a, &rows)) |j| {
                    x.stand = angles[j];
                    put(app, w, class, x);
                }
            }
            gui.fieldRow("");
            if (gui.check(app, clay.id("ab_after"), r.stand_after_move, tx.get(tx.ab_after_move))) {
                x.stand_after_move = !r.stand_after_move;
                put(app, w, class, x);
            }
            clay.close();
        },
        .guard => {
            const g = r.guard.?;
            var ng = g;
            ng.div = @max(1, g.div + step(app, a, "ab_div", tx.alloc(a, tx.ab_div, .{g.div}), g.div));
            ng.min = @max(0, g.min + step(app, a, "ab_min", tx.alloc(a, tx.ab_min, .{g.min}), g.min));
            const c = gui.stepper(app, a, "ab_cone", tx.alloc(a, tx.ab_cone, .{g.cone}), g.cone, 0.1);
            ng.cone = std.math.clamp(g.cone + c, 0, std.math.pi);
            if (!std.meta.eql(ng, g)) {
                x.guard = ng;
                put(app, w, class, x);
            }
        },
        .open_from => {
            const t = relTile(app, a, "ab_open", r.open_from.?);
            if (!std.meta.eql(t, r.open_from.?)) {
                x.open_from = t;
                put(app, w, class, x);
            }
            if (animPick(app, a, "ab_dodge", tx.get(tx.ab_dodge), r.dodge, act)) |v| {
                x.dodge = v;
                put(app, w, class, x);
            }
        },
        .arms => {
            const ar = r.arms.?;
            var na = ar;
            gui.subhead(tx.get(tx.ab_left));
            na.left = relTile(app, a, "ab_left", ar.left);
            gui.subhead(tx.get(tx.ab_right_arm));
            na.right = relTile(app, a, "ab_rarm", ar.right);
            const picked = animPick(app, a, "ab_blocked", tx.get(tx.ab_blocked), ar.blocked, act);
            if (picked) |v| na.blocked = v;
            if (!std.meta.eql(na.left, ar.left) or !std.meta.eql(na.right, ar.right) or picked != null) {
                x.arms = na;
                put(app, w, class, x);
            }
        },
        .pairs => {
            for (r.pairs, 0..) |p, j| {
                var np = p;
                const id = std.fmt.allocPrint(a, "ab_pair{d}", .{j}) catch "ab_pair";
                np[0] = @max(0, p[0] + step(app, a, id, tx.alloc(a, tx.ab_pair_a, .{ j + 1, p[0] }), p[0]));
                const id2 = std.fmt.allocPrint(a, "ab_pairb{d}", .{j}) catch "ab_pairb";
                np[1] = @max(0, p[1] + step(app, a, id2, tx.alloc(a, tx.ab_pair_b, .{ j + 1, p[1] }), p[1]));
                if (!std.meta.eql(np, p)) {
                    const ps = a.dupe([2]i32, r.pairs) catch return;
                    ps[j] = np;
                    x.pairs = ps;
                    return put(app, w, class, x);
                }
            }
            const labels = [_][]const u8{ tx.get(tx.ab_pair_add), tx.get(tx.ab_pair_remove) };
            const k = gui.footer(app, "ab_pairs", labels[0..if (r.pairs.len > 0) 2 else 1], null) orelse return;
            x.pairs = if (k == 0) std.mem.concat(a, [2]i32, &.{ r.pairs, &.{.{ 0, 0 }} }) catch return else r.pairs[0 .. r.pairs.len - 1];
            put(app, w, class, x);
        },
        .fighter => {
            const cur: []const u8 = @field(r, d.field);
            gui.fieldRow(tx.get(tx.ab_fighter));
            const open = picker.field(app, clay.id("ab_" ++ d.field), if (cur.len > 0) cur else "—", false);
            clay.close();
            if (open) {
                const names = fighterNames(app, a);
                const rows = a.alloc(picker.Opt, names.len) catch return;
                for (names, rows) |nm, *o| o.* = .{ .label = nm, .selected = std.ascii.eqlIgnoreCase(nm, cur) };
                if (picker.list(app, a, rows)) |j| {
                    @field(x, d.field) = app.catalog.arena.allocator().dupe(u8, names[j]) catch return;
                    put(app, w, class, x);
                }
            }
        },
    }
}

/// An integer stepper: the step taken (0: none).
fn step(app: *App, a: Allocator, id: []const u8, text: []const u8, cur: i32) i32 {
    return @intFromFloat(@round(gui.stepper(app, a, id, text, @floatFromInt(cur), 1)));
}

/// A tile relative to the fighter (`behaviour.Rel`): to its right, ahead; as edited.
fn relTile(app: *App, a: Allocator, id: []const u8, t: behaviour.Rel) behaviour.Rel {
    return .{
        t[0] + step(app, a, std.fmt.allocPrint(a, "{s}_x", .{id}) catch id, tx.alloc(a, tx.ab_rel_right, .{t[0]}), t[0]),
        t[1] + step(app, a, std.fmt.allocPrint(a, "{s}_y", .{id}) catch id, tx.alloc(a, tx.ab_rel_ahead, .{t[1]}), t[1]),
    };
}

/// An animation (its file, as the battle plays it) picked from the look's (`act`); the
/// picked one, if any.
fn animPick(app: *App, a: Allocator, id: []const u8, label: []const u8, cur: []const u8, act: ?[]const u8) ?[]const u8 {
    gui.fieldRow(label);
    const open = picker.field(app, clay.id(id), if (cur.len > 0) cur else "—", false);
    clay.close();
    if (!open) return null;
    const list = preview.anims(a, act orelse "");
    var rows: std.ArrayList(picker.Opt) = .empty;
    rows.append(a, .{ .label = "—", .key = "", .selected = cur.len == 0 }) catch {};
    for (list) |an| {
        const seen = for (rows.items) |o| {
            if (std.ascii.eqlIgnoreCase(o.key, an.file)) break true;
        } else false;
        if (!seen) rows.append(a, .{ .key = an.file, .label = an.file, .note = an.slot, .selected = std.ascii.eqlIgnoreCase(an.file, cur) }) catch {};
    }
    const v = picker.listKey(app, a, rows.items) orelse return null;
    return app.catalog.arena.allocator().dupe(u8, v) catch null;
}

/// "3.14 (pi)" (the fonts have no π).
fn angleLabel(a: Allocator, v: f32) []const u8 {
    const name: []const u8 = if (v == 0) "0" else if (v == 1.57) "pi/2" else if (v == 3.14) "pi" else if (v == -1.57) "-pi/2" else "";
    return if (name.len > 0) std.fmt.allocPrint(a, "{d} ({s})", .{ v, name }) catch "" else std.fmt.allocPrint(a, "{d}", .{v}) catch "";
}
