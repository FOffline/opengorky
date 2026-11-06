//! New art from PNG files: item icons (`icons\<name>.spr` in common/sprite.dat) and
//! model textures. A texture gives a new look: a copy of the model (`gfx_3d\<new>.msh`
//! naming the new `.3df`, its `.ani`/`.bfr` copied) that an item takes as `meshFile`
//! and an enemy through a new `act_*.ss`; the original model stays as it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const Image = og.image.Image;
const model = @import("model.zig");
const common_archive = @import("store.zig").common_archive;
const app_mod = @import("app.zig");
const App = app_mod.App;

const sprite_archive = @import("store.zig").sprite_archive;

/// Icon frames of the game: big (inventory, up to 160×100) and small (51×40).
pub const big = [2]u32{ 160, 100 };
pub const small = [2]u32{ 51, 40 };

pub fn readPng(app: *App, path: []const u8) !Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(64 << 20));
    defer app.gpa.free(bytes);
    return og.formats.jpeg.decode(app.gpa, bytes);
}

pub const resize = og.formats.tex3df.resize;

/// Downscaled to fit `box` keeping the aspect (never enlarged).
pub fn fit(gpa: Allocator, img: Image, box: [2]u32) !Image {
    const k = @min(1.0, @min(@as(f32, @floatFromInt(box[0])) / @as(f32, @floatFromInt(img.width)), @as(f32, @floatFromInt(box[1])) / @as(f32, @floatFromInt(img.height))));
    return resize(gpa, img, @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img.width)) * k)))), @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img.height)) * k)))));
}

/// A free name `<base>_<n>` (from 2) for which `taken` is false, in `a`.
fn freeName(a: Allocator, base: []const u8, ctx: anytype, comptime taken: fn (@TypeOf(ctx), []const u8) bool) ![]const u8 {
    var buf: [128]u8 = undefined;
    return a.dupe(u8, try @import("freename.zig").freeName(&buf, base, .{ .bare = false }, ctx, taken));
}

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
    return false;
}

/// New icon from `png` for item class file `file`; returns its name.
pub fn importIcon(app: *App, file: usize, id: []const u8, png: []const u8) ![]const u8 {
    var img = try readPng(app, png);
    defer img.deinit(app.gpa);
    var b = try fit(app.gpa, img, big);
    defer b.deinit(app.gpa);
    var s = try fit(app.gpa, img, small);
    defer s.deinit(app.gpa);
    const bytes = try og.formats.sprite.encode(app.gpa, &.{ b, s });
    errdefer app.gpa.free(bytes);
    const a = app.catalog.arena.allocator();
    const name = try freeName(a, id, app.catalog.icons.items, inList);
    var eb: [96]u8 = undefined;
    app.store.group();
    defer app.store.endGroup("+ icons\\{s}.spr", .{name});
    _ = try app.store.addNew(&.{.{ .archive = sprite_archive, .entry = try std.fmt.bufPrint(&eb, "icons\\{s}.spr", .{name}), .text = bytes }});
    try app.catalog.icons.append(a, name);
    var vb: [96]u8 = undefined;
    try model.set(app, file, &.{"icon"}, try std.fmt.bufPrint(&vb, "\"{s}\"", .{name}), "{");
    return name;
}

