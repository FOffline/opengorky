//! A model's animations on its page: the `.ani`'s own (their frames in the `.bfr`) and the
//! actor script's bindings naming them — `RegisterAnimation(stance,"slot","anim")` (the
//! name the game asks for → the model's animation) and `RegisterIdleAnimation(stance,
//! "anim",weight)`. A binding to an animation the model lacks plays nothing: the actor
//! stays in the one shown before, run to its last frame (0x44fce8, actor.zig frameIn); in
//! OpenGorky an idle shows instead (actor.zig idleInstead, the preview too).
//! The lift pose is a slot of OpenGorky's own (`lifted`), built in until bound.
//! A new animation goes into the model first (Import animations), then gets a binding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const ir = og.script.ir;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const search = @import("search.zig");
const common_archive = @import("store.zig").common_archive;
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const picker = @import("picker.zig");
const entries = @import("entries.zig");
const lineAfter = @import("code.zig").lineAfter;

/// One `Register…Animation` call of the script, as the model lifted it (model.zig).
const Binding = struct {
    stance: []const u8,
    /// The name the game asks for; `idle` for an idle one.
    slot: []const u8,
    /// The model's animation it names: argument `fileArg` of `call`.
    file: []const u8,
    idle: bool,
    call: model.Call,

    fn fileArg(b: Binding) usize {
        return if (b.idle) 1 else 2;
    }
};

/// The bindings script `act` (a text of the Store) makes itself, in its order.
fn bindings(app: *App, a: Allocator, act: []const u8) []const Binding {
    const file = model.fileOf(app, act) orelse return &.{};
    if (model.model_og.isOg(app, file)) return ogBindings(a, act);
    var out: std.ArrayList(Binding) = .empty;
    for (model.calls(app, a, file, &.{ "RegisterAnimation", "RegisterIdleAnimation" })) |c| {
        const idle = std.ascii.eqlIgnoreCase(c.name, "RegisterIdleAnimation");
        var b: Binding = .{ .stance = model.show(a, c.args[0]), .slot = "idle", .file = "", .idle = idle, .call = c };
        if (c.args.len <= b.fileArg() or c.args[1] != .string or c.args[b.fileArg()] != .string) continue;
        b.file = c.args[b.fileArg()].string;
        if (!idle) b.slot = c.args[1].string;
        out.append(a, b) catch {};
    }
    return out.items;
}

/// An OpenGorky look block's bindings: its `Slot(state = …, name = …, anim = …)` and
/// `Idle(state = …, anim = …)` (one a line, as the writer puts them), the `anim` string's
/// span as the file argument's (setFile writes it), the element's as the call's.
fn ogBindings(a: Allocator, t: []const u8) []const Binding {
    var out: std.ArrayList(Binding) = .empty;
    var at: usize = 0;
    while (at < t.len) {
        const end = std.mem.indexOfScalarPos(u8, t, at, '\n') orelse t.len;
        defer at = end + 1;
        const l = t[at..end];
        const idle = std.mem.indexOf(u8, l, "Idle(") != null;
        const k = std.mem.indexOf(u8, l, if (idle) "Idle(" else "Slot(") orelse continue;
        const anim = strArg(l, "anim") orelse continue;
        const st = strNum(l, "state") orelse "0";
        const slot = if (idle) "idle" else (strArg(l, "name") orelse continue).text;
        const spans = a.alloc(ir.Span, 3) catch break;
        const sp: ir.Span = .{ .start = @intCast(at + anim.at - 1), .end = @intCast(at + anim.at + anim.text.len + 1) };
        @memset(spans, sp);
        const close = std.mem.lastIndexOfScalar(u8, l, ')') orelse l.len - 1;
        const call: model.Call = .{ .event = "", .name = if (idle) "Idle" else "Slot", .args = &.{}, .span = .{ .start = @intCast(at + k), .end = @intCast(at + close + 1) }, .arg_spans = spans };
        out.append(a, .{ .stance = st, .slot = slot, .file = anim.text, .idle = idle, .call = call }) catch break;
    }
    return out.items;
}

