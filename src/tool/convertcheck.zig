//! gorky-tool `convert-check <game-dir> <project>`: every
//! location of the Classic game and of its converted project (a folder or its package
//! `dist/<id>.ogp`) started, then 10 ticks: each object of the Classic world must be in the
//! OpenGorky one, enabled alike, with every variable of its class the same (the OG object
//! has more: its schema's fields), and an actor the same animation data. The texts
//! (entity.texts: `string.tab`, `items.inf`, `activeareas.inf`, the language) the same, and
//! the OpenGorky run entered no Classic path (rules.classic_paths). What differs is listed
//! and counted (animation data apart); any difference fails.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common = @import("common.zig");
const world_mod = og.state.world;

/// One object as compared: its lines (`enabled`, `var <name> <value>`, actor data).
const Obj = struct { name: []const u8, lines: []const []const u8 };

/// Every level's objects after start + 10 ticks (null: it failed to start).
const Levels = std.StringArrayHashMapUnmanaged(?[]const Obj);

pub fn run(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, project: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var classic: Levels = .empty;
    {
        var dat = try common.openDat(io, game_dir);
        defer dat.close(io);
        const levels = try og.formats.archive.levelDirs(io, gpa, dat);
        defer og.formats.archive.freeList(gpa, levels);
        for (levels) |l| if (!std.ascii.eqlIgnoreCase(l, "common")) try classic.put(a, try a.dupe(u8, l), try level(io, gpa, a, dat, l));
        _ = og.loaders.loadExamine(io, dat);
    }
    var classic_texts = try copyTexts(a, og.core.entity.texts);
    var dat = try common.openDat(io, project);
    defer dat.close(io);
    // The blocks the converter wrote without a number: the core's number for each (the
    // OG reader's) back to the Classic one (`.og/classic_ids.txt`), on both sides alike.
    const back = try backIds(io, a, project);
    var c: Counts = .{};
    // The Classic texts of no one the converter left out (`!<file>=<number>`).
    try dropTexts(io, a, project, &classic_texts);
    var t = og.core.entity.texts;
    t.map = try remapKeys(a, t.map, back);
    t.examine = try remapKeys(a, t.examine, back);
    t.areas = try remapKeys(a, t.areas, back);
    var shown: usize = 0;
    for ([_][2]Map{ .{ classic_texts.map, t.map }, .{ classic_texts.examine, t.examine }, .{ classic_texts.areas, t.areas } }, [_][]const u8{ "string.tab", "items.inf", "activeareas.inf" }) |pair, file| {
        var it = pair[0].iterator();
        while (it.next()) |e| {
            c.texts += 1;
            const got = pair[1].get(e.key_ptr.*) orelse "(none)";
            if (std.mem.eql(u8, got, e.value_ptr.*)) continue;
            c.texts_differ += 1;
            if (shown < 10) try out.print("{s} {d}: \"{s}\" (converted: \"{s}\")\n", .{ file, e.key_ptr.*, e.value_ptr.*, got });
            shown += 1;
        }
        c.texts_differ += pair[1].count() -| pair[0].count();
    }
    if (classic_texts.language != t.language) c.texts_differ += 1;
    for (classic.keys(), classic.values()) |l, cobjs| {
        const oobjs = try backLines(a, try level(io, gpa, a, dat, l), back);
        const x = cobjs orelse continue;
        const y = oobjs orelse {
            c.levels_failed += 1;
            try out.print("{s}: the converted location does not start\n", .{l});
            continue;
        };
        for (x) |o| {
            c.objects += 1;
            const p = for (y) |q| {
                if (std.ascii.eqlIgnoreCase(q.name, o.name)) break q;
            } else {
                c.missing += 1;
                if (shown < 40) try out.print("{s}: no object {s}\n", .{ l, o.name });
                shown += 1;
                continue;
            };
            for (o.lines) |ln| {
                c.lines += 1;
                if (has(p.lines, ln)) continue;
                if (animLine(ln)) c.anims += 1 else c.differ += 1;
                if (shown < 40) try out.print("{s}: {s}: {s} (converted: {s})\n", .{ l, o.name, std.mem.trim(u8, ln, " "), counterpart(p.lines, ln) });
                shown += 1;
            }
        }
    }
    try out.print("locations {d} ({d} do not start converted), objects {d} ({d} missing), values {d}: {d} differ, animation data {d} differ\n", .{ classic.count(), c.levels_failed, c.objects, c.missing, c.lines, c.differ, c.anims });
    try out.print("texts {d} (language {d}): {d} differ\n", .{ c.texts, t.language, c.texts_differ });
    try out.print("classic paths {d}\n", .{og.rules.classic_paths});
    if (c.levels_failed + c.missing + c.differ + c.anims + c.texts_differ + og.rules.classic_paths > 0) return error.ConvertDiffers;
}

