//! A level's right panel and toolbar: the objects by kind, the picked one's card and an
//! enemy's values, the level's Info, the Debug run's panel; the actions on an object
//! the menu and the keys share.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const ui = @import("ui");
const clay = @import("clay.zig");
const textedit = @import("textedit.zig");
const search = @import("search.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const model = @import("model.zig");
const inspector = @import("inspector.zig");
const tx = @import("text.zig");
const entries = @import("entries.zig");
const entry_tables = @import("entry_tables.zig");
const entry_model = @import("entry_model.zig");
const paint = @import("paint.zig");
const paint_panel = @import("paint_panel.zig");
const doctabs = @import("doctabs.zig");
const levelanims = @import("levelanims.zig");
const logicview = @import("logicview.zig");
const infoblock = @import("info.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const play = @import("play.zig");
const picker = @import("picker.zig");
const Stat = app_mod.Stat;
const theme = app_mod.theme;
const fighter_stats = app_mod.fighter_stats;
const damage_stat = app_mod.damage_stat;

/// The level's script file of object `name` (`name.itm`, `.are`, `.ftr`…).
pub fn scriptOf(d: *level.Doc, name: []const u8) ?[]const u8 {
    for (d.scripts.items) |e| {
        const dot = std.mem.lastIndexOfScalar(u8, e, '.') orelse continue;
        if (std.ascii.eqlIgnoreCase(e[0..dot], name)) return e;
    }
    return null;
}

/// The catalog entry object `o` is one of: the class its script includes (an enemy's
/// `ft_`, an item's `ca_`/`ci_`/`cw_`), else a hero of its name.
pub fn entryOfObject(app: *App, d: *level.Doc, o: level.Obj) ?usize {
    const es = app.catalog.entries.items;
    if (scriptOf(d, o.name)) |entry| if (app.store.file(d.level_archive, entry)) |f| {
        var it = std.mem.tokenizeAny(u8, app.store.text(f), "\r\n");
        while (it.next()) |ln| {
            const l = std.mem.trim(u8, ln, " \t");
            if (!std.ascii.startsWithIgnoreCase(l, "#include") and !std.ascii.startsWithIgnoreCase(l, "#inherit")) continue;
            const cls = std.mem.trim(u8, l["#include".len..], " \t\"");
            for (es, 0..) |e, i| {
                const base = baseName(e.entry);
                if (std.ascii.eqlIgnoreCase(base, cls)) return i;
            }
        }
    } else |_| {};
    for (es, 0..) |e, i| if (e.kind == .hero and std.ascii.eqlIgnoreCase(e.id, o.name)) return i;
    return null;
}

pub fn kindName(d: *level.Doc, o: level.Obj) []const u8 {
    if (d.boxFile(o.name) != null) return tx.get(tx.cm_k_box);
    return tx.get(switch (o.kind) {
        .enemy => tx.cm_k_enemy,
        .hero => tx.cm_k_hero,
        .neutral => tx.cm_k_neutral,
        .prop => tx.cm_k_prop,
        .item => tx.cm_k_item,
        .actor => tx.cm_k_actor,
        .area => tx.cm_k_area,
    });
}

/// The level edit mode on tool `t` (a new trigger area or exit is drawn with it).
pub fn paintTool(app: *App, t: paint.Tool) void {
    if (app.paint == null) app.openPaint();
    if (app.paint) |p| p.tool = t;
}

/// Area `name` being renamed: the edit mode's area tool with it picked, its name typed.
pub fn renameArea(app: *App, name: []const u8) void {
    paintTool(app, .area);
    const p = app.paint orelse return;
    paint.pickName(p, name);
    textedit.focusEnd(app, clay.id("lp_area_name"), name, search.keep.areaName, null);
}

/// "New location / battle from this one" (the column's end): opens a name field, its
/// hint and the Make button.
fn newLevelRow(app: *App, a: Allocator, battle: bool) void {
    const fid = clay.id("level_name");
    const name = &app.level_name;
    const live = textedit.live(name);
    if (gui.footer(app, "level_new", &.{tx.get(if (battle) tx.lv_new_battle else tx.lv_new)}, null) != null) {
        app.level_naming = !app.level_naming;
        // Opened: its name typed into at once.
        if (app.level_naming) textedit.focusEnd(app, fid, name.get(), search.keep.levelName, live);
    }
    if (!app.level_naming) return;
    gui.note(tx.get(if (battle) tx.lv_new_battle_hint else tx.lv_new_hint));
    if (app.store.root != null) gui.note(tx.get(tx.lv_og_new));
    gui.row(lay.space.sm);
    if (gui.nameField(app, a, fid, name.get(), search.keep.levelName, live)) |g| if (g.entered) {
        app.level_make = true;
    };
    if (gui.button(app, "level_make", tx.get(tx.lv_make), true)) app.level_make = true;
    clay.close();
    // From no level: a blank one (a battle by an `NN__` name).
    gui.note(tx.get(tx.lv_blank_hint));
    const typed = name.get();
    const def = @import("newlevel.zig").blankSize(typed.len > 5 and std.mem.eql(u8, typed[2..4], "__"));
    gui.fieldRow(tx.get(tx.lv_blank_size));
    for (0..2) |k| if (gui.numberField(app, a, if (k == 0) "blank_w" else "blank_h", if (k == 0) "W" else "H", @floatFromInt(if (app.blank_size[k] > 0) app.blank_size[k] else def[k]), 0)) |v| {
        app.blank_size[k] = @intFromFloat(@max(0, v));
    };
    clay.close();
    gui.fieldNote(tx.get(if (app.ogLayout()) tx.lv_blank_size_og else tx.lv_blank_size_classic), theme.dim);
    if (gui.footer(app, "level_blank", &.{tx.get(tx.lv_blank)}, null) != null) @import("levelops.zig").blankLevel(app, name.get());
}

/// A right panel's scrolled column of blocks (the view's, the edit mode's), its form.
pub fn blockColumn(name: []const u8) void {
    const sid = clay.id(name);
    clay.openScrollColumn(.{ .id = sid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.block.gap, lay.block.gap), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.form(sid, lay.width.label_md, lay.block.gap + lay.block.pad_x);
}

/// The view mode's right panel, a Location's or a Battle's constructor (as a
/// character's): its head (where used), what it picks (music, post-processing) and what
/// is on its map, each with a › to its own page — placed, moved and turned on the map
/// (the edit mode), edited on those pages; then all its objects, its Info and a new
/// level made from this one.
pub fn objectList(app: *App, a: Allocator) void {
    gui.propsPanel(app, "objects");
    defer clay.closeScrollColumn();
    const d = app.doc orelse return;
    const info_rows = infoblock.rows(app, std.fmt.allocPrint(a, "level:{s}", .{d.name}) catch d.name, d, levelInfo);
    head(app, a, d, info_rows);
    if (app.ogLayout()) ogBlocks(app, a, d);
    musicBlock(app, a, d);
    postBlock(app, a, d.name);
    if (d.isBattle()) {
        placedBlock(app, a, d, "la_enemies", tx.la_enemies, &.{.enemy}, 0, tx.la_place_hint_battle);
        // The picked enemy's own values in this battle (over its class's).
        paramsBlock(app, a);
        placedBlock(app, a, d, "la_party", tx.la_party, &.{.hero}, 1, tx.la_party_hint);
        rulesBlock(app, a, d);
    } else {
        scenesBlock(app, a, d);
        placedBlock(app, a, d, "la_chars", tx.la_chars, &.{ .hero, .actor, .enemy }, 2, tx.la_place_hint);
        placedBlock(app, a, d, "la_items", tx.la_items, &.{.item}, 3, tx.la_place_hint);
        exitsBlock(app, a, d);
    }
    const objs = d.objects.items;
    if (gui.block(app, "lv_objects", tx.get(tx.lp_objects_tool), .{ .folded = true, .summary = std.fmt.allocPrint(a, "{d}", .{objs.len}) catch "" })) {
        objectRows(app, a, false);
        gui.blockEnd();
    }
    if (!d.isBattle() and gui.block(app, "lv_info", tx.get(tx.info_title), .{ .folded = true, .summary = infoblock.summary(a, app.store.files.items[d.lev].entry, info_rows) })) {
        infoblock.show(app, info_rows);
        gui.blockEnd();
    }
    newLevelRow(app, a, d.isBattle());
}

/// OpenGorky: the level's own block (its fields, the components it attaches: a battle's
/// Reinforcements waves), then the picked object's block inside it (og_page.zig).
fn ogBlocks(app: *App, a: Allocator, d: *level.Doc) void {
    const og_page = @import("og_page.zig");
    const path = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ if (d.isBattle()) "battles" else "locations", d.name, if (d.isBattle()) "battle.ogs" else "level.ogs" }) catch return;
    const f = app.store.file(@import("store.zig").og_src, path) catch return;
    og_page.sections(app, a, f, "lvl", null);
    filesBlock(app, a, d);
    const i = app.selected orelse return;
    if (i >= d.objects.items.len) return;
    const of = model.model_og.innerFile(app, f, d.objects.items[i].name) catch return;
    if (model.model_og.blockOf(app, a, of) != null) og_page.sections(app, a, of, "sel", null);
}

/// OpenGorky: the level's texts of its folder (`level.ogs`, `objects.ogs`, `logic.ogs`, an
/// object's or a trigger's own), each opening in the code editor (the level's tab kept).
fn filesBlock(app: *App, a: Allocator, d: *level.Doc) void {
    const list = @import("areas.zig").levelTexts(app, d, a);
    // The level's own parts first (its block, objects, Logic), then the rest by name.
    const rank = struct {
        fn of(ap: *App, f: usize) u8 {
            const n = std.fs.path.basename(ap.store.files.items[f].entry);
            for ([_][]const u8{ "level.ogs", "battle.ogs", "objects.ogs", "logic.ogs" }, 0..) |x, i| if (std.mem.eql(u8, n, x)) return @intCast(i);
            return 9;
        }
    };
    std.mem.sort(usize, list, app, struct {
        fn lt(ap: *App, x: usize, y: usize) bool {
            const rx = rank.of(ap, x);
            const ry = rank.of(ap, y);
            if (rx != ry) return rx < ry;
            return std.ascii.lessThanIgnoreCase(ap.store.files.items[x].entry, ap.store.files.items[y].entry);
        }
    }.lt);
    if (!gui.block(app, "lvl_files", tx.get(tx.lvl_files), .{ .og = true, .summary = std.fmt.allocPrint(a, "{d}", .{list.len}) catch "" })) return;
    for (list, 0..) |f, k| {
        gui.rowFit(lay.space.sm);
        gui.icon(app, .code, lay.icon.sm, theme.dim);
        if (gui.link(app, clay.idi("lvl_file", @intCast(k)), std.fs.path.basename(app.store.files.items[f].entry), theme.accent, theme.accent_hover)) {
            doctabs.keepCurrent(app);
            doctabs.showCode(app, f, null);
        }
        clay.close();
    }
    gui.blockEnd();
}

/// The level block file `f`'s `entry` made point `point` ("": taken out). One undo step.
pub fn setEntry(app: *App, f: usize, point: []const u8) !void {
    const mo = model.model_og;
    if (point.len == 0) return mo.unset(app, f, &.{"entry"});
    const e = try app.frame.allocator().create(og.script.ir.Expr);
    e.* = .{ .line = 0, .kind = .{ .lit = .{ .string = point } } };
    return mo.setExpr(app, f, "entry", e);
}

/// The page's head: its name, Location or Battle, its files, the campaign's start, and
/// where it is used (the levels and scenes leading here; a battle: those starting it).
fn head(app: *App, a: Allocator, d: *level.Doc, info_rows: []const infoblock.Row) void {
    gui.headCard();
    defer gui.blockEnd();
    gui.txtWrap(d.name, .heading, theme.text, font_mod.bold);
    gui.row(lay.space.sm);
    gui.chip(tx.get(if (d.isBattle()) tx.la_chip_battle else tx.la_chip_location));
    gui.spacer();
    // OpenGorky: the project's file of the level's block (the installed game's otherwise).
    const where = if (app.ogLayout())
        std.fmt.allocPrint(a, "src/{s}/{s}/{s}", .{ if (d.isBattle()) "battles" else "locations", d.name, if (d.isBattle()) "battle.ogs" else "level.ogs" })
    else
        std.fmt.allocPrint(a, "{s} · {s}", .{ d.level_archive, app.store.files.items[d.lev].entry });
    gui.txtClip(where catch "", .caption, theme.dim, font_mod.regular);
    clay.close();
    if (std.ascii.eqlIgnoreCase(og.rules.campaign().level, d.name)) gui.txtWrap(tx.get(tx.la_campaign_start), .caption, theme.accent_hover, font_mod.regular);
    // A location's uses (the levels leading here) say little: a battle's (what starts it) only.
    if (!d.isBattle()) return;
    gui.subhead(tx.get(tx.info_used));
    var n: u32 = 0;
    for (info_rows) |r| if (r.group == .used) {
        if (gui.listRow(app, clay.idi("la_used", n), .{ .h = lay.height.small })) infoblock.follow(app, r.to);
        gui.icon(app, r.icon, lay.icon.md, theme.dim);
        gui.txtClip(r.text, .body, theme.accent_hover, font_mod.regular);
        clay.close();
        n += 1;
    };
    if (n == 0) gui.txtWrap(tx.get(tx.la_used_none_battle), .caption, theme.dim, font_mod.regular);
}

/// The music it plays (the exe's choice by its name: its own track, its district's, a
/// battle's), › its page; a track picked becomes its own (copied as `<level>.mp3`, so the
/// original plays it too) or one imported.
fn musicBlock(app: *App, a: Allocator, d: *level.Doc) void {
    const media = @import("levelmedia.zig");
    const musicpage = @import("musicpage.zig");
    const voices = @import("voices.zig");
    var tracks: std.ArrayList(media.Use) = .empty;
    if (media.get(app, d)) |m| for (m.sounds) |u| if (u.music) tracks.append(a, u) catch {};
    const first = if (tracks.items.len > 0) tracks.items[0].name else "—";
    if (!gui.block(app, "la_music", tx.get(tx.la_music), .{ .summary = first })) return;
    defer gui.blockEnd();
    for (tracks.items, 0..) |u, k| {
        gui.fieldRow(if (k == 0) tx.get(tx.la_music_track) else "");
        const missing = !voices.has(app, u.name);
        // The first one picked; a battle's others (the enemy turn's, the second track) shown.
        const open = if (k == 0) picker.field(app, clay.id("la_music_pick"), u.name, missing) else blk: {
            gui.txtClip(u.name, .label, if (missing) theme.warn else theme.text, font_mod.regular);
            gui.spacer();
            break :blk false;
        };
        if (!missing and gui.goButton(app, clay.idi("la_music_go", @intCast(k)))) doctabs.openKept(app, .music, u.name);
        clay.close();
        if (open) if (picker.listKey(app, a, picker.names(a, musicpage.names(app)))) |v| {
            const own = std.ascii.allocLowerString(a, std.fmt.allocPrint(a, "{s}.mp3", .{d.name}) catch "") catch "";
            voices.copyTo(app, v, own) catch |err| app.failed(err);
            app.music.read = false;
        };
        gui.fieldNote(if (missing) tx.get(tx.lm_music_missing) else u.by, if (missing) theme.warn else theme.dim);
    }
    if (tracks.items.len == 0) gui.note(tx.get(tx.la_music_none));
    gui.note(tx.get(tx.la_music_hint));
    if (gui.footer(app, "la_music_foot", &.{tx.get(tx.mus_own)}, null) != null) app.askMusic(d.name);
}

/// The scenes its scripts start, each › its page (a start is added on an area's trigger).
fn scenesBlock(app: *App, a: Allocator, d: *level.Doc) void {
    const m = @import("levelmedia.zig").get(app, d);
    const names = if (m) |x| x.scenes else &.{};
    if (!gui.block(app, "la_scenes", tx.get(tx.la_scenes), .{ .summary = std.fmt.allocPrint(a, "{d}", .{names.len}) catch "" })) return;
    defer gui.blockEnd();
    for (names, 0..) |n, k| {
        const go = linkRow(app, clay.idi("la_scene", @intCast(k)), clay.idi("la_scene_go", @intCast(k)), .clapperboard, n, "", doctabs.isShown(app, .scenes, n));
        if (go) doctabs.openKept(app, .scenes, n);
    }
    if (names.len == 0) gui.note(tx.get(tx.la_none));
    gui.note(tx.get(tx.la_scenes_hint));
}

/// The objects of `kinds` on its map (as the map draws them), each › the page of what it
/// is one of; a click picks it on the map. `k`: the block's ids; `hint` under it.
fn placedBlock(app: *App, a: Allocator, d: *level.Doc, key: []const u8, title: tx.Msg, kinds: []const level.Kind, k: u32, hint: tx.Msg) void {
    var rows: std.ArrayList(usize) = .empty;
    for (d.objects.items, 0..) |o, i| if (std.mem.indexOfScalar(level.Kind, kinds, o.kind) != null) rows.append(a, i) catch {};
    if (!gui.block(app, key, tx.get(title), .{ .summary = std.fmt.allocPrint(a, "{d}", .{rows.items.len}) catch "" })) return;
    defer gui.blockEnd();
    for (rows.items) |i| {
        const o = d.objects.items[i];
        const sel = app.selected != null and app.selected.? == i;
        const id = @as(u32, @intCast(i)) * 4 + k;
        _ = gui.listRow(app, clay.idi("la_obj", id), .{ .selected = sel });
        const over = clay.hovered();
        if (o.later != null) gui.dot(theme.later) else swatch(o.kind, lay.space.sm);
        gui.txt(o.name, .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
        const ei = entryOfObject(app, d, o);
        const e = if (ei) |x| app.catalog.entries.items[x] else null;
        const what = if (o.later != null) tx.get(tx.later) else if (e) |x| (if (x.title.len > 0) x.title else x.id) else kindName(d, o);
        gui.txtClip(what, .caption, theme.dim, font_mod.regular);
        gui.spacer();
        const go = if (e != null) gui.goButton(app, clay.idi("la_obj_go", id)) else false;
        clay.close();
        if (go) doctabs.openKept(app, @import("kinds.zig").tabOf(e.?.kind), entries.keyOf(a, e.?) orelse "") else if (over and app.clicked) app.selected = i;
    }
    if (rows.items.len == 0) gui.note(tx.get(tx.la_none));
    gui.note(tx.get(hint));
}

/// Its exits: each area leading to another level, › that level.
fn exitsBlock(app: *App, a: Allocator, d: *level.Doc) void {
    const areas = @import("areas.zig");
    const Exit = struct { area: []const u8, to: ?[]const u8 };
    var exits: std.ArrayList(Exit) = .empty;
    for (d.objects.items) |o| if (o.kind == .area) if (areas.exitTo(app, d, o.name)) |to| {
        exits.append(a, .{ .area = o.name, .to = to }) catch {};
    };
    if (!gui.block(app, "la_exits", tx.get(tx.la_exits), .{ .summary = std.fmt.allocPrint(a, "{d}", .{exits.items.len}) catch "" })) return;
    defer gui.blockEnd();
    for (exits.items, 0..) |x, k| if (linkRow(app, clay.idi("la_exit", @intCast(k)), if (x.to != null) clay.idi("la_exit_go", @intCast(k)) else null, .log_out, x.to orelse "—", x.area, false)) {
        doctabs.keepCurrent(app);
        app.showLevel(x.to.?, null);
    };
    if (exits.items.len == 0) gui.note(tx.get(tx.la_none));
    gui.note(tx.get(tx.la_exits_hint));
}

/// A battle's rules and outcome: its map (itself), how the exe plays it (levelMode, a
/// boss's), the lines before it, and ▶ to play it.
fn rulesBlock(app: *App, a: Allocator, d: *level.Doc) void {
    if (!gui.block(app, "la_rules", tx.get(tx.la_rules), .{})) return;
    defer gui.blockEnd();
    gui.propRow(tx.get(tx.la_field), tx.get(tx.la_field_self));
    const l = d.world.level;
    gui.propRow("mode", std.fmt.allocPrint(a, "{d}", .{if (l) |x| x.getInt("mode") else 0}) catch "");
    gui.propRow(tx.get(tx.la_boss), tx.get(if (l != null and l.?.getInt("boss") != 0) tx.la_yes else tx.la_no));
    gui.fieldNote(tx.get(tx.la_rules_note), theme.dim);
    const dlg = std.fmt.allocPrint(a, "{s}.dlg", .{d.name}) catch "";
    gui.fieldRow(tx.get(tx.sc_battle_open));
    gui.txtClip(dlg, .label, theme.text, font_mod.regular);
    gui.spacer();
    if (gui.goButton(app, clay.id("la_lines_go"))) app.showDialog(dlg);
    clay.close();
    if (gui.footer(app, "la_play", &.{tx.get(tx.la_play)}, 0) != null) play.playLevel(app);
}

/// A slot's row: its icon, `label` (`sub` dim after it) and a › (`go_id`, none: nothing to open); true when › is clicked.
fn linkRow(app: *App, id: ui.Clay_ElementId, go_id: ?ui.Clay_ElementId, ic: @import("icons.zig").Icon, label: []const u8, sub: []const u8, sel: bool) bool {
    _ = gui.listRow(app, id, .{ .selected = sel });
    gui.icon(app, ic, lay.icon.md, theme.dim);
    gui.txt(label, .label, theme.text, font_mod.regular);
    gui.txtClip(sub, .caption, theme.dim, font_mod.regular);
    gui.spacer();
    const go = if (go_id) |g| gui.goButton(app, g) else false;
    clay.close();
    return go;
}

/// The level's post-processing (OpenGorky): the global chain or its own (a copy of the
/// global one made, or its row dropped), › its page on this level's chain.
fn postBlock(app: *App, a: Allocator, name: []const u8) void {
    const pp = @import("postpage.zig");
    const own = og.core.modules.postChain(name);
    // A battle without its own takes its location's own chain, if it has one (else the global).
    const loc = og.core.modules.postLocation(name);
    const what = if (own) |r| tx.alloc(a, tx.post_own, .{r.steps.len}) else if (loc) |r| tx.alloc(a, tx.post_as_loc, .{r.level}) else tx.get(tx.post_shared);
    if (!gui.block(app, "lv_post", tx.get(tx.post_title), .{ .summary = what, .og = true })) return;
    defer gui.blockEnd();
    gui.fieldRow(tx.get(tx.post_for));
    // The location is named in the summary and the hint: its name does not fit the segment.
    const follow = tx.get(if (loc != null) tx.post_as_loc_btn else tx.post_shared_btn);
    if (gui.segmented(app, "lv_post_own", &.{ follow, tx.get(tx.post_own_btn) }, @intFromBool(own != null))) |k| pp.setOwn(app, name, k == 1) catch |err| app.failed(err);
    gui.spacer();
    if (gui.goButton(app, clay.id("lv_post_go"))) pp.showFor(app, name);
    clay.close();
    gui.note(if (name.len > 5 and std.mem.eql(u8, name[2..4], "__")) pp.battleHint(a, name) else tx.get(tx.post_level_hint));
}

/// The level's Info: its script, what it includes, the other levels' scripts and the
/// scenes naming it (an exit, LOADLEVEL).
fn levelInfo(d: *level.Doc, app: *App, list: *infoblock.List) void {
    const entry = app.store.files.items[d.lev].entry;
    // OpenGorky: its texts are the Files block's; the installed game's `.lev` is not its.
    if (!app.ogLayout()) list.add(.{ .group = .file, .text = list.fmt("{s} · {s}", .{ d.level_archive, entry }), .to = .{ .code = .{ .archive = d.level_archive, .entry = entry } }, .icon = .code });
    infoblock.includes(app, list, d.level_archive, app.store.text(d.lev), 4);
    const needle = list.fmt("\"{s}\"", .{d.name});
    const n = list.rows.items.len;
    infoblock.levelsNaming(app, list, needle);
    // Its own scripts name it too (not a use).
    for (list.rows.items[n..], n..) |r, k| if (r.to == .level and std.ascii.eqlIgnoreCase(r.to.level.name, d.name)) {
        _ = list.rows.orderedRemove(k);
        break;
    };
    infoblock.scenesNaming(app, list, needle, "");
}

/// The Debug run's panel in the inspector's place.
pub fn logicPanel(app: *App, a: Allocator, v: *logicview.View) void {
    gui.sidePanel(app.pane(.objects), .{});
    logicview.panel(app, a, v);
    clay.close();
}

/// An OpenGorky level's script: its `logic.ogs`, else its block's file (`level.ogs`,
/// `battle.ogs`); its `.lev` is the installed game's, the model's source only.
fn ogScript(app: *App, d: *Doc) ?usize {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}/logic.ogs", .{ if (d.isBattle()) "battles" else "locations", d.name }) catch return null;
    return app.store.file(@import("store.zig").og_src, path) catch @import("level_og.zig").blockFile(d);
}

/// Over the level: in the view mode its actions (edit it, its script, its battle lines)
/// and what is shown; in the edit mode the tools and Done. Fit and the zoom on the right.
pub fn levelToolbar(app: *App, a: Allocator, d: *level.Doc) void {
    // Named buttons when they all fit (the paint tools, or the view mode's), else icons.
    var bar = gui.Toolbar.open("level_toolbar");
    // The level's script in a tab of its own (the level's tab kept, not replaced).
    var script = false;
    if (app.paint) |p| {
        paint_panel.toolbar(app, p, &bar);
        script = bar.button(app, "level_code", .code, tx.get(tx.code_level), false, false);
    } else {
        if (bar.button(app, "level_paint", .pencil, tx.get(tx.lp_open), false, true)) app.openPaint();
        script = bar.button(app, "level_code", .code, tx.get(tx.code_level), false, false);
        if (bar.button(app, "level_debug", .play, tx.get(tx.lt_open), logicview.of(app) != null, false)) {
            if (logicview.of(app) != null) logicview.close(app) else logicview.run(app);
            app.rendered.on = false;
        }
        // The level as the game draws it (models, light, depth), nothing of the editor's over it.
        if (bar.button(app, "level_preview", .eye, tx.get(tx.show_rendered), app.rendered.on, false)) {
            app.rendered.on = !app.rendered.on;
            if (app.rendered.on) {
                if (logicview.of(app) != null) logicview.close(app);
                app.selected = null;
                app.menu = null;
            }
        }
        // The background with the post-processing in force (OpenGorky; Classic has none).
        if (!app.rendered.on and app.ogLayout() and og.core.modules.postSteps(d.name).len > 0) if (bar.button(app, "stage_post", .image, tx.get(tx.post_title), app.stage_post, false)) {
            app.stage_post = !app.stage_post;
        };
        if (d.isBattle()) if (bar.button(app, "battle_lines", .message_square, tx.get(tx.sc_battle_open), false, false)) app.showDialog(std.fmt.allocPrint(a, "{s}.dlg", .{d.name}) catch "");
    }
    if (script) {
        doctabs.keepCurrent(app);
        doctabs.showCode(app, if (app.ogLayout()) ogScript(app, d) orelse d.lev else d.lev, null);
    }
    gui.spacer();
    // Where heroes can walk (a box put there can be reached).
    if (app.paint == null and !d.isBattle() and !app.rendered.on) if (bar.check(app, "show_walk", app.show_walk, tx.get(tx.show_walk))) {
        app.show_walk = !app.show_walk;
    };
    if (bar.button(app, "view_fit", .maximize, tx.get(tx.tb_fit), false, false)) d.fitted = false;
    bar.note(app, std.fmt.allocPrint(a, "{d:.0}%", .{d.zoom * 100}) catch "");
    if (app.paint != null) {
        if (bar.button(app, "lp_done", .check, tx.get(tx.lp_done), false, true)) app.closePaint();
    } else if (bar.button(app, "play", .play, tx.get(tx.tb_play), false, true)) play.playLevel(app);
    bar.close();
}

/// The edit mode's Objects tool block: how to edit, the picked object, the level's
/// objects (a right click on a row: its menu), fighters nobody places.
pub fn objectsBlock(app: *App, a: Allocator) void {
    const d = app.doc orelse return;
    gui.note(tx.get(if (d.isBattle()) tx.lp_objects_hint_battle else tx.lp_objects_hint));
    // Files of fighters nobody places (an older editor's removals): offered for deletion.
    const orphans = d.orphans(a) catch &.{};
    if (orphans.len > 0) {
        gui.txtWrap(tx.alloc(a, tx.orphans, .{std.mem.join(a, ", ", orphans) catch ""}), .caption, theme.warn, font_mod.regular);
        if (gui.button(app, "purge", tx.get(tx.orphans_drop), false)) app.askDelete(.purge, 0, std.mem.join(a, ", ", orphans) catch "");
    }
    if (app.selected) |i| if (i < d.objects.items.len) selectedCard(app, a, d, i);
    objectRows(app, a, true);
}

/// The picked object (as the concept's inspector): name, kind, lock; where it is; a
/// box's contents; its script.
fn selectedCard(app: *App, a: Allocator, d: *level.Doc, i: usize) void {
    const o = d.objects.items[i];
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.md, lay.space.md), .childGap = lay.space.sm }, .backgroundColor = theme.header, .cornerRadius = clay.radius(lay.radius.md) });
    gui.txt(tx.get(tx.so_title), .body, theme.dim, font_mod.bold);
    gui.row(lay.space.sm);
    swatch(o.kind, lay.icon.sm);
    gui.txt(o.name, .title, theme.text, font_mod.bold);
    gui.spacer();
    gui.txt(kindName(d, o), .caption, theme.dim, font_mod.regular);
    const locked = app.locked.contains(o.name);
    // Quiet, the lock's own colour (a locked object's in the warning colour).
    if (gui.buttonOf(app, clay.id("so_lock"), .{ .icon = if (locked) .lock else .lock_open, .style = .quiet, .size = .small, .color = if (locked) theme.warn else theme.dim })) app.toggleLocked(o.name);
    clay.close();
    const where = if (o.tile) |t| tx.alloc(a, tx.so_tile, .{ t[0], t[1] }) else if (o.grid) |g| tx.alloc(a, tx.so_grid, .{ g[0], g[1] }) else tx.alloc(a, tx.so_pos, .{ o.pos[0], o.pos[1] });
    gui.txt(where, .body, theme.text, font_mod.regular);
    // The model it stands as (an actor's `meshFile`; the map shows only its marker).
    const own_file: ?usize = o.file orelse if (scriptOf(d, o.name)) |entry| app.store.file(d.level_archive, entry) catch null else null;
    if (own_file) |f| if (model.ownStr(app, f, "mesh")) |mesh| {
        if (app.preview.draw(app.gpa, app.io, app.dat, app.r, .{ .ctx = app, .get = entries.overlayGet }, mesh, "", null, entry_model.ridersOn(app, a, if (app.catalog.classOf(app.store.text(f))) |e| e.riders.items else &.{}, ""), .{ 2 * thumb, 2 * thumb })) |tex| {
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(thumb), .height = clay.fixed(thumb) } }, .image = .{ .imageData = tex } });
        } else gui.txt(tx.get(tx.no_model), .body, theme.warn, font_mod.regular);
    };
    // A battle obstacle (`.obs`): whether it explodes.
    if (own_file) |f| if (o.tile != null and std.ascii.endsWithIgnoreCase(app.store.files.items[f].entry, ".obs")) explodableRow(app, d, f, o.name);
    // A box: what is in it.
    if (d.boxFile(o.name)) |f| {
        const items = @import("box.zig").parse(app, a, f) catch &.{};
        gui.txt(tx.alloc(a, tx.so_contents, .{items.len}), .body, theme.dim, font_mod.bold);
        for (items) |it| {
            const n = if (it.count) |cn| cn else @as(i32, @intCast(it.names.items.len));
            // The item's name in the game where the catalog knows it.
            const title = for (app.catalog.entries.items) |e| {
                if (e.title.len > 0 and std.ascii.endsWithIgnoreCase(e.entry, it.class)) break e.title;
            } else std.fs.path.stem(it.class);
            gui.txt(std.fmt.allocPrint(a, "{s}  ×{d}", .{ title, n }) catch it.class, .body, theme.text, font_mod.regular);
        }
        if (gui.toolButton(app, "so_contents", .box, tx.get(tx.cm_edit_contents), false, false)) _ = app.openBox(o.name);
    }
    // Its script: its own file, or the level script's line placing it.
    if (scriptOf(d, o.name)) |entry| {
        if (gui.toolButton(app, "so_script", .code, entry, false, false)) if (app.store.file(d.level_archive, entry)) |f| doctabs.showCode(app, f, null) else |_| {};
    } else if (o.call) |ci| if (gui.toolButton(app, "so_script", .code, tx.get(tx.cm_reveal), false, false)) doctabs.showCode(app, d.lev, d.script.calls[ci].stmt.start);
    clay.close();
}

