//! Actions of an OpenGorky project (src/actions.ogs, `action Open { label = "open"; }`;
//! loaders/rules_text.zig reads each block as its Action row): the list on the left, the
//! shown action edited beside it — its name (the objects naming it follow a rename), its
//! menu text by interface key, its kind, its flags; the item classes and level objects
//! using it; a new one, one deleted. Each edit one undo step.

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
const picker = @import("picker.zig");
const rulesapi = @import("rulesapi.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;
const write = og.compose.og_write;
const parser = og.script.ogs.parser;
const og_src = @import("store.zig").og_src;

const file = "actions.ogs";

pub fn page(app: *App, a: Allocator) void {
    const pid = clay.id("actions_page");
    clay.openScrollColumn(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.md), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.pageHeader(app, .hand, tx.get(tx.act_title), tx.get(tx.act_og_hint));
    if (gui.button(app, "act_new", tx.get(tx.act_new), true)) newAction(app) catch |err| app.failed(err);
    clay.close();
    gui.form(pid, lay.width.label_md, lay.space.xl + lay.block.pad_x);
    // Two columns: the actions, the one shown.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_LEFT_TO_RIGHT, .childGap = lay.block.gap } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(@max(320, app.size[0] * 0.22)) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.block.gap } });
    list(app, a);
    clay.close();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.block.gap } });
    shown(app, a);
    clay.close();
    clay.close();
    clay.closeScrollColumn();
}