/// `name = "x"` of a line: the string and where it starts in the line.
fn strArg(l: []const u8, name: []const u8) ?struct { text: []const u8, at: usize } {
    var buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s} = \"", .{name}) catch return null;
    const i = std.mem.indexOf(u8, l, key) orelse return null;
    const from = i + key.len;
    const to = std.mem.indexOfScalarPos(u8, l, from, '"') orelse return null;
    return .{ .text = l[from..to], .at = from };
}

/// `name = 3` of a line, its digits.
fn strNum(l: []const u8, name: []const u8) ?[]const u8 {
    var buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s} = ", .{name}) catch return null;
    const i = std.mem.indexOf(u8, l, key) orelse return null;
    var e = i + key.len;
    while (e < l.len and (std.ascii.isDigit(l[e]) or l[e] == '-')) e += 1;
    return l[i + key.len .. e];
}

/// The model's animations: the core's record of it (the preview's model cache, unsaved
/// files first; read again after a model edit); null: no such model.
pub fn modelAnims(app: *App, mesh: []const u8) ?[]const og.core.model.Animation {
    const m = app.preview.modelOf(app.gpa, app.io, app.dat, .{ .ctx = app, .get = @import("entries.zig").overlayGet }, mesh) orelse return null;
    return m.anims.items;
}

pub fn has(anims: []const og.core.model.Animation, name: []const u8) bool {
    for (anims) |an| if (std.ascii.eqlIgnoreCase(an.name, name)) return true;
    return false;
}

/// The names the game's scripts ask for (every one some class registers).
const slots = [_][]const u8{
    "idle",            "walk",             "run",            "stepping",        "hit",                 "death",
    "defend",          "dodge",            "short_attack",   "long_attack",     "strafe",              "crouch",
    "jump",            "jump_start",       "jump_hang",      "jump_end",        "stair_up",            "stair_down",
    "walk_footbridge", "ladder_start",     "ladder_walk",    "ladder_end",      "push",                "push_start",
    "push_walk",       "push_end",         "pickup_start",   "pickup_wait",     "pickup_end",          "kneel_down",
    "kneel_up",        "hide",             "hide_back",      "take_out",        "scary",               "delirium",
    "delirium_up",     "use_aid",          "use_medicine",   "use_radio",       "ponton_out",          "attack_axe",
    "attack_baseball", "attack_bazooka",   "attack_blaster", "attack_boxing",   "attack_butcher",      "attack_chaingun",
    "attack_dynamit",  "attack_fireworks", "attack_flame",   "attack_grenade",  "attack_gun",          "attack_ionrifle",
    "attack_knife",    "attack_machingun", "attack_molotov", "attack_rifle",    "attack_sabre",        "attack_shocker",
    "attack_sniper",   "attack_stone",     "attack_syringe", "attack_timebomb",
    // OpenGorky's own (last: a Classic project's list stops before it).
    og.actor.slots.lifted,
};

/// OpenGorky's preview of animation `file` the model lacks, bound to a slot (as the game's
/// actor.zig idleInstead): the script's first idle the model has in that binding's stance
/// (a name under 16 letters), else in stance 0; null: not a slot's, or no such idle.
pub fn idleInstead(app: *App, a: Allocator, act: []const u8, anims: []const og.core.model.Animation, file: []const u8) ?[]const u8 {
    return idleOf(bindings(app, a, act), anims, file);
}

fn idleOf(bs: []const Binding, anims: []const og.core.model.Animation, file: []const u8) ?[]const u8 {
    if (file.len == 0 or has(anims, file)) return null;
    const stance = for (bs) |b| {
        if (!b.idle and std.ascii.eqlIgnoreCase(b.file, file)) break b.stance;
    } else return null;
    for ([_][]const u8{ stance, "0" }) |s| for (bs) |b| {
        if (b.idle and std.mem.eql(u8, b.stance, s) and b.file.len < 16 and has(anims, b.file)) return b.file;
    };
    return null;
}

