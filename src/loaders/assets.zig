//! Assets by logical path: `models/grandma.msh`,
//! `sprites/icons/axe.spr`, `levels/01_port/background.jpg`… Every reader of models,
//! textures, effects, sprites, fonts, sounds, music, voices, backgrounds, level maps and
//! videos asks a `Stack` for one; only this file maps a path to the game's archives
//! (the table `rows`, which the converter uses too, `toEntry`/`fromEntry`).
//!
//! A `Stack` is a list of sources looked up in order, the first that has the path wins:
//! the game's `[Archives(dat)]` (`classic`), an OpenGorky project's own assets over the
//! installed game's (`og`), videos `[Folder(avi)]` (`findVideo`).
//! The Classic reader turns its bare names (`spriteFile = "lever"`, a mesh name, a sound
//! name) into paths; the level-then-common order of a name lives there, not here.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("../formats.zig").archive;
const package = @import("ogs/package.zig");

/// Longest logical path or archive path (an entry name is shorter, `archive.name_size`).
pub const max_path = 256;

/// A table row: logical path `path` is entry `entry` of archive `archive`. A row whose
/// `path` ends in `/` or `.` maps a prefix (the rest follows, `/` as `\`); else one
/// name. Level rows (`level_rows`) are under `levels/<level>/`, their `archive` in
/// `<level>/`, `{l}` in `entry` is the level. `ext`: only names ending so. First
/// match wins both ways (more specific rows first).
const Row = struct {
    path: []const u8,
    archive: []const u8,
    entry: []const u8,
    ext: []const u8 = "",
};

const common_rows = [_]Row{
    .{ .path = "textures/", .archive = "common/other.dat", .entry = "gfx_3d\\textures\\" },
    .{ .path = "effects/", .archive = "common/other.dat", .entry = "gfx_3d\\effects\\" },
    .{ .path = "models/", .archive = "common/other.dat", .entry = "gfx_3d\\" },
    .{ .path = "fonts/", .archive = "common/other.dat", .entry = "", .ext = ".fnt" },
    // The rest of other.dat (`pila.spr`, `load.spr`; scripts, which are no assets).
    .{ .path = "other/", .archive = "common/other.dat", .entry = "" },
    .{ .path = "sprites/", .archive = "common/sprite.dat", .entry = "" },
    .{ .path = "sounds/", .archive = "common/sound.dat", .entry = "" },
    .{ .path = "music/", .archive = "common/voice.dat", .entry = "", .ext = ".mp3" },
    .{ .path = "voice/", .archive = "common/voice.dat", .entry = "" },
};

const level_rows = [_]Row{
    .{ .path = "background.", .archive = "sprite.dat", .entry = "background\\{l}." },
    .{ .path = "sprites/", .archive = "sprite.dat", .entry = "" },
    .{ .path = "walk.wm", .archive = "other.dat", .entry = "{l}.wm" },
    .{ .path = "walk2.wm2", .archive = "other.dat", .entry = "{l}.wm2" },
    .{ .path = "grid.cm", .archive = "other.dat", .entry = "{l}.cm" },
    .{ .path = "areas.ar", .archive = "other.dat", .entry = "{l}.ar" },
    .{ .path = "paths.ap", .archive = "other.dat", .entry = "{l}.ap" },
    .{ .path = "lights.lts", .archive = "other.dat", .entry = "{l}.lts" },
    // The rest of the level's other.dat (its scripts and `.lev`, no assets).
    .{ .path = "files/", .archive = "other.dat", .entry = "" },
};

fn isPrefix(r: Row) bool {
    return r.path.len > 0 and (r.path[r.path.len - 1] == '/' or r.path[r.path.len - 1] == '.');
}

