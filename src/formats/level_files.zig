//! Level data from `dat/<level>/other.dat`: paths `.ap`, areas `.ar`, lights `.lts`,
//! walk grid `.wm`/`.wm2`, battle grid `.cm`.
//!
//! All strings (names) in results point into the source text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const Lines = text.Lines;

const Error = text.Error || Allocator.Error || error{Truncated};

// ---------------------------------------------------------------- .ap

pub const Path = struct {
    name: []const u8,
    /// `link: sx, sy, dx, dy`: anchor points (grid cells? unverified).
    link: [4]f32,
    /// x, y (background pixels), node angle (rad, +0xa0 — ActorAdjustAngle), an int (+0xe0);
    /// format " %d,%d,%f,%d " (0x4ab326).
    points: [][4]f32,
};

pub fn parsePaths(gpa: Allocator, src: []const u8) Error![]Path {
    var lines: Lines = .init(src);
    const count = try lines.expectCount("pathCnt=");
    const paths = try gpa.alloc(Path, count);
    var done: usize = 0;
    errdefer {
        for (paths[0..done]) |p| gpa.free(p.points);
        gpa.free(paths);
    }
    for (paths) |*p| {
        p.name = try lines.expect("pathName:");
        p.link = try text.floats(4, try lines.expect("link:"), " ,sxdy");
        const n = try lines.expectCount("pointCnt=");
        p.points = try gpa.alloc([4]f32, n);
        done += 1;
        for (p.points) |*pt| pt.* = try text.floats(4, lines.nextNonEmpty() orelse return error.BadSyntax, ",");
    }
    return paths;
}

pub fn freePaths(gpa: Allocator, paths: []Path) void {
    for (paths) |p| gpa.free(p.points);
    gpa.free(paths);
}

/// `.ap` text of `paths` in the game's layout (Windows lines; the node's angle `%f`, the
/// rest whole numbers, as 0x4ab326 reads them).
pub fn encodePaths(gpa: Allocator, paths: []const Path) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "pathCnt={d}\r\n", .{paths.len});
    for (paths) |p| {
        try out.print(gpa, "pathName: {s}\r\n    link: sx {d}, sy {d}, dx {d}, dy {d}\r\n    pointCnt={d}\r\n", .{ p.name, whole(p.link[0]), whole(p.link[1]), whole(p.link[2]), whole(p.link[3]), p.points.len });
        for (p.points) |pt| try out.print(gpa, "        {d},{d},{d:.6},{d}\r\n", .{ whole(pt[0]), whole(pt[1]), pt[2], whole(pt[3]) });
        try out.appendSlice(gpa, "\r\n");
    }
    return out.toOwnedSlice(gpa);
}

fn whole(v: f32) i32 {
    return @intFromFloat(@round(v));
}

