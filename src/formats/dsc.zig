//! Effect resource description `.dsc` (`gfx_3d\Effects\<name>\<name>.dsc`): blend header
//! and frame list.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The blend header line: none, `[alpha]` or `[ala]` (D3D), `[add]`.
const Header = enum { none, alpha, add };

/// `.dsc` parse (0x45df40): frame lines up to an empty line; the last header line wins.
/// `frames` are `.3df` file names in the same folder, slices of `text`.
pub const Dsc = struct {
    header: Header = .none,
    frames: []const []const u8 = &.{},
};

pub fn parse(gpa: Allocator, text: []const u8) !Dsc {
    var d: Dsc = .{};
    var frames: std.ArrayList([]const u8) = .empty;
    errdefer frames.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOf(u8, line, "[alpha]") != null or std.mem.indexOf(u8, line, "[ala]") != null) {
            d.header = .alpha;
            continue;
        }
        if (std.mem.indexOf(u8, line, "[add]") != null) {
            d.header = .add;
            continue;
        }
        if (line.len == 0) break;
        try frames.append(gpa, line);
    }
    d.frames = try frames.toOwnedSlice(gpa);
    return d;
}

test parse {
    const d = try parse(std.testing.allocator, "[alpha]\r\nexp.01.3df\r\nexp.02.3df\r\n\r\nzzz\r\n");
    defer std.testing.allocator.free(d.frames);
    try std.testing.expectEqual(Header.alpha, d.header);
    try std.testing.expectEqual(2, d.frames.len);
    try std.testing.expectEqualStrings("exp.02.3df", d.frames[1]);
}
