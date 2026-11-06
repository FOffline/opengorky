//! The editor's layout system, as classic grid systems do it: one base unit and the
//! rules that place things by it, so the UI fits any window and UI scale (layout is in
//! points; the renderer scales points to pixels) without numbers tuned per scale.
//!
//! - Tokens: `unit` (8 points) — every padding, gap and control height is a multiple
//!   of it or of its half (`space`, `height`); text sizes are roles (`Type`); `radius`,
//!   `border`, `icon` and the few widths (`width`) that a column starts from.
//! - Rules (pure, tested here): `resolve` sizes grid columns (points, % of the
//!   container, `fr` shares, `minmax`) as CSS Grid's `grid-template-columns`; `autoFit`
//!   counts the columns of `repeat(auto-fit, minmax(min, 1fr))`; `wrap` breaks a row of
//!   items into lines (Clay rows don't wrap); `pane` sizes a pane from its share of
//!   the window.
//! - Components (widgets.zig) are built from these and the theme (app.zig); a screen
//!   is a tree of components, its containers opened with tokens. A component changes
//!   its form by its own container's width in the last layout (`clay.box`), never by
//!   the window or the UI scale. A fix to how something looks or fits goes there.

const std = @import("std");

/// The base unit, in points.
pub const unit = 8;
pub const half = unit / 2;

/// Gaps and paddings.
pub const space = struct {
    /// Inside a control: an icon to its text, a tag's padding.
    pub const xs = half;
    /// Between controls, a row's text inset.
    pub const sm = unit;
    /// A panel's padding, a label to its field.
    pub const md = unit + half;
    /// A page's padding, between a panel's groups.
    pub const lg = 2 * unit;
    /// A page's side padding, between its sections.
    pub const xl = 3 * unit;
    /// One level of a tree's indent.
    pub const indent = 2 * unit;
};

/// A right panel's blocks (widgets.block): cards on the column's background.
pub const block = struct {
    /// Between blocks, and the column's padding.
    pub const gap = space.sm;
    /// A block's body.
    pub const pad_x = space.md;
    pub const pad_y = space.sm;
    /// Between a form's rows.
    pub const row_gap = space.xs;
};

/// Heights of controls and rows.
pub const height = struct {
    /// A tick box, a switch, an inline number.
    pub const tick = 2 * unit;
    /// A small button, a compact list row.
    pub const small = 3 * unit;
    /// A button, a field, a list or form row.
    pub const control = 3 * unit + half;
    /// A toolbar button, a panel's or section's header.
    pub const tool = 4 * unit;
    /// A tab bar, a table row.
    pub const tab = 5 * unit;
    /// A page's toolbar.
    pub const bar = 5 * unit + half;
    /// A large window over the editor (capped to the window).
    pub const window = 80 * unit;
};

/// Text sizes by role (the font bakes 13, 15 and 18 points; others use the nearest).
pub const Type = enum(u16) {
    /// Counts, tags, hints, a status bar.
    caption = 12,
    /// Values, notes, most text.
    body = 13,
    /// Names in lists, form labels, buttons in menus.
    label = 14,
    /// Group titles, a selected object's name.
    title = 15,
    /// A page's or a window's title.
    heading = 18,

    pub fn pt(t: Type) u16 {
        return @backingInt(t);
    }
};

pub const radius = struct {
    pub const sm = half;
    /// Buttons, fields, panels (theme.radius before).
    pub const md = 6;
};

pub const border = struct {
    pub const line = 1;
    /// A selected tab's underline, a focus mark.
    pub const mark = 2;
    /// A pane's drag edge.
    pub const edge = half;
};

pub const icon = struct {
    /// A chevron, a tick.
    pub const sm = unit + half;
    /// In a row, a button, a field.
    pub const md = 2 * unit;
    pub const lg = 3 * unit;
    /// A page's header.
    pub const xl = 4 * unit;
};

/// The widths a column starts from (a container may give it less).
pub const width = struct {
    /// A form label's column at most: a narrow panel's, the settings', the fields'.
    pub const label_sm = 12 * unit;
    pub const label_md = 20 * unit;
    pub const label_lg = 28 * unit;
    /// Below this a form's labels go above their fields (its 40% this narrow leaves
    /// a value too little room beside it).
    pub const label_min = 15 * unit;
    /// The least a pane is given (its share of a small window can be less).
    const pane_min = 15 * unit;
    /// A small number field, a short text field.
    pub const number = 8 * unit;
    pub const field = 15 * unit;
    /// A slider, a long text field.
    pub const slider = 40 * unit;
    /// A menu, its submenus.
    pub const menu = 34 * unit;
    /// A dialog window, a large one.
    pub const dialog = 52 * unit;
    pub const window = 112 * unit;
    /// A player's time bar.
    pub const track = 30 * unit;
    /// A page's content before its first layout (a table's columns start from it).
    pub const page = 96 * unit;
};

