//! Level editing's side panel and toolbar (paint.zig is the canvas): the layers block,
//! the chosen tool's block, the tools over the view, the layer PNG out and in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const newlevel = @import("newlevel.zig");
const common_archive = @import("store.zig").common_archive;
const paint = @import("paint.zig");
const Paint = paint.Paint;
const Layer = paint.Layer;
const Tool = paint.Tool;
const changed = paint.changed;
const has = paint.hasLayer;
const brushPixels = paint.brushPixels;
const fitDepth = paint.fitDepth;
const importLayer = paint.importLayer;
const exportLayer = paint.exportLayer;
const pointsPanel = @import("paint_points.zig").pointsPanel;
const lightsPanel = @import("paint_lights.zig").lightsPanel;
const exitPanel = @import("paint_areas.zig").exitPanel;
const areaPanel = @import("paint_areas.zig").areaPanel;
const backgroundCfg = @import("paint_camera.zig").backgroundCfg;
const gridPanel = @import("paint_camera.zig").gridPanel;
const cameraPanel = @import("paint_camera.zig").cameraPanel;
const stepper = gui.stepper;

/// The right-hand panel of the mode: the layers block, the tool's block (its setting,
/// its actions in its footer), the picked enemy's values.
pub fn panel(app: *App, a: Allocator, p: *Paint) void {
    gui.sidePanel(app.pane(.objects), .{});
    // Everything scrolls (a battle's grid and camera are taller than a window).
    @import("levelpanel.zig").blockColumn("lp_scroll");
    const names = [_]tx.Msg{ tx.lp_picture, tx.lp_depth, tx.lp_walk, tx.lp_walk2, tx.lp_grid };
    const layers = [_]Layer{ .picture, .depth, .walk, .walk2, .grid };
    if (gui.block(app, "lp_layers", tx.get(tx.lp_title), .{ .summary = for (layers, names) |l, n| {
        if (l == p.layer) break tx.get(n);
    } else "" })) {
        for (layers, 0..) |l, k| {
            if (!has(p, l)) continue;
            const r = layerRow(app, @intCast(k), tx.get(names[k]), p.show[k], p.locked[k], p.layer == l, changed(p, l));
            if (r.eye) p.show[k] = !p.show[k] else if (r.lock) p.locked[k] = !p.locked[k] else if (r.row) {
                p.layer = l;
                p.show[k] = true;
            }
        }
        // The level's objects: shown or not, never painted.
        if (layerRow(app, 9, tx.get(tx.lp_objects), p.show_objects, null, false, false).any()) p.show_objects = !p.show_objects;
        if (p.jpg) gui.note(tx.get(tx.lp_jpg));
        actorScaleRow(app, a);
        if (p.layer == .depth) backgroundCfg(app, a);
        gui.blockEnd();
    }
    if (gui.block(app, "lp_tool", tx.get(switch (p.tool) {
        .objects => tx.lp_objects_tool,
        .move => tx.lp_move,
        .brush => tx.lp_brush,
        .picker => tx.spr_picker,
        .light => tx.lp_lights,
        .area => tx.lp_area,
        .exit => tx.lp_exit,
        .points => tx.lp_points,
        .paths => tx.lp_paths,
        .camera => tx.lp_cam_tool,
    }), .{})) {
        toolBody(app, a, p);
        gui.blockEnd();
    }
    if (p.tool == .objects) @import("levelpanel.zig").paramsBlock(app, a);
    clay.closeScrollColumn();
    clay.close();
}