/// `parts` joined into `buf`, `{l}` in each replaced by `level`, `from` turned to `to`
/// in the last part.
fn join(buf: []u8, parts: []const []const u8, level: []const u8, from: u8, to: u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (parts, 0..) |p, i| {
        var rest = p;
        while (std.mem.indexOf(u8, rest, "{l}")) |k| {
            w.writeAll(rest[0..k]) catch return null;
            w.writeAll(level) catch return null;
            rest = rest[k + 3 ..];
        }
        if (i + 1 < parts.len) {
            w.writeAll(rest) catch return null;
        } else for (rest) |ch| w.writeByte(if (ch == from) to else ch) catch return null;
    }
    return w.buffered();
}

/// An archive entry: `archive` under `dat`, entry `name`.
pub const Entry = struct { archive: []const u8, name: []const u8 };

/// Logical `path` as the archive entry the table maps it to (in `bufs`); null: none.
pub fn toEntry(bufs: *[2][max_path]u8, path: []const u8) ?Entry {
    if (std.mem.startsWith(u8, path, "levels/")) {
        const tail = path["levels/".len..];
        const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return null;
        const level = tail[0..slash];
        const rest = tail[slash + 1 ..];
        if (level.len == 0) return null;
        for (level_rows) |r| {
            const hit = if (isPrefix(r)) std.mem.startsWith(u8, rest, r.path) else std.mem.eql(u8, rest, r.path);
            if (!hit or !std.ascii.endsWithIgnoreCase(rest, r.ext)) continue;
            return .{
                .archive = join(&bufs[0], &.{ level, "/", r.archive }, level, 0, 0) orelse return null,
                .name = join(&bufs[1], &.{ r.entry, rest[r.path.len..] }, level, '/', '\\') orelse return null,
            };
        }
        return null;
    }
    for (common_rows) |r| {
        if (!std.mem.startsWith(u8, path, r.path) or !std.ascii.endsWithIgnoreCase(path, r.ext)) continue;
        return .{ .archive = r.archive, .name = join(&bufs[1], &.{ r.entry, path[r.path.len..] }, "", '/', '\\') orelse return null };
    }
    return null;
}

/// Entry `name` of archive `archive_path` (`common/other.dat`, `<level>/sprite.dat`) as
/// its logical path (in `buf`; the entry's own case); null: the table has none.
pub fn fromEntry(buf: []u8, archive_path: []const u8, name: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfAny(u8, archive_path, "/\\") orelse return null;
    const dir = archive_path[0..slash];
    const file = archive_path[slash + 1 ..];
    const common = std.ascii.eqlIgnoreCase(dir, "common");
    for (if (common) &common_rows else &level_rows) |r| {
        if (!std.ascii.eqlIgnoreCase(if (common) r.archive[slash + 1 ..] else r.archive, file)) continue;
        if (!std.ascii.endsWithIgnoreCase(name, r.ext)) continue;
        var eb: [max_path]u8 = undefined;
        const entry = join(&eb, &.{r.entry}, dir, 0, 0) orelse return null;
        const hit = if (isPrefix(r)) std.ascii.startsWithIgnoreCase(name, entry) else std.ascii.eqlIgnoreCase(name, entry);
        if (!hit) continue;
        const rest = name[entry.len..];
        return if (common)
            join(buf, &.{ r.path, rest }, "", '\\', '/')
        else
            join(buf, &.{ "levels/", dir, "/", r.path, rest }, "", '\\', '/');
    }
    return null;
}

