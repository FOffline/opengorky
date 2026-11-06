//! The game's entities as the core's records up front (core/entity.zig `fill`): every
//! class of `common/other.dat` (`classes\ft_*.ss` enemies, `wp_*` enemy weapons, `cw_*`
//! weapons, `ca_*` ammo, `ci_*` items) and every hero (`.hro` of the common archive and
//! the locations'), each named by its `classic_id` (its own or that of the scripts it
//! `#include`s, as the class runs) and, in an OpenGorky project, its class. The editor's
//! catalog is this list with what only the editor knows (editor/catalog.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("../../formats.zig").archive;
const assigns = @import("../../formats.zig").assigns;
const rules = @import("../../rules.zig");
const entity = @import("../../core.zig").entity;
/// The Classic files' spelling of `classic_id` (script/classic/names.zig).
const id_key = @import("../../script.zig").classic.names.classic(.gameobject, "classic_id");

pub const common_archive = "common/other.dat";

/// `attack`: an enemy's weapon class (`wp_*.ss`, what a battle's `.wpn` includes).
pub const Kind = enum { enemy, weapon, ammo, item, attack, hero };

pub const Entity = struct {
    kind: Kind,
    /// Archive path under `dat` (common_archive or a location's `<level>/other.dat`, in
    /// the list's arena) and its entry.
    archive: []const u8,
    entry: []const u8,
    /// Class without prefix and extension (`garcia`, `stilleto`), or the hero file name;
    /// an attack keeps its `wp_` (`wp_incubus`: enemy classes have the same names).
    id: []const u8,
    name_id: ?i32,
    /// Its identity in the core (rules.Who: the class only in an OpenGorky project).
    who: rules.Who,
    /// The file's text (in the list's arena).
    text: []const u8,
};

/// The core's kind of record for `k`.
pub fn coreKind(k: Kind) entity.Kind {
    return switch (k) {
        .enemy => .enemy,
        .weapon, .attack => .weapon,
        .ammo, .item => .item,
        .hero => .hero,
    };
}

/// Every entity of `dat` (common classes in archive order, then the heroes of the common
/// archive and of `levels`' archives), in `a`.
pub fn scan(io: Io, a: Allocator, dat: Io.Dir, levels: []const []const u8) ![]Entity {
    const gpa = std.heap.page_allocator;
    var out: std.ArrayList(Entity) = .empty;
    var common = try archive.Archive.open(io, gpa, dat, common_archive);
    defer common.close(io, gpa);
    const classes: Classes = .{ .io = io, .a = a, .ar = common };
    for (common.entries) |*e| {
        if (!std.ascii.startsWithIgnoreCase(e.name, "classes\\")) continue;
        const base = e.name["classes\\".len..];
        const kind, const id = classify(base) orelse continue;
        const text = try common.readAlloc(io, a, e);
        // An enemy class names itself only after a look change (its `act_*.ss`).
        const v = if (kind == .enemy or kind == .attack) assigns.inherited(classes, text, id_key, 4) else assigns.get(text, id_key);
        try out.append(a, try make(a, kind, common_archive, e.name, id, v, text));
    }
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(a, common_archive);
    for (levels) |n| try paths.append(a, try std.fmt.allocPrint(a, "{s}/other.dat", .{n}));
    for (paths.items) |p| {
        var own: ?archive.Archive = if (p.ptr == common_archive.ptr) null else (archive.Archive.open(io, gpa, dat, p) catch continue);
        defer if (own) |*o| o.close(io, gpa);
        const ar = if (own) |*o| o else &common;
        for (ar.entries) |*e| {
            if (!std.ascii.endsWithIgnoreCase(e.name, ".hro")) continue;
            const text = try ar.readAlloc(io, a, e);
            const file = e.name[if (std.mem.lastIndexOfScalar(u8, e.name, '\\')) |k| k + 1 else 0..];
            // Battle extras name themselves in their class (medusa.hro → ft_medusa.ss → act_medusa.ss).
            const v = assigns.inherited(classes, text, id_key, 4);
            try out.append(a, try make(a, .hero, p, e.name, file[0 .. file.len - 4], v, text));
        }
    }
    return out.items;
}

