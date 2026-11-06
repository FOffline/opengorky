//! Level editing: a location's layers painted on its map — the picture (`.bkg`, or the
//! `.jpg` of small rooms), the depth that hides actors behind the scenery (`.zbf`), the
//! walk grids of both floors (`.wm`, `.wm2`, 8×8-pixel cells). A brush (and an
//! eyedropper) on the chosen layer, each layer shown or hidden, PNG out and in for the
//! picture and the depth. Strokes undo inside the mode; "Done" (or Save) writes the
//! changed layers into the Store, a step each, in the game's own formats.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const og = @import("opengorky");
const Image = og.image.Image;
const ZBuffer = og.formats.zbuffer.ZBuffer;
const map_io = og.loaders.map;
const core_map = og.core.map;
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const areas = @import("areas.zig");
const art = @import("art.zig");
const Doc = @import("level.zig").Doc;
const trigger = @import("trigger.zig");
const newlevel = @import("newlevel.zig");
const common_archive = @import("store.zig").common_archive;

pub const Layer = enum(u8) { picture, depth, walk, walk2, grid };
pub const Tool = enum { objects, move, brush, picker, area, exit, points, paths, light, camera };
/// The camera gizmo's parts: the centre moves the camera, the rings turn it.
pub const Ring = enum { pan, yaw, pitch, roll };

const Change = struct { idx: u32, old: u32 };
/// One undo step: pixel/cell changes of a stroke, or a whole layer (a PNG loaded).
const Step = struct { layer: Layer, changes: []Change = &.{}, whole: ?[]u8 = null };

pub const Paint = struct {
    /// Layers (null: the level has none) and their Store files.
    pic: ?Image = null,
    pic_file: ?usize = null,
    jpg: bool = false,
    depth: ?ZBuffer = null,
    depth_file: ?usize = null,
    walk: [2]?core_map.WalkMap = .{ null, null },
    walk_file: [2]?usize = .{ null, null },
    tex: [4]?*c.SDL_Texture = .{ null, null, null, null },
    show: [5]bool = .{ true, false, true, false, true },
    /// Locked layers take no strokes (shown or not).
    locked: [5]bool = @splat(false),
    /// The walk grids' overlay opacity over the picture (0…1).
    overlay: f32 = 1,
    /// A battle's grid (`.cm`): its cells painted free/blocked, its placement edited.
    grid: ?core_map.CombatMap = null,
    grid_file: ?usize = null,
    /// The level shown (its camera maps the background onto the grid).
    doc: ?*const Doc = null,
    /// Areas, items, markers of the level over the layers.
    show_objects: bool = true,
    layer: Layer = .picture,
    tool: Tool = .objects,
    size: u16 = 8,
    color: [4]u8 = .{ 255, 255, 255, 255 },
    depth_value: u8 = 128,
    walk_on: bool = true,
    walk_height: i16 = 0,
    /// The stroke in progress: its changes, which indices it touched, the last point.
    painting: bool = false,
    stroke: std.ArrayList(Change) = .empty,
    touched: std.AutoHashMapUnmanaged(u32, void) = .empty,
    last: [2]f32 = .{ 0, 0 },
    undo: std.ArrayList(Step) = .empty,
    /// A trigger area being drawn: its points (background pixels).
    poly: std.ArrayList([2]i32) = .empty,
    /// The exit tool's outline closed before a level is picked: it waits for one.
    poly_closed: bool = false,
    /// The area picked with the hand (its name), the new name it is renamed to (`pending`).
    area: [48]u8 = undefined,
    area_len: usize = 0,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    /// The points tool lists every scene, not only the level's.
    all_scenes: bool = false,
    /// The points tool's scene (its own pick: the Scenes tab's scene when the mode opens).
    scene: app_mod.Name(64) = .{},
    /// A panel button's action, run at the next frame's start (it reloads the level,
    /// this Paint included — not while the panel lays itself out).
    pending: enum { none, finish, rename, delete, reload } = .none,
    /// Pointer over the map (background pixels), for the brush outline.
    hover: ?[2]f32 = null,
    /// The lamp picked with the light tool, and where it is being dragged (written on release).
    light: ?usize = null,
    light_drag: ?[3]f32 = null,
    /// The picked area being dragged with the hand: where the press was, the offset now.
    area_from: ?[2]f32 = null,
    area_off: [2]f32 = .{ 0, 0 },
    /// The exit tool's level and hint (string.tab id).
    exit_to: [64]u8 = undefined,
    exit_to_len: usize = 0,
    exit_label: u16 = trigger.exit_labels[0],
    /// The camera tool: the part dragged and the pointer's last spot (window pixels);
    /// the camera keys before the move (written once it rests: release, wheel idle).
    cam_ring: ?Ring = null,
    cam_last: [2]f32 = .{ 0, 0 },
    cam_base: ?[Doc.camera_keys.len]f32 = null,
    cam_at: u64 = 0,

    pub fn destroy(self: *Paint, gpa: Allocator) void {
        if (self.pic) |*p| p.deinit(gpa);
        if (self.depth) |*d| d.deinit(gpa);
        if (self.grid) |*g| g.deinit(gpa);
        for (&self.walk) |*w| if (w.*) |*m| m.deinit(gpa);
        for (self.tex) |t| if (t) |x| c.SDL_DestroyTexture(x);
        self.stroke.deinit(gpa);
        self.poly.deinit(gpa);
        self.touched.deinit(gpa);
        for (self.undo.items) |s| freeStep(gpa, s);
        self.undo.deinit(gpa);
        gpa.destroy(self);
    }
};

/// Layer `l` has strokes not undone (every one undone: as when the mode opened).
pub fn changed(p: *const Paint, l: Layer) bool {
    for (p.undo.items) |s| if (s.layer == l) return true;
    return false;
}

fn freeStep(gpa: Allocator, s: Step) void {
    gpa.free(s.changes);
    if (s.whole) |w| gpa.free(w);
}

