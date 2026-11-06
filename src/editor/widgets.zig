//! The editor's components: every screen is built from these, on the tokens and rules
//! of layout.zig (its comment describes the system). Nothing here has a size of its
//! own — only layout tokens and the theme (app.zig) — so a fix to how a control looks
//! or fits is made once, here.
//!
//! A screen: containers opened with `stack`/`row` (or `clay.open` with tokens and `pad`),
//! side panes by `sidePanel` and `App.pane`, a `form` over labelled rows (`fieldRow`,
//! `propRow`), and the controls below. A control is laid out against last frame's
//! layout (clicks: `app.clicked` over its box), so it returns true when clicked; one
//! whose caller adds its content leaves it open for the caller to `clay.close()`.
//! A component that changes its form does so by its own container's width in the
//! last layout (labels above fields, a toolbar's icons, buttons wrapping), not by the
//! window or the UI scale.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const icons = @import("icons.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const lay = @import("layout.zig");
pub const Type = lay.Type;
const space = lay.space;
const height = lay.height;

pub const regular = font_mod.regular;
pub const bold = font_mod.bold;

const Id = ui.Clay_ElementId;
const Color = clay.Color;
const fields = @import("fields.zig");
const textedit = @import("textedit.zig");

// The fields (fields.zig).
pub const check = fields.check;
pub const choiceField = fields.choiceField;
pub const fieldBox = fields.fieldBox;
pub const numberField = fields.numberField;
pub const searchField = fields.searchField;
pub const segmented = fields.segmented;
pub const slider = fields.slider;
pub const switchBox = fields.switchBox;
pub const textField = fields.textField;
pub const timeBar = fields.timeBar;
pub const nameField = fields.nameField;

const clear: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
pub const center: ui.Clay_ChildAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER };
pub const middle: ui.Clay_ChildAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER };

// ---- Text

/// One line of text (it widens its row to fit; `txtClip` gives way).
pub fn txt(s: []const u8, t: Type, col: Color, font_id: u16) void {
    clay.text(s, .{ .textColor = col, .fontSize = t.pt(), .fontId = font_id, .wrapMode = ui.CLAY_TEXT_WRAP_NONE });
}

/// Text wrapped at its container's width.
pub fn txtWrap(s: []const u8, t: Type, col: Color, font_id: u16) void {
    clay.text(s, .{ .textColor = col, .fontSize = t.pt(), .fontId = font_id, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
}

/// A dim wrapped note; `warning` in the warning colour.
pub fn note(s: []const u8) void {
    txtWrap(s, .caption, theme.dim, regular);
}

pub fn warning(s: []const u8) void {
    txtWrap(s, .caption, theme.warn, regular);
}

/// Single-line text that gives way in a tight row: cut at its own edge instead of
/// widening the row (plain `txt` is at least its whole string wide).
pub fn txtClip(s: []const u8, t: Type, col: Color, font_id: u16) void {
    openClip(0);
    txt(s, t, col, font_id);
    clay.close();
}

/// A row part that gives way like `txtClip`, for a name and its dim second name together
/// (the second one is cut first). Closed by the caller.
pub fn openClip(gap: u16) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fit() }, .childGap = gap, .childAlignment = middle }, .clip = .{ .horizontal = true } });
}

pub fn icon(app: *const App, ic: icons.Icon, size: f32, col: Color) void {
    icons.leaf(app.r, app.gpa, ic, size, col);
}

/// "12 MB" style counts and other short dim text inside a framed tag.
pub fn chip(s: []const u8) void {
    chipOf(s, theme.text, theme.button_edge);
}

/// A chip in its own colour: the text and the outline (the project's mode).
pub fn chipOf(s: []const u8, col: Color, edge: Color) void {
    clay.open(.{ .layout = .{ .padding = pad(space.sm, lay.border.mark) }, .backgroundColor = theme.button, .cornerRadius = clay.radius(lay.radius.sm), .border = .{ .color = edge, .width = edges(lay.border.line) } });
    txt(s, .caption, col, regular);
    clay.close();
}

/// A small round mark (unsaved, saved).
pub fn dot(col: Color) void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(space.sm), .height = clay.fixed(space.sm) } }, .backgroundColor = col, .cornerRadius = clay.radius(space.xs) });
}

// ---- Containers

pub fn pad(x: u16, y: u16) ui.Clay_Padding {
    return .{ .left = x, .right = x, .top = y, .bottom = y };
}

pub fn edges(w: u16) ui.Clay_BorderWidth {
    return .{ .left = w, .right = w, .top = w, .bottom = w };
}

/// A column as wide as its container, `gap` between its children. Closed by the caller.
pub fn stack(gap: u16) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = gap } });
}

/// A row as wide as its container, its children centred across it. Closed by the caller.
pub fn row(gap: u16) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = gap, .childAlignment = middle } });
}

/// A row as wide as its content.
pub fn rowFit(gap: u16) void {
    clay.open(.{ .layout = .{ .childGap = gap, .childAlignment = middle } });
}

/// Takes the row's free room (pushes what follows to its end).
pub fn spacer() void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
}

/// A line across its container.
pub fn divider() void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.border.line) } }, .backgroundColor = theme.line });
}

