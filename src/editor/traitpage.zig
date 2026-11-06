//! The trait page and the component page. A trait:
//! its kind, supertraits, methods (a script trait's required ones and default bodies; a
//! built-in's signature, when, its rule, what the engine does without an answer, its
//! Classic function) and who implements it (native and scripted components), a built-in
//! one with its text in engine.ogs. A component of the project's code: `Name · for host ·
//! implements T`, its params, its method rows — its own, the defaults it takes (dim, from
//! their trait, "Override") and the required ones it lacks (red, "Stub",
//! "Implement T"), an engine event with its rule and when —, the characters having it.
//! A native one (core/natives.zig): what it implements. Both read only but for the stubs
//! (code is edited in the code editor, attaching on the character's page).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const doctabs = @import("doctabs.zig");
const codeview = @import("codeview.zig");
const code = @import("code.zig");
const ti = @import("traitinfo.zig");
const og = @import("opengorky");
const traits = og.script.traits;
const rules_text = og.loaders.rules_text;
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

/// A page's scroll column and its header row (left open for its actions).
fn head(app: *App, comptime id: []const u8, ic: @import("icons.zig").Icon, title: []const u8, hint: []const u8) void {
    clay.openScrollColumn(.{ .id = clay.id(id), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.md), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.pageHeader(app, ic, title, hint);
}

fn form(comptime id: []const u8) void {
    gui.form(clay.id(id), lay.width.label_md, lay.space.xl + lay.block.pad_x);
}

/// `name(a, b)`.
fn sig(a: Allocator, name: []const u8, params: []const []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}({s})", .{ name, std.mem.join(a, ", ", params) catch "" }) catch name;
}

fn engineSig(a: Allocator, m: traits.Method) []const u8 {
    return std.fmt.allocPrint(a, "{s}({s})", .{ m.name, m.params }) catch m.name;
}

/// Its kind as a chip's text.
fn kindLabel(a: Allocator, t: *const traits.Trait) []const u8 {
    return switch (t.kind) {
        .host => tx.alloc(a, tx.tr_kind_host, .{t.host.?}),
        .role => tx.get(tx.tr_kind_role),
        .mark => tx.get(tx.tr_kind_mark),
    };
}

fn list(a: Allocator, names: []const []const u8) []const u8 {
    return std.mem.join(a, ", ", names) catch "";
}

/// File `entry` of the rules archive shown in the code editor at line `line`.
fn openCode(app: *App, entry: []const u8, line: u32) void {
    const f = app.store.file(@import("store.zig").og_src, entry) catch |err| return app.failed(err);
    doctabs.showCode(app, f, code.lineOffset(app.store.text(f), line));
}

// ---------------------------------------------------------------- the trait page

pub fn traitPage(app: *App, a: Allocator) void {
    const key = app.trait_sel.get();
    const p = ti.load(a);
    const ref: ?ti.Ref = if (p.trait(key)) |t| .{ .script = t } else if (traits.find(ti.engineName(key) orelse key)) |t| .{ .engine = t } else null;
    const hint = if (ref) |r| switch (r) {
        .engine => |t| tx.alloc(a, tx.tr_hint_builtin, .{switch (tx.lang) {
            .en => t.doc.en,
            .ru => t.doc.ru,
        }}),
        .script => |t| tx.alloc(a, tx.tr_hint_script, .{ t.file, t.it.line }),
    } else tx.alloc(a, tx.tr_missing, .{key});
    head(app, "trait_page", .layers, key, hint);
    if (ref) |r| if (r == .script and gui.smallButton(app, clay.id("tr_code"), tx.get(tx.tr_open_code))) openCode(app, r.script.file, r.script.it.line);
    clay.close();
    form("trait_page");
    defer clay.closeScrollColumn();
    const r = ref orelse return;
    // Its kind and supertraits.
    gui.row(lay.space.sm);
    switch (r) {
        .engine => |t| {
            gui.chip(tx.get(tx.tr_builtin));
            gui.chip(kindLabel(a, t));
        },
        .script => gui.chip(tx.get(tx.tr_project)),
    }
    const sups = p.supers(a, r);
    if (sups.len > 1) {
        const names = a.alloc([]const u8, sups.len - 1) catch return;
        for (sups[1..], names) |s, *n| n.* = s.name();
        gui.txt(tx.alloc(a, tx.tr_supers, .{list(a, names)}), .caption, theme.dim, font_mod.regular);
    }
    clay.close();
    methodsBlock(app, a, r);
    whoBlock(app, a, &p, r);
    if (r == .engine) preludeBlock(app, a, r.engine);
}