/// The layers of location `d`, read through the Store (edits since kept).
pub fn open(app: *App, d: *Doc) !*Paint {
    const gpa = app.gpa;
    const p = try gpa.create(Paint);
    p.* = .{};
    errdefer p.destroy(gpa);
    var sb: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const sprites = try std.fmt.bufPrint(&sb, "{s}/sprite.dat", .{d.name});
    for ([_][]const u8{ "bkg", "jpg" }) |ext| {
        const f = app.store.file(sprites, try std.fmt.bufPrint(&eb, "background\\{s}.{s}", .{ d.name, ext })) catch continue;
        const bytes = app.store.text(f);
        p.pic = if (std.mem.eql(u8, ext, "bkg")) try og.formats.background.decode(gpa, bytes) else try og.formats.jpeg.decode(gpa, bytes);
        p.pic_file = f;
        p.jpg = std.mem.eql(u8, ext, "jpg");
        break;
    }
    if (app.store.file(sprites, try std.fmt.bufPrint(&eb, "background\\{s}.zbf", .{d.name}))) |f| {
        p.depth = try og.formats.zbuffer.decode(gpa, app.store.text(f));
        p.depth_file = f;
    } else |_| {}
    for ([_][]const u8{ "wm", "wm2" }, 0..) |ext, k| {
        const f = app.store.file(d.level_archive, try std.fmt.bufPrint(&eb, "{s}.{s}", .{ d.name, ext })) catch continue;
        p.walk[k] = try map_io.parseWalkMap(gpa, app.store.text(f));
        p.walk_file[k] = f;
    }
    p.doc = d;
    if (d.isBattle()) if (app.store.file(d.level_archive, try std.fmt.bufPrint(&eb, "{s}.cm", .{d.name}))) |f| {
        p.grid = try map_io.parseCombatMap(gpa, app.store.text(f));
        p.grid_file = f;
    } else |_| {};
    if (p.pic == null) p.layer = if (p.grid != null) .grid else .walk;
    try textures(app, p);
    return p;
}

pub fn hasLayer(p: *const Paint, l: Layer) bool {
    return has(p, l);
}

fn has(p: *const Paint, l: Layer) bool {
    return switch (l) {
        .picture => p.pic != null,
        .depth => p.depth != null,
        .walk => p.walk[0] != null,
        .walk2 => p.walk[1] != null,
        .grid => p.grid != null,
    };
}

fn makeTexture(app: *App, w: u32, h: u32, nearest: bool) ?*c.SDL_Texture {
    const t = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(w), @intCast(h)) orelse return null;
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetTextureScaleMode(t, if (nearest) c.SDL_SCALEMODE_NEAREST else c.SDL_SCALEMODE_LINEAR);
    return t;
}

fn textures(app: *App, p: *Paint) !void {
    if (p.pic) |img| {
        if (p.tex[0] == null) p.tex[0] = makeTexture(app, img.width, img.height, true);
        refresh(app, p, .picture, .{ 0, 0, img.width, img.height });
    }
    if (p.depth) |z| {
        if (p.tex[1] == null) p.tex[1] = makeTexture(app, z.width, z.height, true);
        refresh(app, p, .depth, .{ 0, 0, z.width, z.height });
    }
    for (0..2) |k| if (p.walk[k]) |m| {
        if (p.tex[2 + k] == null) p.tex[2 + k] = makeTexture(app, m.width, m.height, true);
        refresh(app, p, @fromBackingInt(@intCast(2 + k)), .{ 0, 0, m.width, m.height });
    };
}

/// Layer `l`'s texture redrawn in rectangle `r` (x, y, w, h in its own units).
fn refresh(app: *App, p: *Paint, l: Layer, r: [4]u32) void {
    if (l == .grid) return;
    const t = p.tex[@backingInt(l)] orelse return;
    if (r[2] == 0 or r[3] == 0) return;
    const rect: c.SDL_Rect = .{ .x = @intCast(r[0]), .y = @intCast(r[1]), .w = @intCast(r[2]), .h = @intCast(r[3]) };
    switch (l) {
        .picture => {
            const img = p.pic.?;
            _ = c.SDL_UpdateTexture(t, &rect, img.pixels[(r[1] * img.width + r[0]) * 4 ..].ptr, @intCast(img.width * 4));
        },
        .depth, .walk, .walk2 => {
            const buf = app.gpa.alloc(u8, r[2] * r[3] * 4) catch return;
            defer app.gpa.free(buf);
            for (0..r[3]) |y| for (0..r[2]) |x| {
                const px = buf[(y * r[2] + x) * 4 ..][0..4];
                if (l == .depth) {
                    const z = p.depth.?;
                    const v: u8 = @truncate(z.depth[(r[1] + y) * z.width + r[0] + x] >> 8);
                    px.* = .{ v, v, v, 210 };
                } else if (l == .walk or l == .walk2) {
                    const m = p.walk[@backingInt(l) - 2].?;
                    const on = m.at(r[0] + x, r[1] + y).walkable();
                    px.* = if (on) (if (l == .walk) [4]u8{ 60, 230, 110, 110 } else [4]u8{ 70, 140, 255, 110 }) else [4]u8{ 230, 60, 60, 45 };
                }
            };
            _ = c.SDL_UpdateTexture(t, &rect, buf.ptr, @intCast(r[2] * 4));
        },
        .grid => {},
    }
}

