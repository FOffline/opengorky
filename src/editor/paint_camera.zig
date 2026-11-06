//! A level's view settings in the edit mode: a battle's grid (size, split) and camera
//! (the gizmo dragged, initCamera keys), a location's ortho camera, the background .cfg.

const level_og = @import("level_og.zig");
const std = @import("std");
const screen = @import("paint.zig").screen;
const Ring = @import("paint.zig").Ring;
const Paint = @import("paint.zig").Paint;
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const og = @import("opengorky");
const map_io = og.loaders.map;
const core_map = og.core.map;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const stepper = gui.stepper;
const lay = @import("layout.zig");
const ink = @import("render.zig").ink;
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const Doc = @import("level.zig").Doc;

/// A location's camera (orthographic, initCamera()): the tilt the background was drawn
/// at (`rotxy`, −30° in the game's) and the depth planes. 3D characters are drawn with
/// it over the picture, so it has to match the picture.
fn orthoPanel(app: *App, a: Allocator, d: *Doc) void {
    gui.txtWrap(tx.get(tx.cam_ortho_hint), .caption, theme.dim, font_mod.regular);
    const rows = [_]struct { tx.Msg, []const u8, f32 }{ .{ tx.cam_tilt, "ortho_rotation_radians", 180.0 / std.math.pi }, .{ tx.cam_front, "near_plane", 1 }, .{ tx.cam_back, "far_plane", 1 } };
    inline for (rows) |r| {
        gui.fieldRow(tx.get(r[0]));
        const v = (d.camValue(r[1]) orelse 0) * r[2];
        if (gui.numberField(app, a, "lp_ortho_" ++ r[1], "", v, lay.width.field)) |nv| {
            if (level_og.blockFile(d) != null) {
                d.setCamera(&.{.{ r[1], nv / r[2] }}) catch |err| app.failed(err);
            } else {
                const t = d.withCamera(app.gpa, &.{.{ r[1], nv / r[2] }}) catch |err| {
                    clay.close();
                    return app.failed(err);
                };
                app.store.replaceLabeled(d.lev, t, r[1]) catch |err| {
                    app.gpa.free(t);
                    app.failed(err);
                };
            }
        }
        clay.close();
    }
}

/// The background's `.cfg` (sprite.dat `background\\<level>.cfg`, read by the exe at
/// 0x41cf07): how the depth picture turns into floor height on a location (gscale, g0,
/// g1) and its planes; a battle's eye and target (vx…tz, tl). Shown with the depth layer.
pub fn backgroundCfg(app: *App, a: Allocator) void {
    const d = app.doc orelse return;
    const archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{d.name}) catch return;
    const entry = std.fmt.allocPrint(a, "background\\{s}.cfg", .{d.name}) catch return;
    const f = app.store.file(archive, entry) catch return;
    const t = app.store.text(f);
    gui.txtWrap(tx.get(tx.bg_cfg_hint), .caption, theme.dim, font_mod.regular);
    const keys: []const []const u8 = if (std.mem.indexOf(u8, t, "\ntl ") != null or std.mem.startsWith(u8, t, "tl ")) &.{ "vx", "vy", "vz", "tx", "ty", "tz", "tl" } else &.{ "gscale", "g0", "g1", "frontPlane", "backPlane" };
    for (keys) |k| {
        const v = cfgValue(t, k) orelse continue;
        gui.fieldRow(k);
        if (gui.numberField(app, a, std.fmt.allocPrint(a, "bgcfg_{s}", .{k}) catch k, "", v, lay.width.field)) |nv| {
            const nt = cfgSet(app.gpa, t, k, nv) catch {
                clay.close();
                return;
            };
            app.store.replaceLabeled(f, nt, entry) catch app.gpa.free(nt);
        }
        clay.close();
    }
}

/// `key value` line's value.
fn cfgValue(t: []const u8, key: []const u8) ?f32 {
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == ' ') return std.fmt.parseFloat(f32, std.mem.trim(u8, l[key.len..], " ")) catch null;
    }
    return null;
}

