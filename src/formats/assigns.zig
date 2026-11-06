//! Numeric and string assignments `name = value;` in object scripts as text: class files
//! (`ft_*.ss`, `wp_*.ss`) and object files (`.ftr`, `.wpn`), whose lines after the class
//! `#include` override the class. The last assignment wins, as when the script runs.
//! Values are numbers or quoted strings. (Composition reads classes' classic_ids with it; the
//! editor edits them: editor/model.zig.)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A byte range of the text.
pub const Span = struct { start: usize, end: usize };

pub fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Value span of the last `name = <number or "string">` outside comments (name
/// case-insensitive); a string's span includes the quotes.
pub fn find(text: []const u8, name: []const u8) ?Span {
    var found: ?Span = null;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
        } else if (ch == '"') {
            i = if (std.mem.indexOfScalarPos(u8, text, i + 1, '"')) |e| e + 1 else text.len;
        } else if (isIdent(ch) and (i == 0 or !isIdent(text[i - 1]))) {
            var e = i;
            while (e < text.len and isIdent(text[e])) e += 1;
            if (std.ascii.eqlIgnoreCase(text[i..e], name)) if (value(text, e)) |v| {
                found = v;
            };
            i = e;
        } else i += 1;
    }
    return found;
}

pub fn value(text: []const u8, name_end: usize) ?Span {
    var k = name_end;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    if (k >= text.len or text[k] != '=' or (k + 1 < text.len and text[k + 1] == '=')) return null;
    k += 1;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    const a = k;
    if (k < text.len and text[k] == '"') {
        const e = std.mem.indexOfScalarPos(u8, text, k + 1, '"') orelse return null;
        return .{ .start = a, .end = e + 1 };
    }
    if (k < text.len and text[k] == '-') k += 1;
    while (k < text.len and (std.ascii.isDigit(text[k]) or text[k] == '.')) k += 1;
    if (k == a or std.fmt.parseFloat(f32, text[a..k]) == error.InvalidCharacter) return null;
    return .{ .start = a, .end = k };
}

/// A string value without its quotes.
pub fn getStr(text: []const u8, name: []const u8) ?[]const u8 {
    const s = find(text, name) orelse return null;
    if (text[s.start] != '"') return null;
    return text[s.start + 1 .. s.end - 1];
}

pub fn get(text: []const u8, name: []const u8) ?f32 {
    const s = find(text, name) orelse return null;
    return std.fmt.parseFloat(f32, text[s.start..s.end]) catch null;
}

/// `name`'s value in script `text` or, when it has none, in the files it `#include`s
/// (`lib.read(file)`), nested up to `depth` levels (a cycle ends there): an enemy class
/// is named in its `act_*.ss`, a battle extra's `.hro` in its class's.
pub fn inherited(lib: anytype, text: []const u8, name: []const u8, depth: u8) ?f32 {
    if (get(text, name)) |v| return v;
    if (depth == 0) return null;
    var pos: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, pos, "#include ")) |p| : (pos = p + 1) {
        const s = p + "#include ".len;
        var e = s;
        while (e < text.len and !std.ascii.isWhitespace(text[e])) e += 1;
        const inc = lib.read(text[s..e]) orelse continue;
        if (inherited(lib, inc, name, depth - 1)) |v| return v;
    }
    return null;
}

/// The script that sets `name`: `text` itself or one it `#include`s, as `inherited`
/// (a battle extra's `.hro` has its look in its class's `act_*.ss`).
pub fn definer(lib: anytype, text: []const u8, name: []const u8, depth: u8) ?[]const u8 {
    if (getStr(text, name) != null or get(text, name) != null) return text;
    if (depth == 0) return null;
    var pos: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, pos, "#include ")) |p| : (pos = p + 1) {
        const s = p + "#include ".len;
        var e = s;
        while (e < text.len and !std.ascii.isWhitespace(text[e])) e += 1;
        const inc = lib.read(text[s..e]) orelse continue;
        if (definer(lib, inc, name, depth - 1)) |d| return d;
    }
    return null;
}

