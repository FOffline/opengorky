//! Rules pages (OpenGorky): experience levels (ExpLevel), special values (Value), AI
//! profiles (AiProfile, AiScoring) and actions (Action), the rules' party.ss, ai.ss and
//! actions.ss rows as fields. Each edit writes
//! its row by its key into the layer's rules file (rules_rows.put/drop, one undo step).
//! The files only add rows or write over built-in ones (rules_text.apply): a built-in row
//! is reset (the file's row dropped), never removed. Classic: the exe's values read-only
//! under the lock that converts the project.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const texts = @import("texts.zig");
const model = @import("model.zig");
const rulesapi = @import("rulesapi.zig");
const rules_rows = @import("rules_rows.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;
const info = @import("info.zig");
const ea = @import("entry_attacks.zig");
const picker = @import("picker.zig");
const Doc = @import("level.zig").Doc;

/// The pages' state (`app.rules_page`).
pub const State = struct {
    /// Actions: the action shown.
    act: ?i32 = null,
    /// AI profiles: the row shown (its index in the rules in force).
    /// shortcut: an index, another row after a row is added before it; upgrade to its key if that shows.
    ai: ?usize = null,
    /// OpenGorky: the profile block shown (`ai::cripple`; aipage.zig).
    ai_buf: [96]u8 = undefined,
    ai_len: usize = 0,

    pub fn aiPath(s: *const State) []const u8 {
        return s.ai_buf[0..s.ai_len];
    }

    pub fn setAiPath(s: *State, p: []const u8) void {
        s.ai_len = @min(p.len, s.ai_buf.len);
        @memcpy(s.ai_buf[0..s.ai_len], p[0..s.ai_len]);
    }
};

/// Field `field`'s doc of rules call `call` (rulesapi), in the interface language.
fn doc(call: []const u8, field: []const u8) []const u8 {
    const c = rulesapi.find(call) orelse return "";
    return if (rulesapi.field(c, field)) |f| tx.get(f.doc) else "";
}

fn num(text: []const u8) !i32 {
    return std.fmt.parseInt(i32, std.mem.trim(u8, text, " "), 10) catch error.BadNumber;
}

/// A page's scroll column and header (the row left open for its actions).
pub fn head(app: *App, comptime id: []const u8, ic: @import("icons.zig").Icon, title: tx.Msg, hint: tx.Msg) void {
    const pid = clay.id(id);
    clay.openScrollColumn(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.md), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.pageHeader(app, ic, tx.get(title), tx.get(hint));
}

/// The page's form (Classic: its values read-only).
pub fn form(pid: []const u8) void {
    gui.form(clay.id(pid), lay.width.label_md, lay.space.xl + lay.block.pad_x);
}

/// A value's field (OpenGorky) or its text (Classic) in an open `fieldRow`.
fn valueField(app: *App, id: []const u8, shown: []const u8, w: f32) ?[]const u8 {
    if (app.ogLayout()) return gui.textField(app, id, shown, w, "—");
    gui.txt(shown, .body, theme.text, font_mod.regular);
    return null;
}

// ---------------------------------------------------------------- experience levels

/// OpenGorky: field `name` of the game block (src/game.ogs) made `v` (OG Script as typed);
/// the game's rules live there (loaders/rules_text.zig settingsRows): `exp_levels`, the
/// formulas' numbers, `states`.
fn setGame(app: *App, name: []const u8, v: []const u8) !void {
    const f = try app.store.file(@import("store.zig").og_src, "game.ogs");
    try @import("model_og.zig").set(app, f, &.{name}, v);
    app.setStatus(tx.st_camp_set, .{ name, v });
}

/// The thresholds in force, in level order, `level`'s made `n` (null: as they are), as
/// `[0, 220, …]` (the game block's `exp_levels`).
fn expList(a: Allocator, level: ?i32, n: i32, extra: ?i32) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeByte('[');
    const top = rules.maxLevel();
    var l: i32 = 0;
    while (l <= top) : (l += 1) {
        if (l > 0) try w.writer.writeAll(", ");
        try w.writer.print("{d}", .{if (level != null and level.? == l) n else rules.expLevel(l)});
    }
    if (extra) |x| try w.writer.print(", {d}", .{x});
    try w.writer.writeByte(']');
    return w.written();
}

/// The built-in threshold of `level` (null: a level the project added).
fn builtinExp(level: i32) ?i32 {
    for (rules.builtin.exp_levels) |r| if (r.level == level) return r.exp;
    return null;
}

/// Level `level`'s threshold typed as `text`, refused unless the thresholds keep growing.
pub fn setExp(app: *App, level: i32, text: []const u8) !void {
    const n = try num(text);
    if (!rules.expGrows(rules.active.exp_levels, level, n)) return error.ThresholdsMustGrow;
    if (app.ogLayout()) return setGame(app, "exp_levels", try expList(app.frame.allocator(), level, n, null));
    try rules_rows.putSaid(app, rules.ExpLevel, .{ .level = level, .exp = n });
}