/// The map with the shown layers, the brush outline over it.
pub fn draw(app: *App, p: *Paint, d: *Doc, rect: c.SDL_FRect) void {
    const r = app.r;
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    _ = c.SDL_SetRenderClipRect(r, &clip);
    defer _ = c.SDL_SetRenderClipRect(r, null);
    if (!d.fitted) d.fit(rect);
    const o = screen(d, rect, .{ 0, 0 });
    for ([_]Layer{ .picture, .depth, .walk, .walk2 }) |l| {
        if (!p.show[@backingInt(l)]) continue;
        const t = p.tex[@backingInt(l)] orelse continue;
        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(t, &tw, &th);
        const k: f32 = if (l == .walk or l == .walk2) core_map.WalkMap.cell_size else 1;
        // The walk grids at the overlay opacity (the concept's slider).
        _ = c.SDL_SetTextureAlphaModFloat(t, if (l == .walk or l == .walk2) p.overlay else 1);
        _ = c.SDL_RenderTexture(r, t, null, &.{ .x = o[0], .y = o[1], .w = tw * k * d.zoom, .h = th * k * d.zoom });
    }
    // A battle: its grid as edited here (hidden with its eye).
    d.grid_view = if (p.show[@backingInt(Layer.grid)]) p.grid else null;
    d.grid_hidden = p.grid != null and !p.show[@backingInt(Layer.grid)];
    defer {
        d.grid_view = null;
        d.grid_hidden = false;
    }
    // The Objects tool: the picked object with its turn handles, as the view mode once.
    if (p.show_objects) d.draw(r, app.font, rect, if (p.tool == .objects) app.selected else pickedIndex(p, d), false, false) else if (d.grid_view) |g| d.drawGridOnly(r, app.font, rect, g);
    if (p.tool == .area or p.tool == .exit) drawPoly(r, p, d, rect);
    drawMoved(r, p, d, rect);
    if (p.tool == .points) drawPoints(app, d, rect);
    if (p.tool == .paths) @import("paths.zig").draw(app, d, rect);
    if (p.tool == .light) drawLights(app, p, d, rect);
    if (p.tool == .camera) drawGizmo(app, p, d, rect);
    // The brush: a square of its size (a cell's multiple on the walk grids).
    if (p.tool != .move and p.tool != .camera and p.tool != .objects) if (p.hover) |h| {
        const s: f32 = brushPixels(p);
        const cell: f32 = if (p.layer == .walk or p.layer == .walk2) core_map.WalkMap.cell_size else 1;
        const x0 = @floor((h[0] - s / 2) / cell) * cell;
        const y0 = @floor((h[1] - s / 2) / cell) * cell;
        const a = screen(d, rect, .{ x0, y0 });
        _ = c.SDL_SetRenderDrawColor(r, 255, 255, 255, 200);
        _ = c.SDL_RenderRect(r, &.{ .x = a[0], .y = a[1], .w = @max(1, s * d.zoom), .h = @max(1, s * d.zoom) });
    };
}

fn pickedIndex(p: *const Paint, d: *const Doc) ?usize {
    if (p.area_len == 0) return null;
    for (d.objects.items, 0..) |o, i| if (o.kind == .area and std.ascii.eqlIgnoreCase(o.name, p.area[0..p.area_len])) return i;
    return null;
}

/// A hand press on the map: the area under it picked and its drag started (true),
/// or none picked (false: the hand drags the map).
pub fn pickAt(p: *Paint, d: *const Doc, v: c.SDL_FRect, s: [2]f32) bool {
    p.area_len = 0;
    const i = d.pick(v, s) orelse return false;
    const o = d.objects.items[i];
    if (o.kind != .area) return false;
    pickName(p, o.name);
    p.area_from = d.toBackground(v, s);
    p.area_off = .{ 0, 0 };
    return true;
}

pub fn pickName(p: *Paint, name: []const u8) void {
    p.area_len = @min(name.len, p.area.len);
    @memcpy(p.area[0..p.area_len], name[0..p.area_len]);
    p.name = p.area;
    p.name_len = p.area_len;
}

/// The picked area dragged to background point `b`.
pub fn areaDrag(p: *Paint, b: [2]f32) void {
    const from = p.area_from orelse return;
    p.area_off = .{ @round(b[0] - from[0]), @round(b[1] - from[1]) };
}

/// Released: the dragged area written where it is (a move under 2 pixels is a click).
/// The level reloads: this Paint is gone after a move.
pub fn areaRelease(app: *App, p: *Paint) void {
    if (p.area_from == null) return;
    p.area_from = null;
    const off: [2]i32 = .{ @intFromFloat(p.area_off[0]), @intFromFloat(p.area_off[1]) };
    p.area_off = .{ 0, 0 };
    if (@abs(off[0]) + @abs(off[1]) < 2) return;
    var nb: [48]u8 = undefined;
    const name = nb[0..p.area_len];
    @memcpy(name, p.area[0..p.area_len]);
    areas.moveArea(app, name, off);
}

/// The dragged area's outline where it would go.
fn drawMoved(r: *c.SDL_Renderer, p: *const Paint, d: *const Doc, rect: c.SDL_FRect) void {
    if (p.area_from == null or p.area_len == 0) return;
    const i = pickedIndex(p, d) orelse return;
    const pts = d.objects.items[i].poly orelse return;
    if (pts.len < 2) return;
    _ = c.SDL_SetRenderDrawColor(r, 255, 255, 255, 230);
    var prev = screen(d, rect, .{ pts[pts.len - 1][0] + p.area_off[0], pts[pts.len - 1][1] + p.area_off[1] });
    for (pts) |pt| {
        const q = screen(d, rect, .{ pt[0] + p.area_off[0], pt[1] + p.area_off[1] });
        _ = c.SDL_RenderLine(r, prev[0], prev[1], q[0], q[1]);
        prev = q;
    }
}

/// The panel's button action, if one waits (start of a frame).
pub fn runPending(app: *App, p: *Paint) void {
    if (p.cam_ring == null and c.SDL_GetTicks() > p.cam_at + 400) camCommit(app, p);
    const what = p.pending;
    p.pending = .none;
    switch (what) {
        .none => {},
        .finish => finishArea(app, p),
        .reload => app.reloadLevel(),
        .rename => rename(app, p),
        .delete => {
            var ob: [48]u8 = undefined;
            const old = ob[0..p.area_len];
            @memcpy(old, p.area[0..p.area_len]);
            areas.deleteArea(app, old);
        },
    }
}

