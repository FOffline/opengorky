//! The editor's fields (widgets.zig, on layout.zig's tokens): text, number, script
//! value, search and choice fields, tick boxes, switches, segmented controls, sliders,
//! a player's time bar. widgets.zig re-exports them (`gui.`); the forms stay there.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const app_mod = @import("app.zig");
const search = @import("search.zig");
const textedit = @import("textedit.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const lay = @import("layout.zig");
const space = lay.space;
const height = lay.height;
const Id = ui.Clay_ElementId;
const widgets = @import("widgets.zig");

const bold = widgets.bold;
const center = widgets.center;
const chip = widgets.chip;
const clickable = widgets.clickable;
const edges = widgets.edges;
const icon = widgets.icon;
const middle = widgets.middle;
const pad = widgets.pad;
const regular = widgets.regular;
const rowFit = widgets.rowFit;
const spacer = widgets.spacer;
const txt = widgets.txt;
const txtClip = widgets.txtClip;
const txtWrap = widgets.txtWrap;

/// A field's frame (`active`: typed into); the caller fills and closes it.
pub fn fieldBox(id: Id, active: bool, w: ui.Clay_SizingAxis, h: ui.Clay_SizingAxis) void {
    clay.open(.{
        .id = id,
        .layout = .{ .sizing = .{ .width = w, .height = h }, .padding = pad(space.sm, 0), .childGap = space.sm, .childAlignment = middle },
        .backgroundColor = if (active) theme.field else if (clay.pointerOver(id)) theme.row_hover else theme.field,
        .cornerRadius = clay.radius(lay.radius.md),
        .border = .{ .color = if (active) theme.accent else theme.field_border, .width = edges(lay.border.line) },
    });
}

/// Field `f` being typed into (search.Field): all of it selected while as it began (a key
/// replaces it), else its text and caret; `draw` is txt, txtWrap or txtClip.
pub fn typedText(a: Allocator, f: anytype, comptime draw: anytype) void {
    if (!f.all) return draw(std.fmt.allocPrint(a, "{s}|{s}", .{ f.text()[0..f.caret], f.text()[f.caret..] }) catch "", .body, theme.text, regular);
    clay.open(.{ .backgroundColor = theme.row_selected, .cornerRadius = clay.radius(lay.radius.sm) });
    // A copy: Clay draws it after `f` (passed by value) is gone.
    draw(a.dupe(u8, f.text()) catch "", .body, theme.text, regular);
    clay.close();
}

fn widthOr(w: f32) ui.Clay_SizingAxis {
    return if (w > 0) clay.fixed(w) else clay.grow();
}

/// A text field for free text (textedit.zig keeps what is typed): `key`'s field showing
/// `value` (`w` 0: the rest of the row), wrapping; the typed text when given (Enter or
/// a click away), else null. `hint` shows while empty.
pub fn textField(app: *App, key: []const u8, value: []const u8, w: f32, hint: []const u8) ?[]const u8 {
    const fid = clay.id(key);
    // Its typing ended (Enter, a click away): the text, once.
    var given: ?[]const u8 = null;
    // Left as it was (a click in and away): nothing to write; Enter still gives it.
    if (textedit.taken(app, fid)) |g| if (g.entered or g.field.give() != null) {
        given = app.frame.allocator().dupe(u8, g.text()) catch null;
    };
    var typing = textedit.typedIn(app, fid) != null;
    clay.open(.{
        .id = fid,
        .layout = .{ .sizing = .{ .width = widthOr(w), .height = clay.fitMin(height.control) }, .padding = pad(space.sm, space.xs), .childAlignment = middle },
        .backgroundColor = if (typing) theme.field else if (clay.pointerOver(fid)) theme.row_hover else theme.field,
        .cornerRadius = clay.radius(lay.radius.md),
        .border = .{ .color = if (typing) theme.accent else theme.field_border, .width = edges(lay.border.line) },
    });
    if (!typing and clay.hovered() and app.clicked) {
        textedit.focus(app, key, value);
        typing = true;
    }
    if (typing) typedText(app.frame.allocator(), app.text_edit.?.field, txtWrap) else txtWrap(if (value.len == 0) hint else value, .body, if (value.len == 0) theme.dim else theme.text, regular);
    clay.close();
    return given;
}

/// A name field (a new level's, an area's): `shown`, and while typed into its typed text
/// and caret; a click types into it at its end (`filter`: search.keep; `to`: a buffer
/// following it, textedit `live`). Its typing when given (Enter, a click away).
pub fn nameField(app: *App, a: Allocator, fid: Id, shown: []const u8, filter: *const fn (u8, usize) ?u8, to: ?textedit.Live) ?textedit.Edit {
    const given = textedit.taken(app, fid);
    const typing = textedit.typedIn(app, fid);
    fieldBox(fid, typing != null, clay.grow(), clay.fixed(height.control));
    if (typing == null and clay.hovered() and app.clicked) textedit.focusEnd(app, fid, shown, filter, to);
    txt(std.fmt.allocPrint(a, "{s}{s}", .{ if (typing) |e| e.text() else shown, if (typing != null) "|" else "" }) catch "", .body, theme.text, regular);
    clay.close();
    return given;
}

/// A number field: shows `cur`, a click types a new one (Enter or a click away gives
/// it); `prefix` dim before it ("X", "px"). `w` 0: the rest of the row.
pub fn numberField(app: *App, a: Allocator, id: []const u8, prefix: []const u8, cur: f32, w: f32) ?f32 {
    const fid = clay.id(id);
    const given = textedit.taken(app, fid);
    const typing = textedit.typedIn(app, fid);
    fieldBox(fid, typing != null, widthOr(w), clay.fixed(height.control));
    const over = clay.hovered();
    if (prefix.len > 0) txt(prefix, .caption, theme.dim, regular);
    // Whole numbers without decimals (a brush size), the rest to three places.
    const shown = if (@round(cur) == cur) std.fmt.allocPrint(a, "{d:.0}", .{cur}) else std.fmt.allocPrint(a, "{d:.3}", .{cur});
    if (typing) |e| typedText(a, e.field, txt) else txt(shown catch "", .body, theme.text, regular);
    clay.close();
    if (typing == null and over and app.clicked) beginNumber(app, fid, cur);
    if (given) |g| if (textedit.number(g)) |x| if (x != cur) return x;
    return null;
}

/// Field `fid` typed into, starting from `cur`.
pub fn beginNumber(app: *App, fid: Id, cur: f32) void {
    var nb: [24]u8 = undefined;
    textedit.begin(app, .{ .id = fid, .field = .begin(std.fmt.bufPrint(&nb, "{d}", .{cur}) catch "", search.keep.number) });
}

/// A search typed straight into App.Name `q` (textedit `live`: its list filters as it
/// is typed): the query and its caret while typed into, else `hint`; a click types into
/// it, `always` whenever no other field is typed into (a window's search); `keys` (if
/// any) the shortcut focusing it.
pub fn searchField(app: *App, a: Allocator, id: []const u8, q: anytype, always: bool, hint: []const u8, keys: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = space.sm, .right = space.sm, .top = space.xs, .bottom = space.sm } } });
    const fid = clay.id(id);
    const typing = textedit.typedIn(app, fid) != null;
    const focused = typing or always;
    fieldBox(fid, focused, clay.grow(), clay.fixed(height.control));
    if (!typing and ((clay.hovered() and app.clicked) or (always and app.text_edit == null))) textedit.focusEnd(app, fid, q.get(), search.keep.any, textedit.live(q));
    const query = q.get();
    icon(app, .search, lay.icon.md, theme.dim);
    if (query.len > 0 or focused) txt(std.fmt.allocPrint(a, "{s}{s}", .{ query, if (focused) "|" else "" }) catch query, .body, theme.text, regular) else txtClip(hint, .body, theme.dim, regular);
    if (keys.len > 0) {
        spacer();
        chip(keys);
    }
    clay.close();
    clay.close();
}