/// `t` with `key`'s value `v` (`%f`, as the game's files write it).
fn cfgSet(gpa: Allocator, t: []const u8, key: []const u8, v: f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, t, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == ' ') {
            try out.print(gpa, "{s} {d:.6}", .{ key, v });
            if (raw.len > l.len) try out.append(gpa, '\r');
        } else try out.appendSlice(gpa, raw);
    }
    return out.toOwnedSlice(gpa);
}

/// The battle grid: cells free or blocked (the brush), and where the grid lies — its
/// centre, turn, cell size, size in cells. A placement change is one undo step.
pub fn gridPanel(app: *App, a: Allocator, p: *Paint) void {
    gui.note(tx.get(tx.lp_grid_hint));
    gui.fieldRow(tx.get(tx.lp_brush_mode));
    if (gui.segmented(app, "lp_grid_mode", &.{ tx.get(tx.lp_grid_free), tx.get(tx.lp_grid_blocked) }, if (p.walk_on) 0 else 1)) |k| p.walk_on = k == 0;
    clay.close();
    const g = &(p.grid orelse return);
    const step = g.cell_size[0] / 4;
    const Edit = struct { id: []const u8, label: []const u8, cur: f32, d: f32 };
    const rows = [_]Edit{
        .{ .id = "lp_gx", .label = tx.alloc(a, tx.lp_grid_x, .{g.center[0]}), .cur = g.center[0], .d = step },
        .{ .id = "lp_gy", .label = tx.alloc(a, tx.lp_grid_y, .{g.center[1]}), .cur = g.center[1], .d = step },
        .{ .id = "lp_gz", .label = tx.alloc(a, tx.lp_grid_z, .{g.center[2]}), .cur = g.center[2], .d = 5 },
        .{ .id = "lp_gr", .label = tx.alloc(a, tx.lp_grid_turn, .{g.rotation}), .cur = g.rotation, .d = 0.01 },
        .{ .id = "lp_gs", .label = tx.alloc(a, tx.lp_grid_cell, .{g.cell_size[0]}), .cur = g.cell_size[0], .d = 0.5 },
        .{ .id = "lp_gw", .label = tx.alloc(a, tx.lp_grid_w, .{g.width}), .cur = @floatFromInt(g.width), .d = 1 },
        .{ .id = "lp_gh", .label = tx.alloc(a, tx.lp_grid_h, .{g.height}), .cur = @floatFromInt(g.height), .d = 1 },
        .{ .id = "lp_gsw", .label = tx.alloc(a, tx.lp_grid_split_w, .{g.width}), .cur = @floatFromInt(g.width), .d = 1 },
        .{ .id = "lp_gsh", .label = tx.alloc(a, tx.lp_grid_split_h, .{g.height}), .cur = @floatFromInt(g.height), .d = 1 },
    };
    for (rows, 0..) |r, k| {
        const v = stepper(app, a, r.id, r.label, r.cur, r.d);
        if (v == 0) continue;
        const before = map_io.encodeCombatMap(app.gpa, g.*) catch return;
        p.undo.append(app.gpa, .{ .layer = .grid, .whole = before }) catch {
            app.gpa.free(before);
            return;
        };
        switch (k) {
            0, 1 => g.center[k] += v,
            2 => g.center[2] += v,
            3 => g.rotation += v,
            4 => g.cell_size = .{ @max(4, g.cell_size[0] + v), @max(4, g.cell_size[1] + v) },
            5, 6 => resizeGrid(app.gpa, g, if (k == 5) @intFromFloat(v) else 0, if (k == 6) @intFromFloat(v) else 0) catch {},
            else => splitGrid(app.gpa, g, if (k == 7) @intFromFloat(v) else 0, if (k == 8) @intFromFloat(v) else 0) catch {},
        }
    }
    cameraPanel(app, a, p, true);
}

