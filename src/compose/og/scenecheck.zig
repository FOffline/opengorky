//! The OG build's check of scene blocks (core/scene.zig `commands`): each command is one of
//! the engine's, its arguments of their kinds (`@Sullivan`, a bool, seconds, `~d"…"`), a
//! pair's last argument `true` or `false`, a state 0–9 — errors; what a scene names that the
//! project lacks — warnings, the scene runs on as the exe's does (a missing actor, object or
//! point does nothing): no such `@name` block, no such point in its `points`, a line past
//! its open dialog's, an animation its actor's look's model lacks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../../script.zig").ir;
const parser = @import("../../script.zig").ogs.parser;
const core = @import("../../core.zig");
const assets = @import("../../loaders.zig").assets;
const anim = @import("../../formats.zig").anim;
const Kind = core.scene.Kind;

pub const Problem = struct { file: []const u8, line: u32, message: []const u8, warning: bool };

const Check = struct {
    a: Allocator,
    stack: ?*assets.Stack,
    /// Every block by its name in lower case (an object's, a hero's…), the first of a name.
    names: std.StringHashMapUnmanaged(*const ir.Entity) = .empty,
    /// Top-level blocks by their path (`actors::nato`, `looks::sullivan`).
    paths: std.StringHashMapUnmanaged(*const ir.Entity) = .empty,
    /// Dialog blocks' line counts by name.
    dialogs: std.StringHashMapUnmanaged(usize) = .empty,
    /// A model's animations by its mesh (null: none read).
    anis: std.StringHashMapUnmanaged(?anim.AnimList) = .empty,
    out: std.ArrayList(Problem) = .empty,
    file: []const u8 = "",
    /// The project's code in lower case: an object its code makes (`sound::NewAmbient("x", …)`)
    /// is named there as a string.
    code: []const u8 = "",

    /// Some block is named `n`, or the code names it as a string (`"n"`).
    fn known(self: *Check, n: []const u8) !bool {
        const low = try std.ascii.allocLowerString(self.a, n);
        if (self.names.contains(low)) return true;
        return std.mem.indexOf(u8, self.code, try std.fmt.allocPrint(self.a, "\"{s}\"", .{low})) != null;
    }

    fn put(self: *Check, line: u32, warning: bool, comptime fmt: []const u8, args: anytype) !void {
        try self.out.append(self.a, .{ .file = self.file, .line = line, .message = try std.fmt.allocPrint(self.a, fmt, args), .warning = warning });
    }

    fn index(self: *Check, e: *const ir.Entity) !void {
        if (!std.mem.eql(u8, e.kind, "look") and !std.mem.eql(u8, e.kind, "scene") and !std.mem.eql(u8, e.kind, "dialog")) {
            const g = try self.names.getOrPut(self.a, try std.ascii.allocLowerString(self.a, e.name));
            if (!g.found_existing) g.value_ptr.* = e;
        }
        for (e.children) |*c| try self.index(c);
    }

    /// The model (`mesh`) of block `e`'s look: its `look`, else its archetype's, else its
    /// import's.
    fn meshOf(self: *Check, e: *const ir.Entity, depth: u32) ?[]const u8 {
        if (depth > 8) return null;
        if (field(e, "look")) |v| {
            const l = self.paths.get(if (v.kind == .word) v.kind.word else return null) orelse return null;
            return core.schema.text(field(l, "mesh") orelse return null);
        }
        const next = if (e.base.len > 0) e.base else if (field(e, "same_as")) |v| (if (v.kind == .word) ir.Import.of(v.kind.word).path else return null) else return null;
        return self.meshOf(self.paths.get(next) orelse return null, depth + 1);
    }

    fn ani(self: *Check, mesh: []const u8) !?anim.AnimList {
        const g = try self.anis.getOrPut(self.a, mesh);
        if (g.found_existing) return g.value_ptr.*;
        g.value_ptr.* = null;
        const s = self.stack orelse return null;
        const bytes = s.read(self.a, try std.fmt.allocPrint(self.a, "models/{s}.ani", .{mesh})) catch return null;
        g.value_ptr.* = anim.parseAni(self.a, bytes) catch null;
        return g.value_ptr.*;
    }

    fn scene(self: *Check, e: *const ir.Entity) !void {
        var points: std.StringHashMapUnmanaged(void) = .empty;
        for (e.fields) |f| if (std.mem.eql(u8, f.name, "points") and f.value.kind == .list) for (f.value.kind.list) |x| {
            if (x.kind != .call) continue;
            for (x.kind.call.named) |n| if (std.mem.eql(u8, n.name, "name")) if (core.schema.text(n.value)) |t|
                try points.put(self.a, try std.ascii.allocLowerString(self.a, t), {});
        };
        // A name it lacks, said once.
        var missing: std.StringHashMapUnmanaged(void) = .empty;
        // The open dialog: its name, its lines (null: unknown).
        var open: ?struct { []const u8, usize } = null;
        for (e.rows) |r| {
            if (r.kind != .call) continue;
            const c = r.kind.call;
            if (std.mem.indexOf(u8, c.text, "::") == null) {
                if (core.scene.ofExe(c.text) == null) try self.put(r.line, false, "no scene command {s}", .{c.text});
                open = null;
                continue;
            }
            const cmd = core.scene.ofOgs(c.text, null) orelse {
                try self.put(r.line, false, "no scene command {s} (scene commands: core/scene.zig, docs/og-script.md)", .{c.text});
                continue;
            };
            var args = c.args;
            if (cmd.flag != null) {
                const last = if (args.len > 0) args[args.len - 1] else null;
                if (last == null or !isBool(last.?)) {
                    try self.put(r.line, false, "{s} takes true or false last ({s}(…, true))", .{ c.text, c.text });
                    continue;
                }
                args = args[0 .. args.len - 1];
            }
            var k: usize = 0;
            var actor: ?[]const u8 = null;
            for (args, 0..) |x, i| {
                while (k < cmd.args.len and cmd.args[k] == '_') k += 1;
                const kind: Kind = if (k < cmd.args.len) .of(cmd.args[k]) else break;
                k += 1;
                const what = @tagName(kind);
                switch (kind) {
                    .actor, .object => {
                        if (x.kind != .ref) {
                            try self.put(r.line, false, "{s}: argument {d}: expected @name (an {s})", .{ c.text, i + 1, what });
                            continue;
                        }
                        const n = x.kind.ref;
                        if (std.mem.indexOf(u8, n, "::") != null) {
                            if (std.mem.eql(u8, core.scene.exeActor(n), n)) try self.put(r.line, false, "{s}: @{s}: not a scene's hero (@hero::selected, @hero::last_action)", .{ c.text, n });
                            continue;
                        }
                        if (kind == .actor) actor = n;
                        if (!try self.known(n) and !(try missing.getOrPut(self.a, n)).found_existing) try self.put(r.line, true, "{s}: no block @{s} in the project", .{ c.text, n });
                    },
                    .point => if (core.schema.text(x)) |t| {
                        if (x.kind == .lit and !points.contains(try std.ascii.allocLowerString(self.a, t))) try self.put(r.line, true, "{s}: no point \"{s}\" in the scene's points", .{ c.text, t });
                    },
                    .bool, .not, .given => if (!isBool(x)) try self.put(r.line, false, "{s}: argument {d}: expected true or false", .{ c.text, i + 1 }),
                    .ticks, .centis, .percent, .int, .number, .line, .state => {
                        const v = number(x) orelse {
                            try self.put(r.line, false, "{s}: argument {d}: expected a number{s}", .{ c.text, i + 1, if (kind.scale() != null and kind != .percent) " of seconds" else "" });
                            continue;
                        };
                        if (kind == .state and (v < 0 or v > core.scene.max_state or v != @trunc(v))) try self.put(r.line, false, "{s}: state {d}: 0 to {d}", .{ c.text, v, core.scene.max_state });
                        if (kind == .line) if (open) |o| if (v >= @as(f64, @floatFromInt(o[1]))) try self.put(r.line, true, "{s}({d}): dialog {s} has {d} lines", .{ c.text, v, o[0], o[1] });
                    },
                    .level, .scene, .sound, .weapon, .dialog => {
                        // A sigil's string the link checks; a dialog the game lacks stays a plain string.
                        const t = if (x.kind == .lit and x.kind.lit == .string) x.kind.lit.string else {
                            try self.put(r.line, false, "{s}: argument {d}: expected ~{c}\"…\"", .{ c.text, i + 1, kind.sigil() });
                            continue;
                        };
                        if (kind == .dialog) {
                            open = if (self.dialogs.get(t)) |n| .{ t, n } else null;
                            if (x.sigil == .none) try self.put(r.line, true, "{s}: no dialog \"{s}\" (~d\"name\" names a dialog block)", .{ c.text, t });
                        } else if (x.sigil == .none) try self.put(r.line, false, "{s}: argument {d}: expected ~{c}\"…\"", .{ c.text, i + 1, kind.sigil() });
                    },
                    .name => if (i == 1) if (actor) |n| if (isAnim(cmd.exe)) if (core.schema.text(x)) |t| {
                        const b = self.names.get(try std.ascii.allocLowerString(self.a, n)) orelse continue;
                        const mesh = self.meshOf(b, 0) orelse continue;
                        const list = try self.ani(mesh) orelse continue;
                        if (list.find(t) == null) try self.put(r.line, true, "{s}: no animation {s} in models/{s}.ani (@{s}'s look)", .{ c.text, t, mesh, n });
                    },
                    .dropped => {},
                }
            }
        }
    }
};

