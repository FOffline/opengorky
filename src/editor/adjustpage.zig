//! Engine settings: `adjust.kdt` in the game root — ~600 tuning values (`int`, `float`,
//! `rgba` lines: attacks, explosions, particles, monsters, menus, sound) the original
//! exe reads at start (0x418120), so an edit here works in the original too. Listed by
//! group (the name's first word; `attack_` by its second), searched, picked; the right
//! column edits the value (the line's text keeps the exe's form, "1.300000").
//! OpenGorky: the same values are the rules' Setting rows (rules\adjust.ss, the port's
//! only source; the exe keeps reading adjust.kdt): an edit writes the row (rules_rows.
//! put). A project made before them reads its adjust.kdt still; "Move" writes them
//! into rules\adjust.ss (one undo step, saved into the history).

const std = @import("std");
const og = @import("opengorky");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const store = @import("store.zig");
const lines = @import("adjusttext.zig");
const Param = lines.Param;
const params = lines.params;
const group = lines.group;
const normalize = lines.normalize;
const doc = @import("adjustdoc.zig");
const limits = og.formats.adjust;
const rules_text = og.loaders.rules_text;
const rules_rows = @import("rules_rows.zig");
const entry_rules = @import("entry_rules.zig");
const Setting = og.rules.Setting;

/// The OpenGorky project's rules file of the values.
const og_entry = @import("rules_rows.zig").entryOf(Setting);

/// The page's state (`app.adjust`): the picked value and the search.
pub const State = struct {
    sel: app_mod.Name(64) = .{},
    filter: app_mod.Name(64) = .{},
    /// adjust.dat in the game folder (looked for once): the exe reads it instead (0x4181a0).
    dat: ?bool = null,
};

/// Value `p` of file `f` set to `v` (one undo step); OpenGorky: its Setting row.
fn set(app: *App, f: usize, p: Param, v: []const u8) void {
    if (app.ogLayout()) return setOg(app, p, v) catch |err| app.failed(err);
    const t = app.store.text(f);
    const out = std.mem.concat(app.gpa, u8, &.{ t[0..p.at], v, t[p.at + p.value.len ..] }) catch return;
    const label = std.fmt.allocPrint(app.frame.allocator(), "adjust.kdt: {s} = {s}", .{ p.name, v }) catch p.name;
    app.store.replaceLabeled(f, out, label) catch |err| {
        app.gpa.free(out);
        app.failed(err);
    };
}

/// Value `name` set to `v` as the page's field does (`--adjust NAME VALUE`).
pub fn setByName(app: *App, name: []const u8, v: []const u8) !void {
    const a = app.frame.allocator();
    const f = try source(app);
    const p = for (paramsOf(app, a, app.store.text(f))) |p| {
        if (std.mem.eql(u8, p.name, name)) break p;
    } else return error.NoSuchValue;
    set(app, f, p, normalize(a, p.kind, v) orelse return error.BadValue);
    app.adjust.sel.set(name);
}

