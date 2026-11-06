//! glTF import: a `.glb` back as the game model's files (mapping: gltf.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const formats = @import("../formats.zig");
const mesh_fmt = formats.mesh;
const anim = formats.anim;
const tex3df = formats.tex3df;
const jpeg = formats.jpeg;
const Image = @import("../image.zig").Image;
const skin = @import("../actor.zig").skin;
const rotationXYZ = @import("../actor.zig").camera.rotationXYZ;
const models = @import("models.zig");
const gltf = @import("gltf.zig");
const exportGlb = @import("gltf_export.zig").exportGlb;
const fps = gltf.fps;
const frameTime = gltf.frameTime;
const Doc = gltf.Doc;
const Node = gltf.Node;
const Primitive = gltf.Primitive;
const Mat = gltf.Mat;
const identity = gltf.identity;
const mul = gltf.mul;
const inverse = gltf.inverse;
const trsMatrix = gltf.trsMatrix;
const toBfr = gltf.toBfr;
const dot4 = gltf.dot4;
const rowsFromQuat = gltf.rowsFromQuat;
const anglesXYZ = gltf.anglesXYZ;

/// Files of an imported model: `<name>.msh`, `.ani`, `.bfr` and `.3df` textures.
const Files = struct {
    arena: std.heap.ArenaAllocator,
    msh: []const u8 = "",
    ani: []const u8 = "",
    bfr: []const u8 = "",
    textures: []const struct { name: []const u8, data: []const u8 } = &.{},
    /// The height `importGlb` fitted (0: the extras' own).
    fitted: f32 = 0,

    pub fn deinit(self: *Files) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Gltf = struct {
    doc: Doc,
    bin: []const u8,
    parent: []?u32,

    fn nodes(g: Gltf) []const Node {
        return g.doc.nodes orelse &.{};
    }
};

fn parseGlb(a: Allocator, bytes: []const u8) !Gltf {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..4], "glTF") or std.mem.readInt(u32, bytes[4..8], .little) != 2) return error.NotGlb;
    const total = @min(bytes.len, std.mem.readInt(u32, bytes[8..12], .little));
    var pos: usize = 12;
    var json: ?[]const u8 = null;
    var bin: []const u8 = "";
    while (pos + 8 <= total) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        if (len > total - pos - 8) return error.BadGlb;
        const data = bytes[pos + 8 ..][0..len];
        if (std.mem.eql(u8, bytes[pos + 4 ..][0..4], "JSON")) json = data else if (std.mem.eql(u8, bytes[pos + 4 ..][0..4], "BIN\x00")) bin = data;
        pos += 8 + len;
    }
    const doc = try std.json.parseFromSliceLeaky(Doc, a, json orelse return error.BadGlb, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const g: Gltf = .{ .doc = doc, .bin = bin, .parent = try a.alloc(?u32, if (doc.nodes) |n| n.len else 0) };
    @memset(g.parent, null);
    for (g.nodes(), 0..) |n, i| for (n.children orelse &.{}) |c| {
        if (c >= g.parent.len) return error.BadGlb;
        g.parent[c] = @intCast(i);
    };
    return g;
}

/// Accessor `idx` as `n` floats per element (integers as their value, normalized ones /max).
fn readAccessor(g: Gltf, a: Allocator, idx: u32, comptime n: usize) ![][n]f32 {
    const accs = g.doc.accessors orelse return error.BadGlb;
    if (idx >= accs.len) return error.BadGlb;
    const acc = accs[idx];
    if (acc.sparse != null) return error.SparseAccessor;
    const out = try a.alloc([n]f32, acc.count);
    const vi = acc.bufferView orelse {
        @memset(out, @splat(0));
        return out;
    };
    const views = g.doc.bufferViews orelse return error.BadGlb;
    if (vi >= views.len) return error.BadGlb;
    const v = views[vi];
    const bufs = g.doc.buffers orelse return error.BadGlb;
    if (v.buffer != 0 or bufs.len == 0 or bufs[0].uri != null) return error.ExternalBuffer;
    const csize: usize = switch (acc.componentType) {
        5120, 5121 => 1,
        5122, 5123 => 2,
        5125, 5126 => 4,
        else => return error.BadGlb,
    };
    // Components the accessor has (a VEC3 read as 4 leaves the 4th 0).
    const comps: usize = if (std.mem.eql(u8, acc.type, "SCALAR")) 1 else if (std.mem.eql(u8, acc.type, "MAT4")) 16 else if (acc.type.len == 4 and std.mem.startsWith(u8, acc.type, "VEC")) acc.type[3] - '0' else return error.BadGlb;
    const stride = v.byteStride orelse csize * comps;
    const norm = acc.normalized orelse false;
    if (v.byteOffset + v.byteLength > g.bin.len) return error.BadGlb;
    const data = g.bin[v.byteOffset..][0..v.byteLength];
    for (out, 0..) |*o, i| for (o, 0..) |*x, k| {
        if (k >= comps) {
            x.* = 0;
            continue;
        }
        const off = acc.byteOffset + i * stride + k * csize;
        if (off + csize > data.len) return error.BadGlb;
        var p: [4]u8 = @splat(0);
        @memcpy(p[0..csize], data[off..][0..csize]);
        x.* = switch (acc.componentType) {
            5126 => @bitCast(std.mem.readInt(u32, p[0..4], .little)),
            5125 => @floatFromInt(std.mem.readInt(u32, p[0..4], .little)),
            5123 => @as(f32, @floatFromInt(std.mem.readInt(u16, p[0..2], .little))) / @as(f32, if (norm) 65535 else 1),
            5122 => @max(-1, @as(f32, @floatFromInt(std.mem.readInt(i16, p[0..2], .little))) / @as(f32, if (norm) 32767 else 1)),
            5121 => @as(f32, @floatFromInt(p[0])) / @as(f32, if (norm) 255 else 1),
            else => @max(-1, @as(f32, @floatFromInt(@as(i8, @bitCast(p[0])))) / @as(f32, if (norm) 127 else 1)),
        };
    };
    return out;
}