fn methodsBlock(app: *App, a: Allocator, r: ti.Ref) void {
    const n = switch (r) {
        .engine => |t| t.methods.len,
        .script => |t| t.it.methods.len,
    };
    if (n == 0) return;
    if (!gui.block(app, "tr_methods", tx.get(tx.tr_methods), .{ .summary = std.fmt.allocPrint(a, "{d}", .{n}) catch "" })) return;
    defer gui.blockEnd();
    switch (r) {
        .script => |t| for (t.it.methods, 0..) |m, k| {
            gui.fieldRow(sig(a, m.f.name, paramsOf(a, m.f)));
            if (m.body) gui.chip(tx.get(tx.tr_has_default)) else gui.chipOf(tx.get(tx.tr_required), theme.removed, theme.removed);
            gui.spacer();
            if (gui.goButton(app, clay.idi("tr_m_go", @intCast(k)))) openCode(app, t.file, m.f.line);
            clay.close();
        },
        .engine => |t| for (t.methods) |m| {
            gui.fieldRow(engineSig(a, m));
            if (m.native) gui.chip(tx.get(tx.tr_engine_method)) else gui.chip(tx.alloc(a, tx.tr_rule, .{tx.get(m.combine.label())}));
            if (!m.live) gui.chipOf(tx.get(tx.tr_not_live), theme.warn, theme.warn);
            clay.close();
            gui.fieldNote(tx.alloc(a, tx.tr_when, .{tx.get(m.when)}), theme.dim);
            if (m.default) |d| gui.fieldNote(tx.alloc(a, tx.tr_no_answer, .{tx.get(d)}), theme.dim);
            var cl: std.ArrayList([]const u8) = .empty;
            for (traits.classic) |c| if (std.mem.eql(u8, c.method, m.name)) cl.append(a, c.name) catch {};
            if (cl.items.len > 0 and t.kind == .host) gui.fieldNote(tx.alloc(a, tx.tr_classic, .{list(a, cl.items)}), theme.dim);
        },
    }
}

fn paramsOf(a: Allocator, f: *const og.script.ir.Fn) []const []const u8 {
    const out = a.alloc([]const u8, f.params.len) catch return &.{};
    for (f.params, out) |pr, *o| o.* = pr.name;
    return out;
}

/// Who implements it: the native components (a built-in), the project's components.
fn whoBlock(app: *App, a: Allocator, p: *const ti.Project, r: ti.Ref) void {
    const natives = if (r == .engine) ti.nativesOf(a, r.engine) else &.{};
    const comps = p.implementers(a, r);
    if (!gui.block(app, "tr_who", tx.get(tx.tr_who), .{ .summary = std.fmt.allocPrint(a, "{d}", .{natives.len + comps.len}) catch "" })) return;
    defer gui.blockEnd();
    if (natives.len + comps.len == 0) gui.note(tx.get(tx.tr_who_none));
    for (comps, 0..) |c, k| {
        gui.fieldRow(c.path);
        gui.chip(c.file);
        gui.spacer();
        if (gui.goButton(app, clay.idi("tr_who_c", @intCast(k)))) doctabs.show(app, .components, c.path);
        clay.close();
    }
    for (natives, 0..) |n, k| {
        gui.fieldRow(n);
        gui.chip(tx.get(tx.tr_native));
        gui.spacer();
        if (gui.goButton(app, clay.idi("tr_who_n", @intCast(k)))) doctabs.show(app, .components, n);
        clay.close();
    }
}

/// A built-in trait's text in the prelude (engine.ogs: foundation/traits.ogs), as the
/// linker reads it: its comment lines, its header (`role trait Hero : Fighter`), its docs
/// and its body.
fn preludeBlock(app: *App, a: Allocator, t: *const traits.Trait) void {
    const text = traits.prelude;
    const at = headerAt(a, text, t.name) orelse return;
    var start = at;
    while (start > 0 and std.mem.lastIndexOfScalar(u8, text[0 .. start - 1], '\n') != null) {
        const prev = std.mem.lastIndexOfScalar(u8, text[0 .. start - 1], '\n').?;
        if (!std.mem.startsWith(u8, text[prev + 1 ..], "//")) break;
        start = prev + 1;
    }
    const close = std.mem.indexOfPos(u8, text, at, if (t.methods.len == 0) "{ }\n" else "\n}\n") orelse return;
    const end = close + 3;
    if (!gui.block(app, "tr_prelude", tx.get(tx.tr_prelude), .{ .folded = true })) return;
    defer gui.blockEnd();
    codeview.excerpt(a, text, start, end);
}

