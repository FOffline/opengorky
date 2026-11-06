//! gorky-tool `roundtrip`: every script parsed, printed
//! back by the Classic printer and parsed again — the tree must be the same; every class
//! function imported to IR as the runtime does, then
//! 1. exported unchanged (`classic/export.zig`): no file changes;
//! 2. printed from IR by the Classic printer and imported again: the same IR;
//! 3. a creation event lifted to model data (`classic/lift.zig`) and put back (`unlift`):
//!    the same IR, nothing to export; its first lifted value changed in the model, put
//!    back, exported: only that literal's bytes differ, and the function imported from the
//!    written text lifts to the changed model;
//! 4. changed by each mutation (`mutations`), exported: only the file of the changed
//!    statement differs, a changed literal or call only in its own bytes, the function
//!    imports back to the changed IR and the file's other functions to their old IR.
//! 5. printed as OGS (`ogs/print.zig`) and read back by the OGS parser: the same IR.
//! Prints counts of the source constructs and of what the import made of them (plain
//! nodes, `exe.*` quirks, run-time names), of the model's values by layer (schema default,
//! archetype, instance, `.var`; `core/schema.zig` checked against the base classes).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common_mod = @import("common.zig");
const archive = og.formats.archive;
const script = og.script;
const ast = script.ast;
const ir = script.ir;
const lift = script.classic.lift;
const schema = og.core.schema;

/// Counters by name, in first-seen order.
const Counts = std.StringArrayHashMapUnmanaged(usize);