/// The skin of the mesh nodes, its joints mapped to game bones (`boneNN` names when all
/// joints have them, else skin order; joint `rest` is the bind pose).
const Skeleton = struct {
    joints: []const u32 = &.{},
    /// Game bone of each skin joint (null: `rest`).
    bone: []?u32 = &.{},
    ibm: []Mat = &.{},
    bones: usize = 0,

    fn of(g: Gltf, a: Allocator) !Skeleton {
        var si: ?u32 = null;
        for (g.nodes()) |n| if (n.mesh != null) if (n.skin) |s| {
            if (si != null and si.? != s) return error.SeveralSkins;
            si = s;
        };
        const skins = g.doc.skins orelse return .{};
        const s = skins[si orelse return .{}];
        var sk: Skeleton = .{ .joints = s.joints, .bone = try a.alloc(?u32, s.joints.len), .ibm = try a.alloc(Mat, s.joints.len) };
        @memset(sk.ibm, identity);
        if (s.inverseBindMatrices) |ia| for (try readAccessor(g, a, ia, 16), sk.ibm) |m, *d| {
            for (d, m) |*x, y| x.* = y;
        };
        var named = true;
        for (s.joints, sk.bone) |j, *b| {
            if (j >= g.nodes().len) return error.BadGlb;
            const nm = g.nodes()[j].name orelse "";
            b.* = if (std.mem.eql(u8, nm, "rest")) null else blk: {
                sk.bones += 1;
                const num = if (std.mem.startsWith(u8, nm, "bone")) std.fmt.parseInt(u32, nm[4..], 10) catch null else null;
                named = named and num != null;
                break :blk num orelse 0;
            };
        }
        // boneNN must cover 0..bones-1 once each, else skin order.
        var seen = try a.alloc(bool, sk.bones);
        @memset(seen, false);
        for (sk.bone) |b| if (b) |v| {
            if (v >= sk.bones or seen[v]) named = false else seen[v] = true;
        };
        if (!named) {
            var k: u32 = 0;
            for (sk.bone) |*b| if (b.*) |_| {
                b.* = k;
                k += 1;
            };
        }
        return sk;
    }

    fn jointOf(sk: Skeleton, node: u32) ?usize {
        return std.mem.indexOfScalar(u32, sk.joints, node);
    }
};

/// World size of a hero's bind pose (cpt 24 × 27.7, kozov 24 × 27.4, lamar 25 × 26.8):
/// what a model without a height is fitted to when nothing better is known.
pub const hero_size = 660;

/// The largest side of the bind pose's box, in mesh units (world: × `height`).
pub fn bindSize(m: mesh_fmt.Mesh) f32 {
    var lo: [3]f32 = @splat(std.math.inf(f32));
    var hi: [3]f32 = @splat(-std.math.inf(f32));
    for (m.parts) |p| for (p.vertices) |v| for (0..3) |k| {
        lo[k] = @min(lo[k], v.pos[k]);
        hi[k] = @max(hi[k], v.pos[k]);
    };
    return @max(0, @max(hi[0] - lo[0], @max(hi[1] - lo[1], hi[2] - lo[2])));
}