/// The tool block's body: its description, its settings, its actions in the footer.
fn toolBody(app: *App, a: Allocator, p: *Paint) void {
    // Painting's description first (the brush, the hand and the eyedropper share it).
    const painting = p.tool == .move or p.tool == .brush or p.tool == .picker;
    if (painting) gui.note(tx.get(tx.lp_hint));
    switch (p.tool) {
        .objects => @import("levelpanel.zig").objectsBlock(app, a),
        .points => pointsPanel(app, a, p),
        .paths => if (app.doc) |d| @import("paths.zig").panel(app, a, d),
        .light => lightsPanel(app, a, p),
        .camera => {
            gui.note(tx.get(tx.lp_cam_tool_hint));
            cameraPanel(app, a, p, false);
        },
        .exit => exitPanel(app, a, p),
        .area => {
            gui.note(tx.get(tx.lp_area_hint));
            if (p.poly.items.len >= 3 and gui.footer(app, "lp_area_done", &.{tx.get(tx.lp_area_done)}, 0) != null) p.pending = .finish;
        },
        .move, .brush, .picker => {
            if (p.tool != .move) {
                gui.fieldRow(tx.get(tx.lp_brush_size));
                if (gui.buttonOf(app, clay.id("lp_smaller"), .{ .label = "-", .size = .small })) p.size = @max(1, p.size / 2);
                if (gui.numberField(app, a, "lp_size_box", "px", brushPixels(p), lay.width.number)) |v| p.size = @intFromFloat(std.math.clamp(@round(v), 1, 256));
                if (gui.buttonOf(app, clay.id("lp_bigger"), .{ .label = "+", .size = .small })) p.size = @min(256, p.size * 2);
                clay.close();
            }
            layerSettings(app, a, p);
        },
    }
    if (p.area_len > 0) areaPanel(app, a, p);
    // The layer's PNG out / in: with the painting tools.
    if (painting and (p.layer == .picture or p.layer == .depth)) if (gui.footer(app, "lp_png", &.{ tx.get(tx.spr_to_png), tx.get(tx.spr_from_png) }, null)) |k| {
        const d = app.doc;
        const lname = if (d) |dd| (if (p.layer == .depth) std.fmt.allocPrint(app.frame.allocator(), "{s}_depth", .{dd.name}) catch dd.name else dd.name) else "";
        if (k == 0) app.askFile(.{ .kind = .png_out, .run = onLayerOut, .entry = @backingInt(p.layer), .name = lname }) else app.askFile(.{ .kind = .png, .run = onLayerIn, .entry = @backingInt(p.layer) });
    };
}

/// A painting tool's settings for the layer painted.
fn layerSettings(app: *App, a: Allocator, p: *Paint) void {
    switch (p.layer) {
        .picture => {
            gui.fieldRow(tx.get(tx.lp_color));
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.control), .height = clay.fixed(lay.height.small) } }, .backgroundColor = .{ .r = @floatFromInt(p.color[0]), .g = @floatFromInt(p.color[1]), .b = @floatFromInt(p.color[2]), .a = 255 }, .cornerRadius = clay.radius(lay.radius.sm) });
            clay.close();
        },
        .depth => {
            gui.fieldRow(tx.get(tx.lp_depth_label));
            if (gui.buttonOf(app, clay.id("lp_d_m"), .{ .label = "-8", .size = .small })) p.depth_value -|= 8;
            gui.txt(tx.alloc(a, tx.lp_depth_row, .{p.depth_value}), .body, theme.text, font_mod.regular);
            if (gui.buttonOf(app, clay.id("lp_d_p"), .{ .label = "+8", .size = .small })) p.depth_value +|= 8;
            clay.close();
            gui.fieldNote(tx.get(tx.lp_depth_fit_hint), theme.dim);
            if (gui.footer(app, "lp_depth_fit", &.{tx.get(tx.lp_depth_fit)}, null) != null) if (app.doc) |d| {
                if (fitDepth(app, p, d)) |before| app.setStatus(tx.st_depth_fit, .{before}) else |err| app.failed(err);
            };
        },
        .walk, .walk2 => {
            // As the concept's: the brush mode as two halves, the overlay's opacity.
            gui.fieldRow(tx.get(tx.lp_brush_mode));
            if (gui.segmented(app, "lp_mode", &.{ tx.get(tx.lp_walk_on), tx.get(tx.lp_walk_off) }, if (p.walk_on) 0 else 1)) |k| p.walk_on = k == 0;
            clay.close();
            gui.fieldRow(tx.get(tx.lp_overlay));
            if (gui.slider(app, "lp_overlay", p.overlay)) |v| p.overlay = v;
            gui.txt(std.fmt.allocPrint(a, "{d:.0}%", .{p.overlay * 100}) catch "", .body, theme.dim, font_mod.regular);
            clay.close();
        },
        .grid => gridPanel(app, a, p),
    }
}

