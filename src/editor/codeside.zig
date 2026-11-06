//! The code window's page (codeview.zig): its bar, find bar and crumbs, the outline
//! of functions, the Context panel (rules calls), the problems under it, the help column.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const code = @import("code.zig");
const api = @import("api.zig");
const rulesapi = @import("rulesapi.zig");
const refdata = @import("refdata.zig");
const codenav = @import("codenav.zig");
const og = @import("opengorky");
const info = @import("info.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const View = code.View;
const codeview = @import("codeview.zig");
const codetabs = @import("codetabs.zig");
const codecheck = @import("codecheck.zig");
const codetips = @import("codetips.zig");
const codecomplete = @import("codecomplete.zig");
const completion = @import("completion.zig");

const closeFind = codeview.closeFind;
const findFrom = codeview.findFrom;
const findNext = codeview.findNext;
const follow = codeview.follow;
const formatText = codeview.formatText;
const menu = codeview.menu;
const refresh = codetabs.refresh;
const check = codecheck.check;
const checkable = codecheck.checkable;
const gameFn = codecheck.gameFn;
const isScene = codecheck.isScene;
const Tip = codetips.Tip;
const declTips = codetips.declTips;
const docLine = codetips.docLine;
const headerDecl = codetips.headerDecl;
const problem = codetips.problem;
const rulesFile = codecomplete.rulesFile;

/// The open code as the centre's document: where it is (file, function), its tools;
/// the text with the outline and what the word at the cursor is beside it; problems and
/// the word's uses below.
pub fn page(app: *App, a: Allocator, v: *View) void {
    refresh(app, v);
    check(app, v);
    const t = v.buf.str();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.bg });
    // Breadcrumbs and tools (as icons when the path and their names don't fit).
    var bar = gui.Toolbar.open("code_bar");
    const archive = app.store.files.items[v.file].archive;
    const place = if (std.mem.endsWith(u8, archive, "/other.dat")) archive[0 .. archive.len - "/other.dat".len] else archive;
    // Battles › 01_port › 01__port_barge.lev (a level's), its other files under the level
    // owning them (Locations › 01_port › 01_port_castle › exit_are.are), or the archive (common files).
    const lvl = if (app.levelIndex(place)) |i| app.levels[i] else null;
    if (lvl) |lv| {
        crumb(app, &bar, tx.get(if (lv.battle) tx.at_battles else tx.at_locations), false);
        crumb(app, &bar, std.mem.replaceOwned(u8, a, @import("assettree.zig").chapter(lv.name), "__", "_") catch lv.name, true);
        if (!std.ascii.eqlIgnoreCase(std.fs.path.stem(v.title), lv.name)) crumb(app, &bar, lv.name, true);
    } else crumb(app, &bar, place, false);
    crumb(app, &bar, v.title, true);
    const fns = functions(a, t);
    if (currentFn(fns, v.buf.cursor)) |fi| crumb(app, &bar, std.fmt.allocPrint(a, "{s}{s}", .{ fns[fi].name, if (fns[fi].component) "" else "()" }) catch "", true);
    if (v.buf.changed) gui.txt(tx.get(if (v.stale) tx.code_stale else tx.code_changed), .body, theme.warn, font_mod.regular);
    gui.spacer();
    // A Classic script: its text, or (on) its functions as OG Script.
    if (checkable(v.title) and !rulesFile(app, v)) if (bar.button(app, "code_view", .code, tx.get(tx.code_view_ogs), v.ogs_view, false)) codetabs.setView(app, v, !v.ogs_view);
    if (bar.button(app, "code_tasks", .plus, tx.get(tx.code_tasks), v.tasks, false)) {
        v.tasks = true;
        v.popup = true;
        v.popup_sel = 0;
    }
    if (bar.button(app, "code_format", .file_text, tx.get(tx.code_format), false, false)) formatText(app, v);
    if (bar.button(app, "code_help", .search, tx.get(tx.code_help), v.help, false)) v.help = !v.help;
    bar.close();
    if (v.find_open) findBar(app, a, v);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    clay.leaf(.{ .id = clay.id("code_area"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .backgroundColor = theme.viewport, .custom = .{ .customData = v } });
    if (v.help) helpColumn(app, a, v) else side(app, a, v, fns);
    clay.close();
    bottom(app, a, v);
    menu(app, a, v);
    var line: usize = 1;
    for (t[0..v.buf.cursor]) |ch| line += @intFromBool(ch == '\n');
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.small) }, .padding = gui.pad(lay.space.md, 0), .childGap = lay.space.lg, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .top = lay.border.line } } });
    gui.txt(tx.alloc(a, tx.code_pos, .{ line, v.buf.cursor - code.lineStart(t, v.buf.cursor) + 1 }), .caption, theme.dim, font_mod.regular);
    gui.txtClip(tx.get(if (v.ogs_view) tx.code_view_note else tx.code_keys), .caption, if (v.ogs_view) theme.accent_hover else theme.dim, font_mod.regular);
    clay.close();
    clay.close();
}

