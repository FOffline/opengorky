//! Mod check: what the original exe needs of a game folder the editor changed —
//! archives it can read, scripts that parse and find their #include / #inherit,
//! models and textures that exist and fit its limits, levels that LEVEL_Load names.
//! A problem here is one the original would stumble on (a missing object, a crash),
//! even where the port copes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("formats.zig").archive;
const resource = @import("formats.zig").resource;
const tex3df = @import("formats.zig").tex3df;
const parser = @import("script.zig").parser;
const mesh_fmt = @import("formats.zig").mesh;
const anim = @import("formats.zig").anim;
const findScript = @import("loaders.zig").world.findScript;

pub const Problem = struct {
    /// The archive (`common/other.dat`) and its entry ("" — the archive itself).
    archive: []const u8,
    entry: []const u8,
    what: []const u8,
};

const Check = struct {
    io: Io,
    a: Allocator,
    archives: []const []const u8,
    common: archive.Archive,
    out: std.ArrayList(Problem) = .empty,
    /// Models already looked at (lowercase names).
    meshes: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *Check, path: []const u8, entry: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.out.append(self.a, .{ .archive = path, .entry = try self.a.dupe(u8, entry), .what = try std.fmt.allocPrint(self.a, fmt, args) });
    }
};

/// Every problem of the game folder's `dat` (memory from `a`, an arena).
pub fn run(io: Io, a: Allocator, dat: Io.Dir) ![]Problem {
    var c: Check = .{
        .io = io,
        .a = a,
        .archives = try archive.listArchives(io, a, dat),
        .common = try archive.Archive.open(io, a, dat, "common/other.dat"),
    };
    defer c.common.close(io, a);
    for (c.archives) |path| {
        var arc = archive.Archive.open(io, a, dat, path) catch |err| {
            try c.add(path, "", "can't be read ({t})", .{err});
            continue;
        };
        defer arc.close(io, a);
        if (!arc.wellFormed()) try c.add(path, "", "entries out of order, without a time or a script not marked: the exe misses them (Save or `gorky-tool sortdat` fixes it)", .{});
        for (arc.entries) |*e| {
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(e.name), ".3df")) {
                const head = try arc.readAlloc(io, a, e);
                checkTexture(&c, path, e.name, head) catch {};
            } else if (resource.isScript(e.name)) {
                try checkScript(&c, path, arc, e.name, try arc.readAlloc(io, a, e));
            }
        }
    }
    return c.out.items;
}

/// The exe's texture limits: a format its loader knows, power-of-two sides up to 256, at
/// most 8:1. The port reads the rest (the editor's port-only imports make them).
fn checkTexture(c: *Check, path: []const u8, name: []const u8, bytes: []const u8) !void {
    const h = tex3df.parseHeader(bytes) catch |err| return c.add(path, name, "not a texture the exe reads ({t})", .{err});
    if (!tex3df.exeReads(h.format))
        try c.add(path, name, "port only: {t} is not a format the exe loads (\"Unsupported texture format\", 0x43f2b5)", .{h.format});
    if (!std.math.isPowerOfTwo(h.width) or !std.math.isPowerOfTwo(h.height) or @max(h.width, h.height) > 256 or @max(h.width, h.height) / @min(h.width, h.height) > 8)
        try c.add(path, name, "{s}{d}×{d}: the exe takes power-of-two sides up to 256, at most 8:1", .{ if (tex3df.exeReads(h.format)) "" else "port only: ", h.width, h.height });
}