/// Game model from a `.glb` (chunk 10 names `<name>.ani`). Checked against `target`'s
/// limits (mesh.checkLimits: `.port` skips the exe's caps), textures as tex3df.encode. Without the extras' height (another tool's model) the
/// height makes the bind pose's largest side `fit` world units (`Files.fitted`): the
/// height multiplies every vertex (0x429311), so 1 leaves a model too small to see.
pub fn importGlb(gpa: Allocator, bytes: []const u8, name: []const u8, fit: f32, target: mesh_fmt.Target) !Files {
    var files: Files = .{ .arena = .init(gpa) };
    errdefer files.arena.deinit();
    const a = files.arena.allocator();
    const g = try parseGlb(a, bytes);
    const sk = try Skeleton.of(g, a);

    var m: mesh_fmt.Mesh = .{ .arena = undefined, .animations = try std.fmt.allocPrint(a, "{s}.ani", .{name}) };
    for (g.nodes()) |n| if (n.extras) |e| if (e.gorky) |info| {
        m.name = info.name;
        m.center = info.center;
        m.height = info.height;
        m.has_rotation = info.rotation != null;
        m.rotation = info.rotation orelse .{ 0, 0, 0 };
        // The exported spelling (thiefA.ani) when it names the same file.
        if (std.ascii.eqlIgnoreCase(info.animations, m.animations)) m.animations = info.animations;
        break;
    };

    // Joints and attach points from the bind pose (inverse bind matrices).
    m.joints = try a.alloc([3]f32, sk.bones);
    for (sk.bone, sk.ibm) |bone, ibm| if (bone) |b| {
        const bind = inverse(ibm);
        m.joints[b] = .{ @floatCast(bind[12]), @floatCast(bind[13]), @floatCast(bind[14]) };
        // A pure translation (as exported) negates exactly, −0 included.
        if (std.meta.eql(ibm[0..12].*, identity[0..12].*)) m.joints[b] = .{ @floatCast(-ibm[12]), @floatCast(-ibm[13]), @floatCast(-ibm[14]) };
    };
    // Attach points, in node order: non-joint, non-mesh children of a bone, or of the
    // root (extras `gorky`) for points without a bone (ponton).
    var holds: std.ArrayList(mesh_fmt.HoldMode) = .empty;
    for (g.nodes(), 0..) |cn, ci| {
        const par = g.parent[ci] orelse continue;
        if (sk.jointOf(@intCast(ci)) != null or cn.mesh != null) continue;
        const pn = g.nodes()[par];
        if (sk.jointOf(par)) |k| {
            const b = sk.bone[k] orelse continue;
            try holds.append(a, .{ .name = cn.name orelse "", .params = attachParams(cn, inverse(sk.ibm[k])), .bone = b });
        } else if (pn.extras != null and pn.extras.?.gorky != null) {
            try holds.append(a, .{ .name = cn.name orelse "", .params = attachParams(cn, restWorld(g, par)), .bone = mesh_fmt.no_bone });
        }
    }
    m.hold_modes = holds.items;

    var parts: std.ArrayList(mesh_fmt.Part) = .empty;
    var tex_names: std.ArrayList([]const u8) = .empty;
    var tex_files: std.ArrayList(@typeInfo(@FieldType(Files, "textures")).pointer.child) = .empty;
    for (g.nodes(), 0..) |n, ni| {
        const mi = n.mesh orelse continue;
        const meshes = g.doc.meshes orelse return error.BadGlb;
        if (mi >= meshes.len) return error.BadGlb;
        // A static mesh keeps its place; a skinned one is in bind space already.
        const world = if (n.skin == null) restWorld(g, @intCast(ni)) else identity;
        for (meshes[mi].primitives, 0..) |prim, k| {
            if ((prim.mode orelse 4) != 4) return error.NotTriangles;
            var p = try importPart(g, a, sk, prim, world);
            const base = n.name orelse meshes[mi].name orelse "part";
            p.name = if (meshes[mi].primitives.len > 1) try std.fmt.allocPrint(a, "{s}{d}", .{ base, k }) else base;
            if (prim.material) |mat| p.texture = try importTexture(g, a, mat, name, &tex_names, &tex_files, target);
            try parts.append(a, p);
        }
    }
    m.parts = parts.items;
    if (parts.items.len > 0) m.texture = parts.items[parts.items.len - 1].texture;
    if (m.height == 0) {
        const size = bindSize(m);
        const h = if (size > 0) fit / size else 1;
        // Whole numbers as the game's (24, 37) unless that loses the size.
        m.height = if (h >= 1) @round(h) else h;
        files.fitted = m.height;
    }

    var anims: std.ArrayList(anim.Animation) = .empty;
    var mats: std.ArrayList([12]f32) = .empty;
    try importAnimations(g, a, sk, sk.bones, &anims, &mats, true);
    const frames = try finishFrames(a, m, mats.items);
    try mesh_fmt.checkLimits(m, target);
    try anim.checkLimits(anims.items, frames, m.joints.len);
    files.msh = try mesh_fmt.encode(a, m);
    files.ani = try anim.writeAni(a, anims.items);
    files.bfr = try anim.writeBfr(a, frames);
    files.textures = tex_files.items;
    return files;
}

/// `ani`/`bfr` of an existing model with the animations of a `.glb` of the same skeleton
/// added (an animation of the same name is replaced); the frames no animation uses are
/// dropped (`compactFrames`).
pub fn importAnimationsInto(gpa: Allocator, bytes: []const u8, m: mesh_fmt.Mesh, list: []const anim.Animation, frames: anim.BoneFrames) !Files {
    var files: Files = .{ .arena = .init(gpa) };
    errdefer files.arena.deinit();
    const a = files.arena.allocator();
    const g = try parseGlb(a, bytes);
    const sk = try Skeleton.of(g, a);
    if (sk.bones != m.joints.len or frames.bones != m.joints.len) return error.SkeletonMismatch;
    var anims: std.ArrayList(anim.Animation) = .empty;
    try anims.appendSlice(a, list);
    var mats: std.ArrayList([12]f32) = .empty;
    try mats.appendSlice(a, frames.matrices);
    var new: std.ArrayList(anim.Animation) = .empty;
    try importAnimations(g, a, sk, sk.bones, &new, &mats, false);
    for (new.items) |an| {
        // Braced: the `else` is the loop's (no animation of that name), not the `if`'s.
        for (anims.items) |*old| {
            if (std.ascii.eqlIgnoreCase(old.name, an.name)) {
                // A .glb from another tool has no sounds: the old ones stay, from the
                // new first frame and within it.
                const keep = if (an.sounds.len == 0) try a.dupe(anim.SoundCue, old.sounds) else an.sounds;
                if (an.sounds.len == 0) for (keep) |*s| {
                    s.frame = an.first + @min(s.frame -| old.first, an.last - an.first);
                };
                old.* = an;
                old.sounds = keep;
                break;
            }
        } else try anims.append(a, an);
    }
    const out = try finishFrames(a, m, try compactFrames(a, m.joints.len, anims.items, mats.items, frames.frames));
    try anim.checkLimits(anims.items, out, m.joints.len);
    files.ani = try anim.writeAni(a, anims.items);
    files.bfr = try anim.writeBfr(a, out);
    return files;
}