fn bump(a: Allocator, c: *Counts, key: []const u8) !void {
    const gop = try c.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

/// Script sources of one archive: its own entries, then `common/other.dat` (`classes\`,
/// `scriptlets\`, `gamestart\`), as `loaders/world.zig` resolves them.
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

    var src_counts: Counts = .empty;
    var ir_counts: Counts = .empty;
    var files: usize = 0;
    var failed: usize = 0;
    var mismatched: usize = 0;
    var functions: usize = 0;
    var class_errors: usize = 0;
    var check: Check = .{ .out = out };
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var ogs_differ: usize = 0;
    const schema_bad = try checkSchemas(io, gpa, a, out, &common);
    var layers: [std.enums.values(lift.Layer).len]usize = @splat(0);
    var var_overridden: usize = 0;
    var by_host: Counts = .empty;
    for (archives) |path| {
        var arc = try archive.Archive.open(io, gpa, dat, path);
        defer arc.close(io, gpa);
        var sources: Sources = .{ .io = io, .a = a, .local = &arc, .common = &common };
        var rt: script.runtime.Runtime = .init(gpa, .{ .ctx = &sources, .fetch = Sources.fetch });
        defer rt.deinit();
        inline for (og.builtins.table) |e| try rt.registerBuiltinSig(e[0], &sources, noBuiltin, e[2]);
        for (arc.entries) |*e| {
            if (!og.formats.resource.isScript(e.name)) continue;
            files += 1;
            const text = try arc.readAlloc(io, a, e);
            var diag: script.parser.Diagnostic = .{};
            const tree = script.parser.parse(a, text, &diag) catch |err| {
                failed += 1;
                try out.print("{s}: {s}:{d}: {s} ({t})\n", .{ path, e.name, diag.line, diag.message, err });
                continue;
            };
            for (tree.items) |it| try countItem(a, &src_counts, it);
            var printed: Io.Writer.Allocating = .init(a);
            try script.classic.print.unit(&printed.writer, tree);
            const again = script.parser.parse(a, printed.written(), &diag) catch null;
            if (again == null or !script.classic.print.same(ast.Unit, tree, again.?)) {
                mismatched += 1;
                try out.print("{s}: {s}: printed text parses to another tree\n", .{ path, e.name });
            }
            // Snippets are imported where a function includes them.
            if (std.ascii.endsWithIgnoreCase(e.name, ".ss")) continue;
            const cls = rt.loadClass(e.name) catch |err| {
                class_errors += 1;
                try out.print("{s}: {s}: class: {t}\n", .{ path, e.name, err });
                continue;
            };
            const key = try std.ascii.allocLowerString(a, e.name);
            var init_lifted: lift.Lifted = .{ .items = &.{}, .rest = undefined };
            var fit = cls.functions.valueIterator();
            while (fit.next()) |func| {
                // Each function once: in the file that defines it.
                if (!std.mem.eql(u8, func.*.file, key)) continue;
                functions += 1;
                const f = try rt.compiled(func.*);
                for (f.body) |*st| try countStmt(a, &ir_counts, st);
                defer _ = scratch.reset(.retain_capacity);
                check.where = .{ path, e.name, f.name };
                try check.function(scratch.allocator(), &rt, f);
                if (!try ogsSame(a, f, rt.names(), og.state.object.kindOf(std.fs.path.extension(e.name)) == .actor)) {
                    ogs_differ += 1;
                    try out.print("{s}: {s}: {s}: printed as OGS, reads back to another IR\n", .{ path, e.name, f.name });
                }
                if (!lift.isEvent(f.name)) continue;
                const l = try check.lifted(a, scratch.allocator(), &rt, cls, f);
                if (std.ascii.eqlIgnoreCase(f.name, "init")) init_lifted = l;
            }
            const names = try a.alloc([]const u8, cls.vars.items.len);
            for (cls.vars.items, names) |d, *n| n.* = d.name;
            try bump(a, &by_host, if (schema.hostOf(names)) |h| h.name else "none");
            // The model's values: each declared variable's layer after `.var` and init.
            var buf: [archive.name_size]u8 = undefined;
            const vname = try std.fmt.bufPrint(&buf, "variables\\{s}.var", .{std.fs.path.stem(e.name)});
            var vars: []const lift.Field = &.{};
            if (common.find(vname)) |ve| {
                const vtext = try common.readAlloc(io, a, ve);
                var parsed = try og.formats.vars.parse(a, vtext);
                vars = try lift.varFields(a, cls, try std.ascii.allocLowerString(a, vname), vtext, parsed.entries);
                parsed.entries = &.{};
            }
            for (cls.vars.items) |d| {
                const id = try cls.varId(d);
                const v = lift.fieldValue(vars, init_lifted, id) orelse {
                    layers[@backingInt(lift.Layer.base)] += 1;
                    continue;
                };
                layers[@backingInt(v.origin.layer)] += 1;
                if (v.origin.layer != .vars) for (vars) |x| {
                    if (x.id == id) var_overridden += 1;
                };
            }
        }
    }
    try out.writeAll("source constructs:\n");
    for (src_counts.keys(), src_counts.values()) |k, v| try out.print("  {s:<24} {d}\n", .{ k, v });
    try out.writeAll("imported to IR:\n");
    for (ir_counts.keys(), ir_counts.values()) |k, v| try out.print("  {s:<24} {d}\n", .{ k, v });
    try out.print("scripts {d}, failed {d}, printed back differently {d}; functions imported {d}, class errors {d}\n", .{ files, failed, mismatched, functions, class_errors });
    try out.print("export unchanged: {d} failed; IR printed and imported back: {d} failed; printed as OGS and read back: {d} failed\n", .{ check.unchanged, check.printed, ogs_differ });
    for (mutations, check.applied, check.broken) |m, n, b| try out.print("mutation {s:<8} {d} exported, {d} failed\n", .{ m.name, n, b });
    const lc = check.lift;
    try out.print("lifted: {d} creation events, {d} with data ({d} wholly), {d} fields, {d} calls; put back unchanged: {d} failed; model value changed and exported: {d}, {d} failed\n", .{ lc.events, lc.with_data, lc.whole, lc.fields, lc.calls, lc.unlift_failed, lc.changed, lc.change_failed });
    try out.print("model values: schema default {d}, archetype {d}, instance {d}, .var {d} (init over .var {d}); schemas against base classes: {d} differ\n", .{ layers[0], layers[1], layers[2], layers[3], var_overridden, schema_bad });
    try out.writeAll("classes by host:");
    for (by_host.keys(), by_host.values()) |k, v| try out.print(" {s} {d}", .{ k, v });
    try out.writeAll("\n");
    var broken: usize = 0;
    for (check.broken) |b| broken += b;
    if (failed > 0 or mismatched > 0 or check.unchanged > 0 or check.printed > 0 or ogs_differ > 0 or broken > 0 or lc.unlift_failed > 0 or lc.change_failed > 0 or schema_bad > 0) return error.RoundTrip;
}

