//! A location's bitmap animations: `<name>.ba` (BitmapAnimation: water, lamps — they
//! loop) and `<name>.aba` (ActiveBitmapAnimation: doors, gates — scripts play them,
//! ABA_Impulse) in its archive, each placed by `variables\<name>.var` (pos_x, pos_y: its
//! frames' top-left on the background). The exe reads `.var` first, then init() (start.zig),
//! so the sprite and speed are set in the script, the place in `.var`. Listed beside the
//! objects, drawn on the map (outlines; the picked one's frame), dragged in the Objects
//! tool, made from a level sprite, deleted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const ink = @import("render.zig").ink;
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const doctabs = @import("doctabs.zig");
const sprview = @import("sprview.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const model = @import("model.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const common_archive = @import("store.zig").common_archive;

/// The location's bitmap animations (`app.anims`): the picked one, shown on the map,
/// the new-one sprite list open, one being dragged, first frames (key → texture).
pub const State = struct {
    sel: app_mod.Name(64) = .{},
    shown: bool = true,
    add_open: bool = false,
    drag: ?app_mod.AnimDrag = null,
    tex: std.StringHashMapUnmanaged(?*c.SDL_Texture) = .empty,
};

pub const Anim = struct {
    name: []const u8,
    /// Its script (Store index); with no `.var` it stands at 0,0.
    file: usize,
    active: bool,
    pos: [2]i32,
    speed: i32,
    sprite: []const u8,
    zbuf: []const u8,
};

/// The level's animations as the Store has them (names in `a`).
pub fn list(app: *App, a: Allocator, d: *Doc) []const Anim {
    var out: std.ArrayList(Anim) = .empty;
    for (app.store.listing(a, d.level_archive, isAnim, false)) |entry| {
        const fi = app.store.file(d.level_archive, entry) catch continue;
        if (app.store.gone(fi)) continue;
        const name = entry[0 .. std.mem.lastIndexOfScalar(u8, entry, '.') orelse entry.len];
        const script = app.store.text(fi);
        const vf = d.varFile(name);
        const vt = if (vf) |v| app.store.text(v) else "";
        out.append(a, .{
            .name = name,
            .file = fi,
            .active = std.ascii.endsWithIgnoreCase(entry, ".aba"),
            .pos = .{ @intFromFloat(level.varValue(vt, "pos_x") orelse 0), @intFromFloat(level.varValue(vt, "pos_y") orelse 0) },
            .speed = @intFromFloat(model.get(script, "frames_per_second") orelse level.varValue(vt, "frames_per_second") orelse 15),
            .sprite = model.getStr(script, "sprite") orelse "",
            .zbuf = model.getStr(script, "depth_sprite") orelse "",
        }) catch {};
    }
    return out.items;
}

fn isAnim(entry: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(entry, ".ba") or std.ascii.endsWithIgnoreCase(entry, ".aba");
}

/// The first frame of sprite `name` of the level (a texture kept per sprite).
fn frameOf(app: *App, d: *Doc, name: []const u8) ?struct { tex: *c.SDL_Texture, w: f32, h: f32 } {
    if (name.len == 0) return null;
    var kb: [128]u8 = undefined;
    const key = std.ascii.lowerString(&kb, std.fmt.bufPrint(&kb, "{s}/{s}", .{ d.name, name }) catch return null);
    if (app.anims.tex.get(key)) |t| return if (t) |tex| .{ .tex = tex, .w = texW(tex), .h = texH(tex) } else null;
    const tex = decode(app, d, name);
    const k = app.gpa.dupe(u8, key) catch return null;
    app.anims.tex.put(app.gpa, k, tex) catch app.gpa.free(k);
    return if (tex) |t| .{ .tex = t, .w = texW(t), .h = texH(t) } else null;
}

fn texW(t: *c.SDL_Texture) f32 {
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(t, &w, &h);
    return w;
}

fn texH(t: *c.SDL_Texture) f32 {
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(t, &w, &h);
    return h;
}

fn decode(app: *App, d: *Doc, name: []const u8) ?*c.SDL_Texture {
    var ab: [96]u8 = undefined;
    const archive = std.fmt.bufPrint(&ab, "{s}/sprite.dat", .{d.name}) catch return null;
    var eb: [96]u8 = undefined;
    const entry = std.fmt.bufPrint(&eb, "{s}.spr", .{name}) catch return null;
    const fi = app.store.file(archive, entry) catch return null;
    var spr = og.formats.sprite.parse(app.gpa, app.store.text(fi)) catch return null;
    defer spr.deinit(app.gpa);
    if (spr.frames.len == 0) return null;
    var img = og.formats.sprite.decodeFrame(app.gpa, spr.frames[0]) catch return null;
    defer img.deinit(app.gpa);
    const t = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
    _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    return t;
}

/// Over the level's map: each animation's outline, the picked one's frame (or the one
/// being dragged, where it goes).
pub fn draw(app: *App, d: *Doc, rect: c.SDL_FRect) void {
    if (!shown(app, d)) return;
    const a = app.frame.allocator();
    for (list(app, a, d)) |an| {
        const fr = frameOf(app, d, an.sprite);
        var p: [2]f32 = .{ @floatFromInt(an.pos[0]), @floatFromInt(an.pos[1]) };
        if (app.anims.drag) |dr| if (std.mem.eql(u8, dr.name(), an.name)) {
            p = dr.at;
        };
        const s = d.toScreen(rect, p);
        const w = (if (fr) |f| f.w else 24) * d.zoom;
        const h = (if (fr) |f| f.h else 24) * d.zoom;
        const sel = std.mem.eql(u8, app.anims.sel.get(), an.name);
        if (sel) if (fr) |f| {
            _ = c.SDL_RenderTexture(app.r, f.tex, null, &.{ .x = s[0], .y = s[1], .w = w, .h = h });
        };
        ink(app.r, lay.canvas.alpha(lay.canvas.anim, if (sel) 255 else 140));
        _ = c.SDL_RenderRect(app.r, &.{ .x = s[0], .y = s[1], .w = w, .h = h });
        if (sel) _ = c.SDL_RenderRect(app.r, &.{ .x = s[0] - 1, .y = s[1] - 1, .w = w + 2, .h = h + 2 });
        app.font.draw(app.r, an.name, font_mod.regular, lay.Type.body.pt(), s[0] + 3, s[1] - 17, lay.canvas.anim_text);
    }
}

/// On the map: their eye open and, in the edit mode, the "Areas and objects" layer's.
fn shown(app: *App, d: *Doc) bool {
    return !d.isBattle() and app.anims.shown and (if (app.paint) |p| p.show_objects else true);
}

const Hit = struct { name: []const u8, pos: [2]f32 };

/// The animation under screen point `p` (the picked one first); its top-left.
pub fn hit(app: *App, d: *Doc, rect: c.SDL_FRect, p: [2]f32) ?Hit {
    if (!shown(app, d)) return null;
    const a = app.frame.allocator();
    const bg = d.toBackground(rect, p);
    var found: ?Hit = null;
    for (list(app, a, d)) |an| {
        const fr = frameOf(app, d, an.sprite);
        const x: f32 = @floatFromInt(an.pos[0]);
        const y: f32 = @floatFromInt(an.pos[1]);
        const w = if (fr) |f| f.w else 24;
        const h = if (fr) |f| f.h else 24;
        if (bg[0] < x or bg[1] < y or bg[0] > x + w or bg[1] > y + h) continue;
        found = .{ .name = an.name, .pos = .{ x, y } };
        if (std.mem.eql(u8, app.anims.sel.get(), an.name)) break;
    }
    return found;
}

/// Animation `name` placed at `pos` (its `.var`; one undo step).
pub fn place(app: *App, d: *Doc, name: []const u8, pos: [2]f32) void {
    const vf = d.varFile(name) orelse return app.setStatus(tx.st_anim_novar, .{name});
    var t = app.gpa.dupe(u8, app.store.text(vf)) catch return;
    var vb: [2][24]u8 = undefined;
    for ([_][]const u8{ "pos_x", "pos_y" }, 0..) |k, i| {
        const v = std.fmt.bufPrint(&vb[i], "{d}", .{@as(i32, @intFromFloat(@round(pos[i])))}) catch return;
        const next = level.setVarLine(app.gpa, t, k, v) catch return;
        app.gpa.free(t);
        t = next;
    }
    app.store.replaceLabeled(vf, t, tx.both(app.frame.allocator(), tx.step_placed, .{name})) catch |err| app.failed(err);
}

/// A new animation of level sprite `sprite` at background point `at`: its script and
/// `.var` (one undo step), picked.
pub fn add(app: *App, d: *Doc, sprite: []const u8, at: [2]f32) void {
    const a = app.frame.allocator();
    const stem = std.fs.path.stem(sprite);
    // The `.var` names are the game's (common), so free there and in the level.
    const name = for (1..1000) |k| {
        const n = (if (k == 1) std.fmt.allocPrint(a, "{s}_anim", .{stem}) else std.fmt.allocPrint(a, "{s}_anim{d}", .{ stem, k })) catch return;
        if (d.varFile(n) == null and (app.store.file(d.level_archive, std.fmt.allocPrint(a, "{s}.ba", .{n}) catch return) catch null) == null) break n;
    } else return;
    const script = std.fmt.allocPrint(app.gpa, "#inherit BitmapAnimation\r\n\r\nfunction init()\r\n{{\r\n\tspriteFile=\"{s}\";\r\n\tspeed=10;\r\n}};\r\n\r\nfunction update()\r\n{{\r\n}};\r\n", .{stem}) catch return;
    const v = std.fmt.allocPrint(app.gpa, "nameID=0\r\npos_x={d}\r\npos_y={d}\r\nspeed=10\r\ncur_frame=0\r\nspriteFile={s}\r\nzbufFile=(null)\r\n", .{ @as(i32, @intFromFloat(at[0])), @as(i32, @intFromFloat(at[1])), stem }) catch return;
    _ = app.store.addNew(&.{
        .{ .archive = d.level_archive, .entry = std.fmt.allocPrint(a, "{s}.ba", .{name}) catch return, .text = script },
        .{ .archive = common_archive, .entry = std.fmt.allocPrint(a, "variables\\{s}.var", .{name}) catch return, .text = v },
    }) catch |err| return app.failed(err);
    app.anims.sel.set(name);
    app.setStatus(tx.st_anim_added, .{name});
}

/// Animation `name` deleted: its script and `.var`.
pub fn remove(app: *App, d: *Doc, name: []const u8) void {
    const a = app.frame.allocator();
    var files: std.ArrayList(usize) = .empty;
    for ([_][]const u8{ ".ba", ".aba" }) |ext| if (app.store.file(d.level_archive, std.fmt.allocPrint(a, "{s}{s}", .{ name, ext }) catch continue)) |f| files.append(a, f) catch {} else |_| {};
    if (d.varFile(name)) |vf| files.append(a, vf) catch {};
    app.store.delete(files.items) catch |err| return app.setStatus(tx.st_remove_failed, .{err});
    app.anims.sel.set("");
}

/// The group under the level's objects: the animations (folded at first), a new one from
/// a level sprite, the picked one's fields.
pub fn group(app: *App, a: Allocator, d: *Doc) void {
    if (d.isBattle()) return;
    const anims = list(app, a, d);
    const okey = "objopen/anims";
    const open = app.tree_open.contains(okey);
    const gid = clay.id(okey);
    const folded = gui.folderRow(app, gid, 0, open, .play, false, tx.get(tx.an_title), true, anims.len, a);
    const eye = gui.eye(app, clay.id("anims_eye"), app.anims.shown);
    clay.close();
    if (eye) app.anims.shown = !app.anims.shown else if (folded) @import("assettree.zig").toggleKey(app, okey);
    if (!open) return;
    for (anims, 0..) |an, k| {
        const sel = std.mem.eql(u8, app.anims.sel.get(), an.name);
        const rid = clay.idi("anim_row", @intCast(k));
        if (gui.listRow(app, rid, .{ .selected = sel, .indent = gui.leafIndent(0) })) app.anims.sel.set(if (sel) "" else an.name);
        gui.txt(an.name, .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.txt(tx.get(if (an.active) tx.an_active else tx.an_loop), .caption, theme.dim, font_mod.regular);
        clay.close();
        if (sel) card(app, a, d, an);
    }
    // New: one of the level's sprites, at the view's middle.
    if (gui.toolButton(app, "anim_new", .plus, tx.get(tx.an_new), app.anims.add_open, false)) app.anims.add_open = !app.anims.add_open;
    if (app.anims.add_open) {
        const spr_archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{d.name}) catch return;
        for (sprview.entries(app, a, spr_archive), 0..) |s, k| {
            if (!std.ascii.endsWithIgnoreCase(s, ".spr")) continue;
            if (gui.toolButton(app, std.fmt.allocPrint(a, "anim_spr{d}", .{k}) catch "s", .image, s, false, false)) {
                const mid = if (app_mod.App.viewportRect()) |v| d.toBackground(v, .{ v.x + v.w / 2, v.y + v.h / 2 }) else [2]f32{ 100, 100 };
                add(app, d, s, mid);
                app.anims.add_open = false;
            }
        }
    }
}

/// The picked animation: sprite, speed, place (typed), its script, delete.
fn card(app: *App, a: Allocator, d: *Doc, an: Anim) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = gui.leafIndent(0), .right = lay.space.sm, .top = lay.space.xs, .bottom = lay.space.sm }, .childGap = lay.space.sm } });
    fieldRow(app, a, tx.an_sprite, "an_spr", an.sprite, an, .sprite, d);
    fieldRow(app, a, tx.an_speed, "an_speed", std.fmt.allocPrint(a, "{d}", .{an.speed}) catch "", an, .speed, d);
    fieldRow(app, a, tx.an_x, "an_x", std.fmt.allocPrint(a, "{d}", .{an.pos[0]}) catch "", an, .x, d);
    fieldRow(app, a, tx.an_y, "an_y", std.fmt.allocPrint(a, "{d}", .{an.pos[1]}) catch "", an, .y, d);
    if (an.zbuf.len > 0) gui.txt(tx.alloc(a, tx.an_zbuf, .{an.zbuf}), .caption, theme.dim, font_mod.regular);
    // Each in a tab of its own, the level's kept; wrapped in a narrow panel.
    const items = [_]gui.Item{
        .{ .id = clay.id("an_code"), .b = .{ .label = tx.get(tx.code_open), .icon = .code, .size = .tool } },
        .{ .id = clay.id("an_sprite_edit"), .b = .{ .label = tx.get(tx.an_edit_sprite), .icon = .image, .size = .tool } },
        .{ .id = clay.id("an_del"), .b = .{ .label = tx.get(tx.cm_delete), .icon = .trash_2, .size = .tool } },
    };
    const clicked = gui.buttonRow(app, clay.id("an_buttons"), &items);
    clay.close();
    switch (clicked orelse return) {
        0 => {
            @import("doctabs.zig").keepCurrent(app);
            doctabs.showCode(app, an.file, null);
        },
        1 => {
            @import("doctabs.zig").keepCurrent(app);
            sprview.openEntry(app, std.fmt.allocPrint(a, "{s}/sprite.dat", .{d.name}) catch return, std.fmt.allocPrint(a, "{s}.spr", .{an.sprite}) catch "") catch |err| app.setStatus(tx.st_open_failed, .{ an.sprite, err });
        },
        else => app.askDelete(.anim, 0, an.name),
    }
}

