//! gorky-tool `convert <game-dir> <out-dir>`: the game as a new
//! OpenGorky project (compose/convert.zig), its progress a line a step; converted a second
//! time beside it, the two the same bytes (main.zig then builds it).
//!
//! gorky-tool `convert <game-dir> --code [--stats]`: every
//! class function of the game converted to OG Script (`script/classic/ogsify.zig`): the
//! classes of a level archive as the components of module `locations::<level>` (a battle:
//! `battles::<battle>`), the base classes others `#inherit` as `base` (components/base.ogs),
//! the other common ones as `classes`. Each text is parsed back and the whole program
//! linked. Each function then runs as its Classic IR and as its translation, on objects of
//! its class with the same arguments and the same builtin answers (stubs that record their
//! calls, from one seed per run; `seeds` runs a function): the results, the object's
//! variables and the builtin calls must be the same. Prints the texts (`--stats`: only the
//! counts), the conversion's counts and the `classic::` forms left, by form and by name.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common_mod = @import("common.zig");
const archive = og.formats.archive;
const script = og.script;
const ir = script.ir;
const ogsify = script.classic.ogsify;
const Runtime = script.runtime.Runtime;
const Value = script.value.Value;
const Object = script.object.Object;

/// The game `game_dir` converted into the new folder `out_dir` (refused if it has
/// anything), then again into `<out_dir>.again`: every file the same (that copy removed).
/// `installed_dir`: the installed game the project reads, when `game_dir` is a modded copy
/// of it (its new and changed assets go to `src/assets/`); null: `game_dir` itself.
pub fn project(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, out_dir: []const u8, installed_dir: ?[]const u8) !void {
    var dat = try common_mod.openDat(io, game_dir);
    defer dat.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rules = try og.compose.rulesFiles(a);
    const cwd = Io.Dir.cwd();
    var gb: [std.fs.max_path_bytes]u8 = undefined;
    var game = try cwd.openDir(io, installed_dir orelse game_dir, .{});
    const game_path = try a.dupe(u8, gb[0..try game.realPath(io, &gb)]);
    game.close(io);
    // Its archives only (not openGame: the rules in force stay the converted game's).
    var inst: ?Io.Dir = if (installed_dir) |d| try cwd.openDir(io, try std.fmt.allocPrint(a, "{s}/dat", .{d}), .{ .iterate = true }) else null;
    defer if (inst) |*d| d.close(io);
    const again = try std.fmt.allocPrint(a, "{s}.again", .{out_dir});
    for ([_][]const u8{ out_dir, again }, 0..) |dir, pass| {
        try newFolder(io, cwd, dir);
        var d = try cwd.openDir(io, dir, .{});
        defer d.close(io);
        var pa: std.heap.ArenaAllocator = .init(gpa);
        defer pa.deinit();
        var line: Line = .{ .out = out, .on = pass == 0 };
        const r = try og.compose.convert.run(io, pa.allocator(), dat, d, .{ .id = og.compose.convert.game_id, .title = og.compose.convert.game_title, .game = game_path, .rules = rules, .installed = inst }, .{ .ctx = &line, .on = Line.tell });
        if (pass > 0) continue;
        for (r.lines.items) |l| try out.print("  {s}\n", .{l});
        try og.compose.convert.statsLine(out, &r);
        try out.writeAll("\n");
    }
    const differ = try sameTree(io, a, cwd, out_dir, again);
    try cwd.deleteTree(io, again);
    if (differ) |path| {
        try out.print("FAIL convert: a second conversion differs: {s}\n", .{path});
        return error.CheckFailed;
    }
    try out.writeAll("OK   convert: a second conversion gives the same bytes\n");
}

/// The progress as one line a step (and every tenth of a counted one).
const Line = struct {
    out: *Io.Writer,
    on: bool,
    last: usize = std.math.maxInt(usize),

    fn tell(ctx: ?*anyopaque, step: og.compose.convert.Step, done: usize, total: usize) void {
        const self: *Line = @ptrCast(@alignCast(ctx.?));
        if (!self.on) return;
        const tenth = if (total > 0) done * 10 / total else done / 25;
        if (tenth == self.last and done != total) return;
        self.last = tenth;
        if (total > 0) self.out.print("convert: {t} {d}/{d}\n", .{ step, done, total }) catch {} else self.out.print("convert: {t} {d}\n", .{ step, done }) catch {};
        self.out.flush() catch {};
    }
};