/// `core/schema.zig` against the base classes of `common/other.dat` (`classes\\*.s`, each
/// with its `#inherit`s): Classic fields, names, types and order; the count that differ.
fn checkSchemas(io: Io, gpa: Allocator, a: Allocator, out: *Io.Writer, common: *const archive.Archive) !usize {
    var sources: Sources = .{ .io = io, .a = a, .local = common, .common = common };
    var rt: script.runtime.Runtime = .init(gpa, .{ .ctx = &sources, .fetch = Sources.fetch });
    defer rt.deinit();
    var bad: usize = 0;
    for (&schema.hosts) |*h| {
        const file = try std.fmt.allocPrint(a, "{s}.s", .{h.name});
        const cls = try rt.loadClass(file);
        const want = try schema.fields(a, h, false);
        const same = cls.vars.items.len == want.len and for (cls.vars.items, want) |d, w| {
            if (!std.ascii.eqlIgnoreCase(cls.varName(d), w.name) or d.type != w.type) break false;
        } else true;
        if (same) continue;
        bad += 1;
        try out.print("schema {s}: not as classes\\{s} declares it\n", .{ h.name, file });
    }
    return bad;
}

/// Step 5: `f` printed as OGS (OGS's builtin names, `classic/rename.zig`) parses to the
/// same IR (the exe's names back).
fn ogsSame(a: Allocator, f: *const ir.Fn, names: script.classic.rename.Names, actor: bool) !bool {
    var text: Io.Writer.Allocating = .init(a);
    script.ogs.print.function(&text.writer, try script.classic.rename.toOgs(a, f, names, actor), 0) catch |err| switch (err) {
        error.Unprintable => return false,
        else => return err,
    };
    var diag: script.ogs.parser.Diagnostic = .{};
    const u = script.ogs.parser.parseHosted(a, text.written(), f.file, &diag) catch return false;
    if (u.modules[0].fns.len != 1) return false;
    return script.ogs.print.same(ir.Fn, f.*, (try script.classic.rename.toClassic(a, u.modules[0].fns[0], names, actor, f)).*);
}

// ---------------------------------------------------------------- source constructs

fn countItem(a: Allocator, c: *Counts, it: ast.Item) !void {
    switch (it) {
        .inherit => try bump(a, c, "#inherit"),
        .include => try bump(a, c, "#include (top level)"),
        .var_decl => try bump(a, c, "variable"),
        .function => |f| {
            try bump(a, c, "function");
            for (f.body) |s| try countSrcStmt(a, c, s);
        },
        .stmt => |s| try countSrcStmt(a, c, s),
    }
}

fn countSrcStmt(a: Allocator, c: *Counts, s: ast.Stmt) !void {
    switch (s) {
        .empty, .block => {},
        .expr => |e| try countSrcExpr(a, c, e, true),
        .var_decl => try bump(a, c, "local"),
        .include => try bump(a, c, "#include (in function)"),
        .@"return" => |v| {
            try bump(a, c, if (v.value == null) "return; (no value)" else "return(x)");
            if (v.value) |e| try countSrcExpr(a, c, e, false);
        },
        .@"if" => |i| {
            try bump(a, c, if (i.@"else" != null) "if else" else "if");
            try countSrcExpr(a, c, i.cond, false);
            try countSrcStmt(a, c, i.then.*);
            if (i.@"else") |e| try countSrcStmt(a, c, e.*);
        },
    }
    if (s == .block) for (s.block) |x| try countSrcStmt(a, c, x);
}

fn countSrcExpr(a: Allocator, c: *Counts, e: *const ast.Expr, statement: bool) !void {
    switch (e.kind) {
        .int, .string, .ident => {},
        .float => try bump(a, c, "float literal"),
        .call => |x| for (x.args) |arg| try countSrcExpr(a, c, arg, false),
        .unary => |u| {
            try bump(a, c, if (u.op == .neg) "unary -" else "unary !");
            try countSrcExpr(a, c, u.operand, false);
        },
        .binary => |b| {
            try bump(a, c, switch (b.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
                .@"and" => "&&",
                .@"or" => "||",
            });
            try countSrcExpr(a, c, b.lhs, false);
            try countSrcExpr(a, c, b.rhs, false);
        },
        .assign => |x| {
            try bump(a, c, if (statement) "assignment" else "assignment as a value");
            try countSrcExpr(a, c, x.value, false);
        },
    }
}

// ---------------------------------------------------------------- IR