fn rename(app: *App, p: *Paint) void {
    var ob: [48]u8 = undefined;
    var nb: [48]u8 = undefined;
    const old = ob[0..p.area_len];
    @memcpy(old, p.area[0..p.area_len]);
    const new = nb[0..p.name_len];
    @memcpy(new, p.name[0..p.name_len]);
    if (std.mem.eql(u8, old, new)) return;
    // The mode opens anew over the reloaded level: this Paint is gone after.
    areas.renameArea(app, old, new);
}

const drawPoints = @import("paint_points.zig").drawPoints;
pub const pointClick = @import("paint_points.zig").pointClick;
pub const dropPoint = @import("paint_points.zig").dropPoint;

pub const dropLight = @import("paint_lights.zig").dropLight;
const drawLights = @import("paint_lights.zig").drawLights;
pub const lightPress = @import("paint_lights.zig").lightPress;
pub const lightDrag = @import("paint_lights.zig").lightDrag;
pub const lightRelease = @import("paint_lights.zig").lightRelease;

const drawPoly = @import("paint_areas.zig").drawPoly;
pub const areaClick = @import("paint_areas.zig").areaClick;
pub const finishArea = @import("paint_areas.zig").finishArea;

pub fn screen(d: *const Doc, rect: c.SDL_FRect, b: [2]f32) [2]f32 {
    return .{ rect.x + (b[0] - d.origin[0]) * d.zoom, rect.y + (b[1] - d.origin[1]) * d.zoom };
}

/// The brush side in background pixels (walk grids: whole cells).
pub fn brushPixels(p: *const Paint) f32 {
    const s: f32 = @floatFromInt(p.size);
    return if (p.layer == .walk or p.layer == .walk2) @max(core_map.WalkMap.cell_size, @round(s / 8) * 8) else s;
}

/// Pressed on the map at background point `b`: the eyedropper, or a stroke begins.
pub fn press(app: *App, p: *Paint, b: [2]f32) void {
    if (!has(p, p.layer) or p.tool == .move) return;
    if (p.locked[@backingInt(p.layer)]) return app.setStatus(tx.st_layer_locked, .{});
    if (p.tool == .picker) {
        pick(p, b);
        p.tool = .brush;
        return;
    }
    p.painting = true;
    p.stroke.clearRetainingCapacity();
    p.touched.clearRetainingCapacity();
    // A cell made walkable takes the floor height of where the stroke began, if walkable.
    if (p.layer == .walk or p.layer == .walk2) if (cellAt(p, b)) |ci| {
        const cell = p.walk[@backingInt(p.layer) - 2].?.cells[ci];
        if (cell.walkable()) p.walk_height = cell.height;
    };
    dab(app, p, b);
    p.last = b;
}

/// Dragged to `b`: dabs along the way (no gaps when the pointer moves fast).
pub fn drag(app: *App, p: *Paint, b: [2]f32) void {
    if (!p.painting) return;
    const dx = b[0] - p.last[0];
    const dy = b[1] - p.last[1];
    const step = @max(1, brushPixels(p) / 3);
    const n: usize = @intFromFloat(@ceil(@sqrt(dx * dx + dy * dy) / step));
    for (1..n + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        dab(app, p, .{ p.last[0] + dx * t, p.last[1] + dy * t });
    }
    p.last = b;
}

/// Released: the stroke is one undo step.
pub fn release(app: *App, p: *Paint) void {
    if (!p.painting) return;
    p.painting = false;
    if (p.stroke.items.len == 0) return;
    const changes = app.gpa.dupe(Change, p.stroke.items) catch return;
    p.undo.append(app.gpa, .{ .layer = p.layer, .changes = changes }) catch app.gpa.free(changes);
}

fn cellAt(p: *const Paint, b: [2]f32) ?usize {
    const m = p.walk[@backingInt(p.layer) - 2] orelse return null;
    if (b[0] < 0 or b[1] < 0) return null;
    const x: usize = @intFromFloat(b[0] / core_map.WalkMap.cell_size);
    const y: usize = @intFromFloat(b[1] / core_map.WalkMap.cell_size);
    if (x >= m.width or y >= m.height) return null;
    return y * m.width + x;
}

fn pick(p: *Paint, b: [2]f32) void {
    switch (p.layer) {
        .picture => {
            const img = p.pic.?;
            const x: usize = @intFromFloat(@max(0, b[0]));
            const y: usize = @intFromFloat(@max(0, b[1]));
            if (x < img.width and y < img.height) p.color = img.pixels[(y * img.width + x) * 4 ..][0..4].*;
        },
        .depth => {
            const z = p.depth.?;
            const x: usize = @intFromFloat(@max(0, b[0]));
            const y: usize = @intFromFloat(@max(0, b[1]));
            if (x < z.width and y < z.height) p.depth_value = @truncate(z.depth[y * z.width + x] >> 8);
        },
        .walk, .walk2 => if (cellAt(p, b)) |ci| {
            const cell = p.walk[@backingInt(p.layer) - 2].?.cells[ci];
            p.walk_on = cell.walkable();
            if (cell.walkable()) p.walk_height = cell.height;
        },
        .grid => if (gridCell(p, b)) |ci| {
            p.walk_on = !p.grid.?.blocked[ci];
        },
    }
}

/// The battle grid cell (index into `blocked`) under background point `b`, if any:
/// the floor plane under it as the editor's battle view takes it (Doc.gridAt).
fn gridCell(p: *const Paint, b: [2]f32) ?usize {
    const cm = p.grid orelse return null;
    const d = p.doc orelse return null;
    const h = switch (d.world.cam) {
        .persp => |pc| cm.center[2] - pc.zlevel / pc.scale,
        .ortho => cm.center[2],
    };
    const w = d.world.cam.unproject(b[0], b[1], h);
    const g = cm.toGrid(w[0], w[1]);
    if (g[0] < 0 or g[1] < 0) return null;
    const x: usize = @intFromFloat(g[0]);
    const y: usize = @intFromFloat(g[1]);
    if (x >= cm.width or y >= cm.height) return null;
    return y * cm.width + x;
}