/// The game's archives under its `dat` folder, each opened at its first use and kept;
/// entries by name
/// ignoring case (archive.Archive.find).
const Archives = struct {
    dat: Io.Dir,
    /// Opened archives (each allocated: `archive` hands out pointers); `arc` null:
    /// missing or broken, not tried again.
    open: std.ArrayList(*Slot) = .empty,

    const Slot = struct { path: []u8, arc: ?archive.Archive };

    pub fn deinit(self: *Archives, io: Io, gpa: Allocator) void {
        for (self.open.items) |s| {
            if (s.arc) |*a| a.close(io, gpa);
            gpa.free(s.path);
            gpa.destroy(s);
        }
        self.open.deinit(gpa);
    }

    /// Archive `path` (`common/sound.dat`), opened now if not yet; null: none. The
    /// error is the open's, once (then null).
    pub fn get(self: *Archives, io: Io, gpa: Allocator, path: []const u8) !?*const archive.Archive {
        for (self.open.items) |s| if (std.ascii.eqlIgnoreCase(s.path, path)) return if (s.arc) |*a| a else null;
        var failed: ?anyerror = null;
        var arc: ?archive.Archive = archive.Archive.open(io, gpa, self.dat, path) catch |err| blk: {
            failed = err;
            break :blk null;
        };
        const s = self.slot(gpa, path, arc) catch |err| {
            if (arc) |*a| a.close(io, gpa);
            return err;
        };
        if (failed) |err| return err;
        return &s.arc.?;
    }

    fn slot(self: *Archives, gpa: Allocator, path: []const u8, arc: ?archive.Archive) Allocator.Error!*Slot {
        const s = try gpa.create(Slot);
        errdefer gpa.destroy(s);
        s.* = .{ .path = try gpa.dupe(u8, path), .arc = arc };
        errdefer gpa.free(s.path);
        try self.open.append(gpa, s);
        return s;
    }

    fn find(self: *Archives, io: Io, gpa: Allocator, path: []const u8) ?struct { arc: *const archive.Archive, e: *const archive.Entry } {
        var bufs: [2][max_path]u8 = undefined;
        const at = toEntry(&bufs, path) orelse return null;
        const arc = (self.get(io, gpa, at.archive) catch return null) orelse return null;
        return .{ .arc = arc, .e = arc.find(at.name) orelse return null };
    }
};

/// Files of a folder by logical path: `prefix` + the file's path under `dir` (`/`
/// separated, matched ignoring case as on Windows). `path` names `dir` for callers that
/// need a file on disk (a video for the decoder, `locate`).
const Folder = struct {
    dir: Io.Dir,
    path: []const u8 = "",
    prefix: []const u8 = "",
    /// A name matches whatever its extension (videos: a project may keep a clip in
    /// another container, viewer/media/video.zig).
    any_ext: bool = false,
    /// An empty file hides the path in the sources after this one.
    empty_hides: bool = false,

    /// The file's name under `dir`, as on disk (in `buf`); null: none.
    fn name(self: Folder, io: Io, buf: []u8, path: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, self.prefix)) return null;
        const rel = path[self.prefix.len..];
        if (!self.any_ext) {
            var b: [512]u8 = undefined;
            const on_disk = archive.resolveAnyCase(io, self.dir, rel, &b) catch return null;
            if (on_disk.len > buf.len) return null;
            @memcpy(buf[0..on_disk.len], on_disk);
            return buf[0..on_disk.len];
        }
        // shortcut: any_ext looks in `dir` itself only; nest when a project needs it.
        const stem = std.fs.path.stem(rel);
        var it = self.dir.iterate();
        while (it.next(io) catch null) |e| {
            if (!std.ascii.eqlIgnoreCase(std.fs.path.stem(e.name), stem)) continue;
            if (e.name.len > buf.len) return null;
            @memcpy(buf[0..e.name.len], e.name);
            return buf[0..e.name.len];
        }
        return null;
    }
};

/// The own assets in an OpenGorky package (loaders/ogs/package.zig): entry
/// `src/assets/<path>`, matched ignoring case as a folder's files.
const Packed = struct {
    pkg: *const package.Package,

    fn entry(self: Packed, path: []const u8) ?*const package.Entry {
        var buf: [max_path + 16]u8 = undefined;
        return self.pkg.find(std.fmt.bufPrint(&buf, "src/assets/{s}", .{path}) catch return null, true);
    }
};

pub const Source = union(enum) {
    archives: Archives,
    folder: Folder,
    package: Packed,
};