/// The edit mode's tools over the view (as the concept's toolbar): objects, the hand,
/// painting, lights, then what belongs to the level kind; Done on the right.
const Btn = struct { t: Tool, ic: @import("icons.zig").Icon, label: tx.Msg };
const all_tools = [_]Btn{
    .{ .t = .objects, .ic = .mouse_pointer_2, .label = tx.lp_objects_tool },
    .{ .t = .move, .ic = .hand, .label = tx.lp_move },
    .{ .t = .brush, .ic = .paintbrush, .label = tx.lp_brush },
    .{ .t = .picker, .ic = .pipette, .label = tx.spr_picker },
    .{ .t = .light, .ic = .lightbulb, .label = tx.lp_lights },
    .{ .t = .area, .ic = .square_dashed, .label = tx.lp_area },
    .{ .t = .exit, .ic = .log_out, .label = tx.lp_exit },
    .{ .t = .points, .ic = .crosshair, .label = tx.lp_points },
    .{ .t = .paths, .ic = .redo_2, .label = tx.lp_paths },
    .{ .t = .camera, .ic = .camera, .label = tx.lp_cam_tool },
};

/// The tools in the level's toolbar (each named while the bar fits them, as the concept).
pub fn toolbar(app: *App, p: *Paint, bar: *gui.Toolbar) void {
    if (app.doc == null) return;
    inline for (all_tools) |b| {
        // Triggers, exits and scene points belong to locations; the camera to perspective levels.
        const shown = !((b.t == .area or b.t == .exit or b.t == .points or b.t == .paths) and p.grid != null);
        if (shown and bar.tool(app, "lp_tool_" ++ @tagName(b.t), b.ic, tx.get(b.label), p.tool == b.t)) p.tool = b.t;
    }
}

const RowHit = struct {
    eye: bool = false,
    lock: bool = false,
    row: bool = false,

    fn any(self: RowHit) bool {
        return self.eye or self.lock or self.row;
    }
};

/// A layer's row (as the concept's): the eye (shown), the lock (no painting; null —
/// none), its name, whether changed.
fn layerRow(app: *App, k: u32, label: []const u8, shown: bool, locked: ?bool, sel: bool, edited: bool) RowHit {
    var hit: RowHit = .{};
    const row = gui.listRow(app, clay.idi("lp_layer", k), .{ .selected = sel, .h = lay.height.tool });
    hit.eye = gui.eye(app, clay.idi("lp_eye", k), shown);
    if (locked) |lk| {
        hit.lock = gui.buttonOf(app, clay.idi("lp_lock", k), .{ .icon = if (lk) .lock else .lock_open, .style = .quiet, .size = .small, .color = if (lk) theme.warn else theme.dim });
    } else clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.small) } } });
    gui.txtClip(label, .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
    if (edited) gui.txt(tx.get(tx.lp_changed), .caption, theme.warn, font_mod.regular);
    clay.close();
    hit.row = row and !hit.eye and !hit.lock;
    return hit;
}

/// The size of characters on this level: `actorScale` of initCamera(), which runs
/// after the level's `.var` is applied, else the `.var`'s, else the exe's 0.15 (read
/// after initCamera(), 0x4218e9…0x421907): a new picture drawn at another scale needs it.
fn actorScaleRow(app: *App, a: Allocator) void {
    const d = app.doc orelse return;
    const lev = app.store.text(d.lev);
    const var_file: ?usize = app.store.file(common_archive, std.fmt.allocPrint(a, "variables\\{s}.var", .{d.name}) catch return) catch null;
    const set = newlevel.cameraVar(lev, "actor_scale") orelse if (var_file) |f| newlevel.varValue(app.store.text(f), "actor_scale") else null;
    const v = if (set) |x| (if (x > 0) x else default_actor_scale) else default_actor_scale;
    const step = stepper(app, a, "lp_ascale", tx.alloc(a, tx.lp_actor_scale, .{ v, v / default_actor_scale * 100 }), v, 0.01);
    if (step == 0) return;
    const t = newlevel.setCameraVar(app.gpa, lev, "actor_scale", std.math.clamp(v + step, 0.03, 1)) catch |err| return app.failed(err);
    app.store.replaceLabeled(d.lev, t, tx.both(a, tx.lp_actor_scale, .{ v + step, (v + step) / default_actor_scale * 100 })) catch |err| {
        app.gpa.free(t);
        app.failed(err);
    };
}

const default_actor_scale = og.actor.model_cache.default_actor_scale;

// File dialog answers (app.askFile): `ask.entry` is the layer.
fn onLayerIn(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    try importLayer(app, app.paint orelse return, @fromBackingInt(@intCast(ask.entry)), path);
    app.setStatus(tx.st_layer_set, .{});
}
fn onLayerOut(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    try exportLayer(app, app.paint orelse return, @fromBackingInt(@intCast(ask.entry)), path);
    app.setStatus(tx.st_layer_saved, .{path});
}