/// `g` cut into `dw` columns / `dh` rows more or fewer over the same floor: the cell
/// size follows, each new cell takes the old cell under its middle. (In a battle the
/// cell size also sets the models' size: actorScale = xSize/350, 0x4b49f0.)
fn splitGrid(gpa: Allocator, g: *core_map.CombatMap, dw: i32, dh: i32) !void {
    const w: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.width)) + dw, 1, 255));
    const h: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.height)) + dh, 1, 255));
    const cells = try gpa.alloc(bool, w * h);
    errdefer gpa.free(cells);
    for (0..h) |y| for (0..w) |x| {
        const ox = (2 * x + 1) * g.width / (2 * w);
        const oy = (2 * y + 1) * g.height / (2 * h);
        cells[y * w + x] = g.blocked[oy * g.width + ox];
    };
    // Heights follow the cells: each new cell takes its old cell's.
    var hs: std.ArrayList([3]i32) = .empty;
    errdefer hs.deinit(gpa);
    for (0..h) |y| for (0..w) |x| {
        const ox: i32 = @intCast((2 * x + 1) * g.width / (2 * w));
        const oy: i32 = @intCast((2 * y + 1) * g.height / (2 * h));
        for (g.heights) |ht| if (ht[0] == ox and ht[1] == oy) {
            try hs.append(gpa, .{ @intCast(x), @intCast(y), ht[2] });
            break;
        };
    };
    gpa.free(g.heights);
    g.heights = try hs.toOwnedSlice(gpa);
    g.cell_size = .{ g.cell_size[0] * @as(f32, @floatFromInt(g.width)) / @as(f32, @floatFromInt(w)), g.cell_size[1] * @as(f32, @floatFromInt(g.height)) / @as(f32, @floatFromInt(h)) };
    gpa.free(g.blocked);
    g.blocked = cells;
    g.width = w;
    g.height = h;
}

/// One camera key changed by `dv` in the Store's script (as the panel's buttons).
pub fn cameraStep(app: *App, key: []const u8, dv: f32) !void {
    const d = app.doc orelse return error.NoLevel;
    const l = d.world.level orelse return error.NoLevel;
    var v: ?f32 = null;
    inline for (Doc.camera_keys) |k| if (std.mem.eql(u8, k, key)) {
        v = og.fields.getF(l, k);
    };
    try d.setCamera(&.{.{ key, (v orelse return error.NoSuchKey) + dv }});
}

/// `g` split into `w` × `h` cells over the same floor (CLI; the panel steps by one).
pub fn gridSplitTo(app: *App, p: *Paint, w: u32, h: u32) !void {
    const g = &(p.grid orelse return error.NoGrid);
    try p.undo.append(app.gpa, .{ .layer = .grid, .whole = try map_io.encodeCombatMap(app.gpa, g.*) });
    try splitGrid(app.gpa, g, @as(i32, @intCast(w)) - @as(i32, @intCast(g.width)), @as(i32, @intCast(h)) - @as(i32, @intCast(g.height)));
}

/// The battle's camera (initCamera() of its script): where it looks from and to, its
/// angle and floor level, for a picture rendered from elsewhere. Each change is a
/// history step; the level reloads to show the grid and fighters through it.
/// `titled`: its own header and hint (under the grid; the camera tool has its own).
pub fn cameraPanel(app: *App, a: Allocator, p: *Paint, titled: bool) void {
    const d = app.doc orelse return;
    const l = d.world.level orelse return;
    if (d.world.cam != .persp) return orthoPanel(app, a, d);
    if (titled) {
        gui.subhead(tx.get(tx.lp_camera));
        gui.note(tx.get(tx.lp_camera_hint));
    }
    // As the concept's: position and target as X Y Z, then the single values.
    const Row = struct { label: tx.Msg, keys: []const []const u8, prefixes: []const []const u8 };
    const rows = [_]Row{
        .{ .label = tx.cam_position, .keys = &.{ "eye_x", "eye_y", "eye_z" }, .prefixes = &.{ "X", "Y", "Z" } },
        .{ .label = tx.cam_target, .keys = &.{ "target_x", "target_y", "target_z" }, .prefixes = &.{ "X", "Y", "Z" } },
        .{ .label = tx.cam_fov, .keys = &.{"fov"}, .prefixes = &.{"°"} },
        .{ .label = tx.cam_floor, .keys = &.{"floor_z"}, .prefixes = &.{""} },
        .{ .label = tx.cam_bank, .keys = &.{"camera_bank"}, .prefixes = &.{"°"} },
    };
    var set: ?struct { key: []const u8, v: f32 } = null;
    for (rows) |r| {
        // X Y Z: under their label, the whole row (beside it they are too narrow for the
        // camera's numbers).
        if (r.keys.len == 3) {
            gui.fieldRow(tx.get(r.label));
            clay.close();
            gui.row(lay.space.sm);
        } else gui.fieldRow(tx.get(r.label));
        for (r.keys, r.prefixes) |k, pre| {
            const v = camVar(l, k);
            if (gui.numberField(app, a, std.fmt.allocPrint(a, "lp_cam_{s}", .{k}) catch k, pre, v, if (r.keys.len == 3) 0 else lay.width.field)) |nv| set = .{ .key = k, .v = nv };
        }
        clay.close();
    }
    const s = set orelse return;
    if (level_og.blockFile(d) != null) {
        d.setCamera(&.{.{ s.key, s.v }}) catch |err| return app.failed(err);
        p.pending = .reload;
        return;
    }
    const t = d.withCamera(app.gpa, &.{.{ s.key, s.v }}) catch |err| return app.failed(err);
    app.store.replaceLabeled(d.lev, t, std.fmt.allocPrint(a, "{s} = {d:.3}", .{ s.key, s.v }) catch null) catch |err| {
        app.gpa.free(t);
        return app.failed(err);
    };
    p.pending = .reload;
}