/// Where a path was found: in an archive, or a file of a folder (`hidden`: an empty
/// file of an `empty_hides` folder, the path is not there).
const Hit = union(enum) {
    entry: struct { arc: *const archive.Archive, e: *const archive.Entry },
    file: struct { folder: *const Folder, name: []const u8 },
    in_package: struct { pkg: *const package.Package, e: *const package.Entry },
    hidden,
};

/// Sources looked up in order (the first that has the path wins).
pub const Stack = struct {
    io: Io,
    gpa: Allocator,
    sources: std.ArrayList(Source) = .empty,

    /// Classic: the game's archives under `dat` (it must outlive the stack).
    pub fn classic(io: Io, gpa: Allocator, dat: Io.Dir) !Stack {
        var s: Stack = .{ .io = io, .gpa = gpa };
        try s.sources.append(gpa, .{ .archives = .{ .dat = dat } });
        return s;
    }

    /// An OpenGorky project: its own files — folder `src/assets/` or
    /// its package's (null: none) — over the installed game's archives under `dat` (all
    /// must outlive it).
    pub fn og(io: Io, gpa: Allocator, own: ?Own, dat: Io.Dir) !Stack {
        var s: Stack = .{ .io = io, .gpa = gpa };
        errdefer s.sources.deinit(gpa);
        if (own) |o| try s.sources.append(gpa, switch (o) {
            .folder => |d| .{ .folder = .{ .dir = d } },
            .package => |p| .{ .package = .{ .pkg = p } },
        });
        try s.sources.append(gpa, .{ .archives = .{ .dat = dat } });
        return s;
    }

    pub const Own = union(enum) { folder: Io.Dir, package: *const package.Package };

    /// Frees the stack and what it opened (a folder's `dir` stays its owner's).
    pub fn deinit(self: *Stack) void {
        for (self.sources.items) |*s| switch (s.*) {
            .archives => |*a| a.deinit(self.io, self.gpa),
            .folder, .package => {},
        };
        self.sources.deinit(self.gpa);
    }

    /// Archive `path` of the first archive source (fails as its open does): what a
    /// client needs listed (the editor's sound lists) or must have (a missing
    /// `common/other.dat` fails the model cache, as before the stack).
    pub fn archiveOf(self: *Stack, path: []const u8) !*const archive.Archive {
        for (self.sources.items) |*s| switch (s.*) {
            .archives => |*a| return (try a.get(self.io, self.gpa, path)) orelse error.FileNotFound,
            .folder, .package => {},
        };
        return error.FileNotFound;
    }

    fn find(self: *Stack, buf: []u8, path: []const u8) ?Hit {
        for (self.sources.items) |*s| switch (s.*) {
            .archives => |*a| if (a.find(self.io, self.gpa, path)) |h| return .{ .entry = .{ .arc = h.arc, .e = h.e } },
            .folder => |*f| if (f.name(self.io, buf, path)) |n| {
                if (f.empty_hides) if (f.dir.statFile(self.io, n, .{})) |st| if (st.size == 0) return .hidden else {} else |_| {};
                return .{ .file = .{ .folder = f, .name = n } };
            },
            .package => |p| if (p.entry(path)) |e| return .{ .in_package = .{ .pkg = p.pkg, .e = e } },
        };
        return null;
    }

    pub fn exists(self: *Stack, path: []const u8) bool {
        return self.size(path) != null;
    }

    /// Size in bytes of `path`; null: none.
    pub fn size(self: *Stack, path: []const u8) ?u64 {
        var buf: [max_path]u8 = undefined;
        return switch (self.find(&buf, path) orelse return null) {
            .entry => |h| h.e.size,
            .file => |h| (h.folder.dir.statFile(self.io, h.name, .{}) catch return null).size,
            .in_package => |h| h.e.size,
            .hidden => null,
        };
    }

    /// `path`'s bytes in `a`; error.NotFound: none.
    pub fn read(self: *Stack, a: Allocator, path: []const u8) ![]u8 {
        var buf: [max_path]u8 = undefined;
        return switch (self.find(&buf, path) orelse return error.NotFound) {
            .entry => |h| h.arc.readAlloc(self.io, a, h.e),
            .file => |h| h.folder.dir.readFileAlloc(self.io, h.name, a, .unlimited),
            .in_package => |h| h.pkg.read(self.io, a, h.e),
            .hidden => error.NotFound,
        };
    }

    /// The first `dst.len` bytes of `path` (a header) into `dst`; the count read
    /// (short: the file is); null: none.
    pub fn head(self: *Stack, path: []const u8, dst: []u8) ?usize {
        var buf: [max_path]u8 = undefined;
        switch (self.find(&buf, path) orelse return null) {
            .entry => |h| {
                const n = @min(dst.len, h.e.size);
                return h.arc.file.readPositionalAll(self.io, dst[0..n], h.e.offset) catch null;
            },
            .file => |h| {
                const f = h.folder.dir.openFile(self.io, h.name, .{}) catch return null;
                defer f.close(self.io);
                return f.readPositionalAll(self.io, dst, 0) catch null;
            },
            .in_package => |h| return h.pkg.head(self.io, h.e, dst) catch null,
            .hidden => return null,
        }
    }

    /// `path` as a file on disk (`<folder path>/<name>`, in `out`): only folders have
    /// one (a video for the decoder); null: none, or in an archive.
    fn locate(self: *Stack, out: []u8, path: []const u8) ?[]const u8 {
        var buf: [max_path]u8 = undefined;
        return switch (self.find(&buf, path) orelse return null) {
            .file => |h| std.fmt.bufPrint(out, "{s}/{s}", .{ h.folder.path, h.name }) catch null,
            .entry, .in_package, .hidden => null,
        };
    }
};

