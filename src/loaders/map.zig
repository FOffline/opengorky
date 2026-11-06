//! A location's map (core/map.zig) from its level files: `levels/<level>/areas.ar`,
//! `grid.cm`, `walk.wm`, `walk2.wm2`, `paths.ap` (loaders/assets.zig; Classic:
//! `<level>.ar|cm|wm|wm2|ap` of `<level>/other.dat`), read once at level entry. Also the editor's way to the same
//! records and back to the files (parse*/encode* over formats/level_files.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("assets.zig");
const lf = @import("../formats.zig").level_files;
const map = @import("../core.zig").map;

/// The map of `level` from its files in `s`, in `a` (the world's arena). `.wm` and
/// `.cm` errors fail the load; a bad `.wm2`/`.ap` is warned about and left out (the exe
/// reports via 0x401f20 and continues).
pub fn load(s: *assets.Stack, a: Allocator, level: []const u8) !map.Map {
    const L = struct {
        fn file(st: *assets.Stack, al: Allocator, lv: []const u8, name: []const u8) !?[]const u8 {
            var buf: [assets.max_path]u8 = undefined;
            return st.read(al, try std.fmt.bufPrint(&buf, "levels/{s}/{s}", .{ lv, name })) catch |err| switch (err) {
                error.NotFound => null,
                else => err,
            };
        }
    };
    var m: map.Map = .{};
    if (try L.file(s, a, level, "areas.ar")) |t| m.areas = try parseAreas(a, t);
    if (try L.file(s, a, level, "grid.cm")) |t| m.combat = try parseCombatMap(a, t);
    if (try L.file(s, a, level, "walk.wm")) |t| m.walk = try parseWalkMap(a, t);
    if (try L.file(s, a, level, "walk2.wm2")) |t| m.walk2 = parseWalkMap(a, t) catch |err| blk: {
        std.log.warn("{s}.wm2: {t}", .{ level, err });
        break :blk null;
    };
    if (try L.file(s, a, level, "paths.ap")) |t| m.paths = parsePaths(a, t) catch |err| blk: {
        std.log.warn("{s}.ap: {t}", .{ level, err });
        break :blk &.{};
    };
    return m;
}

/// `.wm` bytes as the core's walk grid (cells in `gpa`).
pub fn parseWalkMap(gpa: Allocator, bytes: []const u8) !map.WalkMap {
    var f = try lf.parseWalkMap(gpa, bytes);
    defer f.deinit(gpa);
    const cells = try gpa.alloc(map.WalkMap.Cell, f.cells.len);
    for (cells, f.cells) |*o, c| o.* = .{ .kind = c.kind, .height = c.height };
    return .{ .width = f.width, .height = f.height, .cells = cells };
}

pub fn encodeWalkMap(gpa: Allocator, m: map.WalkMap) ![]u8 {
    const cells = try gpa.alloc(lf.WalkMap.Cell, m.cells.len);
    defer gpa.free(cells);
    for (cells, m.cells) |*o, c| o.* = .{ .kind = c.kind, .height = c.height };
    return lf.encodeWalkMap(gpa, .{ .width = m.width, .height = m.height, .cells = cells });
}

/// `.cm` text as the core's battle grid (its cells and heights in `gpa`).
pub fn parseCombatMap(gpa: Allocator, src: []const u8) !map.CombatMap {
    const f = try lf.parseCombatMap(gpa, src);
    return .{ .center = f.center, .rotation = f.rotation, .cell_size = f.cell_size, .width = f.width, .height = f.height, .blocked = f.blocked, .heights = f.heights };
}

pub fn encodeCombatMap(gpa: Allocator, m: map.CombatMap) ![]u8 {
    return lf.encodeCombatMap(gpa, .{ .center = m.center, .rotation = m.rotation, .cell_size = m.cell_size, .width = m.width, .height = m.height, .blocked = m.blocked, .heights = m.heights });
}

/// `.ar` text as the core's areas (names point into `src`; free with map.freeAreas).
pub fn parseAreas(gpa: Allocator, src: []const u8) ![]map.Area {
    const f = try lf.parseAreas(gpa, src);
    defer gpa.free(f);
    errdefer for (f) |x| gpa.free(x.points);
    const out = try gpa.alloc(map.Area, f.len);
    for (out, f) |*o, x| o.* = .{ .name = x.name, .points = x.points, .control = x.control };
    return out;
}

/// `.ap` text as the core's paths (names point into `src`; free with map.freePaths).
pub fn parsePaths(gpa: Allocator, src: []const u8) ![]map.Path {
    const f = try lf.parsePaths(gpa, src);
    defer gpa.free(f);
    errdefer for (f) |x| gpa.free(x.points);
    const out = try gpa.alloc(map.Path, f.len);
    for (out, f) |*o, x| o.* = .{ .name = x.name, .link = x.link, .points = x.points };
    return out;
}

pub fn encodePaths(gpa: Allocator, paths: []const map.Path) ![]u8 {
    const f = try gpa.alloc(lf.Path, paths.len);
    defer gpa.free(f);
    for (f, paths) |*o, x| o.* = .{ .name = x.name, .link = x.link, .points = x.points };
    return lf.encodePaths(gpa, f);
}

test "level files round-trip through the core's records" {
    const gpa = std.testing.allocator;
    const cm = "centerX=-806.784790\r\ncenterY=-552.054810\r\ncenterZ=-79.000000\r\nrotation=0.040000\r\nxSize=59.500000\r\nySize=59.500000\r\n\r\n" ++
        "width=3\r\nheight=2\r\n\r\nOO.\r\n..O\r\n\r\nheightCnt=2\r\n7 13 86\r\n8 13 -5\r\n";
    var g = try parseCombatMap(gpa, cm);
    defer g.deinit(gpa);
    const cm_out = try encodeCombatMap(gpa, g);
    defer gpa.free(cm_out);
    try std.testing.expectEqualStrings(cm, cm_out);

    const wm = [_]u8{ 2, 0, 0, 0, 1, 0, 0, 0, 1, 0xee, 0xff, 4, 0x2c, 0x01 };
    var w = try parseWalkMap(gpa, &wm);
    defer w.deinit(gpa);
    try std.testing.expectEqual(map.WalkMap.Cell{ .kind = 1, .height = -18 }, w.at(0, 0));
    const wm_out = try encodeWalkMap(gpa, w);
    defer gpa.free(wm_out);
    try std.testing.expectEqualSlices(u8, &wm, wm_out);

    const ap = "pathCnt=1\r\npathName: deska\r\n    link: sx 182, sy 22, dx 189, dy 11\r\n    pointCnt=2\r\n        1460,180,0.000000,135\r\n        1516,92,-1.040000,-44\r\n\r\n";
    const ps = try parsePaths(gpa, ap);
    defer map.freePaths(gpa, ps);
    const ap_out = try encodePaths(gpa, ps);
    defer gpa.free(ap_out);
    try std.testing.expectEqualStrings(ap, ap_out);

    const ar = "areaCnt=1\r\nareaName: fight5_place\r\npointCnt=3\r\n0,0,0.0\r\n10,0,0\r\n0,10,0\r\ncontrolPoint: 320,370\r\n";
    const as = try parseAreas(gpa, ar);
    defer map.freeAreas(gpa, as);
    try std.testing.expect(map.areaContains(as[0], 2, 2) and !map.areaContains(as[0], 8, 8));
}