/// `path` made; refused if it exists with anything in it (a new folder).
fn newFolder(io: Io, cwd: Io.Dir, path: []const u8) !void {
    try cwd.createDirPath(io, path);
    var d = try cwd.openDir(io, path, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    if (try it.next(io) != null) return error.FolderNotEmpty;
}

/// The first file of `x` that `y` lacks or has other bytes of (and of `y` that `x` lacks).
fn sameTree(io: Io, a: Allocator, cwd: Io.Dir, x: []const u8, y: []const u8) !?[]const u8 {
    var dx = try cwd.openDir(io, x, .{ .iterate = true });
    defer dx.close(io);
    var dy = try cwd.openDir(io, y, .{ .iterate = true });
    defer dy.close(io);
    var n: [2]usize = .{ 0, 0 };
    for ([_]Io.Dir{ dx, dy }, 0..) |d, k| {
        var w = try d.walk(a);
        defer w.deinit();
        while (try w.next(io)) |e| {
            if (e.kind != .file) continue;
            n[k] += 1;
            if (k == 1) continue;
            const p = try a.dupe(u8, e.path);
            const bx = try dx.readFileAlloc(io, p, a, .limited(64 << 20));
            const by = dy.readFileAlloc(io, p, a, .limited(64 << 20)) catch return p;
            if (!std.mem.eql(u8, bx, by)) return p;
        }
    }
    if (n[0] != n[1]) return "(the file counts)";
    return null;
}

/// Runs per function, each with its own seed.
const seeds = 4;

/// Script sources of one archive: its own entries, then `common/other.dat` (as roundtrip).
const Sources = struct {
    io: Io,
    a: Allocator,
    local: *const archive.Archive,
    common: *const archive.Archive,

    fn fetch(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
        const self: *Sources = @ptrCast(@alignCast(ctx));
        if (self.local.find(name)) |e| return try self.local.readAlloc(self.io, self.a, e);
        var buf: [archive.name_size]u8 = undefined;
        for ([_][]const u8{ "classes", "scriptlets", "gamestart" }) |dir| {
            const path = try std.fmt.bufPrint(&buf, "{s}\\{s}", .{ dir, name });
            if (self.common.find(path)) |e| return try self.common.readAlloc(self.io, self.a, e);
        }
        return null;
    }
};

/// The builtins' calls of one run (the ones with effects, in order) and the run's seed.
const Rec = struct {
    log: Io.Writer.Allocating,
    seed: u64 = 0,
    line: Io.Writer.Allocating,

    fn deinit(self: *Rec) void {
        self.log.deinit();
        self.line.deinit();
    }

    fn reset(self: *Rec, seed: u64) void {
        self.log.clearRetainingCapacity();
        self.seed = seed;
    }
};

const Stub = struct { rec: *Rec, name: []const u8, ogs: []const u8, sig: script.runtime.Sig, real: *const fn (*anyopaque, *Runtime, *Object, []const Value) anyerror!Value };

/// A builtin: its call by its OGS name (`"this"` as the caller's name, as the handlers
/// take it), written down if it has effects; its answer a function of the run's seed and
/// the call (the same call, the same answer), of its result type. The string compares
/// answer as themselves; `GetName` the caller's name and `Disable` acts on an actor only,
/// as OGS writes them (`host.name`, `object::Disable(host)`).
fn stub(ctx: *anyopaque, rt: *Runtime, obj: *Object, args: []const Value) anyerror!Value {
    const s: *Stub = @ptrCast(@alignCast(ctx));
    if (std.ascii.eqlIgnoreCase(s.name, "GetName")) return .{ .string = obj.name };
    if (std.ascii.eqlIgnoreCase(s.name, "s_stricmp") or std.mem.eql(u8, s.name, "EqualsIgnoreCase")) return s.real(ctx, rt, obj, args);
    const w = &s.rec.line.writer;
    s.rec.line.clearRetainingCapacity();
    if (std.ascii.eqlIgnoreCase(s.name, "Disable")) {
        if (!isActor(obj.class.name)) return .zero;
        try w.print("object::Disable(\"{s}\")\n", .{obj.name});
    } else {
        try w.print("{s}(", .{s.ogs});
        for (args, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            if (i == 0 and s.sig.this and v == .string and std.ascii.eqlIgnoreCase(v.string, "this")) try w.print("\"{s}\"", .{obj.name}) else try w.print("{f}", .{v});
        }
        try w.writeAll(")\n");
    }
    if (!s.sig.pure) try s.rec.log.writer.writeAll(s.rec.line.written());
    const h = std.hash.Wyhash.hash(s.rec.seed, s.rec.line.written());
    const t = s.sig.text;
    if (std.mem.startsWith(u8, t, "bool(")) return .{ .int = @intCast(h % 2) };
    const k: i32 = @intCast(h % 6);
    if (std.mem.startsWith(u8, t, "int(") or k < 3) return .{ .int = k - 1 };
    if (k == 3) return .{ .float = 1.5 };
    return .{ .string = if (k == 4) "s" else "" };
}

/// `classes\\Item.s` → `Item.s` (archive names use backslashes).
fn baseName(entry: []const u8) []const u8 {
    return entry[if (std.mem.lastIndexOfScalar(u8, entry, '\\')) |k| k + 1 else 0..];
}

fn isActor(file: []const u8) bool {
    return og.state.object.kindOf(std.fs.path.extension(file)) == .actor;
}

/// Every builtin as a stub recording into `rec`.
fn registerStubs(rt: *Runtime, a: Allocator, rec: *Rec) !void {
    inline for (og.builtins.table) |e| {
        const s = try a.create(Stub);
        s.* = .{ .rec = rec, .name = e[0], .ogs = if (e[2].ogs.len > 0) e[2].ogs else e[0], .sig = e[2], .real = e[1] };
        try rt.registerBuiltinSig(e[0], s, stub, e[2]);
    }
}

/// The OGS host kind of a Classic class: its schema host's (`core/schema.zig`, the data
/// blocks' kinds), a path's, else any object.
fn kindOf(a: Allocator, cls: *const script.object.Class, file: []const u8) ![]const u8 {
    const names = try a.alloc([]const u8, cls.vars.items.len);
    for (cls.vars.items, names) |d, *n| n.* = d.name;
    const table = [_][2][]const u8{
        .{ "combatlevel", "battle" }, .{ "level", "level" },          .{ "fighter", "fighter" },                   .{ "weapon", "weapon" },   .{ "actor", "actor" },
        .{ "item", "item" },          .{ "bitmapanimation", "anim" }, .{ "activebitmapanimation", "active_anim" }, .{ "activearea", "area" },
    };
    if (og.core.schema.hostOf(names)) |h| for (table) |t| if (std.mem.eql(u8, t[0], h.name)) return t[1];
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(file), ".pth")) return "path";
    return "object";
}