/// The grid columns of a container `id` (its width in the last layout, less `inset`):
/// `cell(k)` opens column k, as wide in every row. Before its first layout the
/// columns share `fallback`.
pub const Grid = struct {
    w: [8]f32 = undefined,

    pub fn of(id: Id, inset: f32, gap: f32, tracks: []const lay.Track, fallback: f32) Grid {
        var g: Grid = .{};
        const w = if (clay.box(id)) |b| b.width - inset else fallback;
        lay.resolve(w, gap, tracks, &g.w);
        return g;
    }

    /// Column k's cell, its content cut at its edge. Closed by the caller.
    pub fn cell(g: *const Grid, k: usize, gap: u16) void {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(g.w[k]) }, .childGap = gap, .childAlignment = middle }, .clip = .{ .horizontal = true } });
    }
};

/// A side panel's column `w` wide with a line on its `edge` side (toward the centre):
/// the tree, the inspector, a page's properties. `scroll`: it scrolls (an id needed).
const Panel = struct {
    id: ?Id = null,
    edge: enum { left, right, none } = .left,
    scroll: bool = false,
    /// It scrolls, its children in a column as wide as it (clay.openScrollColumn: what
    /// can't shrink is cut at its edge, never widening it); closed by clay.closeScrollColumn.
    column: bool = false,
    pad: ui.Clay_Padding = .{},
    gap: u16 = 0,
    bg: Color = theme.panel,
};

pub fn sidePanel(w: f32, p: Panel) void {
    const d: clay.Decl = .{
        .id = p.id orelse .{},
        .layout = .{ .sizing = .{ .width = clay.fixed(w), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = p.pad, .childGap = p.gap },
        .backgroundColor = p.bg,
        .border = .{ .color = theme.line, .width = switch (p.edge) {
            .left => .{ .left = lay.border.line },
            .right => .{ .right = lay.border.line },
            .none => .{},
        } },
    };
    if (p.column) clay.openScrollColumn(d) else if (p.scroll) clay.openScroll(d) else clay.open(d);
}

/// A page's right column (its properties and actions beside the centre, the width of
/// the level's inspector, dragged by its edge): blocks (`groupTitle`) on the column, a
/// form for `propRow`. Closed by `propsEnd`.
pub fn propsPanel(app: *App, id: []const u8) void {
    app.splitter(.objects, false, -1, 1);
    const pid = clay.id(id);
    sidePanel(app.pane(.objects), .{ .id = pid, .column = true, .pad = pad(lay.block.gap, lay.block.gap), .gap = lay.block.gap, .bg = theme.bg });
    form(pid, lay.width.label_md, lay.block.gap + lay.block.pad_x);
}

/// Closes a `propsPanel` and its last block.
pub fn propsEnd() void {
    blockEnd();
    clay.closeScrollColumn();
}

// ---- Headers

/// A panel's title bar: darker, a line under it.
pub fn panelHeader(s: []const u8) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.tool) }, .padding = pad(space.md, 0), .childGap = space.sm, .childAlignment = middle },
        .backgroundColor = theme.title,
        .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } },
    });
    txt(s, .label, theme.text, bold);
    clay.close();
}

/// A titled block of a properties column (`propsPanel`): the one before it closed.
pub fn groupTitle(s: []const u8, first: bool) void {
    if (!first) blockEnd();
    cardOpen(false);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.tool) }, .padding = pad(space.md, 0), .childAlignment = middle }, .backgroundColor = theme.header, .cornerRadius = topRadius(), .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } } });
    txtClip(s, .title, theme.text, bold);
    clay.close();
    bodyOpen();
}

/// A section title of a page with its dim note.
pub fn heading(title: []const u8, sub: []const u8) void {
    clay.open(.{ .layout = .{ .childGap = space.md, .padding = .{ .top = space.xs }, .childAlignment = middle } });
    txt(title, .title, theme.text, bold);
    txt(sub, .caption, theme.dim, regular);
    clay.close();
}

/// A page's header: its icon, its title over a wrapped hint; the row stays open for
/// the page's actions (closed by the caller).
pub fn pageHeader(app: *const App, ic: icons.Icon, title: []const u8, hint: []const u8) void {
    row(space.md);
    icon(app, ic, lay.icon.xl, theme.accent_hover);
    // The hint wraps beside the actions (one line ran under them in a narrow page).
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    txt(title, .heading, theme.text, bold);
    note(hint);
    clay.close();
}

/// What a block's header shows and how the block folds.
const BlockOpts = struct {
    /// Dim text at the header's end, what the block holds (in sight folded too).
    summary: []const u8 = "",
    /// The summary in the warning colour (something is wrong inside).
    warn: bool = false,
    /// Folded until opened: `secopen/<key>` in the open-folder set means open (else
    /// `sec/<key>` means folded).
    folded: bool = false,
    /// Only OpenGorky projects have it: a Classic one draws nothing (false).
    og: bool = false,
    /// A card inside a block (an attack): its own surface, no frame.
    inner: bool = false,
};