/// `mats` (`bones` per frame) with only frame 0 and the frames of `anims` kept, their
/// ranges and sound cues renumbered: the exe reads frames only through `.ani` ranges and
/// starts a model on frame 0 (player 0x44f910, stride 0x44c012). Padded with rest frames
/// to at least `min_frames` (the old count), so the old `.ani` still fits the new `.bfr`
/// while the editor swaps them one at a time (and back on undo).
fn compactFrames(a: Allocator, bones: usize, anims: []anim.Animation, mats: []const [12]f32, min_frames: u32) ![]const [12]f32 {
    if (bones == 0) return mats;
    const n = mats.len / bones;
    const keep = try a.alloc(bool, n);
    @memset(keep, false);
    if (n > 0) keep[0] = true;
    for (anims) |an| {
        if (an.first > an.last or an.last >= n) return error.AnimOutOfRange;
        @memset(keep[an.first .. an.last + 1], true);
    }
    const to = try a.alloc(u32, n);
    var k: u32 = 0;
    for (keep, to) |kp, *t| {
        t.* = k;
        if (kp) k += 1;
    }
    const out = try a.alloc([12]f32, @max(k, min_frames) * bones);
    @memset(out, rest_matrix);
    for (keep, to, 0..) |kp, t, f| if (kp) @memcpy(out[t * bones ..][0..bones], mats[f * bones ..][0..bones]);
    for (anims) |*an| {
        const first = to[an.first];
        const sounds = try a.dupe(anim.SoundCue, an.sounds);
        for (sounds) |*s| s.frame = s.frame -% an.first +% first;
        an.* = .{ .name = an.name, .first = first, .last = to[an.last], .speed = an.speed, .sounds = sounds };
    }
    return out;
}

/// Attach point params (offset, angles) of node `n` under a bone whose bind matrix is
/// `bind`: offset = bind 3×3 · translation, rotation = bind 3×3 · node rotation. The
/// extras' exact numbers when they still give the same.
fn attachParams(n: Node, bind: Mat) [6]f32 {
    const t = n.translation orelse .{ 0, 0, 0 };
    const q = n.rotation orelse .{ 0, 0, 0, 1 };
    const lr = rowsFromQuat(q);
    var rows: [9]f64 = undefined;
    var p: [6]f32 = undefined;
    for (0..3) |r| {
        p[r] = @floatCast(bind[r] * t[0] + bind[4 + r] * t[1] + bind[8 + r] * t[2]);
        for (0..3) |c| rows[r * 3 + c] = bind[r] * lr[c] + bind[4 + r] * lr[3 + c] + bind[8 + r] * lr[6 + c];
    }
    p[3..6].* = anglesXYZ(rows);
    const e = (n.extras orelse return p).gorky_attach orelse return p;
    const er = rotationXYZ(e[3..6].*);
    for (0..3) |k| if (@abs(e[k] - p[k]) > 1e-4) return p;
    for (0..9) |k| if (@abs(er[k] - rows[k]) > 1e-4) return p;
    return e;
}

/// World matrix of node `ni` in its rest pose.
fn restWorld(g: Gltf, ni: u32) Mat {
    var w = identity;
    var cur: ?u32 = ni;
    while (cur) |c| : (cur = g.parent[c]) w = mul(restLocal(g.nodes()[c]), w);
    return w;
}

fn restLocal(n: Node) Mat {
    if (n.matrix) |mm| {
        var o: Mat = undefined;
        for (&o, mm) |*x, y| x.* = y;
        return o;
    }
    return trsMatrix(n.translation orelse .{ 0, 0, 0 }, n.rotation orelse .{ 0, 0, 0, 1 }, n.scale orelse .{ 1, 1, 1 });
}