/// Line `ln` is animation data (`  idle <state> <anim> <w>`, `  map <state> <name> <anim>`).
/// The core's number of each block `.og/classic_ids.txt` of `project` lists → its Classic
/// one (none listed: empty).
fn backIds(io: Io, a: Allocator, project: []const u8) !std.AutoHashMapUnmanaged(i32, i32) {
    var out: std.AutoHashMapUnmanaged(i32, i32) = .empty;
    // A package `<project>/dist/<id>.ogp`: its project's folder.
    const dir = if (std.ascii.endsWithIgnoreCase(project, ".ogp")) std.fs.path.dirname(std.fs.path.dirname(project) orelse ".") orelse "." else project;
    var root = Io.Dir.cwd().openDir(io, dir, .{}) catch return out;
    defer root.close(io);
    const text = root.readFileAlloc(io, ".og/classic_ids.txt", a, .limited(1 << 22)) catch return out;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0 or ln[0] == '#') continue;
        const eq = std.mem.lastIndexOfScalar(u8, ln, '=') orelse continue;
        const n = std.fmt.parseInt(i32, ln[eq + 1 ..], 10) catch continue;
        const got = og.core.entity.idOf(ln[0..eq]) orelse continue;
        try out.put(a, got, n);
    }
    return out;
}

/// `texts` without each one `.og/classic_ids.txt` of `project` lists as not written.
fn dropTexts(io: Io, a: Allocator, project: []const u8, texts: anytype) !void {
    const dir = if (std.ascii.endsWithIgnoreCase(project, ".ogp")) std.fs.path.dirname(std.fs.path.dirname(project) orelse ".") orelse "." else project;
    var root = Io.Dir.cwd().openDir(io, dir, .{}) catch return;
    defer root.close(io);
    const text = root.readFileAlloc(io, ".og/classic_ids.txt", a, .limited(1 << 22)) catch return;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0 or ln[0] != '!') continue;
        const eq = std.mem.lastIndexOfScalar(u8, ln, '=') orelse continue;
        const n = std.fmt.parseInt(i32, ln[eq + 1 ..], 10) catch continue;
        const file = ln[1..eq];
        const m = if (std.mem.eql(u8, file, "string.tab")) &texts.map else if (std.mem.eql(u8, file, "items.inf")) &texts.examine else if (std.mem.eql(u8, file, "activeareas.inf")) &texts.areas else continue;
        _ = m.remove(n);
    }
}

fn remapKeys(a: Allocator, m: Map, back: std.AutoHashMapUnmanaged(i32, i32)) !Map {
    if (back.count() == 0) return m;
    var out: Map = .empty;
    var it = m.iterator();
    while (it.next()) |e| try out.put(a, back.get(e.key_ptr.*) orelse e.key_ptr.*, e.value_ptr.*);
    return out;
}

