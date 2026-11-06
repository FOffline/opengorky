//! Clay from Zig: the C macros (CLAY, CLAY_TEXT, CLAY_ID) as functions. Strings passed
//! to `text` and `id` must live until the frame is rendered (use the frame arena).

const std = @import("std");
const ui = @import("ui");

pub const Decl = ui.Clay_ElementDeclaration;
const TextConfig = ui.Clay_TextElementConfig;
pub const Color = ui.Clay_Color;
pub const Commands = []const ui.Clay_RenderCommand;

var memory: []u8 = &.{};

/// The same radius at every corner.
pub fn radius(v: f32) ui.Clay_CornerRadius {
    return .{ .topLeft = v, .topRight = v, .bottomLeft = v, .bottomRight = v };
}

/// `font`: a font set from font.zig (`*Font` or `*Fonts(…)`), measuring text.
pub fn init(gpa: std.mem.Allocator, font: anytype, w: f32, h: f32) !void {
    memory = try gpa.alloc(u8, ui.Clay_MinMemorySize());
    const arena = ui.Clay_CreateArenaWithCapacityAndMemory(memory.len, memory.ptr);
    _ = ui.Clay_Initialize(arena, .{ .width = w, .height = h }, .{ .errorHandlerFunction = onError });
    ui.Clay_SetMeasureTextFunction(Measure(@TypeOf(font.*)).f, font);
}

pub fn deinit(gpa: std.mem.Allocator) void {
    gpa.free(memory);
}

fn onError(e: ui.Clay_ErrorData) callconv(.c) void {
    std.log.warn("clay: {s}", .{e.errorText.chars[0..@intCast(e.errorText.length)]});
}

fn Measure(comptime F: type) type {
    return struct {
        fn f(s: ui.Clay_StringSlice, cfg: [*c]ui.Clay_TextElementConfig, user: ?*anyopaque) callconv(.c) ui.Clay_Dimensions {
            const font: *F = @ptrCast(@alignCast(user.?));
            const d = font.measure(s.chars[0..@intCast(s.length)], cfg.*.fontId, cfg.*.fontSize);
            return .{ .width = d[0], .height = d[1] };
        }
    };
}

pub const Input = struct {
    size: [2]f32,
    mouse: [2]f32,
    down: bool,
    wheel: [2]f32,
    dt: f32,
};

pub fn begin(in: Input) void {
    ui.Clay_SetLayoutDimensions(.{ .width = in.size[0], .height = in.size[1] });
    ui.Clay_SetPointerState(.{ .x = in.mouse[0], .y = in.mouse[1] }, in.down);
    // The gesture's main axis only: a trackpad's vertical swipe carries a little sideways
    // motion, which a clipped label under the pointer (a long name in a list) took, so
    // the list stuck while the pointer crossed such rows.
    const wheel: [2]f32 = if (@abs(in.wheel[1]) >= @abs(in.wheel[0])) .{ 0, in.wheel[1] } else .{ in.wheel[0], 0 };
    ui.Clay_UpdateScrollContainers(false, .{ .x = wheel[0], .y = wheel[1] }, in.dt);
    dragBars(in.mouse, in.down);
    offsets_n = 0;
    for (scrolled[0..scrolled_n]) |sid| {
        const d = ui.Clay_GetScrollContainerData(sid);
        if (!d.found or d.scrollPosition == null) continue;
        offsets[offsets_n] = .{ .id = sid.id, .pos = d.scrollPosition };
        offsets_n += 1;
    }
    scrolled_n = 0;
    ui.Clay_BeginLayout();
}

// ---- Scroll bars: every scroll container with an id opened this frame shows how much
// of its content is in view and where, over the frame (render.zig bars); its thumb
// drags, a press on its track jumps there.

/// A bar's thickness and its thumb's shortest length (points).
pub const bar_thick: f32 = 6;
pub const bar_min: f32 = 24;

var scrolled: [128]ui.Clay_ElementId = undefined;
var scrolled_n: usize = 0;
/// Where Clay keeps the scroll positions of last layout's `scrolled` (its entries stay
/// put through a layout): what `openScroll*` offsets its children by.
var offsets: [128]struct { id: u32, pos: *ui.Clay_Vector2 } = undefined;
var offsets_n: usize = 0;
var was_down = false;
/// The thumb held: its container, axis and where on the thumb it was taken.
var held: ?struct { id: ui.Clay_ElementId, vertical: bool, grab: f32 } = null;
/// A press this frame went to a bar (not to what lies under it).
pub var bar_pressed = false;