/// Value `name` as the page has it (its type and value; the Reference's settings).
pub fn find(app: *App, a: Allocator, name: []const u8) ?Param {
    const f = source(app) catch return null;
    for (paramsOf(app, a, app.store.text(f))) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// OpenGorky: setting `p` made `v` (the exe's form): a field of the `settings` block
/// (rules/settings.ogs, made at the first) when it differs from the engine's default
/// (rules/adjust_defaults.zig), else taken out.
fn setOg(app: *App, p: Param, v: []const u8) !void {
    const a = app.frame.allocator();
    const mo = @import("model_og.zig");
    const d = defaultText(a, p.name) orelse return error.NoSuchValue;
    const existing = app.store.file(store.og_src, og_entry) catch null;
    if (std.mem.eql(u8, v, d)) {
        if (existing) |f| try mo.unset(app, f, &.{p.name});
        return app.setStatus(tx.st_camp_set, .{ p.name, v });
    }
    const f = existing orelse blk: {
        _ = try app.store.addNew(&.{.{ .archive = store.og_src, .entry = og_entry, .text = try app.gpa.dupe(u8, "settings engine {\n}\n") }});
        break :blk try app.store.file(store.og_src, og_entry);
    };
    // OG Script's forms: `8`, `1.3`, `[200, 60, 20]`.
    const text = if (std.mem.eql(u8, p.kind, "rgba")) try std.fmt.allocPrint(a, "[{s}]", .{try std.mem.replaceOwned(u8, a, v, ",", ", ")}) else if (std.mem.eql(u8, p.kind, "float")) try std.fmt.allocPrint(a, "{d}", .{std.fmt.parseFloat(f32, v) catch return error.BadValue}) else v;
    const shown_text = if (std.mem.eql(u8, p.kind, "float") and std.mem.indexOfScalar(u8, text, '.') == null) try std.fmt.allocPrint(a, "{s}.0", .{text}) else text;
    try mo.set(app, f, &.{p.name}, shown_text);
    app.setStatus(tx.st_camp_set, .{ p.name, shown_text });
}

/// Setting `name`'s engine default in the exe's form ("8", "1.300000", "200,60,20").
fn defaultText(a: Allocator, name: []const u8) ?[]const u8 {
    const d = og.rules.adjust.defaultOf(name) orelse return null;
    return valueText(a, d);
}

fn valueText(a: Allocator, d: og.rules.adjust.Value) ?[]const u8 {
    return switch (d) {
        .int => |x| std.fmt.allocPrint(a, "{d}", .{x}) catch null,
        .float => |x| std.fmt.allocPrint(a, "{d:.6}", .{x}) catch null,
        .rgba => |x| std.fmt.allocPrint(a, "{d},{d},{d}", .{ x[0], x[1], x[2] }) catch null,
    };
}

/// OpenGorky: every setting the engine reads (rules/adjust_defaults.zig), its value the
/// `settings` block's when set there, else its default.
fn ogParams(app: *App, a: Allocator) []const Param {
    const own: []const Param = if (app.store.file(store.og_src, og_entry)) |f| settingParams(a, app.store.text(f)) else |_| &.{};
    var out: std.ArrayList(Param) = .empty;
    for (og.rules.adjust.defaults) |d| {
        const kind: []const u8 = switch (d[1]) {
            .int => "int",
            .float => "float",
            .rgba => "rgba",
        };
        var v = valueText(a, d[1]) orelse continue;
        for (own) |p| if (std.mem.eql(u8, p.name, d[0])) {
            v = p.value;
        };
        out.append(a, .{ .kind = kind, .name = d[0], .value = v, .at = 0 }) catch {};
    }
    std.mem.sort(Param, out.items, {}, struct {
        fn lt(_: void, x: Param, y: Param) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
    return out.items;
}

/// The values' file: adjust.kdt, OpenGorky rules\adjust.ss.
fn source(app: *App) !usize {
    return if (app.ogLayout()) app.store.file(store.og_src, og_entry) else app.store.file(store.adjust_file, store.adjust_file);
}

fn paramsOf(app: *App, a: Allocator, text: []const u8) []const Param {
    return if (app.ogLayout()) settingParams(a, text) else params(a, text);
}

/// rules\adjust.ss's Setting rows as the page's values (the exe's forms; `at` unused).
fn settingParams(a: Allocator, text: []const u8) []const Param {
    var out: std.ArrayList(Param) = .empty;
    var diag: og.script.ogs.parser.Diagnostic = .{};
    for (og.loaders.codec.parseRows(a, text, &diag) orelse return &.{}) |e| {
        const ex = e.kind.call;
        if (!std.ascii.eqlIgnoreCase(ex.text, Setting.call)) continue;
        const r = og.loaders.codec.read(Setting, a, ex, null) catch continue;
        const p: Param = switch (r.value() orelse continue) {
            .int => |x| .{ .kind = "int", .name = r.name, .value = std.fmt.allocPrint(a, "{d}", .{x}) catch continue, .at = 0 },
            .float => |x| .{ .kind = "float", .name = r.name, .value = std.fmt.allocPrint(a, "{d:.6}", .{x}) catch continue, .at = 0 },
            .rgba => |x| .{ .kind = "rgba", .name = r.name, .value = std.fmt.allocPrint(a, "{d},{d},{d}", .{ x[0], x[1], x[2] }) catch continue, .at = 0 },
        };
        out.append(a, p) catch {};
    }
    // The `settings` block's fields that are settings (no Value's name, no exp_levels:
    // loaders/rules_text.zig settingsRows).
    const u = og.script.ogs.parser.parse(a, text, "settings.ogs", &diag) catch return out.items;
    for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "settings")) for (e.fields) |fd| {
        if (std.mem.eql(u8, fd.name, "exp_levels") or std.meta.stringToEnum(og.rules.Const, fd.name) != null) continue;
        const v = fd.value;
        const p: Param = if (og.core.schema.int(v)) |x|
            .{ .kind = "int", .name = fd.name, .value = std.fmt.allocPrint(a, "{d}", .{x}) catch continue, .at = 0 }
        else if (og.core.schema.number(v)) |x|
            .{ .kind = "float", .name = fd.name, .value = std.fmt.allocPrint(a, "{d:.6}", .{x}) catch continue, .at = 0 }
        else if (v.kind == .list and v.kind.list.len == 3)
            .{ .kind = "rgba", .name = fd.name, .value = std.fmt.allocPrint(a, "{d},{d},{d}", .{ og.core.schema.int(v.kind.list[0]) orelse 0, og.core.schema.int(v.kind.list[1]) orelse 0, og.core.schema.int(v.kind.list[2]) orelse 0 }) catch continue, .at = 0 }
        else
            continue;
        out.append(a, p) catch {};
    };
    return out.items;
}

/// The row of `name` with value `v` (`normalize`d, of `kind`).
fn settingOf(kind: []const u8, name: []const u8, v: []const u8) ?Setting {
    if (std.mem.eql(u8, kind, "int")) return .{ .name = name, .int = std.fmt.parseInt(i32, v, 10) catch return null };
    if (std.mem.eql(u8, kind, "float")) return .{ .name = name, .float = std.fmt.parseFloat(f32, v) catch return null };
    var c: [3]u8 = undefined;
    var it = std.mem.splitScalar(u8, v, ',');
    for (&c) |*ch| ch.* = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    return .{ .name = name, .rgba = c };
}

/// A project made before the Setting rows: the values the port reads (its adjust.kdt)
/// written into rules\adjust.ss (one undo step).
fn migrate(app: *App) !void {
    for (try rules_text.dumpTexts(app.frame.allocator())) |t| if (std.mem.eql(u8, t.name, rules_text.entry_dir ++ Setting.file ++ ".ss")) {
        _ = try app.store.addNew(&.{.{ .archive = store.og_src, .entry = og_entry, .text = try app.gpa.dupe(u8, t.data) }});
        return entry_rules.sync(app);
    };
}

pub fn page(app: *App, a: Allocator) void {
    const is_og = app.ogLayout();
    if (is_og) return ogPage(app, a);
    const f = source(app) catch {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.space.sm, .padding = .{ .left = lay.space.xl, .top = lay.space.lg, .right = lay.space.xl } } });
        gui.txtWrap(tx.get(if (is_og) tx.adj_migrate else tx.adj_none), .label, theme.warn, font_mod.regular);
        if (is_og and gui.footer(app, "adjust_migrate", &.{tx.get(tx.adj_migrate_do)}, null) != null) migrate(app) catch |err| app.failed(err);
        return clay.close();
    };
    const ps = paramsOf(app, a, app.store.text(f));
    const was = paramsOf(app, a, app.store.saved(f));
    var saved: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (was) |p| saved.put(a, p.name, p.value) catch {};
    const q = app.adjust.filter.get();
    clay.openScroll(.{ .id = clay.id("adjust_page"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.lg), .childGap = lay.space.xs } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.space.xs, .padding = .{ .bottom = lay.space.sm } } });
    gui.txt(tx.get(tx.adj_title), .heading, theme.text, font_mod.bold);
    gui.txtWrap(tx.get(if (is_og) tx.adj_hint_og else tx.adj_hint), .caption, theme.dim, font_mod.regular);
    // The exe's limits and its adjust.dat: Classic's file only.
    if (!is_og) {
        const n_lines = std.mem.count(u8, std.mem.trimEnd(u8, app.store.text(f), "\n"), "\n") + 1;
        const bad = if (limits.checkLimits(app.store.text(f))) |_| false else |_| true;
        gui.txtWrap(tx.alloc(a, tx.adj_limits, .{n_lines}), .caption, if (bad) theme.warn else theme.dim, font_mod.regular);
        if (app.adjust.dat == null) app.adjust.dat = if (app.store.dat.statFile(app.store.io, "../adjust.dat", .{})) |_| true else |_| false;
        if (app.adjust.dat.?) gui.txtWrap(tx.get(tx.adj_dat_warn), .caption, theme.warn, font_mod.regular);
    }
    gui.row(lay.space.sm);
    gui.icon(app, .search, lay.icon.md, theme.dim);
    if (gui.textField(app, "adjust_search", q, lay.width.slider, tx.get(tx.adj_search))) |s| app.adjust.filter.set(s);
    if (q.len > 0 and gui.toolButton(app, "adjust_clear", .x, "", false, false)) app.adjust.filter.set("");
    clay.close();
    clay.close();
    var last: []const u8 = "";
    for (ps, 0..) |p, k| {
        if (q.len > 0 and std.ascii.findIgnoreCase(p.name, q) == null) continue;
        const g = group(p.name);
        if (!std.mem.eql(u8, g, last)) {
            last = g;
            clay.open(.{ .layout = .{ .padding = .{ .top = lay.space.sm, .bottom = lay.space.xs } } });
            gui.txt(g, .caption, theme.dim, font_mod.bold);
            clay.close();
        }
        const sel = std.mem.eql(u8, app.adjust.sel.get(), p.name);
        const changed = if (saved.get(p.name)) |v| !std.mem.eql(u8, v, p.value) else true;
        if (gui.listRow(app, clay.idi("adj_row", @intCast(k)), .{ .selected = sel })) app.adjust.sel.set(p.name);
        gui.txt(p.name, .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.spacer();
        if (doc.get(p.name) == null) gui.txt(tx.get(tx.adj_exe_only), .caption, theme.dim, font_mod.regular);
        if (changed) gui.txt(tx.get(tx.adj_changed), .caption, theme.warn, font_mod.regular);
        gui.txt(p.value, .body, if (changed) theme.warn else theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    props(app, a, f, ps, &saved);
}

/// OpenGorky: the engine's settings, a changed one (not its default) marked; the picked
/// one edited in `props` (its default the value it goes back to).
fn ogPage(app: *App, a: Allocator) void {
    const ps = ogParams(app, a);
    var defaults: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (og.rules.adjust.defaults) |d| defaults.put(a, d[0], valueText(a, d[1]) orelse continue) catch {};
    const q = app.adjust.filter.get();
    clay.openScroll(.{ .id = clay.id("adjust_page"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.lg), .childGap = lay.space.xs } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.space.xs, .padding = .{ .bottom = lay.space.sm } } });
    gui.txt(tx.get(tx.adj_title), .heading, theme.text, font_mod.bold);
    gui.txtWrap(tx.get(tx.adj_hint_og), .caption, theme.dim, font_mod.regular);
    gui.row(lay.space.sm);
    gui.icon(app, .search, lay.icon.md, theme.dim);
    if (gui.textField(app, "adjust_search", q, lay.width.slider, tx.get(tx.adj_search))) |s0| app.adjust.filter.set(s0);
    if (q.len > 0 and gui.toolButton(app, "adjust_clear", .x, "", false, false)) app.adjust.filter.set("");
    clay.close();
    clay.close();
    var last: []const u8 = "";
    for (ps, 0..) |p, k| {
        if (q.len > 0 and std.ascii.findIgnoreCase(p.name, q) == null) continue;
        const g = group(p.name);
        if (!std.mem.eql(u8, g, last)) {
            last = g;
            clay.open(.{ .layout = .{ .padding = .{ .top = lay.space.sm, .bottom = lay.space.xs } } });
            gui.txt(g, .caption, theme.dim, font_mod.bold);
            clay.close();
        }
        const sel = std.mem.eql(u8, app.adjust.sel.get(), p.name);
        const changed = if (defaults.get(p.name)) |v| !std.mem.eql(u8, v, p.value) else false;
        if (gui.listRow(app, clay.idi("adj_row", @intCast(k)), .{ .selected = sel })) app.adjust.sel.set(p.name);
        gui.txt(p.name, .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.spacer();
        if (doc.get(p.name)) |m| gui.txtClip(tx.get(m), .caption, theme.dim, font_mod.regular);
        if (changed) gui.txt(tx.get(tx.adj_changed), .caption, theme.warn, font_mod.regular);
        gui.txt(p.value, .body, if (changed) theme.warn else theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    props(app, a, 0, ps, &defaults);
}

/// The picked value: its type, the value typed anew, the saved one, back to it.
fn props(app: *App, a: Allocator, f: usize, ps: []const Param, saved: *const std.StringHashMapUnmanaged([]const u8)) void {
    // Nothing picked: no panel.
    const p = for (ps) |p| {
        if (std.mem.eql(u8, p.name, app.adjust.sel.get())) break p;
    } else return;
    gui.propsPanel(app, "adjust_props");
    defer gui.propsEnd();
    gui.groupTitle(tx.get(tx.props), true);
    gui.propRow(tx.get(tx.p_name), p.name);
    gui.propRow(tx.get(tx.adj_type), p.kind);
    gui.propRow(tx.get(tx.adj_about), if (doc.get(p.name)) |m| tx.get(m) else tx.get(tx.adj_not_port));
    gui.fieldRow(tx.get(tx.adj_value));
    if (gui.textField(app, "adjust_value", p.value, 0, "")) |v| {
        if (normalize(a, p.kind, v)) |nv| {
            if (!std.mem.eql(u8, nv, p.value)) set(app, f, p, nv);
        } else app.setStatus(tx.st_adj_bad, .{ v, p.kind });
    }
    clay.close();
    // A colour: its swatch.
    if (std.mem.eql(u8, p.kind, "rgba")) {
        var c: [3]f32 = .{ 0, 0, 0 };
        var it = std.mem.splitScalar(u8, p.value, ',');
        for (&c) |*ch| ch.* = @floatFromInt(std.fmt.parseInt(u8, std.mem.trim(u8, it.next() orelse "0", " "), 10) catch 0);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(2 * lay.height.small), .height = clay.fixed(lay.height.small) } }, .backgroundColor = .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 }, .cornerRadius = clay.radius(lay.radius.sm) });
    }
    const was = saved.get(p.name) orelse "";
    gui.propRow(tx.get(if (app.ogLayout()) tx.adj_default else tx.adj_saved), was);
    if (!std.mem.eql(u8, was, p.value) and was.len > 0 and gui.footer(app, "adjust_reset", &.{tx.get(tx.adj_reset)}, null) != null) set(app, f, p, was);
    gui.note(tx.get(if (app.ogLayout()) tx.adj_note_og else tx.adj_note));
}