/// Icon `name` (`icons\\<name>.spr`) gets `png` as its first frame, at that frame's
/// size (a report icon, whose name the exe fixes); one undo step.
pub fn replaceIcon(app: *App, name: []const u8, png: []const u8) !void {
    if (name.len == 0) return error.NoIcon;
    var eb: [96]u8 = undefined;
    const entry = try std.fmt.bufPrint(&eb, "icons\\{s}.spr", .{name});
    const f = app.store.find(sprite_archive, entry) orelse try app.store.file(sprite_archive, entry);
    var spr = try og.formats.sprite.parse(app.gpa, app.store.text(f));
    defer spr.deinit(app.gpa);
    var frames: std.ArrayList(Image) = .empty;
    defer {
        for (frames.items) |*fr| fr.deinit(app.gpa);
        frames.deinit(app.gpa);
    }
    for (spr.frames) |fr| try frames.append(app.gpa, try og.formats.sprite.decodeFrame(app.gpa, fr));
    if (frames.items.len == 0) return error.NoFrame;
    var img = try readPng(app, png);
    defer img.deinit(app.gpa);
    const fresh = try resize(app.gpa, img, frames.items[0].width, frames.items[0].height);
    frames.items[0].deinit(app.gpa);
    frames.items[0] = fresh;
    const bytes = try og.formats.sprite.encode(app.gpa, frames.items);
    errdefer app.gpa.free(bytes);
    var lb: [128]u8 = undefined;
    try app.store.replaceLabeled(f, bytes, std.fmt.bufPrint(&lb, "{s}: PNG", .{entry}) catch entry);
    app.forgetIcon(name);
}

/// A common/other.dat file, edited or from the archive.
fn commonFile(app: *App, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var buf: [128]u8 = undefined;
    const i = try app.store.file(common_archive, try std.fmt.bufPrint(&buf, fmt, args));
    return app.store.text(i);
}

fn modelTaken(app: *App, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const e = std.fmt.bufPrint(&buf, "gfx_3d\\{s}.msh", .{name}) catch return true;
    if (app.store.find(common_archive, e) != null) return true;
    _ = app.store.file(common_archive, e) catch return false;
    return true;
}

/// Texture `slot` of a parsed model (`mesh.textureNames` order).
fn textureAt(app: *App, m: og.formats.mesh.Mesh, slot: u8) ![]const u8 {
    const names = try og.formats.mesh.textureNames(app.frame.allocator(), m);
    return if (slot < names.len) names[slot] else error.NoTexture;
}

/// Model texture (or effect frame) from `img` in place of `orig`: the UVs stay, so the
/// original's layout and aspect; for both at its size (at most 256, argb4444), for the port
/// as large as the PNG allows (a power of two times, up to 4096, argb8888: tex3df.encode).
pub fn modelTexture(gpa: Allocator, img: Image, orig: Image, target: og.formats.tex3df.Target) ![]u8 {
    var w = orig.width;
    var h = orig.height;
    const most = og.formats.tex3df.maxSide(target);
    while (@max(w, h) > most) : (h = @max(1, h / 2)) w = @max(1, w / 2);
    if (target == .port) while (w * 2 <= img.width and h * 2 <= img.height and @max(w, h) * 2 <= most) {
        w *= 2;
        h *= 2;
    };
    var sized = try resize(gpa, img, w, h);
    defer sized.deinit(gpa);
    return og.formats.tex3df.encode(gpa, sized, target);
}

/// Model file `msh` (owned) within `target`'s limits (Classic: the exe's, texture names
/// up to 47), its chunk 10 naming `ani` when given: a fork's own `.ani`, which the exe,
/// gorky-tool and modcheck take from there (the port by the model's name).
fn checkedMesh(gpa: Allocator, msh: []u8, ani: ?[]const u8, target: og.formats.tex3df.Target) ![]u8 {
    errdefer gpa.free(msh);
    var m = try og.formats.mesh.parse(gpa, msh);
    defer m.deinit();
    if (ani) |n| if (m.animations.len > 0) {
        m.animations = n;
    };
    try og.formats.mesh.checkLimits(m, target);
    if (ani == null or m.animations.len == 0) return msh;
    const out = try og.formats.mesh.encode(gpa, m);
    gpa.free(msh);
    return out;
}

