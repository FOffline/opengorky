//! Edition language and font letter sets (0x45a1d0, 0x47a2d0, 0x47ad40, 0x47b3f0).
//! The language number is line 950 of `string.tab`; for N > 1 the exe overlays
//! `<name>_N<suffix>` on font `<name>_1` (bitmap `.fnt`) or uses it as the second
//! page (texture `3d_*`). Russian edition: N = 5, Cyrillic in `_5_cz`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("archive.zig");
const strtab = @import("strtab.zig");

/// Game language number in `dat`; 0 if unreadable. Not cached per process:
/// tools and tests may use different game dirs.
pub fn language(io: Io, gpa: Allocator, dat: Io.Dir) u8 {
    return read(io, gpa, dat) catch 0;
}

fn read(io: Io, gpa: Allocator, dat: Io.Dir) !u8 {
    var lang = try archive.Archive.open(io, gpa, dat, "common/lang.dat");
    defer lang.close(io, gpa);
    const bytes = try lang.readAlloc(io, gpa, lang.find("string.tab") orelse return 0);
    defer gpa.free(bytes);
    var t = try strtab.parseStrings(gpa, bytes);
    defer t.deinit(gpa);
    return strtab.language(t);
}

/// Language set name `<base>_N<suffix>`, or null for the base language.
pub fn setName(buf: []u8, base: []const u8, n: u8) ?[]const u8 {
    const suf = strtab.langSuffix(n) orelse return null;
    return std.fmt.bufPrint(buf, "{s}_{d}{s}", .{ base, n, suf }) catch null;
}
