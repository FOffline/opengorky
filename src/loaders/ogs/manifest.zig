//! `opengorky.mod` as the OG reader reads it: "key = value" lines, `#`
//! comments, the keys compose/og/write.zig `manifest` writes. Its own small parser:
//! formats/manifest.zig is the shared reader (format, engine version, writing); this one
//! keeps the OGS loader's own keys (`game`, `language`) apart from it.
//! Unknown keys are ignored; values point into the text.

const std = @import("std");

pub const file_name = "opengorky.mod";

pub const Manifest = struct {
    /// `ogs` for an OpenGorky project (else not one: `classic`, `opengorky`, none).
    format: []const u8 = "",
    engine: []const u8 = "",
    id: []const u8 = "",
    title: []const u8 = "",
    base: []const u8 = "en",
    /// The texts' one language (`en`, `ru`).
    language: []const u8 = "en",
    /// The installed game's folder ("": none; `$OPENGORKY_GAME` overrides it).
    game: []const u8 = "",

    pub fn isOgs(self: Manifest) bool {
        return std.mem.eql(u8, self.format, "ogs");
    }
};

/// A language code and the edition's number the core knows it by (entity.texts.language:
/// the fonts' letter set, formats/strtab.zig langSuffix; the Russian edition's letters are
/// in the `_cz` slot, 5).
const languages = [_]struct { []const u8, u8 }{
    .{ "en", 0 }, .{ "pl", 2 }, .{ "de", 3 }, .{ "fr", 4 }, .{ "ru", 5 }, .{ "nl", 6 }, .{ "es", 7 }, .{ "it", 8 }, .{ "hu", 9 },
};

/// Language `code`'s number (an unknown one: English's, 0).
pub fn languageNumber(code: []const u8) u8 {
    for (languages) |l| if (std.ascii.eqlIgnoreCase(l[0], code)) return l[1];
    return 0;
}

/// Language number `n`'s code (an unknown one: `en`).
pub fn languageCode(n: u8) []const u8 {
    for (languages) |l| if (l[1] == n) return l[0];
    return "en";
}

pub fn parse(text: []const u8) Manifest {
    var m: Manifest = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
        inline for (@typeInfo(Manifest).@"struct".field_names) |f| {
            if (std.mem.eql(u8, key, f)) @field(m, f) = val;
        }
    }
    return m;
}

test "OG manifest: the writer's keys, comments, an empty game" {
    const m = parse("# OpenGorky project\nformat = ogs\nengine = 0.1\nid = port\ntitle = Port (test project)\nbase = en\nlanguage = ru\ngame =\nnope = 1\nbad\n");
    try std.testing.expect(m.isOgs());
    try std.testing.expectEqualStrings("port", m.id);
    try std.testing.expectEqualStrings("Port (test project)", m.title);
    try std.testing.expectEqualStrings("ru", m.language);
    try std.testing.expectEqual(5, languageNumber(m.language));
    try std.testing.expectEqualStrings("ru", languageCode(5));
    try std.testing.expectEqual(0, languageNumber("xx"));
    try std.testing.expectEqualStrings("", m.game);
    try std.testing.expect(!parse("format = opengorky\n").isOgs());
}
