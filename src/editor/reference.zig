//! The Reference (F1): the script functions the engine runs (api.zig, grouped by what
//! they act on), the callbacks it calls (callbacks.zig), the OpenGorky hooks
//! (trait Game, script/traits.zig), the rules calls and their fields (rulesapi.zig) and the engine
//! settings (adjustdoc.zig), the data block kinds' fields (foundation/hosts.ogs) as articles — the code editor's hints, read from the same
//! tables — each with real lines of the game that use it and links to its relatives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const data = @import("refdata.zig");
const api = data.api;
const callbacks = data.callbacks;
const rulesapi = data.rulesapi;
const codenav = @import("codenav.zig");
const codeview = @import("codeview.zig");
const doctabs = @import("doctabs.zig");
const assettree = @import("assettree.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

const hooks = data.hooks;
const Kind = data.Kind;
const Article = data.Article;
pub const find = data.find;
const nameOf = data.nameOf;
const desc = data.desc;
const ogOnly = data.ogOnly;
const matches = data.matches;
const count = data.count;
const groupOf = data.groupOf;
const groups = data.groups;
const sections = data.sections;
const pairs = data.pairs;
const cbs = data.cbs;
const og = @import("opengorky");
const completion = @import("completion.zig");
const stem = data.stem;

/// The page's state (`app.reference`): the article shown and the search.
pub const State = struct {
    sel: ?Article = null,
    filter: app_mod.Name(64) = .{},
};

/// The Reference shown on article `r` (none: as it was); the document shown before it
/// keeps its tab.
pub fn open(app: *App, r: ?Article) void {
    doctabs.openKept(app, .reference, "");
    if (r) |x| select(app, x);
}

fn select(app: *App, r: Article) void {
    app.reference.sel = r;
    assettree.reveal(app, sectionKey(r.kind));
    if (r.kind == .builtin) if (groupOf(nameOf(r))) |g| assettree.reveal(app, groupKey(g));
}

/// F1 in the code on word `w`: its article; false when there is none.
pub fn openWord(app: *App, w: []const u8) bool {
    const r = find(w) orelse return false;
    open(app, r);
    return true;
}

fn sectionKey(k: Kind) []const u8 {
    return switch (k) {
        inline else => |t| "ref/" ++ @tagName(t),
    };
}

fn groupKey(g: usize) []const u8 {
    const keys = comptime blk: {
        var out: [groups.len][]const u8 = undefined;
        for (&out, 0..) |*o, k| o.* = std.fmt.comptimePrint("ref/g{d}", .{k});
        break :blk out;
    };
    return keys[g];
}

/// The search typed so far (it filters as it is typed).
fn query(app: *App) []const u8 {
    if (app.text_edit) |*e| if (e.id.id == clay.id("ref_search").id) return e.text();
    return app.reference.filter.get();
}

pub fn page(app: *App, a: Allocator) void {
    list(app, a);
    article(app, a);
}

// ---------------------------------------------------------------- the list

var row_n: u32 = 0;

/// Article `r` in the list: matching the search, and none of the port's own in a Classic
/// project (its scripts can't use them).
fn listed(app: *const App, r: Article, q: []const u8) bool {
    return (app.ogLayout() or !ogOnly(r)) and !(app.ogLayout() and ogsTwin(r)) and matches(r, q);
}

/// A builtin that shares its OG Script name with an earlier entry (one article in OG).
fn ogsTwin(r: Article) bool {
    return r.kind == .builtin and api.ogsTwin(&api.all[r.i]);
}

fn list(app: *App, a: Allocator) void {
    row_n = 0;
    const q = query(app);
    gui.sidePanel(app.sidePane(360.0 / 1680.0), .{ .edge = .right, .pad = gui.pad(lay.space.sm, lay.space.sm), .gap = lay.space.sm });
    gui.row(lay.space.sm);
    gui.icon(app, .search, lay.icon.md, theme.dim);
    if (gui.textField(app, "ref_search", app.reference.filter.get(), 0, tx.get(tx.ref_search))) |s| app.reference.filter.set(s);
    if (q.len > 0 and gui.toolButton(app, "ref_clear", .x, "", false, false)) {
        app.reference.filter.set("");
        app.text_edit = null;
    }
    clay.close();
    var found: usize = 0;
    if (q.len > 0) {
        for (sections) |s| for (0..count(s[0])) |i| {
            found += @intFromBool(listed(app, .{ .kind = s[0], .i = i }, q));
        };
        gui.note(if (found == 0) tx.get(tx.ref_nothing) else tx.alloc(a, tx.ref_found, .{found}));
    }
    clay.openScroll(.{ .id = clay.id("ref_list"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (sections) |s| {
        var n: usize = 0;
        for (0..count(s[0])) |i| n += @intFromBool(listed(app, .{ .kind = s[0], .i = i }, q));
        if (n == 0) continue;
        if (!folder(app, a, sectionKey(s[0]), 0, tx.get(s[1]), n, q)) continue;
        if (s[0] != .builtin) {
            for (0..count(s[0])) |i| leaf(app, .{ .kind = s[0], .i = i }, 1, q);
            continue;
        }
        for (groups, 0..) |g, gi| {
            var gn: usize = 0;
            for (&api.all, 0..) |*f, i| gn += @intFromBool(groupOf(f.name) == gi and listed(app, .{ .kind = .builtin, .i = i }, q));
            if (gn == 0 or !folder(app, a, groupKey(gi), 1, tx.get(g.title), gn, q)) continue;
            for (&api.all, 0..) |*f, i| if (groupOf(f.name) == gi) leaf(app, .{ .kind = .builtin, .i = i }, 2, q);
        }
    }
    clay.close();
    clay.close();
}

/// A section's (or a group's) row; true while open (a search opens every one).
fn folder(app: *App, a: Allocator, key: []const u8, depth: u32, title: []const u8, n: usize, q: []const u8) bool {
    row_n += 1;
    const is_open = q.len > 0 or app.tree_open.contains(key);
    const hit = gui.folderRow(app, clay.idi("ref_row", row_n), depth, is_open, .folder, false, title, depth == 0, n, a);
    clay.close();
    if (hit and q.len == 0) assettree.toggleKey(app, key);
    return is_open;
}

fn leaf(app: *App, r: Article, depth: u32, q: []const u8) void {
    if (!listed(app, r, q)) return;
    row_n += 1;
    const sel = if (app.reference.sel) |s| std.meta.eql(s, r) else false;
    if (gui.listRow(app, clay.idi("ref_row", row_n), .{ .selected = sel, .indent = gui.leafIndent(depth) })) app.reference.sel = r;
    gui.openClip(lay.space.sm);
    gui.txt(label(app, r), .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
    clay.close();
    clay.close();
}

// ---------------------------------------------------------------- the article

const page_pad = lay.space.xl;

fn article(app: *App, a: Allocator) void {
    const pid = clay.id("ref_article");
    clay.openScroll(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(page_pad, lay.space.lg), .childGap = lay.space.md }, .backgroundColor = theme.bg });
    defer clay.close();
    const r = app.reference.sel orelse {
        gui.pageHeader(app, .search, tx.get(tx.ref_title), tx.get(tx.ref_hint));
        clay.close();
        return gui.note(tx.get(tx.ref_pick));
    };
    const d = desc(r);
    gui.headCard();
    gui.row(lay.space.sm);
    gui.txt(label(app, r), .heading, theme.text, font_mod.bold);
    gui.chip(tx.get(sections[@backingInt(r.kind)][1]));
    clay.close();
    gui.txtWrap(declaration(a, r, label(app, r)), .body, theme.accent_hover, font_mod.regular);
    // A builtin: the other language's name for it.
    if (r.kind == .builtin) {
        const o = api.ogsName(&api.all[r.i]);
        const other = if (!app.ogLayout()) (if (o.len > 0) tx.alloc(a, tx.ref_ogs_name, .{o}) else tx.get(tx.ref_ogs_none)) else if (!std.mem.eql(u8, o, nameOf(r))) tx.alloc(a, tx.ref_classic_name, .{if (o.len > 0) api.classicNames(a, o) else nameOf(r)}) else "";
        if (other.len > 0) gui.txtWrap(other, .caption, theme.dim, font_mod.regular);
    }
    gui.txtWrap(if (r.kind == .builtin) api.docText(a, tx.get(d), app.ogLayout()) else tx.get(d), .body, theme.text, font_mod.regular);
    gui.blockEnd();
    switch (r.kind) {
        .builtin, .callback, .hook => params(app, a, r),
        .rules => fields(app, a, &rulesapi.all[r.i]),
        .block => blockFields(app, a, nameOf(r)),
        .setting => setting(app, a, r),
    }
    if (r.kind == .hook) {
        _ = gui.block(app, null, tx.get(tx.ref_hook_how), .{});
        gui.txtWrap(tx.get(tx.ref_hook_order), .body, theme.text, font_mod.regular);
        gui.blockEnd();
    }
    examples(app, a, r);
    related(app, a, r);
}

/// A builtin as the project's scripts call it: OG Script's name (`fighter::SetHp`) in an
/// OpenGorky project (the exe's where it has none), else the exe's; any other article's name.
fn label(app: *const App, r: Article) []const u8 {
    if (r.kind == .builtin and app.ogLayout()) {
        const o = api.ogsName(&api.all[r.i]);
        if (o.len > 0) return o;
    }
    return nameOf(r);
}

/// How a script writes it (`name`: `label`): the call, the function a script defines, the rules row.
fn declaration(a: Allocator, r: Article, name: []const u8) []const u8 {
    return switch (r.kind) {
        .builtin => std.fmt.allocPrint(a, "{s}{s}", .{ name, codeview.signature(a, &api.all[r.i]) }) catch "",
        .callback => fnDecl(a, nameOf(r), cbs[r.i].params),
        .hook => std.fmt.allocPrint(a, "function {s}({s})", .{ nameOf(r), hooks()[r.i].params }) catch "",
        .rules => blk: {
            const c = &rulesapi.all[r.i];
            var out: std.ArrayList(u8) = .empty;
            out.print(a, "{s}(", .{c.name}) catch {};
            for (c.fields, 0..) |f, k| out.print(a, "{s}{s} = …", .{ if (k > 0) ", " else "", f.name }) catch {};
            out.append(a, ')') catch {};
            break :blk out.items;
        },
        .block => blk: {
            const h = (og.core.schema.blockHost(nameOf(r)) orelse break :blk "").name;
            const parent = if (og.script.hosts.host(h)) |x| x.parent else "";
            break :blk std.fmt.allocPrint(a, "{s} name {{ field = …; }}   · host {s}{s}{s}", .{ nameOf(r), h, if (parent.len > 0) " : " else "", parent }) catch "";
        },
        .setting => std.fmt.allocPrint(a, "Setting(name = \"{s}\", int | float | rgba = …)", .{nameOf(r)}) catch "",
    };
}

fn fnDecl(a: Allocator, n: []const u8, ps: []const callbacks.Param) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "function {s}(", .{n}) catch {};
    for (ps, 0..) |p, k| out.print(a, "{s}{s}", .{ if (k > 0) ", " else "", p.decl }) catch {};
    out.append(a, ')') catch {};
    return out.items;
}

/// Name, type, default, meaning (wrapped) columns.
fn table() gui.Table {
    const t = gui.Table.open(clay.id("ref_article"), 2 * page_pad + 2 * lay.block.pad_x, &.{ col(16), col(18), col(12), .{ .minmax = .{ .min = .{ .pt = 20 * lay.unit }, .max = .{ .pct = 1 } } } });
    t.head(&.{ tx.get(tx.ref_c_name), tx.get(tx.ref_c_type), tx.get(tx.ref_c_default), tx.get(tx.ref_c_meaning) });
    return t;
}

fn col(n: f32) lay.Track {
    return .{ .len = .{ .pt = n * lay.unit } };
}

/// A row of `table`: its cells' text wrapped; the meaning cell left open for more lines.
fn rowOpen(t: *const gui.Table, cells: [3][]const u8, meaning: []const u8) void {
    gui.Table.lineWrap();
    for (cells, 0..) |s, k| {
        t.cell(k);
        gui.txtWrap(s, .body, if (k == 0) theme.text else theme.dim, if (k == 0) font_mod.bold else font_mod.regular);
        clay.close();
    }
    t.cell(3);
    gui.stack(lay.space.xs);
    gui.txtWrap(meaning, .body, theme.text, font_mod.regular);
}

fn rowClose() void {
    clay.close();
    clay.close();
    clay.close();
}

/// `int x` → type, name.
fn splitDecl(decl: []const u8) [2][]const u8 {
    const sp = std.mem.lastIndexOfScalar(u8, decl, ' ') orelse return .{ "", decl };
    return .{ decl[0..sp], decl[sp + 1 ..] };
}

fn params(app: *App, a: Allocator, r: Article) void {
    _ = gui.block(app, null, tx.get(tx.ref_params), .{});
    defer gui.blockEnd();
    var pb: [12]api.Param = undefined;
    var cb: [8]callbacks.Param = undefined;
    const n = switch (r.kind) {
        .builtin => api.params(&api.all[r.i], &pb).len,
        .callback => cbs[r.i].params.len,
        else => (callbacks.hook(&cb, nameOf(r)) orelse return).params.len,
    };
    if (n == 0) return gui.note(tx.get(tx.ref_no_params));
    const t = table();
    for (0..n) |k| {
        if (r.kind == .builtin) {
            const p = pb[k];
            const td = splitDecl(p.decl);
            rowOpen(&t, .{ td[1], td[0], tx.get(if (p.optional) tx.ref_optional else tx.ref_required) }, api.docText(a, tx.get(p.doc), app.ogLayout()));
            gui.txtWrap(tx.alloc(a, tx.ref_sample, .{p.sample}), .caption, theme.dim, font_mod.regular);
        } else {
            const p = if (r.kind == .callback) cbs[r.i].params[k] else cb[k];
            const td = splitDecl(p.decl);
            rowOpen(&t, .{ td[1], td[0], "—" }, tx.get(p.doc));
        }
        rowClose();
    }
    clay.close();
}

fn fields(app: *App, a: Allocator, c: *const rulesapi.Call) void {
    _ = gui.block(app, null, tx.get(tx.ref_fields), .{});
    defer gui.blockEnd();
    if (c.fields.len == 0) return gui.note(tx.get(tx.ref_no_params));
    const t = table();
    for (c.fields) |*f| {
        const sh = rulesapi.shape(a, c.name, f.name);
        const def = if (sh.default.len > 0) sh.default else tx.get(if (sh.optional) tx.ref_optional else tx.ref_required);
        // A word field's words are listed under its meaning (its type would be cut).
        rowOpen(&t, .{ f.name, if (f.words.len > 0) "\"word\"" else sh.ty, def }, tx.get(f.doc));
        for (f.words) |w| gui.txtWrap(std.fmt.allocPrint(a, "\"{s}\" — {s}", .{ w.name, tx.get(w.doc) }) catch "", .caption, theme.dim, font_mod.regular);
        rowClose();
    }
    clay.close();
}

/// Every field of block kind `kind`: its host's, then its parents' (marked whose), an
/// enum's values under its meaning.
fn blockFields(app: *App, a: Allocator, kind: []const u8) void {
    _ = gui.block(app, null, tx.get(tx.ref_fields), .{});
    defer gui.blockEnd();
    const sh = og.core.schema.blockHost(kind) orelse return gui.note(tx.get(tx.ref_no_params));
    const t = table();
    var h = og.script.hosts.host(sh.name);
    var depth: u32 = 0;
    while (h) |x| : (h = if (x.parent.len > 0) og.script.hosts.host(x.parent) else null) {
        depth += 1;
        if (depth > 16) break;
        for (x.fields) |*f| {
            var def: std.Io.Writer.Allocating = .init(a);
            if (f.default) |d| og.script.ogs.print.expression(&def.writer, d) catch {};
            rowOpen(&t, .{ f.name, f.type_name, def.written() }, f.doc);
            if (depth > 1) gui.txtWrap(tx.alloc(a, tx.ref_block_from, .{x.name}), .caption, theme.dim, font_mod.regular);
            if (completion.preludeEnum(elemType(f.type_name))) |e| for (e.values) |v|
                gui.txtWrap(if (v.label.len > 0) std.fmt.allocPrint(a, "{s} — {s}", .{ v.name, v.label }) catch "" else v.name, .caption, theme.dim, font_mod.regular);
            rowClose();
        }
    }
    clay.close();
}

/// `list<T>` → `T`; any other type as it is.
fn elemType(t: []const u8) []const u8 {
    if (std.mem.startsWith(u8, t, "list<") and std.mem.endsWith(u8, t, ">")) return t[5 .. t.len - 1];
    return t;
}

fn setting(app: *App, a: Allocator, r: Article) void {
    _ = gui.block(app, null, tx.get(tx.ref_setting_forms), .{});
    defer gui.blockEnd();
    // The project's own form only (an OpenGorky one has no adjust.kdt).
    gui.txtWrap(tx.get(if (app.ogLayout()) tx.ref_setting_og else tx.ref_setting_classic), .body, theme.text, font_mod.regular);
    if (@import("adjustpage.zig").find(app, a, nameOf(r))) |p| gui.txtWrap(tx.alloc(a, tx.ref_setting_now, .{ p.kind, p.value }), .body, theme.accent_hover, font_mod.regular);
    if (gui.footer(app, "ref_setting_open", &.{tx.get(tx.ref_setting_open)}, null) != null) {
        app.adjust.sel.set(nameOf(r));
        doctabs.openKept(app, .adjust, "");
    }
}

// ---------------------------------------------------------------- examples, links

const examples_max = 8;
var ex_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var ex_for: ?Article = null;
var ex_uses: []const codenav.Use = &.{};

fn examples(app: *App, a: Allocator, r: Article) void {
    // Read once per article (every script and rules file of the game is searched).
    if (ex_for == null or !std.meta.eql(ex_for.?, r)) {
        _ = ex_arena.reset(.retain_capacity);
        ex_uses = codenav.collect(app, ex_arena.allocator(), nameOf(r), examples_max);
        ex_for = r;
    }
    _ = gui.block(app, null, tx.get(tx.ref_examples), .{ .summary = std.fmt.allocPrint(a, "{d}", .{ex_uses.len}) catch "" });
    defer gui.blockEnd();
    if (ex_uses.len == 0) return gui.note(tx.get(tx.ref_examples_none));
    gui.note(tx.get(tx.ref_examples_note));
    for (ex_uses, 0..) |u, k| {
        if (gui.listRow(app, clay.idi("ref_ex", @intCast(k)), .{ .fit = true })) {
            codenav.go(app, .{ .label = u.entry, .to = .{ .code = .{ .archive = u.archive, .entry = u.entry, .at = u.at } } });
        }
        gui.txt(std.fmt.allocPrint(a, "{s}:{d}", .{ u.entry, u.line }) catch "", .caption, theme.accent_hover, font_mod.regular);
        gui.openClip(0);
        gui.txt(u.text, .caption, theme.text, font_mod.regular);
        clay.close();
        clay.close();
    }
}

/// Siblings by name (`Actor_…`, `Item…`), the pairs, hooks ↔ the port's own builtins.
fn related(app: *App, a: Allocator, r: Article) void {
    var out: std.ArrayList(Article) = .empty;
    const n = nameOf(r);
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(Article), x: ?Article, self: Article) void {
            const v = x orelse return;
            if (std.meta.eql(v, self)) return;
            for (o.items) |y| if (std.meta.eql(y, v)) return;
            o.append(al, v) catch {};
        }
    }.f;
    for (pairs) |p| for (p, 0..) |s, k| if (std.ascii.eqlIgnoreCase(s, n)) add(a, &out, find(p[1 - k]), r);
    if (r.kind == .hook) {
        add(a, &out, find("GetLevel"), r);
        add(a, &out, find("GetClass"), r);
    }
    // A block kind: the kinds on the same host and on its parents' (`hero` ↔ `fighter`, `actor`).
    if (r.kind == .block) if (og.core.schema.blockHost(n)) |sh| for (data.blocks(), 0..) |k, i| {
        const kh = (og.core.schema.blockHost(k) orelse continue).name;
        var at = og.script.hosts.host(sh.name);
        while (at) |x| : (at = if (x.parent.len > 0) og.script.hosts.host(x.parent) else null) if (std.mem.eql(u8, x.name, kh)) {
            add(a, &out, .{ .kind = .block, .i = i }, r);
            break;
        };
    };
    if (r.kind == .builtin and ogOnly(r)) for (0..hooks().len) |i| add(a, &out, .{ .kind = .hook, .i = i }, r);
    if (r.kind == .builtin or r.kind == .setting) {
        const pre = stem(n);
        for (0..count(r.kind)) |i| {
            if (out.items.len >= 16) break;
            const m = nameOf(.{ .kind = r.kind, .i = i });
            if (pre.len > 0 and std.mem.startsWith(u8, m, pre)) add(a, &out, .{ .kind = r.kind, .i = i }, r);
        }
    }
    // What the list shows: Classic none of the port's own, OG one article per OG Script name.
    var j: usize = 0;
    for (out.items) |x| if (listed(app, x, "")) {
        out.items[j] = x;
        j += 1;
    };
    out.items.len = j;
    if (out.items.len == 0) return;
    _ = gui.block(app, null, tx.get(tx.ref_related), .{});
    defer gui.blockEnd();
    for (out.items, 0..) |x, k| {
        if (gui.link(app, clay.idi("ref_rel", @intCast(k)), std.fmt.allocPrint(a, "{s} · {s}", .{ label(app, x), tx.get(sections[@backingInt(x.kind)][1]) }) catch "", theme.accent_hover, theme.text)) select(app, x);
    }
}
