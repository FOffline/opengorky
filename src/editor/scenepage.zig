//! Scenes tab: the cutscenes, what each changes in the game, where level scripts start
//! it; a scene can skip itself (its changes still happen) or a start can be turned off.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const scenes = @import("scenes.zig");
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;
const codeview = @import("codeview.zig");
const doctabs = @import("doctabs.zig");
const code = @import("code.zig");
const og = @import("opengorky");
const voices = @import("voices.zig");
const picker = @import("picker.zig");
const app_mod = @import("app.zig");
const icons = @import("icons.zig");
const level_mod = @import("level.zig");
const treemenu = @import("treemenu.zig");
const c = @import("sdl");
const App = app_mod.App;
const play = @import("play.zig");
const levelops = @import("levelops.zig");
const theme = app_mod.theme;
const textedit = @import("textedit.zig");
const search = @import("search.zig");

/// The page's padding (its tables' columns are sized inside it).
const page_pad = gui.pad(lay.space.xl, lay.space.lg);

/// The Scenes tab's state (`app.scenes`; the scene or dialogue shown is `app.scene`).
pub const State = struct {
    /// The page's view and its map preview's shown layers (areas, objects, entry).
    view: enum { overview, lines, debug } = .overview,
    show: [3]bool = .{ true, false, true },
    preview: app_mod.ScenePreview = .{},
    /// The last test run of a scene (its name owned) — the Debug view.
    report: ?struct { name: []u8, level: []u8, report: og.scene_check.Report } = null,
};

/// Scene commands that change the game rather than show it.
const lasting = [_][]const u8{ "SETHERO", "DELETEOBJECT", "DISABLEOBJECT", "LOADLEVEL", "PREVLEVEL", "GO_RUNFUN", "ALLOW_WALK_IN_AREA", "FORBID_WALK_IN_AREA", "ASSIGN_ITEM", "ADDONSCRIPTLET", "PLACEHEROES", "GUI_GAMEOVER", "GUI_ENDDEMO", "GUI_CREDITS" };

fn sceneFile(app: *App, name: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    return app.store.file(common_archive, std.fmt.bufPrint(&buf, "scriptlets\\{s}.scr", .{name}) catch return null) catch null;
}

fn skipped(app: *App, name: []const u8) bool {
    const f = sceneFile(app, name) orelse return false;
    return scenes.isShort(app.store.text(f));
}

pub fn page(app: *App, a: Allocator) void {
    if (app.sceneName()) |n| return scenePage(app, a, n);
    clay.openScrollColumn(.{ .id = clay.id("scene_detail"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = page_pad, .childGap = lay.space.sm } });
    if (app.dialogName()) |n| dialogPage(app, a, n) else gui.txt(tx.get(tx.pick_entry), .title, theme.dim, font_mod.regular);
    clay.closeScrollColumn();
}

/// A battle's or idle dialogue on its own; a battle without one gets a new file.
fn dialogPage(app: *App, a: Allocator, name: []const u8) void {
    if (app.ogLayout()) return dialogPageOg(app, a, name);
    gui.txt(name, .heading, theme.text, font_mod.bold);
    gui.txt(tx.get(if (std.ascii.startsWithIgnoreCase(name, "idle_")) tx.sc_idle_hint else tx.sc_battle_hint), .caption, theme.dim, font_mod.regular);
    if (app.store.file(lang_archive, name)) |f| return dialogBlock(app, a, f, name, 1) else |_| {}
    if (gui.button(app, "dlg_new", tx.get(tx.sc_new_lines), true)) {
        // The game's layout: `DIALOG <name>`, a speaker, the text indented (Windows lines).
        const t = std.fmt.allocPrint(app.gpa, "DIALOG {s}\r\n\r\nSullivan:\r\n  ...\r\n", .{name[0 .. name.len - 4]}) catch return;
        const f = app.store.addNew(&.{.{ .archive = lang_archive, .entry = name, .text = t }}) catch |err| {
            app.gpa.free(t);
            return app.failed(err);
        };
        doctabs.showCode(app, f, null);
    }
}

/// A place a level script starts the scene: its file, level and the call.
const Entry = struct { file: usize, level: []const u8, entry: []const u8, call: scenes.Call };

fn entriesOf(app: *App, a: Allocator, name: []const u8) []const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (app.catalog.scene_files.items) |sfile| {
        const fi = app.store.file(sfile.archive, sfile.entry) catch continue;
        const cs = scenes.calls(a, app.store.text(fi), name) catch continue;
        for (cs) |call| out.append(a, .{ .file = fi, .level = sfile.level, .entry = sfile.entry, .call = call }) catch {};
    }
    return out.items;
}

/// The scene as the concept's page: its header and views (overview, lines, code, debug)
/// on the left, its properties, utilities and Info on the right.
fn scenePage(app: *App, a: Allocator, name: []const u8) void {
    if (app.ogLayout()) return @import("og_page.zig").scene(app, a, name);
    const sf = sceneFile(app, name);
    const entries = entriesOf(app, a, name);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    // The page's width for its tables (they don't widen the window at a large UI scale).
    clay.openScrollColumn(.{ .id = clay.id("scene_detail"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = page_pad, .childGap = lay.space.md } });
    if (header(app, a, name)) {
        clay.closeScrollColumn();
        clay.close();
        return;
    }
    viewTabs(app, sf);
    if (sf) |f| switch (app.scenes.view) {
        .overview => {
            entryTable(app, a, entries);
            effectTable(app, a, f);
            mapPreview(app, a, f, entries);
        },
        .lines => {
            dialogs(app, a, app.store.text(f));
            if (!scenes.hasCmd(app.store.text(f), "DIALOG_INIT")) gui.txt(tx.get(tx.sc_no_lines), .body, theme.dim, font_mod.regular);
        },
        .debug => debugView(app, a, name, f, entries),
    } else gui.txt(tx.get(tx.sc_none), .body, theme.dim, font_mod.regular);
    clay.closeScrollColumn();
    inspector(app, a, name, sf, entries);
    clay.close();
}