/// A level after the last, twice its threshold.
pub fn addLevel(app: *App) !void {
    const top = rules.maxLevel();
    const next = std.math.mul(i32, @max(1, rules.expLevel(top)), 2) catch return error.Overflow;
    if (app.ogLayout()) return setGame(app, "exp_levels", try expList(app.frame.allocator(), null, 0, next));
    try rules_rows.putSaid(app, rules.ExpLevel, .{ .level = top + 1, .exp = next });
}

/// The last level dropped: only one the project added (a built-in level stays).
pub fn removeLevel(app: *App) !void {
    const top = rules.maxLevel();
    if (builtinExp(top) != null) return error.BuiltInLevel;
    if (app.ogLayout()) {
        // The list without its last.
        const t = try expList(app.frame.allocator(), null, 0, null);
        const cut = std.mem.lastIndexOf(u8, t, ", ") orelse return error.BuiltInLevel;
        try setGame(app, "exp_levels", try std.fmt.allocPrint(app.frame.allocator(), "{s}]", .{t[0..cut]}));
        return app.setStatus(tx.st_xp_removed, .{top});
    }
    if (!try rules_rows.drop(app, rules.ExpLevel, .{ .level = top, .exp = 0 })) return error.NotInPartySs;
    app.setStatus(tx.st_xp_removed, .{top});
}

pub fn expPage(app: *App, a: Allocator) void {
    head(app, "exp_page", .layers, tx.xp_title, tx.xp_hint);
    clay.close();
    form("exp_page");
    expBlock(app, a);
    clay.closeScrollColumn();
}

/// The experience levels' block (the Game page's too).
pub fn expBlock(app: *App, a: Allocator) void {
    const top = rules.maxLevel();
    if (gui.block(app, "xp_levels", tx.get(tx.xp_sec), .{ .summary = tx.alloc(a, tx.xp_sum, .{top}) })) {
        var l: i32 = 0;
        while (l <= top) : (l += 1) {
            const v = rules.expLevel(l);
            const built = builtinExp(l);
            gui.fieldRow(tx.alloc(a, tx.xp_level, .{l}));
            if (valueField(app, std.fmt.allocPrint(a, "xp_{d}", .{l}) catch "xp", std.fmt.allocPrint(a, "{d}", .{v}) catch "", lay.width.field)) |t| setExp(app, l, t) catch |err| {
                if (err == error.ThresholdsMustGrow) app.setStatus(tx.st_xp_order, .{ l, t }) else rules_rows.failed(app, "exp", err);
            };
            if (built) |b| {
                if (b != v) gui.txt(tx.alloc(a, tx.rp_builtin, .{b}), .caption, theme.warn, font_mod.regular);
            } else gui.txt(tx.get(tx.rp_added), .caption, theme.warn, font_mod.regular);
            gui.spacer();
            // The last level, the project's: its ×.
            if (gui.trail(app, if (app.ogLayout() and l == top and built == null) clay.id("xp_remove") else null)) removeLevel(app) catch |err| rules_rows.failed(app, "level", err);
            clay.close();
        }
        if (app.ogLayout() and gui.footer(app, "xp_add", &.{tx.get(tx.xp_add)}, null) != null) addLevel(app) catch |err| rules_rows.failed(app, "level", err);
        gui.note(tx.get(tx.xp_note));
        gui.blockEnd();
    }
}

// ---------------------------------------------------------------- special values

/// The values naming a fighter by classic_id (none now: the Incubus's glow is rules Glow).
const fighters = [_]rules.Const{};

/// Value `c` typed as `text`; party_max through the hero page's writer (its 3…12).
pub fn setValue(app: *App, c: rules.Const, text: []const u8) !void {
    if (c == .party_max) {
        if (!app.ogLayout()) return error.ClassicProject;
        try @import("entry_attacks.zig").setHero(app, .{ .id = 0 }, "party_max", text);
        return app.setStatus(tx.st_rules_row, .{rules_rows.rowText(app.frame.allocator(), rules.Value, .{ .name = c, .value = rules.value(c) })});
    }
    const n = try num(text);
    if (n < 0) return error.Negative;
    if (app.ogLayout()) return setGame(app, @tagName(c), try std.fmt.allocPrint(app.frame.allocator(), "{d}", .{n}));
    try rules_rows.putSaid(app, rules.Value, .{ .name = c, .value = n });
}

/// The hero or enemy of classic_id `id`: "Medusa · medusa".
fn fighterName(app: *App, a: Allocator, id: i32) ?[]const u8 {
    for (app.catalog.entries.items) |e| if ((e.kind == .enemy or e.kind == .hero) and e.name_id == id) return std.fmt.allocPrint(a, "{s} · {s}", .{ e.title, e.id }) catch e.id;
    return null;
}

pub fn valuesPage(app: *App, a: Allocator) void {
    head(app, "values_page", .crosshair, tx.val_title, tx.val_hint);
    clay.close();
    form("values_page");
    valuesBlocks(app, a);
    clay.closeScrollColumn();
}