/// A block of a right panel (a card on the column): its header (folding by `key`; null:
/// always open) over its body, padded and spaced alike in every block. True while open:
/// the body is then open, closed by the caller with `blockEnd`.
pub fn block(app: *App, key: ?[]const u8, title: []const u8, o: BlockOpts) bool {
    if (o.og and !app.ogLayout()) return false;
    const shut = o.folded;
    var kb: [64]u8 = undefined;
    const k: ?[]const u8 = if (key) |kk| std.fmt.bufPrint(&kb, "{s}/{s}", .{ if (shut) "secopen" else "sec", kk }) catch kk else null;
    const open = if (k) |kk| app.tree_open.contains(kk) == shut else true;
    cardOpen(o.inner);
    const hd: clay.Decl = .{
        .id = if (k) |kk| clay.id(kk) else .{},
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.tool) }, .padding = .{ .left = space.sm, .right = space.md }, .childGap = space.sm, .childAlignment = middle },
        .backgroundColor = theme.header,
        .cornerRadius = if (open) topRadius() else clay.radius(lay.radius.md),
        .border = if (open) .{ .color = theme.line, .width = .{ .bottom = lay.border.line } } else .{},
    };
    if (k) |kk| {
        if (clickable(app, hd, false)) @import("assettree.zig").toggleKey(app, kk);
        icon(app, if (open) .chevron_down else .chevron_right, lay.icon.sm, theme.dim);
    } else clay.open(hd);
    txtClip(title, .title, theme.text, bold);
    spacer();
    if (o.summary.len > 0) txtClip(o.summary, .caption, if (o.warn) theme.warn else theme.dim, regular);
    clay.close();
    if (!open) {
        clay.close();
        return false;
    }
    bodyOpen();
    // A card in a block: its labels end where the block's do (one value column).
    if (o.inner) if (label_w) |w| {
        label_w = @max(0, w - lay.block.pad_x);
        inner_shift = true;
    };
    return true;
}

fn cardOpen(inner: bool) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = if (inner) theme.header else theme.panel, .cornerRadius = clay.radius(lay.radius.md), .border = if (inner) .{} else .{ .color = theme.line, .width = edges(lay.border.line) } });
}

fn bodyOpen() void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = pad(lay.block.pad_x, lay.block.pad_y), .childGap = lay.block.row_gap } });
}

/// A header's corners under its card's rounded top.
fn topRadius() ui.Clay_CornerRadius {
    return .{ .topLeft = lay.radius.md, .topRight = lay.radius.md, .bottomLeft = 0, .bottomRight = 0 };
}

/// An inner card's labels are shorter by its padding until it ends.
var inner_shift = false;

/// Closes an open block's body and its card.
pub fn blockEnd() void {
    if (inner_shift) if (label_w) |w| {
        label_w = w + lay.block.pad_x;
        inner_shift = false;
    };
    clay.close();
    clay.close();
}

/// A page's head in a right panel: a card without a header bar. Closed by `blockEnd`.
pub fn headCard() void {
    cardOpen(false);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = pad(lay.block.pad_x, lay.block.pad_x), .childGap = space.sm } });
}

/// A subgroup's title inside a block: dim, a line after it to the block's edge.
pub fn subhead(s: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .top = space.sm }, .childGap = space.sm, .childAlignment = middle } });
    txtClip(s, .caption, theme.dim, bold);
    divider();
    clay.close();
}

/// A block's (or a subgroup's) actions after its rows: small buttons side by side,
/// wrapped in a narrow panel; `primary` the one finishing the tool. Returns the one clicked.
pub fn footer(app: *const App, id: []const u8, labels: []const []const u8, primary: ?usize) ?usize {
    var items: [16]Item = undefined;
    const n = @min(labels.len, items.len);
    for (labels[0..n], 0..) |l, k| items[k] = .{ .id = clay.idi(id, @intCast(k)), .b = .{ .label = l, .style = if (primary == k) .primary else .secondary, .size = .small } };
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .top = space.xs } } });
    const hit = buttonRow(app, clay.idi(id, 99), items[0..n]);
    clay.close();
    return hit;
}

// ---- Buttons

pub const Style = enum {
    secondary,
    primary,
    /// No frame until hovered (an eye, a lock, a × at a row's end).
    quiet,
    /// A light frame (a field's small actions).
    outline,
};

const Size = enum {
    small,
    control,
    tool,

    fn h(s: Size) f32 {
        return switch (s) {
            .small => height.small,
            .control => height.control,
            .tool => height.tool,
        };
    }
};

pub const Button = struct {
    label: []const u8 = "",
    icon: ?icons.Icon = null,
    style: Style = .secondary,
    size: Size = .control,
    /// A tool in use, a view shown.
    on: bool = false,
    /// As wide as its container.
    wide: bool = false,
    /// The label's colour (default: by its style).
    color: ?Color = null,
};

fn padX(b: Button) u16 {
    return if (b.label.len == 0) (if (b.size == .tool) space.sm else space.xs) else if (b.size == .small) space.sm else space.md;
}

/// The width `b` takes (its whole label, without cutting).
pub fn buttonWidth(app: *const App, b: Button) f32 {
    var w: f32 = @floatFromInt(2 * padX(b));
    if (b.icon != null) w += lay.icon.md;
    if (b.label.len > 0) w += app.font.measure(b.label, if (b.on or b.style == .primary) bold else regular, Type.body.pt())[0];
    if (b.icon != null and b.label.len > 0) w += space.sm;
    return w;
}