/// The brush once at `b` on the chosen layer; each value's old one kept once a stroke.
fn dab(app: *App, p: *Paint, b: [2]f32) void {
    const s = brushPixels(p);
    switch (p.layer) {
        .picture, .depth => {
            const w: u32 = if (p.layer == .picture) p.pic.?.width else p.depth.?.width;
            const h: u32 = if (p.layer == .picture) p.pic.?.height else p.depth.?.height;
            const x0: i64 = @intFromFloat(@floor(b[0] - s / 2));
            const y0: i64 = @intFromFloat(@floor(b[1] - s / 2));
            const n: i64 = @intFromFloat(s);
            const ax: u32 = @intCast(std.math.clamp(x0, 0, w));
            const ay: u32 = @intCast(std.math.clamp(y0, 0, h));
            const bx: u32 = @intCast(std.math.clamp(x0 + n, 0, w));
            const by: u32 = @intCast(std.math.clamp(y0 + n, 0, h));
            for (ay..by) |y| for (ax..bx) |x| {
                const i: u32 = @intCast(y * w + x);
                if (p.layer == .picture) {
                    const px = p.pic.?.pixels[i * 4 ..][0..4];
                    keep(app, p, i, std.mem.readInt(u32, px, .little));
                    px.* = .{ p.color[0], p.color[1], p.color[2], 255 };
                } else {
                    const z = &p.depth.?.depth[i];
                    keep(app, p, i, z.*);
                    z.* = @as(u16, p.depth_value) << 8;
                }
            };
            refresh(app, p, p.layer, .{ ax, ay, bx -| ax, by -| ay });
        },
        .walk, .walk2 => {
            const m = &p.walk[@backingInt(p.layer) - 2].?;
            const cells: i64 = @intFromFloat(s / core_map.WalkMap.cell_size);
            const cx: i64 = @intFromFloat(@floor(b[0] / core_map.WalkMap.cell_size));
            const cy: i64 = @intFromFloat(@floor(b[1] / core_map.WalkMap.cell_size));
            const x0 = cx - @divFloor(cells - 1, 2);
            const y0 = cy - @divFloor(cells - 1, 2);
            const ax: u32 = @intCast(std.math.clamp(x0, 0, m.width));
            const ay: u32 = @intCast(std.math.clamp(y0, 0, m.height));
            const bx: u32 = @intCast(std.math.clamp(x0 + cells, 0, m.width));
            const by: u32 = @intCast(std.math.clamp(y0 + cells, 0, m.height));
            for (ay..by) |y| for (ax..bx) |x| {
                const i: u32 = @intCast(y * m.width + x);
                const cell = &m.cells[i];
                keep(app, p, i, @as(u32, cell.kind) | @as(u32, @as(u16, @bitCast(cell.height))) << 8);
                if (p.walk_on) {
                    // A cell that wasn't floor gets the stroke's floor height.
                    if (!cell.walkable()) cell.height = p.walk_height;
                    cell.kind |= 1;
                } else cell.kind &= ~@as(u8, 1);
            };
            refresh(app, p, p.layer, .{ ax, ay, bx -| ax, by -| ay });
        },
        // One cell a dab: battle cells are much bigger than the brush.
        .grid => if (gridCell(p, b)) |ci| {
            const cell = &p.grid.?.blocked[ci];
            keep(app, p, @intCast(ci), @intFromBool(cell.*));
            cell.* = !p.walk_on;
        },
    }
}

fn keep(app: *App, p: *Paint, i: u32, old: u32) void {
    const g = p.touched.getOrPut(app.gpa, i) catch return;
    if (g.found_existing) return;
    p.stroke.append(app.gpa, .{ .idx = i, .old = old }) catch {};
}

/// An `.ap` link end moved: walk grid mark `bit` (2: start, 4: end — what the route
/// search tests to take a path, exe 0x4ac454…0x4ac5aa; the game marks both grids)
/// cleared at cell `from` unless `keep_from`, set at `to`; one undo step a grid.
pub fn linkMark(app: *App, p: *Paint, bit: u8, from: ?[2]f32, keep_from: bool, to: ?[2]f32) void {
    for (&p.walk, 0..) |*wm, k| if (wm.*) |*m| {
        var changes: [2]Change = undefined;
        var n: usize = 0;
        for ([_]?[2]f32{ if (keep_from) null else from, to }, [_]bool{ false, true }) |cell, set| {
            const at = cell orelse continue;
            if (at[0] < 0 or at[1] < 0 or at[0] >= @as(f32, @floatFromInt(m.width)) or at[1] >= @as(f32, @floatFromInt(m.height))) continue;
            const i: u32 = @intFromFloat(at[1] * @as(f32, @floatFromInt(m.width)) + at[0]);
            const c0 = &m.cells[i];
            const kind = if (set) c0.kind | bit else c0.kind & ~bit;
            if (kind == c0.kind) continue;
            changes[n] = .{ .idx = i, .old = @as(u32, c0.kind) | @as(u32, @as(u16, @bitCast(c0.height))) << 8 };
            n += 1;
            c0.kind = kind;
        }
        if (n == 0) continue;
        const own = app.gpa.dupe(Change, changes[0..n]) catch return;
        p.undo.append(app.gpa, .{ .layer = @fromBackingInt(@intCast(2 + k)), .changes = own }) catch app.gpa.free(own);
    };
}