/// The class is the file's stem, as rules.classOf names the class it runs.
fn make(a: Allocator, kind: Kind, arc: []const u8, entry: []const u8, id: []const u8, v: ?f32, text: []const u8) !Entity {
    const name_id: ?i32 = if (v) |x| @intFromFloat(x) else null;
    return .{
        .kind = kind,
        .archive = arc,
        .entry = try a.dupe(u8, entry),
        .id = try a.dupe(u8, id),
        .name_id = name_id,
        .who = .{ .id = name_id orelse 0, .class = if (rules.og) try a.dupe(u8, rules.stem(entry)) else "" },
        .text = text,
    };
}

/// `list` as the core's records up front (core/entity.zig `fill`).
pub fn fill(list: []const Entity) Allocator.Error!void {
    var buf: std.ArrayList(entity.Listed) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    for (list) |e| try buf.append(std.heap.page_allocator, .{ .kind = coreKind(e.kind), .who = e.who });
    try entity.fill(buf.items);
}

/// Scans `dat` (the common archive and `levels`') and fills the core's records with it
/// (startup; the list itself is not kept).
pub fn load(io: Io, dat: Io.Dir, levels: []const []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const list = scan(io, arena.allocator(), dat, levels) catch |err| return std.log.warn("entities: {t}", .{err});
    fill(list) catch |err| std.log.warn("entities: {t}", .{err});
}

/// Kind and id of class file `base` (`ft_garcia.ss` → enemy `garcia`); null — not an entity.
pub fn classify(base: []const u8) ?struct { Kind, []const u8 } {
    const kind: Kind = if (prefixed(base, "ft_", ".ss")) .enemy else if (prefixed(base, "cw_", ".s")) .weapon else if (prefixed(base, "ca_", ".s")) .ammo else if (prefixed(base, "ci_", ".s")) .item else if (prefixed(base, "wp_", ".ss") or prefixed(base, "wp_", ".s")) .attack else return null;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.').?;
    return .{ kind, if (kind == .attack) base[0..dot] else base[std.mem.indexOfScalar(u8, base, '_').? + 1 .. dot] };
}

pub fn prefixed(s: []const u8, pre: []const u8, suffix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, pre) and std.ascii.endsWithIgnoreCase(s, suffix) and s.len > pre.len + suffix.len;
}

/// common/other.dat's `classes\` as `assigns.inherited` reads them.
pub const Classes = struct {
    io: Io,
    a: Allocator,
    ar: archive.Archive,
    pub fn read(self: Classes, name: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const e = self.ar.find(std.fmt.bufPrint(&buf, "classes\\{s}", .{name}) catch return null) orelse return null;
        return self.ar.readAlloc(self.io, self.a, e) catch null;
    }
};

test classify {
    const t = std.testing;
    try t.expectEqual(Kind.attack, classify("wp_incubus.ss").?[0]);
    try t.expectEqualStrings("wp_incubus", classify("wp_incubus.ss").?[1]);
    try t.expectEqualStrings("incubus", classify("ft_incubus.ss").?[1]);
    try t.expectEqualStrings("pistol", classify("cw_pistol.s").?[1]);
    try t.expectEqualStrings("wp_timebomb_explode", classify("wp_timebomb_explode.s").?[1]);
    try t.expect(classify("act_incubus.ss") == null);
    try t.expect(classify("wp_.ss") == null);
    // wp_incubus.ss as the game has it: its name and class, no function around them.
    const text = "  nameID=1070;\r\n  funcID=3; // Take\r\n\r\n    two_handed=2;\r\n\r\n    classType = 1008;\r\n    max_damage = 50;\r\n    type = 6;\r\n";
    try t.expectEqual(1070, assigns.get(text, id_key).?);
    try t.expectEqual(1008, assigns.get(text, "classType").?);
}
