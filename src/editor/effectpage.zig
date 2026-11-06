//! Effects tab: a weapon or spell effect (`gfx_3d\effects\<name>\<name>.dsc`: the list of
//! its frames, each a texture `.3df` beside it — flame, smoke, explosions) as its frames
//! with a looping preview; a frame replaced from a PNG (at the frame's size), one added
//! after the last (the next number), one taken out of the list. One undo step each.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const c = @import("sdl");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const art = @import("art.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const common_archive = @import("store.zig").common_archive;

/// The Effects tab's state (`app.effect`): the effect shown, its frames' textures
/// (entry → texture).
pub const State = struct {
    sel: app_mod.Name(64) = .{},
    tex: std.StringHashMapUnmanaged(?*c.SDL_Texture) = .empty,
};

const prefix = "gfx_3d\\effects\\";

/// The effects (folders with a `.dsc`; new ones too).
pub fn names(app: *App, a: Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (app.store.listing(a, common_archive, struct {
        fn f(e: []const u8) bool {
            return std.ascii.startsWithIgnoreCase(e, prefix) and std.ascii.endsWithIgnoreCase(e, ".dsc");
        }
    }.f, false)) |e| {
        const rest = e[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '\\') orelse continue;
        out.append(a, a.dupe(u8, rest[0..slash]) catch continue) catch {};
    }
    return out.items;
}

fn dscEntry(a: Allocator, name: []const u8) []const u8 {
    return std.fmt.allocPrint(a, prefix ++ "{s}\\{s}.dsc", .{ name, name }) catch "";
}

/// The frame file names the `.dsc` lists, in order (as the game reads it: no `[alpha]`
/// header, up to an empty line).
fn frames(app: *App, a: Allocator, name: []const u8) []const []const u8 {
    const f = app.store.file(common_archive, dscEntry(a, name)) catch return &.{};
    const d = og.formats.dsc.parse(a, app.store.text(f)) catch return &.{};
    return d.frames;
}

/// Frame `frame` of effect `name` as a texture (kept per frame; dropped when replaced).
fn texture(app: *App, a: Allocator, name: []const u8, frame: []const u8) ?Tex {
    return cached(app, std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, frame }) catch return null);
}

const Tex = struct { tex: *c.SDL_Texture, w: f32, h: f32 };

/// Texture `entry` of common/other.dat (a `.3df`) to draw, kept until `forget`.
pub fn cached(app: *App, entry: []const u8) ?Tex {
    var kb: [160]u8 = undefined;
    const key = std.ascii.lowerString(&kb, entry[0..@min(entry.len, kb.len)]);
    const t = app.effect.tex.get(key) orelse blk: {
        const made = make(app, entry);
        const k = app.gpa.dupe(u8, key) catch return null;
        app.effect.tex.put(app.gpa, k, made) catch app.gpa.free(k);
        break :blk made;
    };
    const tex = t orelse return null;
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(tex, &w, &h);
    return .{ .tex = tex, .w = w, .h = h };
}

fn make(app: *App, entry: []const u8) ?*c.SDL_Texture {
    const f = app.store.file(common_archive, entry) catch return null;
    var img = og.formats.tex3df.decode(app.gpa, app.store.text(f)) catch return null;
    defer img.deinit(app.gpa);
    const t = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
    _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    return t;
}

pub fn forget(app: *App, entry: []const u8) void {
    var kb: [160]u8 = undefined;
    const key = std.ascii.lowerString(&kb, entry[0..@min(entry.len, kb.len)]);
    const kv = app.effect.tex.fetchRemove(key) orelse return;
    if (kv.value) |t| c.SDL_DestroyTexture(t);
    app.gpa.free(kv.key);
}