/// The icon, the name (a click renames), "Scene scriptlet" and Play in the port; true when renamed.
fn header(app: *App, a: Allocator, name: []const u8) bool {
    gui.row(lay.space.md);
    gui.icon(app, .clapperboard, lay.icon.xl, theme.accent_hover);
    // The name up to a slider's width, narrower when Play needs the room (a large UI scale).
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.growMax(lay.width.slider) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    const fid = classicId(name);
    const given = textedit.taken(app, fid);
    const typing = textedit.typedIn(app, fid);
    const naming = typing != null or given != null;
    // A title until clicked, then a field.
    clay.open(.{ .id = fid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.tool) }, .padding = gui.pad(lay.space.sm, 0), .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (naming) theme.field else if (clay.pointerOver(fid)) theme.row_hover else theme.bg, .cornerRadius = clay.radius(lay.radius.md), .border = .{ .color = if (naming) theme.accent else theme.bg, .width = gui.edges(lay.border.line) } });
    if (clay.hovered() and app.clicked and typing == null) rename(app, name);
    gui.txtClip(if (typing) |e| std.fmt.allocPrint(a, "{s}|", .{e.text()}) catch "" else name, .heading, theme.text, font_mod.bold);
    clay.close();
    gui.txtClip(tx.get(if (naming) tx.sc_rename_hint else tx.sc_kind), .caption, theme.dim, font_mod.regular);
    clay.close();
    // Shown while typed into and the frame its typing is given (its click gives it).
    const button = naming and gui.button(app, "scene_rename", tx.get(tx.lp_area_rename), true);
    gui.spacer();
    if (sceneLevel(app, a, name)) |lvl| if (gui.toolButton(app, "scene_play", .play, tx.alloc(a, tx.sc_play_port, .{lvl}), false, true)) play.playIn(app, lvl, name);
    clay.close();
    if (given) |g| if (g.entered or button) {
        levelops.renameScene(app, name, g.text());
        return true;
    };
    return false;
}

/// OpenGorky: the scene page's header (its name: a click renames it); true when renamed.
pub fn ogHeader(app: *App, a: Allocator, name: []const u8) bool {
    return header(app, a, name);
}

/// OpenGorky: the places the project's texts start scene `name` (`~e"<name>"`): the file,
/// its level (`src/locations/<l>/…`, `src/battles/<b>/…`; "" another text) and the place.
fn ogEntries(app: *App, a: Allocator, name: []const u8) []const Entry {
    const og_src = @import("store.zig").og_src;
    const q = std.fmt.allocPrint(a, "~e\"{s}\"", .{name}) catch return &.{};
    var out: std.ArrayList(Entry) = .empty;
    for (app.store.listing(a, og_src, null, true)) |p| {
        const f = app.store.file(og_src, p) catch continue;
        const text = app.store.text(f);
        var it = std.mem.splitScalar(u8, p, '/');
        const top = it.next() orelse "";
        const lvl = if (std.mem.eql(u8, top, "locations") or std.mem.eql(u8, top, "battles")) it.next() orelse "" else "";
        var pos: usize = 0;
        while (std.ascii.findIgnoreCasePos(text, pos, q)) |at| : (pos = at + q.len) {
            out.append(a, .{ .file = f, .level = lvl, .entry = p, .call = .{ .at = at, .addon = false, .state = .on } }) catch {};
        }
    }
    // The map and the test run take the first start on a level.
    std.mem.sort(Entry, out.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return x.level.len > 0 and y.level.len == 0;
        }
    }.lt);
    return out.items;
}

/// OpenGorky: where the project's texts start scene `name` (`~e"<name>"`): each place, its
/// file (› the code editor) and its block.
pub fn ogStarts(app: *App, a: Allocator, name: []const u8) void {
    gui.heading(tx.get(tx.sc_entries), "");
    const es = ogEntries(app, a, name);
    for (es, 0..) |en, n| {
        const text = app.store.text(en.file);
        gui.rowFit(lay.space.sm);
        gui.icon(app, .code, lay.icon.md, theme.accent_hover);
        gui.txt(en.entry, .label, theme.text, font_mod.regular);
        if (gui.button(app, std.fmt.allocPrint(a, "og_sc_code{d}", .{n + 1}) catch "c", tx.get(tx.code_in_editor), false)) doctabs.showCode(app, en.file, en.call.at);
        clay.close();
        const span = scenes.block(text, en.call.at);
        codeBlock(a, text, span.start, span.end);
    }
    if (es.len == 0) gui.txt(tx.get(tx.sc_none), .body, theme.dim, font_mod.regular);
}

/// OpenGorky: the scene page's views (overview, lines, debug, as on Classic; Code opens the
/// scene's block file `f`).
pub fn ogTabs(app: *App, f: usize) void {
    viewTabs(app, f);
}

/// OpenGorky: the overview's map — the level of the scene's first start, what the scene
/// names picked out (as on Classic); none when no level starts it.
pub fn ogMap(app: *App, a: Allocator, name: []const u8, f: usize) void {
    const es = ogEntries(app, a, name);
    if (es.len == 0 or es[0].level.len == 0) return;
    mapPreview(app, a, f, es[0..1]);
}

/// OpenGorky: the Lines or Debug view of scene `name` (block file `f`) in the page's column.
pub fn ogView(app: *App, a: Allocator, name: []const u8, f: usize) void {
    clay.openScrollColumn(.{ .id = clay.id("scene_detail"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = page_pad, .childGap = lay.space.md } });
    switch (app.scenes.view) {
        .overview => {},
        .lines => ogDialogs(app, a, app.store.text(f)),
        .debug => {
            const es = ogEntries(app, a, name);
            debugView(app, a, name, f, if (es.len > 0 and es[0].level.len > 0) es[0..1] else &.{});
        },
    }
    clay.closeScrollColumn();
}

/// OpenGorky: what the scene's characters say — each `DIALOG_INIT(…, "x.dlg")` of the scene's
/// block as the project's `dialog "x"` block (`src/dialogs/x.ogs`): its lines numbered as
/// `DIALOG_DISPLAY(n)` shows them, typed in place as on Classic (who, what; moved, added
/// after, deleted: the block's `Line(…)` rows, dlgedit.applyOg), each with its voice
/// (listened to, a file of one's own, out to a file, a recording of the dialogue given to it).
fn ogDialogs(app: *App, a: Allocator, scr: []const u8) void {
    var it = std.mem.splitScalar(u8, scr, '\n');
    var k: u32 = 0;
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!scenes.isCmd(l, "DIALOG_INIT")) continue;
        const q1 = std.mem.lastIndexOfScalar(u8, l, '"') orelse continue;
        const q0 = std.mem.lastIndexOfScalar(u8, l[0..q1], '"') orelse continue;
        const dlg = l[q0 + 1 .. q1];
        if (ogDialogFile(app, a, dlg) == null) continue;
        if (k == 0) gui.panelHeader(tx.get(tx.sc_lines));
        k += 1;
        if (ogDialogBlock(app, a, dlg, k)) return;
    }
    if (k == 0) gui.txt(tx.get(tx.sc_no_lines), .body, theme.dim, font_mod.regular);
}

/// OpenGorky: the block file of dialogue `dlg` (`x.dlg` or `x`: `dialogs/x.ogs`), if any.
fn ogDialogFile(app: *App, a: Allocator, dlg: []const u8) ?usize {
    const stem = if (std.ascii.endsWithIgnoreCase(dlg, ".dlg")) dlg[0 .. dlg.len - 4] else dlg;
    return app.store.file(@import("store.zig").og_src, std.fmt.allocPrint(a, "dialogs/{s}.ogs", .{stem}) catch return null) catch null;
}