/// Colours (RGBA) of what the editor draws itself over a view with SDL rather than
/// Clay: map markers, gizmos, the code view; Clay's colours are `theme` (app.zig).
pub const canvas = struct {
    pub const white: [4]u8 = .{ 255, 255, 255, 255 };
    pub const black: [4]u8 = .{ 0, 0, 0, 255 };
    /// Under a label drawn on a map.
    pub const label_bg: [4]u8 = .{ 0, 0, 0, 150 };
    /// Around a marker (an object, the gizmo's centre), a light's, a point's label.
    pub const marker_edge: [4]u8 = .{ 0, 0, 0, 200 };
    pub const light_edge: [4]u8 = .{ 0, 0, 0, 220 };
    pub const point_label_bg: [4]u8 = .{ 0, 0, 0, 170 };
    /// A battle object that is not placed by the battle (a label).
    pub const inactive: [4]u8 = .{ 160, 160, 160, 255 };
    /// An object that comes in later (its markers).
    pub const later: [3]u8 = .{ 150, 150, 150 };
    /// Map objects by kind (level_draw.Kind).
    pub const kind = struct {
        pub const enemy: [3]u8 = .{ 235, 70, 60 };
        pub const hero: [3]u8 = .{ 70, 140, 255 };
        pub const neutral: [3]u8 = .{ 170, 170, 170 };
        pub const prop: [3]u8 = .{ 190, 120, 255 };
        pub const item: [3]u8 = .{ 250, 200, 60 };
        pub const actor: [3]u8 = .{ 120, 220, 140 };
        pub const area: [3]u8 = .{ 80, 200, 230 };
    };
    /// A drop's spot: allowed, not.
    pub const ok: [4]u8 = .{ 80, 255, 120, 255 };
    pub const bad: [4]u8 = .{ 255, 60, 60, 255 };
    /// Walkable cells, the second floor's.
    pub const walk: [4]u8 = .{ 60, 230, 110, 90 };
    pub const walk2: [4]u8 = .{ 70, 140, 255, 90 };
    /// The battle grid: tiles, lines, the x and y numbers.
    pub const tile_free: [4]u8 = .{ 60, 255, 120, 30 };
    pub const tile_blocked: [4]u8 = .{ 255, 60, 60, 45 };
    pub const grid: [4]u8 = .{ 255, 255, 255, 50 };
    pub const grid_x: [4]u8 = .{ 255, 215, 90, 255 };
    pub const grid_y: [4]u8 = .{ 110, 220, 255, 255 };
    /// Walk paths: lines and nodes, their numbers and names, the start and end cells.
    pub const path: [3]u8 = .{ 120, 220, 255 };
    pub const path_text: [3]u8 = .{ 160, 235, 255 };
    pub const path_start: [4]u8 = .{ 90, 230, 120, 255 };
    pub const path_end: [4]u8 = .{ 255, 160, 60, 255 };
    /// Scene points.
    pub const point: [4]u8 = .{ 255, 220, 60, 255 };
    /// Level animations' frames and names.
    pub const anim: [3]u8 = .{ 255, 160, 60 };
    pub const anim_text: [4]u8 = .{ 255, 190, 120, 255 };
    /// Actors' tracks in the logic view.
    pub const trace: [4]u8 = .{ 255, 90, 200, 230 };
    pub const trace_text: [4]u8 = .{ 255, 140, 220, 255 };
    /// An area being drawn.
    pub const poly: [4]u8 = .{ 90, 200, 255, 255 };
    /// The camera gizmo: what it turns about, its rings.
    pub const aim: [4]u8 = .{ 255, 210, 60, 255 };
    pub const roll: [3]u8 = .{ 80, 140, 255 };
    pub const yaw: [3]u8 = .{ 90, 220, 90 };
    pub const pitch: [3]u8 = .{ 240, 80, 80 };
    /// A sprite's transparent pixels, its pixel grid.
    pub const checker_odd: [4]u8 = .{ 58, 58, 58, 255 };
    pub const checker_even: [4]u8 = .{ 44, 44, 44, 255 };
    pub const pixel_grid: [4]u8 = .{ 0, 0, 0, 60 };
    /// Behind a model preview.
    pub const preview_bg: [4]u8 = .{ 17, 18, 20, 255 };
    /// The scroll bars' track and thumb (idle, held).
    pub const bar_track: [4]u8 = .{ 255, 255, 255, 14 };
    pub const bar_thumb: [4]u8 = .{ 255, 255, 255, 70 };
    pub const bar_held: [4]u8 = .{ 255, 255, 255, 150 };
    /// The code view: syntax, gutter, line marks, popups.
    pub const code = struct {
        pub const plain: [4]u8 = .{ 220, 223, 228, 255 };
        pub const keyword: [4]u8 = .{ 198, 120, 221, 255 };
        pub const call: [4]u8 = .{ 97, 175, 239, 255 };
        pub const string: [4]u8 = .{ 152, 195, 121, 255 };
        pub const number: [4]u8 = .{ 209, 154, 102, 255 };
        pub const comment: [4]u8 = .{ 110, 118, 129, 255 };
        pub const directive: [4]u8 = .{ 229, 192, 123, 255 };
        /// An OG Script path (`looks::medusa_2`), a field given a value (`hp = 120`).
        pub const path: [4]u8 = .{ 86, 182, 194, 255 };
        pub const field: [4]u8 = .{ 224, 108, 117, 255 };
        pub const line_no: [4]u8 = .{ 90, 96, 106, 255 };
        pub const err_line: [4]u8 = .{ 160, 40, 40, 90 };
        pub const unknown: [4]u8 = .{ 200, 140, 30, 60 };
        /// The selection (alpha 110), the popup's frame and its picked row (200).
        pub const accent: [4]u8 = .{ 59, 91, 219, 255 };
        pub const match: [4]u8 = .{ 230, 170, 40, 70 };
        pub const bracket: [4]u8 = .{ 150, 160, 180, 160 };
        pub const cursor: [4]u8 = .{ 240, 240, 240, 255 };
        pub const popup_bg: [4]u8 = .{ 43, 45, 49, 250 };
        pub const popup_text: [4]u8 = .{ 230, 232, 236, 255 };
        /// A hint box (alpha 245 over the code, 250 beside the popup), its frame.
        pub const tip_bg: [4]u8 = .{ 30, 31, 34, 250 };
        pub const tip_edge: [4]u8 = .{ 70, 74, 82, 255 };
        /// The argument at the cursor, a description.
        pub const tip_cur: [4]u8 = .{ 255, 215, 90, 255 };
        pub const tip_desc: [4]u8 = .{ 150, 156, 166, 255 };
        /// A problem's wavy underline; a link's underline (Cmd/Ctrl held).
        pub const squiggle: [4]u8 = .{ 230, 170, 40, 255 };
        pub const link: [4]u8 = .{ 97, 175, 239, 255 };
    };

    /// `col` with alpha `a`.
    pub fn alpha(col: anytype, a: u8) [4]u8 {
        return .{ col[0], col[1], col[2], a };
    }
};