test encodePaths {
    const src = "pathCnt=1\r\npathName: deska\r\n    link: sx 182, sy 22, dx 189, dy 11\r\n    pointCnt=2\r\n        1460,180,0.000000,135\r\n        1516,92,-1.040000,-44\r\n\r\n";
    const ps = try parsePaths(std.testing.allocator, src);
    defer freePaths(std.testing.allocator, ps);
    const out = try encodePaths(std.testing.allocator, ps);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

// ---------------------------------------------------------------- .ar

pub const Area = struct {
    name: []const u8,
    /// Polygon: x, y (background pixels), z.
    points: [][3]f32,
    /// Area "entry" point. z is often garbage (0xCDCDCDCD as a float), do not use.
    control: [2]f32,
};

pub fn parseAreas(gpa: Allocator, src: []const u8) Error![]Area {
    var lines: Lines = .init(src);
    const count = try lines.expectCount("areaCnt=");
    const areas = try gpa.alloc(Area, count);
    var done: usize = 0;
    errdefer {
        for (areas[0..done]) |a| gpa.free(a.points);
        gpa.free(areas);
    }
    for (areas) |*a| {
        a.name = try lines.expect("areaName:");
        const n = try lines.expectCount("pointCnt=");
        if (n == 0) return error.BadSyntax;
        a.points = try gpa.alloc([3]f32, n);
        done += 1;
        for (a.points) |*pt| pt.* = try text.floats(3, lines.nextNonEmpty() orelse return error.BadSyntax, ",");
        var cp: [3]f32 = undefined;
        // Two files have controlPoint with only x,y; one .ar lacks it entirely.
        if (peekPrefix(lines, "controlPoint:")) {
            _ = try text.floatsUpTo(&cp, 2, try lines.expect("controlPoint:"), ",");
            a.control = cp[0..2].*;
        } else {
            a.control = a.points[0][0..2].*;
        }
    }
    return areas;
}

pub fn freeAreas(gpa: Allocator, areas: []Area) void {
    for (areas) |a| gpa.free(a.points);
    gpa.free(areas);
}

fn peekPrefix(lines: Lines, prefix: []const u8) bool {
    var copy = lines;
    const l = copy.nextNonEmpty() orelse return false;
    return std.mem.startsWith(u8, l, prefix);
}

// ---------------------------------------------------------------- .lts

pub const Omni = struct { pos: [3]f32, color: [3]f32, range: f32 };

pub const Lights = struct {
    omni: []Omni,
    ambient: [3]f32,
    directional_color: [3]f32,
    shadow_light: [3]f32,
    shadow_intensity: f32,

    pub fn deinit(self: *Lights, gpa: Allocator) void {
        gpa.free(self.omni);
        self.* = undefined;
    }
};

pub fn parseLights(gpa: Allocator, src: []const u8) Error!Lights {
    var lines: Lines = .init(src);
    const n = try lines.expectCount("omniNo=");
    const omni = try gpa.alloc(Omni, n);
    errdefer gpa.free(omni);
    for (omni) |*o| {
        const l = lines.nextNonEmpty() orelse return error.BadSyntax;
        o.* = .{
            .pos = try text.floats(3, try text.field(l, "pos:"), ", "),
            .color = try text.floats(3, try text.field(l, "color:"), ", "),
            .range = (try text.floats(1, try text.field(l, "range:"), ", "))[0],
        };
    }
    return .{
        .omni = omni,
        .ambient = try text.floats(3, try lines.expect("ambient="), ","),
        .directional_color = try text.floats(3, try lines.expect("directionalColor="), ","),
        .shadow_light = try text.floats(3, try lines.expect("shadowLight="), ","),
        .shadow_intensity = try lines.expectFloat("shadowIntensity="),
    };
}

/// `.lts` text as the game's (C `%f`, CRLF; the exe reads it with the same sscanf formats).
pub fn encodeLights(gpa: Allocator, l: Lights) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "omniNo={d}\r\n", .{l.omni.len});
    for (l.omni) |o| try out.print(gpa, "pos: {d:.6},{d:.6},{d:.6}, color: {d:.6},{d:.6},{d:.6}, range: {d:.6}\r\n", .{
        cf(o.pos[0]), cf(o.pos[1]), cf(o.pos[2]), cf(o.color[0]), cf(o.color[1]), cf(o.color[2]), cf(o.range),
    });
    const a = l.ambient;
    const dc = l.directional_color;
    const s = l.shadow_light;
    try out.print(gpa, "ambient={d:.6},{d:.6},{d:.6}\r\ndirectionalColor={d:.6},{d:.6},{d:.6}\r\nshadowLight={d:.6},{d:.6},{d:.6}\r\nshadowIntensity={d:.6}\r\n", .{
        cf(a[0]), cf(a[1]), cf(a[2]), cf(dc[0]), cf(dc[1]), cf(dc[2]), cf(s[0]), cf(s[1]), cf(s[2]), cf(l.shadow_intensity),
    });
    return out.toOwnedSlice(gpa);
}

/// As C passes a float to printf: widened to double.
fn cf(v: f32) f64 {
    return v;
}

// ---------------------------------------------------------------- .wm / .wm2