/// A button; true when clicked. Its label is cut rather than widen a narrow panel.
pub fn buttonOf(app: *const App, id: Id, b: Button) bool {
    const over = clay.pointerOver(id);
    const pressed = over and app.down;
    const strong = b.on or b.style == .primary;
    const bg: Color = switch (b.style) {
        .primary => if (pressed) theme.accent else if (over) theme.accent_hover else theme.accent,
        .secondary => if (b.on) theme.row_selected else if (pressed) theme.button_down else if (over) theme.button_hover else theme.button,
        .quiet => if (b.on) theme.row_selected else if (over) theme.button_hover else clear,
        .outline => if (over) theme.row_hover else theme.panel,
    };
    const edge: ?Color = switch (b.style) {
        .primary => theme.accent,
        .secondary => if (b.on) theme.accent else theme.button_edge,
        .quiet => null,
        .outline => theme.field_border,
    };
    const square = b.label.len == 0;
    clay.open(.{
        .id = id,
        .layout = .{
            .sizing = .{ .width = if (b.wide) clay.grow() else if (square) clay.fixed(b.size.h()) else clay.fit(), .height = clay.fixed(b.size.h()) },
            .padding = pad(padX(b), 0),
            .childGap = space.sm,
            .childAlignment = if (square) center else middle,
        },
        .backgroundColor = bg,
        .cornerRadius = clay.radius(lay.radius.md),
        .border = if (edge) |e| .{ .color = e, .width = edges(lay.border.line) } else .{},
    });
    const hit = clay.hovered() and app.clicked;
    if (b.icon) |ic| icon(app, ic, lay.icon.md, b.color orelse if (strong) theme.text else theme.dim);
    if (b.label.len > 0) txtClip(b.label, .body, b.color orelse theme.text, if (strong) bold else regular);
    clay.close();
    return hit;
}

/// A media page's column (sounds, videos) on the frame's stage, left open (closed by
/// frame.props); with nothing picked (`name` empty) only its import button and `hint`,
/// closed: false then.
pub fn mediaPage(app: *App, name: []const u8, id: []const u8, import: []const u8, hint: []const u8, ask: app_mod.FileAsk) bool {
    if (name.len > 0) @import("frame.zig").stage(app);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = space.xl, .right = space.xl, .top = space.lg }, .childGap = space.md } });
    if (name.len > 0) return true;
    if (button(app, id, import, true)) app.askFile(ask);
    txtWrap(hint, .body, theme.dim, font_mod.regular);
    clay.close();
    return false;
}

/// A button; `primary` in the accent colour.
pub fn button(app: *const App, id: []const u8, label: []const u8, primary: bool) bool {
    return buttonOf(app, clay.id(id), .{ .label = label, .style = if (primary) .primary else .secondary });
}

/// A toolbar button: an icon and (if any) a label; `on` — the tool in use, `primary` —
/// the main action.
pub fn toolButton(app: *const App, id: []const u8, ic: icons.Icon, label: []const u8, on: bool, primary: bool) bool {
    return buttonOf(app, clay.id(id), .{ .label = label, .icon = ic, .on = on, .style = if (primary) .primary else .secondary, .size = .tool });
}

/// A small framed text button (a field's actions: pick a PNG, edit the icon).
pub fn smallButton(app: *const App, id: Id, label: []const u8) bool {
    return buttonOf(app, id, .{ .label = label, .style = .outline, .size = .small });
}

/// A slot's › to the page of what it picks (an icon: nothing to cut in a narrow panel).
pub fn goButton(app: *const App, id: Id) bool {
    return buttonOf(app, id, .{ .icon = .chevron_right, .style = .outline, .size = .small });
}

/// Text without a frame until hovered, in colour `col` (a sound's play and steps, ×).
pub fn textButton(app: *const App, id: []const u8, label: []const u8, col: Color) bool {
    return buttonOf(app, clay.id(id), .{ .label = label, .style = .quiet, .size = .small, .color = col });
}

/// A square icon without a frame until hovered (`on`: highlighted).
pub fn iconButton(app: *const App, id: Id, ic: icons.Icon, on: bool) bool {
    return buttonOf(app, id, .{ .icon = ic, .style = .quiet, .size = .small, .on = on });
}

/// Text that acts as a link (a status bar's "problems", a panel's Cancel); `hover`
/// colours it under the pointer.
pub fn link(app: *const App, id: Id, s: []const u8, col: Color, hover: Color) bool {
    clay.open(.{ .id = id, .layout = .{ .padding = pad(space.xs, 0) } });
    const hit = clay.hovered() and app.clicked;
    txt(s, .caption, if (clay.pointerOver(id)) hover else col, regular);
    clay.close();
    return hit;
}

/// An eye (shown or not) or another on/off icon at a row's end; true when clicked.
pub fn eye(app: *const App, id: Id, shown: bool) bool {
    clay.open(.{ .id = id, .layout = .{ .sizing = .{ .width = clay.fixed(height.small), .height = clay.fixed(height.small) }, .childAlignment = center } });
    const hit = clay.hovered() and app.clicked;
    icon(app, if (shown) .eye else .eye_off, lay.icon.md, if (shown) theme.accent_hover else theme.dim);
    clay.close();
    return hit;
}

/// A clickable row or card: opened as `d` (its id and its own colour), highlighted
/// under the pointer and while `selected`; true when clicked. The caller fills and
/// closes it.
pub fn clickable(app: *const App, d: clay.Decl, selected: bool) bool {
    var dd = d;
    if (selected) dd.backgroundColor = theme.row_selected else if (clay.pointerOver(d.id)) dd.backgroundColor = theme.row_hover;
    clay.open(dd);
    return clay.hovered() and app.clicked;
}

/// Buttons side by side, wrapped into more lines when their container `id` (its width
/// in the last layout) is too narrow — Clay rows don't wrap. Returns the one clicked.
pub const Item = struct { id: Id, b: Button };