/// `objs` with each number the core made for a block (`back`'s) written as its Classic one.
fn backLines(a: Allocator, objs: ?[]const Obj, back: std.AutoHashMapUnmanaged(i32, i32)) !?[]const Obj {
    const list = objs orelse return null;
    if (back.count() == 0) return list;
    const out = try a.alloc(Obj, list.len);
    for (list, out) |o, *r| {
        const lines = try a.alloc([]const u8, o.lines.len);
        for (o.lines, lines) |ln, *nl| {
            var w: std.Io.Writer.Allocating = .init(a);
            var i: usize = 0;
            while (i < ln.len) {
                if (std.ascii.isDigit(ln[i]) and (i == 0 or !std.ascii.isAlphanumeric(ln[i - 1]))) {
                    var e = i;
                    while (e < ln.len and std.ascii.isDigit(ln[e])) e += 1;
                    const n = std.fmt.parseInt(i32, ln[i..e], 10) catch 0;
                    if (back.get(n)) |c| try w.writer.print("{d}", .{c}) else try w.writer.writeAll(ln[i..e]);
                    i = e;
                } else {
                    try w.writer.writeByte(ln[i]);
                    i += 1;
                }
            }
            nl.* = w.written();
        }
        r.* = .{ .name = o.name, .lines = lines };
    }
    return out;
}

/// The walk speeds other than 1 by the exe's logical names (`walk=5.2 ladder_walk=1.2`):
/// Classic keeps them by slot, OpenGorky by name.
fn speedsText(a: std.mem.Allocator, ac: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    for (og.core.classic.look_slots) |e| {
        const v = ac.speedOf(e.name);
        if (v != 1) try w.writer.print("{s}={d} ", .{ e.name, v });
    }
    return w.written();
}

fn animLine(ln: []const u8) bool {
    const t = std.mem.trimStart(u8, ln, " ");
    return std.mem.startsWith(u8, t, "idle ") or std.mem.startsWith(u8, t, "map ");
}

const Counts = struct { objects: usize = 0, missing: usize = 0, lines: usize = 0, differ: usize = 0, anims: usize = 0, levels_failed: usize = 0, texts: usize = 0, texts_differ: usize = 0 };

const Map = std.AutoHashMapUnmanaged(i32, []const u8);

/// The core's texts copied into `a` (the next game opened replaces them).
fn copyTexts(a: Allocator, t: @TypeOf(og.core.entity.texts)) !@TypeOf(og.core.entity.texts) {
    var out: @TypeOf(og.core.entity.texts) = .{ .language = t.language };
    inline for (.{ "map", "examine", "areas" }) |f| {
        var it = @field(t, f).iterator();
        while (it.next()) |e| try @field(out, f).put(a, e.key_ptr.*, try a.dupe(u8, e.value_ptr.*));
    }
    return out;
}

fn has(lines: []const []const u8, ln: []const u8) bool {
    for (lines) |x| if (std.ascii.eqlIgnoreCase(x, ln)) return true;
    return false;
}

/// The converted object's line of the same variable (`  var hp …`), else "none".
fn counterpart(lines: []const []const u8, ln: []const u8) []const u8 {
    const key_end = if (std.mem.startsWith(u8, ln, "  var ")) (std.mem.indexOfScalarPos(u8, ln, 6, ' ') orelse ln.len) + 1 else return "-";
    for (lines) |x| if (x.len >= key_end and std.ascii.eqlIgnoreCase(x[0..key_end], ln[0..key_end])) return std.mem.trim(u8, x, " ");
    return "none";
}

/// Object `o`'s schema host: its Classic class's base class, an OpenGorky block's kind's.
fn hostOf(o: *og.script.object.Object) ?*const og.core.schema.Host {
    if (o.class.host) |h| return og.core.schema.host(@tagName(h));
    var c: ?*og.script.object.Class = o.class;
    while (c) |x| : (c = x.parent) if (og.core.schema.host(x.name)) |h| return h;
    return null;
}