/// A length: points, or a share (0…1) of the container.
const Len = union(enum) {
    pt: f32,
    pct: f32,

    fn of(l: Len, w: f32) f32 {
        return switch (l) {
            .pt => |v| v,
            .pct => |v| v * w,
        };
    }
};

/// A grid column: a fixed length, a share of what is left (`fr`), or `minmax`.
pub const Track = union(enum) {
    len: Len,
    fr: f32,
    minmax: struct { min: Len, max: Len },
};

/// Column widths for `tracks` in a container `w` wide with `gap` between columns, as
/// CSS Grid: lengths first, `minmax` grown from its min toward its max with the room
/// left, then `fr` shares of the rest. When the minimums don't fit, every column
/// shrinks alike (a narrow pane keeps its columns aligned rather than overflowing).
pub fn resolve(w: f32, gap: f32, tracks: []const Track, out: []f32) void {
    std.debug.assert(out.len >= tracks.len);
    const avail = @max(0, w - gap * @as(f32, @floatFromInt(tracks.len -| 1)));
    var used: f32 = 0;
    var grow: f32 = 0;
    var frs: f32 = 0;
    for (tracks, 0..) |t, k| {
        out[k] = switch (t) {
            .len => |l| l.of(avail),
            .fr => 0,
            .minmax => |m| m.min.of(avail),
        };
        used += out[k];
        switch (t) {
            .minmax => |m| grow += @max(0, m.max.of(avail) - out[k]),
            .fr => |f| frs += f,
            .len => {},
        }
    }
    if (used > avail) {
        const k = if (used > 0) avail / used else 0;
        for (out[0..tracks.len]) |*o| o.* *= k;
        return;
    }
    var free = avail - used;
    const g = if (grow > 0) @min(1, free / grow) else 0;
    for (tracks, 0..) |t, k| if (t == .minmax) {
        const d = @max(0, t.minmax.max.of(avail) - out[k]) * g;
        out[k] += d;
        free -= d;
    };
    if (frs > 0) for (tracks, 0..) |t, k| if (t == .fr) {
        out[k] = free * t.fr / frs;
    };
}