/// OpenGorky: a battle's or idle dialogue on its own, its block in `dialogs/`; a battle
/// without one gets a new block there (as a scene's, levelops.newSceneOg).
fn dialogPageOg(app: *App, a: Allocator, name: []const u8) void {
    const stem = if (std.ascii.endsWithIgnoreCase(name, ".dlg")) name[0 .. name.len - 4] else name;
    gui.txt(std.fmt.allocPrint(a, "dialogs/{s}.ogs", .{stem}) catch stem, .heading, theme.text, font_mod.bold);
    gui.txt(tx.get(if (std.ascii.startsWithIgnoreCase(name, "idle_")) tx.sc_idle_hint else tx.sc_battle_hint_og), .caption, theme.dim, font_mod.regular);
    if (ogDialogFile(app, a, name) != null) {
        _ = ogDialogBlock(app, a, name, 1);
        return;
    }
    if (gui.button(app, "dlg_new", tx.get(tx.sc_new_lines), true)) {
        const t = std.fmt.allocPrint(app.gpa, "dialog \"{s}\" {{\n    Line(who = \"Sullivan\", text = \"...\");\n}}\n", .{stem}) catch return;
        const f = app.store.addNew(&.{.{ .archive = @import("store.zig").og_src, .entry = std.fmt.allocPrint(a, "dialogs/{s}.ogs", .{stem}) catch return, .text = t }}) catch |err| {
            app.gpa.free(t);
            return app.failed(err);
        };
        doctabs.showCode(app, f, null);
    }
}

/// OpenGorky: dialogue `dlg`'s block lines (each with its voice), `k` keeping element ids
/// apart; true when a line changed the file (the frame's view of it is stale).
fn ogDialogBlock(app: *App, a: Allocator, dlg: []const u8, k: u32) bool {
    const model_og = @import("model_og.zig");
    const f = ogDialogFile(app, a, dlg) orelse return false;
    const stem = if (std.ascii.endsWithIgnoreCase(dlg, ".dlg")) dlg[0 .. dlg.len - 4] else dlg;
    const b = model_og.blockOf(app, a, f) orelse return false;
    {
        gui.rowFit(lay.space.sm);
        gui.txt(std.fmt.allocPrint(a, "dialogs/{s}.ogs", .{stem}) catch stem, .label, theme.text, font_mod.bold);
        if (gui.button(app, std.fmt.allocPrint(a, "ogdlg_code{d}", .{k}) catch "d", tx.get(tx.sc_edit_lines), false)) doctabs.showCode(app, b.text_file, b.e.span.start);
        clay.close();
        const prefix = stemOf(dlg, a);
        var n: usize = 0;
        for (b.e.rows) |r| {
            if (r.kind != .call or !std.mem.eql(u8, r.kind.call.text, "Line")) continue;
            var who: []const u8 = "";
            var said: []const u8 = "";
            var voice: []const u8 = "";
            for (r.kind.call.named) |nv| {
                const v = og.core.schema.text(nv.value) orelse continue;
                if (std.mem.eql(u8, nv.name, "who")) who = v else if (std.mem.eql(u8, nv.name, "text")) said = v else if (std.mem.eql(u8, nv.name, "voice")) voice = if (std.mem.startsWith(u8, v, "voice/")) v["voice/".len..] else v;
            }
            if (lineRow(app, a, f, dlg, k, n, who, said)) return true;
            const id = k * 1000 + @as(u32, @intCast(n));
            if (voice.len > 0) voiceRow(app, a, voice, id, prefix) else if (silentRow(app, a, f, dlg, n, id, prefix)) return true;
            n += 1;
        }
    }
    return false;
}

/// OpenGorky: under a line with no voice: a file of one's own as its new recording
/// (dlgedit.voiceFromFile), or one of the dialogue's recordings given to it
/// (`voice = ~s"voice/…"`, the chooser). True when it changed the file.
fn silentRow(app: *App, a: Allocator, f: usize, dlg: []const u8, n: usize, id: u32, prefix: []const u8) bool {
    clay.open(.{ .layout = .{ .childGap = lay.space.sm, .padding = .{ .left = lay.space.lg, .bottom = lay.space.xs }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    gui.txt(tx.get(tx.vo_none), .caption, theme.dim, font_mod.regular);
    if (gui.button(app, std.fmt.allocPrint(a, "vo_new{d}", .{id}) catch "v", tx.get(tx.vo_replace), false)) {
        app.voice_for.set(dlg);
        app.voice_line = n;
        app.askFile(.{ .kind = .sound, .run = onLineVoiceIn, .entry = f });
    }
    const pid = std.fmt.allocPrint(a, "vo_pick{d}", .{id}) catch "v";
    if (gui.button(app, pid, tx.get(tx.vo_pick), picker.isOpen(app, clay.id(pid)))) picker.toggle(app, clay.id(pid));
    clay.close();
    if (!picker.isOpen(app, clay.id(pid))) return false;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (voices.names(app, a, prefix)) |cand| rows.append(a, .{ .key = cand, .label = cand }) catch {};
    const j = picker.listPlay(app, a, rows.items, voices.play) orelse return false;
    @import("dlgedit.zig").apply(app, f, dlg, n, .{ .voice = rows.items[j].key }) catch |err| app.failed(err);
    return true;
}

/// File dialog answer of a silent line's «Own file…»: dialogue `app.voice_for`, line
/// `app.voice_line` of block file `ask.entry`.
fn onLineVoiceIn(app: *App, ask: @import("app.zig").FileAsk, path: []const u8) !void {
    try @import("dlgedit.zig").voiceFromFile(app, ask.entry, app.voice_for.get(), app.voice_line, path);
    app.setStatus(tx.st_voice_set, .{app.voice_for.get()});
}

/// Scene `name`'s name field (its own: a typing never reaches another scene's).
fn classicId(name: []const u8) ui.Clay_ElementId {
    return clay.idi("scene_name", @truncate(std.hash.Wyhash.hash(0, name)));
}

/// Scene `name`'s new name typed (its page shown).
pub fn rename(app: *App, name: []const u8) void {
    textedit.focusEnd(app, classicId(name), name, search.keep.sceneName, null);
}

/// The views; Code is the script in the code editor (its own tab, as a level's script).
fn viewTabs(app: *App, sf: ?usize) void {
    gui.rowFit(lay.space.sm);
    const views = [_]struct { @TypeOf(app.scenes.view), tx.Msg }{ .{ .overview, tx.sc_v_overview }, .{ .lines, tx.sc_v_lines }, .{ .debug, tx.sc_v_debug } };
    for (views[0..2]) |v| if (gui.button(app, @tagName(v[0]), tx.get(v[1]), app.scenes.view == v[0])) {
        app.scenes.view = v[0];
    };
    if (sf) |f| if (gui.button(app, "sc_code", tx.get(tx.sc_v_code), false)) doctabs.showCode(app, f, null);
    for (views[2..]) |v| if (gui.button(app, @tagName(v[0]), tx.get(v[1]), app.scenes.view == v[0])) {
        app.scenes.view = v[0];
    };
    clay.close();
}

/// A table's fixed column `n` units wide.
fn col(n: f32) lay.Track {
    return .{ .len = .{ .pt = n * lay.unit } };
}

/// A table's column taking the rest (at least a name's room).
const rest: lay.Track = .{ .minmax = .{ .min = .{ .pt = 15 * lay.unit }, .max = .{ .pct = 1 } } };

/// A table in the page: its columns sized inside the page's padding.
fn table(tracks: []const lay.Track) gui.Table {
    return gui.Table.open(clay.id("scene_detail"), 2 * lay.space.xl, tracks);
}

/// A script excerpt under a row, as code.
fn codeBlock(a: Allocator, text: []const u8, start: usize, end: usize) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = lay.space.sm, .right = lay.space.lg, .top = lay.space.sm, .bottom = lay.space.sm } }, .backgroundColor = theme.viewport });
    codeview.excerpt(a, text, start, end);
    clay.close();
}