/// Camera key `k` of the level object (camera_keys).
fn camVar(l: anytype, k: []const u8) f32 {
    inline for (Doc.camera_keys) |ck| if (std.mem.eql(u8, ck, k)) return og.fields.getF(l, ck);
    return 0;
}

/// The camera gizmo, in the middle of the view: rings turn the camera about its aim
/// (green: round the vertical, red: up/down, blue: the bank `camBan`), the centre
/// moves it, the wheel over it brings it nearer (Shift: the view angle). The level
/// shows it live; the script gets it when the pointer rests (one history step).
pub const gizmo_r: f32 = 90;

fn gizmoCenter(rect: c.SDL_FRect) [2]f32 {
    return .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
}

/// The gizmo's part under window point `m`.
fn ringAt(rect: c.SDL_FRect, m: [2]f32) ?Ring {
    const o = gizmoCenter(rect);
    const dx = m[0] - o[0];
    const dy = m[1] - o[1];
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist <= 16) return .pan;
    if (onEllipse(dx, dy, gizmo_r, gizmo_r * 0.35)) return .yaw;
    if (onEllipse(dx, dy, gizmo_r * 0.35, gizmo_r)) return .pitch;
    if (@abs(dist - gizmo_r * 1.25) <= 8) return .roll;
    return null;
}

/// (dx, dy) within 7 pixels of the ellipse with half-axes a, b (along its own ray).
fn onEllipse(dx: f32, dy: f32, a: f32, b: f32) bool {
    const e = @sqrt((dx / a) * (dx / a) + (dy / b) * (dy / b));
    if (e < 1e-3) return false;
    const dist = @sqrt(dx * dx + dy * dy);
    return @abs(dist - dist / e) <= 7;
}

fn ellipse(r: *c.SDL_Renderer, o: [2]f32, a: f32, b: f32, rgb: [3]u8, hot: bool) void {
    _ = c.SDL_SetRenderDrawColor(r, rgb[0], rgb[1], rgb[2], if (hot) 255 else 170);
    // Hot: drawn three times, a pixel apart (thicker).
    const n: usize = if (hot) 3 else 1;
    for (0..n) |w| {
        const k = @as(f32, @floatFromInt(w)) - @as(f32, @floatFromInt(n / 2));
        var prev: [2]f32 = .{ o[0] + a + k, o[1] };
        for (1..65) |i| {
            const t = @as(f32, @floatFromInt(i)) / 64 * std.math.tau;
            const nx: [2]f32 = .{ o[0] + (a + k) * @cos(t), o[1] + (b + k) * @sin(t) };
            _ = c.SDL_RenderLine(r, prev[0], prev[1], nx[0], nx[1]);
            prev = nx;
        }
    }
}