test idleOf {
    const anims = [_]og.core.model.Animation{ .{ .name = "oddech", .first = 0, .last = 1, .speed = 1, .sounds = &.{} }, .{ .name = "g_idle", .first = 0, .last = 1, .speed = 1, .sounds = &.{} } };
    const B = struct {
        fn idle(stance: []const u8, file: []const u8) Binding {
            return .{ .stance = stance, .slot = "idle", .file = file, .idle = true, .call = undefined };
        }
        fn slot(stance: []const u8, s: []const u8, file: []const u8) Binding {
            return .{ .stance = stance, .slot = s, .file = file, .idle = false, .call = undefined };
        }
    };
    const bs = [_]Binding{ B.idle("0", "oddychanieszybkie"), B.idle("0", "nima"), B.idle("0", "oddech"), B.idle("1", "g_idle"), B.slot("0", "walk", "chodzenie"), B.slot("1", "walk", "g_chod") };
    try std.testing.expectEqualStrings("oddech", idleOf(&bs, &anims, "chodzenie").?);
    try std.testing.expectEqualStrings("g_idle", idleOf(&bs, &anims, "g_chod").?);
    try std.testing.expectEqual(@as(?[]const u8, null), idleOf(&bs, &anims, "nima")); // an idle's own: holds
    try std.testing.expectEqual(@as(?[]const u8, null), idleOf(&bs, &anims, "oddech"));
}

/// Bottom left: the model's animations, each with the slots naming it, then the bindings
/// to animations it lacks; a click shows one.
pub fn list(app: *App, a: Allocator, act: []const u8, mesh: []const u8, shown: []const u8) void {
    const anims = modelAnims(app, mesh) orelse &.{};
    const bs = bindings(app, a, act);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel });
    gui.panelHeader(tx.alloc(a, tx.part_anims_n, .{anims.len}));
    const q = app.anim_query.get();
    gui.searchField(app, a, "anim_search", &app.anim_query, false, tx.get(tx.anim_search), "");
    clay.openScroll(.{ .id = clay.id("anims"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (anims, 0..) |an, i| {
        var named: std.ArrayList([]const u8) = .empty;
        for (bs) |b| if (std.ascii.eqlIgnoreCase(b.file, an.name)) named.append(a, if (std.mem.eql(u8, b.stance, "0")) b.slot else std.fmt.allocPrint(a, "{s}/{s}", .{ b.slot, b.stance }) catch b.slot) catch {};
        const slot_s = std.mem.join(a, ", ", named.items) catch "";
        if (!search.matches(q, &.{ an.name, slot_s })) continue;
        row(app, a, clay.idi("anim", @intCast(i)), an.name, std.ascii.eqlIgnoreCase(an.name, shown), if (named.items.len > 0) slot_s else tx.get(tx.an_unbound), named.items.len > 0, an.last - an.first + 1, false);
    }
    // Bindings to nothing in the model: what the game can't play.
    var any = false;
    for (bs, 0..) |b, i| {
        if (has(anims, b.file) or !search.matches(q, &.{ b.slot, b.file })) continue;
        if (!any) {
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.sm, .right = lay.space.sm, .top = lay.space.sm } } });
            gui.txtWrap(tx.get(tx.an_broken_title), .caption, theme.warn, font_mod.bold);
            clay.close();
            any = true;
        }
        row(app, a, clay.idi("anim_broken", @intCast(i)), b.file, std.ascii.eqlIgnoreCase(b.file, shown), b.slot, true, 0, true);
    }
    clay.close();
    clay.close();
}

fn row(app: *App, a: Allocator, id: ui.Clay_ElementId, name: []const u8, sel: bool, sub: []const u8, bound: bool, frames: u32, broken: bool) void {
    if (gui.listRow(app, id, .{ .selected = sel, .fit = true, .rounded = false })) app.anim_name.set(name);
    // One line, cut where the list is narrow.
    gui.openClip(lay.space.sm);
    gui.txt(name, .label, if (broken) theme.warn else theme.text, if (sel) font_mod.bold else font_mod.regular);
    if (frames > 0) gui.txt(tx.alloc(a, tx.an_frames, .{frames}), .caption, theme.dim, font_mod.regular);
    clay.close();
    gui.spacer();
    gui.txtClip(sub, .caption, if (bound) theme.accent_hover else theme.dim, font_mod.regular);
    clay.close();
}