fn importPart(g: Gltf, a: Allocator, sk: Skeleton, prim: Primitive, world: Mat) !mesh_fmt.Part {
    const pos = try readAccessor(g, a, prim.attributes.POSITION orelse return error.NoPositions, 3);
    const uv = if (prim.attributes.TEXCOORD_0) |i| try readAccessor(g, a, i, 2) else null;
    const ids = if (prim.attributes._VERTEX_ID) |i| try readAccessor(g, a, i, 1) else null;
    var p: mesh_fmt.Part = .{ .name = "", .vertices = try a.alloc(mesh_fmt.Vertex, pos.len), .ranges = try a.alloc([2]u32, pos.len), .influences = &.{}, .triangles = &.{} };
    for (p.vertices, pos, 0..) |*v, ps, i| {
        var q = ps;
        if (!std.meta.eql(world, identity)) for (0..3) |r| {
            q[r] = @floatCast(world[r] * ps[0] + world[4 + r] * ps[1] + world[8 + r] * ps[2] + world[12 + r]);
        };
        // UVs stay as given: the exe clamps them to 0..1 on load (0x44cb0c).
        const t = if (uv) |u| u[i] else [2]f32{ 0, 0 };
        v.* = .{ .pos = q, .uv = t, .id = if (ids) |d| @intFromFloat(std.math.clamp(d[i][0], 0, 0xffff)) else @truncate(i) };
    }
    // Influences: game bones only, the rest joint's share is the bind pose.
    var infl: std.ArrayList(mesh_fmt.Influence) = .empty;
    const at = prim.attributes;
    const sets = [2][3]?u32{ .{ at.JOINTS_0, at.WEIGHTS_0, at._PERCENTS_0 }, .{ at.JOINTS_1, at.WEIGHTS_1, at._PERCENTS_1 } };
    // Joints, weights, file percents (weights ·100 when missing).
    var jw: [2]?[3][][4]f32 = .{ null, null };
    for (sets, &jw) |s, *d| if (s[0] != null and s[1] != null and sk.joints.len > 0) {
        const w = try readAccessor(g, a, s[1].?, 4);
        d.* = .{ try readAccessor(g, a, s[0].?, 4), w, if (s[2]) |pi| try readAccessor(g, a, pi, 4) else w };
        for (d.*.?) |x| if (x.len != pos.len) return error.BadGlb;
    };
    for (p.ranges, 0..) |*rg, i| {
        const start = infl.items.len;
        var total: f32 = 0;
        for (jw) |set| if (set) |s| for (s[0][i], s[1][i], s[2][i]) |jf, w, pc| {
            if (w <= 0) continue;
            const j: usize = @intFromFloat(jf);
            if (j >= sk.joints.len) return error.BadGlb;
            total += w;
            if (sk.bone[j]) |b| try infl.append(a, .{ .bone = b, .weight = w, .percent = pc });
        };
        // Weights above 1 would push the vertex past the pose (the exe adds 1 − Σ).
        for (infl.items[start..]) |*inf| {
            if (total > 1.0001) inf.weight /= total;
            if (inf.percent * 0.01 != inf.weight) inf.percent = percentOf(inf.weight);
            inf.weight = inf.percent * 0.01;
        }
        rg.* = .{ @intCast(start), @intCast(infl.items.len) };
        // A vertex at the place of an earlier one with the same influences shares its
        // range, as in the game's files (all but 8 of 7600 such vertices).
        for (p.ranges[0..i], p.vertices[0..i]) |prev, pv| if (std.meta.eql(pv.pos, p.vertices[i].pos) and
            std.mem.eql(u8, std.mem.sliceAsBytes(infl.items[prev[0]..prev[1]]), std.mem.sliceAsBytes(infl.items[start..])))
        {
            infl.shrinkRetainingCapacity(start);
            rg.* = prev;
            break;
        };
    }
    p.influences = infl.items;
    const idx = if (prim.indices) |i| try readAccessor(g, a, i, 1) else null;
    const count = if (idx) |x| x.len else pos.len;
    var tris: std.ArrayList([3]u32) = .empty;
    for (0..count / 3) |k| {
        var t: [3]u32 = undefined;
        for (&t, 0..) |*v, c| {
            const vi: usize = if (idx) |x| @intFromFloat(x[k * 3 + c][0]) else k * 3 + c;
            if (vi >= pos.len) return error.BadGlb;
            v.* = @intCast(vi);
        }
        // A triangle with a repeated vertex cuts the part short in the exe (0x4c6f55).
        if (t[0] != t[1] and t[1] != t[2] and t[0] != t[2]) try tris.append(a, t);
    }
    p.triangles = tris.items;
    // A mirroring node transform turns the faces inside out.
    const det = world[0] * (world[5] * world[10] - world[9] * world[6]) - world[4] * (world[1] * world[10] - world[9] * world[2]) + world[8] * (world[1] * world[6] - world[5] * world[2]);
    if (det < 0) for (p.triangles) |*t| std.mem.swap(u32, &t[1], &t[2]);
    return p;
}

/// The file percent whose ·0.01 is `w` (the exe multiplies by 0.01, 0x44cd09), so an
/// exported weight comes back as the same bits.
fn percentOf(w: f32) f32 {
    var p: f32 = w * 100;
    for (0..4) |_| {
        const back: f32 = p * 0.01;
        if (back == w) break;
        p = if (back < w) std.math.nextAfter(f32, p, std.math.inf(f32)) else std.math.nextAfter(f32, p, -std.math.inf(f32));
    }
    return p;
}