/// The special values' blocks (the Game page's too).
pub fn valuesBlocks(app: *App, a: Allocator) void {
    if (gui.block(app, "val_limits", tx.get(tx.val_sec_limits), .{})) {
        valueRow(app, a, .idle_ticks);
        valueRow(app, a, .party_max);
        gui.fieldNote(tx.get(tx.val_party_note), theme.dim);
        gui.blockEnd();
    }
    if (gui.block(app, "val_battle", tx.get(tx.val_sec_battle), .{})) {
        for ([_]rules.Const{ .kill_exp_pm, .level_points, .stat_cap, .skill_step, .crit_pm, .rage_pm, .side_bonus, .back_bonus, .counter_step, .lose_on_hero_death }) |c| valueRow(app, a, c);
        gui.fieldNote(tx.get(tx.val_battle_note), theme.dim);
        gui.blockEnd();
    }
}

// ---------------------------------------------------------------- fighter states

/// The fighter states the game sets (core/fight.zig StateEffect): how long, the damage by turn.
const states = [_]rules.Effect{ .burn, .freeze, .gas, .soak, .sleep, .bite };

/// The fighter states' block (the Game page's): each one's turns and its damage by turn
/// (`15 10 5`), written as the game block's `states`.
pub fn statesBlock(app: *App, a: Allocator) void {
    if (!gui.block(app, "g_states", tx.get(tx.g_sec_states), .{})) return;
    for (states) |e| {
        const r = og.core.modules.stateEffect(e);
        gui.fieldRow(@tagName(e));
        var dw: std.Io.Writer.Allocating = .init(a);
        for (r.damage, 0..) |d, i| dw.writer.print("{s}{d}", .{ if (i > 0) " " else "", d }) catch {};
        if (gui.numberField(app, a, std.fmt.allocPrint(a, "st_t_{t}", .{e}) catch "st_t", tx.get(tx.g_state_turns), @floatFromInt(r.turns), gui.cellWidth(2, false))) |v| setState(app, e, @intFromFloat(@round(v)), null) catch |err| rules_rows.failed(app, "states", err);
        if (gui.textField(app, std.fmt.allocPrint(a, "st_d_{t}", .{e}) catch "st_d", dw.written(), gui.cellWidth(2, false), tx.get(tx.g_state_damage))) |t| setState(app, e, null, t) catch |err| rules_rows.failed(app, "states", err);
        clay.close();
    }
    gui.fieldNote(tx.get(tx.g_states_note), theme.dim);
    gui.blockEnd();
}

/// State `e`'s turns or damage (`15 10 5`) set: the game block's `states` written anew.
fn setState(app: *App, e: rules.Effect, turns: ?i32, damage: ?[]const u8) !void {
    const a = app.frame.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeByte('[');
    var n: usize = 0;
    for (states) |x| {
        const r = og.core.modules.stateEffect(x);
        const t = if (x == e and turns != null) turns.? else r.turns;
        var dmg: std.ArrayList(i32) = .empty;
        if (x == e and damage != null) {
            var it = std.mem.tokenizeAny(u8, damage.?, " ,");
            while (it.next()) |d| try dmg.append(a, try num(d));
        } else try dmg.appendSlice(a, r.damage);
        if (t == 0 and dmg.items.len == 0) continue;
        try w.writer.print("{s}StateEffect(effect = {t}", .{ if (n > 0) ", " else "", x });
        if (t != 0) try w.writer.print(", turns = {d}", .{t});
        if (dmg.items.len > 0) {
            try w.writer.writeAll(", damage = [");
            for (dmg.items, 0..) |d, i| try w.writer.print("{s}{d}", .{ if (i > 0) ", " else "", d });
            try w.writer.writeByte(']');
        }
        try w.writer.writeByte(')');
        n += 1;
    }
    try w.writer.writeByte(']');
    try setGame(app, "states", w.written());
}

fn valueRow(app: *App, a: Allocator, c: rules.Const) void {
    const v = rules.value(c);
    const is_fighter = std.mem.indexOfScalar(rules.Const, &fighters, c) != null;
    gui.fieldRow(@tagName(c));
    if (valueField(app, std.fmt.allocPrint(a, "val_{t}", .{c}) catch "val", std.fmt.allocPrint(a, "{d}", .{v}) catch "", lay.width.field)) |t| setValue(app, c, t) catch |err| rules_rows.failed(app, @tagName(c), err);
    const pid = valuePick(c);
    if (is_fighter and app.ogLayout() and gui.smallButton(app, pid, tx.get(tx.camp_pick))) picker.toggle(app, pid);
    clay.close();
    if (rulesapi.find("Value")) |call| if (rulesapi.field(call, "name")) |f| if (rulesapi.word(f, @tagName(c))) |w| gui.fieldNote(tx.get(w.doc), theme.dim);
    if (is_fighter) {
        const name = fighterName(app, a, v);
        gui.fieldNote(name orelse tx.get(tx.val_none), if (name == null) theme.warn else theme.dim);
    }
    const d = og.rules.builtin.values[@backingInt(c)].value;
    if (d != v) gui.fieldNote(tx.alloc(a, tx.rp_builtin, .{d}), theme.warn);
    if (!picker.isOpen(app, pid)) return;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (app.catalog.entries.items) |e| {
        if (!(e.kind == .enemy or e.kind == .hero)) continue;
        const id = e.name_id orelse continue;
        rows.append(a, .{ .key = std.fmt.allocPrint(a, "{d}", .{id}) catch continue, .label = std.fmt.allocPrint(a, "{d} · {s} · {s}", .{ id, e.title, e.id }) catch continue, .selected = id == v }) catch {};
    }
    if (picker.list(app, a, rows.items)) |j| setValue(app, c, rows.items[j].key) catch |err| rules_rows.failed(app, @tagName(c), err);
}