/// The bindings' line (a character's slot, the block's header): how many, how many name
/// nothing in model `mesh`.
pub fn summary(app: *App, a: Allocator, act: []const u8, mesh: []const u8) struct { text: []const u8, warn: bool } {
    const anims = modelAnims(app, mesh) orelse &.{};
    const bs = bindings(app, a, act);
    var missing: usize = 0;
    for (bs) |b| missing += @intFromBool(!has(anims, b.file));
    return .{ .text = if (missing > 0) tx.alloc(a, tx.sum_anims_missing, .{ bs.len, missing }) else tx.alloc(a, tx.sum_anims, .{bs.len}), .warn = missing > 0 };
}

/// The Animations block of look script `file` (`act` its text; its header counts the
/// bindings and those to nothing): each binding — its animation chosen from the model's,
/// removed — then import into the model, a new binding for the animation shown, the
/// missing ones bound.
pub fn section(app: *App, a: Allocator, file: usize, act: []const u8, mesh: []const u8, shown: []const u8) void {
    const anims = modelAnims(app, mesh) orelse &.{};
    const bs = bindings(app, a, act);
    const sum = summary(app, a, act, mesh);
    const missing = sum.warn;
    if (!gui.block(app, "anims", tx.get(tx.sec_anims), .{ .summary = sum.text, .warn = sum.warn })) return;
    defer gui.blockEnd();
    gui.note(tx.get(tx.an_hint));
    const og_project = app.ogLayout();
    var lift_bound = false;
    for (bs, 0..) |b, i| {
        const ok = has(anims, b.file);
        const lift = !b.idle and std.ascii.eqlIgnoreCase(b.slot, og.actor.slots.lifted);
        lift_bound = lift_bound or lift;
        const name = if (lift) tx.get(tx.an_lifted) else b.slot;
        const label = if (b.idle) tx.get(tx.an_idle) else if (std.mem.eql(u8, b.stance, "0")) name else std.fmt.allocPrint(a, "{s}/{s}", .{ name, b.stance }) catch name;
        gui.fieldRow(label);
        // A binding to a missing animation: the field in the warning colour, why under it.
        const bid = clay.idi("an_bind", @intCast(i));
        const open = picker.field(app, bid, b.file, !ok);
        if (gui.trail(app, clay.id(entries.idName(a, "an_del", i)))) remove(app, file, i);
        clay.close();
        if (open) {
            const rows = a.alloc(picker.Opt, anims.len) catch continue;
            for (anims, rows) |an, *o| o.* = .{ .key = an.name, .label = an.name, .selected = std.ascii.eqlIgnoreCase(an.name, b.file) };
            if (picker.listKey(app, a, rows)) |v| setFile(app, file, i, v) catch |err| app.failed(err);
        }
        if (!ok) gui.fieldNote(tx.get(if (og_project and !b.idle) tx.an_missing_og else tx.an_missing), theme.warn);
    }
    // The lift pose unbound: the built-in one (core module Heroes by the script's classic_id —
    // a hero's own file has it), an OpenGorky project binds its own from the model's
    // (Classic: no row).
    if (!lift_bound and og_project) {
        const builtin = og.core.modules.liftPose(.{ .id = @intFromFloat(model.ownNum(app, file, "classic_id") orelse 0) });
        gui.fieldRow(tx.get(tx.an_lifted));
        const bid = clay.id("an_lifted");
        const open = picker.field(app, bid, builtin, false);
        _ = gui.trail(app, null);
        clay.close();
        if (open) if (a.alloc(picker.Opt, anims.len)) |rows| {
            for (anims, rows) |an, *o| o.* = .{ .key = an.name, .label = an.name, .selected = false };
            if (picker.listKey(app, a, rows)) |v| add(app, file, og.actor.slots.lifted, v) catch |err| app.failed(err);
        } else |_| {};
        gui.fieldNote(tx.alloc(a, tx.an_lifted_og, .{builtin}), theme.dim);
    }
    // Import into the model, a binding for the animation shown, after a new model the
    // bindings to the old one's names onto its own of the slot's name.
    var labels: [3][]const u8 = undefined;
    const Act = enum { import, add, autobind };
    var acts: [3]Act = undefined;
    var n: usize = 0;
    labels[n] = tx.get(tx.b_anims_in);
    acts[n] = .import;
    n += 1;
    if (has(anims, shown)) {
        labels[n] = tx.alloc(a, tx.an_add, .{shown});
        acts[n] = .add;
        n += 1;
    }
    if (missing) {
        labels[n] = tx.get(tx.an_autobind);
        acts[n] = .autobind;
        n += 1;
    }
    const hit = gui.footer(app, "an_foot", labels[0..n], null);
    // A new binding's slot picked from a list under its button.
    if (n > 1 and acts[1] == .add and picker.isOpen(app, clay.idi("an_foot", 1))) if (picker.listKey(app, a, picker.names(a, if (og_project) &slots else slots[0 .. slots.len - 1]))) |v| add(app, file, v, app.anim_name.get()) catch |err| app.failed(err);
    switch (acts[hit orelse return]) {
        .import => app.askFile(.{ .kind = .glb, .run = @import("look_pages.zig").onAnimsIn }),
        .add => {
            app.anim_name.set(shown);
            picker.toggle(app, clay.idi("an_foot", 1));
        },
        .autobind => autoBind(app, file, mesh) catch |err| app.failed(err),
    }
}