/// The columns of `repeat(auto-fit, minmax(min, 1fr))` in `w`: as many as fit, at least one.
pub fn autoFit(w: f32, gap: f32, min: f32) usize {
    if (min <= 0) return 1;
    return @max(1, @as(usize, @intFromFloat(@floor((w + gap) / (min + gap)))));
}

/// Breaks items `widths` wide into lines `w` wide (`gap` between items), greedily:
/// `line[k]` gets item k's line; returns the number of lines. An item wider than the
/// line has a line of its own.
pub fn wrap(widths: []const f32, gap: f32, w: f32, line: []u8) usize {
    std.debug.assert(line.len >= widths.len);
    var n: u8 = 0;
    var x: f32 = 0;
    for (widths, 0..) |iw, k| {
        if (k > 0 and x + gap + iw > w) {
            n += 1;
            x = iw;
        } else x += if (k > 0) gap + iw else iw;
        line[k] = n;
    }
    return if (widths.len == 0) 0 else n + 1;
}

/// A pane's size: its share `frac` of `room`, at least `width.pane_min` (unless the
/// room is smaller) and at most `max` of it, so the panes beside it keep theirs.
pub fn pane(room: f32, frac: f32, max: f32) f32 {
    const lo = @min(width.pane_min, room);
    return std.math.clamp(frac * room, lo, @max(lo, room * max));
}

/// A form label's width in a form `w` wide: 40% of it, at most `cap`; null when even
/// that is narrower than `width.label_min` (the labels go above their fields).
pub fn labelWidth(w: f32, cap: f32) ?f32 {
    const l = @round(w * 0.4);
    return if (l < width.label_min) null else @min(cap, l);
}

test resolve {
    var out: [3]f32 = undefined;
    // minmax(30%, 40%) 1fr: the label takes its max, the value the rest.
    resolve(500, 0, &.{ .{ .minmax = .{ .min = .{ .pct = 0.3 }, .max = .{ .pct = 0.4 } } }, .{ .fr = 1 } }, out[0..2]);
    try std.testing.expectEqual(200, out[0]);
    try std.testing.expectEqual(300, out[1]);
    // Lengths, then fr shares of what is left after the gaps.
    resolve(420, 10, &.{ .{ .fr = 1 }, .{ .len = .{ .pt = 100 } }, .{ .fr = 3 } }, &out);
    try std.testing.expectEqual(75, out[0]);
    try std.testing.expectEqual(100, out[1]);
    try std.testing.expectEqual(225, out[2]);
    // minmax grows toward its max only as far as the room goes.
    resolve(150, 0, &.{ .{ .minmax = .{ .min = .{ .pt = 100 }, .max = .{ .pt = 300 } } }, .{ .len = .{ .pt = 30 } } }, out[0..2]);
    try std.testing.expectEqual(120, out[0]);
    // Too narrow for the minimums: all shrink alike.
    resolve(100, 0, &.{ .{ .len = .{ .pt = 150 } }, .{ .len = .{ .pt = 50 } } }, out[0..2]);
    try std.testing.expectEqual(75, out[0]);
    try std.testing.expectEqual(25, out[1]);
}

test autoFit {
    try std.testing.expectEqual(3, autoFit(320, 8, 96));
    try std.testing.expectEqual(1, autoFit(50, 8, 96));
    try std.testing.expectEqual(2, autoFit(200, 8, 96));
}

test wrap {
    var line: [4]u8 = undefined;
    try std.testing.expectEqual(1, wrap(&.{ 50, 50, 50 }, 10, 170, &line));
    try std.testing.expectEqual(2, wrap(&.{ 50, 50, 50 }, 10, 160, &line));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1 }, line[0..3]);
    // Wider than the line: alone on its own.
    try std.testing.expectEqual(3, wrap(&.{ 30, 200, 30 }, 10, 100, &line));
    try std.testing.expectEqual(0, wrap(&.{}, 10, 100, &line));
}

test pane {
    try std.testing.expectEqual(280, pane(1400, 0.2, 0.5));
    // A small window: the least a pane gets, never past the room.
    try std.testing.expectEqual(120, pane(400, 0.2, 0.5));
    try std.testing.expectEqual(100, pane(100, 0.2, 0.5));
    // Dragged too wide: kept to its max share.
    try std.testing.expectEqual(700, pane(1400, 0.9, 0.5));
}

test labelWidth {
    try std.testing.expectEqual(224, labelWidth(800, width.label_lg).?);
    try std.testing.expectEqual(120, labelWidth(300, width.label_lg).?);
    try std.testing.expect(labelWidth(250, width.label_lg) == null);
    // A narrow cap still has its labels beside the values while the form is wide enough.
    try std.testing.expectEqual(width.label_sm, labelWidth(400, width.label_sm).?);
}