/// The last stroke (or loaded PNG) undone.
pub fn undo(app: *App, p: *Paint) bool {
    const s = p.undo.pop() orelse return false;
    defer freeStep(app.gpa, s);
    if (s.whole) |w| {
        switch (s.layer) {
            .picture => @memcpy(p.pic.?.pixels, w),
            .depth => @memcpy(std.mem.sliceAsBytes(p.depth.?.depth), w),
            // The grid's placement or size changed: its `.cm` text before.
            .grid => if (map_io.parseCombatMap(app.gpa, w)) |g| {
                p.grid.?.deinit(app.gpa);
                p.grid = g;
            } else |_| {},
            else => {},
        }
    } else {
        var k = s.changes.len;
        while (k > 0) {
            k -= 1;
            const ch = s.changes[k];
            switch (s.layer) {
                .picture => std.mem.writeInt(u32, p.pic.?.pixels[ch.idx * 4 ..][0..4], ch.old, .little),
                .depth => p.depth.?.depth[ch.idx] = @truncate(ch.old),
                .walk, .walk2 => {
                    const cell = &p.walk[@backingInt(s.layer) - 2].?.cells[ch.idx];
                    cell.kind = @truncate(ch.old);
                    cell.height = @bitCast(@as(u16, @truncate(ch.old >> 8)));
                },
                .grid => p.grid.?.blocked[ch.idx] = ch.old != 0,
            }
        }
    }
    textures(app, p) catch {};
    return true;
}

/// Changed layers written into the Store (a step each, in the game's formats).
pub fn commit(app: *App, p: *Paint) !void {
    const gpa = app.gpa;
    camCommit(app, p);
    if (changed(p, .picture)) if (p.pic_file) |f| {
        const bytes = if (p.jpg) try og.formats.jpeg.encode(gpa, p.pic.?, 92) else try og.formats.background.encode(gpa, p.pic.?);
        try app.store.replaceLabeled(f, bytes, tx.both(app.frame.allocator(), tx.lp_step_picture, .{}));
    };
    if (changed(p, .grid)) if (p.grid_file) |f| {
        var was = try map_io.parseCombatMap(gpa, app.store.text(f));
        defer was.deinit(gpa);
        const g = p.grid.?;
        try app.store.replaceLabeled(f, try map_io.encodeCombatMap(gpa, g), tx.both(app.frame.allocator(), tx.lp_step_grid, .{}));
        // Cells more or fewer: the placements follow (the grid's own heights went with
        // its cells, paint_camera.zig). The same floor span: cut finer or coarser.
        const span = @abs(was.cell_size[0] * @as(f32, @floatFromInt(was.width)) - g.cell_size[0] * @as(f32, @floatFromInt(g.width))) < 0.01;
        if (was.width != g.width or was.height != g.height) if (app.doc) |d| {
            const placement = @import("placement.zig");
            var calls = try placement.scan(app, gpa, d.lev);
            defer calls.deinit(gpa);
            if (try placement.remapTiles(gpa, app.store.text(d.lev), calls, .{ was.width, was.height }, .{ g.width, g.height }, span)) |r| {
                app.store.replace(d.lev, r.text) catch |err| {
                    gpa.free(r.text);
                    return err;
                };
                if (r.moved > 0) app.setStatus(tx.lp_tiles_clamped, .{ r.moved, r.first });
            }
        };
    };
    if (changed(p, .depth)) if (p.depth_file) |f| try app.store.replaceLabeled(f, try og.formats.zbuffer.encode(gpa, p.depth.?), tx.both(app.frame.allocator(), tx.lp_step_depth, .{}));
    for (0..2) |k| if (changed(p, @fromBackingInt(@intCast(2 + k)))) if (p.walk_file[k]) |f| {
        try app.store.replaceLabeled(f, try map_io.encodeWalkMap(gpa, p.walk[k].?), if (k == 0) tx.both(app.frame.allocator(), tx.lp_step_walk, .{}) else tx.both(app.frame.allocator(), tx.lp_step_walk2, .{}));
    };
}

/// Layer `l` from a PNG (fitted to its size; the depth from the grey); one step. A
/// location's picture of another size resizes the level instead (resizeLevel).
pub fn importLayer(app: *App, p: *Paint, l: Layer, path: []const u8) !void {
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    if (l == .picture and (img.width != p.pic.?.width or img.height != p.pic.?.height)) if (app.doc) |d| if (!d.isBattle()) return resizeLevel(app, p, d, img);
    const w = if (l == .picture) p.pic.?.width else p.depth.?.width;
    const h = if (l == .picture) p.pic.?.height else p.depth.?.height;
    var fit = try art.resize(app.gpa, img, w, h);
    defer fit.deinit(app.gpa);
    const old = try app.gpa.dupe(u8, if (l == .picture) p.pic.?.pixels else std.mem.sliceAsBytes(p.depth.?.depth));
    errdefer app.gpa.free(old);
    try p.undo.append(app.gpa, .{ .layer = l, .whole = old });
    if (l == .picture) {
        for (0..w * h) |i| p.pic.?.pixels[i * 4 ..][0..4].* = .{ fit.pixels[i * 4], fit.pixels[i * 4 + 1], fit.pixels[i * 4 + 2], 255 };
    } else for (0..w * h) |i| {
        p.depth.?.depth[i] = @as(u16, fit.pixels[i * 4]) << 8;
    }
    try textures(app, p);
}

