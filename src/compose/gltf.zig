//! glTF 2.0 binary (`.glb`) export and import of game models (not in the exe).
//! Composition: it turns `.msh`/`.ani`/`.bfr` (format records, kept byte-exact) into glTF
//! and back, and takes the frame bounds from the core's skinning (actor/skin.zig).
//!
//! Mapping (export writes it, import reads it back):
//! - mesh units and axes as in `.msh` (Y up; the game's view is right-handed, camera.zig
//!   Persp), triangles as they are (outward normal (B−A)×(C−A) is glTF's CCW front);
//! - a part is a node + mesh named like the part; its texture a material and PNG named
//!   like the `.3df`;
//! - bone i is node `boneNN` at its chunk 1 joint, no hierarchy (the `.bfr` matrices take
//!   the bind pose straight to the pose), inverse bind matrix = translation by −joint.
//!   The weight the bones leave stays on the bind pose in the exe (skin.zig): it goes to
//!   joint `rest`, which never moves;
//! - bone i at frame f: node TRS = M·T(joint), M the `.bfr` matrix (shear, in 3 models,
//!   does not fit TRS and is dropped);
//! - each `.ani` animation is a glTF animation at 30 frames a second, a LINEAR key per
//!   frame; extras keep first/last/speed/sounds, so frames go back where they were;
//! - an attach point (chunk 13: weapon grips, kula1, pilot1…) is a child node of its
//!   bone: offset as translation, angles as rotation; extras keep the exact numbers;
//! - root node extras `gorky`: chunk 0 name, center, rotation, height, `.ani` spelling.
//! This file: the glTF schema subset and the matrix helpers both directions share;
//! gltf_export.zig writes it, gltf_import.zig reads it back.

const std = @import("std");
const anim = @import("../formats.zig").anim;

comptime {
    // Buffers are written and read in host order; glb is little-endian.
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

/// Game frames a second (one `.bfr` frame per 30 Hz tick, model_cache.frameOf).
pub const fps = 30;

// The subset of the glTF schema used here (field names are glTF's).
pub const Doc = struct {
    asset: struct { version: []const u8 = "2.0", generator: ?[]const u8 = null } = .{},
    scene: ?u32 = null,
    scenes: ?[]const Scene = null,
    nodes: ?[]const Node = null,
    meshes: ?[]const GMesh = null,
    skins: ?[]const Skin = null,
    animations: ?[]const Animation = null,
    materials: ?[]const Material = null,
    textures: ?[]const Texture = null,
    images: ?[]const GImage = null,
    samplers: ?[]const TexSampler = null,
    accessors: ?[]const Accessor = null,
    bufferViews: ?[]const BufferView = null,
    buffers: ?[]const Buffer = null,
};

pub const Scene = struct { nodes: []const u32 = &.{} };
pub const GMesh = struct { name: ?[]const u8 = null, primitives: []const Primitive };
pub const Skin = struct { joints: []const u32, inverseBindMatrices: ?u32 = null, skeleton: ?u32 = null };
pub const Texture = struct { source: ?u32 = null, sampler: ?u32 = null };
pub const GImage = struct { name: ?[]const u8 = null, bufferView: ?u32 = null, mimeType: ?[]const u8 = null, uri: ?[]const u8 = null };
pub const TexSampler = struct { wrapS: ?u32 = null, wrapT: ?u32 = null };
pub const Buffer = struct { byteLength: usize, uri: ?[]const u8 = null };

pub const Node = struct {
    name: ?[]const u8 = null,
    children: ?[]const u32 = null,
    mesh: ?u32 = null,
    skin: ?u32 = null,
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    matrix: ?[16]f32 = null,
    extras: ?struct { gorky: ?Info = null, gorky_attach: ?[6]f32 = null } = null,
};

/// Model fields without a glTF place (root node extras).
pub const Info = struct { name: []const u8 = "", center: [3]f32 = .{ 0, 0, 0 }, rotation: ?[3]f32 = null, height: f32 = 0, animations: []const u8 = "" };

pub const Primitive = struct {
    attributes: struct {
        POSITION: ?u32 = null,
        TEXCOORD_0: ?u32 = null,
        JOINTS_0: ?u32 = null,
        WEIGHTS_0: ?u32 = null,
        JOINTS_1: ?u32 = null,
        WEIGHTS_1: ?u32 = null,
        /// `.msh` vertex number (Vertex.id) and the file percents beside WEIGHTS_0/1
        /// (several percents give one f32 weight), for byte-exact round trips.
        _VERTEX_ID: ?u32 = null,
        _PERCENTS_0: ?u32 = null,
        _PERCENTS_1: ?u32 = null,
    },
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: ?u32 = null,
};

pub const Animation = struct {
    name: ?[]const u8 = null,
    channels: []const struct { sampler: u32, target: struct { node: ?u32 = null, path: []const u8 } },
    samplers: []const struct { input: u32, output: u32, interpolation: ?[]const u8 = null },
    extras: ?struct { first: ?u32 = null, last: ?u32 = null, speed: ?f32 = null, sounds: ?[]const anim.SoundCue = null } = null,
};

pub const Material = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?struct {
        baseColorTexture: ?struct { index: u32 } = null,
        metallicFactor: ?f32 = null,
        roughnessFactor: ?f32 = null,
    } = null,
};