/// One class converted: what the differential run needs.
const Conv = struct {
    entry: []const u8,
    /// The object's name: the file's stem (Classic names an object by its file).
    obj: []const u8,
    comp: *const ir.Component,
    /// Its own functions' IR: the component's first methods (then merged events).
    fns: []const *const ir.Fn,
};

/// One archive: its module and its classes.
const Text = struct { file: []const u8, module: []const u8, convs: []const Conv, path: []const u8, kept: *Kept };

/// An archive's Classic runtime (its classes and their IR).
const Kept = struct { arc: archive.Archive, sources: Sources, rec: Rec, rt: Runtime };

const Counts = std.StringArrayHashMapUnmanaged(usize);

pub fn run(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, stats_only: bool) !void {
    var dat = try common_mod.openDat(io, game_dir);
    defer dat.close(io);
    const archives = try archive.listArchives(io, gpa, dat);
    defer archive.freeList(gpa, archives);
    var common = try archive.Archive.open(io, gpa, dat, "common/other.dat");
    defer common.close(io, gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var stats: ogsify.Stats = .{};
    var texts: std.ArrayList(Text) = .empty;
    // Classes some class inherits (lower-case): the common ones go to `base`.
    var bases: std.StringHashMapUnmanaged(void) = .empty;
    var class_errors: usize = 0;
    var included: usize = 0;
    var diff: Diff = .{ .out = out };
    var kept: std.ArrayList(*Kept) = .empty;
    defer for (kept.items) |k| {
        k.rt.deinit();
        k.rec.deinit();
        k.arc.close(io, gpa);
    };
    for (archives) |path| {
        // Kept to the end: the IR and the texts point into them.
        const k = try a.create(Kept);
        k.arc = try archive.Archive.open(io, gpa, dat, path);
        k.sources = .{ .io = io, .a = a, .local = &k.arc, .common = &common };
        k.rec = .{ .log = .init(gpa), .line = .init(gpa) };
        k.rt = .init(gpa, .{ .ctx = &k.sources, .fetch = Sources.fetch });
        try kept.append(a, k);
        const rt = &k.rt;
        rt.lift = false;
        try registerStubs(rt, a, &k.rec);
        const arc = &k.arc;
        const dir = std.fs.path.dirname(path) orelse path;
        const is_common = std.mem.eql(u8, dir, "common");
        const level_ns = if (std.mem.indexOf(u8, dir, "__") != null) "battles" else "locations";
        const module = if (is_common) "classes" else try std.fmt.allocPrint(a, "{s}::{s}", .{ level_ns, try ogsify.ident(a, dir) });
        var convs: std.ArrayList(Conv) = .empty;
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        for (arc.entries) |*e| {
            if (!og.formats.resource.isScript(e.name) or std.ascii.endsWithIgnoreCase(e.name, ".ss")) continue;
            const cls = rt.loadClass(e.name) catch |err| {
                class_errors += 1;
                try out.print("{s}: {s}: class: {t}\n", .{ path, e.name, err });
                continue;
            };
            var p = cls.parent;
            while (p) |x| : (p = x.parent) try bases.put(a, try a.dupe(u8, baseName(x.name)), {});
            const stem = std.fs.path.stem(baseName(e.name));
            var name = try ogsify.ident(a, stem);
            if (taken.contains(name)) name = try std.fmt.allocPrint(a, "{s}_{s}", .{ name, try ogsify.ident(a, std.fs.path.extension(e.name)[1..]) });
            try taken.put(a, name, {});
            const oc = try ogsify.classOf(a, rt, cls, e.name, name, try kindOf(a, cls, e.name), isActor(e.name));
            var own: std.ArrayList(*const ir.Fn) = .empty;
            for (oc.methods) |m| if (m.own) {
                try own.append(a, m.f);
                if (!std.ascii.eqlIgnoreCase(m.f.file, e.name)) included += 1;
            } else try bases.put(a, try a.dupe(u8, baseName(m.f.file)), {});
            const comp = try ogsify.component(a, &oc, rt.builtinNames(), &stats);
            // A class without functions is data only.
            if (comp.methods.len == 0) continue;
            try convs.append(a, .{ .entry = e.name, .obj = stem, .comp = comp, .fns = own.items });
        }
        if (convs.items.len == 0) continue;
        const file = if (is_common) "components/classes.ogs" else try std.fmt.allocPrint(a, "{s}/{s}/logic.ogs", .{ level_ns, dir });
        try texts.append(a, .{ .file = file, .module = module, .convs = convs.items, .path = path, .kept = k });
    }
    // The base classes out of `classes`.
    for (texts.items) |*t| {
        if (!std.mem.eql(u8, t.module, "classes")) continue;
        var rest: std.ArrayList(Conv) = .empty;
        var base: std.ArrayList(Conv) = .empty;
        for (t.convs) |c| try (if (bases.contains(try std.ascii.allocLowerString(a, baseName(c.entry)))) &base else &rest).append(a, c);
        t.convs = rest.items;
        try texts.append(a, .{ .file = "components/base.ogs", .module = "base", .convs = base.items, .path = t.path, .kept = t.kept });
        break;
    }

    // Texts: printed, parsed back, linked as one program.
    var all_rec: Rec = .{ .log = .init(gpa), .line = .init(gpa) };
    defer all_rec.deinit();
    var none: Sources = .{ .io = io, .a = a, .local = &common, .common = &common };
    var all: Runtime = .init(gpa, .{ .ctx = &none, .fetch = Sources.fetch });
    defer all.deinit();
    try registerStubs(&all, a, &all_rec);
    var printed: std.ArrayList([]const u8) = .empty;
    var parse_failed: usize = 0;
    for (texts.items) |t| {
        const comps = try a.alloc(*const ir.Component, t.convs.len);
        for (t.convs, comps) |c, *x| x.* = c.comp;
        const src = try ogsify.text(a, t.module, comps);
        try printed.append(a, src);
        if (!stats_only) try out.print("=== {s}\n{s}", .{ t.file, src });
        all.addOgs(t.file, src) catch |err| {
            parse_failed += 1;
            try out.print("{s}:{d}: {s} ({t})\n", .{ t.file, all.diag.line, all.diag.message, err });
        };
    }
    var link_failed: usize = 0;
    while (true) {
        all.linkOgs() catch |err| {
            if (err == error.OutOfMemory) return err;
            link_failed += 1;
            try out.print("{s}:{d}: {s}\n", .{ all.diag.file, all.diag.line, all.diag.message });
            continue;
        };
        break;
    }

    // Each function: Classic IR and translation, on the same inputs.
    for (texts.items, printed.items) |t, src| {
        if (t.convs.len == 0) continue;
        try diff.archive(gpa, a, &t.kept.sources, t, src);
    }

    // Counts.
    try out.print("classes {d} (class errors {d}), functions {d} ({d} of their own files, {d} of top-level #include), texts {d}; parse failed {d}, link failed {d}\n", .{ diff.classes, class_errors, stats.functions, stats.functions - included, included, texts.items.len, parse_failed, link_failed });
    try out.print("differential: {d} runs ({d} seeds a function), {d} differ\n", .{ diff.runs, seeds, diff.differ });
    try out.print("events renamed {d} (parameters added {d}, merged {d}), return 0 added {d}, fields {d}, this {d}, undeclared assignments dropped {d}, calls of nothing {d}, inherited inlined {d}, on host {d}, bool as int {d}\n", .{ stats.events, stats.padded, stats.merged, stats.returns, stats.fields, stats.this, stats.dropped, stats.unknown_calls, stats.inlined, stats.host_calls, stats.bool_ints });
    try out.writeAll("quirks made plain:");
    for (std.enums.values(ogsify.Form)) |k| if (stats.clean.get(k) > 0) try out.print(" {t} {d}", .{ k, stats.clean.get(k) });
    try out.writeAll("\n");
    // What is left, from the texts themselves.
    var forms: Counts = .empty;
    var names: Counts = .empty;
    var total: usize = 0;
    for (printed.items) |src| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, src, i, "classic::")) |k| {
            i = k + "classic::".len;
            const end = std.mem.indexOfScalarPos(u8, src, i, '(') orelse continue;
            try bump(a, &forms, src[i..end]);
            total += 1;
            if (std.mem.eql(u8, src[i..end], "name") or std.mem.eql(u8, src[i..end], "maybe")) {
                const close = std.mem.indexOfScalarPos(u8, src, end, ')') orelse continue;
                try bump(a, &names, src[end + 1 .. close]);
            }
        }
    }
    try out.print("classic:: left {d}:", .{total});
    for (forms.keys(), forms.values()) |k, v| try out.print(" {s} {d}", .{ k, v });
    try out.writeAll("\nclassic::name by name:");
    for (names.keys(), names.values()) |k, v| try out.print(" {s} {d}", .{ k, v });
    try out.writeAll("\n");
    if (class_errors > 0 or parse_failed > 0 or link_failed > 0 or diff.differ > 0) return error.Convert;
}