/// Location `d` takes picture `img` at its size (sizes vary in the game: 1280×960 to
/// 2600×1916, the exe reads it from the `.bkg`/`.jpg`): the depth and both walk grids
/// resampled onto it (cells of 8 pixels, w/8 × h/8 as the game's), the `.ar` corners
/// scaled. A perspective camera spans the background width (initBank), so the world
/// scales with it. The path nodes (`.ap`, their links' walk marks set on the new grids)
/// and the points of the scenes its scripts start scale too. Written into the Store as
/// the mode closes; the level reloads.
/// shortcut: a scene started from two levels gets this one's scale, rare in the game.
fn resizeLevel(app: *App, p: *Paint, d: *Doc, img: Image) !void {
    const gpa = app.gpa;
    const w = img.width;
    const h = img.height;
    // The exe's screen: a smaller picture leaves the view outside it.
    if (w < 640 or h < 480) return error.PictureTooSmall;
    // The port reads no larger `.bkg` (formats/background.zig).
    if (!p.jpg and (w > og.formats.background.max_side or h > og.formats.background.max_side)) return error.PictureTooLarge;
    const old: [2]u32 = .{ p.pic.?.width, p.pic.?.height };
    var pic = try Image.init(gpa, w, h);
    errdefer pic.deinit(gpa);
    for (0..w * h) |i| pic.pixels[i * 4 ..][0..4].* = .{ img.pixels[i * 4], img.pixels[i * 4 + 1], img.pixels[i * 4 + 2], 255 };
    const depth: ?[]u16 = if (p.depth) |z| try resample(u16, gpa, z.depth, z.width, z.height, w, h) else null;
    errdefer if (depth) |x| gpa.free(x);
    var cells: [2]?[]core_map.WalkMap.Cell = .{ null, null };
    errdefer for (cells) |x| if (x) |m| gpa.free(m);
    const cs = core_map.WalkMap.cell_size;
    for (p.walk, 0..) |m, k| if (m) |x| {
        cells[k] = try resample(core_map.WalkMap.Cell, gpa, x.cells, x.width, x.height, w / cs, h / cs);
    };
    try p.undo.ensureUnusedCapacity(gpa, 4);
    if (app.store.file(d.level_archive, try std.fmt.allocPrint(app.frame.allocator(), "{s}.ar", .{d.name}))) |f| {
        const t = try newlevel.scaleAr(gpa, app.store.text(f), .{ @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(old[0])), @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(old[1])) });
        app.store.replaceLabeled(f, t, tx.both(app.frame.allocator(), tx.lp_step_resize, .{ w, h })) catch |err| {
            gpa.free(t);
            return err;
        };
    } else |_| {}
    const k: [2]f32 = .{ @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(old[0])), @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(old[1])) };
    const label = tx.alloc(app.frame.allocator(), tx.lp_step_resize, .{ w, h });
    if (app.store.file(d.level_archive, try std.fmt.allocPrint(app.frame.allocator(), "{s}.ap", .{d.name}))) |f| {
        const r = try newlevel.scaleAp(gpa, app.store.text(f), k);
        defer gpa.free(r.links);
        app.store.replaceLabeled(f, r.text, label) catch |err| {
            gpa.free(r.text);
            return err;
        };
        // The route search takes a path at its link cells' marks (2 start, 4 end; linkMark).
        // A mark the old grid had at a link's cell is on its new cell (resampling may drop it).
        for (cells, p.walk) |m, was| if (m) |x| for (r.links) |l| for ([_]u8{ 2, 4 }, 0..) |bit, e| {
            const ox: usize = @intFromFloat(@max(0, l[0][e * 2]));
            const oy: usize = @intFromFloat(@max(0, l[0][e * 2 + 1]));
            if (ox >= was.?.width or oy >= was.?.height or was.?.at(ox, oy).kind & bit == 0) continue;
            const cx: u32 = @intFromFloat(std.math.clamp(l[1][e * 2], 0, @as(f32, @floatFromInt(w / cs - 1))));
            const cy: u32 = @intFromFloat(std.math.clamp(l[1][e * 2 + 1], 0, @as(f32, @floatFromInt(h / cs - 1))));
            x[cy * (w / cs) + cx].kind |= bit;
        };
    } else |_| {}
    for (app.catalog.scenes.items) |sc| if (startedIn(app, d, sc.name)) {
        const f = app.store.file(common_archive, try std.fmt.allocPrint(app.frame.allocator(), "scriptlets\\{s}.pts", .{sc.name})) catch continue;
        const t = try newlevel.scalePts(gpa, app.store.text(f), k);
        app.store.replaceLabeled(f, t, label) catch |err| {
            gpa.free(t);
            return err;
        };
    };
    // Nothing fails past here: the layers swapped, each marked changed for commit().
    p.pic.?.deinit(gpa);
    p.pic = pic;
    if (p.depth) |*z| {
        gpa.free(z.depth);
        z.* = .{ .width = w, .height = h, .depth = depth.? };
    }
    for (&p.walk, cells) |*m, x| if (m.*) |*wm| {
        gpa.free(wm.cells);
        wm.* = .{ .width = w / cs, .height = h / cs, .cells = x.? };
    };
    for (&p.tex) |*t| if (t.*) |x| {
        c.SDL_DestroyTexture(x);
        t.* = null;
    };
    for ([_]Layer{ .picture, .depth, .walk, .walk2 }) |l| if (has(p, l)) p.undo.appendAssumeCapacity(.{ .layer = l });
    textures(app, p) catch {};
    p.pending = .reload;
}

/// Scene `name` is started by a script of level `d` (its `.lev` or another of its archive).
fn startedIn(app: *App, d: *const Doc, name: []const u8) bool {
    const a = app.frame.allocator();
    for (app.store.files.items) |f| if (!f.deleted and std.mem.eql(u8, f.archive, d.level_archive)) {
        if ((@import("scenes.zig").calls(a, f.text, name) catch continue).len > 0) return true;
    };
    return false;
}

/// `src` (sw×sh) on a dw×dh grid, the nearest value each.
fn resample(comptime T: type, gpa: Allocator, src: []const T, sw: u32, sh: u32, dw: u32, dh: u32) ![]T {
    const out = try gpa.alloc(T, @as(usize, dw) * dh);
    for (0..dh) |y| for (0..dw) |x| {
        out[y * dw + x] = src[(y * sh / dh) * sw + x * sw / dw];
    };
    return out;
}

test resample {
    const out = try resample(u8, std.testing.allocator, &.{ 1, 2, 3, 4 }, 2, 2, 4, 1);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2, 2 }, out);
}

