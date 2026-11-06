//! AI profiles of an OpenGorky project (`ai_profile cripple: monster { … }`, src/ai/*.ogs;
//! loaders/rules_text.zig Profiles): the profiles on the left, the shown one edited
//! beside them — its base, each field its own value or the one it inherits (a choice for
//! a word or a flag: the mode, what it plans with, the scoring component), the characters
//! and profiles using it. Each edit one undo step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const picker = @import("picker.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const ir = og.script.ir;
const mo = @import("model_og.zig");
const og_src = @import("store.zig").og_src;

/// What a field takes.
const Kind = enum { number, flag, mode, weapons, score, object };

/// `fighter`: none set, the fighter's own field of that name is used (combat/ai.zig params).
const Field = struct { name: []const u8, label: tx.Msg, kind: Kind, default: []const u8 = "", fighter: []const u8 = "" };

/// The profile's fields (rules.AiProfile, its tile scoring: rules_text.zig scoring_fields),
/// with the engine's value of a field no profile sets.
const fields = [_]Field{
    .{ .name = "weapons", .label = tx.ai_keep, .kind = .weapons, .default = "all" },
    .{ .name = "damage_bonus", .label = tx.ai_bonus, .kind = .number },
    .{ .name = "ally_penalty", .label = tx.ai_ally, .kind = .number },
    .{ .name = "lock", .label = tx.ai_lock, .kind = .number },
    .{ .name = "monitor", .label = tx.ai_monitor, .kind = .number },
    .{ .name = "decoy_pull", .label = tx.ai_pull, .kind = .number },
    .{ .name = "decoys", .label = tx.ai_decoys, .kind = .flag, .default = "false" },
    .{ .name = "step_away", .label = tx.ai_step, .kind = .flag, .default = "false" },
    .{ .name = "threat", .label = tx.ai_threat, .kind = .flag, .default = "false" },
    .{ .name = "follow_lock", .label = tx.ai_follow_lock, .kind = .flag, .default = "true" },
    .{ .name = "wakeful", .label = tx.ai_wakeful, .kind = .flag, .default = "false" },
    .{ .name = "score", .label = tx.ai_score, .kind = .score },
    .{ .name = "near", .label = tx.ai_near, .kind = .object },
};

/// The fighter's own fields a profile may set for all its fighters.
const fighter_fields = [_]Field{
    .{ .name = "mode", .label = tx.ai_mode, .kind = .mode, .fighter = "ai_mode" },
    .{ .name = "attack_weight", .label = tx.ai_attack, .kind = .number, .fighter = "ai_attack_weight" },
    .{ .name = "threat_weight", .label = tx.ai_defense, .kind = .number, .fighter = "ai_threat_weight" },
    .{ .name = "opponent_distance_weight", .label = tx.ai_player, .kind = .number, .fighter = "ai_opponent_distance_weight" },
    .{ .name = "guard_distance_weight", .label = tx.ai_guard, .kind = .number, .fighter = "ai_guard_distance_weight" },
};

const mode_names = [_][]const u8{ "free", "target", "passive", "guard" };
const mode_labels = [_]tx.Msg{ tx.aim_free, tx.aim_target, tx.aim_passive, tx.aim_guard };
const weapon_names = std.meta.fieldNames(@FieldType(og.core.behaviour.Scoring, "keep"));

/// The project's profiles: `ai::<name>` of each src/ai/<name>.ogs, in name order.
pub fn profiles(app: *App, a: Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (app.store.listing(a, og_src, null, true)) |p| {
        if (!std.mem.startsWith(u8, p, "ai/") or !std.mem.endsWith(u8, p, ".ogs") or std.mem.indexOfScalarPos(u8, p, 3, '/') != null) continue;
        out.append(a, std.fmt.allocPrint(a, "ai::{s}", .{p[3 .. p.len - 4]}) catch continue) catch {};
    }
    return out.items;
}

/// Profile `path`'s block (its file's main block).
fn block(app: *App, a: Allocator, path: []const u8) ?struct { file: usize, e: *const ir.Entity } {
    const f = mo.archetypeFile(app, path) orelse return null;
    const b = mo.blockOf(app, a, f) orelse return null;
    return .{ .file = f, .e = b.e };
}

/// Its base's path (`monster` → `ai::monster`); "" none.
fn baseOf(a: Allocator, e: *const ir.Entity) []const u8 {
    if (e.base.len == 0) return "";
    if (std.mem.indexOf(u8, e.base, "::") != null) return e.base;
    return std.fmt.allocPrint(a, "ai::{s}", .{e.base}) catch "";
}

