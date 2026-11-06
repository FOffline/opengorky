//! The Settings tab.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const settings_mod = @import("settings.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const play = @import("play.zig");
const theme = app_mod.theme;

/// The Settings tab: language, UI scale, the project's format, the game folder, the
/// viewer, the settings file and what the folder holds.
pub fn settingsPage(app: *App, a: Allocator) void {
    // Scrolled, its rows as wide as the page (a large UI scale leaves few points).
    const pid = clay.id("settings_page");
    clay.openScrollColumn(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.md), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.form(pid, lay.width.label_md, lay.space.xl + lay.block.pad_x);
    if (gui.block(app, "set_ui", tx.get(tx.s_sec_ui), .{})) {
        gui.fieldRow(tx.get(tx.s_language));
        for (tx.langs, 0..) |l, k| {
            const sel = tx.lang == l.lang;
            if (gui.buttonOf(app, clay.idi("lang", @intCast(k)), .{ .label = l.name, .style = .quiet, .on = sel, .color = if (sel) theme.text else theme.dim })) app.setLang(l.lang);
        }
        clay.close();
        gui.fieldRow(tx.get(tx.s_ui_scale));
        // Applied on release: the panes resize with it, so not under the pointer while dragged.
        const lo = settings_mod.ui_scale_min;
        const hi = settings_mod.ui_scale_max;
        const shown = app.scale_drag orelse app.settings.ui_scale;
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.growMax(lay.width.slider) } } });
        if (gui.slider(app, "ui_scale", (shown - lo) / (hi - lo))) |v| app.scale_drag = @round((lo + v * (hi - lo)) * 20) / 20;
        clay.close();
        gui.txt(std.fmt.allocPrint(a, "{d}%", .{@round(shown * 100)}) catch "", .label, theme.text, font_mod.bold);
        if (app.scale_drag) |v| if (app.slider_drag == null) {
            app.scale_drag = null;
            app.settings.ui_scale = v;
            app.saveSettings();
        };
        if (shown != 1 and gui.smallButton(app, clay.id("ui_scale_reset"), "100%")) {
            app.settings.ui_scale = 1;
            app.saveSettings();
        }
        clay.close();
        gui.blockEnd();
    }
    if (gui.block(app, "set_project", tx.get(tx.s_sec_project), .{})) {
        // The project's format (its manifest), not a setting.
        gui.fieldRow(tx.get(tx.s_target));
        const port = app.project.format == .ogs;
        gui.txt(tx.get(if (port) tx.s_format_og else tx.s_format_classic), .label, if (port) theme.warn else theme.text, font_mod.bold);
        // Classic converts into a new folder, one way (projconvert.zig).
        gui.spacer();
        if (!port and app.game_dir.len > 0) if (gui.smallButton(app, clay.id("convert_og"), tx.get(tx.s_convert))) @import("projconvert.zig").ask(app);
        clay.close();
        gui.fieldNote(tx.get(if (port) tx.s_target_port_warn else tx.s_target_hint), if (port) theme.warn else theme.dim);
        gui.fieldRow(tx.get(tx.s_game));
        gui.txtClip(if (app.game_dir.len > 0) app.game_dir else tx.get(tx.s_no_game), .label, if (app.game_dir.len > 0) theme.text else theme.warn, font_mod.regular);
        gui.spacer();
        if (gui.smallButton(app, clay.id("pick_game"), tx.get(tx.s_pick_game))) app.askGame();
        clay.close();
        gui.fieldNote(tx.get(if (port) tx.s_game_og_hint else tx.s_game_hint), theme.warn);
        gui.fieldNote(tx.get(if (port) tx.s_build_pkg_hint else tx.s_package_hint), theme.warn);
        if (!port) if (gui.footer(app, "package_mod", &.{tx.get(tx.s_package)}, null) != null) app.askFile(.{ .kind = .folder, .run = App.onPackage });
        // OpenGorky: the package for players, and where it is.
        if (port) {
            const built = play.packageBuilt(app);
            const labels: []const []const u8 = if (built) &.{ tx.get(tx.s_build_pkg), tx.get(tx.s_reveal_pkg) } else &.{tx.get(tx.s_build_pkg)};
            if (gui.footer(app, "build_pkg", labels, null)) |k| if (k == 0) play.buildPackage(app) else play.revealPackage(app);
        }
        gui.blockEnd();
    }
    if (gui.block(app, "set_port", tx.get(tx.s_sec_port), .{})) {
        gui.fieldRow(tx.get(tx.s_viewer));
        const viewer = app.settings.viewerPath();
        // Found beside the editor: shown (dim) too, so Play's program is plain.
        var vb: [1200]u8 = undefined;
        // (A copy in the frame: the text is drawn after this returns.)
        const near = if (viewer == null) if (play.nearViewer(app, &vb)) |p| a.dupe(u8, p) catch null else null else null;
        gui.txtClip(viewer orelse near orelse tx.get(tx.s_viewer_auto), .label, if (viewer != null) theme.text else theme.dim, font_mod.regular);
        gui.spacer();
        if (gui.smallButton(app, clay.id("pick_viewer"), tx.get(tx.s_pick_viewer))) app.askFile(.{ .kind = .program, .run = play.onViewer });
        if (viewer != null) if (gui.smallButton(app, clay.id("viewer_auto"), tx.get(tx.s_viewer_clear))) {
            app.settings.setViewerPath("");
            app.saveSettings();
        };
        clay.close();
        gui.fieldNote(tx.get(tx.s_viewer_hint), theme.warn);
        gui.blockEnd();
    }
    if (gui.block(app, "set_about", tx.get(tx.s_sec_about), .{})) {
        gui.fieldRow(tx.get(tx.s_file));
        gui.txtClip(app.settings_path orelse tx.get(tx.s_no_file), .label, theme.text, font_mod.regular);
        clay.close();
        var battles: usize = 0;
        for (app.levels) |e| battles += @intFromBool(e.battle);
        gui.fieldRow(tx.get(tx.s_levels));
        gui.txtClip(tx.alloc(a, tx.s_levels_n, .{ battles, app.levels.len - battles, app.templates.len }), .label, theme.text, font_mod.regular);
        clay.close();
        gui.blockEnd();
    }
    clay.closeScrollColumn();
}