/// The button opening special value `c`'s fighter list.
pub fn valuePick(c: rules.Const) ui.Clay_ElementId {
    return clay.idi("val_pick", @backingInt(c));
}

// ---------------------------------------------------------------- AI profiles

const ai_fields = .{
    .{ "scoring", tx.ai_eval, ea.eval_choice },    .{ "attack_weight", tx.ai_attack },          .{ "threat_weight", tx.ai_defense },
    .{ "opponent_distance_weight", tx.ai_player }, .{ "guard_distance_weight", tx.ai_guard },   .{ "mode", tx.ai_mode, ea.mode_choice },
    .{ "damage_bonus", tx.ai_bonus },              .{ "ally_penalty", tx.ai_ally },             .{ "lock", tx.ai_lock },
    .{ "monitor", tx.ai_monitor },                 .{ "decoy_pull", tx.ai_pull },               .{ "decoys", tx.ai_decoys, ea.flag_choice },
    .{ "step_away", tx.ai_step, ea.flag_choice },  .{ "threat", tx.ai_threat, ea.flag_choice }, .{ "generic_ai", tx.ai_generic },
};

fn applyAi(key: rules.AiProfile, app: *App, field: []const u8, text: []const u8) !void {
    try setAi(app, key, field, text);
}

/// The AiProfile row of `key`'s key (in force, else `key`) with `field` = `text`.
pub fn setAi(app: *App, key: rules.AiProfile, field: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const base = rules_rows.inForce(rules.AiProfile, "ai_profiles", key) orelse key;
    try rules_rows.putField(app, rules.AiProfile, base, field, text);
    app.setStatus(tx.st_rule_set, .{ field, ea.profileName(app.frame.allocator(), key) });
}