/// The Classic name of an object's sprite (`spriteFile`, the exe's 0x4c8d50 loader):
/// `<name>.<ext>` of the location's own sprite.dat, never common's (in `buf`).
pub fn levelSprite(buf: []u8, level: []const u8, name: []const u8, ext: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "levels/{s}/sprites/{s}.{s}", .{ level, name, ext }) catch null;
}

/// Asset `video/<name>` as a file of game folder `game_dir` (in `buf`): `avi\<name>.asf`
/// case-insensitively, any extension ("gradma.avi" → "gradma.asf"). Videos are files, not
/// archive entries: the player opens them by path.
pub fn findVideo(buf: []u8, io: Io, game_dir: []const u8, name: []const u8) ?[]const u8 {
    var srcs: [1]Source = undefined;
    var s: Stack = .{ .io = io, .gpa = undefined, .sources = .initBuffer(&srcs) };
    var path_buf: [512]u8 = undefined;
    const avi = std.fmt.bufPrint(&path_buf, "{s}/avi", .{game_dir}) catch return null;
    var dir = Io.Dir.cwd().openDir(io, avi, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    s.sources.appendAssumeCapacity(.{ .folder = .{ .dir = dir, .path = avi, .prefix = "video/", .any_ext = true } });
    var pb: [max_path]u8 = undefined;
    return s.locate(buf, std.fmt.bufPrint(&pb, "video/{s}", .{name}) catch return null);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "table: logical paths and archive entries, both ways" {
    var bufs: [2][max_path]u8 = undefined;
    const cases = [_]struct { path: []const u8, archive: []const u8, name: []const u8 }{
        .{ .path = "models/grandma.msh", .archive = "common/other.dat", .name = "gfx_3d\\grandma.msh" },
        .{ .path = "textures/a.3df", .archive = "common/other.dat", .name = "gfx_3d\\textures\\a.3df" },
        .{ .path = "effects/fire/fire.dsc", .archive = "common/other.dat", .name = "gfx_3d\\effects\\fire\\fire.dsc" },
        .{ .path = "fonts/02_dialog_1.fnt", .archive = "common/other.dat", .name = "02_dialog_1.fnt" },
        .{ .path = "other/pila.spr", .archive = "common/other.dat", .name = "pila.spr" },
        .{ .path = "sprites/icons/axe.spr", .archive = "common/sprite.dat", .name = "icons\\axe.spr" },
        .{ .path = "sounds/weapons/axe.wav", .archive = "common/sound.dat", .name = "weapons\\axe.wav" },
        .{ .path = "music/01_port.mp3", .archive = "common/voice.dat", .name = "01_port.mp3" },
        .{ .path = "voice/port_arriving_ov_00.wav", .archive = "common/voice.dat", .name = "port_arriving_ov_00.wav" },
        .{ .path = "levels/01_port/background.jpg", .archive = "01_port/sprite.dat", .name = "background\\01_port.jpg" },
        .{ .path = "levels/01_port/sprites/lever.spr", .archive = "01_port/sprite.dat", .name = "lever.spr" },
        .{ .path = "levels/01_port/walk.wm", .archive = "01_port/other.dat", .name = "01_port.wm" },
        .{ .path = "levels/01_port/walk2.wm2", .archive = "01_port/other.dat", .name = "01_port.wm2" },
        .{ .path = "levels/01_port/lights.lts", .archive = "01_port/other.dat", .name = "01_port.lts" },
    };
    for (cases) |c| {
        const e = toEntry(&bufs, c.path).?;
        try testing.expectEqualStrings(c.archive, e.archive);
        try testing.expectEqualStrings(c.name, e.name);
        var pb: [max_path]u8 = undefined;
        try testing.expectEqualStrings(c.path, fromEntry(&pb, c.archive, c.name).?);
    }
    // The entry's own case is kept; the archive's and the folders' don't matter.
    var pb: [max_path]u8 = undefined;
    try testing.expectEqualStrings("textures/Kursor.3df", fromEntry(&pb, "COMMON/OTHER.DAT", "GFX_3D\\Textures\\Kursor.3df").?);
    try testing.expectEqualStrings("effects/Fire/f.dsc", fromEntry(&pb, "common/other.dat", "gfx_3d\\Effects\\Fire\\f.dsc").?);
    try testing.expect(toEntry(&bufs, "levels/01_port/walk.wm2") == null);
    try testing.expect(toEntry(&bufs, "nowhere/x") == null);
    try testing.expect(fromEntry(&pb, "common/lang.dat", "string.tab") == null);
}

/// A test game: `dat/common/sprite.dat` and a level's `dat/01_port/SPRITE.DAT`, both
/// with a `lever.spr` (different bytes, different case).
fn testGame(io: Io, dir: Io.Dir) !void {
    const gpa = testing.allocator;
    const common = try archive.build(gpa, &.{ .{ .name = "LEVER.spr", .data = "common" }, .{ .name = "icons\\axe.spr", .data = "axe" } });
    defer gpa.free(common);
    const level = try archive.build(gpa, &.{ .{ .name = "lever.SPR", .data = "level" }, .{ .name = "background\\01_port.jpg", .data = "jpeg!" } });
    defer gpa.free(level);
    try dir.createDirPath(io, "dat/common");
    try dir.createDirPath(io, "dat/01_port");
    try dir.writeFile(io, .{ .sub_path = "dat/common/sprite.dat", .data = common });
    try dir.writeFile(io, .{ .sub_path = "dat/01_port/SPRITE.DAT", .data = level });
}

test "Archives: names ignoring case; one name in two archives stays two assets" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testGame(io, tmp.dir);
    var dat = try tmp.dir.openDir(io, "dat", .{});
    defer dat.close(io);
    var s: Stack = try .classic(io, testing.allocator, dat);
    defer s.deinit();
    const a = try s.read(testing.allocator, "sprites/lever.spr");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("common", a);
    const b = try s.read(testing.allocator, "levels/01_port/sprites/LEVER.spr");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("level", b);
    try testing.expectEqual(@as(?u64, 3), s.size("sprites/ICONS/AXE.SPR"));
    var h: [4]u8 = undefined;
    try testing.expectEqual(@as(?usize, 4), s.head("levels/01_port/background.jpg", &h));
    try testing.expectEqualStrings("jpeg", &h);
    try testing.expect(!s.exists("levels/02_other/sprites/lever.spr"));
    try testing.expectError(error.NotFound, s.read(testing.allocator, "sprites/none.spr"));
    // Only folders give a file on disk.
    var lb: [64]u8 = undefined;
    try testing.expect(s.locate(&lb, "sprites/lever.spr") == null);
}

test "Stack: a file in the folder overrides the archive entry, the rest falls through" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testGame(io, tmp.dir);
    try tmp.dir.createDirPath(io, "src/assets/sprites/Icons");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/assets/sprites/Icons/axe.spr", .data = "my axe" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/assets/sprites/gone.spr", .data = "" });
    var dat = try tmp.dir.openDir(io, "dat", .{});
    defer dat.close(io);
    var own = try tmp.dir.openDir(io, "src/assets", .{ .iterate = true });
    defer own.close(io);
    var s: Stack = .{ .io = io, .gpa = gpa };
    defer s.deinit();
    try s.sources.append(gpa, .{ .folder = .{ .dir = own, .path = "src/assets" } });
    try s.sources.append(gpa, .{ .archives = .{ .dat = dat } });
    const axe = try s.read(gpa, "sprites/icons/axe.spr");
    defer gpa.free(axe);
    try testing.expectEqualStrings("my axe", axe);
    try testing.expectEqual(@as(?u64, 6), s.size("sprites/icons/axe.spr"));
    const lever = try s.read(gpa, "sprites/lever.spr");
    defer gpa.free(lever);
    try testing.expectEqualStrings("common", lever);
    var lb: [64]u8 = undefined;
    try testing.expectEqualStrings("src/assets/sprites/Icons/axe.spr", s.locate(&lb, "sprites/icons/axe.spr").?);
    // An empty file is a file, unless the folder hides with it.
    try testing.expectEqual(@as(?u64, 0), s.size("sprites/gone.spr"));
    s.sources.items[0].folder.empty_hides = true;
    try testing.expect(!s.exists("sprites/gone.spr"));
}

