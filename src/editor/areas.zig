//! A location's areas and exits: drawn, moved, renamed, deleted (its `.ar`, the
//! triggers and exit scripts naming them), refused while a script still uses one.

const std = @import("std");
const og = @import("opengorky");
const tx = @import("text.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const doctabs = @import("doctabs.zig");
const paint = @import("paint.zig");
const trigger = @import("trigger.zig");
const placement = @import("placement.zig");
const common_archive = @import("store.zig").common_archive;
const og_src = @import("store.zig").og_src;
const model_og = @import("model_og.zig");
const level_og = @import("level_og.zig");
const ir = og.script.ir;
const App = @import("app.zig").App;

// ---------------------------------------------------------------- OpenGorky
// On an OpenGorky project a location's areas stay its `.ar` (the project's own asset,
// src/assets/, store.zig ownAsset); what Classic writes into `.lev`/`.are` goes into its
// OG Script: the trigger into the level's own code (`level "x" { fn OnUpdate() … }`)
// (logic.ogs), an exit as an `area` block (objects.ogs) with its component's OnExit().

/// The text of a level's code: a location's `logic.ogs`, a battle's `battle.ogs` (all of it).
fn codeText(d: *Doc) []const u8 {
    return if (d.isBattle()) "battle.ogs" else "logic.ogs";
}

/// The open level's text `name` (`logic.ogs`) of the project's src/.
fn ogText(app: *App, d: *Doc, name: []const u8) !usize {
    var buf: [256]u8 = undefined;
    return app.store.file(og_src, try std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ if (d.isBattle()) "battles" else "locations", d.name, name }));
}

/// The open level's `logic.ogs`, a new one (its module alone, trigger.newLogicOg) made when
/// it has none: a level needs it only for its first trigger or exit. Inside the caller's
/// undo group (undo takes the new file away again).
fn logicOg(app: *App, d: *Doc) !usize {
    return ogText(app, d, codeText(d)) catch |err| {
        if (err != error.NotFound) return err;
        const top = if (d.isBattle()) "battles" else "locations";
        const t = try trigger.newLogicOg(app.gpa, top, d.name);
        errdefer app.gpa.free(t);
        return app.store.addNew(&.{.{ .archive = og_src, .entry = try std.fmt.allocPrint(app.frame.allocator(), "{s}/{s}/{s}", .{ top, d.name, codeText(d) }), .text = t }});
    };
}

/// The level's scripts: on an OpenGorky project its texts in src/ (`level.ogs`,
/// `objects.ogs`, `logic.ogs`…), else its Classic files (Doc.levelFiles).
pub fn levelTexts(app: *App, d: *Doc, a: std.mem.Allocator) []usize {
    if (!app.ogLayout()) return d.levelFiles(a) catch &.{};
    const dir = std.fmt.allocPrint(a, "{s}/{s}/", .{ if (d.isBattle()) "battles" else "locations", d.name }) catch return &.{};
    var out: std.ArrayList(usize) = .empty;
    for (app.store.listingFrame(og_src, null, true)) |p| {
        if (!std.mem.startsWith(u8, p, dir) or std.mem.indexOfScalarPos(u8, p, dir.len, '/') != null) continue;
        out.append(a, app.store.file(og_src, p) catch continue) catch {};
    }
    return out.items;
}

/// An exit of the open OpenGorky level: area object `obj` (its block in the level's
/// objects) naming area `name`, its component `comp` (in text `file`: its own beside the
/// level's, as the converter writes it, or logic.ogs) loading `to`.
const OgExit = struct { obj: []const u8, comp: []const u8, to: []const u8, file: usize };

/// Component `comp` out of its own text `f`: the file removed when no component is left.
fn removeOwnComponent(app: *App, f: usize, comp: []const u8) !void {
    const t = try trigger.removeComponentOg(app.gpa, app.store.text(f), comp);
    if (std.mem.indexOf(u8, t, "component ") == null) {
        app.gpa.free(t);
        return app.store.delete(&.{f});
    }
    app.store.replace(f, t) catch |err| {
        app.gpa.free(t);
        return err;
    };
}

/// The level's text defining component `comp` (its own file or logic.ogs).
pub fn compFile(app: *App, d: *Doc, comp: []const u8) ?usize {
    for (levelTexts(app, d, app.frame.allocator())) |f| if (trigger.componentSpanOg(app.store.text(f), comp) != null) return f;
    return null;
}