fn isAnim(exe: []const u8) bool {
    for ([_][]const u8{ "ANIMATION", "FAST_ANIMATION", "USEANIMATION", "IDLE_ANIMATION", "WALK_ANIMATION" }) |n| if (std.mem.eql(u8, exe, n)) return true;
    return false;
}

fn isBool(x: *const ir.Expr) bool {
    return x.kind == .lit and x.kind.lit == .bool;
}

fn number(x: *const ir.Expr) ?f64 {
    return switch (x.kind) {
        .lit => |v| switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        },
        .unary => |u| if (u.op == .neg) if (number(u.operand)) |n| -n else null else null,
        else => null,
    };
}

fn field(e: *const ir.Entity, name: []const u8) ?*const ir.Expr {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

/// The problems of the scene blocks of `units` (`stack`: the assets, for the animations;
/// `code`: the texts that are no scene or dialog, an object their code makes named there).
pub fn run(a: Allocator, stack: ?*assets.Stack, units: []const parser.Unit, code: []const []const u8) ![]const Problem {
    var all: std.ArrayList(u8) = .empty;
    for (code) |t| {
        try all.appendSlice(a, t);
        try all.append(a, '\n');
    }
    var ch: Check = .{ .a = a, .stack = stack, .code = try std.ascii.allocLowerString(a, all.items) };
    for (units) |u| for (u.modules) |m| for (m.entities) |*e| {
        try ch.index(e);
        try ch.paths.put(a, if (m.path.len > 0) try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name }) else e.name, e);
        if (std.mem.eql(u8, e.kind, "dialog")) {
            var n: usize = 0;
            for (e.rows) |r| n += @intFromBool(r.kind == .call);
            try ch.dialogs.put(a, e.name, n);
        }
    };
    for (units) |u| for (u.modules) |m| for (m.entities) |*e| if (std.mem.eql(u8, e.kind, "scene")) {
        ch.file = u.file;
        try ch.scene(e);
    };
    return ch.out.items;
}

