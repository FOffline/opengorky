//! A look's asset pages (the Assets tier; a character only picks them, char_page.zig):
//! a model (`gfx_3d\<name>.msh`: its height, centre, rotation and attach points, to
//! glTF), the animations a look script binds (an enemy's `act_*.ss`, a hero's file: the
//! model's animations and their sounds on the stage, the bindings in the constructor), a
//! texture (`gfx_3d\textures\<name>`: to PNG, from one in place when the editor made it).
//! Each with where it is used.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const info = @import("info.zig");
const art = @import("art.zig");
const frame = @import("frame.zig");
const entries = @import("entries.zig");
const entry_model = @import("entry_model.zig");
const entry_anims = @import("entry_anims.zig");
const effectpage = @import("effectpage.zig");
const common_archive = @import("store.zig").common_archive;
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

const models_dir = "gfx_3d\\";
const textures_dir = "gfx_3d\\textures\\";

/// The models (`gfx_3d\*.msh`, new ones too), by name.
pub fn models(app: *App, a: Allocator) []const []const u8 {
    return stems(a, app.store.listing(a, common_archive, struct {
        fn f(e: []const u8) bool {
            return std.ascii.startsWithIgnoreCase(e, models_dir) and std.mem.indexOfScalarPos(u8, e, models_dir.len, '\\') == null and std.ascii.endsWithIgnoreCase(e, ".msh");
        }
    }.f, true), models_dir.len, ".msh".len);
}

/// The model textures (`gfx_3d\textures\*.3df`, new ones too), by file name.
pub fn textures(app: *App, a: Allocator) []const []const u8 {
    return stems(a, app.store.listing(a, common_archive, struct {
        fn f(e: []const u8) bool {
            return std.ascii.startsWithIgnoreCase(e, textures_dir) and std.ascii.endsWithIgnoreCase(e, ".3df");
        }
    }.f, true), textures_dir.len, 0);
}

fn stems(a: Allocator, es: []const []const u8, dir: usize, ext: usize) []const []const u8 {
    const out = a.alloc([]const u8, es.len) catch return &.{};
    for (es, out) |e, *o| o.* = e[dir .. e.len - ext];
    return out;
}

/// Look script `file`'s key (`archive|entry`: its animations' page).
pub fn scriptKey(app: *App, a: Allocator, file: usize) []const u8 {
    const f = app.store.files.items[file];
    return @import("doctab.zig").join(a, f.archive, f.entry) catch "";
}

/// The look script of key `key` (`archive|entry`).
fn scriptFile(app: *App, key: []const u8) ?usize {
    const p = @import("doctab.zig").split(key) orelse return null;
    return app.store.file(p[0], p[1]) catch null;
}

/// A page's head: its name, what it is, its file.
fn head(name: []const u8, kind: tx.Msg, file: []const u8) void {
    gui.headCard();
    gui.txtWrap(name, .heading, theme.text, font_mod.bold);
    gui.row(lay.space.sm);
    gui.chip(tx.get(kind));
    gui.txtClip(file, .caption, theme.dim, font_mod.regular);
    clay.close();
    gui.blockEnd();
}

/// The Info block (folded at first) of page `key`: where it is used.
pub fn infoBlock(app: *App, a: Allocator, key: []const u8, ctx: []const u8, comptime build: fn ([]const u8, *App, *info.List) void) void {
    const rows = info.rows(app, key, ctx, build);
    if (gui.block(app, "info", tx.get(tx.info_title), .{ .folded = true, .summary = tx.alloc(a, tx.sum_used, .{used(rows)}) })) {
        info.show(app, rows);
        gui.blockEnd();
    }
}

fn used(rows: []const info.Row) usize {
    var n: usize = 0;
    for (rows) |r| n += @intFromBool(r.group == .used and r.to != .none);
    return n;
}