/// Where it starts: each level script call as a row (where, what event, a switch
/// turning the start off, show on the map) with its block below.
fn entryTable(app: *App, a: Allocator, entries: []const Entry) void {
    gui.heading(tx.get(tx.sc_entries), tx.get(tx.sc_entries_note));
    if (entries.len == 0) return gui.txt(tx.get(tx.sc_none), .body, theme.dim, font_mod.regular);
    const t = table(&.{ rest, col(24), col(10), col(21) });
    t.head(&.{ tx.get(tx.sc_c_where), tx.get(tx.sc_c_event), tx.get(tx.sc_c_enabled), tx.get(tx.sc_c_actions) });
    for (entries, 0..) |en, k| {
        const text = app.store.text(en.file);
        const area = scenes.areaOf(a, text, en.call.at);
        gui.Table.line(false);
        t.cell(0);
        gui.icon(app, .map_pin, lay.icon.md, theme.accent_hover);
        gui.txt(en.level, .label, theme.text, font_mod.regular);
        if (area) |ar| {
            gui.icon(app, .chevron_right, lay.icon.sm, theme.dim);
            gui.txt(ar, .label, theme.text, font_mod.regular);
        }
        clay.close();
        t.cell(1);
        gui.txt(tx.get(if (en.call.addon) tx.sc_ev_addon else if (area != null) tx.sc_ev_area else tx.sc_ev_script), .body, theme.text, font_mod.regular);
        clay.close();
        t.cell(2);
        const id: u32 = @intCast(k);
        switch (en.call.state) {
            .game_off => gui.txt(tx.get(tx.sc_game_off_short), .caption, theme.dim, font_mod.regular),
            .on, .off => {
                const on = en.call.state == .on;
                const span = if (on) scenes.block(text, en.call.at) else scenes.offRun(text, en.call.at);
                if (!on or scenes.safe(text, en.call.at)) {
                    if (gui.switchBox(app, clay.idi("sc_en", id), on)) change(app, en.file, if (on) scenes.turnOff(app.gpa, text, span) else scenes.turnOn(app.gpa, text, en.call.at));
                } else gui.txt(tx.get(tx.sc_unsafe_short), .caption, theme.warn, font_mod.regular);
            },
        }
        clay.close();
        t.cell(3);
        if (area) |ar| {
            if (gui.toolButton(app, std.fmt.allocPrint(a, "sc_map{d}", .{k}) catch "m", .crosshair, tx.get(tx.sc_show_map), false, false)) app.link(false, en.level, ar);
        } else if (gui.toolButton(app, std.fmt.allocPrint(a, "sc_ecode{d}", .{k}) catch "m", .code, tx.get(tx.sc_view_code), false, false)) doctabs.showCode(app, en.file, en.call.at);
        clay.close();
        clay.close();
        const span = if (en.call.state == .off) scenes.offRun(text, en.call.at) else scenes.block(text, en.call.at);
        codeBlock(a, text, span.start, span.end);
    }
    clay.close();
}

/// What it changes in the game: each lasting command as a row (what, on what, the rest
/// of its arguments, its line in the code), the line below.
fn effectTable(app: *App, a: Allocator, f: usize) void {
    gui.heading(tx.get(tx.sc_effects), tx.get(tx.sc_effects_note));
    const text = app.store.text(f);
    var rows: usize = 0;
    var pos: usize = 0;
    var t: gui.Table = undefined;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (pos += raw.len + 1) {
        const l = std.mem.trim(u8, raw, " \t\r");
        const lc = scenes.lineCmd(l) orelse continue;
        const k = for (lasting, 0..) |cmd, i| {
            if (std.ascii.eqlIgnoreCase(lc.exe, cmd)) break i;
        } else continue;
        if (rows == 0) {
            t = table(&.{ col(25), rest, col(18), col(21) });
            t.head(&.{ tx.get(tx.sc_c_type), tx.get(tx.sc_c_target), tx.get(tx.sc_c_arg), tx.get(tx.sc_c_actions) });
        }
        rows += 1;
        const args = l[lc.args .. std.mem.lastIndexOfScalar(u8, l, ')') orelse l.len];
        const comma = std.mem.indexOfScalar(u8, args, ',');
        // `@Sullivan`, `~l"01_port"`, `"x"`: the name.
        const first = std.mem.trim(u8, args[0 .. comma orelse args.len], " ");
        const target = std.mem.trim(u8, if (first.len > 2 and first[0] == '~') first[2..] else if (first.len > 0 and first[0] == '@') first[1..] else first, "\"");
        const args_rest = if (comma) |ci| std.mem.trim(u8, args[ci + 1 ..], " ") else "";
        gui.Table.line(false);
        t.cell(0);
        gui.icon(app, effectIcon(lasting[k]), lay.icon.md, theme.dim);
        gui.txt(tx.get(effect_names[k]), .label, theme.text, font_mod.regular);
        clay.close();
        t.cell(1);
        gui.txt(target, .label, theme.text, font_mod.regular);
        clay.close();
        t.cell(2);
        gui.txt(args_rest, .body, theme.dim, font_mod.regular);
        clay.close();
        t.cell(3);
        const id = std.fmt.allocPrint(a, "sc_eff{d}", .{rows}) catch "e";
        if (std.ascii.eqlIgnoreCase(lasting[k], "ADDONSCRIPTLET")) {
            if (gui.toolButton(app, id, .clapperboard, tx.alloc(a, tx.ln_scene, .{target}), false, false)) app.link(true, target, null);
        } else if (std.ascii.eqlIgnoreCase(lasting[k], "LOADLEVEL")) {
            if (gui.toolButton(app, id, .map_pin, tx.alloc(a, tx.ln_level, .{target}), false, false)) app.link(false, target, null);
        } else if (gui.toolButton(app, id, .code, tx.get(tx.sc_view_code), false, false)) doctabs.showCode(app, f, pos);
        clay.close();
        clay.close();
        codeBlock(a, text, pos, pos + raw.len);
    }
    if (rows == 0) gui.txt(tx.get(tx.sc_no_changes), .body, theme.dim, font_mod.regular) else clay.close();
}