/// Model `mesh` with its texture `slot` from `png` (modelTexture for `target`) under a
/// new name; the other textures stay. Returns the name.
pub fn newModel(app: *App, mesh: []const u8, png: []const u8, slot: u8, target: og.formats.tex3df.Target) ![]const u8 {
    const a = app.catalog.arena.allocator();
    const msh = try commonFile(app, "gfx_3d\\{s}.msh", .{mesh});
    var m = try og.formats.mesh.parse(app.gpa, msh);
    defer m.deinit();
    const old = try textureAt(app, m, slot);
    var orig = try og.formats.tex3df.decode(app.gpa, try commonFile(app, "gfx_3d\\textures\\{s}", .{old}));
    defer orig.deinit(app.gpa);
    var img = try readPng(app, png);
    defer img.deinit(app.gpa);
    const tex = try modelTexture(app.gpa, img, orig, target);

    const name = try freeName(a, mesh, app, modelTaken);
    var tb: [128]u8 = undefined;
    const tex_name = try std.fmt.bufPrint(&tb, "{s}.3df", .{name});
    var ab: [160]u8 = undefined;
    const new_msh = try checkedMesh(app.gpa, try og.formats.mesh.withTexture(app.gpa, msh, old, tex_name), try std.fmt.bufPrint(&ab, "{s}.ani", .{name}), target);
    var eb: [160]u8 = undefined;
    app.store.group();
    defer app.store.endGroup("+ gfx_3d\\{s}.msh", .{name});
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.bufPrint(&eb, "gfx_3d\\textures\\{s}", .{tex_name}), .text = tex }});
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{name}), .text = new_msh }});
    for ([_][]const u8{ "ani", "bfr" }) |ext| {
        const src = try app.gpa.dupe(u8, try commonFile(app, "gfx_3d\\{s}.{s}", .{ mesh, ext }));
        _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.{s}", .{ name, ext }), .text = src }});
    }
    try app.catalog.meshes.append(a, name);
    return name;
}

/// `entry` of common/other.dat made by the editor (new and unsaved, or not in the
/// archive before the save that first wrote it): no game file shares it.
/// shortcut: a file first saved in this session reads as the game's (Store.past holds
/// earlier sessions only), so it forks once more; reload the log on save if that matters.
pub fn editorMade(app: *App, entry: []const u8) bool {
    if (app.store.find(common_archive, entry)) |i| if (!app.store.files.items[i].on_disk) return true;
    const log = app.store.past orelse return false;
    for (log.steps) |st| for (st.files) |f| {
        if (std.mem.eql(u8, f.archive, common_archive) and std.ascii.eqlIgnoreCase(f.entry, entry)) return f.before == null;
    };
    return false;
}

/// Texture `slot` of model `mesh` from `png` in place when the editor made the model
/// (a game model is shared: newModel forks it): the texture itself when the editor made
/// it too, else a new `<mesh>_<n>.3df` the model names. Returns the texture's name, null
/// for a game model.
pub fn replaceOwnTexture(app: *App, mesh: []const u8, png: []const u8, slot: u8, target: og.formats.tex3df.Target) !?[]const u8 {
    var eb: [160]u8 = undefined;
    const msh_entry = try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh});
    if (!editorMade(app, msh_entry)) return null;
    const msh_file = try app.store.file(common_archive, msh_entry);
    var m = try og.formats.mesh.parse(app.gpa, app.store.text(msh_file));
    defer m.deinit();
    const old = try app.catalog.arena.allocator().dupe(u8, try textureAt(app, m, slot));
    var orig = try og.formats.tex3df.decode(app.gpa, try commonFile(app, "gfx_3d\\textures\\{s}", .{old}));
    defer orig.deinit(app.gpa);
    var img = try readPng(app, png);
    defer img.deinit(app.gpa);
    const tex = try modelTexture(app.gpa, img, orig, target);
    var lb: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "{s}: texture from PNG", .{mesh}) catch null;
    var tb: [160]u8 = undefined;
    const tex_entry = try std.fmt.bufPrint(&tb, "gfx_3d\\textures\\{s}", .{old});
    if (editorMade(app, tex_entry)) {
        try app.store.replaceLabeled(try app.store.file(common_archive, tex_entry), tex, label);
        app.preview.reload();
        return old;
    }
    const name = try std.fmt.allocPrint(app.catalog.arena.allocator(), "{s}.3df", .{try freeName(app.frame.allocator(), mesh, app, struct {
        fn f(ap: *App, s: []const u8) bool {
            var buf: [160]u8 = undefined;
            return textureTaken(ap, std.fmt.bufPrint(&buf, "{s}.3df", .{s}) catch return true);
        }
    }.f)});
    const new_msh = try checkedMesh(app.gpa, try og.formats.mesh.withTexture(app.gpa, app.store.text(msh_file), old, name), null, target);
    app.store.group();
    defer app.store.endGroup("{s}", .{label orelse mesh});
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.bufPrint(&tb, "gfx_3d\\textures\\{s}", .{name}), .text = tex }});
    try app.store.replaceLabeled(msh_file, new_msh, label);
    app.preview.reload();
    return name;
}