/// An obstacle's `explodable` (OpenGorky; og.fields.explodable): a tick written explicit
/// (`int explodable;` and init()'s value, one undo step), the exe's until set (a barrel
/// whose blast weapon is classic_id 1002). Classic: none.
fn explodableRow(app: *App, d: *level.Doc, f: usize, name: []const u8) void {
    if (!app.ogLayout()) return;
    const text = app.store.text(f);
    const on = if (model.textNum(app, text, "explodable")) |v| v != 0 else exeExplodes(d, name);
    gui.fieldRow(tx.get(tx.so_explodable));
    if (gui.check(app, clay.id("so_explodable"), on, "")) setExplodable(app, f, !on) catch |err| app.failed(err);
    clay.close();
}

/// The exe's: `explosive` and the blast shown only for weapon classic_id 1002 (0x4ceb72).
fn exeExplodes(d: *level.Doc, name: []const u8) bool {
    const o = d.world.rt.findObject(name) orelse return false;
    const w = d.world.rt.findObject(o.getString("blast_weapon")) orelse return false;
    return o.getInt("explosive") != 0 and og.fields.classicId(w) == 1002;
}

/// Obstacle file `f` declares `explodable` and sets it to `on` in init().
pub fn setExplodable(app: *App, f: usize, on: bool) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const t = app.store.text(f);
    const declared = try model.declare(app.gpa, t, "int explodable;");
    defer if (declared) |x| app.gpa.free(x);
    try app.store.replace(f, try model.setIn(app.gpa, declared orelse t, "explodable", if (on) "1" else "0", "#include obs_"));
}