const effect_names = [_]tx.Msg{ tx.ef_sethero, tx.ef_delete, tx.ef_disable, tx.ef_loadlevel, tx.ef_prevlevel, tx.ef_runfun, tx.ef_allow_walk, tx.ef_forbid_walk, tx.ef_item, tx.ef_next, tx.ef_place, tx.ef_gameover, tx.ef_enddemo, tx.ef_credits };

fn effectIcon(cmd: []const u8) icons.Icon {
    if (std.ascii.eqlIgnoreCase(cmd, "PLACEHEROES") or std.ascii.eqlIgnoreCase(cmd, "SETHERO")) return .user;
    if (std.ascii.eqlIgnoreCase(cmd, "LOADLEVEL") or std.ascii.eqlIgnoreCase(cmd, "PREVLEVEL")) return .log_out;
    if (std.ascii.eqlIgnoreCase(cmd, "ASSIGN_ITEM")) return .package;
    if (std.ascii.eqlIgnoreCase(cmd, "ADDONSCRIPTLET")) return .clapperboard;
    if (std.ascii.endsWithIgnoreCase(cmd, "OBJECT")) return .eye_off;
    if (std.ascii.findIgnoreCase(cmd, "WALK") != null) return .square_dashed;
    return .play;
}

/// The scene's location (its first start's level) drawn small: its areas, objects and
/// the area that starts it, with what the scene names picked out.
fn mapPreview(app: *App, a: Allocator, f: usize, entries: []const Entry) void {
    if (entries.len == 0) return;
    const lvl = entries[0].level;
    const d = app.levelDoc(lvl) orelse return;
    gui.row(lay.space.md);
    gui.heading(tx.get(tx.sc_map), "");
    gui.spacer();
    gui.txt(tx.get(tx.sc_show), .body, theme.dim, font_mod.regular);
    const names = [_]tx.Msg{ tx.sc_show_areas, tx.sc_show_objects, tx.sc_show_entries };
    for (names, 0..) |n, k| if (gui.check(app, clay.idi("sc_show", @intCast(k)), app.scenes.show[k], tx.get(n))) {
        app.scenes.show[k] = !app.scenes.show[k];
    };
    clay.close();
    // What it uses: the starting area and the places the scene names.
    const pv = &app.scenes.preview;
    pv.doc = d;
    pv.sel = null;
    pv.focus = null;
    pv.names.clearRetainingCapacity();
    const text = app.store.text(entries[0].file);
    if (scenes.areaOf(a, text, entries[0].call.at)) |ar| for (d.objects.items, 0..) |o, i| if (std.ascii.eqlIgnoreCase(o.name, ar)) {
        pv.sel = i;
    };
    for (usedNames(a, d, app.store.text(f))) |i| pv.names.append(app.gpa, i) catch {};
    pv.show = app.scenes.show;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(48 * lay.unit) } }, .backgroundColor = theme.viewport, .cornerRadius = clay.radius(lay.radius.md), .custom = .{ .customData = pv } });
}

/// Objects of level `d` the scene text names in quotes.
fn usedNames(a: Allocator, d: *level_mod.Doc, text: []const u8) []const usize {
    var out: std.ArrayList(usize) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '"')) |q| {
        const e = std.mem.indexOfScalarPos(u8, text, q + 1, '"') orelse break;
        pos = e + 1;
        const n = text[q + 1 .. e];
        for (d.objects.items, 0..) |o, i| if (std.ascii.eqlIgnoreCase(o.name, n) and std.mem.indexOfScalar(usize, out.items, i) == null) out.append(a, i) catch {};
    }
    return out.items;
}

/// Draws the preview (the viewport callback): the level fitted around what the scene
/// uses, the doc's own view kept.
pub fn drawPreview(app: *App, rect: c.SDL_FRect) void {
    const pv = &app.scenes.preview;
    const d = pv.doc orelse return;
    const keep = .{ d.origin, d.zoom, d.fitted, d.view_hidden };
    defer {
        d.origin = keep[0];
        d.zoom = keep[1];
        d.fitted = keep[2];
        d.view_hidden = keep[3];
    }
    // Hidden kinds: areas or every object (the checkboxes).
    var hidden: std.StringHashMapUnmanaged(void) = .empty;
    defer hidden.deinit(app.gpa);
    if (!pv.show[0]) hidden.put(app.gpa, "kind:area", {}) catch {};
    if (!pv.show[1]) for ([_][]const u8{ "kind:enemy", "kind:hero", "kind:neutral", "kind:prop", "kind:item", "kind:actor" }) |k| hidden.put(app.gpa, k, {}) catch {};
    d.view_hidden = &hidden;
    // Around the used places (the whole level if none), with room about them.
    var lo: [2]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32) };
    var hi: [2]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (pv.names.items) |i| {
        const p = d.objects.items[i].pos;
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    if (pv.sel) |i| {
        const p = d.objects.items[i].pos;
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    d.fit(rect);
    if (lo[0] <= hi[0]) {
        const w = @max(hi[0] - lo[0] + 500, 700);
        const h = @max(hi[1] - lo[1] + 400, 500);
        d.zoom = @max(d.zoom, @min(rect.w / w, rect.h / h));
        const mid: [2]f32 = .{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 };
        d.origin = .{ mid[0] - rect.w / 2 / d.zoom, mid[1] - rect.h / 2 / d.zoom };
    }
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    _ = c.SDL_SetRenderClipRect(app.r, &clip);
    d.draw(app.r, app.font, rect, if (pv.show[2]) pv.sel else null, true, true);
    _ = c.SDL_SetRenderClipRect(app.r, null);
}

/// Where the scene is tried: the level of its first start.
fn sceneLevel(app: *App, a: Allocator, name: []const u8) ?[]const u8 {
    const es = entriesOf(app, a, name);
    return if (es.len > 0) es[0].level else null;
}

/// A test run: the scene on its level to the end without a window — whether it ends,
/// when each command starts (a click: its line in the code), what looks wrong.
fn debugView(app: *App, a: Allocator, name: []const u8, f: usize, entries: []const Entry) void {
    gui.heading(tx.get(tx.sc_v_debug), tx.get(tx.sc_debug_note));
    if (entries.len == 0) return gui.txt(tx.get(tx.sc_debug_nolevel), .body, theme.warn, font_mod.regular);
    const lvl = entries[0].level;
    gui.rowFit(lay.space.sm);
    if (gui.toolButton(app, "sc_run", .check, tx.get(tx.sc_run), false, true)) play.testScene(app, lvl, name);
    if (gui.toolButton(app, "sc_run_port", .play, tx.alloc(a, tx.sc_play_port, .{lvl}), false, false)) play.playIn(app, lvl, name);
    gui.txt(tx.alloc(a, tx.sc_run_on, .{lvl}), .caption, theme.dim, font_mod.regular);
    clay.close();
    const r = app.scenes.report orelse return;
    if (!std.ascii.eqlIgnoreCase(r.name, name)) return;
    const rep = r.report;
    const ok = std.mem.eql(u8, rep.result, "ok");
    gui.rowFit(lay.space.sm);
    gui.icon(app, if (ok) .check else .x, lay.icon.md, if (ok) theme.ok else theme.warn);
    gui.txt(tx.alloc(a, tx.sc_run_result, .{ rep.result, rep.ticks, @as(f32, @floatFromInt(rep.ticks)) / 30.0 }), .label, if (ok) theme.text else theme.warn, font_mod.bold);
    clay.close();
    gui.txt(tx.get(if (ok) tx.sc_r_ok else if (std.mem.eql(u8, rep.result, "HUNG")) tx.sc_r_hung else if (std.mem.eql(u8, rep.result, "moves")) tx.sc_r_moves else tx.sc_r_level), .caption, theme.dim, font_mod.regular);
    // What looks wrong, one per line.
    var it = std.mem.splitSequence(u8, rep.issues, "; ");
    while (it.next()) |is| if (is.len > 0) gui.txt(is, .body, theme.warn, font_mod.regular);
    if (rep.issues.len == 0) gui.txt(tx.get(tx.sc_run_clean), .body, theme.dim, font_mod.regular);
    // The commands as they ran.
    const t = table(&.{ col(11), col(8), rest, col(14) });
    t.head(&.{ tx.get(tx.sc_c_tick), tx.get(tx.sc_c_line), tx.get(tx.sc_c_cmd), tx.get(tx.sc_c_took) });
    const text = app.store.text(f);
    for (rep.trace, 0..) |st, k| {
        const rid = clay.idi("sc_step", @intCast(k));
        if (gui.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.control) }, .padding = gui.pad(lay.space.md, 0), .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } } }, false)) doctabs.showCode(app, f, code.lineOffset(text, st.line));
        t.cell(0);
        gui.txt(std.fmt.allocPrint(a, "{d}", .{st.start}) catch "", .body, theme.dim, font_mod.regular);
        clay.close();
        t.cell(1);
        gui.txt(std.fmt.allocPrint(a, "{d}", .{st.line}) catch "", .body, theme.dim, font_mod.regular);
        clay.close();
        t.cell(2);
        gui.txt(lineText(text, st.line), .body, theme.text, font_mod.regular);
        clay.close();
        t.cell(3);
        const took = st.end - st.start;
        gui.txt(std.fmt.allocPrint(a, "{d} ({d:.1} s)", .{ took, @as(f32, @floatFromInt(took)) / 30.0 }) catch "", .body, if (took > 300) theme.warn else theme.dim, font_mod.regular);
        clay.close();
        clay.close();
    }
    clay.close();
}