/// Where the line declaring built-in trait `name` starts in `text`.
fn headerAt(a: Allocator, text: []const u8, name: []const u8) ?usize {
    for ([_][]const u8{ "", "role ", "mark " }) |kind| for ([_][]const u8{ " ", "\n" }) |after| {
        const line = std.fmt.allocPrint(a, "\n{s}trait {s}{s}", .{ kind, name, after }) catch return null;
        if (std.mem.indexOf(u8, text, line)) |k| return k + 1;
    };
    return null;
}

// ---------------------------------------------------------------- the component page

pub fn compPage(app: *App, a: Allocator) void {
    const key = app.comp_sel.get();
    const p = ti.load(a);
    if (p.comp(key)) |c| return scriptComp(app, a, &p, c);
    if (ti.native(key)) |n| return nativeComp(app, a, n);
    head(app, "comp_page", .code, key, tx.alloc(a, tx.tr_missing, .{key}));
    clay.close();
    clay.closeScrollColumn();
}

/// `for fighter · implements Shielded` (`Shielded: Fighter` small after it).
fn compHeader(app: *App, a: Allocator, p: *const ti.Project, c: *const ti.SComp) void {
    gui.row(lay.space.sm);
    // No `for`: the host kind its traits give (`: Reflective`, Shielded: Fighter), if any.
    const kind: ?[]const u8 = for (p.closure(a, c)) |r| {
        if (r == .engine) if (r.engine.host) |h| break h;
    } else null;
    gui.chip(if (c.it.hosts.len > 0) tx.alloc(a, tx.cp_for, .{list(a, c.it.hosts)}) else if (kind) |k| tx.alloc(a, tx.cp_for, .{k}) else tx.get(tx.cp_any_host));
    if (c.it.traits.len > 0) gui.chip(tx.alloc(a, tx.cp_implements, .{list(a, c.it.traits)}));
    for (c.it.hosts) |h| if (traits.Role.of(h)) |role| gui.chipOf(tx.get(if (role == .hero) tx.ab_hero_only else tx.ab_enemy_only), theme.accent_hover, theme.accent);
    // The supertraits of what it names, small.
    var sup: std.ArrayList(u8) = .empty;
    for (c.it.traits) |n| {
        const sups = p.supers(a, p.resolve(a, c.it.module, c.uses, n) orelse continue);
        if (sups.len < 2) continue;
        sup.print(a, "{s}{s}", .{ if (sup.items.len > 0) "; " else "", sups[0].name() }) catch {};
        for (sups[1..], 0..) |s, k| sup.print(a, "{s}{s}", .{ if (k == 0) ": " else ", ", s.name() }) catch {};
    }
    if (sup.items.len > 0) gui.txt(sup.items, .caption, theme.dim, font_mod.regular);
    _ = app;
    clay.close();
}