pub const Accessor = struct {
    bufferView: ?u32 = null,
    byteOffset: usize = 0,
    componentType: u32,
    normalized: ?bool = null,
    count: usize,
    type: []const u8,
    min: ?[]const f32 = null,
    max: ?[]const f32 = null,
    sparse: ?std.json.Value = null,
};

pub const BufferView = struct { buffer: u32 = 0, byteOffset: usize = 0, byteLength: usize, byteStride: ?u32 = null, target: ?u32 = null };

pub fn frameTime(k: usize) f32 {
    const t = @as(f64, @floatFromInt(k)) / fps;
    const f: f32 = @floatCast(t);
    // Never under k/fps: Blender reads the time back as t·fps and 127/30 in f32 gives
    // 126.99999, a frame range one short, so its export dropped the last frame.
    return if (f < t) std.math.nextAfter(f32, f, std.math.inf(f32)) else f;
}

test "frameTime: times a tool multiplies back by fps never fall short of the frame" {
    for (0..2000) |k| try std.testing.expect(@as(f64, frameTime(k)) * fps >= @as(f64, @floatFromInt(k)));
}

// ---- matrices ----

/// 4×4, column-major (glTF's order).
pub const Mat = [16]f64;
pub const identity: Mat = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

pub fn mul(x: Mat, y: Mat) Mat {
    var o: Mat = undefined;
    for (0..4) |c| for (0..4) |r| {
        var s: f64 = 0;
        for (0..4) |k| s += x[k * 4 + r] * y[c * 4 + k];
        o[c * 4 + r] = s;
    };
    return o;
}

