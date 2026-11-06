//! The OpenGorky package `dist/<id>.ogp`: what the viewer
//! plays — the manifest, every `.ogs` text of `src/` as is and the project's own assets
//! (`src/assets/…`), each under its path in the project (`opengorky.mod`,
//! `src/rules/ui.ogs`, `src/assets/sprites/x.spr`). The original's assets are never in
//! it: the reader takes them from the installed game (loaders/assets.zig).
//! Its own small container, not a game archive (formats/archive.zig is Classic's), all
//! numbers little-endian:
//!   "OGP1", u32 entry count, u32 table size in bytes;
//!   the table: per entry u16 path length, the path, u64 offset, u64 size, the sha256;
//!   the data, entry after entry.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const magic = "OGP1";
const head_size = 12;

pub const Entry = struct {
    path: []const u8,
    offset: u64,
    size: u64,
    sha: [32]u8,
};

/// A package open for reading: its table in memory, the data read on demand.
pub const Package = struct {
    file: Io.File,
    entries: []const Entry,

    /// Package `sub_path` of `dir`, its table in `a` (error.BadPackage: not one, or cut short).
    pub fn open(io: Io, a: Allocator, dir: Io.Dir, sub_path: []const u8) !Package {
        const file = try dir.openFile(io, sub_path, .{});
        errdefer file.close(io);
        var hd: [head_size]u8 = undefined;
        if (try file.readPositionalAll(io, &hd, 0) != head_size or !std.mem.eql(u8, hd[0..4], magic)) return error.BadPackage;
        const count = std.mem.readInt(u32, hd[4..8], .little);
        const toc = try a.alloc(u8, std.mem.readInt(u32, hd[8..12], .little));
        if (try file.readPositionalAll(io, toc, head_size) != toc.len) return error.BadPackage;
        const entries = try a.alloc(Entry, count);
        var at: usize = 0;
        const end = (try file.stat(io)).size;
        for (entries) |*e| {
            if (at + 2 > toc.len) return error.BadPackage;
            const n = std.mem.readInt(u16, toc[at..][0..2], .little);
            at += 2;
            if (at + n + 48 > toc.len) return error.BadPackage;
            e.* = .{
                .path = toc[at..][0..n],
                .offset = std.mem.readInt(u64, toc[at + n ..][0..8], .little),
                .size = std.mem.readInt(u64, toc[at + n + 8 ..][0..8], .little),
                .sha = toc[at + n + 16 ..][0..32].*,
            };
            at += n + 48;
            if (e.offset + e.size > end) return error.BadPackage;
        }
        return .{ .file = file, .entries = entries };
    }

    pub fn close(self: *Package, io: Io) void {
        self.file.close(io);
    }

    /// Entry `path` (exact; `ignore_case`: as on Windows, the assets' rule).
    pub fn find(self: *const Package, path: []const u8, ignore_case: bool) ?*const Entry {
        for (self.entries) |*e| if (if (ignore_case) std.ascii.eqlIgnoreCase(e.path, path) else std.mem.eql(u8, e.path, path)) return e;
        return null;
    }

    /// Entry `e`'s bytes in `a`.
    pub fn read(self: *const Package, io: Io, a: Allocator, e: *const Entry) ![]u8 {
        const buf = try a.alloc(u8, e.size);
        errdefer a.free(buf);
        if (try self.file.readPositionalAll(io, buf, e.offset) != buf.len) return error.BadPackage;
        return buf;
    }

    /// The first `dst.len` bytes of `e` (a header); the count read.
    pub fn head(self: *const Package, io: Io, e: *const Entry, dst: []u8) !usize {
        return self.file.readPositionalAll(io, dst[0..@min(dst.len, e.size)], e.offset);
    }
};

/// One file going into a package: its path and bytes (`sha`: their hash, if known).
pub const File = struct { path: []const u8, data: []const u8, sha: ?[32]u8 = null };

pub fn hash(data: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    Sha256.hash(data, &h, .{});
    return h;
}

/// `files` as package `sub_path` of `dir`, in their order: written beside it first, then
/// renamed over it (a reader never sees half a package).
pub fn write(io: Io, a: Allocator, dir: Io.Dir, sub_path: []const u8, files: []const File) !void {
    var toc_size: usize = 0;
    for (files) |f| toc_size += 2 + f.path.len + 48;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(magic);
    try w.writeInt(u32, @intCast(files.len), .little);
    try w.writeInt(u32, @intCast(toc_size), .little);
    var offset: u64 = head_size + toc_size;
    for (files) |f| {
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeAll(f.path);
        try w.writeInt(u64, offset, .little);
        try w.writeInt(u64, f.data.len, .little);
        try w.writeAll(&(f.sha orelse hash(f.data)));
        offset += f.data.len;
    }
    for (files) |f| try w.writeAll(f.data);
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{sub_path});
    defer a.free(tmp);
    try dir.writeFile(io, .{ .sub_path = tmp, .data = out.written() });
    try Io.Dir.rename(dir, tmp, dir, sub_path, io);
}

test "package: written and read back, the table checked" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, a, tmp.dir, "p.ogp", &.{ .{ .path = "opengorky.mod", .data = "format = ogs\n" }, .{ .path = "src/game.ogs", .data = "game g { }\n" }, .{ .path = "src/assets/Sprites/x.spr", .data = "" } });
    var p = try Package.open(io, a, tmp.dir, "p.ogp");
    defer p.close(io);
    try std.testing.expectEqual(3, p.entries.len);
    try std.testing.expectEqualStrings("game g { }\n", try p.read(io, a, p.find("src/game.ogs", false).?));
    try std.testing.expectEqual(hash("format = ogs\n"), p.find("opengorky.mod", false).?.sha);
    try std.testing.expect(p.find("src/assets/sprites/X.SPR", false) == null);
    try std.testing.expectEqual(0, p.find("src/assets/sprites/X.SPR", true).?.size);
    // Not a package; one cut short.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.ogp", .data = "OGP1\x05\x00\x00\x00\xff\x00\x00\x00" });
    try std.testing.expectError(error.BadPackage, Package.open(io, a, tmp.dir, "bad.ogp"));
    try tmp.dir.writeFile(io, .{ .sub_path = "zip.ogp", .data = "PK\x03\x04............" });
    try std.testing.expectError(error.BadPackage, Package.open(io, a, tmp.dir, "zip.ogp"));
}