/// Cmd+F's bar: the text (Enter: the next match), how many, previous / next, close.
fn findBar(app: *App, a: Allocator, v: *View) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.tab) }, .padding = gui.pad(lay.space.md, 0), .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } } });
    gui.icon(app, .search, lay.icon.md, theme.dim);
    if (gui.textField(app, "code_find", v.findText(), lay.width.slider, tx.get(tx.code_find))) |q| {
        v.setFind(q);
        findNext(v, true);
        // Enter again: the next one (a click away leaves the field).
        if (!app.clicked) @import("textedit.zig").focus(app, "code_find", q);
    }
    const q = v.findText();
    var n: usize = 0;
    if (q.len > 0) {
        var i: usize = 0;
        while (findFrom(v.buf.str(), q, i)) |k| : (i = k + q.len) n += 1;
    }
    gui.txt(tx.alloc(a, tx.code_matches, .{n}), .caption, theme.dim, font_mod.regular);
    if (gui.toolButton(app, "code_find_prev", .skip_back, "", false, false)) findNext(v, false);
    if (gui.toolButton(app, "code_find_next", .skip_forward, "", false, false)) findNext(v, true);
    gui.spacer();
    if (gui.toolButton(app, "code_find_close", .x, "", false, false)) closeFind(app, v);
    clay.close();
}

fn crumb(app: *App, bar: *gui.Toolbar, s: []const u8, chevron: bool) void {
    const font: u16 = if (chevron) font_mod.bold else font_mod.regular;
    if (chevron) gui.icon(app, .chevron_right, lay.icon.sm, theme.dim);
    gui.txt(s, .body, if (chevron) theme.text else theme.dim, font);
    bar.reserve(app.font.measure(s, font, gui.Type.body.pt())[0] + @as(f32, if (chevron) lay.icon.sm + lay.space.sm else 0));
}

pub const functions = code.functions;
pub const signatureOf = completion.signatureOf;
pub const fieldLine = completion.fieldLine;
pub const fnDesc = completion.fnDesc;
pub const signature = completion.signature;
pub const currentFn = code.currentFn;
const Func = code.Func;

/// The identifier around the cursor (with its path: `fighter::SetHp`).
fn wordAt(t: []const u8, i: usize) []const u8 {
    var b = @min(i, t.len);
    while (b < t.len) {
        if (code.isIdent(t[b])) {
            b += 1;
        } else if (b + 2 < t.len and t[b] == ':' and t[b + 1] == ':' and code.isIdent(t[b + 2])) {
            b += 2;
        } else break;
    }
    return t[@import("callscan.zig").nameStart(t, @min(i, t.len))..b];
}

/// Uses of `w` as a whole word: their offsets.
fn uses(a: Allocator, t: []const u8, w: []const u8) []const usize {
    var out: std.ArrayList(usize) = .empty;
    if (w.len == 0) return out.items;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, t, pos, w)) |i| {
        pos = i + w.len;
        if (i > 0 and code.isIdent(t[i - 1])) continue;
        if (pos < t.len and code.isIdent(t[pos])) continue;
        out.append(a, i) catch {};
    }
    return out.items;
}