/// Inverse of an affine matrix.
pub fn inverse(x: Mat) Mat {
    const a = x[0];
    const b = x[4];
    const c = x[8];
    const d = x[1];
    const e = x[5];
    const f = x[9];
    const g = x[2];
    const h = x[6];
    const i = x[10];
    const det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    const k = if (det == 0) 0 else 1 / det;
    // Rows of the inverse 3×3 (adjugate / det).
    const r = [9]f64{ (e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k, (f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k, (d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k };
    var o = identity;
    for (0..3) |row| {
        for (0..3) |col| o[col * 4 + row] = r[row * 3 + col];
        o[12 + row] = -(r[row * 3] * x[12] + r[row * 3 + 1] * x[13] + r[row * 3 + 2] * x[14]);
    }
    return o;
}

pub fn trsMatrix(t: [3]f32, q: [4]f32, s: [3]f32) Mat {
    const r = rowsFromQuat(q);
    var o = identity;
    for (0..3) |c| {
        for (0..3) |row| o[c * 4 + row] = r[row * 3 + c] * s[c];
        o[12 + c] = t[c];
    }
    return o;
}

/// The `.bfr` 12 floats are the column-major 4×4 without its last row.
fn fromBfr(m: *const [12]f32) Mat {
    var o = identity;
    for (0..4) |c| for (0..3) |r| {
        o[c * 4 + r] = m[c * 3 + r];
    };
    return o;
}

pub fn toBfr(x: Mat) [12]f32 {
    var o: [12]f32 = undefined;
    for (0..4) |c| for (0..3) |r| {
        o[c * 3 + r] = @floatCast(x[c * 4 + r]);
    };
    return o;
}

const Trs = struct { t: [3]f32, r: [4]f32, s: [3]f32 };

/// Joint node TRS for bone matrix `m`: world = M·T(joint). The 3×3 is split into a
/// rotation and per-axis scales (Gram-Schmidt on its columns; shear is dropped).
pub fn boneTrs(m: *const [12]f32, joint: [3]f32) Trs {
    const w = mul(fromBfr(m), trsMatrix(joint, .{ 0, 0, 0, 1 }, .{ 1, 1, 1 }));
    var c: [3][3]f64 = undefined;
    for (0..3) |i| c[i] = .{ w[i * 4], w[i * 4 + 1], w[i * 4 + 2] };
    const unit = [3][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    var u: [3][3]f64 = undefined;
    u[0] = normalized(c[0]) orelse unit[0];
    u[1] = normalized(sub3(c[1], scale3(u[0], dot3(c[1], u[0])))) orelse
        normalized(cross3(u[0], unit[2])) orelse normalized(cross3(u[0], unit[0])).?;
    u[2] = cross3(u[0], u[1]);
    var rows: [9]f64 = undefined;
    for (0..3) |i| for (0..3) |r| {
        rows[r * 3 + i] = u[i][r];
    };
    var s: [3]f32 = undefined;
    for (0..3) |i| s[i] = @floatCast(dot3(c[i], u[i]));
    return .{ .t = .{ @floatCast(w[12]), @floatCast(w[13]), @floatCast(w[14]) }, .r = quatFromRows(rows), .s = s };
}

fn dot3(x: [3]f64, y: [3]f64) f64 {
    return x[0] * y[0] + x[1] * y[1] + x[2] * y[2];
}
fn sub3(x: [3]f64, y: [3]f64) [3]f64 {
    return .{ x[0] - y[0], x[1] - y[1], x[2] - y[2] };
}
fn scale3(x: [3]f64, k: f64) [3]f64 {
    return .{ x[0] * k, x[1] * k, x[2] * k };
}
fn cross3(x: [3]f64, y: [3]f64) [3]f64 {
    return .{ x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0] };
}
pub fn normalized(x: [3]f64) ?[3]f64 {
    const l = @sqrt(dot3(x, x));
    return if (l < 1e-12) null else scale3(x, 1 / l);
}
pub fn dot4(x: [4]f32, y: [4]f32) f32 {
    return x[0] * y[0] + x[1] * y[1] + x[2] * y[2] + x[3] * y[3];
}

/// Quaternion (x, y, z, w) of a rotation given by rows (f32 or f64).
pub fn quatFromRows(m: anytype) [4]f32 {
    var r: [9]f64 = undefined;
    for (&r, m) |*d, v| d.* = v;
    const tr = r[0] + r[4] + r[8];
    var q: [4]f64 = undefined;
    if (tr > 0) {
        const s = @sqrt(tr + 1) * 2;
        q = .{ (r[7] - r[5]) / s, (r[2] - r[6]) / s, (r[3] - r[1]) / s, s / 4 };
    } else if (r[0] > r[4] and r[0] > r[8]) {
        const s = @sqrt(1 + r[0] - r[4] - r[8]) * 2;
        q = .{ s / 4, (r[1] + r[3]) / s, (r[2] + r[6]) / s, (r[7] - r[5]) / s };
    } else if (r[4] > r[8]) {
        const s = @sqrt(1 + r[4] - r[0] - r[8]) * 2;
        q = .{ (r[1] + r[3]) / s, s / 4, (r[5] + r[7]) / s, (r[2] - r[6]) / s };
    } else {
        const s = @sqrt(1 + r[8] - r[0] - r[4]) * 2;
        q = .{ (r[2] + r[6]) / s, (r[5] + r[7]) / s, s / 4, (r[3] - r[1]) / s };
    }
    const l = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    return .{ @floatCast(q[0] / l), @floatCast(q[1] / l), @floatCast(q[2] / l), @floatCast(q[3] / l) };
}

pub fn rowsFromQuat(q4: [4]f32) [9]f64 {
    const l = @sqrt(@as(f64, dot4(q4, q4)));
    const x = q4[0] / l;
    const y = q4[1] / l;
    const z = q4[2] / l;
    const w = q4[3] / l;
    return .{
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w),
        2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
        2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y),
    };
}

/// Angles a with rotationXYZ(a) = R (R by rows): R = Rx·Ry·Rz gives R02 = −sin y,
/// R01/R00 = −tan z, R12/R22 = −tan x.
pub fn anglesXYZ(r: [9]f64) [3]f32 {
    const y = std.math.asin(std.math.clamp(-r[2], -1, 1));
    if (@abs(r[2]) > 0.999999) {
        // Gimbal lock: z folds into x.
        return .{ @floatCast(std.math.atan2(r[3], r[4])), @floatCast(y), 0 };
    }
    return .{ @floatCast(std.math.atan2(-r[5], r[8])), @floatCast(y), @floatCast(std.math.atan2(-r[1], r[0])) };
}
