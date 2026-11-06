//! Model textures for drawing, on the renderer's side: mip levels by texture name (a model's
//! mesh and parts name theirs) and single pictures of the models' archive (effect frames,
//! markers). The core's models hold mesh, skeleton and animations only; composition
//! (compose/models.zig `textures`) reads the files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("../image.zig").Image;
const Model = @import("../actor.zig").model_cache.Model;

/// Where textures come from (composition). Null functions: nothing there.
pub const Source = struct {
    ctx: ?*anyopaque = null,
    /// Texture `name`'s (`textures/<name>`) mip levels in `a`; null: missing or broken.
    mips: ?*const fn (ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]Image = null,
    /// Texture asset `path` (loaders/assets.zig: `textures/*.3df`, effect frames
    /// `effects/<name>/*`), its top level in `a`; null: missing or broken.
    texture: ?*const fn (ctx: ?*anyopaque, a: Allocator, path: []const u8) ?Image = null,
};

/// Longest texture name kept (an archive entry name).
const name_max = 112;

pub const Textures = struct {
    gpa: Allocator,
    source: Source,
    /// The mip levels and their names.
    arena: std.heap.ArenaAllocator,
    /// Mip levels by texture name (lowercase), decoded on first use; null: none.
    mips: std.StringHashMapUnmanaged(?[]Image) = .empty,

    pub fn init(gpa: Allocator, source: Source) Textures {
        return .{ .gpa = gpa, .source = source, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Textures) void {
        self.mips.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Mip levels of texture `name` (case-insensitive); null: none or no such texture.
    fn mipsOf(self: *Textures, name: []const u8) ?[]Image {
        var key_buf: [name_max]u8 = undefined;
        if (name.len == 0 or name.len > key_buf.len) return null;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.mips.get(key)) |m| return m;
        const a = self.arena.allocator();
        const m = (self.source.mips orelse return null)(self.source.ctx, a, name);
        self.mips.put(self.gpa, a.dupe(u8, key) catch return m, m) catch {};
        return m;
    }

    /// Mip levels of model part `pi`'s texture: its own (chunk 9 sets the texture of the part
    /// being read, 0x44cf3a → 0x44d7b0, part +0x6c: fang has `pasozyt` on the back and
    /// `fang_poprawiany` on the body) or, without one or when it is missing, the mesh's.
    /// The exe picks a level with MIPLINEAR filtering (0x406d90).
    pub fn partMips(self: *Textures, model: *const Model, pi: usize) []const Image {
        const mesh = self.mipsOf(model.mesh.texture) orelse &.{};
        if (pi >= model.mesh.parts.len) return mesh;
        const own = model.mesh.parts[pi].texture;
        if (own.len == 0 or std.ascii.eqlIgnoreCase(own, model.mesh.texture)) return mesh;
        return self.mipsOf(own) orelse mesh;
    }

    /// The mesh's own texture (its top mip level).
    pub fn meshTexture(self: *Textures, model: *const Model) ?Image {
        const m = self.mipsOf(model.mesh.texture) orelse return null;
        return if (m.len > 0) m[0] else null;
    }

    /// Texture of model part `pi` (its top mip level).
    pub fn partTexture(self: *Textures, model: *const Model, pi: usize) ?Image {
        const m = self.partMips(model, pi);
        return if (m.len > 0) m[0] else null;
    }

    /// Texture asset `path` (an effect frame, a marker's), decoded into
    /// `a` (the caller's); null: missing or broken.
    pub fn texture(self: *Textures, a: Allocator, path: []const u8) ?Image {
        return (self.source.texture orelse return null)(self.source.ctx, a, path);
    }
};

test "a part without its own texture shares the mesh's" {
    const S = struct {
        var img_px = [_]u8{ 1, 2, 3, 4 };
        fn mips(_: ?*anyopaque, a: Allocator, name: []const u8) ?[]Image {
            if (std.ascii.eqlIgnoreCase(name, "missing.3df")) return null;
            const m = a.alloc(Image, 1) catch return null;
            m[0] = .{ .width = 1, .height = @intCast(name.len), .pixels = &img_px };
            return m;
        }
    };
    var t: Textures = .init(std.testing.allocator, .{ .mips = S.mips });
    defer t.deinit();
    var m: Model = undefined;
    const P = @import("../core.zig").model.Part;
    const p: P = .{ .name = "", .vertices = &.{}, .ranges = &.{}, .influences = &.{}, .triangles = &.{} };
    var parts = [_]P{ p, p, p, p };
    parts[1].texture = "OTHER_1.3df";
    parts[2].texture = "missing.3df";
    parts[3].texture = "a.3df";
    m.mesh = .{ .texture = "a.3df", .parts = &parts };
    try std.testing.expectEqual(@as(u32, 5), t.partTexture(&m, 0).?.height);
    try std.testing.expectEqual(@as(u32, 11), t.partTexture(&m, 1).?.height);
    try std.testing.expectEqual(@as(u32, 5), t.partTexture(&m, 2).?.height);
    try std.testing.expectEqual(t.partMips(&m, 0).ptr, t.partMips(&m, 3).ptr);
}