pub fn buttonRow(app: *const App, rid: Id, items: []const Item) ?usize {
    var widths: [16]f32 = undefined;
    var line: [16]u8 = undefined;
    const n = @min(items.len, widths.len);
    for (items[0..n], 0..) |it, k| widths[k] = buttonWidth(app, it.b);
    const w = if (clay.box(rid)) |b| b.width else std.math.floatMax(f32);
    const lines = lay.wrap(widths[0..n], space.sm, w, &line);
    var hit: ?usize = null;
    clay.open(.{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = space.sm } });
    var k: usize = 0;
    for (0..lines) |l| {
        rowFit(space.sm);
        while (k < n and line[k] == l) : (k += 1) if (buttonOf(app, items[k].id, items[k].b)) {
            hit = k;
        };
        clay.close();
    }
    clay.close();
    return hit;
}

/// A toolbar across the page: named buttons when they all fit (by last frame's
/// widths), else icons (the tool in use keeps its name). Scrolled sideways: a window
/// too narrow even for the icons cuts it (reached by a sideways scroll) rather than
/// widening the window.
pub const Toolbar = struct {
    id: Id,
    named: bool,
    need: f32 = space.sm * 2,

    var last: [8]struct { id: u32, need: f32 } = @splat(.{ .id = 0, .need = 0 });

    /// A page's bar, under its tabs.
    pub fn open(name: []const u8) Toolbar {
        return start(name, .{
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.bar) }, .padding = pad(space.sm, 0), .childGap = space.sm, .childAlignment = middle },
            .backgroundColor = theme.header,
            .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } },
        });
    }

    /// A bar over a picture (the model's view): no background of its own.
    pub fn over(name: []const u8) Toolbar {
        return start(name, .{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = pad(space.sm, 0), .childGap = space.sm, .childAlignment = middle } });
    }

    fn start(name: []const u8, d: clay.Decl) Toolbar {
        const id = clay.id(name);
        var named = true;
        for (last) |l| if (l.id == id.id) {
            named = if (clay.box(id)) |b| l.need <= b.width else true;
        };
        var dd = d;
        dd.id = id;
        clay.openScrollX(dd);
        return .{ .id = id, .named = named };
    }

    /// A tool button, named while the bar fits names.
    pub fn button(t: *Toolbar, app: *const App, id: []const u8, ic: icons.Icon, label: []const u8, on: bool, primary: bool) bool {
        return t.add(app, id, .{ .label = label, .icon = ic, .on = on, .style = if (primary) .primary else .secondary, .size = .tool }, t.named);
    }

    /// One of the bar's tools: named while the bar fits names, or while in use.
    pub fn tool(t: *Toolbar, app: *const App, id: []const u8, ic: icons.Icon, label: []const u8, on: bool) bool {
        return t.add(app, id, .{ .label = label, .icon = ic, .on = on, .size = .tool }, t.named or on);
    }

    fn add(t: *Toolbar, app: *const App, id: []const u8, b: Button, named: bool) bool {
        t.need += buttonWidth(app, b) + space.sm;
        var shown = b;
        if (!named) shown.label = "";
        return buttonOf(app, clay.id(id), shown);
    }

    /// A tick box, its label shown while the bar fits names.
    pub fn check(t: *Toolbar, app: *const App, id: []const u8, on: bool, label: []const u8) bool {
        t.reserve(height.tick + 3 * space.sm + app.font.measure(label, regular, Type.body.pt())[0]);
        return @import("widgets.zig").check(app, clay.id(id), on, if (t.named) label else "");
    }

    /// Dim text shown while the bar fits names (the zoom).
    pub fn note(t: *Toolbar, app: *const App, s: []const u8) void {
        t.reserve(app.font.measure(s, regular, Type.body.pt())[0]);
        if (t.named) txt(s, .body, theme.dim, regular);
    }

    /// Room for other content of the bar.
    pub fn reserve(t: *Toolbar, w: f32) void {
        t.need += w + space.sm;
    }

    pub fn close(t: *Toolbar) void {
        clay.close();
        for (&last) |*l| if (l.id == t.id.id or l.id == 0) {
            l.* = .{ .id = t.id.id, .need = t.need };
            return;
        };
        last[0] = .{ .id = t.id.id, .need = t.need };
    }
};

// ---- Forms

/// The label column of the rows that follow (`fieldRow`, `propRow`), from their form's
/// width in the last layout: null — the labels go above their fields.
var label_w: ?f32 = lay.width.label_lg;
/// The form's rows' width (0: not laid out yet).
var form_w: f32 = 0;

/// The rows that follow are in container `id`'s form, their labels at most `cap` wide,
/// `inset` from its edges (its padding and its blocks'): one label column for them all.
pub fn form(id: Id, cap: f32, inset: u16) void {
    const b = clay.box(id) orelse {
        form_w = 0;
        label_w = cap;
        return;
    };
    form_w = b.width - 2 * @as(f32, @floatFromInt(inset));
    // Labels beside the values while the container is wide enough for them (its 40%),
    // 40% of the rows' width, at least the least label column.
    label_w = if (lay.labelWidth(b.width, cap) == null) null else @min(cap, @max(lay.width.label_min, @round(form_w * 0.4)));
}

/// The width of each of `n` alike values in a row (a vector's X, Y, Z), the row's end
/// slot (`trail`) kept: the same in every row, whatever their numbers. 0 (the values
/// share the row) before the form's first layout and in a narrow form.
pub fn cellWidth(n: usize, with_trail: bool) f32 {
    // Labels above (a narrow form): the values share the row as their numbers need.
    if (form_w <= 0 or label_w == null) return 0;
    const k: f32 = @floatFromInt(n);
    const end: f32 = if (with_trail) height.tick + space.sm else 0;
    const used = (if (label_w) |w| w + space.sm else 0) + end + (k - 1) * space.sm;
    return @max(0, @floor((form_w - used) / k));
}