test "scene check: kinds are errors, missing names warnings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\hero sullivan {}
        \\dialog d { Line(who = "x", text = "a"); }
        \\scene s {
        \\    points = [Point(name = "p1", x = 0, y = 0, angle = 0)];
        \\    camera::Panorama();
        \\    actor::Place("Sullivan", "p1");
        \\    actor::Place(@Sullivan, "p2");
        \\    actor::Wait(@Nobody);
        \\    object::Delete(@made);
        \\    actor::SetState(@Sullivan, 12);
        \\    dialog::Open(~d"d");
        \\    dialog::Say(0);
        \\    dialog::Say(1);
        \\    scene::Wait("x");
        \\    object::Enable(@hero::selected, true);
        \\    gui::Shake();
        \\}
    ;
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, src, "s.ogs", &diag);
    const ps = try run(a, null, &.{u}, &.{"sound::NewAmbient(\"Made\", 1, 2, \"x.wav\");"});
    const want = [_]struct { u32, bool, []const u8 }{
        .{ 5, false, "camera::Panorama takes true or false last (camera::Panorama(…, true))" },
        .{ 6, false, "actor::Place: argument 1: expected @name (an actor)" },
        .{ 7, true, "actor::Place: no point \"p2\" in the scene's points" },
        .{ 8, true, "actor::Wait: no block @Nobody in the project" },
        .{ 10, false, "actor::SetState: state 12: 0 to 9" },
        .{ 13, true, "dialog::Say(1): dialog d has 1 lines" },
        .{ 14, false, "scene::Wait: argument 1: expected a number of seconds" },
        .{ 16, false, "no scene command gui::Shake (scene commands: core/scene.zig, docs/og-script.md)" },
    };
    try std.testing.expectEqual(want.len, ps.len);
    for (want, ps) |w, p| {
        try std.testing.expectEqual(w[0], p.line);
        try std.testing.expectEqual(w[1], p.warning);
        try std.testing.expectEqualStrings(w[2], p.message);
    }
}
