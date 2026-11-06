//! Mod check window (run by every save; opens itself when there are problems, the
//! status bar opens it again): what the original exe would stumble on in the game
//! folder as saved — `og.modcheck`; in an OpenGorky project what the port would, against
//! its limits. A script's row opens it. An OpenGorky project of OG Script: the build's
//! problems instead (compose/og/build.zig, «Play»: `file:line` and why).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const Video = @import("viewer").Video;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const doctabs = @import("doctabs.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

/// The check's result, shown until closed.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    problems: []og.modcheck.Problem = &.{},
    /// Unsaved edits when it ran (they aren't on disk, so not checked).
    unsaved: bool,
    failed: ?anyerror = null,
    /// The window is open (closed, the status bar still counts the problems).
    shown: bool = true,
    /// The OG build's problems (play.zig), not the mod check's: «again» builds again.
    build: bool = false,
};

/// The OG build's `problems` shown (each row `file:line`, its message; a warning says so).
pub fn showBuild(app: *App, problems: []const og.compose.og_build.Problem) void {
    close(app);
    const r = app.gpa.create(Result) catch return;
    r.* = .{ .arena = .init(app.gpa), .unsaved = false, .build = true };
    app.check = r;
    const a = r.arena.allocator();
    const list = a.alloc(og.modcheck.Problem, problems.len) catch return;
    for (list, problems) |*o, p| o.* = .{
        .archive = if (p.line > 0) std.fmt.allocPrint(a, "{s}:{d}", .{ p.file, p.line }) catch p.file else a.dupe(u8, p.file) catch "",
        .entry = "",
        .what = if (p.warning) tx.alloc(a, tx.bd_warning, .{p.message}) else a.dupe(u8, p.message) catch "",
    };
    r.problems = list;
}

/// Runs the check on the game folder (the saved state).
pub fn run(app: *App) void {
    close(app);
    const r = app.gpa.create(Result) catch return;
    r.* = .{ .arena = .init(app.gpa), .unsaved = app.store.dirty() };
    r.problems = og.modcheck.run(app.io, r.arena.allocator(), app.dat) catch |err| blk: {
        r.failed = err;
        break :blk &.{};
    };
    r.shown = r.failed != null or r.problems.len > 0;
    app.check = r;
}

pub fn close(app: *App) void {
    const r = app.check orelse return;
    r.arena.deinit();
    app.gpa.destroy(r);
    app.check = null;
}

pub fn panel(app: *App, a: Allocator, r: *Result) void {
    const hit = gui.modal(app, "checkpanel", .{ .h = lay.height.window, .bg = theme.bg, .title = if (r.build) tx.alloc(a, tx.bd_title, .{r.problems.len}) else tx.alloc(a, tx.ck_title, .{r.problems.len}), .extra = tx.get(tx.ck_again) });
    const rerun = hit == .extra;
    const shut = hit == .close;
    clay.openScroll(.{ .id = clay.id("check_body"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = lay.space.lg, .right = lay.space.lg, .bottom = lay.space.lg }, .childGap = lay.space.sm } });
    if (r.unsaved) gui.txtWrap(tx.get(tx.ck_unsaved), .body, theme.warn, font_mod.regular);
    if (r.failed) |err| gui.txtWrap(tx.alloc(a, tx.ck_failed, .{err}), .body, theme.warn, font_mod.regular);
    if (r.failed == null and r.problems.len == 0) gui.txtWrap(tx.get(if (app.ogLayout()) tx.ck_ok_og else tx.ck_ok), .label, theme.text, font_mod.regular);
    var open_at: ?usize = null;
    for (r.problems, 0..) |p, k| {
        const rid = clay.idi("check_row", @intCast(k));
        const script = og.formats.resource.isScript(p.entry);
        clay.open(.{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.sm, lay.space.xs) }, .backgroundColor = if (script and clay.pointerOver(rid)) theme.row_hover else theme.panel, .cornerRadius = clay.radius(lay.radius.md) });
        if (script and clay.hovered() and app.clicked) open_at = k;
        gui.txt(if (p.entry.len > 0) std.fmt.allocPrint(a, "{s}: {s}", .{ p.archive, p.entry }) catch p.archive else p.archive, .body, if (script) theme.accent_hover else theme.text, font_mod.bold);
        gui.txtWrap(p.what, .body, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    clay.close();
    // After the layout: these replace or drop `r`.
    if (open_at) |k| {
        const p = r.problems[k];
        if (app.store.file(p.archive, p.entry)) |f| {
            r.shown = false;
            doctabs.showCode(app, f, null);
        } else |err| app.setStatus(tx.st_import_failed, .{err});
    } else if (rerun) {
        if (r.build) @import("play.zig").rebuild(app) else run(app);
    } else if (shut) {
        r.shown = false;
    }
}