/// The AI profiles in the frame (a component: an enemy only picks one): the list on the
/// stage, the shown profile's fields and where it is used in the constructor.
pub fn aiPage(app: *App, a: Allocator) void {
    // OpenGorky: the profiles are blocks (aipage.zig).
    if (app.ogLayout()) return @import("aipage.zig").page(app, a);
    @import("frame.zig").stage(app);
    head(app, "ai_page", .swords, tx.aip_title, tx.aip_hint);
    clay.close();
    form("ai_page");
    if (gui.block(app, "aip_list", tx.get(tx.aip_sec), .{ .summary = tx.alloc(a, tx.aip_sum, .{rules.active.ai_profiles.len}) })) {
        for (rules.active.ai_profiles, 0..) |r, k| {
            const sel = app.rules_page.ai == k;
            if (gui.listRow(app, clay.idi("aip_row", @intCast(k)), .{ .selected = sel })) @import("doctabs.zig").show(app, .ai_profiles, if (sel) "" else std.fmt.allocPrint(a, "{d}", .{k}) catch "");
            gui.txt(ea.profileName(a, r), .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
            gui.txtClip(r.note, .caption, theme.dim, font_mod.regular);
            gui.spacer();
            gui.txt(if (r.profile.len > 0) r.profile else r.scoring orelse "—", .caption, theme.dim, font_mod.regular);
            clay.close();
        }
        gui.blockEnd();
    }
    clay.closeScrollColumn();
    @import("frame.zig").props(app, "aip_props");
    aiProps(app, a);
    clay.closeScrollColumn();
}

/// Where row `r` is written: OpenGorky its rules file (`rules/ai.ogs`), a button opening the
/// code at the row; Classic the game's built-in table (rules\<file>.ss over it).
fn rowSource(app: *App, a: Allocator, comptime Row: type, r: Row, comptime id: []const u8) void {
    if (!app.ogLayout()) return gui.txtClip("rules\\" ++ Row.file ++ ".ss", .caption, theme.dim, font_mod.regular);
    // A profile of an `ai_profile` block (rules_text Profiles): that block's file.
    if (Row == rules.AiProfile and r.profile.len > 0) {
        const f = @import("model_og.zig").archetypeFile(app, r.profile) orelse return gui.txtClip(r.profile, .caption, theme.dim, font_mod.regular);
        if (gui.smallButton(app, clay.id(id), r.profile)) @import("doctabs.zig").showCode(app, f, null);
        return;
    }
    const entry = rules_rows.entryOfRow(Row, r);
    const f = app.store.file(@import("store.zig").og_src, entry) catch return gui.txtClip(entry, .caption, theme.dim, font_mod.regular);
    const at = if (rules_rows.span(a, Row, app.store.text(f), r)) |sp| sp[0] else null;
    if (gui.smallButton(app, clay.id(id), entry)) @import("doctabs.zig").showCode(app, f, at);
}

/// The shown profile: its head, its fields (Classic: as text), its eval's tile scoring,
/// the enemies using it.
fn aiProps(app: *App, a: Allocator) void {
    const k = app.rules_page.ai orelse return gui.note(tx.get(tx.aip_pick));
    if (k >= rules.active.ai_profiles.len) return gui.note(tx.get(tx.aip_pick));
    const r = rules.active.ai_profiles[k];
    gui.headCard();
    gui.txtWrap(ea.profileName(a, r), .heading, theme.text, font_mod.bold);
    gui.row(lay.space.sm);
    gui.chip(tx.get(tx.chip_ai));
    rowSource(app, a, rules.AiProfile, r, "aip_src");
    clay.close();
    if (r.note.len > 0) gui.note(r.note);
    gui.blockEnd();
    gui.groupTitle(tx.get(tx.sec_props), true);
    if (app.ogLayout()) ea.fieldRows(app, a, rules.AiProfile, r, ai_fields, "ai", r, applyAi) else inline for (ai_fields) |fl| gui.propRow(tx.get(fl[1]), rules_rows.fieldText(a, rules.AiProfile, r, fl[0]));
    gui.fieldNote(tx.get(tx.ai_note), theme.dim);
    scoringRows(app, a, r.scoring orelse "generic");
    gui.blockEnd();
    const n = std.fmt.allocPrint(a, "{d}", .{k}) catch return;
    @import("look_pages.zig").infoBlock(app, a, std.fmt.allocPrint(a, "aip:{s}", .{n}) catch n, n, aiInfo);
}

/// A profile's Info: the enemy classes using it (its own row, else their classType's).
fn aiInfo(ctx: []const u8, app: *App, list: *info.List) void {
    const k = std.fmt.parseInt(usize, ctx, 10) catch return;
    const entries = @import("entries.zig");
    const n = list.rows.items.len;
    for (app.catalog.entries.items, 0..) |e, i| {
        if (e.kind != .enemy) continue;
        const text = app.store.text(entries.fileOf(app, e) orelse continue);
        if (ea.profileOf(entries.enemyWho(app, e, text), @intFromFloat(model.get(text, "battle_class") orelse 0)) == k) list.add(.{ .group = .used, .text = info.entryText(list, e), .to = .{ .entry = i }, .icon = .user });
    }
    info.usedNone(list, n, tx.aip_used_none);
}

// ---------------------------------------------------------------- AI scoring (AiScoring)

const Scoring = og.core.behaviour.Scoring;

/// OpenGorky: profile `eval`'s (its path, `ai::garcia`; a bare name is `ai::`'s) scoring
/// field `field` = `text` in its block (loaders/rules_text.zig Profiles): `weapons` a
/// word (`all`: none), `follow_lock` and `wakeful` true/false (the default: none), `score`
/// a component (""), `near` an object's name (`@grandma`; "": none).
pub fn setScoring(app: *App, eval: rules.AiEval, field: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const a = app.frame.allocator();
    const mo = @import("model_og.zig");
    const path = if (std.mem.indexOf(u8, eval, "::") != null) eval else try std.fmt.allocPrint(a, "ai::{s}", .{eval});
    const f = mo.archetypeFile(app, path) orelse return error.NoSuchBlock;
    const t = std.mem.trim(u8, text, " \t");
    const none = t.len == 0 or (std.mem.eql(u8, field, "weapons") and std.mem.eql(u8, t, "all")) or
        (std.mem.eql(u8, field, "follow_lock") and std.mem.eql(u8, t, "true")) or (std.mem.eql(u8, field, "wakeful") and std.mem.eql(u8, t, "false"));
    if (none) {
        mo.edit(app, f, .{ .field = .{ .name = field, .value = null } }) catch |err| if (err != error.NoSuchBlock) return err;
    } else if (std.mem.eql(u8, field, "near")) {
        try mo.set(app, f, &.{field}, if (t[0] == '@') t else try std.fmt.allocPrint(a, "@{s}", .{t}));
    } else try mo.set(app, f, &.{field}, t);
    @import("entry_rules.zig").sync(app);
    app.setStatus(tx.st_rule_set, .{ field, path });
}

/// The tile scoring of profile eval `eval`: what it plans with, an occupant's worth, the
/// tile scored whole, wakeful, near; who else has this eval (the row is theirs too).
fn scoringRows(app: *App, a: Allocator, eval: rules.AiEval) void {
    const s = og.core.modules.aiScoring(eval).*;
    gui.groupTitle(tx.alloc(a, tx.ai_scoring, .{eval}), false);
    if (!app.ogLayout()) {
        inline for (.{ .{ "keep", tx.ai_keep }, .{ "occupant", tx.ai_occupant }, .{ "tile", tx.ai_tile }, .{ "wakeful", tx.ai_wakeful }, .{ "near", tx.ai_near } }) |f| gui.propRow(tx.get(f[1]), rules_rows.fieldText(a, Scoring, s, f[0]));
        return;
    }
    // OpenGorky: the profile's own scoring fields (rules_text.zig Profiles; no AiScoring row).
    const names = comptime std.meta.fieldNames(@FieldType(Scoring, "keep"));
    gui.fieldRow(tx.get(tx.ai_keep));
    const open = picker.field(app, clay.idi("rule_pick", 60_000), @tagName(s.keep), false);
    clay.close();
    if (open) if (picker.list(app, a, picker.names(a, names))) |j| setScoring(app, eval, "weapons", names[j]) catch |err| app.failed(err);
    gui.fieldRow("");
    const follows = s.occupant != .no_lock;
    if (gui.check(app, clay.id("ai_sc_lock"), follows, tx.get(tx.ai_follow_lock))) setScoring(app, eval, "follow_lock", if (follows) "false" else "true") catch |err| app.failed(err);
    clay.close();
    gui.fieldRow(tx.get(tx.ai_score));
    if (gui.textField(app, "ai_sc_score", s.script, 0, "—")) |t| setScoring(app, eval, "score", t) catch |err| app.failed(err);
    clay.close();
    gui.fieldRow("");
    if (gui.check(app, clay.id("ai_sc_wakeful"), s.wakeful, tx.get(tx.ai_wakeful))) setScoring(app, eval, "wakeful", if (s.wakeful) "false" else "true") catch |err| app.failed(err);
    clay.close();
    gui.fieldRow(tx.get(tx.ai_near));
    if (gui.textField(app, "ai_sc_near", s.near, 0, "—")) |t| setScoring(app, eval, "near", t) catch |err| app.failed(err);
    clay.close();
    // The profiles naming this eval: the row is shared by all of them.
    var users: std.ArrayList(u8) = .empty;
    for (rules.active.ai_profiles) |r| if (r.scoring != null and std.ascii.eqlIgnoreCase(r.scoring.?, eval)) {
        if (users.items.len > 0) users.appendSlice(a, ", ") catch {};
        const one = ea.profileName(a, r);
        users.appendSlice(a, one) catch {};
    };
    gui.fieldNote(tx.alloc(a, tx.ai_shared, .{ eval, if (users.items.len > 0) users.items else "—" }), theme.warn);
}

// ---------------------------------------------------------------- actions

fn builtinAction(func: i32) ?rules.Action {
    for (rules.builtin.actions) |r| if (r.classic_id == func) return r;
    return null;
}

/// Action `r` differs from its built-in row (null: none, the project's own).
fn changed(r: rules.Action) ?bool {
    _ = builtinAction(r.classic_id) orelse return null;
    return !rules_rows.isBuiltin(rules.Action, "actions", r);
}

/// A new action at the next free classic_id, shown.
pub fn newAction(app: *App) !void {
    var top: i32 = 0;
    for (rules.active.actions) |r| top = @max(top, r.classic_id);
    const f = top + 1;
    try rules_rows.putSaid(app, rules.Action, .{ .classic_id = f, .name = std.fmt.allocPrint(app.frame.allocator(), "Action{d}", .{f}) catch "Action" });
    app.rules_page.act = f;
}

/// Action `func`'s field `field` typed as `text` (name, text, kind; a flag "1"/"0").
pub fn setAction(app: *App, func: i32, field: []const u8, text: []const u8) !void {
    var r = (rules.action(func) orelse return error.NoSuchAction).*;
    const eq = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    if (eq(field, "name")) {
        if (std.mem.trim(u8, text, " ").len == 0) return error.EmptyName;
        // The row's key: a built-in row keeps its name (the files can't remove it); the
        // project's own goes under the new one (objects name it by it).
        if (builtinAction(func) != null) return error.BuiltinName;
        app.store.group();
        defer app.store.endGroup("{s}", .{"Action"});
        _ = try rules_rows.drop(app, rules.Action, r);
        r.name = std.mem.trim(u8, text, " ");
    } else if (eq(field, "text")) {
        r.text = try num(text);
    } else if (eq(field, "kind")) {
        r.kind = std.meta.stringToEnum(@FieldType(rules.Action, "kind"), text) orelse return error.BadKind;
    } else if (eq(field, "auto_open")) {
        r.auto_open = (try num(text)) != 0;
    } else if (eq(field, "on_exit")) {
        r.on_exit = (try num(text)) != 0;
    } else if (eq(field, "walk_click")) {
        r.walk_click = (try num(text)) != 0;
    } else return error.NoSuchField;
    try rules_rows.putSaid(app, rules.Action, r);
}

/// Action `func`'s row out of actions.ss: a project's action deleted, a built-in one
/// back to the exe's (the files can't remove a built-in row).
pub fn dropAction(app: *App, func: i32) !void {
    const r = (rules.action(func) orelse return error.NoSuchAction).*;
    if (!app.ogLayout()) return error.ClassicProject;
    if (!try rules_rows.drop(app, rules.Action, r)) return error.NotInActionsSs;
    if (builtinAction(func) == null) app.rules_page.act = null;
    app.setStatus(tx.st_act_dropped, .{ func, r.name });
}

fn stringOf(strs: []const texts.Row, id: i32) ?[]const u8 {
    for (strs) |s| if (s.id == id) return s.text;
    return null;
}

pub fn actionsPage(app: *App, a: Allocator) void {
    // OpenGorky: the actions are blocks (actionspage.zig).
    if (app.ogLayout()) return @import("actionspage.zig").page(app, a);
    const strs = texts.rows(app, a, .strings);
    head(app, "actions_page", .hand, tx.act_title, tx.act_hint);
    if (app.ogLayout() and gui.button(app, "act_new", tx.get(tx.act_new), true)) newAction(app) catch |err| rules_rows.failed(app, "func", err);
    clay.close();
    form("actions_page");
    if (gui.block(app, "act_list", tx.get(tx.act_sec), .{ .summary = tx.alloc(a, tx.act_sum, .{rules.active.actions.len}) })) {
        for (rules.active.actions, 0..) |r, k| {
            const sel = app.rules_page.act == r.classic_id;
            if (gui.listRow(app, clay.idi("act_row", @intCast(k)), .{ .selected = sel })) app.rules_page.act = if (sel) null else r.classic_id;
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.width.number) } } });
            gui.txt(std.fmt.allocPrint(a, "{d}", .{r.classic_id}) catch "", .body, theme.dim, font_mod.regular);
            clay.close();
            gui.txt(r.name, .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
            gui.txtClip(stringOf(strs, rules.actionText(r.classic_id)) orelse "", .caption, theme.dim, font_mod.regular);
            gui.spacer();
            if (changed(r)) |c| {
                if (c) gui.txt(tx.get(tx.adj_changed), .caption, theme.warn, font_mod.regular);
            } else gui.txt(tx.get(tx.rp_added), .caption, theme.warn, font_mod.regular);
            gui.txt(@tagName(r.kind), .caption, theme.dim, font_mod.regular);
            clay.close();
        }
        gui.blockEnd();
    }
    clay.closeScrollColumn();
    actionProps(app, a, strs);
}