/// The level's objects by kind (as the concept's scene tree): a group per kind, its
/// rows by name; the eyes hide them in the view; a click picks one, in the edit mode a
/// right click opens its menu.
fn objectRows(app: *App, a: Allocator, edit: bool) void {
    const d = app.doc orelse return;
    const objs = d.objects.items;
    // Allies first, then enemies, the rest after.
    const order = [_]level.Kind{ .hero, .enemy, .neutral, .actor, .item, .prop, .area };
    const names = [_]tx.Msg{ tx.ok_heroes, tx.ok_enemies, tx.ok_neutral, tx.ok_actors, tx.ok_items, tx.ok_props, tx.ok_areas };
    for (order, names) |kind, title| {
        var n: usize = 0;
        for (objs) |o| n += @intFromBool(o.kind == kind);
        if (n == 0) continue;
        const kkey = std.fmt.allocPrint(a, "kind:{t}", .{kind}) catch continue;
        const ckey = std.fmt.allocPrint(a, "objclosed/{t}", .{kind}) catch continue;
        const open = !app.tree_open.contains(ckey);
        const kind_shown = !app.view_hidden.contains(kkey);
        const gid = clay.idi("obj_group", @backingInt(kind));
        const g_hit = gui.folderRow(app, gid, 0, open, .folder, false, tx.get(title), true, n, a);
        const g_eye = gui.eye(app, clay.idi("obj_geye", @backingInt(kind)), kind_shown);
        clay.close();
        // The eye hides the kind; the row folds it (`objclosed/<kind>` kept while folded).
        if (g_eye) app.toggleHidden(kkey) else if (g_hit) @import("assettree.zig").toggleKey(app, ckey);
        if (!open) continue;
        // Rows by name; reinforcements after the starting ones.
        var rows: std.ArrayList(usize) = .empty;
        for (objs, 0..) |o, i| if (o.kind == kind) rows.append(a, i) catch {};
        std.mem.sort(usize, rows.items, objs, struct {
            fn f(os: []const level.Obj, x: usize, y: usize) bool {
                if ((os[x].later == null) != (os[y].later == null)) return os[x].later == null;
                return std.ascii.lessThanIgnoreCase(os[x].name, os[y].name);
            }
        }.f);
        for (rows.items) |i| {
            const o = objs[i];
            const sel = app.selected != null and app.selected.? == i;
            const rid = clay.idi("obj", @intCast(i));
            _ = gui.listRow(app, rid, .{ .selected = sel, .indent = gui.leafIndent(0) });
            const over = clay.hovered();
            if (o.later != null) gui.dot(theme.later) else swatch(o.kind, lay.space.sm);
            const locked = d.isBattle() and o.call == null;
            gui.txtClip(o.name, .label, if (locked or o.later != null) theme.dim else theme.text, if (sel) font_mod.bold else font_mod.regular);
            if (locked) gui.txt(tx.get(tx.scripted), .caption, theme.dim, font_mod.regular);
            if (o.later) |m| gui.txt(if (m == 0) tx.get(tx.later) else tx.get(tx.later_alt), .caption, theme.dim, font_mod.regular);
            if (o.added) gui.txt(tx.get(tx.new), .caption, theme.accent_hover, font_mod.regular);
            if (o.hidden) gui.txt(tx.get(tx.hero_hidden), .caption, theme.dim, font_mod.regular);
            gui.spacer();
            const eye = gui.eye(app, clay.idi("obj_eye", @intCast(i)), kind_shown and !app.view_hidden.contains(o.name));
            clay.close();
            if (eye) app.toggleHidden(o.name) else if (over and app.clicked) app.selected = i;
            if (edit and over and app.right_clicked) app.openMenuFor(i);
        }
    }
    // The level's sprites and the sounds it plays (folded at first).
    levelanims.group(app, a, d);
    varsGroup(app, a, d);
    @import("levelmedia.zig").groups(app, a, d);
}