/// Texture of material `mat` as a `.3df` (tex3df.encode for `target`, resampled to its sizes):
/// the image's name when it is a `.3df` name, else `<model>_<n>.3df`.
fn importTexture(g: Gltf, a: Allocator, mat: u32, model: []const u8, names: *std.ArrayList([]const u8), files: anytype, target: mesh_fmt.Target) ![]const u8 {
    const mats = g.doc.materials orelse return "";
    if (mat >= mats.len) return error.BadGlb;
    const ti = ((mats[mat].pbrMetallicRoughness orelse return "").baseColorTexture orelse return "").index;
    const texs = g.doc.textures orelse return error.BadGlb;
    if (ti >= texs.len) return error.BadGlb;
    const si = texs[ti].source orelse return "";
    const imgs = g.doc.images orelse return error.BadGlb;
    if (si >= imgs.len) return error.BadGlb;
    const im = imgs[si];
    const nm = im.name orelse "";
    const tex_name = if (std.ascii.endsWithIgnoreCase(nm, ".3df")) nm else try std.fmt.allocPrint(a, "{s}_{d}.3df", .{ model, si });
    for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, tex_name)) return n;
    const views = g.doc.bufferViews orelse return error.BadGlb;
    const vi = im.bufferView orelse return error.ExternalImage;
    if (vi >= views.len or views[vi].byteOffset + views[vi].byteLength > g.bin.len) return error.BadGlb;
    var img = try jpeg.decode(a, g.bin[views[vi].byteOffset..][0..views[vi].byteLength]);
    // Power-of-two sides up to the target's most (exe 256, port 4096), 8:1: resampled to the nearest.
    const fit = tex3df.fitSize(img.width, img.height, target);
    if (fit[0] != img.width or fit[1] != img.height) img = try tex3df.resize(a, img, fit[0], fit[1]);
    try names.append(a, tex_name);
    try files.append(a, .{ .name = tex_name, .data = try tex3df.encode(a, img, target) });
    return tex_name;
}

/// A bone in the bind pose (frames no animation covers).
const rest_matrix = [12]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };

/// Input sampler of an animation channel.
const Sampler = struct {
    times: [][1]f32,
    values: [][4]f32,
    step: bool,
    /// CUBICSPLINE: (in-tangent, value, out-tangent) per key.
    cubic: bool,

    fn at(s: Sampler, t: f32) [4]f32 {
        const n = s.times.len;
        const k: usize = if (s.cubic) 3 else 1;
        const off: usize = if (s.cubic) 1 else 0;
        if (n == 0) return .{ 0, 0, 0, 1 };
        if (t <= s.times[0][0]) return s.values[off];
        var i: usize = 0;
        while (i + 1 < n and s.times[i + 1][0] <= t) i += 1;
        if (i + 1 >= n or s.times[i][0] == t or s.step) return s.values[i * k + off];
        // shortcut: CUBICSPLINE is read as LINEAR between its key values (tangents
        // ignored); exact enough for baked per-frame keys, sample properly if needed.
        const x0 = s.values[i * k + off];
        var x1 = s.values[(i + 1) * k + off];
        const f = (t - s.times[i][0]) / (s.times[i + 1][0] - s.times[i][0]);
        if (dot4(x0, x1) < 0) x1 = .{ -x1[0], -x1[1], -x1[2], -x1[3] };
        var o: [4]f32 = undefined;
        for (&o, x0, x1) |*d, p, q| d.* = p + (q - p) * f;
        return o;
    }
};