fn scriptComp(app: *App, a: Allocator, p: *const ti.Project, c: *const ti.SComp) void {
    head(app, "comp_page", .code, c.path, tx.alloc(a, tx.cp_hint, .{ c.file, c.it.line }));
    if (gui.smallButton(app, clay.id("cp_code"), tx.get(tx.tr_open_code))) openCode(app, c.file, c.it.line);
    clay.close();
    form("comp_page");
    defer clay.closeScrollColumn();
    compHeader(app, a, p, c);
    const og_project = app.ogLayout();
    // Its traits: each a link to its page, "Implement T" while it lacks one's methods.
    const cl = p.closure(a, c);
    if (gui.block(app, "cp_traits", tx.get(tx.at_traits), .{ .summary = std.fmt.allocPrint(a, "{d}", .{cl.len}) catch "" })) {
        defer gui.blockEnd();
        for (cl, 0..) |r, k| {
            gui.fieldRow(r.name());
            gui.chip(switch (r) {
                .engine => |t| kindLabel(a, t),
                .script => tx.get(tx.tr_project),
            });
            gui.spacer();
            const stubs = if (r == .script) ti.missing(p, a, c, r) else &.{};
            if (og_project and stubs.len > 0 and gui.smallButton(app, clay.idi("cp_impl", @intCast(k)), tx.alloc(a, tx.cp_implement, .{r.name()}))) insert(app, c, stubs) catch |err| app.failed(err);
            if (gui.goButton(app, clay.idi("cp_tr_go", @intCast(k)))) doctabs.show(app, .traits, r.name());
            clay.close();
        }
    }
    paramsBlock(app, a, c);
    const rows = p.rows(a, c);
    if (gui.block(app, "cp_methods", tx.get(tx.tr_methods), .{ .summary = std.fmt.allocPrint(a, "{d}", .{rows.len}) catch "", .warn = for (rows) |r| {
        if (r.kind == .required) break true;
    } else false })) {
        defer gui.blockEnd();
        for (rows, 0..) |r, k| methodRow(app, a, c, r, @intCast(k), og_project);
    }
    usedBlock(app, a, c.path);
}

/// One method of the component: its own (› to its line), a default (dim, "Override")
/// or a required one it lacks (red, "Stub"); an engine event with its rule and when.
fn methodRow(app: *App, a: Allocator, c: *const ti.SComp, r: ti.Row, k: u32, og_project: bool) void {
    gui.fieldRow(sig(a, r.name, r.params));
    switch (r.kind) {
        .own => gui.chip(if (r.from) |f| tx.alloc(a, tx.cp_implements, .{f.name()}) else tx.get(tx.cp_own)),
        .default => gui.chipOf(tx.alloc(a, tx.cp_from, .{r.from.?.name()}), theme.dim, theme.button_edge),
        .required => gui.chipOf(tx.alloc(a, tx.cp_required_by, .{r.from.?.name()}), theme.removed, theme.removed),
    }
    if (r.event) |e| gui.chip(tx.alloc(a, tx.tr_rule, .{tx.get(e.combine.label())}));
    gui.spacer();
    switch (r.kind) {
        .own => if (gui.goButton(app, clay.idi("cp_m_go", k))) openCode(app, c.file, r.line),
        .default => if (og_project and gui.smallButton(app, clay.idi("cp_ovr", k), tx.get(tx.cp_override))) insert(app, c, &.{ti.stub(a, r.name, r.params, true)}) catch |err| app.failed(err),
        .required => if (og_project and gui.smallButton(app, clay.idi("cp_stub", k), tx.get(tx.cp_stub))) insert(app, c, &.{ti.stub(a, r.name, r.params, false)}) catch |err| app.failed(err),
    }
    clay.close();
    if (r.event) |e| gui.fieldNote(tx.alloc(a, tx.tr_when, .{tx.get(e.when)}), theme.dim);
}

/// Its params as declared: name, type, label (set where a character attaches it).
fn paramsBlock(app: *App, a: Allocator, c: *const ti.SComp) void {
    var n: usize = 0;
    for (c.it.fields) |f| n += @intFromBool(f.kind == .param);
    if (!gui.block(app, "cp_params", tx.get(tx.cp_params), .{ .summary = std.fmt.allocPrint(a, "{d}", .{n}) catch "" })) return;
    defer gui.blockEnd();
    if (n == 0) gui.note(tx.get(tx.cp_params_none));
    for (c.it.fields) |f| if (f.kind == .param) gui.propRow(if (f.type_name.len > 0) std.fmt.allocPrint(a, "{s} {s}", .{ f.type_name, f.name }) catch f.name else f.name, if (f.doc.len > 0) f.doc else "—");
}

/// The characters whose Abilities row attaches it (its `scripts`; a native: its part).
fn usedBlock(app: *App, a: Allocator, path: []const u8) void {
    var who: std.ArrayList([]const u8) = .empty;
    for (og.core.modules.tables().classes) |r| for (r.scripts) |s| if (std.mem.eql(u8, s.component, path)) {
        who.append(a, rowName(a, r)) catch {};
        break;
    };
    usedList(app, a, who.items);
}

fn usedList(app: *App, a: Allocator, who: []const []const u8) void {
    if (!gui.block(app, "cp_used", tx.get(tx.cp_used), .{ .summary = std.fmt.allocPrint(a, "{d}", .{who.len}) catch "" })) return;
    defer gui.blockEnd();
    if (who.len == 0) gui.note(tx.get(tx.cp_used_none));
    for (who) |w| gui.propRow(w, "");
}