/// Container `d`'s scroll offset. Clay_GetScrollOffset finds it by the element's slot in
/// the last layout, so one frame after an element was added or removed before it (a tab's
/// unsaved dot) it gave 0: the content jumped to the top for a frame. By its id instead.
fn scrollOffset(d: Decl) ui.Clay_Vector2 {
    if (d.id.id != 0) for (offsets[0..offsets_n]) |o| {
        if (o.id == d.id.id) return o.pos.*;
    };
    return ui.Clay_GetScrollOffset();
}

fn noteScroll(d: Decl) void {
    if (d.id.id == 0 or scrolled_n == scrolled.len) return;
    scrolled[scrolled_n] = d.id;
    scrolled_n += 1;
}

pub const Bar = struct { id: ui.Clay_ElementId, vertical: bool, track: ui.Clay_BoundingBox, thumb: ui.Clay_BoundingBox, held: bool };

/// Container `id`'s bar on one axis; null when all its content is in view.
fn barOf(eid: ui.Clay_ElementId, vertical: bool) ?Bar {
    const d = ui.Clay_GetScrollContainerData(eid);
    if (!d.found or d.scrollPosition == null) return null;
    const b = box(eid) orelse return null;
    const view = if (vertical) d.scrollContainerDimensions.height else d.scrollContainerDimensions.width;
    const content = if (vertical) d.contentDimensions.height else d.contentDimensions.width;
    if (!(if (vertical) d.config.vertical else d.config.horizontal) or content <= view + 1) return null;
    const track: ui.Clay_BoundingBox = if (vertical)
        .{ .x = b.x + b.width - bar_thick - 2, .y = b.y + 2, .width = bar_thick, .height = b.height - 4 }
    else
        .{ .x = b.x + 2, .y = b.y + b.height - bar_thick - 2, .width = b.width - 4, .height = bar_thick };
    const len = if (vertical) track.height else track.width;
    const t = @min(len, @max(bar_min, len * view / content));
    const off = std.math.clamp(-(if (vertical) d.scrollPosition.*.y else d.scrollPosition.*.x), 0, content - view);
    const at = (if (vertical) track.y else track.x) + off / (content - view) * (len - t);
    const thumb: ui.Clay_BoundingBox = if (vertical) .{ .x = track.x, .y = at, .width = bar_thick, .height = t } else .{ .x = at, .y = track.y, .width = t, .height = bar_thick };
    const is_held = if (held) |h| h.id.id == eid.id and h.vertical == vertical else false;
    return .{ .id = eid, .vertical = vertical, .track = track, .thumb = thumb, .held = is_held };
}

/// The bars of the containers opened in the last layout.
pub fn bars(out: []Bar) []Bar {
    var n: usize = 0;
    for (scrolled[0..scrolled_n]) |sid| for ([_]bool{ true, false }) |v| if (barOf(sid, v)) |b| if (n < out.len) {
        out[n] = b;
        n += 1;
    };
    return out[0..n];
}

fn inside(r: ui.Clay_BoundingBox, p: [2]f32) bool {
    return p[0] >= r.x and p[0] < r.x + r.width and p[1] >= r.y and p[1] < r.y + r.height;
}

/// A press on a bar takes its thumb (on the track: the thumb jumps under the pointer);
/// while held it scrolls its container with the pointer.
fn dragBars(mouse: [2]f32, down: bool) void {
    defer was_down = down;
    bar_pressed = false;
    if (!down) held = null;
    if (down and !was_down) {
        var buf: [256]Bar = undefined;
        for (bars(&buf)) |b| if (inside(b.track, mouse)) {
            const p = if (b.vertical) mouse[1] else mouse[0];
            const t0 = if (b.vertical) b.thumb.y else b.thumb.x;
            const tl = if (b.vertical) b.thumb.height else b.thumb.width;
            held = .{ .id = b.id, .vertical = b.vertical, .grab = if (inside(b.thumb, mouse)) p - t0 else tl / 2 };
            bar_pressed = true;
            break;
        };
    }
    const h = held orelse return;
    const b = barOf(h.id, h.vertical) orelse return;
    const d = ui.Clay_GetScrollContainerData(h.id);
    const view = if (h.vertical) d.scrollContainerDimensions.height else d.scrollContainerDimensions.width;
    const content = if (h.vertical) d.contentDimensions.height else d.contentDimensions.width;
    const len = if (h.vertical) b.track.height else b.track.width;
    const tl = if (h.vertical) b.thumb.height else b.thumb.width;
    const start = if (h.vertical) b.track.y else b.track.x;
    const p = (if (h.vertical) mouse[1] else mouse[0]) - h.grab - start;
    const off = std.math.clamp(p / @max(1, len - tl), 0, 1) * (content - view);
    if (h.vertical) d.scrollPosition.*.y = -off else d.scrollPosition.*.x = -off;
}