fn lineText(text: []const u8, line: u32) []const u8 {
    const s0 = code.lineOffset(text, line);
    const e = std.mem.indexOfScalarPos(u8, text, s0, '\n') orelse text.len;
    return std.mem.trim(u8, text[s0..e], " \t\r");
}

/// The scene's Info: its file and location, the areas and objects of the location it
/// names, the level scripts starting it (each call), the scenes naming it.
fn sceneInfo(name: []const u8, app: *App, list: *info.List) void {
    const a = list.a;
    const entry = list.fmt("scriptlets\\{s}.scr", .{name});
    info.defined(list, common_archive, entry, true);
    const entries = entriesOf(app, a, name);
    if (entries.len > 0) list.add(.{ .group = .level, .text = entries[0].level, .to = .{ .level = .{ .name = entries[0].level } }, .icon = .map_pin });
    if (sceneFile(app, name)) |f| if (entries.len > 0) if (app.levelDoc(entries[0].level)) |d| {
        for (usedNames(a, d, app.store.text(f))) |i| {
            const o = d.objects.items[i];
            list.add(.{ .group = .refs, .text = o.name, .to = .{ .level = .{ .name = entries[0].level, .obj = o.name } }, .icon = if (o.kind == .area) .square_dashed else .box });
        }
    };
    for (entries) |en| list.add(.{ .group = .used, .text = list.fmt("{s} · {s}", .{ en.level, en.entry }), .to = .{ .code = .{ .archive = app.store.files.items[en.file].archive, .entry = en.entry, .at = en.call.at } }, .icon = .code });
    info.scenesNaming(app, list, list.fmt("\"{s}\"", .{name}), name);
}

/// The right column: ID, entry points; a shortened copy, skipping it; its Info.
fn inspector(app: *App, a: Allocator, name: []const u8, sf: ?usize, entries: []const Entry) void {
    gui.propsPanel(app, "scene_inspector");
    gui.groupTitle(tx.get(tx.sc_props), true);
    gui.propRow(tx.get(tx.sc_p_id), name);
    gui.propRow(tx.get(tx.sc_entries), std.fmt.allocPrint(a, "{d}", .{entries.len}) catch "");
    gui.groupTitle(tx.get(tx.sc_utils), false);
    if (gui.toolButton(app, "sc_short_copy", .copy, tx.get(tx.sc_short_copy), false, false)) shortCopy(app, name);
    gui.note(tx.get(tx.sc_short_copy_hint));
    if (sf) |f| {
        const on = skipped(app, name);
        if (gui.toolButton(app, "scene_skip", .eye_off, tx.get(if (on) tx.sc_unskip else tx.sc_skip), on, false)) toggleSkip(app, f, on);
        gui.note(tx.get(tx.sc_skip_hint));
    }
    gui.groupTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "scene:{s}", .{name}) catch name, name, sceneInfo));
    gui.propsEnd();
}

/// A copy of the scene with its presentation commented out (its changes stay).
fn shortCopy(app: *App, name: []const u8) void {
    treemenu.duplicate(app, treemenu.Item.of(.scene, name));
    const copy = app.sceneName() orelse return;
    if (std.ascii.eqlIgnoreCase(copy, name)) return;
    const f = sceneFile(app, copy) orelse return;
    if (!skipped(app, copy)) toggleSkip(app, f, false);
}

/// What the scene's characters say: each `DIALOG_INIT(name, "file.dlg")` file of
/// `common/lang.dat`, its lines numbered as `DIALOG_DISPLAY(n)` shows them; the text
/// opens in the code editor (the original reads lang.dat from the game folder).
fn dialogs(app: *App, a: Allocator, scr: []const u8) void {
    var it = std.mem.splitScalar(u8, scr, '\n');
    var k: u32 = 0;
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!std.ascii.startsWithIgnoreCase(l, "DIALOG_INIT(")) continue;
        // The file: the last quoted argument.
        const q1 = std.mem.lastIndexOfScalar(u8, l, '"') orelse continue;
        const q0 = std.mem.lastIndexOfScalar(u8, l[0..q1], '"') orelse continue;
        const name = l[q0 + 1 .. q1];
        const f = app.store.file(lang_archive, name) catch continue;
        if (k == 0) gui.panelHeader(tx.get(tx.sc_lines));
        k += 1;
        dialogBlock(app, a, f, name, k);
    }
}

