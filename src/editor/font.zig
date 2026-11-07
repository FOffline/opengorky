//! UI text: TrueType faces baked by stb_truetype into one atlas at a few sizes, Latin and
//! Cyrillic. Sizes are in points; glyphs are baked at points × pixel density so text
//! stays sharp on HiDPI screens. `Font` is the editor's set (PT Sans regular, bold,
//! italic); the game's launcher bakes its own with `Fonts`.

const std = @import("std");
const c = @import("sdl");
const ui = @import("ui");

pub const regular = 0;
pub const bold = 1;
/// A preview tab's name (as editors show one not kept yet).
pub const italic = 2;

pub const Font = Fonts(&.{
    .{ .ttf = @embedFile("font_regular"), .sizes = &.{ 13, 15, 18 } },
    .{ .ttf = @embedFile("font_bold"), .sizes = &.{ 13, 15, 18 } },
    .{ .ttf = @embedFile("font_italic"), .sizes = &.{ 13, 15, 18 } },
}, 900);

/// A TrueType file and its baked sizes in points; other sizes use the nearest. `latin`:
/// ASCII only (a large display size: other letters show as "?"), so it fits the atlas.
const Face = struct { ttf: []const u8, sizes: []const u16, latin: bool = false };

/// Code point ranges (start, count): ASCII, Latin-1 (×, «»), Cyrillic, punctuation (—, …),
/// arrows (→ ↔), minus, ≠ ≤ ≥ (the UI's strings use them).
const ranges = [_][2]u32{ .{ 32, 95 }, .{ 0xa0, 0x60 }, .{ 0x400, 0x60 }, .{ 0x2010, 0x18 }, .{ 0x2190, 6 }, .{ 0x2212, 1 }, .{ 0x2260, 6 } };
const n_chars = blk: {
    var n = 0;
    for (ranges) |rg| n += rg[1];
    break :blk n;
};