/// Objects script `text` makes party heroes: `SETHERO("x",1)` (scenes),
/// `HERO_EnableEnumerate("x",1)` (level scripts); slices of `text`.
pub fn joins(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for ([_][]const u8{ "SETHERO(\"", "HERO_EnableEnumerate(\"" }) |needle| {
        var pos: usize = 0;
        while (std.ascii.findIgnoreCasePos(text, pos, needle)) |i| : (pos = i + 1) {
            const s = i + needle.len;
            const q = std.mem.indexOfScalarPos(u8, text, s, '"') orelse continue;
            var k = q + 1;
            while (k < text.len and (text[k] == ',' or text[k] == ' ')) k += 1;
            if (k < text.len and std.ascii.isDigit(text[k]) and text[k] != '0' and q > s) try out.append(a, text[s..q]);
        }
    }
    return out.toOwnedSlice(a);
}

/// The files `#include NAME` and `#inherit NAME` lines of `text` name (an `#inherit`
/// without an extension is `NAME.s`, as the engine loads it), in `a`.
pub fn directives(a: Allocator, text: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        const inherit = std.ascii.startsWithIgnoreCase(l, "#inherit");
        if (!inherit and !std.ascii.startsWithIgnoreCase(l, "#include")) continue;
        var words = std.mem.tokenizeAny(u8, l["#include".len..], " \t\";");
        const n = words.next() orelse continue;
        const name = if (inherit and std.fs.path.extension(n).len == 0) std.fmt.allocPrint(a, "{s}.s", .{n}) catch continue else n;
        out.append(a, name) catch {};
    }
    return out.items;
}

test "find: last assignment, comments and == skipped" {
    const t = "armor = 0;\n  hp=40; // hp = 9\n if (armor == 2) {}\n  armor = 1;\n";
    try std.testing.expectEqual(1, get(t, "armor").?);
    try std.testing.expectEqual(40, get(t, "HP").?);
    try std.testing.expectEqual(null, get(t, "max_hp"));
}

test directives {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = directives(arena.allocator(), "#inherit Level\r\nint a;\r\nfunction init()\r\n{\r\n\t#include ft_fang.ss\r\n#inherit Weapon.s\r\n};");
    try std.testing.expectEqual(@as(usize, 3), d.len);
    try std.testing.expectEqualStrings("Level.s", d[0]);
    try std.testing.expectEqualStrings("ft_fang.ss", d[1]);
    try std.testing.expectEqualStrings("Weapon.s", d[2]);
}

test "inherited: nameID through nested includes, own value first, cycles end" {
    const Lib = struct {
        pub fn read(_: @This(), n: []const u8) ?[]const u8 {
            const files = [_][2][]const u8{
                .{ "Fighter.s", "int nameID; int avoidEnumerate;" },
                .{ "ft_medusa.ss", "#include act_medusa.ss\n hp = 1;" },
                .{ "act_medusa.ss", "  nameID=119;" },
                .{ "loop.ss", "#include loop.ss" },
            };
            for (files) |f| if (std.mem.eql(u8, f[0], n)) return f[1];
            return null;
        }
    };
    const medusa = "#include Fighter.s\nfunction init()\n{\n#include ft_medusa.ss\n moveLock = 1;\n avoidEnumerate = 1;\n};";
    try std.testing.expectEqual(@as(?f32, 119), inherited(Lib{}, medusa, "nameID", 4));
    try std.testing.expectEqual(@as(?f32, 1), inherited(Lib{}, medusa, "avoidEnumerate", 4));
    try std.testing.expectEqual(@as(?f32, 24), inherited(Lib{}, "#include ft_medusa.ss\n nameID=24;", "nameID", 4));
    try std.testing.expectEqual(@as(?f32, null), inherited(Lib{}, "#include loop.ss", "nameID", 4));
}

test "joins: SETHERO/HERO_EnableEnumerate with 1 join, with 0 leave" {
    const j = try joins(std.testing.allocator, "SETHERO(\"Medusa\",1);\nHERO_EnableEnumerate(\"MacFadden\", 1);\nHERO_EnableEnumerate(\"Bt\",0);");
    defer std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(usize, 2), j.len);
    try std.testing.expectEqualStrings("Medusa", j[0]);
    try std.testing.expectEqualStrings("MacFadden", j[1]);
}
