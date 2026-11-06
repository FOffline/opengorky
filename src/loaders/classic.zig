//! The Classic loader: the original game's files into the core. A game folder (`dat/`
//! and its archives, adjust.kdt) opened with the built-in rules (the exe's) and its
//! globals; string.tab as the classic_id texts, the classes and heroes as the core's
//! records (entities), the examine texts. The worlds read the rest as they open
//! (loaders/world.zig), the scripts the runtime (script/runtime.zig).

const std = @import("std");
const Io = std.Io;
const archive = @import("../formats.zig").archive;
const strtab = @import("../formats.zig").strtab;
const adjust = @import("../formats.zig").adjust;
const rules = @import("../rules.zig");
const entity = @import("../core.zig").entity;
const modules = @import("../core.zig").modules;
const core_adjust = rules.adjust;
/// The game's classes and heroes as the core's records up front.
pub const entities = @import("classic/entities.zig");

/// Folder `path` has a `dat` folder: it looks like the original game's.
pub fn probe(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer d.close(io);
    var dat = d.openDir(io, "dat", .{}) catch return false;
    dat.close(io);
    return true;
}

/// Game folder `root` opened (loaders.openGame): the built-in rules, adjust.kdt as the
/// globals, no OpenGorky battle starts; its `dat` (iterable).
pub fn open(io: Io, root: Io.Dir) !Io.Dir {
    rules.reset();
    loadAdjust(io, root);
    modules.starts = &.{};
    return root.openDir(io, "dat", .{ .iterate = true });
}

/// string.tab as the core's classic_id registry; borrowed: `t` must outlive it unchanged
/// (null: no names).
fn setTexts(t: ?*const strtab.Table) void {
    const keep = entity.texts;
    entity.useTexts(if (t) |x| .{ .map = x.map, .language = strtab.language(x.*), .examine = keep.examine, .areas = keep.areas } else .{});
}

/// `items.inf` and `activeareas.inf` of `<dat>/common/lang.dat` as the core's examine
/// texts (entity.texts), read once at startup and kept for the process; false: no
/// `items.inf` (none set).
pub fn loadExamine(io: Io, dat: Io.Dir) bool {
    const gpa = std.heap.page_allocator;
    var ar = archive.Archive.open(io, gpa, dat, "common/lang.dat") catch return false;
    defer ar.close(io, gpa);
    const a = examine_arena.allocator();
    const items = ar.readAlloc(io, a, ar.find("items.inf") orelse return false) catch return false;
    const t = strtab.parseExamine(gpa, a, items) catch return false;
    entity.texts.examine = t.map;
    if (ar.find("activeareas.inf")) |e| if (ar.readAlloc(io, a, e)) |b| {
        entity.texts.areas = (strtab.parseExamineKey(gpa, a, b, "AREA_EXAMINE:") catch strtab.Table{}).map;
    } else |_| {};
    return true;
}

/// loadExamine's texts (never freed: the process's).
var examine_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// The game's adjust.kdt as the core's globals (rules.adjust), read at startup after
/// the rules; the exe reads it too (0x418120), so a mod's edits there reach both.
/// `<root>/adjust.kdt`; missing: the globals stay as they were, broken: none (every value
/// the shipped default). OpenGorky: the rules' Setting rows are the globals (rules.use).
fn loadAdjust(io: Io, root: Io.Dir) void {
    const gpa = std.heap.page_allocator;
    const bytes = root.readFileAlloc(io, "adjust.kdt", gpa, .limited(1 << 20)) catch return;
    defer gpa.free(bytes);
    core_adjust.clear();
    var f = adjust.parse(gpa, bytes) catch return;
    defer f.deinit(gpa);
    var it = f.values.iterator();
    while (it.next()) |e| core_adjust.put(e.key_ptr.*, switch (e.value_ptr.*) {
        inline else => |v, tag| @unionInit(core_adjust.Value, @tagName(tag), v),
    }) catch return;
}

/// The original's core (loaders.loadCore): the classic_id texts (loadTexts), then the
/// game's classes and heroes as the core's records (they take their names from the texts).
pub fn loadCore(io: Io, dat: Io.Dir) void {
    rules.classicPath("loaders.classic.loadCore: string.tab, the Classic records");
    loadTexts(io, dat);
    const gpa = std.heap.page_allocator;
    const levels = archive.levelDirs(io, gpa, dat) catch &.{};
    defer archive.freeList(gpa, levels);
    entities.load(io, dat, levels);
}

/// string.tab of `<dat>/common/lang.dat` as the core's classic_id texts and language
/// (entity.texts), read once at startup (loadCore; the editor: again when its catalog is
/// read again). Missing: the texts stay as they were.
pub fn loadTexts(io: Io, dat: Io.Dir) void {
    const gpa = std.heap.page_allocator;
    var ar = archive.Archive.open(io, gpa, dat, "common/lang.dat") catch return;
    defer ar.close(io, gpa);
    const bytes = ar.readAlloc(io, gpa, ar.find("string.tab") orelse return) catch return;
    const table = strtab.parseStrings(gpa, bytes) catch return gpa.free(bytes);
    const old = texts_table;
    const old_bytes = texts_bytes;
    texts_table = table;
    texts_bytes = bytes;
    setTexts(&texts_table.?);
    if (old) |o| {
        var t = o;
        t.deinit(gpa);
        gpa.free(old_bytes);
    }
}

/// loadTexts' table; null before it or without a string.tab. Valid until the next loadTexts.
pub fn textTable() ?*const strtab.Table {
    return if (texts_table) |*t| t else null;
}

/// loadTexts' table and the text it points into (kept until the next loadTexts).
var texts_table: ?strtab.Table = null;
var texts_bytes: []u8 = &.{};

test {
    _ = entities;
}