pub fn modelPage(app: *App, a: Allocator) void {
    const mesh = app.model_sel.get();
    if (mesh.len == 0) return;
    // The model alone: its animation picked on a look's page, else its first.
    const l = entry_model.look(app, a, std.fmt.allocPrint(a, "meshFile=\"{s}\";", .{mesh}) catch "", null, null, &.{});
    frame.stage(app);
    entry_model.modelPane(app, l, entry_model.pointInfo(app, a, mesh), tx.model_hint);
    entry_model.pointHandles(app, mesh);
    frame.props(app, "model_props");
    head(mesh, tx.sec_model, std.fmt.allocPrint(a, models_dir ++ "{s}.msh", .{mesh}) catch mesh);
    if (gui.block(app, "model", tx.alloc(a, tx.tag_proto, .{tx.get(tx.sec_model)}), .{ .summary = entry_model.modelSummary(app, a, mesh) })) {
        entry_model.modelFields(app, a, null, mesh);
        gui.blockEnd();
    }
    infoBlock(app, a, std.fmt.allocPrint(a, "model:{s}", .{mesh}) catch mesh, mesh, modelInfo);
    clay.closeScrollColumn();
}

/// A model's Info: its file, its textures, the looks and entries wearing it.
fn modelInfo(mesh: []const u8, app: *App, list: *info.List) void {
    info.defined(list, common_archive, list.fmt(models_dir ++ "{s}.msh", .{mesh}), false);
    for (art.textures(app, list.a, mesh)) |t| list.add(.{ .group = .refs, .text = t, .to = .{ .doc = .{ .tab = .textures, .name = t } }, .icon = .image });
    const n = list.rows.items.len;
    for (app.catalog.acts.items) |act| {
        const f = actFile(app, act) orelse continue;
        if (std.ascii.eqlIgnoreCase(model.getStr(app.store.text(f), "mesh") orelse "", mesh)) list.add(.{ .group = .used, .text = act, .to = .{ .doc = .{ .tab = .anims, .name = scriptKey(app, list.a, f) } }, .icon = .play });
    }
    for (app.catalog.entries.items, 0..) |e, i| {
        const f = entries.fileOf(app, e) orelse continue;
        if (std.ascii.eqlIgnoreCase(entries.meshOf(app, e, app.store.text(f)) orelse "", mesh)) list.add(.{ .group = .used, .text = info.entryText(list, e), .to = .{ .entry = i }, .icon = if (e.kind == .enemy or e.kind == .hero) .user else .package });
    }
    info.usedNone(list, n, tx.look_used_none);
}

fn actFile(app: *App, act: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    return app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{act}) catch return null) catch null;
}

pub fn animsPage(app: *App, a: Allocator) void {
    const key = app.anims_sel.get();
    const file = scriptFile(app, key) orelse return;
    const act = app.store.text(file);
    const l = entry_model.look(app, a, act, null, null, &.{});
    frame.stage(app);
    entry_model.lookStage(app, a, l, act, null, null, @import("entry_attacks.zig").spinLanes(app, a, file, act, l.file));
    frame.props(app, "anims_props");
    const f = app.store.files.items[file];
    head(baseName(f.entry), tx.sec_anims, f.archive);
    entry_anims.section(app, a, file, act, l.mesh, l.file);
    infoBlock(app, a, std.fmt.allocPrint(a, "anims:{s}", .{key}) catch key, key, animsInfo);
    clay.closeScrollColumn();
}

/// A look script's Info: its file, its model, the characters it gives their look.
fn animsInfo(key: []const u8, app: *App, list: *info.List) void {
    const file = scriptFile(app, key) orelse return;
    const f = app.store.files.items[file];
    info.defined(list, f.archive, f.entry, true);
    const text = app.store.text(file);
    if (model.textStr(app, text, "mesh")) |m| list.add(.{ .group = .refs, .text = m, .to = .{ .doc = .{ .tab = .models, .name = list.a.dupe(u8, m) catch m } }, .icon = .box });
    const n = list.rows.items.len;
    for (app.catalog.entries.items, 0..) |e, i| {
        if (e.kind != .enemy and e.kind != .hero) continue;
        const ef = entries.fileOf(app, e) orelse continue;
        if (lookFile(app, e, app.store.text(ef)) == file) list.add(.{ .group = .used, .text = info.entryText(list, e), .to = .{ .entry = i }, .icon = .user });
    }
    info.usedNone(list, n, tx.look_used_none);
}

/// The script with a fighter's look (model, animation bindings): an enemy's `act_*.ss`, a
/// hero's own file or the class's it includes; null: none.
pub fn lookFile(app: *App, e: @import("catalog.zig").Entry, text: []const u8) ?usize {
    if (e.kind == .enemy) return actFile(app, entries.actOf(text) orelse return null);
    // The file whose text it is (lookOf reads it through the Store).
    return model.fileOf(app, entries.lookOf(app, text));
}

