//! The game's files as edited, for "where is it used": each file of an archive that a
//! filter takes, with its text — the Store's when edited (unsaved too), the archive's
//! otherwise; files added and not saved yet are there, deleted ones are not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const App = @import("app.zig").App;

pub const File = struct { name: []const u8, text: []const u8 };

/// Scripts the engine's parser reads (`.lev`, `.are`, classes…).
pub fn script(name: []const u8) bool {
    return og.formats.resource.isScript(name);
}

/// Scenes (`scriptlets\<name>.scr`).
pub fn scene(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "scriptlets\\") and std.ascii.endsWithIgnoreCase(name, ".scr");
}

/// Model animation lists (`gfx_3d\…\.ani`).
pub fn anim(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "gfx_3d\\") and std.ascii.endsWithIgnoreCase(name, ".ani");
}

/// File `name` of archive `path` as edited (put in or changed here, unsaved), else the
/// archive's (read into `a`); null if it is not there or deleted.
pub fn read(app: *App, a: Allocator, path: []const u8, name: []const u8) ?[]const u8 {
    if (app.store.find(path, name)) |i| return if (app.store.gone(i)) null else app.store.text(i);
    // OpenGorky: the Store reads the project's own asset first (store.zig ownAsset).
    if (app.store.root != null) return if (app.store.file(path, name)) |i| app.store.text(i) else |_| null;
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, path) catch return null;
    defer ar.close(app.io, app.gpa);
    const e = ar.find(name) orelse return null;
    return ar.readAlloc(app.io, a, e) catch null;
}

/// The files of archive `path` that `keep` takes (texts in `a`).
pub fn files(app: *App, a: Allocator, path: []const u8, keep: *const fn ([]const u8) bool) []const File {
    var out: std.ArrayList(File) = .empty;
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, path) catch null;
    defer if (ar) |*x| x.close(app.io, app.gpa);
    const base: []const og.formats.archive.Entry = if (ar) |x| x.entries else &.{};
    for (app.store.listingOver(a, path, base, keep, false)) |n| {
        const text = if (app.store.find(path, n)) |i| app.store.text(i) else (ar.?.readAlloc(app.io, a, ar.?.find(n).?) catch continue);
        out.append(a, .{ .name = n, .text = text }) catch {};
    }
    return out.items;
}

/// Names of those files whose text has `needle` (case aside); only the names kept in `a`.
pub fn naming(app: *App, a: Allocator, path: []const u8, keep: *const fn ([]const u8) bool, needle: []const u8) []const []const u8 {
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    for (files(app, tmp.allocator(), path, keep)) |f| {
        if (std.ascii.findIgnoreCase(f.text, needle) != null) out.append(a, a.dupe(u8, f.name) catch continue) catch {};
    }
    return out.items;
}