/// Exploration level grid, 8×8 background-pixel cells.
/// `.wm` is the main floor, `.wm2` the second (bridges, roofs; switched by
/// `TestActorMapChange` in the level script).
pub const WalkMap = struct {
    width: u32,
    height: u32,
    cells: []Cell,

    pub const Cell = struct {
        /// Bit 0 — walkable; bit 1 — start cell of an `.ap` path (link sx, sy),
        /// bit 2 — end cell (dx, dy); bits 3–5 the exe puts into the grid word
        /// (0x4abae1), they are zero in the data (0x4ab8b0).
        kind: u8,
        /// Floor height; the exe takes 12 signed bits (0x4abafd), the data never exceeds that.
        height: i16,
    };

    pub fn deinit(self: *WalkMap, gpa: Allocator) void {
        gpa.free(self.cells);
        self.* = undefined;
    }

    pub fn at(self: WalkMap, x: usize, y: usize) Cell {
        return self.cells[y * self.width + x];
    }
};

pub fn parseWalkMap(gpa: Allocator, bytes: []const u8) Error!WalkMap {
    if (bytes.len < 8) return error.Truncated;
    const w = std.mem.readInt(u32, bytes[0..4], .little);
    const h = std.mem.readInt(u32, bytes[4..8], .little);
    const n = std.math.mul(usize, w, h) catch return error.Truncated;
    if (bytes.len != 8 + (std.math.mul(usize, n, 3) catch return error.Truncated)) return error.Truncated;
    const cells = try gpa.alloc(WalkMap.Cell, n);
    for (cells, 0..) |*c, i| {
        const raw = bytes[8 + i * 3 ..][0..3];
        c.* = .{ .kind = raw[0], .height = std.mem.readInt(i16, raw[1..3], .little) };
    }
    return .{ .width = w, .height = h, .cells = cells };
}

/// `.wm` bytes of `m` (as parseWalkMap reads them).
pub fn encodeWalkMap(gpa: Allocator, m: WalkMap) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, 8 + m.cells.len * 3);
    std.mem.writeInt(u32, out[0..4], m.width, .little);
    std.mem.writeInt(u32, out[4..8], m.height, .little);
    for (m.cells, 0..) |c, i| {
        out[8 + i * 3] = c.kind;
        std.mem.writeInt(i16, out[8 + i * 3 + 1 ..][0..2], c.height, .little);
    }
    return out;
}

// ---------------------------------------------------------------- .cm

/// Battle grid. Cells are in world 3D coordinates and projected by the level's
/// `initCamera()` camera.
pub const CombatMap = struct {
    center: [3]f32,
    rotation: f32,
    /// Cell size in world units.
    cell_size: [2]f32,
    width: u32,
    height: u32,
    /// true — cell blocked (`O`), rows top to bottom as in the file.
    blocked: []bool,
    /// Cells with height: x, y, height.
    heights: [][3]i32,

    pub fn deinit(self: *CombatMap, gpa: Allocator) void {
        gpa.free(self.blocked);
        gpa.free(self.heights);
        self.* = undefined;
    }
};

pub fn parseCombatMap(gpa: Allocator, src: []const u8) Error!CombatMap {
    var lines: Lines = .init(src);
    var m: CombatMap = undefined;
    m.center = .{ try lines.expectFloat("centerX="), try lines.expectFloat("centerY="), try lines.expectFloat("centerZ=") };
    m.rotation = try lines.expectFloat("rotation=");
    m.cell_size = .{ try lines.expectFloat("xSize="), try lines.expectFloat("ySize=") };
    m.width = try lines.expectInt(u32, "width=");
    m.height = try lines.expectInt(u32, "height=");
    // Edge cells are u8 (GridEdge).
    if (m.width > 255 or m.height > 255) return error.BadSyntax;

    m.blocked = try gpa.alloc(bool, @as(usize, m.width) * m.height);
    errdefer gpa.free(m.blocked);
    for (0..m.height) |y| {
        const row = lines.nextNonEmpty() orelse return error.BadSyntax;
        if (row.len != m.width) return error.BadSyntax;
        for (row, 0..) |ch, x| m.blocked[y * m.width + x] = switch (ch) {
            '.' => false,
            'O' => true,
            else => return error.BadSyntax,
        };
    }

    // One file (03__museum_monuments) lacks heightCnt.
    const count: u32 = if (peekPrefix(lines, "heightCnt=")) try lines.expectCount("heightCnt=") else 0;
    m.heights = try gpa.alloc([3]i32, count);
    errdefer gpa.free(m.heights);
    for (m.heights) |*h| {
        const l = lines.nextNonEmpty() orelse return error.BadSyntax;
        const f = try text.floats(3, l, " \t");
        for (f) |v| if (!(@abs(v) < 2147483648.0)) return error.BadSyntax;
        h.* = .{ @intFromFloat(f[0]), @intFromFloat(f[1]), @intFromFloat(f[2]) };
    }
    return m;
}