/// A new look for an enemy class: its `act_*.ss` copied with a model wearing `png`.
pub fn newLook(app: *App, act: []const u8, png: []const u8, slot: u8, target: og.formats.tex3df.Target) ![]const u8 {
    const mesh = model.getStr(try commonFile(app, "classes\\{s}", .{act}), "mesh") orelse return error.NoModel;
    app.store.group();
    defer app.store.endGroup("+ {s}", .{act});
    return newAct(app, act, try newModel(app, mesh, png, slot, target));
}

/// Enemy look `act` (`act_*.ss`) copied with `model` as its `meshFile`; returns the copy's name.
pub fn newAct(app: *App, act: []const u8, mesh_file: []const u8) ![]const u8 {
    const a = app.catalog.arena.allocator();
    const act_text = try commonFile(app, "classes\\{s}", .{act});
    const base = act[0 .. std.mem.lastIndexOfScalar(u8, act, '.') orelse act.len];
    const new_base = try freeName(a, base, app.catalog.acts.items, struct {
        fn f(list: []const []const u8, s: []const u8) bool {
            for (list) |x| if (std.ascii.startsWithIgnoreCase(x, s) and x.len == s.len + 3) return true;
            return false;
        }
    }.f);
    const new_act = try std.fmt.allocPrint(a, "{s}.ss", .{new_base});
    var vb: [128]u8 = undefined;
    const text = try model.setIn(app.gpa, act_text, "mesh", try std.fmt.bufPrint(&vb, "\"{s}\"", .{mesh_file}), null);
    var eb: [128]u8 = undefined;
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.bufPrint(&eb, "classes\\{s}", .{new_act}), .text = text }});
    try app.catalog.acts.append(a, new_act);
    return new_act;
}

/// The models' files over the archive and the unsaved files (as the preview's).
fn openModels(app: *App) !*og.compose.models.Files {
    const f = try og.compose.models.Files.open(app.io, app.gpa, app.dat);
    f.overlay = .{ .ctx = app, .get = @import("entries.zig").overlayGet };
    return f;
}

/// Model `mesh` (textures, skeleton, animations, attach points) as a `.glb` at `path`.
pub fn exportGlb(app: *App, mesh: []const u8, path: []const u8) !void {
    const models = try openModels(app);
    defer models.close();
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = models.parse(a, mesh) catch return error.NoModel;
    const names = try og.formats.mesh.textureNames(a, parsed.mesh);
    const images = try a.alloc(?Image, names.len);
    for (names, images) |n, *img| img.* = models.texture(a, n);
    const glb = try og.compose.gltf_export.exportGlb(app.gpa, mesh, parsed.mesh, parsed.anims.items, parsed.frames, images);
    defer app.gpa.free(glb);
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = glb });
}

fn textureTaken(app: *App, name: []const u8) bool {
    var buf: [160]u8 = undefined;
    const e = std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{s}", .{name}) catch return true;
    if (app.store.find(common_archive, e) != null) return true;
    _ = app.store.file(common_archive, e) catch return false;
    return true;
}