/// ogExit's answers for the open level, kept until the Store changes (the exits block asks
/// for every area each frame: each answer parses the level and lists the project's files).
var exit_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var exit_cache: std.StringHashMapUnmanaged(?OgExit) = .empty;
var exit_key: struct { rev: u64 = std.math.maxInt(u64), level: [64]u8 = undefined, len: usize = 0 } = .{};

fn ogExit(app: *App, d: *Doc, name: []const u8) ?OgExit {
    const same = exit_key.rev == app.store.rev and exit_key.len == d.name.len and d.name.len <= exit_key.level.len and std.mem.eql(u8, exit_key.level[0..exit_key.len], d.name);
    if (!same) {
        _ = exit_arena.reset(.retain_capacity);
        exit_cache = .empty;
        exit_key.rev = app.store.rev;
        exit_key.len = @min(d.name.len, exit_key.level.len);
        @memcpy(exit_key.level[0..exit_key.len], d.name[0..exit_key.len]);
    }
    const ea = exit_arena.allocator();
    var kb: [96]u8 = undefined;
    const key = std.ascii.lowerString(&kb, name[0..@min(name.len, kb.len)]);
    if (exit_cache.get(key)) |x| return x;
    const found: ?OgExit = if (ogExitRead(app, d, name)) |x| .{ .obj = ea.dupe(u8, x.obj) catch return x, .comp = ea.dupe(u8, x.comp) catch return x, .to = ea.dupe(u8, x.to) catch return x, .file = x.file } else null;
    exit_cache.put(ea, ea.dupe(u8, key) catch return found, found) catch {};
    return found;
}

fn ogExitRead(app: *App, d: *Doc, name: []const u8) ?OgExit {
    const a = app.frame.allocator();
    const lf = level_og.blockFile(d) orelse return null;
    for (model_og.levelObjects(app, a, lf)) |o| {
        if (!std.mem.eql(u8, o.kind, "area")) continue;
        const an = for (o.fields) |f| {
            if (std.mem.eql(u8, f.name, "areaName")) break og.core.schema.text(f.value) orelse continue;
        } else continue;
        if (!std.ascii.eqlIgnoreCase(an, name)) continue;
        for (o.attach) |x| {
            const comp = x.component[if (std.mem.lastIndexOf(u8, x.component, "::")) |k| k + 2 else 0..];
            const cf = compFile(app, d, comp) orelse continue;
            if (trigger.exitTargetOg(app.store.text(cf), comp)) |to| return .{ .obj = o.name, .comp = comp, .to = to, .file = cf };
        }
    }
    return null;
}

/// The level area `name` of the open level leads to (its exit's), if it is one.
pub fn exitTo(app: *App, d: *Doc, name: []const u8) ?[]const u8 {
    if (app.ogLayout()) return if (ogExit(app, d, name)) |x| x.to else null;
    return trigger.exitTarget(app.store.text(exitOf(app, d, name) orelse return null));
}