fn countStmt(a: Allocator, c: *Counts, s: *const ir.Stmt) !void {
    switch (s.kind) {
        .expr => |e| try countExpr(a, c, e),
        .local => try bump(a, c, "local declaration"),
        .assign => |x| {
            try bump(a, c, if (x.target == .local) "assign local" else "assign name (run time)");
            try countExpr(a, c, x.value);
        },
        .@"if" => |i| {
            try bump(a, c, "if");
            try countExpr(a, c, i.cond);
            for (i.then) |*t| try countStmt(a, c, t);
            for (i.@"else") |*t| try countStmt(a, c, t);
        },
        .@"return" => |e| {
            try bump(a, c, "return");
            try countExpr(a, c, e);
        },
        .fail => |f| try bump(a, c, if (f.err == error.ScriptNotFound) "include not found" else "include failed"),
        .@"while", .for_in, .@"break", .@"continue" => unreachable,
    }
}

fn countExpr(a: Allocator, c: *Counts, e: *const ir.Expr) !void {
    switch (e.kind) {
        .lit => {},
        .local => try bump(a, c, "read local"),
        .name => |n| try bump(a, c, if (n.slot != null) "read name (maybe local)" else "read name (run time)"),
        .call => |x| {
            try bump(a, c, "call");
            for (x.args) |arg| try countExpr(a, c, arg);
        },
        .exe => |x| {
            try bump(a, c, try std.fmt.allocPrint(a, "exe.{t}", .{x.op}));
            for (x.args) |arg| try countExpr(a, c, arg);
        },
        .unary => |u| {
            try bump(a, c, if (u.op == .neg) "plain -x" else "plain !x");
            try countExpr(a, c, u.operand);
        },
        .binary => |b| {
            try bump(a, c, try std.fmt.allocPrint(a, "plain {t}", .{b.op}));
            try countExpr(a, c, b.lhs);
            try countExpr(a, c, b.rhs);
        },
        .logic => |l| {
            try bump(a, c, try std.fmt.allocPrint(a, "short-circuit {t}", .{l.op}));
            try countExpr(a, c, l.lhs);
            try countExpr(a, c, l.rhs);
        },
        .assign => |x| {
            try bump(a, c, "assignment as a value");
            try countExpr(a, c, x.value);
        },
        .field, .host, .self, .member, .index, .list, .map, .ref, .method, .word, .trait_op => unreachable,
    }
}

// ---------------------------------------------------------------- export (steps 1, 2, 4)

const export_mod = script.classic.@"export";
const print = script.classic.print;

/// A deterministic change of a function's IR; null where it does not apply. `at`: the
/// changed statement and the node whose bytes alone may change (none: anywhere in the file).
const Mutation = struct {
    name: []const u8,
    make: *const fn (a: Allocator, f: *const ir.Fn, at: *At) anyerror!?*const ir.Fn,
};

const At = struct { stmt: ?*const ir.Stmt = null, span: ir.Span = .{} };

const mutations = [_]Mutation{
    .{ .name = "value", .make = mutValue },
    .{ .name = "insert", .make = mutInsert },
    .{ .name = "remove", .make = mutRemove },
    .{ .name = "call", .make = mutCall },
    .{ .name = "branch", .make = mutBranch },
};

