//! A free name for something new: the first of a numbered series nothing has yet
//! (`taken`), and a file name's stem as the game's archives spell them.

const std = @import("std");

/// The names tried: `<base><ext>` first when `bare`, then `<base><sep><n><ext>` from `from`.
const Series = struct { sep: []const u8 = "_", ext: []const u8 = "", bare: bool = true, from: usize = 2 };

/// The first name of series `s` from `base` for which `taken` is false (in `buf`; `base`
/// not in it).
pub fn freeName(buf: []u8, base: []const u8, s: Series, ctx: anytype, comptime taken: fn (@TypeOf(ctx), []const u8) bool) ![]const u8 {
    if (s.bare) {
        const n = try std.fmt.bufPrint(buf, "{s}{s}", .{ base, s.ext });
        if (!taken(ctx, n)) return n;
    }
    for (s.from..1000) |k| {
        const n = try std.fmt.bufPrint(buf, "{s}{s}{d}{s}", .{ base, s.sep, k, s.ext });
        if (!taken(ctx, n)) return n;
    }
    return error.NoFreeName;
}

/// `stem` as an archive name's stem: lowercase letters, digits and `_`, cut to `buf`;
/// `blank` when nothing is left.
pub fn fileStem(buf: []u8, stem: []const u8, blank: u8) []const u8 {
    const n = @min(stem.len, buf.len);
    for (stem[0..n], buf[0..n]) |ch, *o| o.* = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_';
    if (n > 0) return buf[0..n];
    buf[0] = blank;
    return buf[0..1];
}

test freeName {
    var buf: [32]u8 = undefined;
    const taken = struct {
        fn f(have: []const []const u8, s: []const u8) bool {
            for (have) |x| if (std.mem.eql(u8, x, s)) return true;
            return false;
        }
    }.f;
    const have: []const []const u8 = &.{ "a_copy.s", "a.wav", "a_2.wav", "trigger1" };
    try std.testing.expectEqualStrings("a_copy2.s", try freeName(&buf, "a_copy", .{ .sep = "", .ext = ".s" }, have, taken));
    try std.testing.expectEqualStrings("a_3.wav", try freeName(&buf, "a", .{ .ext = ".wav" }, have, taken));
    try std.testing.expectEqualStrings("m_2", try freeName(&buf, "m", .{ .bare = false }, have, taken));
    try std.testing.expectEqualStrings("trigger2", try freeName(&buf, "trigger", .{ .sep = "", .bare = false, .from = 1 }, have, taken));
    try std.testing.expectEqualStrings("my_song_1", fileStem(&buf, "My Song-1", 's'));
    try std.testing.expectEqualStrings("s", fileStem(&buf, "", 's'));
}