/// The shown action's fields, the item classes naming it, delete or reset.
fn actionProps(app: *App, a: Allocator, strs: []const texts.Row) void {
    const func = app.rules_page.act orelse return;
    const r = (rules.action(func) orelse return).*;
    const is_og = app.ogLayout();
    gui.propsPanel(app, "act_props");
    defer gui.propsEnd();
    gui.groupTitle(tx.alloc(a, tx.act_props, .{ func, r.name }), true);
    gui.fieldRow("name");
    if (valueField(app, "act_name", r.name, 0)) |t| setAction(app, func, "name", t) catch |err| rules_rows.failed(app, "name", err);
    clay.close();
    gui.fieldNote(doc("Action", "name"), theme.dim);
    gui.fieldRow("text");
    if (valueField(app, "act_text", std.fmt.allocPrint(a, "{d}", .{r.text}) catch "", 0)) |t| setAction(app, func, "text", t) catch |err| rules_rows.failed(app, "text", err);
    if (is_og and gui.smallButton(app, clay.id("act_text_pick"), tx.get(tx.camp_pick))) picker.toggle(app, clay.id("act_text_pick"));
    clay.close();
    const own = rules.actionText(func);
    gui.fieldNote(std.fmt.allocPrint(a, "{d} · {s}", .{ own, stringOf(strs, own) orelse r.name }) catch "", theme.text);
    gui.fieldNote(doc("Action", "text"), theme.dim);
    if (picker.isOpen(app, clay.id("act_text_pick"))) textPick(app, a, func, r.text, strs);
    gui.fieldRow("kind");
    const kinds = comptime std.meta.fieldNames(@FieldType(rules.Action, "kind"));
    if (is_og) {
        if (gui.segmented(app, "act_kind", kinds, @backingInt(r.kind))) |k| setAction(app, func, "kind", kinds[k]) catch |err| rules_rows.failed(app, "kind", err);
    } else gui.txt(@tagName(r.kind), .body, theme.text, font_mod.regular);
    clay.close();
    if (rulesapi.find("Action")) |call| if (rulesapi.field(call, "kind")) |f| if (rulesapi.word(f, @tagName(r.kind))) |w| gui.fieldNote(tx.get(w.doc), theme.dim);
    inline for (.{ "auto_open", "on_exit", "walk_click" }) |fl| {
        gui.fieldRow(fl);
        const on = @field(r, fl);
        if (!is_og) gui.txt(tx.get(if (on) tx.la_yes else tx.la_no), .body, theme.text, font_mod.regular) else if (gui.check(app, clay.id("act_" ++ fl), on, "")) setAction(app, func, fl, if (on) "0" else "1") catch |err| rules_rows.failed(app, fl, err);
        clay.close();
        gui.fieldNote(doc("Action", fl), theme.dim);
    }
    usedBy(app, func);
    if (!is_og) return;
    const c = changed(r);
    if (c == null or c.?) if (gui.footer(app, "act_drop", &.{tx.get(if (c == null) tx.act_delete else tx.act_reset)}, null) != null) dropAction(app, func) catch |err| rules_rows.failed(app, "func", err);
    gui.note(tx.get(if (c == null) tx.act_own_note else tx.act_builtin_note));
}