/// A labelled row (as tall as its field, or a wrapped label, so rows never overlap):
/// the label in the form's column, the caller's values after it; in a narrow form the
/// label on a line of its own above them. The values' row is closed by the caller.
pub fn fieldRow(label: []const u8) void {
    fieldRowLead();
    txtWrap(label, .label, theme.dim, regular);
    clay.close();
    fieldRowValues();
}

/// `fieldRow` with the caller's own content in the label's column (an attach point's
/// name field), closed by the caller before the values (`fieldRowValues` after it).
pub fn fieldRowLead() void {
    const lw = label_w orelse {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .top = space.xs } } });
        return;
    };
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fitMin(height.control) }, .childGap = space.sm, .childAlignment = middle } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lw) }, .childAlignment = middle } });
}

/// After `fieldRowLead`'s content: the values' row in a narrow form (its label above).
pub fn fieldRowValues() void {
    if (label_w != null) return;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fitMin(height.control) }, .childGap = space.sm, .childAlignment = middle } });
}

/// A row's end slot (the same in every row of a block, so the values end alike): × with
/// `id` (true when clicked), else empty.
pub fn trail(app: *const App, id: ?Id) bool {
    const tid = id orelse Id{};
    clay.open(.{ .id = tid, .layout = .{ .sizing = .{ .width = clay.fixed(height.tick), .height = clay.fixed(height.small) }, .childAlignment = center } });
    const hit = id != null and clay.hovered() and app.clicked;
    if (id != null) txt("×", .title, if (clay.pointerOver(tid)) theme.warn else theme.dim, bold);
    clay.close();
    return hit;
}

/// A row under a form's values (aligned with them): a note and its button. Closed by the caller.
pub fn valueLine() void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = if (label_w) |w| @as(u16, @intFromFloat(w)) + space.sm else 0 }, .childGap = space.sm, .childAlignment = middle } });
}

/// A labelled value with `-`/`+` (a level's light, the grid): `text` is "Label: value",
/// the value clicked is typed anew. Returns the step taken (0: none).
pub fn stepper(app: *App, a: Allocator, id: []const u8, text: []const u8, cur: f32, step: f32) f32 {
    const cut = std.mem.lastIndexOf(u8, text, ": ");
    fieldRow(if (cut) |k| text[0..k] else text);
    defer clay.close();
    const value = if (cut) |k| text[k + 2 ..] else "";
    var out: f32 = 0;
    if (buttonOf(app, clay.id(std.fmt.allocPrint(a, "{s}_m", .{id}) catch id), .{ .label = "-", .size = .small })) out = -step;
    const fid = clay.id(std.fmt.allocPrint(a, "{s}_n", .{id}) catch id);
    const given = textedit.taken(app, fid);
    const typing = textedit.typedIn(app, fid);
    fieldBox(fid, typing != null, clay.growMax(lay.width.field), clay.fixed(height.small));
    const over = clay.hovered();
    if (typing) |e| fields.typedText(a, e.field, txtClip) else txtClip(value, .body, theme.text, regular);
    clay.close();
    if (buttonOf(app, clay.id(std.fmt.allocPrint(a, "{s}_p", .{id}) catch id), .{ .label = "+", .size = .small })) out = step;
    // The value clicked: typed anew (the step taken is new − current).
    if (typing == null and over and app.clicked) fields.beginNumber(app, fid, cur);
    if (given) |g| if (textedit.number(g)) |x| return x - cur;
    return out;
}

/// A note under a form's values (aligned with them).
pub fn fieldNote(s: []const u8, col: Color) void {
    valueLine();
    txtWrap(s, .caption, col, regular);
    clay.close();
}

/// A label and its value as text, compact (a properties column).
pub fn propRow(label: []const u8, value: []const u8) void {
    if (label_w == null) {
        stack(0);
        txtWrap(label, .body, theme.dim, regular);
        txtWrap(value, .body, theme.text, regular);
        return clay.close();
    }
    row(space.sm);
    // Up to the label column, narrower (wrapped) when the value needs the room.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.growMax(label_w.?) } } });
    txtWrap(label, .body, theme.dim, regular);
    clay.close();
    txtWrap(value, .body, theme.text, regular);
    clay.close();
}

// ---- Lists

/// A list row: `indent` at its start, `selected` highlighted, as tall as a control
/// (`fit`: its content, at least a small row). True when clicked; the caller fills and
/// closes it (`clay.hovered()` tells a right click).
pub const Row = struct {
    selected: bool = false,
    indent: u16 = space.sm,
    h: f32 = height.control,
    fit: bool = false,
    gap: u16 = space.sm,
    rounded: bool = true,
    bg: Color = theme.panel,
};

pub fn listRow(app: *const App, id: Id, r: Row) bool {
    return clickable(app, .{
        .id = id,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = if (r.fit) clay.fitMin(height.small) else clay.fixed(r.h) }, .padding = .{ .left = r.indent, .right = space.sm, .top = if (r.fit) space.xs else 0, .bottom = if (r.fit) space.xs else 0 }, .childGap = r.gap, .childAlignment = middle },
        .backgroundColor = r.bg,
        .cornerRadius = clay.radius(if (r.rounded) lay.radius.sm else 0),
    }, r.selected);
}