/// `.cm` text as the game's (C `%f`, CRLF, blank lines between the parts); a map
/// read without `heightCnt` (03__museum_monuments) gets `heightCnt=0`.
pub fn encodeCombatMap(gpa: Allocator, m: CombatMap) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "centerX={d:.6}\r\ncenterY={d:.6}\r\ncenterZ={d:.6}\r\nrotation={d:.6}\r\nxSize={d:.6}\r\nySize={d:.6}\r\n\r\nwidth={d}\r\nheight={d}\r\n\r\n", .{
        cf(m.center[0]), cf(m.center[1]), cf(m.center[2]), cf(m.rotation), cf(m.cell_size[0]), cf(m.cell_size[1]), m.width, m.height,
    });
    for (0..m.height) |y| {
        for (m.blocked[y * m.width ..][0..m.width]) |b| try out.append(gpa, if (b) 'O' else '.');
        try out.appendSlice(gpa, "\r\n");
    }
    try out.print(gpa, "\r\nheightCnt={d}\r\n", .{m.heights.len});
    for (m.heights) |h| try out.print(gpa, "{d} {d} {d}\r\n", .{ h[0], h[1], h[2] });
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- tests

test parsePaths {
    const gpa = std.testing.allocator;
    const src = "pathCnt=1\r\npathName: deska\r\n    link: sx 182, sy 22, dx 189, dy 11\r\n    pointCnt=2\r\n" ++
        "        1460,180,0.000000,135\r\n        1516,92,-1.5,135\r\n";
    const paths = try parsePaths(gpa, src);
    defer freePaths(gpa, paths);
    try std.testing.expectEqualStrings("deska", paths[0].name);
    try std.testing.expectEqual([4]f32{ 182, 22, 189, 11 }, paths[0].link);
    try std.testing.expectEqual([4]f32{ 1516, 92, -1.5, 135 }, paths[0].points[1]);
}

test parseAreas {
    const gpa = std.testing.allocator;
    const src = "areaCnt=2\r\nareaName: fight5_place\r\npointCnt=3\r\n0,0,0.0\r\n10,0,0\r\n0,10,0\r\n" ++
        "controlPoint: 320,370,-431602080.000000\r\nareaName: b\r\npointCnt=3\r\n0,0,0\r\n1,0,0\r\n0,1,0\r\ncontrolPoint: 5,6\r\n";
    const areas = try parseAreas(gpa, src);
    defer freeAreas(gpa, areas);
    try std.testing.expectEqualStrings("fight5_place", areas[0].name);
    try std.testing.expectEqual([2]f32{ 320, 370 }, areas[0].control);
    try std.testing.expectEqual([2]f32{ 5, 6 }, areas[1].control);
}

test parseLights {
    const gpa = std.testing.allocator;
    const src = "omniNo=1\r\npos: 1648.7,-404.3,118.3, color: 1.0,1.0,0.79, range: 167.3\r\n" ++
        "ambient=0.25,0.25,0.25\r\ndirectionalColor=0.47,0.47,0.47\r\nshadowLight=2294.4,-1978.4,6218.5\r\nshadowIntensity=0.5\r\n";
    var l = try parseLights(gpa, src);
    defer l.deinit(gpa);
    try std.testing.expectEqual(1, l.omni.len);
    try std.testing.expectApproxEqAbs(167.3, l.omni[0].range, 1e-3);
    try std.testing.expectEqual(0.5, l.shadow_intensity);
}