/// string.tab's rows searched; the one clicked is the action's text.
fn textPick(app: *App, a: Allocator, func: i32, cur: i32, strs: []const texts.Row) void {
    const rows = a.alloc(picker.Opt, strs.len) catch return;
    for (strs, rows) |s, *o| o.* = .{ .label = std.fmt.allocPrint(a, "{d} · {s}", .{ s.id, s.text }) catch "", .selected = s.id == cur };
    if (picker.list(app, a, rows)) |j| setAction(app, func, "text", std.fmt.allocPrint(a, "{d}", .{strs[j].id}) catch "") catch |err| rules_rows.failed(app, "text", err);
}

/// The item classes whose action is `func`; the levels' objects naming it on demand.
pub fn usedBy(app: *App, func: i32) void {
    gui.groupTitle(tx.get(tx.act_used), false);
    var any = false;
    for (app.catalog.entries.items) |e| {
        if (e.kind != .item) continue;
        const f = @import("entries.zig").fileOf(app, e) orelse continue;
        // Classic `funcID = 3`, OpenGorky `action = Take` (model.get: the row's number).
        const t = app.store.text(f);
        if ((model.get(t, "action") orelse continue) != @as(f32, @floatFromInt(func))) continue;
        any = true;
        gui.propRow(e.id, e.title);
    }
    if (!any) gui.note(tx.get(tx.act_used_none));
    gui.groupTitle(tx.get(tx.act_levels_sec), false);
    if (gui.smallButton(app, clay.id("act_levels"), tx.get(tx.act_levels))) searchLevels(app, func);
    // Found before the last edit (or for another action): searched again on demand.
    if (found.func == func and found.rev == app.store.rev) {
        for (found.hits, 0..) |h, k| {
            if (gui.listRow(app, clay.idi("act_level_hit", @intCast(k)), .{ .h = lay.height.small })) info.follow(app, .{ .level = .{ .name = h.level, .obj = h.obj } });
            gui.icon(app, h.icon, lay.icon.md, theme.dim);
            gui.txt(h.text, .body, theme.accent_hover, font_mod.regular);
            clay.close();
        }
        if (found.hits.len == 0) gui.note(tx.get(tx.act_levels_none));
    }
    gui.note(tx.get(tx.act_levels_note));
}