/// `v` is a variable's initial value: 0, 0.0, "", nil.
fn initial(v: og.script.value.Value) bool {
    return switch (v) {
        .int => |x| x == 0,
        .float => |x| x == 0,
        .string => |x| x.len == 0,
        .nil => true,
        else => false,
    };
}

/// A fighter that is no hero (its `armor` a class, a hero's points).
fn monster(o: *og.script.object.Object) bool {
    const n = world_mod.World.nativeOf(o);
    return og.fields.isFighter(o) and !n.hero and !n.hro;
}

/// Level `l` started and ticked 10 times: its objects as lines (in `a`).
fn level(io: Io, gpa: Allocator, a: Allocator, dat: Io.Dir, l: []const u8) !?[]const Obj {
    const w = og.loaders.world.create(io, gpa, dat, l, null, .{}) catch return null;
    defer w.destroy();
    for (0..10) |_| og.game.tick(w) catch return null;
    var objs: std.ArrayList(Obj) = .empty;
    for (w.rt.objects.items) |o| {
        // An empty ammo pack (the exe's ready one; the converter writes none): no object to compare.
        if (og.inventory.item.emptyPack(o)) continue;
        var lines: std.ArrayList([]const u8) = .empty;
        try lines.append(a, try std.fmt.allocPrint(a, "  enabled {}", .{o.enabled}));
        const host = hostOf(o);
        var it = o.vars.iterator();
        while (it.next()) |e| {
            const n = og.script.object.nameOf(e.key_ptr.*);
            // A value OpenGorky does not carry (schema `Field.dropped`: no reader).
            if (host) |h| if (og.core.schema.field(h, n)) |fd| if (fd.dropped) continue;
            // A variable at its initial value: one absent reads as that (the converter leaves
            // out the unread ones: unread_vars, a field of another kind).
            if (initial(e.value_ptr.value)) continue;
            // A monster's armour class past 0-2 cuts nothing: `none` (the converter writes it so).
            if (std.mem.eql(u8, n, "armor") and e.value_ptr.value == .int and (e.value_ptr.value.int < 0 or e.value_ptr.value.int > 2) and monster(o)) {
                try lines.append(a, "  var armor none");
                continue;
            }
            // A fighter class by its name (an OpenGorky project's are its own names).
            if (std.mem.eql(u8, n, "battle_class") and e.value_ptr.value == .int) if (og.rules.fighterClassName(e.value_ptr.value.int)) |cn| {
                try lines.append(a, try std.fmt.allocPrint(a, "  var battle_class {s}", .{cn}));
                continue;
            };
            // A weapon class by its name (an OpenGorky project numbers its classes itself).
            if (std.mem.eql(u8, n, "class") and e.value_ptr.value == .int) if (og.rules.weaponClassName(e.value_ptr.value.int)) |cn| {
                try lines.append(a, try std.fmt.allocPrint(a, "  var class {s}", .{cn}));
                continue;
            };
            try lines.append(a, try std.fmt.allocPrint(a, "  var {s} {f}", .{ n, e.value_ptr.value }));
        }
        if (world_mod.isActor(o)) {
            const ac = world_mod.actorOf(o);
            for (ac.mappings.items) |m| try lines.append(a, try std.fmt.allocPrint(a, "  map {d} {s} {s}", .{ m.state, m.m.logical, m.m.actual }));
            for (0..ac.idle_count.len) |s| for (ac.idle[s][0..ac.idle_count[s]]) |i| try lines.append(a, try std.fmt.allocPrint(a, "  idle {d} {s} {d}", .{ s, i.anim, i.weight }));
            try lines.append(a, try std.fmt.allocPrint(a, "  actor ref {s} notinplace {d} speeds {s} scale {d}", .{ ac.reference, ac.not_in_place.items.len, try speedsText(a, ac), ac.scale_mul }));
        }
        try objs.append(a, .{ .name = try a.dupe(u8, o.name), .lines = lines.items });
    }
    return objs.items;
}
