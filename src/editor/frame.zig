//! A page's frame: the stage in the centre (the document as it looks, with its controls)
//! and the constructor on the right (gui.propsPanel: its blocks, what it picks and
//! attaches, where it is used). A page opens the stage, draws it, then the constructor
//! (`props`) and closes that with gui.propsEnd.

const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const App = @import("app.zig").App;

/// What the asset tree and the constructor leave of the window, and their edges.
pub fn width(app: *const App) f32 {
    return @max(0, app.size[0] - app.pane(.levels) - app.pane(.objects) - 2 * lay.border.edge);
}

/// The stage opened: a column of `width`, as a bound rather than a clip (a clip doesn't
/// squeeze its content, a note would stop wrapping; unbounded, what can't shrink would
/// push the constructor off the window). Closed by `props`.
pub fn stage(app: *const App) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(width(app)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
}

/// The stage closed, the constructor `id` opened beside it.
pub fn props(app: *App, id: []const u8) void {
    clay.close();
    gui.propsPanel(app, id);
}