/// One dialogue file `name` (Store file `f`): its lines with their voice files, the
/// recordings no line plays; `k` keeps the element ids apart.
fn dialogBlock(app: *App, a: Allocator, f: usize, name: []const u8, k: u32) void {
    gui.rowFit(lay.space.sm);
    gui.txt(name, .label, theme.text, font_mod.bold);
    if (gui.button(app, std.fmt.allocPrint(a, "dlg_code{d}", .{k}) catch "d", tx.get(tx.sc_edit_lines), false)) doctabs.showCode(app, f, null);
    clay.close();
    const utf8 = code.fromGame(a, app.store.text(f), app.catalog.cyrillic) catch return;
    const dlg = og.formats.dialog.parse(a, utf8) catch return;
    // Voice files: the lines' own, and the dialogue's no line names (left over from
    // a shift, or not yet given to a line).
    var used: std.ArrayList([]const u8) = .empty;
    for (dlg.lines, 0..) |ln, n| {
        var vb: [64]u8 = undefined;
        const vn = a.dupe(u8, og.formats.dialog.voiceName(&vb, name, ln.code, n) catch "") catch "";
        used.append(a, vn) catch {};
        // The line typed in place: who says it, what; moved, added after, deleted.
        if (lineRow(app, a, f, name, k, n, ln.speaker, ln.text)) return;
        voiceRow(app, a, vn, k * 1000 + @as(u32, @intCast(n)), stemOf(name, a));
    }
    const all = voices.names(app, a, stemOf(name, a));
    var spare: usize = 0;
    for (all) |vn| {
        for (used.items) |u| {
            if (std.ascii.eqlIgnoreCase(u, vn)) break;
        } else {
            if (spare == 0) gui.txt(tx.get(tx.vo_spare), .caption, theme.warn, font_mod.bold);
            spare += 1;
            clay.open(.{ .layout = .{ .childGap = lay.space.sm, .padding = .{ .left = lay.space.lg }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            gui.txt(vn, .caption, theme.dim, font_mod.regular);
            if (gui.button(app, std.fmt.allocPrint(a, "vs_play{d}_{d}", .{ k, spare }) catch "v", tx.get(tx.vo_play), false)) voices.play(app, vn);
            if (gui.button(app, std.fmt.allocPrint(a, "vs_del{d}_{d}", .{ k, spare }) catch "v", tx.get(tx.vo_remove), false)) app.askDelete(.voice, 0, vn);
            clay.close();
        }
    }
}

/// Line `n` of dialogue file `f`: its number (DIALOG_DISPLAY's), speaker and text fields,
/// up, down, a new line after it, delete. True when it changed the file (the caller stops
/// drawing the old lines).
fn lineRow(app: *App, a: Allocator, f: usize, name: []const u8, k: u32, n: usize, speaker: []const u8, text: []const u8) bool {
    const dlgedit = @import("dlgedit.zig");
    const id = k * 1000 + @as(u32, @intCast(n));
    var op: ?dlgedit.Op = null;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_TOP } } });
    // The number level with the fields' first line.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.control) }, .padding = .{ .top = lay.space.sm } } });
    gui.txt(std.fmt.allocPrint(a, "{d}.", .{n}) catch "", .body, theme.dim, font_mod.regular);
    clay.close();
    if (gui.textField(app, std.fmt.allocPrint(a, "dl_sp{d}", .{id}) catch "s", speaker, lay.width.field, "")) |v| {
        if (!std.mem.eql(u8, v, speaker)) op = .{ .speaker = v };
    }
    if (gui.textField(app, std.fmt.allocPrint(a, "dl_tx{d}", .{id}) catch "t", text, 0, "")) |v| {
        if (!std.mem.eql(u8, v, text)) op = .{ .text = v };
    }
    if (gui.toolButton(app, std.fmt.allocPrint(a, "dl_up{d}", .{id}) catch "u", .chevron_down, "", false, false)) op = .down;
    if (gui.toolButton(app, std.fmt.allocPrint(a, "dl_add{d}", .{id}) catch "p", .plus, "", false, false)) op = .add_after;
    if (gui.toolButton(app, std.fmt.allocPrint(a, "dl_del{d}", .{id}) catch "d", .trash_2, "", false, false)) op = .delete;
    clay.close();
    const o = op orelse return false;
    dlgedit.apply(app, f, name, n, o) catch |err| app.failed(err);
    return true;
}

/// The voice file prefix of dialogue `dlg` (`port-arriving.dlg` → `port_arriving_`).
fn stemOf(dlg: []const u8, a: Allocator) []const u8 {
    return og.formats.dialog.voicePrefix(a.alloc(u8, dlg.len + 1) catch return "", dlg) catch "";
}

