//! The OpenGorky packages a player has (`<id>.ogp`, a project's `dist/`): in the game
//! folder's `mods/` and in the settings folder's `mods/` (beside opengorky.cfg). The
//! launcher lists them beside the original game; the chosen one (`package` in the
//! settings, its file name) is what Play starts, over the game folder's assets.

const std = @import("std");
const Io = std.Io;
const og = @import("opengorky");

pub const Package = struct {
    /// Its file name (`gorky.ogp`): what the settings keep.
    file: []const u8,
    path: []const u8,
    /// The manifest's `title`, else the file name.
    title: []const u8,
    /// Made for this engine or an older one (else Play refuses it).
    supported: bool,
};

/// Every package of the two `mods/` folders (the game's first; a name in both: the game's),
/// by title; in `a`.
pub fn find(io: Io, a: std.mem.Allocator, game_dir: []const u8, cfg_dir: ?[]const u8) []const Package {
    var out: std.ArrayList(Package) = .empty;
    for ([_]?[]const u8{ game_dir, cfg_dir }) |base| {
        const b = base orelse continue;
        if (b.len == 0) continue;
        const dir_path = std.fmt.allocPrint(a, "{s}/mods", .{b}) catch continue;
        var d = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file or !og.loaders.ogs.isPackage(e.name)) continue;
            const seen = for (out.items) |p| {
                if (std.ascii.eqlIgnoreCase(p.file, e.name)) break true;
            } else false;
            if (seen) continue;
            const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, e.name }) catch continue;
            const text = og.loaders.ogs.manifestAt(io, a, path);
            if (text.len == 0) continue;
            const m = og.formats.manifest.Manifest.parse(text);
            const file = a.dupe(u8, e.name) catch continue;
            out.append(a, .{ .file = file, .path = path, .title = if (m.title().len > 0) (a.dupe(u8, m.title()) catch file) else file, .supported = m.supported() }) catch {};
        }
    }
    std.mem.sort(Package, out.items, {}, struct {
        fn lt(_: void, x: Package, y: Package) bool {
            return std.ascii.lessThanIgnoreCase(x.title, y.title);
        }
    }.lt);
    return out.items;
}

/// The path of package file `file` (the settings' `package`), or null: not there.
pub fn resolve(io: Io, a: std.mem.Allocator, game_dir: []const u8, cfg_dir: ?[]const u8, file: []const u8) ?[]const u8 {
    for (find(io, a, game_dir, cfg_dir)) |p| if (std.ascii.eqlIgnoreCase(p.file, file)) return p.path;
    return null;
}

test "packages: the mods folders' .ogp files, the game's first, by title" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Not a package: a stray file, an .ogp without a manifest.
    try tmp.dir.createDirPath(io, "game/mods");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/mods/readme.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/mods/broken.ogp", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const game = try std.fmt.allocPrint(a, "{s}/game", .{root});
    try std.testing.expectEqual(0, find(io, a, game, null).len);
    try std.testing.expect(resolve(io, a, game, null, "broken.ogp") == null);
}