/// A folding group's row: chevron, icon (accent when `ic_accent`), title, its count
/// (maxInt: none) at its end. True when clicked; the caller adds what ends it (an
/// eye) and closes it.
pub fn folderRow(app: *const App, id: Id, depth: u32, open: bool, ic: icons.Icon, ic_accent: bool, title: []const u8, strong: bool, n: usize, a: Allocator) bool {
    const hit = listRow(app, id, .{ .indent = @intCast(space.sm + depth * space.indent), .rounded = false });
    icon(app, if (open) .chevron_down else .chevron_right, lay.icon.sm, theme.dim);
    icon(app, ic, lay.icon.md, if (ic_accent) theme.accent_hover else theme.dim);
    // Names cut at a narrow list's edge (the count stays in sight).
    txtClip(title, .label, theme.text, if (strong) bold else regular);
    spacer();
    if (n != std.math.maxInt(usize)) txt(std.fmt.allocPrint(a, "({d})", .{n}) catch "", .caption, theme.dim, regular);
    return hit;
}

/// A row's indent under a folder of depth `depth` (past its chevron).
pub fn leafIndent(depth: u32) u16 {
    return @intCast(space.sm + depth * space.indent + space.lg + space.xs);
}

/// A band between a list's rows (the last save, earlier sessions).
pub fn listMark(s: []const u8, col: Color) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.small) }, .padding = .{ .left = space.md }, .childAlignment = middle }, .backgroundColor = theme.bg });
    txt(s, .caption, col, bold);
    clay.close();
}

/// A list's dim line (nothing to show).
pub fn listNote(s: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = pad(space.md, space.sm) } });
    txtWrap(s, .body, theme.dim, regular);
    clay.close();
}

// ---- Tabs

/// Tabs underlined when picked (a panel's views); returns the one clicked.
pub fn tabs(app: *const App, id: []const u8, labels: []const []const u8, sel: usize) ?usize {
    var hit: ?usize = null;
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.tab) }, .padding = pad(space.sm, 0), .childGap = space.xs, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } },
        .backgroundColor = theme.panel,
        .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } },
    });
    for (labels, 0..) |l, k| {
        const on = k == sel;
        clay.open(.{
            .id = clay.idi(id, @intCast(k)),
            .layout = .{ .sizing = .{ .height = clay.fixed(height.tab - space.xs) }, .padding = pad(space.md, 0), .childAlignment = middle },
            .border = .{ .color = theme.accent, .width = .{ .bottom = if (on) lay.border.mark else 0 } },
        });
        if (clay.hovered() and app.clicked) hit = k;
        txt(l, .label, if (on) theme.accent_hover else theme.dim, if (on) bold else regular);
        clay.close();
    }
    clay.close();
    return hit;
}

// ---- Menus

/// A menu's shape: a rounded panel `w` wide floating as `float`. Closed by the caller.
pub fn menuPanel(id: Id, w: f32, float: ui.Clay_FloatingElementConfig) void {
    clay.open(.{
        .id = id,
        .layout = .{ .sizing = .{ .width = clay.fixed(w), .height = clay.fit() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = pad(space.xs, space.xs) },
        .backgroundColor = theme.panel,
        .cornerRadius = clay.radius(lay.radius.md),
        .border = .{ .color = theme.button_edge, .width = edges(lay.border.line) },
        .floating = float,
    });
}

/// A submenu's panel beside its row (open over everything else).
pub fn submenuPanel(id: Id, w: f32) void {
    menuPanel(id, w, .{ .attachTo = ui.CLAY_ATTACH_TO_PARENT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_LEFT_TOP, .parent = ui.CLAY_ATTACH_POINT_RIGHT_TOP }, .offset = .{ .x = space.sm, .y = -space.xs }, .zIndex = 110 });
}

/// One menu row: icon, label, the key on the right; true when clicked (the menu closes).
/// A disabled row is dim and takes no click.
pub fn menuRow(app: *App, id: []const u8, ic: ?icons.Icon, label: []const u8, key: []const u8, col: Color, enabled: bool) bool {
    const rid = clay.id(id);
    const over = enabled and clay.pointerOver(rid);
    clay.open(.{
        .id = rid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.control) }, .padding = pad(space.sm, 0), .childGap = space.sm, .childAlignment = middle },
        .backgroundColor = if (over) theme.row_hover else theme.panel,
        .cornerRadius = clay.radius(lay.radius.sm),
    });
    const hit = over and app.clicked;
    const warn = col.r == theme.warn.r and col.g == theme.warn.g;
    if (ic) |i| icon(app, i, lay.icon.md, if (!enabled) theme.line else if (warn) col else theme.dim) else clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.icon.md) } } });
    txtClip(label, .label, if (enabled) col else theme.dim, regular);
    spacer();
    if (key.len > 0) txt(key, .caption, theme.dim, regular);
    clay.close();
    if (hit) {
        app.menu = null;
        app.tree_menu = null;
    }
    return hit;
}

/// A row opening a submenu (`open`: shown beside it); the caller opens the panel.
pub fn submenuRow(app: *const App, id: Id, ic: icons.Icon, label: []const u8, open: bool) void {
    clay.open(.{
        .id = id,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.control) }, .padding = pad(space.sm, 0), .childGap = space.sm, .childAlignment = middle },
        .backgroundColor = if (open) theme.accent else theme.panel,
        .cornerRadius = clay.radius(lay.radius.sm),
    });
    icon(app, ic, lay.icon.md, if (open) theme.text else theme.dim);
    txt(label, .label, theme.text, regular);
    spacer();
    icon(app, .chevron_right, lay.icon.sm, if (open) theme.text else theme.dim);
}

pub fn menuLine() void {
    divider();
}

