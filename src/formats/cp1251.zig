//! Windows-1251, the game's 8-bit text (its fonts' glyph order), and UTF-8, an OpenGorky
//! project's: the converter writes UTF-8, the OG reader hands the core
//! the font's bytes back (a subtitle's time and its glyphs count bytes, as in the exe).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 0x80…0xFF as code points (0x98, undefined there, as U+FFFD).
const high = [64]u21{
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
} ++ blk: {
    var t: [64]u21 = undefined;
    for (&t, 0..) |*x, i| x.* = 0x0410 + i;
    break :blk t;
};

fn ascii(s: []const u8) bool {
    for (s) |ch| if (ch >= 0x80) return false;
    return true;
}

/// `s` (cp1251) as UTF-8, in `a`; ASCII is itself.
pub fn toUtf8(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (ascii(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (ch < 0x80) {
            try out.append(a, ch);
            continue;
        }
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(high[ch - 0x80], &b) catch unreachable;
        try out.appendSlice(a, b[0..n]);
    }
    return out.items;
}

/// `s` (UTF-8) as cp1251, in `a`: a character it has no byte for is `?`, bytes that are no
/// UTF-8 stay as they are.
pub fn fromUtf8(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (ascii(s)) return s;
    const view = std.unicode.Utf8View.init(s) catch return s;
    var out: std.ArrayList(u8) = .empty;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            try out.append(a, @intCast(cp));
            continue;
        }
        const k = std.mem.indexOfScalar(u21, &high, cp);
        try out.append(a, if (k) |i| @intCast(0x80 + i) else '?');
    }
    return out.items;
}

test "cp1251 to UTF-8 and back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = "\xcf\xf0\xe8\xe2\xe5\xf2, \xa8\xe6 \x85";
    try std.testing.expectEqualStrings("Привет, Ёж …", try toUtf8(a, w));
    try std.testing.expectEqualStrings(w, try fromUtf8(a, try toUtf8(a, w)));
    try std.testing.expectEqualStrings("plain", try toUtf8(a, "plain"));
}