/// The outline (functions; a click goes there) and the word at the cursor: what it is
/// (engine function, variable and its type), its value set here, its uses.
fn side(app: *App, a: Allocator, v: *View, fns: []const Func) void {
    const t = v.buf.str();
    const sid = clay.id("code_side");
    gui.sidePanel(app.sidePane(300.0 / 1680.0), .{ .id = sid, .scroll = true, .pad = gui.pad(lay.space.md, lay.space.md), .gap = lay.space.xs });
    gui.form(sid, lay.width.label_sm, 0);
    gui.txt(tx.get(tx.code_outline), .label, theme.text, font_mod.bold);
    if (fns.len == 0) gui.txt(tx.get(tx.code_no_fns), .caption, theme.dim, font_mod.regular);
    const cur = currentFn(fns, v.buf.cursor);
    for (fns, 0..) |f, k| {
        const on = cur != null and cur.? == k;
        if (gui.listRow(app, clay.idi("code_fn", @intCast(k)), .{ .selected = on })) {
            v.buf.cursor = f.at;
            follow(v);
        }
        gui.icon(app, if (f.component) .package else .code, lay.icon.md, if (on) theme.text else theme.accent_hover);
        gui.txt(std.fmt.allocPrint(a, "{s}{s}", .{ f.name, if (f.component) "" else "()" }) catch f.name, if (f.component) .label else .body, theme.text, if (f.component) font_mod.bold else font_mod.regular);
        clay.close();
    }
    gui.divider();
    gui.txt(tx.get(tx.code_context), .label, theme.text, font_mod.bold);
    const w = wordAt(t, v.buf.cursor);
    if (w.len == 0) {
        gui.note(tx.get(tx.code_context_none));
    } else {
        // The buffer may change before the frame is drawn: copies.
        gui.propRow(tx.get(tx.code_k_name), a.dupe(u8, w) catch w);
        if (rulesFile(app, v) and rulesContext(app, a, v, w)) return clay.close();
        var file: []const u8 = v.title;
        if (api.find(w)) |f| {
            gui.propRow(tx.get(tx.code_k_type), tx.get(tx.code_t_fn));
            gui.txtWrap(signature(a, f), .caption, theme.accent_hover, font_mod.regular);
            gui.note(fnDesc(a, f, codecomplete.isOgs(app, v)));
        } else if (gameFn(app, w)) |g| {
            gui.propRow(tx.get(tx.code_k_type), tx.get(tx.code_t_game_fn));
            file = g.file;
            var tl: std.ArrayList(Tip) = .empty;
            declTips(a, headerDecl(a, g.name, g.params, g.doc, ""), &tl);
            for (tl.items, 0..) |l, k| gui.txtWrap(l.s, .caption, if (k == 0) theme.accent_hover else theme.text, font_mod.regular);
        } else if (isUnknown(v, w)) {
            gui.propRow(tx.get(tx.code_k_type), tx.get(tx.code_t_unknown));
        } else if (codetips.sceneText(app, v) and @import("scenedoc.zig").find(w) != null) {
            gui.propRow(tx.get(tx.code_k_type), tx.get(tx.code_t_scene));
            gui.note(tx.get(@import("scenedoc.zig").find(w).?.what));
        } else if (declType(t, w)) |ty| gui.propRow(tx.get(tx.code_k_type), a.dupe(u8, ty) catch ty);
        if (code.valueOf(t, w, v.buf.cursor)) |val| gui.propRow(tx.get(tx.code_k_value), a.dupe(u8, val) catch val);
        gui.propRow(tx.get(tx.code_k_uses), std.fmt.allocPrint(a, "{d}", .{uses(a, t, w).len}) catch "");
        gui.propRow(tx.get(tx.code_k_file), file);
    }
    clay.close();
}

/// `int w;` / `float w;` / `string w;`: its type.
fn declType(t: []const u8, w: []const u8) ?[]const u8 {
    for ([_][]const u8{ "int", "float", "string" }) |ty| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, t, pos, ty)) |i| {
            pos = i + ty.len;
            if (i > 0 and code.isIdent(t[i - 1])) continue;
            var j = pos;
            while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
            if (std.mem.startsWith(u8, t[j..], w) and (j + w.len >= t.len or !code.isIdent(t[j + w.len]))) return ty;
        }
    }
    return null;
}

