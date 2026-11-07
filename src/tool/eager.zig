//! gorky-tool `eager <game-dir>`: every class of every archive loaded and each of its
//! functions compiled to IR at once, as an eager loader would: the time it takes (load,
//! compile; the slowest archive), the functions whose IR is incomplete (an include not
//! found) and what the IR leaves to run time (names, exe quirks).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common_mod = @import("common.zig");
const archive = og.formats.archive;
const script = og.script;
const ir = script.ir;

const Counts = std.StringArrayHashMapUnmanaged(usize);

fn bump(a: Allocator, c: *Counts, key: []const u8) !void {
    const gop = try c.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

/// The sources of one archive, then `common/other.dat` (as loaders/world.zig resolves them).
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

fn noBuiltin(_: *anyopaque, _: *script.runtime.Runtime, _: *script.object.Object, _: []const script.value.Value) anyerror!script.value.Value {
    return .zero;
}

fn ms(from: Io.Timestamp, to: Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(from.durationTo(to).nanoseconds)) / 1e6;
}

pub fn run(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8) !void {
    var dat = try common_mod.openDat(io, game_dir);
    defer dat.close(io);
    const archives = try archive.listArchives(io, gpa, dat);
    defer archive.freeList(gpa, archives);
    var common = try archive.Archive.open(io, gpa, dat, "common/other.dat");
    defer common.close(io, gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var classes: usize = 0;
    var class_errors: usize = 0;
    var functions: usize = 0;
    var incomplete: usize = 0;
    var left: Counts = .empty;
    var missing: Counts = .empty;
    var unknown: Counts = .empty;
    var load_ms: f64 = 0;
    var compile_ms: f64 = 0;
    var worst: struct { path: []const u8 = "", ms: f64 = 0 } = .{};
    const t0 = Io.Timestamp.now(io, .awake);
    for (archives) |path| {
        var arc = try archive.Archive.open(io, gpa, dat, path);
        defer arc.close(io, gpa);
        var sources: Sources = .{ .io = io, .a = a, .local = &arc, .common = &common };
        var rt: script.runtime.Runtime = .init(gpa, .{ .ctx = &sources, .fetch = Sources.fetch });
        defer rt.deinit();
        inline for (og.builtins.table) |e| try rt.registerBuiltinSig(e[0], &sources, noBuiltin, e[2]);
        const ta = Io.Timestamp.now(io, .awake);
        var loaded: std.ArrayList(*script.object.Class) = .empty;
        for (arc.entries) |*e| {
            if (!og.formats.resource.isScript(e.name)) continue;
            // Snippets are compiled where a function includes them.
            if (std.ascii.endsWithIgnoreCase(e.name, ".ss")) continue;
            const cls = rt.loadClass(e.name) catch |err| {
                class_errors += 1;
                try out.print("{s}: {s}: class: {t}\n", .{ path, e.name, err });
                continue;
            };
            classes += 1;
            try loaded.append(a, cls);
        }
        const tb = Io.Timestamp.now(io, .awake);
        var w: Walk = .{ .a = a, .rt = &rt, .left = &left, .missing = &missing, .unknown = &unknown };
        for (loaded.items) |cls| {
            var fit = cls.functions.valueIterator();
            while (fit.next()) |func| {
                if (!std.mem.eql(u8, func.*.file, cls.name)) continue;
                functions += 1;
                w.where = cls.name;
                const f = try rt.compiled(func.*);
                // compiled() keeps only complete IR.
                if (func.*.ir == null) {
                    incomplete += 1;
                    if (incomplete <= 30) try out.print("{s}: {s}: {s}: incomplete\n", .{ path, cls.name, f.name });
                }
                for (f.body) |*st| try walkStmt(&w, st);
            }
        }
        const tc = Io.Timestamp.now(io, .awake);
        load_ms += ms(ta, tb);
        compile_ms += ms(tb, tc);
        if (ms(ta, tc) > worst.ms) worst = .{ .path = path, .ms = ms(ta, tc) };
    }
    const total = ms(t0, Io.Timestamp.now(io, .awake));
    try out.print("archives {d}, classes {d} ({d} fail to load), functions {d}: {d} incomplete\n", .{ archives.len, classes, class_errors, functions, incomplete });
    try out.print("time: total {d:.1} ms (classes loaded and parsed {d:.1} ms, compiled {d:.1} ms); slowest archive {s} {d:.1} ms\n", .{ total, load_ms, compile_ms, worst.path, worst.ms });
    try out.writeAll("left to run time:\n");
    for (left.keys(), left.values()) |k, v| try out.print("  {s:<32} {d}\n", .{ k, v });
    if (unknown.count() > 0) {
        try out.writeAll("calls to no builtin and no script function:\n");
        for (unknown.keys(), unknown.values()) |k, v| try out.print("  {s:<32} {d}\n", .{ k, v });
    }
    if (missing.count() > 0) {
        try out.writeAll("includes not found:\n");
        for (missing.keys(), missing.values()) |k, v| try out.print("  {s:<32} {d}\n", .{ k, v });
    }
}

/// What a walk of one function's IR counts.
const Walk = struct {
    a: Allocator,
    rt: *script.runtime.Runtime,
    left: *Counts,
    missing: *Counts,
    unknown: *Counts,
    /// The class being walked (for messages).
    where: []const u8 = "",
};

fn walkStmt(w: *Walk, s: *const ir.Stmt) !void {
    const a = w.a;
    const c = w.left;
    switch (s.kind) {
        .expr => |e| try walkExpr(w, e),
        .local => {},
        .assign => |x| {
            if (x.target != .local) try bump(a, c, "assign name");
            try walkExpr(w, x.value);
        },
        .@"if" => |i| {
            try walkExpr(w, i.cond);
            for (i.then) |*t| try walkStmt(w, t);
            for (i.@"else") |*t| try walkStmt(w, t);
        },
        .@"return" => |e| try walkExpr(w, e),
        .fail => |f| {
            try bump(a, c, if (f.err == error.ScriptNotFound) "include not found" else "include failed");
            try bump(a, w.missing, f.file);
        },
        .@"while", .for_in, .@"break", .@"continue" => unreachable,
    }
}

fn walkExpr(w: *Walk, e: *const ir.Expr) !void {
    const a = w.a;
    const c = w.left;
    switch (e.kind) {
        .lit, .local => {},
        .name => |n| if (n.slot == null) try bump(a, c, "read name"),
        .call => |x| {
            if (!w.rt.builtins.contains(x.id) and !w.rt.fn_names.contains(x.id)) try bump(a, w.unknown, try std.fmt.allocPrint(a, "{s} ({s})", .{ x.text, w.where }));
            for (x.args) |arg| try walkExpr(w, arg);
        },
        .exe => |x| {
            try bump(a, c, try std.fmt.allocPrint(a, "exe.{t}", .{x.op}));
            for (x.args) |arg| try walkExpr(w, arg);
        },
        .unary => |u| try walkExpr(w, u.operand),
        .binary => |b| {
            try walkExpr(w, b.lhs);
            try walkExpr(w, b.rhs);
        },
        .logic => |l| {
            try walkExpr(w, l.lhs);
            try walkExpr(w, l.rhs);
        },
        .assign => |x| try walkExpr(w, x.value),
        .field, .host, .self, .member, .index, .list, .map, .ref, .method, .word, .trait_op => unreachable,
    }
}