/// A new model `<base>_<n>` from the `.glb` at `path` (`target`'s limits checked): its
/// `.msh`, `.ani`, `.bfr` and textures; a texture name the game has already (an exported
/// model's own) gets a free `<model>_<n>.3df`, so no game texture changes. A `.glb`
/// without a height is fitted to `base`'s size (`fitted`: the height chosen, else 0);
pub fn importGlb(app: *App, base: []const u8, path: []const u8, target: og.formats.mesh.Target) !struct { name: []const u8, textures: usize, fitted: f32 } {
    const glb = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 30));
    defer app.gpa.free(glb);
    const name = try freeName(app.catalog.arena.allocator(), base, app, modelTaken);
    // As large as the model it replaces (a weapon stays a weapon's size), else a hero's.
    const size: f32 = fit: {
        var old = og.formats.mesh.parse(app.gpa, commonFile(app, "gfx_3d\\{s}.msh", .{base}) catch break :fit og.compose.gltf_import.hero_size) catch break :fit og.compose.gltf_import.hero_size;
        defer old.deinit();
        const old_size = old.height * og.compose.gltf_import.bindSize(old);
        break :fit if (old_size > 0) old_size else og.compose.gltf_import.hero_size;
    };
    var files = try og.compose.gltf_import.importGlb(app.gpa, glb, name, size, target);
    defer files.deinit();
    const fa = files.arena.allocator();
    var msh: []const u8 = files.msh;
    const tex_names = try fa.alloc([]const u8, files.textures.len);
    for (files.textures, tex_names, 0..) |t, *tn, i| {
        tn.* = t.name;
        var n: usize = 1;
        // Not one the game has, nor one this import names (else withTexture renames both).
        while (textureTaken(app, tn.*) or inList(tex_names[0..i], tn.*) or (tn.*.ptr != t.name.ptr and for (files.textures) |o| {
            if (std.ascii.eqlIgnoreCase(o.name, tn.*)) break true;
        } else false)) : (n += 1) tn.* = try std.fmt.allocPrint(fa, "{s}_{d}.3df", .{ name, n });
        if (tn.*.ptr != t.name.ptr) msh = try og.formats.mesh.withTexture(fa, msh, t.name, tn.*);
    }
    var m = try og.formats.mesh.parse(app.gpa, msh);
    defer m.deinit();
    try og.formats.mesh.checkLimits(m, target);
    var eb: [160]u8 = undefined;
    app.store.group();
    defer app.store.endGroup("+ gfx_3d\\{s}.msh", .{name});
    for (files.textures, tex_names) |t, tn| _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.bufPrint(&eb, "gfx_3d\\textures\\{s}", .{tn}), .text = try app.gpa.dupe(u8, t.data) }});
    for ([_][]const u8{ "msh", "ani", "bfr" }, [_][]const u8{ msh, files.ani, files.bfr }) |ext, data| {
        _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.{s}", .{ name, ext }), .text = try app.gpa.dupe(u8, data) }});
    }
    try app.catalog.meshes.append(app.catalog.arena.allocator(), name);
    return .{ .name = name, .textures = files.textures.len, .fitted = files.fitted };
}