test encodeLights {
    const gpa = std.testing.allocator;
    const src = "omniNo=2\r\npos: 1648.724121,-404.325958,118.356354, color: 1.000000,1.000000,0.790000, range: 167.317535\r\n" ++
        "pos: -50.230278,5.929730,-66.137024, color: 0.830000,0.300000,0.200000, range: 15.391061\r\n" ++
        "ambient=0.254902,0.254902,0.254902\r\ndirectionalColor=0.470588,0.470588,0.470588\r\n" ++
        "shadowLight=2294.429199,-1978.424927,6218.500000\r\nshadowIntensity=0.500000\r\n";
    var l = try parseLights(gpa, src);
    defer l.deinit(gpa);
    const out = try encodeLights(gpa, l);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test parseWalkMap {
    const gpa = std.testing.allocator;
    const bytes = [_]u8{ 2, 0, 0, 0, 1, 0, 0, 0, 1, 0xee, 0xff, 0, 0, 0 };
    var m = try parseWalkMap(gpa, &bytes);
    defer m.deinit(gpa);
    try std.testing.expectEqual(WalkMap.Cell{ .kind = 1, .height = -18 }, m.at(0, 0));
    try std.testing.expectEqual(WalkMap.Cell{ .kind = 0, .height = 0 }, m.at(1, 0));
}

test parseCombatMap {
    const gpa = std.testing.allocator;
    const src = "centerX=-1416.8\r\ncenterY=-227.1\r\ncenterZ=-76\r\nrotation=0\r\nxSize=39.5\r\nySize=39.5\r\n\r\n" ++
        "width=3\r\nheight=2\r\n\r\nOO.\r\n...\r\n\r\nheightCnt=1\r\n2 1 92\r\n";
    var m = try parseCombatMap(gpa, src);
    defer m.deinit(gpa);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, false, false, false }, m.blocked);
    try std.testing.expectEqualSlices([3]i32, &.{.{ 2, 1, 92 }}, m.heights);
}

test "bad level files are errors, not panics" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadSyntax, parseAreas(gpa, "areaCnt=1\r\nareaName: a\r\npointCnt=0\r\n"));
    try std.testing.expectError(error.BadSyntax, parsePaths(gpa, "pathCnt=4000000000\r\n"));
    const head = "centerX=0\r\ncenterY=0\r\ncenterZ=0\r\nrotation=0\r\nxSize=1\r\nySize=1\r\n";
    try std.testing.expectError(error.BadSyntax, parseCombatMap(gpa, head ++ "width=300\r\nheight=1\r\n"));
    try std.testing.expectError(error.BadSyntax, parseCombatMap(gpa, head ++ "width=1\r\nheight=1\r\n.\r\nheightCnt=1\r\nnan 0 0\r\n"));
}

test "walk map with overflowing size is an error" {
    const bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.Truncated, parseWalkMap(std.testing.allocator, &bytes));
}

test encodeWalkMap {
    const gpa = std.testing.allocator;
    var cells = [_]WalkMap.Cell{ .{ .kind = 1, .height = -5 }, .{ .kind = 4, .height = 300 } };
    const bytes = try encodeWalkMap(gpa, .{ .width = 2, .height = 1, .cells = &cells });
    defer gpa.free(bytes);
    var m = try parseWalkMap(gpa, bytes);
    defer m.deinit(gpa);
    try std.testing.expectEqual(-5, m.cells[0].height);
    try std.testing.expectEqual(4, m.cells[1].kind);
}

test encodeCombatMap {
    const gpa = std.testing.allocator;
    const src = "centerX=-806.784790\r\ncenterY=-552.054810\r\ncenterZ=-79.000000\r\nrotation=0.040000\r\nxSize=59.500000\r\nySize=59.500000\r\n\r\n" ++
        "width=3\r\nheight=2\r\n\r\nOO.\r\n..O\r\n\r\nheightCnt=2\r\n7 13 86\r\n8 13 -5\r\n";
    var m = try parseCombatMap(gpa, src);
    defer m.deinit(gpa);
    const out = try encodeCombatMap(gpa, m);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(src, out);
}