/// A menu's title: what it acts on, its kind dim after it.
pub fn menuTitle(a: Allocator, name: []const u8, kind: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(height.control) }, .padding = pad(space.sm, 0), .childGap = space.sm, .childAlignment = middle } });
    txt(name, .body, theme.text, bold);
    if (kind.len > 0) txt(std.fmt.allocPrint(a, "/  {s}", .{kind}) catch kind, .body, theme.dim, regular);
    clay.close();
}

/// A menu's dim line (nothing to pick).
pub fn menuNote(s: []const u8) void {
    clay.open(.{ .layout = .{ .padding = pad(space.sm, space.xs) } });
    txt(s, .body, theme.dim, regular);
    clay.close();
}

// ---- Windows

const ModalHit = enum { none, close, extra };

const Modal = struct {
    /// Its size at most (capped to the window); `h` null: as tall as its content.
    w: f32 = lay.width.window,
    h: ?f32 = null,
    bg: Color = theme.panel,
    title: []const u8,
    /// Before the title (a confirmation's mark).
    icon: ?icons.Icon = null,
    icon_color: Color = theme.dim,
    /// A text action in the title bar ("" for none), and Close.
    extra: []const u8 = "",
    close: bool = true,
    /// The editor under it dimmed (a question to answer).
    shade: bool = false,
};

/// A centred window over the editor with its title bar: the icon and title, then
/// `extra` and Close. Says which was clicked; the caller fills the window under the bar
/// and closes it.
pub fn modal(app: *const App, id: []const u8, m: Modal) ModalHit {
    // Within the window at any UI scale (300% leaves a few hundred points).
    const w = @min(m.w, app.size[0] - 2 * space.lg);
    const z: i16 = if (m.shade) 200 else 100;
    if (m.shade) clay.leaf(.{ .id = clay.id("modal_shade"), .layout = .{ .sizing = .{ .width = clay.fixed(app.size[0]), .height = clay.fixed(app.size[1]) } }, .backgroundColor = .{ .r = 0, .g = 0, .b = 0, .a = 120 }, .floating = .{ .zIndex = z - 1, .attachTo = ui.CLAY_ATTACH_TO_ROOT } });
    clay.open(.{
        .id = clay.id(id),
        .layout = .{ .sizing = .{ .width = clay.fixed(w), .height = if (m.h) |h| clay.fixed(@min(h, app.size[1] - 2 * height.bar)) else clay.fit() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = m.bg,
        .cornerRadius = clay.radius(if (m.shade) lay.radius.md else 0),
        .border = .{ .color = if (m.shade) theme.button_edge else theme.row_selected, .width = edges(lay.border.line) },
        .floating = .{ .zIndex = z, .attachTo = ui.CLAY_ATTACH_TO_ROOT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_CENTER_CENTER, .parent = ui.CLAY_ATTACH_POINT_CENTER_CENTER } },
    });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = space.lg + space.xs, .right = space.md, .top = space.md + space.xs, .bottom = space.xs }, .childGap = space.sm, .childAlignment = middle } });
    if (m.icon) |ic| icon(app, ic, lay.icon.lg, m.icon_color);
    txt(m.title, .heading, theme.text, bold);
    spacer();
    var hit: ModalHit = .none;
    for ([_][]const u8{ m.extra, if (m.close) tx.get(tx.close) else "" }, 0..) |label, k| {
        if (label.len == 0) continue;
        if (clickable(app, .{ .id = clay.idi(id, @intCast(k + 1)), .layout = .{ .padding = pad(space.md, space.xs) }, .backgroundColor = m.bg }, false)) hit = if (k == 0) .extra else .close;
        txt(label, .label, theme.dim, regular);
        clay.close();
    }
    clay.close();
    return hit;
}

/// A modal's body: padded, `gap` between its parts. Closed by the caller.
pub fn modalBody(gap: u16) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = space.lg + space.xs, .right = space.lg + space.xs, .top = space.sm, .bottom = space.lg }, .childGap = gap } });
}

// ---- Tables

/// A table: a framed box whose rows (`line`) put their cells in the grid's columns
/// (`cell`), the same in every row; narrow, every column shrinks alike.
pub const Table = struct {
    grid: Grid,

    /// In container `page` (its width in the last layout; `page_pad` its padding).
    pub fn open(page: Id, page_pad: f32, tracks: []const lay.Track) Table {
        const t: Table = .{ .grid = Grid.of(page, page_pad + 2 * space.md, space.sm, tracks, lay.width.page) };
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(lay.radius.md), .border = .{ .color = theme.line, .width = edges(lay.border.line) } });
        return t;
    }

    /// A row of cells (`top`: the column names'). Closed by the caller.
    pub fn line(top: bool) void {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(if (top) height.tool else height.tab) }, .padding = pad(space.md, 0), .childGap = space.sm, .childAlignment = middle }, .backgroundColor = if (top) theme.header else theme.panel, .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } } });
    }

    /// A row as tall as its cells' wrapped text. Closed by the caller.
    pub fn lineWrap() void {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fitMin(height.tab) }, .padding = pad(space.md, space.sm), .childGap = space.sm }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } } });
    }

    pub fn cell(t: *const Table, k: usize) void {
        t.grid.cell(k, space.sm);
    }

    pub fn head(t: *const Table, labels: []const []const u8) void {
        line(true);
        for (labels, 0..) |l, k| {
            t.cell(k);
            txt(l, .caption, theme.dim, regular);
            clay.close();
        }
        clay.close();
    }
};
