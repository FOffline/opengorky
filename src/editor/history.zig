//! The history: the History tab (every edit of the session, the saves of earlier ones,
//! going back to any of them).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const savelog = @import("savelog.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

/// History tab: every edit of the session, newest first, the last save marked, then
/// the saves of earlier sessions and the original. A click on a row shows what it
/// changed (nothing changes); "Return to this point" goes back to it.
pub fn historyPage(app: *App, a: Allocator) void {
    gui.sidePanel(app.pane(.history), .{ .edge = .none });
    gui.panelHeader(tx.alloc(a, tx.history_n_title, .{app.store.undo.items.len}));
    clay.openScroll(.{ .id = clay.id("history_list"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    historyRows(app, a);
    clay.close();
    clay.close();
    app.splitter(.history, false, 1, 0);

    // The picked row: what it changed, and going back to it.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = lay.space.xl, .right = lay.space.xl, .top = lay.space.lg }, .childGap = lay.space.md } });
    const past = pastSteps(app);
    var diff: []const u8 = "";
    switch (historyPick(app)) {
        .none => gui.txtWrap(tx.get(tx.history_pick), .label, theme.dim, font_mod.regular),
        .session => |k| if (k > 0) {
            gui.txt(std.fmt.allocPrint(a, "{d}. {s}", .{ k, tx.label(app.store.undo.items[k - 1].label) }) catch "", .heading, theme.text, font_mod.bold);
            if (k <= app.store.saved_at) gui.txt(tx.get(tx.history_was_saved), .caption, theme.accent_hover, font_mod.regular);
            diff = app.store.stepDiff(k - 1);
        } else historyOriginal(),
        .past => |j| if (j > 0) {
            gui.txt(std.fmt.allocPrint(a, "{s} · {s}", .{ dateText(a, past[j - 1].time), tx.label(past[j - 1].label) }) catch "", .heading, theme.text, font_mod.bold);
            diff = past[j - 1].diff;
        } else historyOriginal(),
    }
    historyReturn(app, a);
    if (diff.len > 0) {
        clay.openScroll(.{ .id = clay.id("history_diff"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.viewport });
        // What the step changed: lines gone in red, new ones in green.
        var lines = std.mem.splitScalar(u8, diff, '\n');
        var n: usize = 0;
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            n += 1;
            if (n > 400) break;
            const col = if (l[0] == '-') theme.removed else theme.added;
            clay.open(.{ .layout = .{ .padding = gui.pad(lay.space.md, 0) } });
            gui.txt(std.fmt.allocPrint(a, "{c} {s}", .{ l[0], std.mem.replaceOwned(u8, a, l[1..], "\t", "    ") catch l[1..] }) catch l, .body, col, font_mod.regular);
            clay.close();
        }
        clay.close();
    }
    clay.close();
}

fn historyOriginal() void {
    gui.txt(tx.get(tx.history_original), .heading, theme.text, font_mod.bold);
    gui.txtWrap(tx.get(tx.history_original_info), .body, theme.dim, font_mod.regular);
}

/// The saves of earlier sessions, oldest first.
fn pastSteps(app: *const App) []const savelog.Step {
    return if (app.store.past) |p| p.steps else &.{};
}

/// The row picked: a step of this session (1-based; 0: the original when no earlier
/// session saved), a save of an earlier one (1-based; 0: the original).
pub const Pick = union(enum) {
    none,
    session: usize,
    past: usize,

    fn is(p: Pick, q: Pick) bool {
        return std.meta.eql(p, q);
    }
};

/// `app.history_pick` while its row is still there.
fn historyPick(app: *const App) Pick {
    return switch (app.history_pick) {
        .none => .none,
        .session => |k| if (k <= app.store.undo.items.len) app.history_pick else .none,
        .past => |j| if (j <= pastSteps(app).len) app.history_pick else .none,
    };
}

/// "2026-10-26 14:03 UTC" for unix time `secs`.
fn dateText(a: Allocator, secs: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, secs)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
}

/// The steps, newest first, with where the last save was, then the earlier sessions'
/// saves and the original; a click picks one.
fn historyRows(app: *App, a: Allocator) void {
    var buf: [512][]const u8 = undefined;
    const labels = app.store.labels(&buf);
    const skipped = app.store.undo.items.len - labels.len;
    const past = pastSteps(app);
    if (labels.len == 0 and past.len == 0) {
        return gui.listNote(tx.get(tx.history_empty));
    }
    var k = labels.len;
    while (k > 0) {
        k -= 1;
        const step = skipped + k + 1;
        // The last save between the steps after it and those before.
        if (step == app.store.saved_at and step < app.store.undo.items.len) gui.listMark(tx.get(tx.history_saved), theme.accent_hover);
        if (historyRow(app, clay.idi("history", @intCast(step)), std.fmt.allocPrint(a, "{d}", .{step}) catch "", tx.label(labels[k]), app.history_pick.is(.{ .session = step }))) app.history_pick = .{ .session = step };
    }
    if (past.len > 0) gui.listMark(tx.get(tx.history_earlier), theme.dim);
    var j = past.len;
    while (j > 0) : (j -= 1) if (historyRow(app, clay.idi("history_old", @intCast(j)), dateText(a, past[j - 1].time), tx.label(past[j - 1].label), app.history_pick.is(.{ .past = j }))) {
        app.history_pick = .{ .past = j };
    };
    // The original: before the earliest save kept, else as the editor opened the files.
    const orig: Pick = if (past.len > 0) .{ .past = 0 } else .{ .session = 0 };
    if (historyRow(app, clay.id("history_original"), "", tx.get(tx.history_original), app.history_pick.is(orig))) app.history_pick = orig;
}

/// One row: its number or date, its label; true when clicked.
fn historyRow(app: *App, rid: ui.Clay_ElementId, num: []const u8, label: []const u8, sel: bool) bool {
    const hit = gui.listRow(app, rid, .{ .selected = sel, .indent = lay.space.md, .rounded = false });
    if (num.len > 0) gui.txt(num, .caption, if (sel) theme.text else theme.dim, font_mod.regular);
    gui.txt(label, .body, theme.text, if (sel) font_mod.bold else font_mod.regular);
    clay.close();
    return hit;
}

/// What returning to the picked row does, and the button that does it (none: the
/// files are as it left them).
fn historyReturn(app: *App, a: Allocator) void {
    const n = app.store.undo.items.len;
    const past = pastSteps(app).len;
    const pick = historyPick(app);
    const info = switch (pick) {
        .none => return,
        .session => |k| if (k == n) null else tx.alloc(a, tx.history_back_session, .{n - k}),
        .past => |j| if (j == past and n == 0) null else tx.get(tx.history_back_past),
    };
    if (pick == .past and info != null and n > 0) gui.txtWrap(tx.alloc(a, tx.history_back_past_n, .{n}), .body, theme.text, font_mod.regular);
    gui.txtWrap(info orelse tx.get(tx.history_here), .body, if (info == null) theme.dim else theme.text, font_mod.regular);
    if (info == null) return;
    // Done at the next frame's start: it rewrites what this frame's layout points into.
    if (gui.toolButton(app, "history_return", .undo_2, tx.get(tx.history_return), false, true)) app.history_go = true;
}

/// The step picked in History returned to (asked for by its button last frame).
pub fn historyGo(app: *App) void {
    const past = pastSteps(app).len;
    switch (historyPick(app)) {
        .none => {},
        .session => |k| app.rollBack(k),
        .past => |j| if (j == past) app.rollBack(0) else app.returnToPast(j),
    }
    app.history_pick = .none;
}