/// Field `name`'s value as written in `path` or the first base setting it, and where.
fn valueOf(app: *App, a: Allocator, path: []const u8, name: []const u8) ?struct { text: []const u8, from: []const u8 } {
    var p = path;
    var depth: usize = 0;
    while (p.len > 0 and depth < 8) : (depth += 1) {
        const b = block(app, a, p) orelse return null;
        for (b.e.fields) |f| if (std.mem.eql(u8, f.name, name)) {
            var w: std.Io.Writer.Allocating = .init(a);
            og.script.ogs.print.expression(&w.writer, f.value) catch return null;
            return .{ .text = w.written(), .from = p };
        };
        p = baseOf(a, b.e);
    }
    return null;
}

pub fn page(app: *App, a: Allocator) void {
    const pid = clay.id("ai_page");
    clay.openScrollColumn(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.md), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.pageHeader(app, .swords, tx.get(tx.aip_title), tx.get(tx.aip_og_hint));
    clay.close();
    gui.form(pid, lay.width.label_md, lay.space.xl + lay.block.pad_x);
    const all = profiles(app, a);
    shown(app, a, all, app.rules_page.aiPath());
    clay.closeScrollColumn();
}

fn shown(app: *App, a: Allocator, all: []const []const u8, path: []const u8) void {
    const b = block(app, a, path) orelse {
        if (gui.block(app, "aip_none", tx.get(tx.aip_title), .{})) {
            gui.note(tx.get(tx.aip_pick));
            gui.blockEnd();
        }
        return;
    };
    if (gui.block(app, "aip_shown", path, .{})) {
        // Its base: another profile, or none.
        const base = baseOf(a, b.e);
        const bid = clay.id("aip_base");
        if (picker.row(app, bid, tx.get(tx.aip_base), if (base.len > 0) base else "—")) {
            var opts: std.ArrayList(picker.Opt) = .empty;
            opts.append(a, .{ .key = "", .label = "—", .selected = base.len == 0 }) catch {};
            for (all) |p| if (!std.mem.eql(u8, p, path)) opts.append(a, .{ .key = p, .label = p, .selected = std.mem.eql(u8, p, base) }) catch {};
            if (picker.listKey(app, a, opts.items)) |k| setBase(app, b.file, b.e, path, k) catch |err| app.failed(err);
        }
        gui.fieldNote(tx.get(tx.aip_base_note), theme.dim);
        for (fields, 0..) |f, i| fieldRow(app, a, path, b.file, f, @intCast(i));
        gui.subhead(tx.get(tx.aip_sub_fighter));
        for (fighter_fields, 0..) |f, i| fieldRow(app, a, path, b.file, f, @intCast(fields.len + i));
        gui.fieldNote(tx.get(tx.aip_fighter_note), theme.dim);
        gui.blockEnd();
    }
    usedBy(app, a, all, path);
}

fn fieldRow(app: *App, a: Allocator, path: []const u8, file: usize, f: Field, i: u32) void {
    const v = valueOf(app, a, path, f.name);
    const own = v != null and std.mem.eql(u8, v.?.from, path);
    // None set: the fighter's own field (empty), else the engine's value.
    const text = if (v) |x| x.text else if (f.fighter.len > 0) "" else f.default;
    gui.fieldRow(tx.get(f.label));
    switch (f.kind) {
        .number => if (gui.textField(app, std.fmt.allocPrint(a, "aip_f_{s}", .{f.name}) catch "aip_f", text, gui.cellWidth(2, true), "—")) |t| set(app, file, f.name, t) catch |err| app.failed(err),
        .flag => {
            const on = std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1");
            if (gui.check(app, clay.idi("aip_flag", i), on, "")) set(app, file, f.name, if (on) "false" else "true") catch |err| app.failed(err);
        },
        .mode, .weapons, .score => {
            const id = clay.idi("aip_pick", i);
            const shown_text = switch (f.kind) {
                .mode => if (text.len > 0) modeLabel(text) else "—",
                else => if (text.len > 0) text else "—",
            };
            if (picker.field(app, id, shown_text, false)) if (picker.listKey(app, a, options(app, a, f.kind, text))) |k| set(app, file, f.name, k) catch |err| app.failed(err);
        },
        .object => if (gui.textField(app, std.fmt.allocPrint(a, "aip_f_{s}", .{f.name}) catch "aip_f", text, gui.cellWidth(2, true), "—")) |t| set(app, file, f.name, if (t.len > 0 and t[0] != '@') std.fmt.allocPrint(a, "@{s}", .{t}) catch t else t) catch |err| app.failed(err),
    }
    // Inherited (dim, from which), or its own with a reset.
    if (own) {
        if (gui.smallButton(app, clay.idi("aip_reset", i), tx.get(tx.aip_reset))) set(app, file, f.name, "") catch |err| app.failed(err);
    } else gui.txtClip(if (v) |x| tx.alloc(a, tx.aip_from, .{x.from}) else if (f.fighter.len > 0) tx.alloc(a, tx.aip_fighter, .{f.fighter}) else tx.get(tx.aip_engine), .caption, theme.dim, font_mod.regular);
    clay.close();
}