pub fn drawGizmo(app: *App, p: *const Paint, d: *const Doc, rect: c.SDL_FRect) void {
    const r = app.r;
    const o = gizmoCenter(rect);
    const hot = p.cam_ring orelse ringAt(rect, app.mouse);
    // Where it turns about: the aim (camera → world is (X, Z, Y) / cameraScale).
    if (d.world.cam == .persp) if (d.world.level) |l| {
        const s = d.world.cam.persp.scale;
        const q = d.world.cam.project(.{ og.fields.getF(l, "target_x") / s, og.fields.getF(l, "target_z") / s, og.fields.getF(l, "target_y") / s });
        const a = screen(d, rect, .{ q.x, q.y });
        ink(r, lay.canvas.aim);
        _ = c.SDL_RenderLine(r, a[0] - 8, a[1], a[0] + 8, a[1]);
        _ = c.SDL_RenderLine(r, a[0], a[1] - 8, a[0], a[1] + 8);
    };
    ellipse(r, o, gizmo_r * 1.25, gizmo_r * 1.25, lay.canvas.roll, hot == .roll);
    ellipse(r, o, gizmo_r, gizmo_r * 0.35, lay.canvas.yaw, hot == .yaw);
    ellipse(r, o, gizmo_r * 0.35, gizmo_r, lay.canvas.pitch, hot == .pitch);
    ink(r, lay.canvas.marker_edge);
    _ = c.SDL_RenderFillRect(r, &.{ .x = o[0] - 11, .y = o[1] - 11, .w = 22, .h = 22 });
    ink(r, lay.canvas.alpha(lay.canvas.white, if (hot == .pan) 255 else 190));
    _ = c.SDL_RenderFillRect(r, &.{ .x = o[0] - 8, .y = o[1] - 8, .w = 16, .h = 16 });
}

fn camKeys(l: anytype) [Doc.camera_keys.len]f32 {
    var v: [Doc.camera_keys.len]f32 = undefined;
    inline for (Doc.camera_keys, 0..) |k, i| v[i] = og.fields.getF(l, k);
    return v;
}

/// The level's camera set to `v` (camera_keys order) and shown; false (and nothing
/// changed) when it makes no picture (looking straight down).
fn camSet(p: *Paint, d: *Doc, l: anytype, v: [Doc.camera_keys.len]f32) bool {
    const old = camKeys(l);
    inline for (Doc.camera_keys, 0..) |k, i| og.fields.setF(l, k, v[i]);
    const cam = og.world.start.makeCamera(d.world, l);
    if (cam != .persp) {
        inline for (Doc.camera_keys, 0..) |k, i| og.fields.setF(l, k, old[i]);
        return false;
    }
    if (p.cam_base == null) p.cam_base = old;
    d.world.cam = cam;
    p.cam_at = c.SDL_GetTicks();
    return true;
}

/// Pressed at window point `m`: a part of the gizmo grabbed (false off it: the map moves).
pub fn cameraPress(p: *Paint, rect: c.SDL_FRect, m: [2]f32) bool {
    p.cam_ring = ringAt(rect, m) orelse return false;
    p.cam_last = m;
    return true;
}

/// The grabbed part dragged to window point `m`.
pub fn cameraDrag(p: *Paint, d: *Doc, rect: c.SDL_FRect, m: [2]f32) void {
    const ring = p.cam_ring orelse return;
    const l = d.world.level orelse return;
    if (d.world.cam != .persp) return;
    const cam = d.world.cam.persp;
    var v = camKeys(l);
    const dx = m[0] - p.cam_last[0];
    const dy = m[1] - p.cam_last[1];
    const vec = og.vec;
    var aim: [3]f32 = v[3..6].*;
    var off = vec.sub(v[0..3].*, aim);
    const dist = @sqrt(vec.dot(off, off));
    switch (ring) {
        // Round the vertical (camera Y).
        .yaw => {
            const t = -dx * 0.006;
            off = .{ off[0] * @cos(t) + off[2] * @sin(t), off[1], -off[0] * @sin(t) + off[2] * @cos(t) };
        },
        // Up/down over the aim, short of straight up or down.
        .pitch => {
            const h = @sqrt(off[0] * off[0] + off[2] * off[2]);
            const e = std.math.clamp(std.math.atan2(off[1], h) + dy * 0.006, -1.5, 1.5);
            const k = if (h > 1e-6) dist * @cos(e) / h else 0;
            off = .{ off[0] * k, dist * @sin(e), off[2] * k };
        },
        // The bank: the pointer's turn round the gizmo centre.
        .roll => {
            const o = gizmoCenter(rect);
            const a0 = std.math.atan2(p.cam_last[1] - o[1], p.cam_last[0] - o[0]);
            const a1 = std.math.atan2(m[1] - o[1], m[0] - o[0]);
            var da = a1 - a0;
            if (da > std.math.pi) da -= std.math.tau;
            if (da < -std.math.pi) da += std.math.tau;
            v[8] -= da * 180 / std.math.pi;
        },
        // Camera and aim together, so the picture under the pointer follows it.
        .pan => {
            const k = dist / cam.focal / d.zoom;
            const move = vec.add(mul(cam.right, -dx * k), mul(cam.up, dy * k));
            aim = vec.add(aim, move);
        },
    }
    v[0..3].* = vec.add(aim, off);
    v[3..6].* = aim;
    p.cam_last = m;
    _ = camSet(p, d, l, v);
}

