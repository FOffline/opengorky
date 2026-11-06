//! Texts tab: one of the game's text files (texts.zig) as a table — number, the section
//! or comment it is under, its text — every cell typed into in place (a number typed
//! moves the row), a search, a new row, a row deleted (asked first).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const texts = @import("texts.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

/// The Texts tab's state (`app.texts`): the file shown and its search.
pub const State = struct {
    file: @import("texts.zig").File = .strings,
    filter: app_mod.Name(64) = .{},
};

pub fn page(app: *App, a: Allocator) void {
    const f = app.texts.file;
    clay.openScrollColumn(.{ .id = clay.id("texts_page"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.lg), .childGap = lay.space.xs } });
    gui.pageHeader(app, .file_text, f.entry(), tx.get(switch (f) {
        .strings => tx.tx_strings_hint,
        .items => tx.tx_items_hint,
        .areas => tx.tx_areas_hint,
    }));
    if (gui.toolButton(app, "texts_new", .plus, tx.get(tx.tx_new), false, true)) newRow(app, f);
    clay.close();
    // The search: rows whose number or text has it (Enter applies).
    gui.row(lay.space.sm);
    gui.icon(app, .search, lay.icon.md, theme.dim);
    if (gui.textField(app, "texts_search", app.texts.filter.get(), lay.width.slider, tx.get(tx.tx_search))) |q| app.texts.filter.set(q);
    if (app.texts.filter.get().len > 0 and gui.toolButton(app, "texts_clear", .x, "", false, false)) app.texts.filter.set("");
    clay.close();
    const rs = texts.rows(app, a, f);
    var shown: usize = 0;
    var section: []const u8 = "";
    for (rs) |r| {
        const q = app.texts.filter.get();
        if (q.len > 0) {
            var nb: [16]u8 = undefined;
            const ids = std.fmt.bufPrint(&nb, "{d}", .{r.id}) catch "";
            if (std.ascii.findIgnoreCase(r.text, q) == null and !std.mem.eql(u8, ids, q)) continue;
        }
        shown += 1;
        if (shown > 600) break;
        // A section header where the section changes (string.tab's `//===` lines).
        if (f == .strings and !std.mem.eql(u8, r.section, section)) {
            section = r.section;
            clay.open(.{ .layout = .{ .padding = .{ .top = lay.space.sm } } });
            gui.txt(if (section.len > 0) section else "—", .body, theme.dim, font_mod.bold);
            clay.close();
        }
        row(app, a, f, r);
    }
    if (shown == 0) gui.txt(tx.get(tx.sc_none), .body, theme.dim, font_mod.regular);
    clay.closeScrollColumn();
}

fn row(app: *App, a: Allocator, f: texts.File, r: texts.Row) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_TOP } } });
    var kb: [48]u8 = undefined;
    // In this frame's memory: clay draws it after this returns.
    const ids = std.fmt.allocPrint(a, "{d}", .{r.id}) catch "";
    // The number: typed anew, the row moves to it (if free).
    if (gui.textField(app, std.fmt.bufPrint(&kb, "tx_id{d}", .{r.id}) catch "tx_id", ids, lay.width.number, "")) |v| {
        const to = std.fmt.parseInt(i32, std.mem.trim(u8, v, " "), 10) catch return clay.close();
        if (to != r.id) moveRow(app, f, r, to);
    }
    if (f != .strings and r.section.len > 0) {
        // Level with the fields' first line.
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.width.label_md) }, .padding = .{ .top = lay.space.sm } } });
        gui.txtWrap(r.section, .caption, theme.dim, font_mod.regular);
        clay.close();
    }
    if (gui.textField(app, std.fmt.bufPrint(&kb, "tx_text{d}", .{r.id}) catch "tx_text", r.text, 0, "")) |v| {
        if (!std.mem.eql(u8, v, r.text)) texts.set(app, f, r.id, v) catch |err| app.failed(err);
        app.refreshTitles();
    }
    if (gui.toolButton(app, std.fmt.bufPrint(&kb, "tx_del{d}", .{r.id}) catch "tx_del", .trash_2, "", false, false)) app.askDelete(.text_row, @intCast(r.id), f.entry());
    clay.close();
}

fn moveRow(app: *App, f: texts.File, r: texts.Row, to: i32) void {
    if (texts.get(app, app.frame.allocator(), f, to) != null) return app.setStatus(tx.st_text_taken, .{to});
    texts.set(app, f, to, r.text) catch |err| return app.failed(err);
    texts.remove(app, f, r.id) catch |err| app.failed(err);
    app.refreshTitles();
}

fn newRow(app: *App, f: texts.File) void {
    // Names past the game's numbers (its language line is 950); descriptions by the
    // item's or area's number (typed in after).
    const id = texts.freeId(app, f, if (f == .strings) 2000 else 900);
    texts.set(app, f, id, tx.get(tx.tx_new_text)) catch |err| return app.failed(err);
    app.texts.filter.set("");
    app.setStatus(tx.st_text_added, .{ f.entry(), id });
}