/// Faces (font ids are their indices) in an atlas of `atlas` points square.
pub fn Fonts(comptime faces: []const Face, comptime atlas: comptime_int) type {
    const max_sizes = comptime blk: {
        var m = 0;
        for (faces) |f| m = @max(m, f.sizes.len);
        break :blk m;
    };
    const face_latin = comptime blk: {
        var l: [faces.len]bool = undefined;
        for (faces, 0..) |f, i| l[i] = f.latin;
        break :blk l;
    };
    const face_sizes = comptime blk: {
        var s: [faces.len][]const u16 = undefined;
        for (faces, 0..) |f, i| s[i] = f.sizes;
        break :blk s;
    };
    return struct {
        const Self = @This();

        tex: *c.SDL_Texture,
        density: f32,
        /// [face][size][range] glyphs.
        chars: [faces.len][max_sizes][n_chars]ui.stbtt_packedchar,
        /// Line height and ascent per [face][size], in points.
        line: [faces.len][max_sizes]f32,
        ascent: [faces.len][max_sizes]f32,

        pub fn init(gpa: std.mem.Allocator, r: *c.SDL_Renderer, density: f32) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const alpha = try self.bake(gpa, density);
            defer gpa.free(alpha);
            const side: c_int = @intCast(std.math.sqrt(alpha.len));
            // White RGBA with the coverage as alpha: SDL tints it with the color mod.
            const rgba = try gpa.alloc(u8, alpha.len * 4);
            defer gpa.free(rgba);
            for (alpha, 0..) |a, i| rgba[i * 4 ..][0..4].* = .{ 255, 255, 255, a };
            self.tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, side, side) orelse return error.Texture;
            _ = c.SDL_UpdateTexture(self.tex, null, rgba.ptr, side * 4);
            _ = c.SDL_SetTextureBlendMode(self.tex, c.SDL_BLENDMODE_BLEND);
            return self;
        }

        /// Packs every face and size into a new coverage atlas (side × side bytes, the
        /// caller frees it) and fills the glyph boxes and metrics; no renderer needed.
        fn bake(self: *Self, gpa: std.mem.Allocator, density: f32) ![]u8 {
            // Baked at 4× at most (the atlas's memory); the renderer scales larger glyphs up.
            self.density = @min(density, 4);
            const side: c_int = @intFromFloat(@ceil(atlas * self.density));
            const alpha = try gpa.alloc(u8, @intCast(side * side));
            errdefer gpa.free(alpha);
            var pc: ui.stbtt_pack_context = undefined;
            if (ui.stbtt_PackBegin(&pc, alpha.ptr, side, side, 0, 1, null) == 0) return error.FontPack;
            ui.stbtt_PackSetOversampling(&pc, 1, 1);
            inline for (faces, 0..) |face, fi| {
                const ttf = face.ttf;
                var info: ui.stbtt_fontinfo = undefined;
                if (ui.stbtt_InitFont(&info, ttf.ptr, 0) == 0) return error.FontInit;
                var asc: c_int = 0;
                var desc: c_int = 0;
                var gap: c_int = 0;
                ui.stbtt_GetFontVMetrics(&info, &asc, &desc, &gap);
                for (face.sizes, 0..) |pt, si| {
                    const px = @as(f32, @floatFromInt(pt)) * self.density;
                    var at: usize = 0;
                    for (ranges[0..if (face.latin) 1 else ranges.len]) |rg| {
                        const n: c_int = @intCast(rg[1]);
                        if (ui.stbtt_PackFontRange(&pc, ttf.ptr, 0, px, @intCast(rg[0]), n, &self.chars[fi][si][at]) == 0) return error.FontAtlasFull;
                        at += rg[1];
                    }
                    const k = ui.stbtt_ScaleForPixelHeight(&info, px);
                    self.line[fi][si] = @as(f32, @floatFromInt(asc - desc + gap)) * k / self.density;
                    self.ascent[fi][si] = @as(f32, @floatFromInt(asc)) * k / self.density;
                }
            }
            ui.stbtt_PackEnd(&pc);
            return alpha;
        }

        /// Baked again at another density (the UI scale changed); on failure the old stays.
        pub fn rebake(self: *Self, gpa: std.mem.Allocator, r: *c.SDL_Renderer, density: f32) !void {
            const fresh = try init(gpa, r, density);
            c.SDL_DestroyTexture(self.tex);
            self.* = fresh.*;
            gpa.destroy(fresh);
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            c.SDL_DestroyTexture(self.tex);
            gpa.destroy(self);
        }

        /// Face and size index for font id `font_id` at `pt` points.
        fn pick(font_id: u16, pt: u16) [2]usize {
            const fi = @min(font_id, faces.len - 1);
            const sizes = face_sizes[fi];
            var best: usize = 0;
            for (sizes, 0..) |s, i| {
                if (@abs(@as(i32, s) - pt) < @abs(@as(i32, sizes[best]) - pt)) best = i;
            }
            return .{ fi, best };
        }

        fn glyph(cp: u21) ?usize {
            var at: usize = 0;
            for (ranges) |rg| {
                if (cp >= rg[0] and cp < rg[0] + rg[1]) return at + (cp - rg[0]);
                at += rg[1];
            }
            return null;
        }

        /// Glyph of `cp` in face `fi` ("?" for one it lacks).
        fn glyphIn(fi: usize, cp: u21) usize {
            const g = glyph(cp) orelse return glyph('?').?;
            return if (face_latin[fi] and g >= ranges[0][1]) glyph('?').? else g;
        }

        /// Width and line height of UTF-8 `text`, in points.
        pub fn measure(self: *const Self, text: []const u8, font_id: u16, pt: u16) [2]f32 {
            return self.measureSpaced(text, font_id, pt, 0);
        }

        /// As `measure`, `spacing` points between letters.
        pub fn measureSpaced(self: *const Self, text: []const u8, font_id: u16, pt: u16, spacing: f32) [2]f32 {
            const fi, const si = pick(font_id, pt);
            var w: f32 = 0;
            var n: f32 = 0;
            var it = (std.unicode.Utf8View.init(text) catch return .{ 0, self.line[fi][si] }).iterator();
            while (it.nextCodepoint()) |cp| {
                w += self.chars[fi][si][glyphIn(fi, cp)].xadvance;
                n += 1;
            }
            return .{ w / self.density + spacing * @max(n - 1, 0), self.line[fi][si] };
        }

        /// Atlas pixels of baked glyph `pc`, taken from its integer box: the quad's s0…t1
        /// times the side lands a hair below the integer (33.99998), and renderers that
        /// truncate the source rect (SDL's software one, Windows) then lose the glyph's right
        /// column and take the padding instead (at 1× «о» looked like «с»).
        fn cell(pc: ui.stbtt_packedchar) c.SDL_FRect {
            return .{ .x = @floatFromInt(pc.x0), .y = @floatFromInt(pc.y0), .w = @floatFromInt(pc.x1 - pc.x0), .h = @floatFromInt(pc.y1 - pc.y0) };
        }

        /// Draws `text` with its top-left at (x, y) points.
        pub fn draw(self: *const Self, r: *c.SDL_Renderer, text: []const u8, font_id: u16, pt: u16, x: f32, y: f32, rgba: [4]u8) void {
            self.drawSpaced(r, text, font_id, pt, x, y, rgba, 0);
        }

        /// As `draw`, `spacing` points between letters.
        pub fn drawSpaced(self: *const Self, r: *c.SDL_Renderer, text: []const u8, font_id: u16, pt: u16, x: f32, y: f32, rgba: [4]u8, spacing: f32) void {
            const fi, const si = pick(font_id, pt);
            _ = c.SDL_SetTextureColorMod(self.tex, rgba[0], rgba[1], rgba[2]);
            _ = c.SDL_SetTextureAlphaMod(self.tex, rgba[3]);
            const side: c_int = @intFromFloat(@ceil(atlas * self.density));
            var px: f32 = x * self.density;
            const py: f32 = (y + self.ascent[fi][si]) * self.density;
            var it = (std.unicode.Utf8View.init(text) catch return).iterator();
            while (it.nextCodepoint()) |cp| {
                const g = glyphIn(fi, cp);
                var q: ui.stbtt_aligned_quad = undefined;
                var gy = py;
                // Whole device pixels: renderers that truncate a fractional destination
                // (software, Windows) otherwise jam or gap letters at 1× («ru les»).
                ui.stbtt_GetPackedQuad(&self.chars[fi][si], side, side, @intCast(g), &px, &gy, &q, 1);
                const d = self.density;
                const src = cell(self.chars[fi][si][g]);
                const dst: c.SDL_FRect = .{ .x = q.x0 / d, .y = q.y0 / d, .w = (q.x1 - q.x0) / d, .h = (q.y1 - q.y0) / d };
                _ = c.SDL_RenderTexture(r, self.tex, &src, &dst);
                px += @round(spacing * d);
            }
        }
    };
}