const Field = enum { sprite, speed, x, y };

fn fieldRow(app: *App, a: Allocator, label: tx.Msg, key: []const u8, value: []const u8, an: Anim, what: Field, d: *Doc) void {
    gui.row(lay.space.sm);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.width.label_min) } } });
    gui.txt(tx.get(label), .caption, theme.dim, font_mod.regular);
    clay.close();
    if (gui.textField(app, key, value, 0, "")) |v| set(app, a, d, an, what, std.mem.trim(u8, v, " ")) catch |err| app.failed(err);
    clay.close();
}

fn set(app: *App, a: Allocator, d: *Doc, an: Anim, what: Field, v: []const u8) !void {
    switch (what) {
        .sprite => try model.set(app, an.file, &.{"sprite"}, try std.fmt.allocPrint(a, "\"{s}\"", .{std.fs.path.stem(v)}), "{"),
        .speed => {
            _ = try std.fmt.parseInt(i32, v, 10);
            try model.set(app, an.file, &.{"frames_per_second"}, v, "{");
        },
        .x, .y => {
            const n: f32 = @floatFromInt(try std.fmt.parseInt(i32, v, 10));
            var p: [2]f32 = .{ @floatFromInt(an.pos[0]), @floatFromInt(an.pos[1]) };
            p[@intFromBool(what == .y)] = n;
            place(app, d, an.name, p);
        },
    }
}