fn modeLabel(text: []const u8) []const u8 {
    const n = std.fmt.parseInt(usize, text, 10) catch {
        for (mode_names, mode_labels) |m, l| if (std.mem.eql(u8, m, text)) return tx.get(l);
        return text;
    };
    return if (n < mode_labels.len) tx.get(mode_labels[n]) else text;
}

fn options(app: *App, a: Allocator, k: Kind, cur: []const u8) []const picker.Opt {
    var out: std.ArrayList(picker.Opt) = .empty;
    switch (k) {
        .mode => for (mode_labels, 0..) |l, n| {
            const key = std.fmt.allocPrint(a, "{d}", .{n}) catch continue;
            out.append(a, .{ .key = key, .label = tx.get(l), .note = mode_names[n], .selected = std.mem.eql(u8, key, cur) }) catch {};
        },
        .weapons => for (weapon_names) |n| out.append(a, .{ .key = n, .label = n, .selected = std.mem.eql(u8, n, cur) }) catch {},
        .score => {
            out.append(a, .{ .key = "", .label = "—", .note = tx.get(tx.aip_score_none), .selected = cur.len == 0 }) catch {};
            // The project's scoring components (components/ai_scoring/*.ogs).
            for (app.store.listing(a, og_src, null, true)) |p| {
                if (!std.mem.startsWith(u8, p, "components/ai_scoring/") or !std.mem.endsWith(u8, p, ".ogs")) continue;
                const n = std.fmt.allocPrint(a, "ai_scoring::{s}", .{p["components/ai_scoring/".len .. p.len - 4]}) catch continue;
                out.append(a, .{ .key = n, .label = n, .selected = std.mem.eql(u8, n, cur) }) catch {};
            }
        },
        else => {},
    }
    return out.items;
}

/// Field `name` of the profile in `file` made `v` (OG Script); "" its own one taken out.
fn set(app: *App, file: usize, name: []const u8, v: []const u8) !void {
    const t = std.mem.trim(u8, v, " ");
    if (t.len == 0) try mo.unset(app, file, &.{name}) else try mo.set(app, file, &.{name}, t);
    @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_camp_set, .{ name, if (t.len > 0) t else "—" });
}

/// The profile's base made `base` ("" none): its block's head rewritten.
fn setBase(app: *App, file: usize, e: *const ir.Entity, path: []const u8, base: []const u8) !void {
    const a = app.frame.allocator();
    const name = path["ai::".len..];
    const t = app.store.text(file);
    const head_old = if (e.base.len > 0) try std.fmt.allocPrint(a, "ai_profile {s}: {s} {{", .{ name, e.base }) else try std.fmt.allocPrint(a, "ai_profile {s} {{", .{name});
    const short = if (std.mem.startsWith(u8, base, "ai::")) base["ai::".len..] else base;
    const head_new = if (base.len > 0) try std.fmt.allocPrint(a, "ai_profile {s}: {s} {{", .{ name, short }) else try std.fmt.allocPrint(a, "ai_profile {s} {{", .{name});
    if (std.mem.indexOf(u8, t, head_old) == null) return error.NoSuchBlock;
    try app.store.replace(file, try std.mem.replaceOwned(u8, app.gpa, t, head_old, head_new));
    @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_camp_set, .{ "base", if (base.len > 0) base else "—" });
}

/// The characters naming the profile (`ai_profile = ai::x`), the profiles built on it.
fn usedBy(app: *App, a: Allocator, all: []const []const u8, path: []const u8) void {
    if (!gui.block(app, "aip_used", tx.get(tx.aip_used), .{})) return;
    var any = false;
    const want = std.fmt.allocPrint(a, "ai_profile = {s};", .{path}) catch return;
    for (app.store.listing(a, og_src, null, true)) |p| {
        if (!std.mem.startsWith(u8, p, "characters/")) continue;
        const f = app.store.file(og_src, p) catch continue;
        if (std.mem.indexOf(u8, app.store.text(f), want) == null) continue;
        any = true;
        if (gui.listRow(app, clay.id(std.fmt.allocPrint(a, "aip_used_{s}", .{p}) catch "aip_used"), .{ .h = lay.height.small })) @import("doctabs.zig").showCode(app, f, null);
        gui.icon(app, .user, lay.icon.md, theme.dim);
        gui.txt(p, .body, theme.accent_hover, font_mod.regular);
        clay.close();
    }
    for (all) |p| {
        const b = block(app, a, p) orelse continue;
        if (!std.mem.eql(u8, baseOf(a, b.e), path)) continue;
        any = true;
        if (gui.listRow(app, clay.id(std.fmt.allocPrint(a, "aip_child_{s}", .{p}) catch "aip_child"), .{ .h = lay.height.small })) @import("doctabs.zig").show(app, .ai_profiles, p);
        gui.icon(app, .swords, lay.icon.md, theme.dim);
        gui.txt(p, .body, theme.accent_hover, font_mod.regular);
        clay.close();
    }
    if (!any) gui.note(tx.get(tx.aip_unused));
    gui.blockEnd();
}