/// A value picked from a list: the field shows `value` and "…"; true when clicked
/// (`open`: its list is shown; `warn`: the value names nothing, in the warning colour).
pub fn choiceField(app: *const App, id: Id, value: []const u8, open: bool, warn: bool) bool {
    const hit = clickable(app, .{
        .id = id,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.small) }, .padding = pad(space.sm, 0), .childAlignment = middle },
        .backgroundColor = theme.field,
        .cornerRadius = clay.radius(lay.radius.md),
        .border = .{ .color = if (open) theme.accent else if (warn) theme.warn else theme.field_border, .width = edges(lay.border.line) },
    }, open);
    txtClip(value, .label, if (warn) theme.warn else theme.text, regular);
    spacer();
    txt("…", .body, theme.dim, regular);
    clay.close();
    return hit;
}

/// A tick box (drawn; the row around it takes the click).
fn checkbox(app: *const App, on: bool) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(height.tick), .height = clay.fixed(height.tick) }, .childAlignment = center },
        .backgroundColor = if (on) theme.accent else theme.field,
        .cornerRadius = clay.radius(lay.radius.sm),
        .border = .{ .color = if (on) theme.accent else theme.field_border, .width = edges(lay.border.line) },
    });
    if (on) icon(app, .check, lay.icon.sm, theme.text);
    clay.close();
}

/// A tick box with its label; true when clicked.
pub fn check(app: *const App, id: Id, on: bool, label: []const u8) bool {
    clay.open(.{ .id = id, .layout = .{ .padding = pad(space.sm, 0), .childGap = space.sm, .childAlignment = middle } });
    const hit = clay.hovered() and app.clicked;
    checkbox(app, on);
    if (label.len > 0) txt(label, .body, theme.text, regular);
    clay.close();
    return hit;
}