fn bump(a: Allocator, c: *Counts, key: []const u8) !void {
    const gop = try c.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

/// The differential runs.
const Diff = struct {
    out: *Io.Writer,
    classes: usize = 0,
    runs: usize = 0,
    differ: usize = 0,
    /// Seeds handed out so far.
    seed: u64 = 0,

    /// The classes of text `t` (`src`): Classic in one runtime, the translation in another.
    fn archive(self: *Diff, gpa: Allocator, a: Allocator, sources: *Sources, t: Text, src: []const u8) !void {
        var rec_a: Rec = .{ .log = .init(gpa), .line = .init(gpa) };
        defer rec_a.deinit();
        var rec_b: Rec = .{ .log = .init(gpa), .line = .init(gpa) };
        defer rec_b.deinit();
        var ra: Runtime = .init(gpa, .{ .ctx = sources, .fetch = Sources.fetch });
        defer ra.deinit();
        var rb: Runtime = .init(gpa, .{ .ctx = sources, .fetch = Sources.fetch });
        defer rb.deinit();
        ra.lift = false;
        rb.lift = false;
        try registerStubs(&ra, a, &rec_a);
        try registerStubs(&rb, a, &rec_b);
        rb.loadOgs(t.file, src) catch |err| {
            self.differ += 1;
            return self.out.print("{s}: {s}:{d}: {s} ({t})\n", .{ t.file, rb.diag.file, rb.diag.line, rb.diag.message, err });
        };
        for (t.convs) |c| {
            self.classes += 1;
            const ca = try ra.loadClass(c.entry);
            const cb = try rb.loadClass(c.entry);
            const comp = (try rb.ogs.component(a, null, try std.fmt.allocPrint(a, "{s}::{s}", .{ t.module, c.comp.name }))).?;
            for (c.fns, comp.methods[0..c.fns.len]) |f, m| for (0..seeds) |_| {
                self.seed += 1;
                self.runs += 1;
                const oa = try ra.createObject(c.obj, ca);
                const ob = try rb.createObject(c.obj, cb);
                const inst = try rb.attach(ob, comp, &.{});
                // The object's variables from the seed too (every branch on them gets its turn).
                for (oa.vars.keys(), oa.vars.values()) |id, *v| {
                    v.value = varOf(self.seed, id, v.type, c.obj);
                    ob.getVarId(id).?.value = v.value;
                }
                var args_buf: [16]Value = undefined;
                var rng: std.Random.DefaultPrng = .init(self.seed *% 7919);
                const args = args_buf[0..@min(f.params.len, args_buf.len)];
                for (args, f.params[0..args.len]) |*v, p| v.* = argOf(rng.random(), p.type, c.obj);
                rec_a.reset(self.seed);
                const va = ra.callIfExists(oa, f.name, args);
                rec_b.reset(self.seed);
                const vb = rb.callIfExists(inst, m.name, args);
                if (try why(a, va, vb, oa, ob, &rec_a, &rec_b, &rb, c.comp.hosts[0], m.name)) |what| {
                    self.differ += 1;
                    if (self.differ <= 40) try self.out.print("{s}: {s}: {s} (seed {d}): {s}\n", .{ t.path, c.entry, f.name, self.seed, what });
                }
            };
        }
    }
};

/// What differs between a Classic run (`va`, `oa`, `ra`) and its translation's (`vb`,
/// `ob`, `rb`; method `name` of a component for `kind`), or null.
fn why(a: Allocator, va: anyerror!?Value, vb: anyerror!?Value, oa: *Object, ob: *Object, ra: *Rec, rb: *Rec, rtb: *Runtime, kind: []const u8, name: []const u8) !?[]const u8 {
    const x = va catch |ea| {
        if (vb) |_| return try std.fmt.allocPrint(a, "Classic {t}, OGS ran", .{ea}) else |eb| if (eb != ea) return try std.fmt.allocPrint(a, "Classic {t}, OGS {t}", .{ ea, eb });
        return null;
    };
    const y = vb catch |eb| return try std.fmt.allocPrint(a, "OGS {t} ({s}:{d}: {s})", .{ eb, rtb.fault.file, rtb.fault.line, rtb.fault.message });
    if (x == null or y == null) return "not called";
    // An event whose result nobody reads may give nil.
    const unused = if (script.traits.lookup(script.traits.ofHost(kind).?, name)) |em| em.combine == .all else false;
    if (!(y.? == .nil and unused) and !ir.sameSkipping(Value, x.?, y.?, &.{})) return try std.fmt.allocPrint(a, "result {f} / {f}", .{ x.?, y.? });
    for (oa.vars.keys(), oa.vars.values()) |id, v| {
        const w = ob.getVarId(id) orelse return "variable missing";
        if (!ir.sameSkipping(Value, v.value, w.value, &.{})) return try std.fmt.allocPrint(a, "{s} = {f} / {f}", .{ script.object.nameOf(id), v.value, w.value });
    }
    if (!std.mem.eql(u8, ra.log.written(), rb.log.written())) return try std.fmt.allocPrint(a, "calls:\n{s}--- OGS:\n{s}", .{ ra.log.written(), rb.log.written() });
    return null;
}

/// A value of an object variable `id` of type `t` for run `seed`.
fn varOf(seed: u64, id: u32, t: ir.Type, obj: []const u8) Value {
    var rng: std.Random.DefaultPrng = .init(seed *% 31 +% id);
    return argOf(rng.random(), t, obj);
}

/// An argument of a parameter of type `t`, from `r`.
fn argOf(r: std.Random, t: ir.Type, obj: []const u8) Value {
    const k = r.uintLessThan(u8, 4);
    return switch (t) {
        .int, .bool, .any => .{ .int = @as(i32, k) - 1 },
        .float => .{ .float = @as(f32, @floatFromInt(k)) * 0.75 - 0.5 },
        .string, .object => .{ .string = if (k == 0) obj else if (k == 1) "" else "x" },
    };
}