/// Auto-bind on script `file` of model `mesh` (one undo step), said in the status: each
/// binding to an animation the model lacks bound to the model's animation named as its
/// slot (walk → walk, an idle one → idle), as the model spells it.
fn autoBind(app: *App, file: usize, mesh: []const u8) !void {
    const a = app.frame.allocator();
    const anims = modelAnims(app, mesh) orelse &.{};
    var sets: std.ArrayList(model.ArgSet) = .empty;
    var left: usize = 0;
    for (bindings(app, a, app.store.text(file))) |b| {
        if (has(anims, b.file)) continue;
        const to = for (anims) |an| {
            if (std.ascii.eqlIgnoreCase(an.name, b.slot)) break an.name;
        } else {
            left += 1;
            continue;
        };
        try sets.append(a, .{ .call = b.call, .index = b.fileArg(), .value = .{ .string = to } });
    }
    if (sets.items.len > 0) try model.setArgs(app, file, sets.items, tx.both(a, tx.step_anim_auto, .{}));
    app.setStatus(tx.st_autobind, .{ mesh, sets.items.len, left });
}

/// `--anim-bind ID SLOT ANIM` (SLOT's first binding set to ANIM, or one added) and
/// `--anim-autobind ID` (slot null) on entry ID's look script: an enemy's act_*.ss, a
/// hero's own file.
pub fn bindOp(app: *App, id: []const u8, slot: ?[]const u8, name: []const u8) !void {
    const i = try entries.entryById(app, id);
    entries.showEntry(app, i);
    const e = app.catalog.entries.items[i];
    var file = entries.fileOf(app, e) orelse return error.NoFile;
    if (e.kind == .enemy) {
        var buf: [128]u8 = undefined;
        file = try app.store.file(common_archive, try std.fmt.bufPrint(&buf, "classes\\{s}", .{entries.actOf(app.store.text(file)) orelse return error.NoLook}));
    }
    const mesh = model.ownStr(app, file, "mesh") orelse return error.NoLook;
    const s = slot orelse return autoBind(app, file, mesh);
    for (bindings(app, app.frame.allocator(), app.store.text(file)), 0..) |b, k| if (std.mem.eql(u8, b.slot, s)) return setFile(app, file, k, name);
    return add(app, file, s, name);
}

/// Binding `i` of script `file` names animation `name` instead (one undo step).
fn setFile(app: *App, file: usize, i: usize, name: []const u8) !void {
    const a = app.frame.allocator();
    const bs = bindings(app, a, app.store.text(file));
    if (i >= bs.len) return error.NoBinding;
    try model.setArgs(app, file, &.{.{ .call = bs[i].call, .index = bs[i].fileArg(), .value = .{ .string = name } }}, tx.both(a, tx.step_anim_bind, .{}));
}

/// Binding `i` of script `file` removed with its line (one undo step). shortcut: by
/// text, the lift cannot drop a call.
pub fn remove(app: *App, file: usize, i: usize) void {
    const t = app.store.text(file);
    const bs = bindings(app, app.frame.allocator(), t);
    if (i >= bs.len) return;
    const at = lineStart(t, bs[i].call.span.start);
    const out = std.mem.concat(app.gpa, u8, &.{ t[0..at], t[lineAfter(t, bs[i].call.span.start)..] }) catch return;
    app.store.replaceLabeled(file, out, tx.both(app.frame.allocator(), tx.step_anim_removed, .{})) catch |err| app.failed(err);
    app.pick = null;
}