pub fn end() Commands {
    const a = ui.Clay_EndLayout();
    return a.internalArray[0..@intCast(a.length)];
}

/// Opens an element; children follow, then `close`.
pub fn open(d: Decl) void {
    ui.Clay__OpenElement();
    ui.Clay__ConfigureOpenElement(d);
}

/// Opens a vertically scrolling element (CLAY with `.clip.childOffset` its scroll offset).
pub fn openScroll(d: Decl) void {
    openScrollAxes(d, false, true);
}

/// Opens an element scrolling sideways.
pub fn openScrollX(d: Decl) void {
    openScrollAxes(d, true, false);
}

/// Opens an element scrolling both ways (a picture or grid wider than a narrow pane).
pub fn openScrollXY(d: Decl) void {
    openScrollAxes(d, true, true);
}

fn openScrollAxes(d: Decl, h: bool, v: bool) void {
    noteScroll(d);
    ui.Clay__OpenElement();
    var dd = d;
    dd.clip = .{ .horizontal = h, .vertical = v, .childOffset = scrollOffset(d) };
    ui.Clay__ConfigureOpenElement(dd);
}

/// A vertically scrolling column that never widens what holds it: clipped sideways
/// too, its children in a column as wide as its box in the last layout (minus padding),
/// so text wraps and grow children fit (in a scroll container alone they run past its
/// edge). `d` needs an id; its gap and direction go to the column. Close with
/// `closeScrollColumn`.
pub fn openScrollColumn(d: Decl) void {
    noteScroll(d);
    ui.Clay__OpenElement();
    var dd = d;
    dd.clip = .{ .vertical = true, .horizontal = true, .childOffset = .{ .x = 0, .y = scrollOffset(d).y } };
    ui.Clay__ConfigureOpenElement(dd);
    const p = d.layout.padding;
    const w = if (box(d.id)) |b| b.width - @as(f32, @floatFromInt(p.left + p.right)) else 0;
    open(.{ .layout = .{ .sizing = .{ .width = if (w > 0) fixed(w) else grow() }, .layoutDirection = d.layout.layoutDirection, .childGap = d.layout.childGap } });
}

pub fn closeScrollColumn() void {
    close();
    close();
}

pub fn close() void {
    ui.Clay__CloseElement();
}

/// A leaf element.
pub fn leaf(d: Decl) void {
    open(d);
    close();
}

pub fn text(s: []const u8, cfg: TextConfig) void {
    ui.Clay__OpenTextElement(str(s), ui.Clay__StoreTextElementConfig(cfg));
}

pub fn str(s: []const u8) ui.Clay_String {
    return .{ .length = @intCast(s.len), .chars = s.ptr };
}

pub fn id(s: []const u8) ui.Clay_ElementId {
    return ui.Clay__HashString(str(s), 0, 0);
}

pub fn idi(s: []const u8, i: u32) ui.Clay_ElementId {
    return ui.Clay__HashString(str(s), i, 0);
}

/// The element being declared is under the pointer (by last frame's layout).
pub fn hovered() bool {
    return ui.Clay_Hovered();
}

pub fn pointerOver(e: ui.Clay_ElementId) bool {
    return ui.Clay_PointerOver(e);
}

/// Bounding box of element `e` from the last layout.
pub fn box(e: ui.Clay_ElementId) ?ui.Clay_BoundingBox {
    const d = ui.Clay_GetElementData(e);
    return if (d.found) d.boundingBox else null;
}

pub fn grow() ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_GROW };
}

/// Grows to `max` at most, gives way (to its content's minimum) when there is no room.
pub fn growMax(max: f32) ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = max } } };
}

pub fn fit() ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_FIT };
}

/// Its content's size, at least `min`.
pub fn fitMin(min: f32) ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = min, .max = 0 } } };
}

pub fn fixed(v: f32) ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = v, .max = v } } };
}

pub fn rgb(hex: u24) Color {
    return .{ .r = @floatFromInt(hex >> 16), .g = @floatFromInt((hex >> 8) & 0xff), .b = @floatFromInt(hex & 0xff), .a = 255 };
}