/// An Abilities row's key as the rules write it.
fn rowName(a: Allocator, r: og.core.behaviour.Abilities) []const u8 {
    if (r.fighter_class.len > 0) return r.fighter_class;
    if (r.fighter != 0) return std.fmt.allocPrint(a, "classic_id {d}", .{r.fighter}) catch "";
    return std.fmt.allocPrint(a, "classType {d}", .{r.class}) catch "";
}

/// A native component: what it implements (each method with its when, a mark), where used.
fn nativeComp(app: *App, a: Allocator, n: *const og.script.object.Native) void {
    head(app, "comp_page", .settings, n.name, tx.get(tx.nc_hint));
    clay.close();
    form("comp_page");
    defer clay.closeScrollColumn();
    gui.row(lay.space.sm);
    gui.chip(tx.get(tx.tr_native));
    gui.chip(tx.alloc(a, tx.cp_for, .{"fighter"}));
    clay.close();
    const names = ti.nativeImplements(a, n);
    if (gui.block(app, "nc_impl", tx.get(tx.nc_implements), .{ .summary = std.fmt.allocPrint(a, "{d}", .{names.len}) catch "" })) {
        defer gui.blockEnd();
        for (names, 0..) |m, k| {
            gui.fieldRow(m);
            const owner = ownerOf(m);
            if (owner) |o| {
                if (o.kind == .mark) gui.chip(tx.get(tx.ab_mark)) else if (o.own(m)) |em| gui.chip(tx.alloc(a, tx.tr_rule, .{tx.get(em.combine.label())}));
            }
            gui.spacer();
            if (owner) |o| if (gui.goButton(app, clay.idi("nc_go", @intCast(k)))) doctabs.show(app, .traits, o.name);
            clay.close();
            if (owner) |o| if (o.own(m)) |em| gui.fieldNote(tx.alloc(a, tx.tr_when, .{tx.get(em.when)}), theme.dim) else gui.fieldNote(tx.get(o.doc), theme.dim);
        }
    }
    paramsNative(app, a, n);
    var who: std.ArrayList([]const u8) = .empty;
    for (og.core.modules.tables().classes) |*r| if (og.core.natives.has(r, og.core.natives.kindOf(n.tag))) who.append(a, rowName(a, r.*)) catch {};
    usedList(app, a, who.items);
}

/// Its params: its instance's object variables (core/natives.zig `params`).
fn paramsNative(app: *App, a: Allocator, n: *const og.script.object.Native) void {
    const ps = og.core.natives.params(og.core.natives.kindOf(n.tag));
    if (!gui.block(app, "cp_params", tx.get(tx.cp_params), .{ .summary = std.fmt.allocPrint(a, "{d}", .{ps.len}) catch "" })) return;
    defer gui.blockEnd();
    if (ps.len == 0) gui.note(tx.get(tx.cp_params_none));
    for (ps) |pr| gui.propRow(std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(pr.type), pr.name }) catch pr.name, tx.get(pr.doc));
}

/// The engine trait whose method (or mark) `name` is: a fighter's natives' (Fighter first).
fn ownerOf(name: []const u8) ?*const traits.Trait {
    if (traits.find(name)) |t| if (t.kind == .mark) return t;
    for ([_][]const u8{ "Fighter", "Hero", "Enemy", "Actor", "Object" }) |tn| if (traits.find(tn).?.own(name) != null) return traits.find(tn);
    return null;
}

// ---------------------------------------------------------------- stubs

/// `methods` added to component `c` in its file, before its closing brace (one undo step),
/// the code shown at the first.
pub fn insert(app: *App, c: *const ti.SComp, methods: []const []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const f = try app.store.file(@import("store.zig").og_src, c.file);
    const old = app.store.text(f);
    const at = ti.bodyEnd(old, c.it.line) orelse return error.NoComponentBody;
    const r = try ti.insertMethods(app.gpa, old, at, methods);
    app.store.group();
    defer app.store.endGroup("{s}: + {s}", .{ c.path, methods[0] });
    try app.store.replace(f, r.text);
    @import("entry_rules.zig").sync(app);
    doctabs.showCode(app, f, r.at);
}