const Check = struct {
    out: *Io.Writer,
    /// Archive, file and function (for messages).
    where: [3][]const u8 = .{ "", "", "" },
    unchanged: usize = 0,
    printed: usize = 0,
    applied: [mutations.len]usize = @splat(0),
    broken: [mutations.len]usize = @splat(0),
    /// Messages printed so far (the rest only counted).
    shown: usize = 0,
    lift: struct { events: usize = 0, with_data: usize = 0, whole: usize = 0, fields: usize = 0, calls: usize = 0, unlift_failed: usize = 0, changed: usize = 0, change_failed: usize = 0 } = .{},

    fn report(self: *Check, what: []const u8, detail: []const u8) !void {
        self.shown += 1;
        if (self.shown > 40) return;
        try self.out.print("{s}: {s}: {s}: {s}: {s}\n", .{ self.where[0], self.where[1], self.where[2], what, detail });
    }

    fn function(self: *Check, a: Allocator, rt: *script.runtime.Runtime, f: *const ir.Fn) !void {
        // 1. Unchanged: nothing to write.
        var ex: export_mod.Export = .init(a, rt.importEnv());
        if (ex.apply(&.{.{ .old = f, .new = f }})) {
            if (ex.files.count() > 0) {
                self.unchanged += 1;
                try self.report("unchanged export", "files written");
            }
        } else |err| {
            self.unchanged += 1;
            try self.report("unchanged export", try diagText(a, err, ex.diag));
        }
        // 2. IR → Classic text → IR.
        if (printedBack(a, rt, f)) |same| {
            if (!same) {
                self.printed += 1;
                try self.report("printed IR", "imports to other IR");
            }
        } else |err| {
            self.printed += 1;
            try self.report("printed IR", @errorName(err));
        }
        // 4. Mutations.
        for (mutations, 0..) |m, i| {
            var at: At = .{};
            const g = try m.make(a, f, &at) orelse continue;
            self.applied[i] += 1;
            if (try self.mutated(a, rt, f, g, at)) |why| {
                self.broken[i] += 1;
                try self.report(m.name, why);
            }
        }
    }

    /// Step 3 for creation event `f` of `cls`: lifted (in `keep`, for the model counts) and
    /// put back, then its first lifted field changed (in `a`).
    fn lifted(self: *Check, keep: Allocator, a: Allocator, rt: *script.runtime.Runtime, cls: *const script.object.Class, f: *const ir.Fn) !lift.Lifted {
        const c = &self.lift;
        c.events += 1;
        const l = try lift.lift(keep, rt.importEnv(), f, cls);
        if (l.items.len == 0) return l;
        c.with_data += 1;
        if (l.rest.body.len == 0) c.whole += 1;
        for (l.items) |it| if (it == .field) {
            c.fields += 1;
        } else {
            c.calls += 1;
        };
        const back = try lift.unlift(a, f, l);
        var ex: export_mod.Export = .init(a, rt.importEnv());
        ex.apply(&.{.{ .old = f, .new = back }}) catch |err| {
            c.unlift_failed += 1;
            try self.report("unlift", try diagText(a, err, ex.diag));
            return l;
        };
        if (!print.same(ir.Fn, f.*, back.*) or ex.files.count() > 0 or l.items.len + l.rest.body.len != f.body.len) {
            c.unlift_failed += 1;
            try self.report("unlift", "another function");
            return l;
        }
        // The model changed: its first field with text.
        const k = for (l.items, 0..) |it, i| {
            if (it == .field and !it.field.origin.span.none()) break i;
        } else return l;
        const items = try a.dupe(lift.Item, l.items);
        const x = &items[k].field;
        x.value = switch (x.value) {
            .int => |v| .{ .int = if (v < std.math.maxInt(i32)) v + 1 else 0 },
            .float => |v| .{ .float = v + 1 },
            .string => |v| .{ .string = try std.mem.concat(a, u8, &.{ v, "_rt" }) },
            else => unreachable,
        };
        c.changed += 1;
        const changed: lift.Lifted = .{ .items = items, .rest = l.rest };
        const g = try lift.unlift(a, f, changed);
        if (try self.mutated(a, rt, f, g, .{ .stmt = &f.body[x.origin.at], .span = x.origin.span })) |why| {
            c.change_failed += 1;
            try self.report("model change", why);
            return l;
        }
        // Imported from the written text, the function lifts to the changed model.
        var ex2: export_mod.Export = .init(a, rt.importEnv());
        try ex2.apply(&.{.{ .old = f, .new = g }});
        var diag: script.parser.Diagnostic = .{};
        const unit = (try ex2.env().unit(&ex2, f.file, &diag)).unit;
        for (unit.items) |*it| {
            if (it.* != .function or !std.ascii.eqlIgnoreCase(it.function.name, f.name)) continue;
            var func: script.object.Func = .{ .ast = &it.function, .file = f.file, .class = cls };
            const again = try script.classic.import.function(a, a, ex2.env(), &func);
            const l2 = try lift.lift(a, ex2.env(), again.ir, cls);
            if (!print.same([]const lift.Item, items, l2.items)) {
                c.change_failed += 1;
                try self.report("model change", "lifts to another model");
            }
            break;
        }
        return l;
    }

    /// Why the export of `g` is wrong, or null.
    fn mutated(self: *Check, a: Allocator, rt: *script.runtime.Runtime, f: *const ir.Fn, g: *const ir.Fn, at: At) !?[]const u8 {
        _ = self;
        var ex: export_mod.Export = .init(a, rt.importEnv());
        ex.apply(&.{.{ .old = f, .new = g }}) catch |err| return try diagText(a, err, ex.diag);
        const file = if (at.stmt) |s| s.file else f.file;
        if (ex.files.count() != 1 or ex.files.get(file) == null) return try std.fmt.allocPrint(a, "{d} files written, expected {s}", .{ ex.files.count(), file });
        const new = ex.files.get(file).?;
        var diag: script.parser.Diagnostic = .{};
        const old_unit = (try rt.importEnv().unit(rt, file, &diag)).unit;
        if (!at.span.none()) {
            const old = old_unit.src;
            const pre = std.mem.indexOfDiff(u8, old, new) orelse old.len;
            var suf: usize = 0;
            while (suf < old.len and suf < new.len and old[old.len - 1 - suf] == new[new.len - 1 - suf]) suf += 1;
            if (pre < at.span.start or old.len - suf > at.span.end) return "bytes outside the changed node differ";
        }
        // The file's other functions: the same IR as before.
        const new_unit = (try ex.env().unit(&ex, file, &diag)).unit;
        var k: usize = 0;
        for (old_unit.items) |*it| {
            if (it.* != .function) continue;
            while (k < new_unit.items.len and new_unit.items[k] != .function) k += 1;
            if (k == new_unit.items.len) return "a function is gone";
            const nf = &new_unit.items[k].function;
            k += 1;
            if (std.ascii.eqlIgnoreCase(it.function.name, f.name)) continue;
            var of: script.object.Func = .{ .ast = &it.function, .file = file };
            var nfn: script.object.Func = .{ .ast = nf, .file = file };
            const x = try script.classic.import.function(a, a, rt.importEnv(), &of);
            const y = try script.classic.import.function(a, a, ex.env(), &nfn);
            if (!print.same(ir.Fn, x.ir.*, y.ir.*)) return try std.fmt.allocPrint(a, "function {s} changed", .{it.function.name});
        }
        return null;
    }
};

