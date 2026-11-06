//! A mod packed for the original game: the files of the game folder the editor's saves
//! changed (its history, savelog.zig: `dat/**`, `avi/*`, adjust.kdt), copied into a
//! folder with the same layout, with a README and `clear-cache.bat` (the exe keeps
//! drawing its `dat\r1..r7.dat` and `dat\common\sprite.kdt` copies of changed
//! sprite archives until they are gone).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const savelog = @import("savelog.zig");
const store = @import("store.zig");
const test_room = @import("level_templates.zig").test_room;

/// Paths (relative to the game folder, `/`) of the files the editor's saves changed
/// (the history in `game`), there now and with an entry other than before the first
/// save (an archive whose every entry is back as it was is left out); sorted. Edits
/// made outside the editor are not seen.
pub fn changed(io: Io, gpa: Allocator, game: Io.Dir) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var hist = game.openDir(io, savelog.dir_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(gpa),
        else => return err,
    };
    defer hist.close(io);
    var log = try savelog.load(io, gpa, hist);
    defer log.deinit();
    const first = try log.targets(gpa, 0);
    defer gpa.free(first);
    for (first) |f| {
        const rel = if (std.mem.eql(u8, f.archive, store.adjust_file))
            try gpa.dupe(u8, store.adjust_file)
        else if (std.mem.eql(u8, f.archive, store.video_dir))
            try std.fmt.allocPrint(gpa, store.video_dir ++ "/{s}", .{f.entry})
        else
            try std.fmt.allocPrint(gpa, "dat/{s}", .{f.archive});
        const keep = for (out.items) |o| {
            if (std.ascii.eqlIgnoreCase(o, rel)) break false;
        } else if (game.access(io, rel, .{})) |_| try differs(io, gpa, game, rel, f) else |_| false;
        if (keep) try out.append(gpa, rel) else gpa.free(rel);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// Entry `f` of game file `rel` (as the store reads it) is not its first `before`.
fn differs(io: Io, gpa: Allocator, game: Io.Dir, rel: []const u8, f: savelog.File) !bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const now: ?[]const u8 = if (std.mem.eql(u8, f.archive, store.adjust_file))
        try og.formats.adjust.decrypt(a, try game.readFileAlloc(io, rel, a, .limited(1 << 20)))
    else if (std.mem.eql(u8, f.archive, store.video_dir))
        try game.readFileAlloc(io, rel, a, .unlimited)
    else now: {
        var dat = try game.openDir(io, "dat", .{});
        defer dat.close(io);
        var ar = try og.formats.archive.Archive.open(io, a, dat, f.archive);
        defer ar.close(io, a);
        const e = ar.find(f.entry) orelse break :now null;
        break :now try ar.readAlloc(io, a, e);
    };
    const n = now orelse return f.before != null;
    const was = f.before orelse return true;
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(n, &h, .{});
    return !std.mem.eql(u8, &std.fmt.bytesToHex(h, .lower), was);
}

pub fn freeList(gpa: Allocator, items: []const []const u8) void {
    for (items) |p| gpa.free(p);
    gpa.free(items);
}

