//! A world's files: its location's archive (`<level>/other.dat`), the common ones
//! (`common/other.dat`, `lang.dat`), its assets (sprites, background, map, voices:
//! loaders/assets.zig) and the mod folders, opened at level entry
//! and owned here until the world's destroy. The core asks through core/source.zig
//! (scripts, variables, frame counts, the map, mods) and core/scene.zig (scenes and
//! dialogs: read from `common/other.dat: scriptlets\*.scr|pts`, `common/lang.dat: *.dlg`).
//! The game opens them through `Opener` (its world factory).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("../formats.zig").archive;
const vars = @import("../formats.zig").vars;
const scriptlet = @import("../formats.zig").scriptlet;
const dialog = @import("../formats.zig").dialog;
const core = @import("../core.zig");
const rules = @import("../rules.zig");
const map = @import("map.zig");
const assets = @import("assets.zig");
const level_assets = @import("level_assets.zig");
const life = @import("../game.zig").life;
const World = @import("../state.zig").world.World;
const model_cache = @import("../actor.zig").model_cache;

/// Mod folders (not in the exe: scripts over the game archives), set at startup
/// (`<game>/mods`, the data dir; gorky-tool `$OPENGORKY_MODS`); none: as in the exe.
/// A script is looked up in mods first, `<mod>/<location>/<name>` then `<mod>/<name>`;
/// location objects (`.ftr`, `.wpn`, `.act`, …) in `<mod>/<location>/` are made with the
/// archive's. Custom fighters use the generic class (`classType = 100`, battle/generic.zig).
pub var mod_dirs: [2]?Io.Dir = .{ null, null };

/// The game's world factory over `dat` (it must outlive the factory).
pub const Opener = struct {
    io: Io,
    dat: Io.Dir,

    pub fn factory(self: *const Opener) core.source.Factory {
        return .{ .ctx = @constCast(self), .open = openCtx };
    }
};

/// The reader that opens locations instead of these files: an OpenGorky project's
/// (loaders.openGame sets it to loaders/ogs.zig's for `format = ogs`, null for Classic), so
/// every client's `Opener` and `create` open the project without knowing its format.
pub var reader: ?core.source.Factory = null;

fn openCtx(ctx: ?*anyopaque, gpa: Allocator, level: []const u8) anyerror!core.source.Source {
    if (reader) |r| return r.openLevel(gpa, level);
    const o: *const Opener = @ptrCast(@alignCast(ctx.?));
    return (try open(o.io, gpa, o.dat, level)).source();
}

/// A world of location `level` over `dat` (one without a game: gorky-tool, the editor).
pub fn create(io: Io, gpa: Allocator, dat: Io.Dir, level: []const u8, models: ?*model_cache.Cache, opts: life.Options) !*World {
    const o: Opener = .{ .io = io, .dat = dat };
    return life.create(io, gpa, o.factory(), level, models, opts);
}

pub const Files = struct {
    io: Io,
    gpa: Allocator,
    /// Game `dat` dir: other locations' archives.
    dat: Io.Dir,
    level: []const u8,
    other: archive.Archive,
    /// The location's sprites, background, map; voices.
    assets: assets.Stack,
    common: archive.Archive,
    lang: archive.Archive,
    /// `other`'s entry names, `common`'s `gamestart\*` without the folder (into the entries).
    level_files: [][]const u8,
    gamestart: [][]const u8,
    /// The mods' files of the location (`<mod>/<level>/*`), in `mod_arena`.
    mod_files: [][]const u8 = &.{},
    mod_arena: std.heap.ArenaAllocator,

    /// The core's view of these files.
    pub fn source(self: *Files) core.source.Source {
        return .{
            .ctx = self,
            .level_files = self.level_files,
            .gamestart = self.gamestart,
            .script = script,
            .foreign = foreign,
            .vars = varsOf,
            .frame_count = frameCount,
            .background_size = backgroundSize,
            .mod = modScript,
            .mod_files = self.mod_files,
            .map = mapOf,
            .has_voice = hasVoice,
            .backdrop = backdropOf,
            .scenes = .{ .ctx = self, .scene = scene, .dialog = dialogOf },
            .close = closeCtx,
        };
    }

    pub fn close(self: *Files) void {
        const gpa = self.gpa;
        gpa.free(self.level_files);
        gpa.free(self.gamestart);
        self.mod_arena.deinit();
        self.lang.close(self.io, gpa);
        self.common.close(self.io, gpa);
        self.assets.deinit();
        self.other.close(self.io, gpa);
        gpa.free(self.level);
        gpa.destroy(self);
    }
};