test "Folder: any extension (videos)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "GRADMA.mp4", .data = "v" });
    var d = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var s: Stack = .{ .io = io, .gpa = testing.allocator };
    defer s.deinit();
    try s.sources.append(testing.allocator, .{ .folder = .{ .dir = d, .path = "avi", .prefix = "video/", .any_ext = true } });
    var lb: [64]u8 = undefined;
    try testing.expectEqualStrings("avi/GRADMA.mp4", s.locate(&lb, "video/gradma.avi").?);
    try testing.expect(s.locate(&lb, "sprites/gradma.avi") == null);
}

test "Stack: a package's own assets override the archive entry, the rest falls through" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testGame(io, tmp.dir);
    try package.write(io, a, tmp.dir, "p.ogp", &.{ .{ .path = "src/game.ogs", .data = "" }, .{ .path = "src/assets/sprites/Icons/axe.spr", .data = "my axe" } });
    var pkg = try package.Package.open(io, a, tmp.dir, "p.ogp");
    defer pkg.close(io);
    var dat = try tmp.dir.openDir(io, "dat", .{});
    defer dat.close(io);
    var s: Stack = try .og(io, testing.allocator, .{ .package = &pkg }, dat);
    defer s.deinit();
    try testing.expectEqualStrings("my axe", try s.read(a, "sprites/icons/axe.spr"));
    try testing.expectEqual(@as(?u64, 6), s.size("sprites/ICONS/axe.spr"));
    var h: [2]u8 = undefined;
    try testing.expectEqual(@as(?usize, 2), s.head("sprites/icons/axe.spr", &h));
    try testing.expectEqualStrings("common", try s.read(a, "sprites/lever.spr"));
    // A text of the package is no asset.
    try testing.expect(!s.exists("game.ogs"));
}