fn diagText(a: Allocator, err: anyerror, d: export_mod.Diagnostic) ![]const u8 {
    return std.fmt.allocPrint(a, "{t} at {s}:{d}: {s}", .{ err, d.file, d.line, d.message });
}

/// Step 2: the function printed whole (includes inline) imports to the same IR.
fn printedBack(a: Allocator, rt: *script.runtime.Runtime, f: *const ir.Fn) !bool {
    var text: Io.Writer.Allocating = .init(a);
    try print.function(&text.writer, f, .{});
    var diag: script.parser.Diagnostic = .{};
    const unit = try script.parser.parse(a, text.written(), &diag);
    if (unit.items.len != 1 or unit.items[0] != .function) return false;
    // A file no source has: the reimport has no byte ranges (not compared anyway).
    var func: script.object.Func = .{ .ast = &unit.items[0].function, .file = "<printed>" };
    const r = try script.classic.import.function(a, a, rt.importEnv(), &func);
    return print.same(ir.Fn, r.ir.*, f.*);
}

fn withBody(a: Allocator, f: *const ir.Fn, body: []const ir.Stmt) !*const ir.Fn {
    const g = try a.create(ir.Fn);
    g.* = f.*;
    g.body = body;
    return g;
}

/// `og_roundtrip = 1;`, a statement of no file.
fn newStmt(a: Allocator) !ir.Stmt {
    const one = try a.create(ir.Expr);
    one.* = .{ .line = 0, .kind = .{ .lit = .{ .int = 1 } } };
    return .{ .file = "", .line = 0, .kind = .{ .assign = .{
        .target = .{ .name = .{ .id = try script.object.intern("og_roundtrip"), .text = "og_roundtrip" } },
        .value = one,
    } } };
}