/// The depth layer put on the exe's scale. A depth made elsewhere (a render, a depth
/// estimator) has its own: the exe compares a model's W-buffer depth with the `.zbf`
/// value as is (0x41cf07: z = far − v·tl/65536; without a `.cfg` far = tl =
/// frontPlane − backPlane), and feet sink into a floor it takes for nearer. On
/// walkable floor cells each value is paired with the one the exe expects there, a
/// line fitted (lineFit), every pixel mapped by it, the floor two steps farther so
/// feet stand on it. One undo step. Returns the floor's median mismatch before, in
/// `.zbf` steps.
pub fn fitDepth(app: *App, p: *Paint, d: *Doc) !f32 {
    const z = &(p.depth orelse return error.NoDepth);
    const cam = switch (d.world.cam) {
        .persp => |pc| pc,
        .ortho => return error.NotPerspective,
    };
    var cb: [160]u8 = undefined;
    const l = d.world.level orelse return error.NoLevel;
    // Without a `.cfg` far = tl = the planes' span; with one (a perspective one) its own.
    var tl = og.fields.getF(l, "near_plane") - og.fields.getF(l, "far_plane");
    var far = tl;
    if (app.store.find(try std.fmt.bufPrint(&cb, "{s}/sprite.dat", .{d.name}), try std.fmt.bufPrint(cb[80..], "background\\{s}.cfg", .{d.name}))) |f| {
        const cfg = og.formats.level.parsePerspCfg(app.store.text(f)) orelse return error.HasCfg;
        tl = cfg.tl;
        const e: [3]f32 = .{ cfg.eye[0] - cfg.target[0], cfg.eye[1] - cfg.target[1], cfg.eye[2] - cfg.target[2] };
        far = @sqrt(e[0] * e[0] + e[1] * e[1] + e[2] * e[2]) + tl;
    }
    if (tl <= 0) return error.NoPlanes;
    const a = app.frame.allocator();
    // Floor points: walkable cells of a location, free cells of a battle grid.
    var floor: std.ArrayList([3]f32) = .empty;
    if (p.walk[0]) |m| {
        var y: usize = 0;
        while (y < m.height) : (y += 2) {
            var x: usize = 0;
            while (x < m.width) : (x += 2) {
                if (!m.at(x, y).walkable()) continue;
                const cs = core_map.WalkMap.cell_size;
                const bg: [2]f32 = .{ @as(f32, @floatFromInt(x * cs)) + cs / 2, @as(f32, @floatFromInt(y * cs)) + cs / 2 };
                try floor.append(a, og.world.floor.groundAt(d.world, bg));
            }
        }
    } else if (p.grid) |g| {
        for (0..g.height) |y| for (0..g.width) |x| {
            if (g.blocked[y * g.width + x]) continue;
            for ([_][2]f32{ .{ 0.25, 0.25 }, .{ 0.75, 0.25 }, .{ 0.25, 0.75 }, .{ 0.75, 0.75 } }) |f|
                try floor.append(a, g.toWorld(@as(f32, @floatFromInt(x)) + f[0], @as(f32, @floatFromInt(y)) + f[1]));
        };
    } else return error.NoFloor;
    var pts: std.ArrayList([2]f32) = .empty;
    for (floor.items) |fp| {
        const q = cam.project(fp);
        if (q.x < 0 or q.y < 0 or q.x >= @as(f32, @floatFromInt(z.width)) or q.y >= @as(f32, @floatFromInt(z.height))) continue;
        const g: f32 = @floatFromInt(z.depth[@as(usize, @intFromFloat(q.y)) * z.width + @as(usize, @intFromFloat(q.x))]);
        try pts.append(a, .{ g, (far + q.depth) * 65536 / tl });
    }
    var miss = try a.alloc(f32, pts.items.len);
    for (pts.items, 0..) |pt, i| miss[i] = @abs(pt[0] - pt[1]) / 256;
    std.mem.sort(f32, miss, {}, std.sort.asc(f32));
    const ab = og.render.depth_fit.lineFit(pts.items) orelse return error.TooLittleFloor;
    try p.undo.append(app.gpa, .{ .layer = .depth, .whole = try app.gpa.dupe(u8, std.mem.sliceAsBytes(z.depth)) });
    for (z.depth) |*v| {
        const nv = ab[0] * @as(f32, @floatFromInt(v.*)) + ab[1] - 2 * 256;
        // The game's `.zbf` keeps the high byte only.
        v.* = @as(u16, @intFromFloat(std.math.clamp(nv, 0, 65535))) & 0xff00;
    }
    try textures(app, p);
    return if (miss.len > 0) miss[miss.len / 2] else 0;
}

/// Layer `l` as a PNG (the depth as grey: its high byte, the low one is 0 in the game).
pub fn exportLayer(app: *App, p: *Paint, l: Layer, path: []const u8) !void {
    if (l == .picture) return art.writePng(app, p.pic.?, path);
    const z = p.depth.?;
    var img = try Image.init(app.gpa, z.width, z.height);
    defer img.deinit(app.gpa);
    for (z.depth, 0..) |v, i| {
        const g: u8 = @truncate(v >> 8);
        img.pixels[i * 4 ..][0..4].* = .{ g, g, g, 255 };
    }
    try art.writePng(app, img, path);
}

pub const cameraStep = @import("paint_camera.zig").cameraStep;
pub const gridSplitTo = @import("paint_camera.zig").gridSplitTo;
pub const gizmo_r = @import("paint_camera.zig").gizmo_r;
const drawGizmo = @import("paint_camera.zig").drawGizmo;
pub const cameraPress = @import("paint_camera.zig").cameraPress;
pub const cameraDrag = @import("paint_camera.zig").cameraDrag;
pub const cameraRelease = @import("paint_camera.zig").cameraRelease;
pub const cameraWheel = @import("paint_camera.zig").cameraWheel;
pub const camCommit = @import("paint_camera.zig").camCommit;