fn checkScript(c: *Check, path: []const u8, arc: archive.Archive, name: []const u8, src: []const u8) !void {
    var diag: parser.Diagnostic = .{};
    const unit = parser.parse(c.a, src, &diag) catch |err| return c.add(path, name, "line {d}: {s} ({t})", .{ diag.line, diag.message, err });
    for (unit.items) |it| switch (it) {
        .include => |n| if (findScript(arc, c.common, n) == null) try c.add(path, name, "#include \"{s}\" not found", .{n}),
        // `#inherit Level` → `level.s`.
        .inherit => |n| {
            const file = if (std.fs.path.extension(n).len > 0) n else try std.fmt.allocPrint(c.a, "{s}.s", .{n});
            if (findScript(arc, c.common, file) == null) try c.add(path, name, "#inherit {s}: {s} not found", .{ n, file });
        },
        else => {},
    };
    // References by name in the text (comments skipped).
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: usize = 0;
    var mesh: ?[]const u8 = null;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = raw[0 .. std.mem.indexOf(u8, raw, "//") orelse raw.len];
        if (quotedAfter(line, "meshFile")) |m| {
            try checkMesh(c, path, name, line_no, m);
            if (mesh == null) mesh = m;
        }
        if (quotedAfter(line, "LEVEL_Load")) |lv| if (!levelExists(c, lv))
            try c.add(path, name, "line {d}: LEVEL_Load(\"{s}\"): no such level (dat/{s}/other.dat)", .{ line_no, lv, lv });
    }
    if (mesh) |m| try checkBindings(c, path, name, src, m);
}

/// The animation a `Register…Animation` line binds: `RegisterAnimation(stance,"slot","anim")`'s
/// second string, `RegisterIdleAnimation(stance,"anim",weight)`'s first.
fn boundAnim(line: []const u8) ?[]const u8 {
    const l = std.mem.trim(u8, line, " \t\r");
    const k: usize = if (std.mem.startsWith(u8, l, "RegisterAnimation(")) 3 else if (std.mem.startsWith(u8, l, "RegisterIdleAnimation(")) 1 else return null;
    var it = std.mem.splitScalar(u8, l, '"');
    for (0..k) |_| _ = it.next() orelse return null;
    const s = it.next() orelse return null;
    return if (it.peek() == null) null else s;
}

test boundAnim {
    try std.testing.expectEqualStrings("chodzenie", boundAnim("  RegisterAnimation(1,\"walk\",\"chodzenie\");").?);
    try std.testing.expectEqualStrings("drapanie", boundAnim("\tRegisterIdleAnimation(0,\"drapanie\",100);\r").?);
    try std.testing.expect(boundAnim("x = RegisterAnimation;") == null);
    try std.testing.expect(boundAnim("RegisterAnimation(0,\"walk\",\"w") == null);
}

/// The script's bindings name animations its model's `.ani` has (the one chunk 10 of the
/// `.msh` names): a missing one plays nothing, the actor freezes in the last one shown.
/// Only most of them missing is a problem: the game's own scripts miss some (shoggoth's
/// death, lamar 52 of 68), a model swapped under them misses nearly all.
fn checkBindings(c: *Check, path: []const u8, name: []const u8, src: []const u8, mesh: []const u8) !void {
    var buf: [archive.name_size]u8 = undefined;
    const me = c.common.find(std.fmt.bufPrint(&buf, "gfx_3d\\{s}.msh", .{mesh}) catch return) orelse return;
    var m = mesh_fmt.parse(c.a, try c.common.readAlloc(c.io, c.a, me)) catch return;
    defer m.deinit();
    const ae = c.common.find(std.fmt.bufPrint(&buf, "gfx_3d\\{s}", .{m.animations}) catch return);
    var list: ?anim.AnimList = if (ae) |e| anim.parseAni(c.a, try c.common.readAlloc(c.io, c.a, e)) catch null else null;
    defer if (list) |*l| l.deinit();
    var missing: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const an = boundAnim(raw[0 .. std.mem.indexOf(u8, raw, "//") orelse raw.len]) orelse continue;
        total += 1;
        if (list == null or list.?.find(an) == null) try missing.append(c.a, an);
    }
    if (missing.items.len * 5 <= total * 4) return;
    try c.add(path, name, "{d} of {d} animation bindings name nothing in {s}'s {s} ({s}…): a new model? Auto-bind on its page", .{ missing.items.len, total, mesh, m.animations, try std.mem.join(c.a, ", ", missing.items[0..@min(5, missing.items.len)]) });
}