/// An on/off switch (as the concept's); true when clicked.
pub fn switchBox(app: *const App, id: Id, on: bool) bool {
    const knob = height.tick - space.xs;
    clay.open(.{ .id = id, .layout = .{ .sizing = .{ .width = clay.fixed(2 * height.tick + space.xs), .height = clay.fixed(height.tick + space.xs) }, .padding = pad(lay.border.mark, 0), .childAlignment = .{ .x = if (on) ui.CLAY_ALIGN_X_RIGHT else ui.CLAY_ALIGN_X_LEFT, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (on) theme.accent else theme.field_border, .cornerRadius = clay.radius(height.tick) });
    const hit = clay.hovered() and app.clicked;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(knob), .height = clay.fixed(knob) } }, .backgroundColor = theme.text, .cornerRadius = clay.radius(knob / 2) });
    clay.close();
    return hit;
}

/// A segmented control (as the concept's Paint | Erase): `labels` side by side, `sel`
/// highlighted; returns the one clicked.
pub fn segmented(app: *const App, id: []const u8, labels: []const []const u8, sel: usize) ?usize {
    var hit: ?usize = null;
    // Cut at a narrow pane's edge rather than widen it.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fit() } }, .cornerRadius = clay.radius(lay.radius.md), .border = .{ .color = theme.button_edge, .width = edges(lay.border.line) }, .clip = .{ .horizontal = true } });
    for (labels, 0..) |l, k| {
        const bid = clay.idi(id, @intCast(k));
        const on = k == sel;
        clay.open(.{ .id = bid, .layout = .{ .sizing = .{ .height = clay.fixed(height.control) }, .padding = pad(space.lg, 0), .childAlignment = middle }, .backgroundColor = if (on) theme.accent else if (clay.pointerOver(bid)) theme.button_hover else theme.button, .cornerRadius = clay.radius(lay.radius.md) });
        if (clay.hovered() and app.clicked) hit = k;
        txt(l, .body, theme.text, if (on) bold else regular);
        clay.close();
    }
    clay.close();
    return hit;
}

/// A slider 0…1 (as the concept's opacity): a track, its filled part and a knob;
/// pressed and dragged it follows the pointer. Returns the new value while moved.
pub fn slider(app: *App, id: []const u8, v: f32) ?f32 {
    const sid = clay.id(id);
    const h: u32 = sid.id;
    const b = clay.box(sid);
    const knob = height.tick;
    const track = space.xs + lay.border.mark;
    clay.open(.{ .id = sid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.small) }, .childAlignment = middle } });
    if (clay.hovered() and app.clicked) app.slider_drag = h;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(track) } }, .backgroundColor = theme.field_border, .cornerRadius = clay.radius(track / 2) });
    // A share of the track, not last frame's points (those kept a full track from shrinking).
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = .{ .type = ui.CLAY__SIZING_TYPE_PERCENT, .size = .{ .percent = std.math.clamp(v, 0, 1) } }, .height = clay.fixed(track) } }, .backgroundColor = theme.accent, .cornerRadius = clay.radius(track / 2) });
    clay.close();
    const w = if (b) |bb| bb.width else 0;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(knob), .height = clay.fixed(knob) } }, .backgroundColor = theme.text, .cornerRadius = clay.radius(knob / 2), .floating = .{ .offset = .{ .x = w * std.math.clamp(v, 0, 1) - knob / 2, .y = (height.small - knob) / 2 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
    clay.close();
    if (app.slider_drag == h) {
        if (!app.down) {
            app.slider_drag = null;
            return null;
        }
        const bb = b orelse return null;
        return std.math.clamp((app.mouse[0] - bb.x) / @max(1, bb.width), 0, 1);
    }
    return null;
}

/// A player's place: "0:42 / 3:15" and a bar filled that far (`len` null: unknown).
pub fn timeBar(a: Allocator, at: f32, len: ?f32) void {
    const w: f32 = lay.width.track;
    const track = space.xs;
    rowFit(space.sm);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w), .height = clay.fixed(track) } }, .backgroundColor = theme.line, .cornerRadius = clay.radius(track / 2) });
    const frac = if (len) |l| if (l > 0) std.math.clamp(at / l, 0, 1) else 0 else 0;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w * frac), .height = clay.grow() } }, .backgroundColor = theme.accent, .cornerRadius = clay.radius(track / 2) });
    clay.close();
    const s: u32 = @intFromFloat(at);
    const t = if (len) |l| std.fmt.allocPrint(a, "{d}:{d:0>2} / {d}:{d:0>2}", .{ s / 60, s % 60, @as(u32, @intFromFloat(l)) / 60, @as(u32, @intFromFloat(l)) % 60 }) else std.fmt.allocPrint(a, "{d}:{d:0>2}", .{ s / 60, s % 60 });
    txt(t catch "", .body, theme.dim, regular);
    clay.close();
}
