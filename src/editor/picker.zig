//! The editor's one value chooser: a choice field (or a button) opening a list dropped
//! down under it, searched when long. One list is open at a time (`app.pick`: the id of
//! what opened it); a pick, its field again or a click outside the list closes it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const search = @import("search.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const Id = ui.Clay_ElementId;

/// A row of a list: what the caller reads back (`key`), what it shows (an item icon of
/// sprite.dat before it, a dim note after it) and whether it is the value now.
pub const Opt = struct {
    key: []const u8 = "",
    label: []const u8,
    icon: ?[]const u8 = null,
    note: []const u8 = "",
    selected: bool = false,
};

/// Lists longer than this get a search field.
const search_from = 12;

pub fn isOpen(app: *const App, id: Id) bool {
    return app.pick == id.id;
}

/// The list of `id` opened (its search empty), or closed when it is open.
pub fn toggle(app: *App, id: Id) void {
    if (isOpen(app, id)) app.pick = null else open(app, id);
}

/// The list of `id` opened, its search empty (scripted shots open one too).
pub fn open(app: *App, id: Id) void {
    app.pick = id.id;
    app.pick_q.set("");
}

/// A choice field showing `value` (`warn`: it names nothing) that opens its list; true
/// while the list is open: the caller then draws it (`list`) right after the field.
pub fn field(app: *App, id: Id, value: []const u8, warn: bool) bool {
    if (gui.choiceField(app, id, value, isOpen(app, id), warn)) toggle(app, id);
    return isOpen(app, id);
}

/// `field` on a form row labelled `label`.
pub fn row(app: *App, id: Id, label: []const u8, value: []const u8) bool {
    gui.fieldRow(label);
    defer clay.close();
    return field(app, id, value, false);
}

/// The key of the row `list` returns.
pub fn listKey(app: *App, a: Allocator, rows: []const Opt) ?[]const u8 {
    return rows[list(app, a, rows) orelse return null].key;
}

/// The open list of `rows` under what opened it; the row clicked (the list then closes).
pub fn list(app: *App, a: Allocator, rows: []const Opt) ?usize {
    return listPlay(app, a, rows, null);
}

/// `list` with a play button on each row (`play` of its key) that picks nothing.
pub fn listPlay(app: *App, a: Allocator, rows: []const Opt, play: ?*const fn (*App, []const u8) void) ?usize {
    const anchor: Id = .{ .id = app.pick orelse return null };
    const lid = clay.id("pick_list");
    if (app.clicked and !clay.pointerOver(lid) and !clay.pointerOver(anchor)) {
        app.pick = null;
        return null;
    }
    dropDown(app, anchor, lid);
    const q = if (rows.len > search_from) app.pick_q.get() else "";
    if (rows.len > search_from) gui.searchField(app, a, "pick_search", &app.pick_q, true, tx.get(tx.search_hint), "");
    clay.openScroll(.{ .id = clay.id("pick_rows"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .bottom = lay.space.xs } } });
    var hit: ?usize = null;
    var shown: usize = 0;
    for (rows, 0..) |r, i| {
        if (!search.matches(q, &.{ r.label, r.note, r.key })) continue;
        // shortcut: 300 rows at most; the search narrows the rest.
        shown += 1;
        if (shown > 300) break;
        const clicked = gui.listRow(app, clay.idi("pick_opt", @intCast(i)), .{ .indent = lay.space.md, .h = if (r.icon != null) lay.height.tab else lay.height.small, .rounded = false, .selected = r.selected });
        if (r.icon) |n| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.icon.xl), .height = clay.fixed(lay.icon.xl) } }, .image = .{ .imageData = app.icon(n) } });
        // A note gives way to its label (the one cut at a narrow list's edge).
        if (r.note.len > 0) {
            gui.txt(r.label, .body, theme.text, font_mod.regular);
            gui.txtClip(r.note, .caption, theme.dim, font_mod.regular);
        } else gui.txtClip(r.label, .body, theme.text, font_mod.regular);
        const played = if (play) |p| blk: {
            gui.spacer();
            const b = gui.buttonOf(app, clay.idi("pick_play", @intCast(i)), .{ .label = tx.get(tx.snd_play), .style = .quiet, .size = .small, .color = theme.accent_hover });
            if (b) p(app, r.key);
            break :blk b;
        } else false;
        clay.close();
        if (clicked and !played) hit = i;
    }
    if (shown == 0) gui.txt(tx.get(tx.ref_nothing), .body, theme.dim, font_mod.regular);
    clay.close();
    clay.close();
    if (hit != null) app.pick = null;
    return hit;
}

/// The list floating over the page: dropped down from `anchor` (up when there is more
/// room above), at the window's right edge before `anchor` has been laid out.
fn dropDown(app: *App, anchor: Id, lid: Id) void {
    // A share of the window as 340 of the 1680 the editor was laid out in.
    const side = app.sidePane(340.0 / 1680.0);
    var d: clay.Decl = if (clay.box(anchor)) |r| blk: {
        // The status bar (app_mod.statusBar) stays uncovered.
        const below = app.size[1] - lay.height.control - (r.y + r.height) - lay.space.xl;
        const up = r.y - lay.space.xl > below;
        break :blk .{
            .layout = .{ .sizing = .{ .width = clay.fixed(@max(r.width, side)), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = @max(if (up) r.y - lay.space.xl else below, lay.height.control * 4) } } } }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
            .floating = .{ .attachTo = ui.CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = anchor.id, .attachPoints = if (up) .{ .element = ui.CLAY_ATTACH_POINT_RIGHT_BOTTOM, .parent = ui.CLAY_ATTACH_POINT_RIGHT_TOP } else .{ .element = ui.CLAY_ATTACH_POINT_RIGHT_TOP, .parent = ui.CLAY_ATTACH_POINT_RIGHT_BOTTOM }, .offset = .{ .y = if (up) -lay.space.xs else lay.space.xs }, .zIndex = 10 },
        };
    } else .{
        .layout = .{ .sizing = .{ .width = clay.fixed(side), .height = clay.fixed(app.size[1] - lay.height.control) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .floating = .{ .attachTo = ui.CLAY_ATTACH_TO_ROOT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_RIGHT_TOP, .parent = ui.CLAY_ATTACH_POINT_RIGHT_TOP }, .zIndex = 10 },
    };
    d.id = lid;
    d.backgroundColor = theme.panel;
    d.cornerRadius = clay.radius(lay.radius.md);
    d.border = .{ .color = theme.field_border, .width = gui.edges(lay.border.line) };
    clay.open(d);
}

/// Rows of `names`, each its own key.
pub fn names(a: Allocator, ns: []const []const u8) []Opt {
    const out = a.alloc(Opt, ns.len) catch return &.{};
    for (ns, out) |n, *o| o.* = .{ .key = n, .label = n };
    return out;
}
