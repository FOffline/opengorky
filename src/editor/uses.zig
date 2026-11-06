//! The where-used index: the files the Info blocks and pages search for what names
//! something — each level's scripts, the common scripts and scenes, the models' `.ani`
//! frame sounds — read once as edited (refs.files: the Store's unsaved texts first) and
//! kept until the Store, the language or the levels change (the key info.rows uses).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const refs = @import("refs.zig");
const tx = @import("text.zig");
const common_archive = @import("store.zig").common_archive;
const App = @import("app.zig").App;
const File = refs.File;

/// A level's scripts (`<level>/other.dat`).
pub const Level = struct { name: []const u8, archive: []const u8, files: []const File };

/// A sound on a frame of a model's animation list (`gfx_3d\<model>.ani`).
const Cue = struct { file: []const u8, anim: []const u8, frame: u32, sound: []const u8 };

const Index = struct {
    levels: []const Level = &.{},
    scripts: []const File = &.{},
    scenes: []const File = &.{},
    cues: []const Cue = &.{},

    /// The levels whose scripts have `needle` (case aside).
    pub fn levelsNaming(ix: *const Index, a: Allocator, needle: []const u8) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (ix.levels) |lv| for (lv.files) |f| if (std.ascii.findIgnoreCase(f.text, needle) != null) {
            out.append(a, a.dupe(u8, lv.name) catch break) catch {};
            break;
        };
        return out.items;
    }

    /// The level `name`'s scripts (none: not a level).
    pub fn level(ix: *const Index, name: []const u8) []const File {
        for (ix.levels) |lv| if (std.ascii.eqlIgnoreCase(lv.name, name)) return lv.files;
        return &.{};
    }
};

/// Names of `files` whose text has `needle` (case aside), in their order (copied into
/// `a`: the index goes after an edit).
pub fn naming(a: Allocator, files: []const File, needle: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |f| if (std.ascii.findIgnoreCase(f.text, needle) != null) out.append(a, a.dupe(u8, f.name) catch continue) catch {};
    return out.items;
}

var cache: struct { arena: ?std.heap.ArenaAllocator = null, key: u64 = 0, ix: Index = .{} } = .{};

/// The index as the Store holds the files now (built again after an edit: an undo step;
/// a file only read into the Store has the archive's text).
pub fn get(app: *App) *const Index {
    var h = std.hash.Wyhash.init(app.store.rev);
    h.update(std.mem.asBytes(&app.catalog.gen));
    h.update(std.mem.asBytes(&tx.lang));
    for (app.levels) |lv| h.update(lv.name);
    const key = h.final();
    if (cache.arena != null and cache.key == key) return &cache.ix;
    if (cache.arena) |*ar| _ = ar.reset(.retain_capacity) else cache.arena = .init(app.gpa);
    cache.ix = build(app, cache.arena.?.allocator());
    cache.key = key;
    return &cache.ix;
}

pub fn deinit() void {
    if (cache.arena) |*ar| ar.deinit();
    cache = .{};
}

fn build(app: *App, a: Allocator) Index {
    const levels = a.alloc(Level, app.levels.len) catch return .{};
    for (app.levels, levels) |lv, *o| {
        const archive = std.fmt.allocPrint(a, "{s}/other.dat", .{lv.name}) catch "";
        o.* = .{ .name = lv.name, .archive = archive, .files = refs.files(app, a, archive, refs.script) };
    }
    var cues: std.ArrayList(Cue) = .empty;
    for (refs.files(app, a, common_archive, refs.anim)) |f| {
        const anims = og.formats.anim.parseAni(a, f.text) catch continue;
        for (anims.items) |an| for (an.sounds) |c| cues.append(a, .{ .file = f.name, .anim = an.name, .frame = c.frame - an.first, .sound = c.name }) catch {};
    }
    return .{
        .levels = levels,
        .scripts = refs.files(app, a, common_archive, refs.script),
        .scenes = refs.files(app, a, common_archive, refs.scene),
        .cues = cues.items,
    };
}

test "uses: levels and files naming a needle, case aside, in their order" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const ix: Index = .{
        .levels = &.{
            .{ .name = "01_port", .archive = "01_port/other.dat", .files = &.{ .{ .name = "01_port.lev", .text = "LEVEL_Load(\"02_Museum\");" }, .{ .name = "a.are", .text = "" } } },
            .{ .name = "02_museum", .archive = "02_museum/other.dat", .files = &.{.{ .name = "02_museum.lev", .text = "spriteFile=\"woda1\";" }} },
        },
        .scenes = &.{ .{ .name = "scriptlets\\x.scr", .text = "PLAYVIDEO(\"intro.avi\")" }, .{ .name = "scriptlets\\y.scr", .text = "\"02_museum\"" } },
    };
    const lv = ix.levelsNaming(ar, "\"02_museum\"");
    try std.testing.expectEqual(1, lv.len);
    try std.testing.expectEqualStrings("01_port", lv[0]);
    try std.testing.expectEqual(0, ix.levelsNaming(ar, "nothing").len);
    try std.testing.expectEqualStrings("scriptlets\\y.scr", naming(ar, ix.scenes, "\"02_MUSEUM\"")[0]);
    try std.testing.expectEqual(1, naming(ar, ix.level("02_Museum"), "\"woda1\"").len);
    try std.testing.expectEqual(0, ix.level("03_none").len);
}