/// The first `"…"` after `key` on `line` (`key = "x"`, `key("x")`).
fn quotedAfter(line: []const u8, key: []const u8) ?[]const u8 {
    const k = for (0..(line.len + 1) -| key.len) |i| {
        if (std.ascii.startsWithIgnoreCase(line[i..], key)) break i;
    } else return null;
    const q0 = std.mem.indexOfScalarPos(u8, line, k + key.len, '"') orelse return null;
    // Only `=`, `(` and spaces between the key and the quote.
    for (line[k + key.len .. q0]) |ch| if (ch != ' ' and ch != '\t' and ch != '=' and ch != '(') return null;
    const q1 = std.mem.indexOfScalarPos(u8, line, q0 + 1, '"') orelse return null;
    return line[q0 + 1 .. q1];
}

test quotedAfter {
    try std.testing.expectEqualStrings("fang", quotedAfter("  meshFile=\"fang\";", "meshFile").?);
    try std.testing.expectEqualStrings("01_port", quotedAfter("LEVEL_Load( \"01_port\");", "LEVEL_Load").?);
    try std.testing.expect(quotedAfter("meshFile = name;", "meshFile") == null);
    try std.testing.expect(quotedAfter("x = meshFile; y(\"a\")", "meshFile") == null);
}

fn levelExists(c: *Check, level: []const u8) bool {
    for (c.archives) |p| {
        const slash = std.mem.indexOfAny(u8, p, "/\\") orelse continue;
        if (std.ascii.eqlIgnoreCase(p[0..slash], level) and std.ascii.eqlIgnoreCase(p[slash + 1 ..], "other.dat")) return true;
    }
    return false;
}

/// A model named by `meshFile`: its `.msh` and the textures its parts name.
fn checkMesh(c: *Check, path: []const u8, name: []const u8, line_no: usize, mesh: []const u8) !void {
    if (mesh.len == 0) return;
    const key = try std.ascii.allocLowerString(c.a, mesh);
    if ((try c.meshes.getOrPut(c.a, key)).found_existing) return;
    var buf: [archive.name_size]u8 = undefined;
    const e = c.common.find(std.fmt.bufPrint(&buf, "gfx_3d\\{s}.msh", .{mesh}) catch return) orelse
        return c.add(path, name, "line {d}: meshFile \"{s}\": no gfx_3d\\{s}.msh in common/other.dat", .{ line_no, mesh, mesh });
    const bytes = try c.common.readAlloc(c.io, c.a, e);
    if (mesh_fmt.parse(c.a, bytes)) |parsed| {
        var m = parsed;
        defer m.deinit();
        // The port draws these; the exe overruns its vertex caches (mesh.checkLimits).
        // BadTriangle aside: game models have repeated indices (the exe draws less of them).
        const over = try partsOver(c.a, m);
        if (over.len > 0) {
            try c.add("common/other.dat", e.name, "port only: past the exe's 1024 vertices / 2048 triangles a part ({s})", .{over});
        } else mesh_fmt.checkLimits(m, .both) catch |err| if (err != error.BadTriangle) try c.add("common/other.dat", e.name, "port only: past the exe's model limits ({t})", .{err});
    } else |_| {}
    // Chunk 9: a part's texture (sizes and kinds as in formats/mesh.zig).
    var pos: usize = 0;
    while (pos + 12 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        if (size < 8 or pos + size > bytes.len) return c.add("common/other.dat", e.name, "broken chunk at {d}", .{pos});
        if (kind == 9 and size >= 12) {
            const raw = bytes[pos + 12 .. pos + size];
            const tex = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
            if (tex.len > 0 and c.common.find(std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{s}", .{tex}) catch "") == null)
                try c.add("common/other.dat", e.name, "texture {s} not found in gfx_3d\\textures", .{tex});
        }
        pos += size;
    }
}

/// "cialo 1650 vertices / 2432 triangles, …": the parts past the exe's 1024 / 2048 ("" none).
fn partsOver(a: Allocator, m: mesh_fmt.Mesh) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (m.parts) |p| if (p.vertices.len > 1024 or p.triangles.len > 2048)
        try out.print(a, "{s}{s} {d} vertices / {d} triangles", .{ if (out.items.len > 0) ", " else "", p.name, p.vertices.len, p.triangles.len });
    return out.items;
}