/// The Context panel for word `w` of a rules file: a table's call (what it is) or a field
/// of the call at the cursor (its value on this row, type, default, what the value
/// means); false when `w` is neither.
fn rulesContext(app: *App, a: Allocator, v: *View, w: []const u8) bool {
    const t = v.buf.str();
    if (callName(t, v.buf.cursor)) |rc| {
        gui.propRow(tx.get(tx.code_k_type), tx.get(tx.code_t_rules));
        gui.txtWrap(signatureOf(a, rc), .caption, theme.accent_hover, font_mod.regular);
        gui.note(tx.get(rc.doc));
        return true;
    }
    const r = rulesAt(t, v.buf.cursor) orelse return false;
    const f = r.field orelse return false;
    if (!std.ascii.eqlIgnoreCase(f.name, w) and !(v.buf.cursor >= r.arg.?.value_start)) return false;
    const sh = rulesapi.shape(a, r.call.name, f.name);
    gui.propRow(tx.get(tx.code_k_type), tx.alloc(a, tx.code_t_field, .{ r.call.name, sh.ty }));
    gui.propRow(tx.get(tx.code_k_value), a.dupe(u8, r.arg.?.value) catch "");
    const means = codenav.rulesMeaning(app, a, f, r.arg.?.value);
    if (means.len > 0) gui.propRow(tx.get(tx.code_k_means), means);
    gui.propRow(tx.get(tx.code_k_default), if (sh.optional) tx.get(tx.code_optional) else if (sh.default.len > 0) sh.default else tx.get(tx.code_required));
    gui.note(tx.get(f.doc));
    return true;
}

pub const RulesAt = @import("completion.zig").RulesAt;
pub const rulesAt = @import("completion.zig").rulesAt;

/// The rules call whose name is the word at `i` (followed by its `(`; none in a comment).
pub fn callName(t: []const u8, i: usize) ?*const rulesapi.Call {
    const tok = code.tokenAt(t, i) orelse return null;
    if (tok.string or code.scanTo(t, tok.start).in != .code) return null;
    var e = tok.end;
    while (e < t.len and t[e] == ' ') e += 1;
    if (e >= t.len or t[e] != '(') return null;
    return rulesapi.find(t[tok.start..tok.end]);
}

