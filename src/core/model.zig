//! A model as the core keeps it: mesh (parts, skeleton joints, attach points),
//! animations with their frame sound cues, bone frames. The core reads no files:
//! composition (compose/models.zig) parses `.msh`/`.ani`/`.bfr` and converts them to
//! these records; actor/model_cache.zig keeps them (textures: render/textures.zig).

const std = @import("std");

pub const Vertex = struct {
    pos: [3]f32,
    uv: [2]f32,
};

pub const Influence = struct {
    bone: u32,
    /// 0..1.
    weight: f32,
};

pub const Part = struct {
    name: []const u8,
    vertices: []const Vertex,
    /// Per vertex, a range `[start, end)` into `influences`.
    ranges: []const [2]u32,
    influences: []const Influence,
    triangles: []const [3]u32,
    /// The part's own texture (empty: the mesh's).
    texture: []const u8 = "",
};

/// Weapon hold mode (`default`, `two_hands`, `one_hand`) and the hand bone.
pub const HoldMode = struct {
    name: []const u8,
    /// Offset from the bone joint (x, y, z) and rotation angles around X, Y, Z (0x4290f0).
    params: [6]f32,
    bone: u32,
};

pub const Mesh = struct {
    name: []const u8 = "",
    /// Model shift to the origin (0x44c060: v' = height·(R·v + shift)).
    center: [3]f32 = .{ 0, 0, 0 },
    /// Model rotation around X, Y, Z in radians.
    rotation: [3]f32 = .{ 0, 0, 0 },
    height: f32 = 0,
    /// Joint points in the bind pose (one per bone).
    joints: []const [3]f32 = &.{},
    texture: []const u8 = "",
    animations: []const u8 = "",
    hold_modes: []const HoldMode = &.{},
    parts: []const Part = &.{},

    /// Attachment point by name (case-insensitive), first match.
    pub fn holdMode(self: Mesh, name: []const u8) ?HoldMode {
        for (self.hold_modes) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h;
        return null;
    }
};

/// A sound started when an animation shows frame `frame`.
pub const SoundCue = struct {
    name: []const u8,
    frame: u32,
    volume: u8,
};

pub const Animation = struct {
    name: []const u8,
    /// Global bone frame numbers, inclusive.
    first: u32,
    last: u32,
    speed: f32,
    sounds: []const SoundCue,

    /// Shown frame for step `fr` (first…last): reversed, the exe counts down from
    /// last (0x44fb3b, 0x44fc05) and matches frame sounds against it (0x44fb92).
    pub fn shown(self: Animation, fr: u32, reverse: bool) u32 {
        return if (reverse) self.last - (fr - self.first) else fr;
    }
};

pub const Anims = struct {
    items: []const Animation = &.{},

    pub fn find(self: Anims, name: []const u8) ?*const Animation {
        for (self.items) |*a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a;
        return null;
    }
};

/// Bone matrices per frame (3×3 rotation by rows, then translation) and each frame's
/// skinned bounds (min xyz, max xyz).
pub const BoneFrames = struct {
    frames: u32,
    bones: u32,
    matrices: []const [12]f32,
    extra: []const [6]f32,

    pub fn matrix(self: BoneFrames, frame: u32, bone: u32) *const [12]f32 {
        return &self.matrices[@as(usize, frame) * self.bones + bone];
    }
};

test "find is case-insensitive" {
    const items = [_]Animation{.{ .name = "G_Idle", .first = 1, .last = 4, .speed = 1, .sounds = &.{} }};
    const l: Anims = .{ .items = &items };
    try std.testing.expectEqual(1, l.find("g_idle").?.first);
    try std.testing.expectEqual(3, items[0].shown(2, true));
}