/// The animations of the `.glb` at `path` into model `mesh` (same skeleton): one of the
/// same name replaced, new ones added, unused frames dropped. Names added and replaced.
pub fn importAnims(app: *App, a: Allocator, mesh: []const u8, path: []const u8) !struct { added: []const []const u8, replaced: []const []const u8 } {
    const glb = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 30));
    defer app.gpa.free(glb);
    const models = try openModels(app);
    defer models.close();
    var model_arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer model_arena.deinit();
    const parsed = models.parse(model_arena.allocator(), mesh) catch return error.NoModel;
    var files = try og.compose.gltf_import.importAnimationsInto(app.gpa, glb, parsed.mesh, parsed.anims.items, parsed.frames);
    defer files.deinit();
    var list = try og.formats.anim.parseAni(app.gpa, files.ani);
    defer list.deinit();
    var bf = try og.formats.anim.parseBfr(app.gpa, files.bfr, parsed.frames.bones);
    defer bf.deinit(app.gpa);
    const B = parsed.frames.bones;
    var eb: [160]u8 = undefined;
    // The frames as the archive holds them (the preview's cache keeps them converted).
    const bfr = try app.store.file(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.bfr", .{mesh}));
    var raw = try og.formats.anim.parseBfr(app.gpa, app.store.text(bfr), B);
    defer raw.deinit(app.gpa);
    var added: std.ArrayList([]const u8) = .empty;
    var replaced: std.ArrayList([]const u8) = .empty;
    for (list.items) |an| {
        // A replaced one has other frames (the kept ones may have moved down).
        const old = parsed.anims.find(an.name) orelse {
            try added.append(a, try a.dupe(u8, an.name));
            continue;
        };
        // Within float noise: a round trip through Blender splits each matrix into a
        // translation and rotation and back, off in the 4th–7th digit, the same frame.
        const was = raw.matrices[old.first * B .. (old.last + 1) * B];
        const now = bf.matrices[an.first * B .. (an.last + 1) * B];
        const same = was.len == now.len and for (was, now) |x, y| {
            if (!sameMatrix(x, y)) break false;
        } else true;
        if (!same) try replaced.append(a, try a.dupe(u8, an.name));
    }
    var lb: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "{s}: .glb animations", .{mesh}) catch null;
    // The frames first: the old .ani still fits them (no fewer frames; undo takes the .ani back first).
    const ani = try app.store.file(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.ani", .{mesh}));
    try app.store.replaceLabeled(bfr, try app.gpa.dupe(u8, files.bfr), label);
    try app.store.replaceLabeled(ani, try app.gpa.dupe(u8, files.ani), label);
    app.preview.reload();
    return .{ .added = added.items, .replaced = replaced.items };
}

fn sameMatrix(x: [12]f32, y: [12]f32) bool {
    for (x, y) |p, q| if (@abs(p - q) > 1e-3 * @max(1, @abs(p))) return false;
    return true;
}

/// A model field (`.msh` chunks 11 centre, 12 height, 13 attach points, 14 rotation).
pub const MeshField = union(enum) {
    height: f32,
    center: struct { k: usize, v: f32 },
    hold_name: struct { i: usize, v: []const u8 },
    hold_bone: struct { i: usize, v: u32 },
    /// Offset x, y, z (k 0–2) or angles around X, Y, Z (k 3–5).
    hold_param: struct { i: usize, k: usize, v: f32 },
    /// Offset x, y, z all moved by `d` (a handle dragged on the preview).
    hold_move: struct { i: usize, d: [3]f32 },
    /// Chunk 14: angle around X, Y, Z (k 0–2).
    rotation: struct { k: usize, v: f32 },
    /// A new attach point of this name at the joint of the last one's bone (or bone 0;
    /// none: model space), or point `i` removed.
    hold_add: []const u8,
    hold_remove: usize,
};