test "glyph cells fit the atlas, never overlap, and hold the whole glyph" {
    const gpa = std.testing.allocator;
    for ([_]f32{ 1, 2 }) |density| {
        const f = try gpa.create(Font);
        defer gpa.destroy(f);
        const alpha = try f.bake(gpa, density);
        defer gpa.free(alpha);
        const side = std.math.sqrt(alpha.len);
        // Each pixel's cell (its top-left + 1): code points missing from the font share
        // stb's one missing-glyph cell, any other sharing is an overlap.
        const owner = try gpa.alloc(usize, alpha.len);
        defer gpa.free(owner);
        @memset(owner, 0);
        for (&f.chars) |*sizes| for (sizes) |*glyphs| for (glyphs) |pc| {
            try std.testing.expect(pc.x0 <= pc.x1 and pc.x1 <= side and pc.y0 <= pc.y1 and pc.y1 <= side);
            for (pc.y0..pc.y1) |y| for (pc.x0..pc.x1) |x| {
                const id = @as(usize, pc.y0) * side + pc.x0 + 1;
                try std.testing.expect(owner[y * side + x] == 0 or owner[y * side + x] == id);
                owner[y * side + x] = id;
            };
        };
        // «о» at the UI's 13 pt: ink in the cell's rightmost column (the bug drew «с»).
        const pc = f.chars[regular][0][Font.glyph(0x43e).?];
        const r = Font.cell(pc);
        try std.testing.expectEqual(@as(f32, @floatFromInt(pc.x1)), r.x + r.w);
        var ink: u32 = 0;
        for (pc.y0..pc.y1) |y| ink += alpha[y * side + pc.x1 - 1];
        try std.testing.expect(ink > 0);
    }
}
