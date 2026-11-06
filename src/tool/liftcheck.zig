//! gorky-tool `lift`: every location started twice, its creation
//! events run as code and as the lifted model (`script/classic/lift.zig`), then `ticks`
//! ticks: every object's variables and the actors' data from the declarative builtins
//! (animation slots, idles, walk speeds, scale, offsets, extra bodies) must be the same.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common = @import("common.zig");
const world_mod = og.state.world;

pub fn run(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8) !void {
    var dat = try common.openDat(io, game_dir);
    defer dat.close(io);
    const levels = try og.formats.archive.levelDirs(io, gpa, dat);
    defer og.formats.archive.freeList(gpa, levels);
    var differ: usize = 0;
    var objects: usize = 0;
    var events: usize = 0;
    var items: usize = 0;
    for (levels) |level| {
        var texts: [2]Io.Writer.Allocating = .{ .init(gpa), .init(gpa) };
        defer for (&texts) |*t| t.deinit();
        for (&texts, [_]bool{ false, true }) |*t, on| {
            const w = og.loaders.world.create(io, gpa, dat, level, null, .{ .lift = on }) catch |err| {
                try t.writer.print("create: {t}\n", .{err});
                continue;
            };
            defer w.destroy();
            for (0..10) |_| try og.game.tick(w);
            try dump(&t.writer, w);
            if (!on) continue;
            objects += w.rt.objects.items.len;
            var it = w.rt.lifted.valueIterator();
            while (it.next()) |l| if (l.l) |x| {
                events += 1;
                items += x.items.len;
            };
        }
        const x = texts[0].written();
        const y = texts[1].written();
        if (std.mem.eql(u8, x, y)) continue;
        differ += 1;
        const at = std.mem.indexOfDiff(u8, x, y).?;
        const line = (std.mem.lastIndexOfScalar(u8, x[0..at], '\n') orelse 0);
        try out.print("{s}: differs at\n  code: {s}\n  lift: {s}\n", .{ level, firstLine(x[line..]), firstLine(y[line..]) });
    }
    try out.print("locations {d}, objects {d}, lifted events run {d} ({d} items): {d} differ\n", .{ levels.len, objects, events, items, differ });
    if (differ > 0) return error.LiftDiffers;
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, s, "\n");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

fn dump(w: *Io.Writer, world: *world_mod.World) !void {
    for (world.rt.objects.items) |o| {
        try w.print("{s} enabled={}\n", .{ o.name, o.enabled });
        var it = o.vars.iterator();
        while (it.next()) |e| try w.print("  {s} {t} {f}\n", .{ og.script.object.nameOf(e.key_ptr.*), e.value_ptr.type, e.value_ptr.value });
        if (!world_mod.isActor(o)) continue;
        const a = world_mod.actorOf(o);
        for (a.mappings.items) |m| try w.print("  map {d} {s} {s}\n", .{ m.state, m.m.logical, m.m.actual });
        for (0..a.idle_count.len) |s| for (a.idle[s][0..a.idle_count[s]]) |i| try w.print("  idle {d} {s} {d} {}\n", .{ s, i.anim, i.weight, i.broken });
        try w.print("  ref {s} notinplace {d} speeds ", .{ a.reference, a.not_in_place.items.len });
        // By the exe's logical names (Classic keeps them by slot, OpenGorky by name).
        for (og.core.classic.look_slots) |e| if (a.speedOf(e.name) != 1) try w.print("{s}={d} ", .{ e.name, a.speedOf(e.name) });
        try w.print("scale {d} offset {any}\n", .{ a.scale_mul, a.render_offset });
        for (a.extra_bodies) |b| if (b) |x| try w.print("  body {s} {}\n", .{ x.mesh, x.still });
    }
}