pub fn page(app: *App, a: Allocator) void {
    const name = app.effect.sel.get();
    if (name.len == 0) return;
    const fs = frames(app, a, name);
    const pid = clay.id("effect_page");
    @import("frame.zig").stage(app);
    clay.openScroll(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.lg), .childGap = lay.space.md } });
    gui.row(lay.space.md);
    gui.icon(app, .image, lay.icon.xl, theme.accent_hover);
    gui.txt(name, .heading, theme.text, font_mod.bold);
    clay.close();
    // The preview: the frames in turn, 15 a second.
    if (fs.len > 0) {
        const k: usize = @intCast((c.SDL_GetTicks() / 66) % fs.len);
        if (texture(app, a, name, fs[k])) |t| {
            const s = @min(2, 32 * lay.unit / @max(t.w, t.h));
            clay.open(.{ .layout = .{ .padding = gui.pad(lay.space.sm, lay.space.sm) }, .backgroundColor = theme.viewport, .cornerRadius = clay.radius(lay.radius.md) });
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(t.w * s), .height = clay.fixed(t.h * s) } }, .image = .{ .imageData = t.tex } });
            clay.close();
        }
    }
    // The frames: each with its name, from a PNG, out of the list; as many cards a row
    // as the page fits (auto-fit).
    const card_w = 19 * lay.unit;
    const per = if (clay.box(pid)) |b| lay.autoFit(b.width - 2 * lay.space.xl, lay.space.sm, card_w) else 6;
    var i: usize = 0;
    while (i < fs.len) : (i += per) {
        clay.open(.{ .layout = .{ .childGap = lay.space.sm } });
        for (fs[i..@min(fs.len, i + per)], i..) |fr, k| {
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(card_w) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.sm, lay.space.sm), .childGap = lay.space.xs }, .backgroundColor = theme.field, .cornerRadius = clay.radius(lay.radius.md) });
            gui.txt(std.fmt.allocPrint(a, "{d}. {s}", .{ k + 1, fr }) catch fr, .caption, theme.text, font_mod.regular);
            if (texture(app, a, name, fr)) |t| {
                const s = @min(1, 16 * lay.unit / @max(t.w, t.h));
                clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(t.w * s), .height = clay.fixed(t.h * s) } }, .image = .{ .imageData = t.tex } });
            }
            clay.open(.{ .layout = .{ .childGap = lay.space.xs } });
            if (gui.toolButton(app, std.fmt.allocPrint(a, "ef_png{d}", .{k}) catch "p", .image, "", false, false)) app.askFile(.{ .kind = .png, .run = onFrameIn, .entry = k });
            if (gui.toolButton(app, std.fmt.allocPrint(a, "ef_del{d}", .{k}) catch "d", .trash_2, "", false, false)) app.askDelete(.effect_frame, k, fr);
            clay.close();
            clay.close();
        }
        clay.close();
    }
    clay.close();
    @import("frame.zig").props(app, "effect_props");
    gui.groupTitle(tx.get(tx.props), true);
    gui.propRow(tx.get(tx.p_file), dscEntry(a, name));
    gui.propRow(tx.get(tx.p_frames), std.fmt.allocPrint(a, "{d}", .{fs.len}) catch "");
    gui.note(tx.alloc(a, tx.ef_hint, .{fs.len}));
    gui.groupTitle(tx.get(tx.p_actions), false);
    if (gui.toolButton(app, "ef_add", .plus, tx.get(tx.ef_add), false, false)) app.askFile(.{ .kind = .png, .run = onFrameAdd });
    if (gui.toolButton(app, "ef_new", .plus, tx.get(tx.ef_new), false, false)) _ = newEffect(app) catch |err| app.failed(err);
    gui.note(tx.get(tx.ef_new_hint));
    gui.propsEnd();
}

/// Frame `k` from PNG `path` (the frame's size: the effect's sprites keep it; in an
/// OpenGorky project as large as the PNG allows, argb8888 — art.modelTexture).
fn replaceFrame(app: *App, k: usize, path: []const u8) !void {
    const a = app.frame.allocator();
    const name = app.effect.sel.get();
    const fs = frames(app, a, name);
    if (k >= fs.len) return error.NoFrame;
    const entry = try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, fs[k] });
    const f = try app.store.file(common_archive, entry);
    var orig = try og.formats.tex3df.decode(app.gpa, app.store.text(f));
    defer orig.deinit(app.gpa);
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    const bytes = try art.modelTexture(app.gpa, img, orig, app.importTarget());
    try app.store.replaceLabeled(f, bytes, entry);
    forget(app, entry);
}