/// Area `name`'s exit leading to level `target` instead (one undo step).
pub fn setExitTo(app: *App, d: *Doc, name: []const u8, target: []const u8) void {
    if (!app.ogLayout()) return setExitTarget(app, exitOf(app, d, name) orelse return, target);
    const x = ogExit(app, d, name) orelse return app.setStatus(tx.st_paint_failed, .{error.NoTarget});
    const t = trigger.setExitTargetOg(app.gpa, app.store.text(x.file), x.comp, target) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    app.store.replaceLabeled(x.file, t, std.fmt.allocPrint(app.frame.allocator(), "→ {s}", .{target}) catch null) catch |err| {
        app.gpa.free(t);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    @import("entry_rules.zig").sync(app);
}

fn addTriggerAreaOg(app: *App, d: *Doc, pts: []const [2]i32) void {
    const arf = arFile(app, d) orelse return;
    const lf = level_og.blockFile(d) orelse return app.setStatus(tx.st_paint_failed, .{error.NoSuchBlock});
    var nb: [32]u8 = undefined;
    const name = trigger.freeName(&nb, app.store.text(arf), "trigger");
    var logic: usize = undefined;
    const at = blk: {
        app.store.group();
        defer app.store.endGroup("+ {s}", .{name});
        logic = logicOg(app, d) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        const ar = trigger.addArea(app.gpa, app.store.text(arf), name, pts, null) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        app.store.replace(arf, ar) catch |err| {
            app.gpa.free(ar);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        const r = trigger.addTriggerOg(app.gpa, app.store.text(logic), if (d.isBattle()) "battle" else "level", d.name, name) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        app.store.replace(logic, r.text) catch |err| {
            app.gpa.free(r.text);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        // Its variable: the level block's.
        const lv = trigger.addLevelVarOg(app.gpa, app.store.text(lf), name) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        app.store.replace(lf, lv) catch |err| {
            app.gpa.free(lv);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        break :blk r.at;
    };
    @import("entry_rules.zig").sync(app);
    app.reloadLevel();
    doctabs.showCode(app, logic, at);
    app.setStatus(tx.st_trigger_added, .{name});
}

fn addExitAreaOg(app: *App, d: *Doc, pts: []const [2]i32, to: [2]f32, target: []const u8, label: u16) void {
    const a = app.frame.allocator();
    const arf = arFile(app, d) orelse return;
    const lf = level_og.blockFile(d) orelse return app.setStatus(tx.st_paint_failed, .{error.NoSuchBlock});
    var nb: [32]u8 = undefined;
    const name = trigger.freeName(&nb, app.store.text(arf), "exit");
    const comp = std.fmt.allocPrint(a, "{s}_are", .{name}) catch return;
    {
        app.store.group();
        defer app.store.endGroup("+ {s} → {s}", .{ name, target });
        const logic = logicOg(app, d) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        // The component's path: the module addExitOg puts it in (`locations::_01_port`).
        const lt = trigger.withModuleOg(a, app.store.text(logic), if (d.isBattle()) "battles" else "locations", d.name) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        const module = trigger.exitModuleOg(a, lt) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        const path = std.fmt.allocPrint(a, "{s}::{s}", .{ module, comp }) catch return;
        const ar = trigger.addArea(app.gpa, app.store.text(arf), name, pts, .{ @intFromFloat(@round(to[0])), @intFromFloat(@round(to[1])) }) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        app.store.replace(arf, ar) catch |err| {
            app.gpa.free(ar);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        const enable = std.mem.indexOf(u8, lt, "hero::DisableOthers(") != null;
        const nl = trigger.addExitOg(app.gpa, lt, comp, target, enable) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        app.store.replace(logic, nl) catch |err| {
            app.gpa.free(nl);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        // As the Classic exit's init(): classic_id (its hint), areaName, action −1 (OG
        // Script's word `walk`), isLevelSwitch.
        const fields = ogFields(a, &.{ .{ "classic_id", .{ .int = label } }, .{ "areaName", .{ .string = name } }, .{ "action", .{ .int = -1 } }, .{ "isLevelSwitch", .{ .int = 1 } } }) catch return;
        const walk = a.create(ir.Expr) catch return;
        walk.* = .{ .line = 0, .kind = .{ .word = "walk" } };
        @constCast(fields)[2].value = walk;
        const att = a.dupe(ir.Attach, &.{.{ .component = path, .params = &.{}, .line = 0 }}) catch return;
        model_og.addInnerBlock(app, lf, .{ .kind = "area", .name = comp, .fields = fields, .attach = att, .line = 0 }) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    }
    @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_exit_added, .{ name, target });
    app.reloadLevel();
}

fn ogFields(a: std.mem.Allocator, kv: []const struct { []const u8, og.script.value.Value }) ![]const ir.Named {
    const out = try a.alloc(ir.Named, kv.len);
    for (kv, out) |x, *o| {
        const e = try a.create(ir.Expr);
        e.* = .{ .line = 0, .kind = switch (x[1]) {
            .int => |n| if (n < 0) .{ .unary = .{ .op = .neg, .operand = try lit(a, .{ .int = -n }) } } else .{ .lit = x[1] },
            else => .{ .lit = x[1] },
        } };
        o.* = .{ .name = x[0], .value = e };
    }
    return out;
}

fn lit(a: std.mem.Allocator, v: og.script.value.Value) !*const ir.Expr {
    const e = try a.create(ir.Expr);
    e.* = .{ .line = 0, .kind = .{ .lit = v } };
    return e;
}

/// A trigger on area `name` in a text of its own (the converter's `fight2_place.ogs`: a
/// component of the level, OnUpdate calling it `host.fight2_place();`): that text and the
/// component's name.
fn ownTrigger(app: *App, d: *Doc, name: []const u8) ?struct { file: usize, comp: []const u8 } {
    const a = app.frame.allocator();
    const q = std.fmt.allocPrint(a, "hero::AnyInArea(\"{s}\")", .{name}) catch return null;
    for (levelTexts(app, d, a)) |f| {
        const t = app.store.text(f);
        // Not the level's own code (its logic.ogs): a component of its own elsewhere.
        if (std.ascii.findIgnoreCase(t, q) == null or std.mem.endsWith(u8, app.store.files.items[f].entry, codeText(d))) continue;
        const k = std.mem.indexOf(u8, t, "component ") orelse continue;
        const rest = t[k + "component ".len ..];
        return .{ .file = f, .comp = rest[0 .. std.mem.indexOfAny(u8, rest, " {") orelse continue] };
    }
    return null;
}

/// `text` without its first line holding `needle` (as it is when none does).
fn withoutLine(gpa: std.mem.Allocator, text: []const u8, needle: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return gpa.dupe(u8, text);
    const s = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |k| k + 1 else 0;
    const e = if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |k| k + 1 else text.len;
    return std.mem.concat(gpa, u8, &.{ text[0..s], text[e..] });
}

fn deleteAreaOg(app: *App, d: *Doc, name: []const u8) void {
    const a = app.frame.allocator();
    const arf = arFile(app, d) orelse return;
    // No logic.ogs: no trigger or exit to take out with it.
    const logic: ?usize = ogText(app, d, codeText(d)) catch null;
    const exit = ogExit(app, d, name);
    var nl = trigger.removeTriggerOg(app.gpa, if (logic) |l| app.store.text(l) else "", name) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    // A trigger in a text of its own goes whole: its text, OnUpdate's call, its attach.
    const own = ownTrigger(app, d, name);
    if (own) |o| {
        const t = withoutLine(app.gpa, nl, std.fmt.allocPrint(a, "host.{s}();", .{o.comp}) catch return) catch |err| {
            app.gpa.free(nl);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        app.gpa.free(nl);
        nl = t;
    }
    if (exit) |x| if (logic != null and x.file == logic.?) {
        const t = trigger.removeComponentOg(app.gpa, nl, x.comp) catch |err| {
            app.gpa.free(nl);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        app.gpa.free(nl);
        nl = t;
    };
    // Still named elsewhere (the exit's own block aside)?
    const obj: ?usize = if (exit) |x| (if (level_og.blockFile(d)) |lf| model_og.innerFile(app, lf, x.obj) catch null else null) else null;
    const skip: ?model_og.Block = if (obj) |o| model_og.blockOf(app, a, o) else null;
    const q = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return;
    for (levelTexts(app, d, a)) |f| {
        if (own) |o| if (o.file == f) continue;
        var t: []const u8 = if (logic != null and f == logic.?) nl else app.store.text(f);
        // The exit's component in its own text goes with it.
        if (exit) |x| if (x.file == f and (logic == null or f != logic.?)) if (trigger.componentSpanOg(t, x.comp)) |sp| {
            t = std.mem.concat(a, u8, &.{ t[0..sp[0]], t[sp[1]..] }) catch t;
        };
        if (skip) |b| if (b.text_file == f and !b.e.span.none()) {
            t = std.mem.concat(a, u8, &.{ t[0..b.e.span.start], t[b.e.span.end..] }) catch t;
        };
        if (std.ascii.findIgnoreCase(placement.uncommented(a, t) catch t, q) != null) {
            app.gpa.free(nl);
            return app.setStatus(tx.st_area_used, .{ name, app.store.files.items[f].entry });
        }
    }
    if (sceneUser(app, name)) |where| {
        app.gpa.free(nl);
        return app.setStatus(tx.st_area_used, .{ name, where });
    }
    {
        app.store.group();
        defer app.store.endGroup("− {s}", .{name});
        const ar = trigger.removeArea(app.gpa, app.store.text(arf), name) catch |err| {
            app.gpa.free(nl);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        app.store.replace(arf, ar) catch |err| {
            app.gpa.free(ar);
            app.gpa.free(nl);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        if (logic == null or std.mem.eql(u8, nl, app.store.text(logic.?))) app.gpa.free(nl) else app.store.replace(logic.?, nl) catch |err| {
            app.gpa.free(nl);
            return app.setStatus(tx.st_paint_failed, .{err});
        };
        // The trigger's variable in the level block.
        if (level_og.blockFile(d)) |lf| {
            var vb: [96]u8 = undefined;
            const vn = std.fmt.bufPrint(&vb, "ready_{s}", .{name}) catch return;
            var lv = trigger.removeLevelVarOg(app.gpa, app.store.text(lf), vn) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
            if (own) |o| {
                const t = withoutLine(app.gpa, lv, std.fmt.allocPrint(a, "::{s}();", .{o.comp}) catch return) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
                app.gpa.free(lv);
                lv = t;
            }
            if (std.mem.eql(u8, lv, app.store.text(lf))) app.gpa.free(lv) else app.store.replace(lf, lv) catch |err| {
                app.gpa.free(lv);
                return app.setStatus(tx.st_paint_failed, .{err});
            };
        }
        if (obj) |o| model_og.remove(app, o) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        if (exit) |x| if (logic == null or x.file != logic.?) removeOwnComponent(app, x.file, x.comp) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
        if (own) |o| app.store.delete(&.{o.file}) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    }
    @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_area_deleted, .{name});
    app.reloadLevel();
}

/// A trigger on the open location: polygon `pts` into its `.ar`, a once-only
/// `HeroInArea` block into its `.lev`; the level read again (the edit mode
/// stays on), the code editor at the block for what happens.
pub fn addTriggerArea(app: *App, pts: []const [2]i32) void {
    const d = app.doc orelse return;
    if (app.ogLayout()) return addTriggerAreaOg(app, d, pts);
    var eb: [160]u8 = undefined;
    const ar_entry = std.fmt.bufPrint(&eb, "{s}.ar", .{d.name}) catch return;
    const arf = app.store.file(d.level_archive, ar_entry) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    const lev_file = d.lev;
    var nb: [32]u8 = undefined;
    const name = trigger.freeName(&nb, app.store.text(arf), "trigger");
    // The area and its trigger in the level script: one undo step.
    app.store.group();
    defer app.store.endGroup("+ {s}", .{name});
    const ar = trigger.addArea(app.gpa, app.store.text(arf), name, pts, null) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    const lev = trigger.addTrigger(app.gpa, app.store.text(lev_file), name) catch |err| {
        app.gpa.free(ar);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    app.store.replace(arf, ar) catch |err| {
        app.gpa.free(ar);
        app.gpa.free(lev.text);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    app.store.replace(lev_file, lev.text) catch |err| {
        app.gpa.free(lev.text);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    app.reloadLevel();
    doctabs.showCode(app, lev_file, lev.at);
    app.setStatus(tx.st_trigger_added, .{name});
}

/// A clickable exit on polygon `pts` of the open location to level `target`, hint
/// `label` (string.tab): the area, its control point on the walkable cell nearest
/// its middle (the hero walks there), and its `<area>_are.are`. Two undo steps.
pub fn addExitArea(app: *App, pts: []const [2]i32, target: []const u8, label: u16) void {
    const d = app.doc orelse return;
    const a = app.frame.allocator();
    var mid: [2]f32 = .{ 0, 0 };
    for (pts) |p| mid = .{ mid[0] + @as(f32, @floatFromInt(p[0])), mid[1] + @as(f32, @floatFromInt(p[1])) };
    const n: f32 = @floatFromInt(@max(1, pts.len));
    const to = d.nearestWalkable(.{ mid[0] / n, mid[1] / n }) orelse return app.setStatus(tx.st_paint_failed, .{error.NoWalkableNear});
    if (app.ogLayout()) return addExitAreaOg(app, d, pts, to, target, label);
    const arf = arFile(app, d) orelse return;
    var nb: [32]u8 = undefined;
    const name = trigger.freeName(&nb, app.store.text(arf), "exit");
    app.store.group();
    defer app.store.endGroup("+ {s} → {s}", .{ name, target });
    const ar = trigger.addArea(app.gpa, app.store.text(arf), name, pts, .{ @intFromFloat(@round(to[0])), @intFromFloat(@round(to[1])) }) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    const enable = std.mem.indexOf(u8, app.store.text(d.lev), "DisableHeroes(") != null;
    const script = trigger.exitScript(app.gpa, name, label, target, enable) catch |err| {
        app.gpa.free(ar);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    _ = app.store.addNew(&.{.{ .archive = d.level_archive, .entry = std.fmt.allocPrint(a, "{s}_are.are", .{name}) catch return, .text = script }}) catch |err| {
        app.gpa.free(ar);
        app.gpa.free(script);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    app.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "+ {s} → {s}", .{ name, target }) catch null) catch |err| {
        app.gpa.free(ar);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    app.setStatus(tx.st_exit_added, .{ name, target });
    app.reloadLevel();
}

/// Area `name` of the open location moved by `off` (background pixels): its points,
/// its control point too, kept on the walkable cell nearest (a hero walks there).
pub fn moveArea(app: *App, name: []const u8, off_in: [2]i32) void {
    const d = app.doc orelse return;
    const a = app.frame.allocator();
    const arf = arFile(app, d) orelse return;
    const areas = og.loaders.map.parseAreas(a, app.store.text(arf)) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    const area = for (areas) |ar| {
        if (std.ascii.eqlIgnoreCase(ar.name, name)) break ar;
    } else return app.setStatus(tx.st_paint_failed, .{error.NoArea});
    // Kept on the picture: the shift stops where a corner would leave it.
    var off = off_in;
    for (0..2) |j| for (area.points) |pt| {
        const v: i32 = @intFromFloat(@round(pt[j]));
        const most: i32 = @as(i32, @intFromFloat(d.bg_size[j])) - 1;
        off[j] = std.math.clamp(off[j], -v, most - v);
    };
    const moved: [2]f32 = .{ area.control[0] + @as(f32, @floatFromInt(off[0])), area.control[1] + @as(f32, @floatFromInt(off[1])) };
    const cp = d.nearestWalkable(moved) orelse moved;
    const ar = trigger.moveArea(app.gpa, app.store.text(arf), name, off, .{ @intFromFloat(@round(cp[0])), @intFromFloat(@round(cp[1])) }) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    app.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "{s} ↔ {d},{d}", .{ name, off[0], off[1] }) catch null) catch |err| {
        app.gpa.free(ar);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    app.reloadLevel();
    // The mode opened anew: the area picked again.
    if (app.paint) |p| if (app.doc) |nd| {
        for (nd.objects.items) |o| if (o.kind == .area and std.ascii.eqlIgnoreCase(o.name, name)) {
            paint.pickName(p, o.name);
        };
    };
}

/// The exit script (`.are` with LevelSwitch) of area `name` of location `d`, if any.
fn exitOf(app: *App, d: *Doc, name: []const u8) ?usize {
    for (d.levelFiles(app.frame.allocator()) catch &.{}) |f| {
        if (std.ascii.endsWithIgnoreCase(app.store.files.items[f].entry, ".are") and trigger.isExitOf(app.store.text(f), name)) return f;
    }
    return null;
}

/// Exit `f` leading to level `target` instead (one undo step): its first LEVEL_Load's
/// level, at the bytes the model gives (LevelSwitch() is code, not lifted data).
fn setExitTarget(app: *App, f: usize, target: []const u8) void {
    const text = app.store.text(f);
    const sites = @import("model.zig").sites(app, app.frame.allocator(), f, &.{"LEVEL_Load"});
    const arg = if (sites.len > 0 and sites[0].call.args.len > 0) sites[0].call.args[0] else return app.setStatus(tx.st_paint_failed, .{error.NoTarget});
    if (arg.kind != .lit or arg.kind.lit != .string) return app.setStatus(tx.st_paint_failed, .{error.NoTarget});
    const t = std.mem.concat(app.gpa, u8, &.{ text[0 .. arg.span.start + 1], target, text[arg.span.end - 1 ..] }) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    app.store.replaceLabeled(f, t, std.fmt.allocPrint(app.frame.allocator(), "→ {s}", .{target}) catch null) catch |err| {
        app.gpa.free(t);
        app.setStatus(tx.st_paint_failed, .{err});
    };
}

/// Area `name` of the open location taken out: its polygon from `.ar`, the trigger
/// the editor made for it from `.lev`, its exit script. Refused while another script
/// still names it (the level's or a scene's): the status says which.
pub fn deleteArea(app: *App, name: []const u8) void {
    const d = app.doc orelse return;
    if (app.ogLayout()) return deleteAreaOg(app, d, name);
    const a = app.frame.allocator();
    const arf = arFile(app, d) orelse return;
    const exit = exitOf(app, d, name);
    app.store.group();
    defer app.store.endGroup("− {s}", .{name});
    const lev = trigger.removeTrigger(app.gpa, app.store.text(d.lev), name) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    if (areaUser(app, d, name, lev, exit)) |where| {
        app.gpa.free(lev);
        return app.setStatus(tx.st_area_used, .{ name, where });
    }
    const ar = trigger.removeArea(app.gpa, app.store.text(arf), name) catch |err| {
        app.gpa.free(lev);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    app.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "− {s}", .{name}) catch null) catch |err| {
        app.gpa.free(ar);
        app.gpa.free(lev);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    if (std.mem.eql(u8, lev, app.store.text(d.lev))) app.gpa.free(lev) else app.store.replace(d.lev, lev) catch |err| {
        app.gpa.free(lev);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    if (exit) |f| app.store.delete(&.{f}) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    app.setStatus(tx.st_area_deleted, .{name});
    app.reloadLevel();
}

/// Area `old` named `new`: in `.ar` and in every script of the level (`"old"`, the
/// editor's `ready_old`). Refused if a scene names it (they are shared by levels).
pub fn renameArea(app: *App, old: []const u8, new: []const u8) void {
    const d = app.doc orelse return;
    const a = app.frame.allocator();
    if (!trigger.validName(new)) return app.setStatus(tx.st_area_bad_name, .{new});
    const arf = arFile(app, d) orelse return;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    if (trigger.hasArea(app.store.text(arf), new)) return app.setStatus(tx.st_area_taken, .{new});
    if (sceneUser(app, old)) |where| return app.setStatus(tx.st_area_in_scene, .{ old, where });
    app.store.group();
    defer app.store.endGroup("{s} → {s}", .{ old, new });
    const ar = trigger.renameArea(app.gpa, app.store.text(arf), old, new) catch |err| return app.setStatus(tx.st_paint_failed, .{err});
    app.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "{s} → {s}", .{ old, new }) catch null) catch |err| {
        app.gpa.free(ar);
        return app.setStatus(tx.st_paint_failed, .{err});
    };
    for (levelTexts(app, d, arena.allocator())) |f| {
        const t = trigger.renameRefs(app.gpa, app.store.text(f), old, new) catch continue;
        if (std.mem.eql(u8, t, app.store.text(f))) app.gpa.free(t) else app.store.replace(f, t) catch app.gpa.free(t);
    }
    if (app.ogLayout()) @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_area_renamed, .{ old, new });
    app.reloadLevel();
}

fn arFile(app: *App, d: *Doc) ?usize {
    var eb: [160]u8 = undefined;
    return app.store.file(d.level_archive, std.fmt.bufPrint(&eb, "{s}.ar", .{d.name}) catch return null) catch |err| {
        app.setStatus(tx.st_paint_failed, .{err});
        return null;
    };
}

/// The script still naming area `name` (`"name"` outside comments): one of the
/// level's (its `.lev` as `lev`) or a scene; null if none.
fn areaUser(app: *App, d: *Doc, name: []const u8, lev: []const u8, skip: ?usize) ?[]const u8 {
    const a = app.frame.allocator();
    const q = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return null;
    for (d.levelFiles(a) catch &.{}) |f| {
        if (skip != null and skip.? == f) continue;
        const t = if (f == d.lev) lev else app.store.text(f);
        if (std.ascii.findIgnoreCase(placement.uncommented(a, t) catch t, q) != null) return app.store.files.items[f].entry;
    }
    return sceneUser(app, name);
}

fn sceneUser(app: *App, name: []const u8) ?[]const u8 {
    const a = app.frame.allocator();
    const q = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return null;
    for (app.catalog.scenes.items) |sc| {
        // OpenGorky: the scene's block text (src/scenes/<name>.ogs).
        const e = (if (app.ogLayout()) std.fmt.allocPrint(a, "scenes/{s}.ogs", .{sc.name}) else std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{sc.name})) catch continue;
        const f = app.store.file(if (app.ogLayout()) og_src else common_archive, e) catch continue;
        if (std.ascii.findIgnoreCase(app.store.text(f), q) != null) return app.store.files.items[f].entry;
    }
    return null;
}