fn list(app: *App, a: Allocator) void {
    const acts = rules.active.actions;
    if (!gui.block(app, "act_list", tx.get(tx.act_title), .{ .summary = tx.alloc(a, tx.act_sum, .{acts.len}) })) return;
    for (acts, 0..) |r, k| {
        const sel = app.rules_page.act == r.classic_id;
        if (gui.listRow(app, clay.idi("act_row", @intCast(k)), .{ .selected = sel })) app.rules_page.act = r.classic_id;
        gui.txt(r.name, .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.txtClip(labelText(app, a, r.label), .caption, theme.dim, font_mod.regular);
        gui.spacer();
        if (r.kind != .call) gui.chip(@tagName(r.kind));
        clay.close();
    }
    gui.blockEnd();
}

/// The shown action's fields, what uses it, delete.
fn shown(app: *App, a: Allocator) void {
    const func = app.rules_page.act orelse {
        if (gui.block(app, "act_none", tx.get(tx.act_title), .{})) {
            gui.note(tx.get(tx.act_pick_note));
            gui.blockEnd();
        }
        return;
    };
    const r = (rules.action(func) orelse return).*;
    if (!gui.block(app, "act_shown", r.name, .{})) return;
    gui.fieldRow(tx.get(tx.act_f_name));
    if (gui.textField(app, "act_name", r.name, 0, "—")) |t| rename(app, r.name, t) catch |err| app.failed(err);
    clay.close();
    gui.fieldNote(tx.get(tx.act_name_note), theme.dim);
    // The menu row's text: an interface text's key.
    const pid = clay.id("act_label_pick");
    if (picker.row(app, pid, tx.get(tx.act_f_label), if (r.label.len > 0) std.fmt.allocPrint(a, "{s} · {s}", .{ r.label, labelText(app, a, r.label) }) catch r.label else "—")) {
        if (picker.listKey(app, a, labelOpts(app, a, r.label))) |k| setField(app, r.name, "label", std.fmt.allocPrint(a, "\"{s}\"", .{k}) catch return) catch |err| app.failed(err);
    }
    gui.fieldRow(tx.get(tx.act_f_kind));
    const kinds = comptime std.meta.fieldNames(@FieldType(rules.Action, "kind"));
    if (gui.segmented(app, "act_kind", kinds, @backingInt(r.kind))) |k| setField(app, r.name, "kind", if (k == 0) null else kinds[k]) catch |err| app.failed(err);
    clay.close();
    if (rulesapi.find("Action")) |call| if (rulesapi.field(call, "kind")) |f| if (rulesapi.word(f, @tagName(r.kind))) |w| gui.fieldNote(tx.get(w.doc), theme.dim);
    inline for (.{ "auto_open", "on_exit", "walk_click" }, .{ tx.act_f_auto_open, tx.act_f_on_exit, tx.act_f_walk_click }) |fl, label| {
        gui.fieldRow(tx.get(label));
        const on = @field(r, fl);
        if (gui.check(app, clay.id("act_" ++ fl), on, "")) setField(app, r.name, fl, if (on) null else "true") catch |err| app.failed(err);
        clay.close();
        if (rulesapi.find("Action")) |call| if (rulesapi.field(call, fl)) |f| gui.fieldNote(tx.get(f.doc), theme.dim);
    }
    if (gui.footer(app, "act_drop", &.{tx.get(tx.act_delete)}, null) != null) delete(app, r.name) catch |err| app.failed(err);
    gui.blockEnd();
    @import("rulespages.zig").usedBy(app, func);
}

/// Interface text `key`'s text in the project's language ("" none).
fn labelText(app: *App, a: Allocator, key: []const u8) []const u8 {
    const k = og.core.ui_text.named(key) orelse return "";
    const id = og.core.ui_text.id(k);
    for (texts.rows(app, a, .strings)) |s| if (s.id == id) return s.text;
    return "";
}

/// The interface texts' keys, each with its text.
fn labelOpts(app: *App, a: Allocator, cur: []const u8) []const picker.Opt {
    const names = comptime std.meta.fieldNames(og.core.ui_text.Key);
    const out = a.alloc(picker.Opt, names.len) catch return &.{};
    for (names, out) |n, *o| o.* = .{ .key = n, .label = n, .note = labelText(app, a, n), .selected = std.mem.eql(u8, n, cur) };
    return out;
}

/// The actions' text (actions.ogs), its file in the Store.
fn actionsFile(app: *App) !usize {
    return app.store.file(og_src, file);
}

/// Field `field` of action `name` made `v` (OG Script; null: taken out, its default).
fn setField(app: *App, name: []const u8, field: []const u8, v: ?[]const u8) !void {
    const a = app.frame.allocator();
    const f = try actionsFile(app);
    const value = if (v) |x| try @import("model_og.zig").parseValue(a, x) else null;
    var diag: parser.Diagnostic = .{};
    const new = write.editBlock(a, app.store.text(f), file, "", &.{name}, .{ .field = .{ .name = field, .value = value } }, &diag) catch |err| switch (err) {
        // Taking out a field it has not: nothing to do.
        error.NoSuchBlock => if (v == null) return else return err,
        else => return err,
    };
    try app.store.replace(f, try app.gpa.dupe(u8, new));
    app.setStatus(tx.st_camp_set, .{ field, v orelse "—" });
}

/// A new action `ActionN` (the first free N) at the file's end, shown.
fn newAction(app: *App) !void {
    const a = app.frame.allocator();
    var n: usize = 1;
    const name = while (true) : (n += 1) {
        const x = try std.fmt.allocPrint(a, "Action{d}", .{n});
        if (rules.actionNamed(x) == null) break x;
    };
    const block = try std.fmt.allocPrint(a, "action {s} {{\n    label = \"{s}\";\n}}\n", .{ name, "use" });
    if (actionsFile(app)) |f| {
        const t = app.store.text(f);
        try app.store.replace(f, try std.mem.concat(app.gpa, u8, &.{ t, if (t.len > 0 and t[t.len - 1] != '\n') "\n" else "", block }));
    } else |_| _ = try app.store.addNew(&.{.{ .archive = og_src, .entry = file, .text = try app.gpa.dupe(u8, block) }});
    app.setStatus(tx.st_act_new, .{name});
}

/// Action `old` named `new`: its block and every object naming it (`action = Old;`,
/// `action2 = Old;`), one undo step.
fn rename(app: *App, old: []const u8, new_in: []const u8) !void {
    const new = std.mem.trim(u8, new_in, " ");
    if (new.len == 0 or !isName(new)) return error.BadName;
    if (std.mem.eql(u8, new, old)) return;
    if (rules.actionNamed(new) != null) return error.NameTaken;
    const a = app.frame.allocator();
    app.store.group();
    defer app.store.endGroup("{s} → {s}", .{ old, new });
    const f = try actionsFile(app);
    try app.store.replace(f, try std.mem.replaceOwned(u8, app.gpa, app.store.text(f), try std.fmt.allocPrint(a, "action {s} {{", .{old}), try std.fmt.allocPrint(a, "action {s} {{", .{new})));
    var n: usize = 0;
    for (app.store.listing(a, og_src, null, false)) |p| {
        if (!std.mem.endsWith(u8, p, ".ogs")) continue;
        const of = app.store.file(og_src, p) catch continue;
        const t = app.store.text(of);
        const out = renamedRefs(a, t, old, new) catch continue;
        if (out.len == t.len and std.mem.eql(u8, out, t)) continue;
        try app.store.replace(of, try app.gpa.dupe(u8, out));
        n += 1;
    }
    app.setStatus(tx.st_act_renamed, .{ old, new, n });
}

/// Text `t` with each `actionN = old;` field naming `new`.
fn renamedRefs(a: Allocator, t: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, t, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        const l = std.mem.trimStart(u8, line, " \t");
        const eq = std.mem.indexOf(u8, l, " = ") orelse {
            try out.appendSlice(a, line);
            continue;
        };
        const field = l[0..eq];
        const is_action = std.mem.startsWith(u8, field, "action") and (field.len == 6 or (field.len == 7 and std.ascii.isDigit(field[6])));
        const val = std.mem.trimEnd(u8, l[eq + 3 ..], " ;");
        if (is_action and std.mem.eql(u8, val, old)) {
            try out.appendSlice(a, line[0 .. line.len - l.len]);
            try out.print(a, "{s} = {s};", .{ field, new });
        } else try out.appendSlice(a, line);
    }
    return out.items;
}

/// Action `name`'s block out of actions.ogs (the objects naming it then fail the build).
fn delete(app: *App, name: []const u8) !void {
    const a = app.frame.allocator();
    const f = try actionsFile(app);
    const t = app.store.text(f);
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, t, file, &diag);
    for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "action") and std.mem.eql(u8, e.name, name)) {
        var end = e.span.end;
        while (end < t.len and (t[end] == '\n' or t[end] == '\r')) end += 1;
        const start = if (std.mem.lastIndexOfScalar(u8, t[0..e.span.start], '\n')) |k| k + 1 else 0;
        try app.store.replace(f, try std.mem.concat(app.gpa, u8, &.{ t[0..start], t[end..] }));
        app.rules_page.act = null;
        return app.setStatus(tx.st_act_deleted, .{name});
    };
    return error.NoSuchAction;
}

fn isName(n: []const u8) bool {
    if (n.len == 0 or std.ascii.isDigit(n[0])) return false;
    for (n) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}