/// A binding of `slot` to animation `name` added (one undo step). shortcut: by text, the
/// lift cannot add a call.
pub fn add(app: *App, file: usize, slot: []const u8, name: []const u8) !void {
    const t = app.store.text(file);
    const bs = bindings(app, app.frame.allocator(), t);
    // OpenGorky: an element after the last of its list (`slots`, `idles`).
    if (model.model_og.isOg(app, file)) {
        const idle = std.mem.eql(u8, slot, "idle");
        const last = for (0..bs.len) |k| {
            const b = bs[bs.len - 1 - k];
            if (b.idle == idle) break b;
        } else return error.NoSuchList;
        const after = lineAfter(t, last.call.span.start);
        const ls = lineStart(t, last.call.span.start);
        const l = t[ls..after];
        const indent = l[0 .. l.len - std.mem.trimStart(u8, l, " \t").len];
        const line = if (idle) try std.fmt.allocPrint(app.frame.allocator(), "{s}Idle(state = 0, anim = \"{s}\", weight = 100),\n", .{ indent, name }) else try std.fmt.allocPrint(app.frame.allocator(), "{s}Slot(state = 0, name = \"{s}\", anim = \"{s}\"),\n", .{ indent, slot, name });
        const out = try std.mem.concat(app.gpa, u8, &.{ t[0..after], line, t[after..] });
        return app.store.replaceLabeled(file, out, tx.both(app.frame.allocator(), tx.step_anim_added, .{}));
    }
    const last: ?usize = if (bs.len > 0) bs[bs.len - 1].call.span.start else null;
    try app.store.replaceLabeled(file, try withBinding(app.gpa, app.frame.allocator(), t, last, slot, name), tx.both(app.frame.allocator(), tx.step_anim_added, .{}));
}

fn lineStart(t: []const u8, i: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, t[0..i], '\n')) |k| k + 1 else 0;
}

/// `t` with a binding of `slot` to `name` after the line of its last one (at `last`; or
/// its meshFile line), indented and ended as they are; slot `idle`: an idle one, weight 20.
fn withBinding(gpa: Allocator, a: Allocator, t: []const u8, last: ?usize, slot: []const u8, name: []const u8) ![]u8 {
    const crlf = std.mem.indexOf(u8, t, "\r\n") != null;
    var at: usize = t.len;
    var indent: []const u8 = "  ";
    if (last) |p| {
        at = lineAfter(t, p);
        const l = t[lineStart(t, p)..at];
        indent = l[0 .. l.len - std.mem.trimStart(u8, l, " \t").len];
    } else if (std.mem.indexOf(u8, t, "mesh")) |m| {
        at = if (std.mem.indexOfScalarPos(u8, t, m, '\n')) |e| e + 1 else t.len;
    }
    const nl = if (crlf) "\r\n" else "\n";
    // A last line without its newline gets one first.
    const pre = if (at == t.len and t.len > 0 and t[t.len - 1] != '\n') nl else "";
    const line = if (std.mem.eql(u8, slot, "idle"))
        try std.fmt.allocPrint(a, "{s}{s}RegisterIdleAnimation(0,\"{s}\",20);{s}", .{ pre, indent, name, nl })
    else
        try std.fmt.allocPrint(a, "{s}{s}RegisterAnimation(0,\"{s}\",\"{s}\");{s}", .{ pre, indent, slot, name, nl });
    return std.mem.concat(gpa, u8, &.{ t[0..at], line, t[at..] });
}

test "withBinding: after the last one, as it is written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\tmeshFile=\"x\";\r\n\tRegisterAnimation(0,\"walk\",\"w\");\r\n\tRegisterAnimation(0,\"death\",\"smierc\");\r\n}", try withBinding(a, a, "\tmeshFile=\"x\";\r\n\tRegisterAnimation(0,\"walk\",\"w\");\r\n}", 17, "death", "smierc"));
    try std.testing.expectEqualStrings("  meshFile=\"x\";\n  RegisterIdleAnimation(0,\"i\",20);\n", try withBinding(a, a, "  meshFile=\"x\";", null, "idle", "i"));
}