/// The changed files of `game` copied into `out` (made if missing) under their paths,
/// with README.txt and clear-cache.bat; the files packed.
pub fn pack(io: Io, gpa: Allocator, game: Io.Dir, out: Io.Dir) ![][]const u8 {
    const files = try changed(io, gpa, game);
    errdefer freeList(gpa, files);
    for (files) |rel| {
        if (std.fs.path.dirname(rel)) |d| try out.createDirPath(io, d);
        const data = try game.readFileAlloc(io, rel, gpa, .unlimited);
        defer gpa.free(data);
        try out.writeFile(io, .{ .sub_path = rel, .data = data });
    }
    var readme: std.ArrayList(u8) = .empty;
    defer readme.deinit(gpa);
    try readme.appendSlice(gpa,
        \\Gorky 17 mod (made with the OpenGorky editor)
        \\
        \\Install: copy everything in this folder over the game folder (replace files),
        \\then run clear-cache.bat there once. The game keeps converted copies of
        \\pictures in dat\r1.dat ... r7.dat and dat\common\sprite.kdt and would go on
        \\showing the old ones.
        \\
        \\Pictures, animations, music and voices (sprite.dat, voice.dat) are read from
        \\the folder in the registry value HKLM\SOFTWARE\Metropolis\G17 "src" (GOG sets
        \\it to the game folder). If it points elsewhere, copy the dat folder there too.
        \\
        \\Files:
        \\
    );
    for (files) |rel| {
        try readme.appendSlice(gpa, "  ");
        for (rel) |ch| try readme.append(gpa, if (ch == '/') '\\' else ch);
        try readme.appendSlice(gpa, "\r\n");
    }
    // Windows line ends: the readme and the batch file are for the original's machine.
    const text = try std.mem.replaceOwned(u8, gpa, readme.items, "\n", "\r\n");
    defer gpa.free(text);
    const fixed = try std.mem.replaceOwned(u8, gpa, text, "\r\r\n", "\r\n");
    defer gpa.free(fixed);
    try out.writeFile(io, .{ .sub_path = "README.txt", .data = fixed });
    try out.writeFile(io, .{ .sub_path = "clear-cache.bat", .data = "@echo off\r\ncd /d \"%~dp0\"\r\nfor %%i in (1 2 3 4 5 6 7) do if exist dat\\r%%i.dat del dat\\r%%i.dat\r\nif exist dat\\common\\sprite.kdt del dat\\common\\sprite.kdt\r\necho Picture cache cleared.\r\npause\r\n" });
    return files;
}

test "changed: what the history saved, there now and not back as it was" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const ar = og.formats.archive;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir;
    for ([_][]const u8{ "dat/common", "dat/lv", "avi", savelog.dir_name }) |p| try root.createDirPath(io, p);
    const put = struct {
        fn f(d: Io.Dir, path: []const u8, files: []const ar.File) !void {
            const data = try ar.build(std.testing.allocator, files);
            defer std.testing.allocator.free(data);
            try d.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
        }
    }.f;
    try put(root, "dat/common/other.dat", &.{ .{ .name = "a.lev", .data = "x = 1" }, .{ .name = "", .data = "" } });
    try put(root, "dat/common/lang.dat", &.{ .{ .name = "s.txt", .data = "s" }, .{ .name = "", .data = "" } });
    try put(root, "dat/lv/sprite.dat", &.{ .{ .name = "bg.bmp", .data = "p" }, .{ .name = "", .data = "" } });
    try root.writeFile(io, .{ .sub_path = "avi/clip.asf", .data = "v" });
    const enc = try og.formats.adjust.encode(gpa, "k = 1\n");
    defer gpa.free(enc);
    try root.writeFile(io, .{ .sub_path = "adjust.kdt", .data = enc });
    // Not packed: never saved by the editor.
    try root.writeFile(io, .{ .sub_path = "dat/common/sprite.dat", .data = "outside" });
    var hist = try root.openDir(io, savelog.dir_name, .{});
    defer hist.close(io);
    try savelog.append(io, gpa, hist, 1, "one", "", &.{
        .{ .archive = "common/other.dat", .entry = "a.lev", .before = "x = 0", .after = "x = 1" },
        .{ .archive = "common/lang.dat", .entry = "s.txt", .before = "s", .after = "t" },
        .{ .archive = "lv/sprite.dat", .entry = "bg.bmp", .before = null, .after = "p" },
        .{ .archive = "avi", .entry = "clip.asf", .before = null, .after = "v" },
        .{ .archive = "avi", .entry = "gone.asf", .before = null, .after = "g" },
        .{ .archive = "adjust.kdt", .entry = "adjust.kdt", .before = "k = 0\n", .after = "k = 1\n" },
    });
    // lang.dat back as it was; other.dat again (listed once).
    try savelog.append(io, gpa, hist, 2, "two", "", &.{
        .{ .archive = "common/lang.dat", .entry = "s.txt", .before = "t", .after = "s" },
        .{ .archive = "common/other.dat", .entry = "A.LEV", .before = "x = 1", .after = "x = 1" },
    });
    const files = try changed(io, gpa, root);
    defer freeList(gpa, files);
    try std.testing.expectEqual(4, files.len);
    try std.testing.expectEqualStrings("adjust.kdt", files[0]);
    try std.testing.expectEqualStrings("avi/clip.asf", files[1]);
    try std.testing.expectEqualStrings("dat/common/other.dat", files[2]);
    try std.testing.expectEqualStrings("dat/lv/sprite.dat", files[3]);
}