fn mul(a: [3]f32, k: f32) [3]f32 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}

/// Released: the moved camera written.
pub fn cameraRelease(app: *App, p: *Paint) void {
    if (p.cam_ring == null) return;
    p.cam_ring = null;
    camCommit(app, p);
}

/// The wheel at window point `m` over the gizmo: nearer/farther (`fov`: the view
/// angle narrower/wider); false off it (the view zooms).
pub fn cameraWheel(p: *Paint, d: *Doc, rect: c.SDL_FRect, m: [2]f32, notches: f32, fov: bool) bool {
    const o = gizmoCenter(rect);
    if (std.math.hypot(m[0] - o[0], m[1] - o[1]) > gizmo_r * 1.25 + 10) return false;
    const l = d.world.level orelse return false;
    if (d.world.cam != .persp) return false;
    var v = camKeys(l);
    const k = std.math.pow(f32, 0.92, notches);
    if (fov) {
        v[6] = std.math.clamp(v[6] * k, 5, 150);
    } else {
        const vec = og.vec;
        const aim: [3]f32 = v[3..6].*;
        const off = vec.sub(v[0..3].*, aim);
        if (vec.dot(off, off) * k * k > 1e-4) v[0..3].* = vec.add(aim, mul(off, k));
    }
    _ = camSet(p, d, l, v);
    return true;
}

/// The camera moved since the last write: its changed keys into initCamera(), one step.
pub fn camCommit(app: *App, p: *Paint) void {
    const base = p.cam_base orelse return;
    p.cam_base = null;
    const d = app.doc orelse return;
    const l = d.world.level orelse return;
    const v = camKeys(l);
    var kv: [Doc.camera_keys.len]struct { []const u8, f32 } = undefined;
    var n: usize = 0;
    inline for (Doc.camera_keys, 0..) |k, i| if (v[i] != base[i]) {
        kv[n] = .{ k, v[i] };
        n += 1;
    };
    d.setCamera(kv[0..n]) catch |err| return app.failed(err);
    // The fighters' marks are placed on load.
    p.pending = .reload;
}

/// `g` with `dw` columns / `dh` rows more (new cells free) or fewer (1…255 each).
fn resizeGrid(gpa: Allocator, g: *core_map.CombatMap, dw: i32, dh: i32) !void {
    const w: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.width)) + dw, 1, 255));
    const h: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.height)) + dh, 1, 255));
    const cells = try gpa.alloc(bool, w * h);
    errdefer gpa.free(cells);
    for (0..h) |y| for (0..w) |x| {
        cells[y * w + x] = if (x < g.width and y < g.height) g.blocked[y * g.width + x] else false;
    };
    // Heights of cells cut off go with them (the `.cm` lists cells by x, y).
    var n: usize = 0;
    for (g.heights) |ht| n += @intFromBool(ht[0] >= 0 and ht[1] >= 0 and ht[0] < w and ht[1] < h);
    const hs = try gpa.alloc([3]i32, n);
    n = 0;
    for (g.heights) |ht| if (ht[0] >= 0 and ht[1] >= 0 and ht[0] < w and ht[1] < h) {
        hs[n] = ht;
        n += 1;
    };
    gpa.free(g.heights);
    g.heights = hs;
    gpa.free(g.blocked);
    g.blocked = cells;
    g.width = w;
    g.height = h;
}