/// The files of location `level` (read at level entry; `close` releases them).
pub fn open(io: Io, gpa: Allocator, dat: Io.Dir, level: []const u8) !*Files {
    rules.classicPath("compose/world: a location's Classic files");
    var path_buf: [256]u8 = undefined;
    var other = try archive.Archive.open(io, gpa, dat, try std.fmt.bufPrint(&path_buf, "{s}/other.dat", .{level}));
    errdefer other.close(io, gpa);
    var sprites: assets.Stack = try .classic(io, gpa, dat);
    errdefer sprites.deinit();
    // No sprite.dat, no location (as before the stack).
    _ = try sprites.archiveOf(try std.fmt.bufPrint(&path_buf, "{s}/sprite.dat", .{level}));
    var common = try archive.Archive.open(io, gpa, dat, "common/other.dat");
    errdefer common.close(io, gpa);
    var lang = try archive.Archive.open(io, gpa, dat, "common/lang.dat");
    errdefer lang.close(io, gpa);
    const level_files = try gpa.alloc([]const u8, other.entries.len);
    errdefer gpa.free(level_files);
    for (level_files, other.entries) |*n, e| n.* = e.name;
    var start: std.ArrayList([]const u8) = .empty;
    errdefer start.deinit(gpa);
    for (common.entries) |e| if (std.ascii.startsWithIgnoreCase(e.name, "gamestart\\")) try start.append(gpa, e.name["gamestart\\".len..]);
    const f = try gpa.create(Files);
    errdefer gpa.destroy(f);
    f.* = .{
        .io = io,
        .gpa = gpa,
        .dat = dat,
        .level = try gpa.dupe(u8, level),
        .other = other,
        .assets = sprites,
        .common = common,
        .lang = lang,
        .level_files = level_files,
        .gamestart = try start.toOwnedSlice(gpa),
        .mod_arena = .init(gpa),
    };
    f.mod_files = modFiles(f) catch &.{};
    return f;
}

fn filesOf(ctx: ?*anyopaque) *Files {
    return @ptrCast(@alignCast(ctx.?));
}

fn closeCtx(ctx: ?*anyopaque) void {
    filesOf(ctx).close();
}

/// An included script (`#include`, `#inherit`): the level archive `local`, then
/// `common/other.dat` `classes\`, `scriptlets\`, `gamestart\` (the runtime, modcheck, `tool scripts`).
pub fn findScript(local: archive.Archive, common: archive.Archive, name: []const u8) ?*const archive.Entry {
    if (local.find(name)) |e| return e;
    var buf: [archive.name_size]u8 = undefined;
    for ([_][]const u8{ "classes", "scriptlets", "gamestart" }) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ dir, name }) catch return null;
        if (common.find(path)) |e| return e;
    }
    return null;
}

fn script(ctx: ?*anyopaque, a: Allocator, name: []const u8) anyerror!?[]const u8 {
    const f = filesOf(ctx);
    const e = findScript(f.other, f.common, name) orelse return null;
    const in_level = f.other.find(name) == e;
    return try (if (in_level) f.other else f.common).readAlloc(f.io, a, e);
}

/// `name` of `<level>/other.dat`; null `level`: the first location folder that has it.
fn foreign(ctx: ?*anyopaque, a: Allocator, level: ?[]const u8, name: []const u8) anyerror!?[]const u8 {
    const f = filesOf(ctx);
    const one = [_][]const u8{level orelse ""};
    const dirs = if (level != null) &one else try archive.levelDirs(f.io, f.gpa, f.dat);
    defer if (level == null) archive.freeList(f.gpa, dirs);
    for (dirs) |d| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/other.dat", .{d}) catch continue;
        var ar = archive.Archive.open(f.io, f.gpa, f.dat, path) catch continue;
        defer ar.close(f.io, f.gpa);
        const e = ar.find(name) orelse continue;
        return try ar.readAlloc(f.io, a, e);
    }
    return null;
}

/// `common/other.dat: variables\<object>.var`.
fn varsOf(ctx: ?*anyopaque, a: Allocator, object: []const u8) anyerror!?[]const core.source.Var {
    const f = filesOf(ctx);
    var buf: [archive.name_size]u8 = undefined;
    const e = f.common.find(try std.fmt.bufPrint(&buf, "variables\\{s}.var", .{object})) orelse return null;
    const text = try f.common.readAlloc(f.io, a, e);
    var v = try vars.parse(f.gpa, text);
    defer v.deinit(f.gpa);
    const out = try a.alloc(core.source.Var, v.entries.len);
    for (out, v.entries) |*o, x| o.* = .{ .key = x.key, .value = x.value };
    return out;
}

fn frameCount(ctx: ?*anyopaque, name: []const u8) u32 {
    const f = filesOf(ctx);
    return level_assets.frameCount(&f.assets, f.level, name);
}

fn backgroundSize(ctx: ?*anyopaque) ?[2]u32 {
    const f = filesOf(ctx);
    return level_assets.backgroundSize(&f.assets, f.gpa, f.level);
}