/// The animations of `g` as `.ani` entries and frames appended to `mats` (`bones` per
/// frame). `keep_place`: frames go back to the extras' first…last when free (or holding
/// the same matrices), as they were in the exported model.
fn importAnimations(g: Gltf, a: Allocator, sk: Skeleton, bones: usize, anims: *std.ArrayList(anim.Animation), mats: *std.ArrayList([12]f32), keep_place: bool) !void {
    const gl_anims = g.doc.animations orelse return;
    if (bones == 0) return;
    const nn = g.nodes().len;
    var placed: std.ArrayList(bool) = .empty;
    try placed.appendNTimes(a, false, mats.items.len / bones);
    for (gl_anims, 0..) |ga, ai| {
        // Channels by node and path (translation, rotation, scale).
        const ch = try a.alloc([3]?Sampler, nn);
        @memset(ch, .{ null, null, null });
        var dur: f32 = 0;
        for (ga.channels) |c| {
            const node = c.target.node orelse continue;
            const path: usize = if (std.mem.eql(u8, c.target.path, "translation")) 0 else if (std.mem.eql(u8, c.target.path, "rotation")) 1 else if (std.mem.eql(u8, c.target.path, "scale")) 2 else continue;
            if (node >= nn or c.sampler >= ga.samplers.len) return error.BadGlb;
            const s = ga.samplers[c.sampler];
            const interp = s.interpolation orelse "LINEAR";
            const smp: Sampler = .{ .times = try readAccessor(g, a, s.input, 1), .values = try readAccessor(g, a, s.output, 4), .step = std.mem.eql(u8, interp, "STEP"), .cubic = std.mem.eql(u8, interp, "CUBICSPLINE") };
            if (smp.values.len < smp.times.len * @as(usize, if (smp.cubic) 3 else 1)) return error.BadGlb;
            if (smp.times.len > 0) dur = @max(dur, smp.times[smp.times.len - 1][0]);
            ch[node][path] = smp;
        }
        const count: u32 = @as(u32, @intFromFloat(@round(dur * fps))) + 1;
        const start = mats.items.len;
        const world = try a.alloc(Mat, nn);
        const done = try a.alloc(bool, nn);
        for (0..count) |k| {
            @memset(done, false);
            const row = try mats.addManyAsSlice(a, bones);
            @memset(row, rest_matrix);
            for (sk.joints, sk.bone, sk.ibm) |jn, bone, ibm| if (bone) |b| {
                row[b] = toBfr(mul(worldAt(g, ch, frameTime(k), jn, world, done), ibm));
            };
        }
        // Back to the exported place when it is free or already holds these frames.
        const ex = ga.extras;
        var first: u32 = @intCast(start / bones);
        if (keep_place) if (ex) |e| if (e.first) |f| if (e.last == null or e.last.? == f + count - 1) {
            const new = mats.items[start..];
            var fits = true;
            for (0..count) |k| {
                const slot = f + k;
                if (slot < placed.items.len and placed.items[slot] and !std.mem.eql(u8, std.mem.sliceAsBytes(mats.items[slot * bones ..][0..bones]), std.mem.sliceAsBytes(new[k * bones ..][0..bones]))) fits = false;
            }
            if (fits) {
                const moved = try a.dupe([12]f32, new);
                mats.shrinkRetainingCapacity(start);
                if (mats.items.len < (f + count) * bones) {
                    const old_len = mats.items.len;
                    try mats.resize(a, (f + count) * bones);
                    @memset(mats.items[old_len..], rest_matrix);
                }
                @memcpy(mats.items[f * bones ..][0 .. count * bones], moved);
                first = f;
            }
        };
        if (placed.items.len < mats.items.len / bones) try placed.appendNTimes(a, false, mats.items.len / bones - placed.items.len);
        @memset(placed.items[first..][0..count], true);
        const sounds = try a.dupe(anim.SoundCue, if (ex) |e| e.sounds orelse &.{} else &.{});
        const was: u32 = if (ex) |e| e.first orelse first else first;
        for (sounds) |*s| s.frame = s.frame -% was +% first;
        try anims.append(a, .{
            .name = ga.name orelse try std.fmt.allocPrint(a, "anim{d}", .{ai}),
            .first = first,
            .last = first + count - 1,
            .speed = if (ex) |e| e.speed orelse 1 else 1,
            .sounds = sounds,
        });
    }
}

/// World matrix of node `ni` at time `t` (memoized in `world`/`done`).
fn worldAt(g: Gltf, ch: []const [3]?Sampler, t: f32, ni: u32, world: []Mat, done: []bool) Mat {
    if (done[ni]) return world[ni];
    const n = g.nodes()[ni];
    var local = restLocal(n);
    if (ch[ni][0] != null or ch[ni][1] != null or ch[ni][2] != null) {
        const tr = if (ch[ni][0]) |s| s.at(t)[0..3].* else n.translation orelse .{ 0, 0, 0 };
        const rot = if (ch[ni][1]) |s| s.at(t) else n.rotation orelse .{ 0, 0, 0, 1 };
        const sc = if (ch[ni][2]) |s| s.at(t)[0..3].* else n.scale orelse .{ 1, 1, 1 };
        local = trsMatrix(tr, rot, sc);
    }
    world[ni] = if (g.parent[ni]) |p| mul(worldAt(g, ch, t, p, world, done), local) else local;
    done[ni] = true;
    return world[ni];
}

/// Bone frames from matrices (at least one frame: the bind pose), with each frame's
/// skinned bounds.
fn finishFrames(a: Allocator, m: mesh_fmt.Mesh, mats: []const [12]f32) !anim.BoneFrames {
    const bones = m.joints.len;
    var all = mats;
    var frames: u32 = if (bones == 0) 1 else @intCast(mats.len / bones);
    if (frames == 0) {
        frames = 1;
        const id = try a.alloc([12]f32, bones);
        @memset(id, rest_matrix);
        all = id;
    }
    const bf: anim.BoneFrames = .{ .frames = frames, .bones = @intCast(bones), .matrices = @constCast(all), .extra = try a.alloc([6]f32, frames) };
    const cm = try models.meshOf(a, m);
    const cf = models.framesOf(bf);
    for (bf.extra, 0..) |*e, f| {
        var lo: [3]f32 = @splat(std.math.inf(f32));
        var hi: [3]f32 = @splat(-std.math.inf(f32));
        for (try skin.pose(a, cm, cf, @intCast(f), .row)) |part| for (part) |v| for (0..3) |k| {
            lo[k] = @min(lo[k], v[k]);
            hi[k] = @max(hi[k], v[k]);
        };
        if (lo[0] > hi[0]) {
            lo = @splat(0);
            hi = @splat(0);
        }
        e.* = lo ++ hi;
    }
    return bf;
}