/// Problems (the parser's error; a click goes to its line) or the word's uses.
fn bottom(app: *App, a: Allocator, v: *View) void {
    const t = v.buf.str();
    // Its tabs and three lines of problems or uses.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(4 * lay.height.tab) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .top = lay.border.line } } });
    const w = wordAt(t, v.buf.cursor);
    const refs = uses(a, t, w);
    const labels = [_][]const u8{
        tx.alloc(a, tx.code_problems, .{@as(u32, @intFromBool(v.err_line > 0)) + @as(u32, @intCast(v.unknown_n))}),
        tx.alloc(a, tx.code_refs, .{refs.len}),
        if (codenav.uses_word.len > 0) tx.alloc(a, tx.code_usages, .{ codenav.uses_word, codenav.uses.len }) else tx.get(tx.code_usages_tab),
    };
    if (gui.tabs(app, "code_bottom_tab", &labels, @backingInt(app.code_bottom))) |k| app.code_bottom = @fromBackingInt(@intCast(k));
    clay.openScroll(.{ .id = clay.id("code_bottom"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = lay.space.lg, .right = lay.space.lg, .top = lay.space.xs, .bottom = lay.space.sm }, .childGap = lay.space.xs } });
    switch (app.code_bottom) {
        .problems => if (v.err_line > 0 or v.unknown_n > 0) {
            if (v.err_line > 0) {
                const rid = clay.id("code_err");
                if (gui.clickable(app, .{ .id = rid, .layout = .{ .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false)) goLine(v, v.err_line);
                const msg = if (v.force) tx.alloc(a, tx.code_error_force, .{ v.err_line, v.err() }) else tx.alloc(a, tx.code_error, .{ v.err_line, v.err() });
                gui.txt(msg, .body, theme.warn, font_mod.regular);
                // A component lacking a trait's required methods: "Implement T" adds stubs.
                if (app.ogLayout()) if (@import("traitinfo.zig").requiredError(v.err())) |re| {
                    if (gui.smallButton(app, clay.id("code_fix"), tx.alloc(a, tx.cp_implement, .{re.trait}))) implement(app, a, v, re.comp, re.trait);
                };
                clay.close();
            }
            for (v.unknown[0..v.unknown_n], 0..) |*u, k| {
                if (gui.clickable(app, .{ .id = clay.idi("code_unk", @intCast(k)), .layout = .{ .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false)) goLine(v, u.line);
                const name = u.name[0..u.len];
                const msg = if (u.kind == .call and isScene(v.title)) tx.alloc(a, tx.code_unknown_scene, .{ u.line, name }) else problem(a, u);
                gui.txt(msg, .body, theme.warn, font_mod.regular);
                clay.close();
            }
        } else {
            clay.open(.{ .layout = .{ .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            gui.icon(app, .check, lay.icon.md, theme.ok);
            gui.txt(tx.get(if (checkable(v.title) or isScene(v.title) or codecheck.ogsText(v.title)) tx.code_no_issues else tx.code_not_checked), .body, theme.text, font_mod.regular);
            clay.close();
        },
        .usages => {
            if (codenav.uses.len == 0) gui.txt(tx.get(tx.code_usages_none), .body, theme.dim, font_mod.regular);
            for (codenav.uses, 0..) |u, k| {
                if (k >= 120) break;
                if (gui.clickable(app, .{ .id = clay.idi("code_use", @intCast(k)), .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = lay.space.sm }, .backgroundColor = theme.panel }, false)) {
                    info.follow(app, .{ .code = .{ .archive = u.archive, .entry = u.entry, .at = u.at } });
                }
                gui.txt(std.fmt.allocPrint(a, "{s}:{d}", .{ u.entry, u.line }) catch "", .caption, theme.accent_hover, font_mod.regular);
                gui.txt(u.text, .caption, theme.text, font_mod.regular);
                clay.close();
            }
        },
        .refs => for (refs, 0..) |at, k| {
            if (k >= 60) break;
            const ls = code.lineStart(t, at);
            const le = code.lineEnd(t, at);
            var ln: u32 = 1;
            for (t[0..at]) |ch| ln += @intFromBool(ch == '\n');
            const rid = clay.idi("code_ref", @intCast(k));
            if (gui.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = lay.space.sm }, .backgroundColor = theme.panel }, false)) {
                v.buf.cursor = at;
                follow(v);
            }
            gui.txt(std.fmt.allocPrint(a, "{d}", .{ln}) catch "", .caption, theme.dim, font_mod.regular);
            gui.txt(std.mem.trim(u8, t[ls..le], " \t\r\n"), .caption, theme.text, font_mod.regular);
            clay.close();
        },
    }
    clay.close();
    clay.close();
}

/// Quick fix "Implement T": stubs of the required methods of trait `trait` (and its
/// supertraits) component `comp` of the text lacks, before its closing brace; one undo step.
fn implement(app: *App, a: Allocator, v: *View, comp: []const u8, trait: []const u8) void {
    const ti = @import("traitinfo.zig");
    const own = app.store.files.items[v.file].entry;
    var texts: std.ArrayList(og.rules.Script) = .empty;
    for (og.rules.scripts) |x| if (!std.ascii.eqlIgnoreCase(x.name, own)) texts.append(a, x) catch {};
    texts.append(a, .{ .name = own, .data = v.buf.str() }) catch return;
    const p = ti.fromTexts(a, texts.items);
    const c = for (p.comps) |*c| {
        if (std.mem.eql(u8, c.it.name, comp) and std.mem.eql(u8, c.file, own)) break c;
    } else return;
    const r = p.resolve(a, c.it.module, c.uses, trait) orelse return;
    const stubs = ti.missing(&p, a, c, r);
    const at = ti.bodyEnd(v.buf.str(), c.it.line) orelse return;
    if (stubs.len == 0) return;
    const done = ti.insertMethods(a, v.buf.str(), at, stubs) catch return;
    v.buf.replaceSpan(0, v.buf.str().len, done.text) catch return;
    v.buf.cursor = done.at;
    follow(v);
}

pub fn goLine(v: *View, line: u32) void {
    v.buf.cursor = code.lineOffset(v.buf.str(), line);
    follow(v);
}

/// The quick list beside the code: the Reference's articles (refdata) of the file's
/// kind — the functions the engine runs, or in a rules file its calls (those the file
/// makes) — matching the call or word at the cursor; a click puts one in at the cursor,
/// its link opens its Reference article.
fn helpColumn(app: *App, a: Allocator, v: *View) void {
    const t = v.buf.str();
    const rules_file = rulesFile(app, v);
    const kind: refdata.Kind = if (rules_file) .rules else .builtin;
    const at_call = if (rules_file) (if (rulesAt(t, v.buf.cursor)) |r| r.call.name else null) else if (code.callAt(t, v.buf.cursor)) |cp| cp.name else null;
    const filter = at_call orelse v.buf.wordBefore();
    gui.sidePanel(app.sidePane(420.0 / 1680.0), .{ .id = clay.id("code_help_list"), .scroll = true, .pad = gui.pad(lay.space.md, lay.space.sm), .gap = lay.space.sm });
    const n = refdata.count(kind);
    gui.note(if (rules_file) tx.alloc(a, tx.code_rules_count, .{n}) else tx.alloc(a, tx.code_help_count, .{n}));
    var shown: usize = 0;
    for (0..n) |i| {
        const r: refdata.Article = .{ .kind = kind, .i = i };
        // OG Script calls a builtin by its package's name (`fighter::SetHp`); some it lacks.
        const name = if (kind == .builtin) api.shown(&api.all[i], codecomplete.isOgs(app, v)) else refdata.nameOf(r);
        if (name.len == 0) continue;
        if (filter.len > 0) {
            if (std.ascii.findIgnoreCase(name, filter) == null) continue;
        } else if (rules_file) {
            var it = code.wordUses(t, name);
            if (it.next() == null) continue;
        }
        shown += 1;
        const insert = gui.clickable(app, .{
            .id = clay.idi(if (rules_file) "rules_api" else "api", @intCast(i)),
            .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xs, lay.space.xs), .childGap = lay.border.mark },
            .backgroundColor = theme.panel,
        }, false);
        gui.txt(name, .label, theme.text, font_mod.bold);
        if (rules_file) {
            const d = refdata.desc(r);
            gui.note(tx.get(d));
            const rc = &rulesapi.all[i];
            for (rc.fields) |*f| gui.txtWrap(fieldLine(a, rc, f), .caption, theme.text, font_mod.regular);
        } else {
            const f = &api.all[i];
            gui.txtWrap(signature(a, f), .caption, theme.accent_hover, font_mod.regular);
            var pb: [12]api.Param = undefined;
            for (api.params(f, &pb)) |p| gui.txtWrap(paramLine(a, p, codecomplete.isOgs(app, v)), .caption, theme.text, font_mod.regular);
            gui.note(fnDesc(a, f, codecomplete.isOgs(app, v)));
        }
        const to_ref = gui.link(app, clay.idi(if (rules_file) "rules_api_ref" else "api_ref", @intCast(i)), tx.get(tx.code_help_ref), theme.accent_hover, theme.text);
        clay.close();
        if (to_ref) {
            @import("reference.zig").open(app, r);
            break;
        } else if (insert) {
            v.buf.insertCall(name, if (rules_file) "" else api.sampleArgs(a, &api.all[i]) catch "") catch {};
            follow(v);
        }
    }
    if (shown == 0) gui.txt(tx.get(tx.code_help_none), .caption, theme.dim, font_mod.regular);
    clay.close();
}

/// `type name — what it is` of parameter `p` (`[…]` when it may be left out).
pub fn paramLine(a: Allocator, p: api.Param, ogs: bool) []const u8 {
    const decl = if (p.optional) std.fmt.allocPrint(a, "[{s}]", .{p.decl}) catch p.decl else p.decl;
    return docLine(a, decl, api.docText(a, tx.get(p.doc), ogs));
}

/// `w` is one of the view's unknown calls (or scene commands).
fn isUnknown(v: *const View, w: []const u8) bool {
    for (v.unknown[0..v.unknown_n]) |*u| if (u.kind == .call and std.ascii.eqlIgnoreCase(u.name[0..u.len], w)) return true;
    return false;
}