/// Under a line: its voice file, there or not; listen, a file of one's own, out to a
/// file, or one of the dialogue's recordings given to it (the chooser).
fn voiceRow(app: *App, a: Allocator, vn: []const u8, id: u32, prefix: []const u8) void {
    const there = voices.has(app, vn);
    clay.open(.{ .layout = .{ .childGap = lay.space.sm, .padding = .{ .left = lay.space.lg, .bottom = lay.space.xs }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    gui.txt(vn, .caption, if (there) theme.dim else theme.warn, font_mod.regular);
    if (!there) gui.txt(tx.get(tx.vo_missing), .caption, theme.warn, font_mod.bold);
    if (there) if (gui.button(app, std.fmt.allocPrint(a, "vo_play{d}", .{id}) catch "v", tx.get(tx.vo_play), false)) voices.play(app, vn);
    if (gui.button(app, std.fmt.allocPrint(a, "vo_set{d}", .{id}) catch "v", tx.get(tx.vo_replace), false)) {
        app.voice_for.set(vn);
        app.askFile(.{ .kind = .sound, .run = voices.onVoiceIn });
    }
    if (there) if (gui.button(app, std.fmt.allocPrint(a, "vo_out{d}", .{id}) catch "v", tx.get(tx.vo_export), false)) {
        app.voice_for.set(vn);
        app.askFile(.{ .kind = .wav_out, .run = voices.onVoiceOut, .name = vn });
    };
    const pid = std.fmt.allocPrint(a, "vo_pick{d}", .{id}) catch "v";
    if (gui.button(app, pid, tx.get(tx.vo_pick), picker.isOpen(app, clay.id(pid)))) picker.toggle(app, clay.id(pid));
    clay.close();
    if (!picker.isOpen(app, clay.id(pid))) return;
    // The chooser: every recording of this dialogue, each played or taken.
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (voices.names(app, a, prefix)) |cand| if (!std.ascii.eqlIgnoreCase(cand, vn)) rows.append(a, .{ .key = cand, .label = cand }) catch {};
    const j = picker.listPlay(app, a, rows.items, voices.play) orelse return;
    if (voices.copyTo(app, rows.items[j].key, vn)) app.setStatus(tx.st_voice_set, .{vn}) else |err| app.failed(err);
}

const lang_archive = "common/lang.dat";

/// A script place as a card: where (`title`), its block and the button turning it
/// off (`off`) or on again.
pub fn card(app: *App, a: Allocator, file: usize, level: []const u8, title: []const u8, call: scenes.Call, id: u32, off: tx.Msg) void {
    const text = app.store.text(file);
    const span = if (call.state == .off) scenes.offRun(text, call.at) else scenes.block(text, call.at);
    // OpenGorky: off by the block's switch variable (ogSwitch), never by comments.
    const sw = if (app.ogLayout()) ogSwitch(app, text, call.at) else null;
    const off_now = if (sw) |w| !w.on else call.state == .off;
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.md, lay.space.sm), .childGap = lay.space.xs },
        .backgroundColor = theme.panel,
        .border = .{ .color = if (off_now) theme.warn else theme.line, .width = .{ .left = lay.border.mark } },
    });
    gui.rowFit(lay.space.sm);
    gui.txt(title, .label, theme.text, font_mod.bold);
    if (gui.button(app, std.fmt.allocPrint(a, "trig_code{d}", .{id}) catch "c", tx.get(tx.code_in_editor), false)) doctabs.showCode(app, file, call.at);
    if (app.ogLayout()) {
        if (sw) |w| if (gui.button(app, std.fmt.allocPrint(a, "trig_og{d}", .{id}) catch "t", tx.get(if (w.on) off else tx.sc_turn_on), !w.on)) change(app, w.file, @import("trigger.zig").setLevelVarOg(app.gpa, app.store.text(w.file), w.name, !w.on));
    } else switch (call.state) {
        .game_off => gui.txt(tx.get(tx.sc_game_off), .caption, theme.dim, font_mod.regular),
        .on => if (!scenes.safe(text, call.at)) {
            gui.txt(tx.get(tx.sc_unsafe), .caption, theme.warn, font_mod.regular);
        } else if (gui.button(app, std.fmt.allocPrint(a, "trig_off{d}", .{id}) catch "t", tx.get(off), false)) change(app, file, scenes.turnOff(app.gpa, text, span)),
        .off => if (gui.button(app, std.fmt.allocPrint(a, "trig_on{d}", .{id}) catch "t", tx.get(tx.sc_turn_on), true)) change(app, file, scenes.turnOn(app.gpa, text, call.at)),
    }
    clay.close();
    // OpenGorky: what switches it, under its buttons.
    if (app.ogLayout()) gui.txtWrap(if (sw) |w| tx.alloc(a, tx.sc_og_switch, .{ w.name, w.off_word }) else tx.get(tx.sc_og_no_switch), .caption, theme.dim, font_mod.regular);
    // Links: the area whose entering runs this block, the scenes it starts.
    gui.rowFit(lay.space.sm);
    if (scenes.areaOf(a, text, call.at)) |ar| if (gui.button(app, std.fmt.allocPrint(a, "lnk_area{d}", .{id}) catch "l", tx.alloc(a, tx.ln_area, .{ ar, level }), false)) app.link(false, level, ar);
    for (scenes.startedIn(a, text, call.at), 0..) |sc, k| {
        if (app.sceneName()) |cur| if (app.tab == .scenes and std.ascii.eqlIgnoreCase(cur, sc)) continue;
        if (gui.button(app, std.fmt.allocPrint(a, "lnk_scene{d}_{d}", .{ id, k }) catch "l", tx.alloc(a, tx.ln_scene, .{sc}), false)) app.link(true, sc, null);
    }
    clay.close();
    // The lines turning it off takes (or took) out.
    var lines = std.mem.splitScalar(u8, text[span.start..span.end], '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, " \t\r");
        if (l.len == 0) continue;
        // Tabs as spaces (the font has no tab glyph).
        gui.txt(std.mem.replaceOwned(u8, a, l, "\t", "    ") catch l, .caption, if (off_now) theme.dim else theme.text, font_mod.regular);
    }
    clay.close();
}

/// OpenGorky: the switch of the block at `at` of a level's logic text — the level variable
/// its `if (ready_x and …)` tests (trigger.armOg), declared in the level block (level.ogs,
/// shown in "Fields"): off is its initial value false/0, so the block never runs (no comments
/// in the code). Null: no such variable, or the code arms it again (`ready_x = 1;`).
pub const Switch = struct { file: usize, name: []const u8, on: bool, off_word: []const u8 };

pub fn ogSwitch(app: *App, text: []const u8, at: usize) ?Switch {
    const trigger = @import("trigger.zig");
    const d = app.doc orelse return null;
    const lf = @import("level_og.zig").blockFile(d) orelse return null;
    const name = trigger.armOg(text, at) orelse return null;
    const lt = app.store.text(lf);
    const v = trigger.levelVarOg(lt, name) orelse return null;
    if (trigger.rearmedOg(text, name)) return null;
    const cur = lt[v.start..v.end];
    const words = std.mem.eql(u8, cur, "true") or std.mem.eql(u8, cur, "false");
    return .{ .file = lf, .name = name, .on = trigger.levelVarOn(lt, name), .off_word = if (words) "false" else "0" };
}

fn change(app: *App, file: usize, r: anyerror![]u8) void {
    const t = r catch |err| return app.failed(err);
    app.store.replace(file, t) catch |err| {
        app.gpa.free(t);
        app.failed(err);
    };
}

fn toggleSkip(app: *App, f: usize, on: bool) void {
    const text = app.store.text(f);
    change(app, f, if (on) scenes.unshorten(app.gpa, text) else scenes.shorten(app.gpa, text));
}

/// CLI `--scene-skip NAME` / `--scene-off NAME` (every start that is on).
pub fn scripted(app: *App, a: Allocator, skip: bool, name: []const u8) !void {
    // OpenGorky: off is the scene block's `enabled = false` (skip has no OG form yet).
    if (app.ogLayout()) {
        const op = @import("og_page.zig");
        if (skip) return error.NotOnOg;
        return op.setSceneOn(app, op.sceneFile(app, name) orelse return error.NoSuchScene, false);
    }
    if (skip) {
        const f = sceneFile(app, name) orelse return error.NoSuchScene;
        if (!skipped(app, name)) toggleSkip(app, f, false);
        return;
    }
    for (app.catalog.scene_files.items) |sfile| {
        const fi = app.store.file(sfile.archive, sfile.entry) catch continue;
        while (true) {
            const cs = try scenes.calls(a, app.store.text(fi), name);
            const call = for (cs) |cl| {
                if (cl.state == .on and scenes.safe(app.store.text(fi), cl.at)) break cl;
            } else break;
            change(app, fi, scenes.turnOff(app.gpa, app.store.text(fi), scenes.block(app.store.text(fi), call.at)));
        }
    }
}