/// The first statement (pre-order, into `if` branches unless `top`) `edit` returns a
/// replacement for (zero or more statements); the list rebuilt along the way.
fn rewrite(a: Allocator, list: []const ir.Stmt, top: bool, at: *At, edit: *const fn (a: Allocator, s: *const ir.Stmt, at: *At) anyerror!?[]const ir.Stmt) !?[]const ir.Stmt {
    for (list, 0..) |*s, i| {
        const repl: []const ir.Stmt = if (try edit(a, s, at)) |r| blk: {
            at.stmt = s;
            break :blk r;
        } else if (!top and s.kind == .@"if") blk: {
            const x = s.kind.@"if";
            var y = x;
            if (try rewrite(a, x.then, top, at, edit)) |t| {
                y.then = t;
            } else if (try rewrite(a, x.@"else", top, at, edit)) |e| {
                y.@"else" = e;
            } else continue;
            var c = s.*;
            c.kind = .{ .@"if" = y };
            break :blk try a.dupe(ir.Stmt, &.{c});
        } else continue;
        return try std.mem.concat(a, ir.Stmt, &.{ list[0..i], repl, list[i + 1 ..] });
    }
    return null;
}

fn mutValue(a: Allocator, f: *const ir.Fn, at: *At) !?*const ir.Fn {
    const body = try rewrite(a, f.body, false, at, struct {
        fn edit(ea: Allocator, s: *const ir.Stmt, eat: *At) !?[]const ir.Stmt {
            if (s.kind != .assign or s.kind.assign.value.kind != .lit) return null;
            const v = s.kind.assign.value;
            const e = try ea.create(ir.Expr);
            e.* = .{ .line = v.line, .kind = .{ .lit = switch (v.kind.lit) {
                .int => |x| .{ .int = if (x < std.math.maxInt(i32)) x + 1 else 0 },
                .float => |x| .{ .float = x + 1 },
                .string => |x| .{ .string = try std.mem.concat(ea, u8, &.{ x, "_rt" }) },
                else => unreachable,
            } } };
            eat.span = v.span;
            var c = s.*;
            c.kind = .{ .assign = .{ .target = s.kind.assign.target, .value = e } };
            return try ea.dupe(ir.Stmt, &.{c});
        }
    }.edit) orelse return null;
    return try withBody(a, f, body);
}

fn mutInsert(a: Allocator, f: *const ir.Fn, _: *At) !?*const ir.Fn {
    return try withBody(a, f, try std.mem.concat(a, ir.Stmt, &.{ f.body, &.{try newStmt(a)} }));
}

/// The first statement of the function's own text (not a declaration: a removed one
/// would make its later uses another node).
fn mutRemove(a: Allocator, f: *const ir.Fn, at: *At) !?*const ir.Fn {
    const body = try rewrite(a, f.body, true, at, struct {
        fn edit(_: Allocator, s: *const ir.Stmt, _: *At) !?[]const ir.Stmt {
            if (!s.via.none() or (s.kind != .expr and s.kind != .assign)) return null;
            return &.{};
        }
    }.edit) orelse return null;
    return try withBody(a, f, body);
}

/// The first call statement calls `og_roundtrip` with the same arguments.
fn mutCall(a: Allocator, f: *const ir.Fn, at: *At) !?*const ir.Fn {
    const body = try rewrite(a, f.body, false, at, struct {
        fn edit(ea: Allocator, s: *const ir.Stmt, eat: *At) !?[]const ir.Stmt {
            if (s.kind != .expr or s.kind.expr.kind != .call) return null;
            const old = s.kind.expr;
            const e = try ea.create(ir.Expr);
            e.* = old.*;
            e.kind.call.text = "og_roundtrip";
            e.kind.call.id = try script.object.intern("og_roundtrip");
            eat.span = old.span;
            var c = s.*;
            c.kind = .{ .expr = e };
            return try ea.dupe(ir.Stmt, &.{c});
        }
    }.edit) orelse return null;
    return try withBody(a, f, body);
}

/// A statement added to the first `if` of the function's top level: the `if` re-printed.
fn mutBranch(a: Allocator, f: *const ir.Fn, at: *At) !?*const ir.Fn {
    const body = try rewrite(a, f.body, true, at, struct {
        fn edit(ea: Allocator, s: *const ir.Stmt, _: *At) !?[]const ir.Stmt {
            if (s.kind != .@"if") return null;
            var y = s.kind.@"if";
            y.then = try std.mem.concat(ea, ir.Stmt, &.{ y.then, &.{try newStmt(ea)} });
            var c = s.*;
            c.kind = .{ .@"if" = y };
            return try ea.dupe(ir.Stmt, &.{c});
        }
    }.edit) orelse return null;
    return try withBody(a, f, body);
}