/// The level's map files of `other.dat`.
fn mapOf(ctx: ?*anyopaque, a: Allocator) anyerror!core.map.Map {
    const f = filesOf(ctx);
    return map.load(&f.assets, a, f.level);
}

fn backdropOf(ctx: ?*anyopaque, a: Allocator) anyerror!core.map.Backdrop {
    const f = filesOf(ctx);
    return level_assets.backdrop(&f.assets, a, f.level);
}

fn hasVoice(ctx: ?*anyopaque, name: []const u8) bool {
    return level_assets.hasVoice(&filesOf(ctx).assets, name);
}

// ---------------------------------------------------------------- mods

fn anyMods() bool {
    return mod_dirs[0] != null or mod_dirs[1] != null;
}

/// Mod file `name` (`<location>/name` then `name`; as given and lowercase), in `a`.
fn modScript(ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]const u8 {
    if (!anyMods()) return null;
    const f = filesOf(ctx);
    var low_buf: [256]u8 = undefined;
    if (name.len > low_buf.len) return null;
    const low = std.ascii.lowerString(&low_buf, name);
    var path_buf: [512]u8 = undefined;
    for (mod_dirs) |dir_opt| {
        const dir = dir_opt orelse continue;
        for ([_]?[]const u8{ f.level, null }) |sub| {
            for ([_][]const u8{ name, low }) |n| {
                const path = if (sub) |s| std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ s, n }) catch continue else n;
                if (dir.readFileAlloc(f.io, path, a, .limited(1 << 20))) |text| return text else |_| {}
            }
        }
    }
    return null;
}

/// The files of `<mod>/<level>/`, folder by folder in its order.
fn modFiles(f: *Files) ![][]const u8 {
    const a = f.mod_arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    for (mod_dirs) |dir_opt| {
        const dir = dir_opt orelse continue;
        var sub = dir.openDir(f.io, f.level, .{ .iterate = true }) catch continue;
        defer sub.close(f.io);
        var it = sub.iterate();
        while (it.next(f.io) catch null) |e| {
            if (e.kind != .file) continue;
            try out.append(a, try a.dupe(u8, e.name));
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- scenes and dialogs

fn scene(ctx: ?*anyopaque, a: Allocator, name: []const u8) anyerror!core.scene.Scene {
    const w = filesOf(ctx);
    const common = &w.common;
    var buf: [archive.name_size]u8 = undefined;
    const scr = common.find(try std.fmt.bufPrint(&buf, "scriptlets\\{s}.scr", .{name})) orelse return error.NotFound;
    const cmds = try scriptlet.parse(a, try common.readAlloc(w.io, a, scr));
    const pts = if (common.find(try std.fmt.bufPrint(&buf, "scriptlets\\{s}.pts", .{name}))) |e|
        try scriptlet.parsePoints(a, try common.readAlloc(w.io, a, e))
    else
        &.{};
    const out_cmds = try a.alloc(core.scene.Command, cmds.len);
    for (out_cmds, cmds) |*o, c| {
        const args = try a.alloc(core.scene.Arg, c.args.len);
        for (args, c.args) |*x, y| x.* = switch (y) {
            .string => |s| .{ .string = s },
            .number => |n| .{ .number = n },
        };
        o.* = .{ .name = c.name, .args = args, .line = c.line };
    }
    const out_pts = try a.alloc(core.scene.Point, pts.len);
    for (out_pts, pts) |*o, p| o.* = .{ .name = p.name, .x = p.x, .y = p.y, .angle = p.angle };
    return .{ .commands = out_cmds, .points = out_pts };
}

fn dialogOf(ctx: ?*anyopaque, a: Allocator, file: []const u8, language: u8) anyerror!core.scene.Dialog {
    const w = filesOf(ctx);
    const lang = &w.lang;
    // Combat levels' StartDialog() gives the name without extension.
    var buf: [archive.name_size]u8 = undefined;
    const e = lang.find(file) orelse
        lang.find(std.fmt.bufPrint(&buf, "{s}.dlg", .{file}) catch file) orelse
        return error.NotFound;
    const d = try dialog.parseCut(a, try lang.readAlloc(w.io, a, e), dialog.editionCut(file, language));
    const lines = try a.alloc(core.scene.Line, d.lines.len);
    for (lines, d.lines, 0..) |*o, l, i| {
        var vb: [96]u8 = undefined;
        const voice: ?[]const u8 = if (dialog.voiceName(&vb, file, l.code, d.voiceIndex(i))) |v| try a.dupe(u8, v) else |_| null;
        o.* = .{ .speaker = l.speaker, .text = l.text, .cam = l.cam, .voice = voice };
    }
    return .{ .lines = lines };
}