/// Field `f` of model `mesh` set (one undo step; the exe's limits checked); `what` names it.
pub fn setMeshField(app: *App, mesh: []const u8, f: MeshField, what: []const u8) !void {
    var eb: [160]u8 = undefined;
    const file = try app.store.file(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh}));
    var m = try og.formats.mesh.parse(app.gpa, app.store.text(file));
    defer m.deinit();
    // An edit keeps a model within the exe's limits; one past them (port only) stays editable.
    const target: og.formats.mesh.Target = if (og.formats.mesh.checkLimits(m, .both)) .both else |_| .port;
    const n = m.hold_modes.len;
    switch (f) {
        .height => |v| m.height = v,
        .center => |c| m.center[c.k] = c.v,
        .hold_name => |h| if (h.i < n) {
            m.hold_modes[h.i].name = h.v;
        } else return error.NoAttachPoint,
        .hold_bone => |h| if (h.i < n) {
            m.hold_modes[h.i].bone = h.v;
        } else return error.NoAttachPoint,
        .hold_param => |h| if (h.i < n) {
            m.hold_modes[h.i].params[h.k] = h.v;
        } else return error.NoAttachPoint,
        .hold_move => |h| if (h.i < n) {
            for (0..3) |k| m.hold_modes[h.i].params[k] += h.d[k];
        } else return error.NoAttachPoint,
        .rotation => |r| {
            m.rotation[r.k] = r.v;
            m.has_rotation = true;
        },
        .hold_add => |name| {
            const list = try m.arena.allocator().alloc(og.formats.mesh.HoldMode, n + 1);
            @memcpy(list[0..n], m.hold_modes);
            const bone: u32 = if (n > 0) m.hold_modes[n - 1].bone else if (m.joints.len > 0) 0 else og.formats.mesh.no_bone;
            list[n] = .{ .name = name, .params = @splat(0), .bone = bone };
            m.hold_modes = list;
        },
        .hold_remove => |i| if (i < n) {
            const list = try m.arena.allocator().alloc(og.formats.mesh.HoldMode, n - 1);
            @memcpy(list[0..i], m.hold_modes[0..i]);
            @memcpy(list[i..], m.hold_modes[i + 1 ..]);
            m.hold_modes = list;
        } else return error.NoAttachPoint,
    }
    try og.formats.mesh.checkLimits(m, target);
    const bytes = try og.formats.mesh.encode(app.gpa, m);
    errdefer app.gpa.free(bytes);
    var lb: [160]u8 = undefined;
    try app.store.replaceLabeled(file, bytes, std.fmt.bufPrint(&lb, "{s}.msh: {s}", .{ mesh, what }) catch null);
    app.preview.reload();
}

/// Texture `slot` of model `mesh` as a PNG at `path` (to paint a new one over).
pub fn exportTexture(app: *App, mesh: []const u8, path: []const u8, slot: u8) !void {
    var m = try og.formats.mesh.parse(app.gpa, try commonFile(app, "gfx_3d\\{s}.msh", .{mesh}));
    defer m.deinit();
    var img = try og.formats.tex3df.decode(app.gpa, try commonFile(app, "gfx_3d\\textures\\{s}", .{try textureAt(app, m, slot)}));
    defer img.deinit(app.gpa);
    try writePng(app, img, path);
}

/// The textures of model `mesh` (`mesh.textureNames` order); none if it can't be read.
pub fn textures(app: *App, a: std.mem.Allocator, mesh: []const u8) []const []const u8 {
    var m = og.formats.mesh.parse(app.gpa, commonFile(app, "gfx_3d\\{s}.msh", .{mesh}) catch return &.{}) catch return &.{};
    defer m.deinit();
    // The names point into the mesh bytes: copied before it goes.
    const names = og.formats.mesh.textureNames(a, m) catch return &.{};
    const out = a.alloc([]const u8, names.len) catch return &.{};
    for (names, out) |n, *o| o.* = a.dupe(u8, n) catch return &.{};
    return out;
}

/// Icon `name` (its big frame) as a PNG at `path`.
pub fn exportIcon(app: *App, name: []const u8, path: []const u8) !void {
    var buf: [96]u8 = undefined;
    const entry = try std.fmt.bufPrint(&buf, "icons\\{s}.spr", .{name});
    const i = app.store.find(sprite_archive, entry) orelse try app.store.file(sprite_archive, entry);
    var spr = try og.formats.sprite.parse(app.gpa, app.store.text(i));
    defer spr.deinit(app.gpa);
    var img = try og.formats.sprite.decodeFrame(app.gpa, spr.frames[0]);
    defer img.deinit(app.gpa);
    try writePng(app, img, path);
}

pub fn writePng(app: *App, img: Image, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    try og.formats.png.write(app.gpa, &out.writer, img);
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() });
}