/// A frame from PNG `path` after the last (named as the last with the next number; the
/// size of the others, larger in OpenGorky as in replaceFrame).
pub fn addFrame(app: *App, path: []const u8) !void {
    const a = app.frame.allocator();
    const name = app.effect.sel.get();
    const fs = frames(app, a, name);
    if (fs.len == 0) return error.NoFrame;
    const last = fs[fs.len - 1];
    const stem = last[0 .. std.mem.lastIndexOfScalar(u8, last, '.') orelse last.len];
    var ds = stem.len;
    while (ds > 0 and std.ascii.isDigit(stem[ds - 1])) ds -= 1;
    const digits = stem.len - ds;
    var n = (std.fmt.parseInt(u32, stem[ds..], 10) catch 0) + 1;
    const new = while (n < 100000) : (n += 1) {
        const s = if (digits > 0) try std.fmt.allocPrint(a, "{s}{d:0>4}.3df", .{ stem[0..ds], n }) else try std.fmt.allocPrint(a, "{s}{d}.3df", .{ stem, n });
        if ((app.store.file(common_archive, try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, s })) catch null) == null) break s;
    } else return error.NoFreeName;
    var orig = try og.formats.tex3df.decode(app.gpa, app.store.text(try app.store.file(common_archive, try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, last }))));
    defer orig.deinit(app.gpa);
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    const tex = try art.modelTexture(app.gpa, img, orig, app.importTarget());
    const df = try app.store.file(common_archive, dscEntry(a, name));
    const t = app.store.text(df);
    const nl = if (t.len == 0 or std.mem.endsWith(u8, t, "\n")) "" else "\r\n";
    const dsc = try std.mem.concat(app.gpa, u8, &.{ t, nl, new, "\r\n" });
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, new }), .text = tex }});
    try app.store.replaceLabeled(df, dsc, dscEntry(a, name));
}

/// Frame `k` out of the effect's list (its texture stays; the blend header kept).
pub fn removeFrame(app: *App, k: usize) !void {
    const a = app.frame.allocator();
    const name = app.effect.sel.get();
    const df = try app.store.file(common_archive, dscEntry(a, name));
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, app.store.text(df), '\n');
    var i: usize = 0;
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0) continue;
        if (l[0] != '[') {
            defer i += 1;
            if (i == k) continue;
        }
        try out.appendSlice(a, l);
        try out.appendSlice(a, "\r\n");
    }
    try app.store.replaceLabeled(df, try app.gpa.dupe(u8, out.items), dscEntry(a, name));
}

/// A new effect from no other (`gfx_3d\effects\fx_new_<n>\`): an additive `.dsc` with
/// one frame, a soft white dot 64×64 (argb4444, as the game's frames: the exe reads it);
/// its frames then replaced or added from PNGs. Shown; one undo step. Returns its name.
pub fn newEffect(app: *App) ![]const u8 {
    const a = app.frame.allocator();
    const have = names(app, a);
    var n: u32 = 1;
    const name = while (n < 1000) : (n += 1) {
        const s = try std.fmt.allocPrint(a, "fx_new_{d}", .{n});
        for (have) |x| {
            if (std.ascii.eqlIgnoreCase(x, s)) break;
        } else if ((app.store.file(common_archive, dscEntry(a, s)) catch null) == null) break s;
    } else return error.NoFreeName;
    var img = try og.image.Image.init(app.gpa, 64, 64);
    defer img.deinit(app.gpa);
    for (0..64) |y| for (0..64) |x| {
        const dx = (@as(f32, @floatFromInt(x)) - 31.5) / 32;
        const dy = (@as(f32, @floatFromInt(y)) - 31.5) / 32;
        const v: u8 = @intFromFloat(255 * std.math.clamp(1 - @sqrt(dx * dx + dy * dy), 0, 1));
        img.pixels[(y * 64 + x) * 4 ..][0..4].* = .{ v, v, v, v };
    };
    const tex = try og.formats.tex3df.encodeArgb4444(app.gpa, img);
    const dsc = try app.gpa.dupe(u8, "[add]\r\nfx0001.3df\r\n");
    _ = try app.store.addNew(&.{
        .{ .archive = common_archive, .entry = try std.fmt.allocPrint(a, prefix ++ "{s}\\fx0001.3df", .{name}), .text = tex },
        .{ .archive = common_archive, .entry = dscEntry(a, name), .text = dsc },
    });
    app.effect.sel.set(name);
    app.setStatus(tx.st_effect_new, .{name});
    return name;
}

// File dialog answers (app.askFile).
fn onFrameIn(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    try replaceFrame(app, ask.entry, path);
    app.setStatus(tx.st_frame_set, .{ask.entry + 1});
}
fn onFrameAdd(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    try addFrame(app, path);
    app.setStatus(tx.st_frame_added, .{});
}