test "export then import gives the model back" {
    const gpa = std.testing.allocator;
    var verts = [_]mesh_fmt.Vertex{ .{ .pos = .{ 0, 0, 0 }, .uv = .{ 0, 0 } }, .{ .pos = .{ 1, 0, 0 }, .uv = .{ 1, 0 }, .id = 1 }, .{ .pos = .{ 0, 1, -0.0 }, .uv = .{ 0, 1 }, .id = 2 } };
    var ranges = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 2 } };
    var infl = [_]mesh_fmt.Influence{ .{ .bone = 0, .weight = 1, .percent = 100 }, .{ .bone = 0, .weight = 0.6, .percent = 60 } };
    var tris = [_][3]u32{.{ 0, 1, 2 }};
    var parts = [_]mesh_fmt.Part{.{ .name = "body", .vertices = &verts, .ranges = &ranges, .influences = &infl, .triangles = &tris, .texture = "t.3df" }};
    var joints = [_][3]f32{.{ 0, 5, 0 }};
    var holds = [_]mesh_fmt.HoldMode{.{ .name = "one_hand", .params = .{ 1, 2, 3, 0.1, -0.2, 0.3 }, .bone = 0 }};
    const m: mesh_fmt.Mesh = .{ .arena = undefined, .center = .{ 0, 9.4, 0 }, .has_rotation = true, .height = 24, .joints = &joints, .texture = "t.3df", .animations = "x.ani", .hold_modes = &holds, .parts = &parts };
    var sounds = [_]anim.SoundCue{.{ .name = "a.wav", .frame = 2, .volume = 100 }};
    const anims = [_]anim.Animation{.{ .name = "turn", .first = 1, .last = 2, .speed = 1, .sounds = &sounds }};
    // Frame 0 rest, 1 moved, 2 turned 90° around Y.
    var mats = [_][12]f32{ rest_matrix, .{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 0, 0 }, .{ 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 0, 0 } };
    var extra: [3][6]f32 = undefined;
    const frames: anim.BoneFrames = .{ .frames = 3, .bones = 1, .matrices = &mats, .extra = &extra };
    var img = try Image.init(gpa, 2, 2);
    defer img.deinit(gpa);
    const glb_bytes = try exportGlb(gpa, "x", m, &anims, frames, &.{img});
    defer gpa.free(glb_bytes);

    var files = try importGlb(gpa, glb_bytes, "x", hero_size, .both);
    defer files.deinit();
    const want = try mesh_fmt.encode(gpa, m);
    defer gpa.free(want);
    try std.testing.expectEqualSlices(u8, want, files.msh);
    const want_ani = try anim.writeAni(gpa, &anims);
    defer gpa.free(want_ani);
    try std.testing.expectEqualSlices(u8, want_ani, files.ani);
    try std.testing.expectEqualStrings("t.3df", files.textures[0].name);
    var back = try anim.parseBfr(gpa, files.bfr, 1);
    defer back.deinit(gpa);
    try std.testing.expectEqual(3, back.frames);
    for (mats, back.matrices) |x, y| for (x, y) |p, q| try std.testing.expectApproxEqAbs(p, q, 1e-5);
    // Frame 1 bounds (bone +2 x): the 60% vertex moves 1.2, its 40% stays on the bind pose.
    try std.testing.expectApproxEqAbs(@as(f32, 2.2), back.extra[1][3], 1e-5);

    // Its animations into a model having "turn" and "idle": "turn" replaced, none added.
    const two = [_]anim.Animation{ .{ .name = "idle", .first = 0, .last = 0, .speed = 1, .sounds = &.{} }, anims[0] };
    var into = try importAnimationsInto(gpa, glb_bytes, m, &two, frames);
    defer into.deinit();
    var list = try anim.parseAni(gpa, into.ani);
    defer list.deinit();
    try std.testing.expectEqual(2, list.items.len);
    // The old "turn" frames dropped: again 3 frames, "turn" on 1…2 with its sound on 2.
    var got = try anim.parseBfr(gpa, into.bfr, 1);
    defer got.deinit(gpa);
    try std.testing.expectEqual(3, got.frames);
    var again = try importAnimationsInto(gpa, glb_bytes, m, list.items, got);
    defer again.deinit();
    try std.testing.expectEqual(into.bfr.len, again.bfr.len);
    var list2 = try anim.parseAni(gpa, again.ani);
    defer list2.deinit();
    const t = list2.find("turn").?;
    try std.testing.expectEqual(1, t.first);
    try std.testing.expectEqual(2, t.last);
    try std.testing.expectEqual(2, t.sounds[0].frame);
    for (mats[1..], got.matrices[1..]) |x, y| for (x, y) |p, q| try std.testing.expectApproxEqAbs(p, q, 1e-5);

    // A "turn" without sounds (another tool's) keeps the old one's sound.
    const silent = [_]anim.Animation{.{ .name = "turn", .first = 1, .last = 2, .speed = 1, .sounds = &.{} }};
    const quiet = try exportGlb(gpa, "x", m, &silent, frames, &.{img});
    defer gpa.free(quiet);
    var kept = try importAnimationsInto(gpa, quiet, m, &two, frames);
    defer kept.deinit();
    var list3 = try anim.parseAni(gpa, kept.ani);
    defer list3.deinit();
    const k = list3.find("turn").?;
    try std.testing.expectEqual(1, k.sounds.len);
    try std.testing.expectEqual(k.first + 1, k.sounds[0].frame);
}

test anglesXYZ {
    const a = [3]f32{ 0.3, -1.1, 2.5 };
    var r: [9]f64 = undefined;
    for (&r, rotationXYZ(a)) |*d, v| d.* = v;
    for (anglesXYZ(r), a) |x, y| try std.testing.expectApproxEqAbs(y, x, 1e-5);
}