pub fn texturePage(app: *App, a: Allocator) void {
    const name = app.texture_sel.get();
    if (name.len == 0) return;
    const entry = std.fmt.allocPrint(a, textures_dir ++ "{s}", .{name}) catch return;
    const t = effectpage.cached(app, entry);
    frame.stage(app);
    // As large as the stage allows (whole times when it fits), pixels kept.
    const sid = clay.id("tex_stage");
    clay.open(.{ .id = sid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
    if (t) |tt| {
        // Last frame's room (none yet: its own size).
        const room: [2]f32 = if (clay.box(sid)) |b| .{ b.width - 2 * lay.space.xl, b.height - 2 * lay.space.xl } else .{ tt.w, tt.h };
        const fit = @min(4, @min(room[0] / tt.w, room[1] / tt.h));
        const k = if (fit >= 1) @floor(fit) else @max(0.05, fit);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(tt.w * k), .height = clay.fixed(tt.h * k) } }, .image = .{ .imageData = tt.tex } });
    } else gui.txt(tx.get(tx.tex_none), .body, theme.warn, font_mod.regular);
    clay.close();
    frame.props(app, "tex_props");
    head(name, tx.chip_texture, entry);
    if (gui.block(app, "texture", tx.get(tx.chip_texture), .{})) {
        if (t) |tt| gui.propRow(tx.get(tx.p_size), std.fmt.allocPrint(a, "{d} × {d}", .{ tt.w, tt.h }) catch "");
        // A game texture is shared: replaced only where the editor made it.
        const own = art.editorMade(app, entry);
        var labels: [2][]const u8 = .{ tx.get(tx.b_export_texture), tx.get(tx.b_tex_in) };
        if (gui.footer(app, "tex_foot", labels[0..if (own) 2 else 1], null)) |k| app.askFile(if (k == 0) .{ .kind = .png_out, .run = onTexOut, .name = name } else .{ .kind = .png, .run = onTexIn });
        if (!own) gui.note(tx.get(tx.tex_shared));
        gui.blockEnd();
    }
    infoBlock(app, a, std.fmt.allocPrint(a, "texture:{s}", .{name}) catch name, name, textureInfo);
    clay.closeScrollColumn();
}

/// A texture's Info: its file, the models wearing it.
fn textureInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, common_archive, list.fmt(textures_dir ++ "{s}", .{name}), false);
    const n = list.rows.items.len;
    for (models(app, list.a)) |m| for (art.textures(app, list.a, m)) |t| if (std.ascii.eqlIgnoreCase(t, name)) {
        list.add(.{ .group = .used, .text = m, .to = .{ .doc = .{ .tab = .models, .name = m } }, .icon = .box });
        break;
    };
    info.usedNone(list, n, tx.look_used_none);
}

// File dialog answers of the pages (app.askFile), on the document shown.
pub fn onGlbOut(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    try art.exportGlb(app, app.model_sel.get(), path);
    app.setStatus(tx.st_glb_out, .{path});
}
pub fn onAnimsIn(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    const file = scriptFile(app, app.anims_sel.get()) orelse return error.NoLook;
    return entry_model.animsIn(app, model.ownStr(app, file, "mesh") orelse return error.NoModel, path);
}
fn onTexOut(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    const f = try app.store.file(common_archive, try std.fmt.allocPrint(app.frame.allocator(), textures_dir ++ "{s}", .{app.texture_sel.get()}));
    var img = try og.formats.tex3df.decode(app.gpa, app.store.text(f));
    defer img.deinit(app.gpa);
    try art.writePng(app, img, path);
    app.setStatus(tx.st_exported, .{path});
}
/// The texture from a PNG in place (one the editor made: no game model wears it).
fn onTexIn(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    const name = app.texture_sel.get();
    const entry = try std.fmt.allocPrint(app.frame.allocator(), textures_dir ++ "{s}", .{name});
    if (!art.editorMade(app, entry)) return error.GameTexture;
    const f = try app.store.file(common_archive, entry);
    var orig = try og.formats.tex3df.decode(app.gpa, app.store.text(f));
    defer orig.deinit(app.gpa);
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    try app.store.replaceLabeled(f, try art.modelTexture(app.gpa, img, orig, app.importTarget()), entry);
    effectpage.forget(app, entry);
    app.preview.reload();
    app.setStatusPort(tx.st_tex_in, .{name}, tx.st_og_art);
}