/// Kind `k`'s colour mark, `size` square (as the map draws it).
fn swatch(k: level.Kind, size: f32) void {
    const col = Doc.kindColor(k);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(size), .height = clay.fixed(size) } }, .backgroundColor = .{ .r = @floatFromInt(col[0]), .g = @floatFromInt(col[1]), .b = @floatFromInt(col[2]), .a = 255 }, .cornerRadius = clay.radius(lay.border.mark) });
}

/// A picked object's model, as wide as a form's label column.
const thumb = lay.width.label_lg;

/// The picked enemy's own values over its class (its own block after the tool's): its
/// stats, AI, resistances and weapons; × drops an own value.
pub fn paramsBlock(app: *App, a: Allocator) void {
    const en = app.selectedEnemy() orelse return;
    var own: usize = 0;
    for (fighter_stats) |st| own += @intFromBool(model.field(app, en.ftr, st.names[0]).own);
    for (en.wpn[0..en.n_wpn]) |w| own += @intFromBool(model.field(app, w, damage_stat.names[0]).own);
    // This enemy's own values; its class (every such enemy) is edited on its page.
    if (!gui.block(app, "lp_params", tx.alloc(a, tx.params_of, .{en.name}), .{ .summary = tx.alloc(a, tx.sum_own, .{own}) })) return;
    defer gui.blockEnd();
    gui.note(tx.get(tx.scope_one_hint));
    const ai_from = fighter_stats.len - 4;
    for (fighter_stats, 0..) |st, k| {
        if (k == ai_from) gui.subhead(tx.get(tx.sec_ai));
        statRow(app, a, @intCast(k), tx.get(st.label), st, en.ftr, "#include ft_");
    }
    {
        const who: og.rules.Who = if (app.doc) |d| (if (d.world.rt.findObject(en.name)) |o| og.rules.who(o) else .{ .id = 0 }) else .{ .id = 0 };
        entries.resistBlock(app, a, who);
    }
    if (en.n_wpn > 0) gui.subhead(tx.get(tx.wp_title));
    for (0..en.n_wpn) |k| {
        const w = app.store.files.items[en.wpn[k]].entry;
        statRow(app, a, @intCast(fighter_stats.len + k), w[0 .. w.len - 4], damage_stat, en.wpn[k], "#include wp_");
        entries.weaponChoice(app, a, en.wpn[k], en.wpn_class[k]);
    }
}