const Hit = struct { level: []const u8, obj: []const u8, text: []const u8, icon: @import("icons.zig").Icon };

/// The last levels search: its action, the edits it saw and what it found.
var found: struct { arena: ?std.heap.ArenaAllocator = null, func: ?i32 = null, rev: u64 = std.math.maxInt(u64), hits: []const Hit = &.{} } = .{};

pub fn deinit() void {
    if (found.arena) |*ar| ar.deinit();
    found = .{};
}

/// Every level's objects naming action `func` (action, action1…) after init(), as the
/// world starts them (an open level as edited), those the level view shows; each a
/// link to the object.
pub fn searchLevels(app: *App, func: i32) void {
    if (found.arena) |*ar| _ = ar.reset(.retain_capacity) else found.arena = .init(app.gpa);
    const a = found.arena.?.allocator();
    var hits: std.ArrayList(Hit) = .empty;
    for (app.levels, 0..) |lv, li| {
        const live: ?*Doc = if (app.current == li) app.doc else for (app.parked.items) |pk| {
            if (pk.current == li) break pk.doc;
        } else null;
        const d = live orelse Doc.load(&app.store, null, lv.name) catch continue;
        defer if (live == null) d.deinit();
        for (d.world.rt.objects.items) |o| {
            if (og.state.world.World.nativeOf(o).deleted or !namesAction(o, func)) continue;
            // Those the level view shows (an area by its polygon, areaName); the items in
            // inventories and boxes are left out.
            const shown = for (d.objects.items) |ob| {
                if (std.ascii.eqlIgnoreCase(ob.name, o.name) or std.ascii.eqlIgnoreCase(ob.name, o.getString("areaName"))) break ob;
            } else continue;
            hits.append(a, .{
                .level = lv.name,
                .obj = a.dupe(u8, shown.name) catch continue,
                .text = std.fmt.allocPrint(a, "{s} · {s}", .{ lv.name, o.name }) catch continue,
                .icon = if (shown.kind == .area) .square_dashed else .box,
            }) catch {};
        }
    }
    found.func = func;
    found.rev = app.store.rev;
    found.hits = hits.items;
}

/// Object `o` names action `func` in one of its menu's actions (action, action1…).
fn namesAction(o: *og.script.object.Object, func: i32) bool {
    for (0..og.state.world.World.max_actions) |k| if (og.world.areas.actionId(o, @intCast(k)) == func) return true;
    return false;
}