/// One parameter: this enemy's value (its class's until set; click to type a new one)
/// and, for an own value, × to drop it.
fn statRow(app: *App, a: Allocator, row: u32, label: []const u8, st: Stat, own: usize, include: []const u8) void {
    // The armour is one of four (entry_tables.armorRows), the rest typed.
    const armor = std.mem.eql(u8, st.names[0], "armor");
    const v = if (armor) model.num(model.field(app, own, "armor").value) else null;
    const open = inspector.row(app, a, row, label, own, st.names, .{ .after = include, .reset = true, .choice = if (armor) entry_tables.armorLabel(a, v) else null });
    if (open) if (picker.listKey(app, a, entry_tables.armorRows(a, v))) |nv| model.set(app, own, st.names, nv, include) catch |err| app.failed(err);
}

/// The level's own variables — its quest flags and counters (`int readyF01;   // battle 1`
/// in the `.lev`) — with their comments, where they are named, and their starting values
/// (the `.var` layer: `variables\\<level>.var`, which the exe applies before init(), so a
/// value init() sets wins and is shown instead), folded under the level's objects.
fn varsGroup(app: *App, a: Allocator, d: *Doc) void {
    const okey = "objopen/vars";
    const open = app.tree_open.contains(okey);
    const vs = model.declared(app, a, d.lev);
    if (vs.len == 0) return;
    const gid = clay.id(okey);
    if (gui.folderRow(app, gid, 0, open, .code, false, tx.get(tx.lv_title), true, vs.len, a)) @import("assettree.zig").toggleKey(app, okey);
    clay.close();
    if (!open) return;
    // Mentions are counted only while open (it reads every script of the level).
    const scripts = levelTexts(app, a, d);
    gui.txtWrap(tx.get(tx.lv_hint), .caption, theme.dim, font_mod.regular);
    for (vs, 0..) |v, k| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = gui.leafIndent(0), .right = lay.space.sm, .top = lay.space.xs, .bottom = lay.space.xs }, .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
        gui.txt(std.fmt.allocPrint(a, "{t} {s}", .{ v.type, v.name }) catch v.name, .body, theme.text, font_mod.regular);
        const f = model.field(app, d.lev, v.name);
        const uses = count(scripts, v.name);
        const note = if (f.own and f.layer == .instance) tx.alloc(a, tx.lv_in_init, .{ f.text(a), uses }) else if (v.comment.len > 0) std.fmt.allocPrint(a, "{s} · {d}×", .{ v.comment, uses }) catch "" else std.fmt.allocPrint(a, "{d}×", .{uses}) catch "";
        gui.note(note);
        clay.close();
        if (gui.textField(app, std.fmt.allocPrint(a, "lv_{d}", .{k}) catch "lv", model.start(app, d.name, v.name) orelse "0", lay.width.number, "")) |nv| {
            model.setStart(app, d.name, v.name, std.mem.trim(u8, nv, " ")) catch |err| app.failed(err);
        }
        // Its declaration in the level script, in a tab of its own.
        if (gui.toolButton(app, std.fmt.allocPrint(a, "lv_open{d}", .{k}) catch "lvo", .code, "", false, false)) {
            doctabs.keepCurrent(app);
            doctabs.showCode(app, d.lev, v.at);
        }
        clay.close();
    }
}

/// The level's script texts (edited ones as edited).
fn levelTexts(app: *App, a: Allocator, d: *Doc) []const []const u8 {
    const refs = @import("refs.zig");
    const fs = refs.files(app, a, d.level_archive, refs.script);
    const out = a.alloc([]const u8, fs.len) catch return &.{};
    for (fs, out) |f, *t| t.* = f.text;
    return out;
}

/// Mentions of `name` in `scripts` (the declaration is one).
fn count(scripts: []const []const u8, name: []const u8) usize {
    var n: usize = 0;
    for (scripts) |t| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, t, pos, name)) |i| {
            pos = i + name.len;
            if ((i > 0 and model.isIdent(t[i - 1])) or (pos < t.len and model.isIdent(t[pos]))) continue;
            n += 1;
        }
    }
    return n;
}
