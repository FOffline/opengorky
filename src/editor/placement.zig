//! Placement calls in a level script (`.lev`): PlaceActor(name, x, y[, dir]),
//! AIEnemyAppear(name, x0, y0, x1, y1), PlaceCombatActor(name, x, y, angle), read from
//! the level's model (`model.sites`: the IR of its functions). Edits change
//! the call text in place, so the rest of the script (comments, formatting, CRLF) stays
//! byte for byte; a lifted call's values go through the exporter (`level.Doc.drop`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("opengorky").script.ir;
const model = @import("model.zig");
const App = @import("app.zig").App;

const Func = enum { place_actor, enemy_appear, place_combat };

pub const Span = @import("opengorky").formats.assigns.Span;

pub const Call = struct {
    func: Func,
    name: []const u8,
    /// Numeric arguments after the name.
    args: [4]Span = undefined,
    n_args: usize = 0,
    /// The statement, `Name(` to `;` inclusive.
    stmt: Span,
    /// Inside `function restore()` and not nested in a condition (depth 1).
    in_restore: bool,
    /// Inside `function CombatEnemiesAppear()` (any depth): reinforcements the game
    /// runs at the end of each enemy turn.
    in_appear: bool = false,
    /// Reinforcement: the `if(AIFreeTile(x, y))` chain guarding its block, the x and y
    /// of each (the battles check the tiles it stops on).
    guards: [9][2]Span = undefined,
    n_guards: usize = 0,

    pub fn arg(self: Call, text: []const u8, i: usize) ?f32 {
        if (i >= self.n_args) return null;
        return std.fmt.parseFloat(f32, text[self.args[i].start..self.args[i].end]) catch null;
    }
};

pub const Script = struct {
    calls: []Call,
    /// Offset of restore()'s closing brace.
    restore_close: ?usize,

    pub fn deinit(self: *Script, gpa: Allocator) void {
        gpa.free(self.calls);
    }
};

const names = [_]struct { s: []const u8, f: Func }{
    .{ .s = "PlaceActor", .f = .place_actor },
    .{ .s = "AIEnemyAppear", .f = .enemy_appear },
    .{ .s = "PlaceCombatActor", .f = .place_combat },
};
const call_names = [_][]const u8{ names[0].s, names[1].s, names[2].s };

/// The placement calls of level script `file` (Store index), from its model's IR;
/// `error.ScriptBroken` when it does not parse (no model).
pub fn scan(app: *App, gpa: Allocator, file: usize) !Script {
    if (!model.parses(app, file)) return error.ScriptBroken;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = app.store.text(file);
    return build(gpa, text, model.sites(app, arena.allocator(), file, &call_names), model.funcSpan(app, file, "restore"));
}

/// `Script` of `text` from its call sites (`model.sites`) and restore()'s span. Calls whose
/// arguments are a string then numeric literals; other forms (`PlaceActor(name, "area",
/// 0)`, expressions) are skipped.
fn build(gpa: Allocator, text: []const u8, sites: []const model.Site, restore: ?ir.Span) !Script {
    var calls: std.ArrayList(Call) = .empty;
    errdefer calls.deinit(gpa);
    for (sites) |st| if (callOf(text, st)) |call| try calls.append(gpa, call);
    const close: ?usize = if (restore) |sp| if (std.mem.lastIndexOfScalar(u8, text[sp.start..sp.end], '}')) |k| sp.start + k else null else null;
    return .{ .calls = try calls.toOwnedSlice(gpa), .restore_close = close };
}

fn callOf(text: []const u8, st: model.Site) ?Call {
    const f = for (names) |n| {
        if (std.ascii.eqlIgnoreCase(n.s, st.call.text)) break n.f;
    } else return null;
    const args = st.call.args;
    const want: usize = switch (f) {
        .place_actor => 2,
        .enemy_appear => 4,
        .place_combat => 3,
    };
    if (args.len < 1 + want or args.len > 5 or args[0].kind != .lit or args[0].kind.lit != .string) return null;
    const q = args[0].span;
    var call: Call = .{ .func = f, .name = text[q.start + 1 .. q.end - 1], .stmt = .{ .start = st.stmt.start, .end = st.stmt.end }, .in_restore = st.top and std.ascii.eqlIgnoreCase(st.func, "restore") };
    for (args[1..]) |e| {
        if (number(e) == null) return null;
        call.args[call.n_args] = .{ .start = e.span.start, .end = e.span.end };
        call.n_args += 1;
    }
    call.in_appear = std.ascii.eqlIgnoreCase(st.func, "CombatEnemiesAppear");
    if (call.in_appear and f == .enemy_appear) for (st.conds) |cond| guardsIn(cond, &call);
    return call;
}

/// A numeric literal (a minus over one too).
fn number(e: *const ir.Expr) ?f32 {
    return switch (e.kind) {
        .lit => |v| switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |x| x,
            else => null,
        },
        .unary => |u| if (u.op == .neg) if (number(u.operand)) |x| -x else null else null,
        else => null,
    };
}

/// The `AIFreeTile(x, y)` calls with integer tiles in condition `e` (the battles check
/// the tiles a reinforcement stops on), in the text's order.
fn guardsIn(e: *const ir.Expr, call: *Call) void {
    switch (e.kind) {
        .call => |c| {
            for (c.args) |x| guardsIn(x, call);
            if (!std.ascii.eqlIgnoreCase(c.text, "AIFreeTile") or c.args.len != 2 or call.n_guards == call.guards.len) return;
            var g: [2]Span = undefined;
            for (c.args, &g) |x, *sp| {
                const v = number(x) orelse return;
                if (v != @trunc(v) or (x.kind == .lit and x.kind.lit != .int)) return;
                sp.* = .{ .start = x.span.start, .end = x.span.end };
            }
            call.guards[call.n_guards] = g;
            call.n_guards += 1;
        },
        .exe => |x| for (x.args) |a| guardsIn(a, call),
        .unary => |u| guardsIn(u.operand, call),
        .binary => |b| {
            guardsIn(b.lhs, call);
            guardsIn(b.rhs, call);
        },
        .logic => |l| {
            guardsIn(l.lhs, call);
            guardsIn(l.rhs, call);
        },
        else => {},
    }
}

/// `text` without its `//` and `/* */` comments (a name only in a comment is no use).
pub fn uncommented(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"') {
            const e = if (std.mem.indexOfScalarPos(u8, text, i + 1, '"')) |k| k + 1 else text.len;
            try out.appendSlice(a, text[i..e]);
            i = e;
        } else if (std.mem.startsWith(u8, text[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (std.mem.startsWith(u8, text[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |k| k + 2 else text.len;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
    return out.items;
}

test "uncommented: strings kept, comments gone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = try uncommented(arena.allocator(), "a(\"x//y\"); // PlaceActor(\"s\")\n/* \"t\" */b;");
    try std.testing.expectEqualStrings("a(\"x//y\"); \nb;", t);
}

/// One text replacement.
pub const Edit = struct {
    span: Span,
    text: []const u8,
};

/// `text` with `edits` applied (spans of the original text, not overlapping).
pub fn apply(gpa: Allocator, text: []const u8, edits: []Edit) ![]u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.span.start < b.span.start;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    for (edits) |e| {
        try out.appendSlice(gpa, text[at..e.span.start]);
        try out.appendSlice(gpa, e.text);
        at = e.span.end;
    }
    try out.appendSlice(gpa, text[at..]);
    return out.toOwnedSlice(gpa);
}

/// `text` with each tile of a battle grid gone from `from` to `to` cells (PlaceActor's,
/// PlaceCombatActor's, AIEnemyAppear's two and the AIFreeTile guards before it): `split`
/// (the same floor cut finer or coarser) scales it to the cell over the same spot; a tile
/// still off the grid (a shrunk one) is moved onto its nearest edge tile (not dropped: the
/// fighter would stand nowhere; the editor shows where it went). An appearing enemy's
/// start off the grid (it walks on from there) stays off, as far past the same edge.
/// Null when nothing changes. `first`: the first call moved off the grid, `moved` their count.
/// `s`: the calls of `text` (`scan`).
pub fn remapTiles(gpa: Allocator, text: []const u8, s: Script, from: [2]u32, to: [2]u32, split: bool) !?struct { text: []u8, first: []const u8, moved: usize } {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var edits: std.ArrayList(Edit) = .empty;
    var guards: std.AutoHashMapUnmanaged(usize, void) = .empty;
    var first: []const u8 = "";
    var moved: usize = 0;
    for (s.calls) |cl| {
        var off = false;
        const n_args: usize = if (cl.func == .enemy_appear) 4 else 2;
        for (0..n_args) |j| {
            const i = j % 2;
            const v = cl.arg(text, j) orelse continue;
            const was: f32 = @floatFromInt(from[i]);
            const n: f32 = @floatFromInt(to[i]);
            const nv = if (cl.func == .enemy_appear and j < 2 and (v < 0 or v >= was))
                (if (v < 0) v else v - was + n)
            else blk: {
                const scaled = if (!split) v else if (cl.func == .place_combat) (v + 0.5) * n / was - 0.5 else @floor((v + 0.5) * n / was);
                const c = std.math.clamp(scaled, 0, n - 1);
                off = off or c != scaled;
                break :blk c;
            };
            if (nv != v) try edits.append(a, .{ .span = cl.args[j], .text = try std.fmt.allocPrint(a, "{d}", .{nv}) });
        }
        // Guards may head a block of several calls: each edited once.
        for (cl.guards[0..cl.n_guards]) |g| if (!(try guards.getOrPut(a, g[0].start)).found_existing) for (g, 0..) |sp, i| {
            const v = std.fmt.parseFloat(f32, text[sp.start..sp.end]) catch continue;
            const n: f32 = @floatFromInt(to[i]);
            const c = std.math.clamp(if (split) @floor((v + 0.5) * n / @as(f32, @floatFromInt(from[i]))) else v, 0, n - 1);
            if (c != v) try edits.append(a, .{ .span = sp, .text = try std.fmt.allocPrint(a, "{d}", .{c}) });
        };
        if (!off) continue;
        if (moved == 0) first = cl.name;
        moved += 1;
    }
    if (edits.items.len == 0) return null;
    return .{ .text = try apply(gpa, text, edits.items), .first = first, .moved = moved };
}

/// Span removing statement `s` with its line when nothing else is on it.
pub fn lineOf(text: []const u8, s: Span) Span {
    var a = s.start;
    while (a > 0 and (text[a - 1] == ' ' or text[a - 1] == '\t')) a -= 1;
    var b = s.end;
    while (b < text.len and (text[b] == ' ' or text[b] == '\t')) b += 1;
    const own_line = (a == 0 or text[a - 1] == '\n') and (b == text.len or text[b] == '\r' or text[b] == '\n');
    if (!own_line) return s;
    if (b < text.len and text[b] == '\r') b += 1;
    if (b < text.len and text[b] == '\n') b += 1;
    return .{ .start = a, .end = b };
}

/// Line ending used by the script.
pub fn newline(text: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
}

/// Offset of the start of the line holding restore()'s closing brace (new calls go there).
pub fn insertPoint(text: []const u8, restore_close: usize) usize {
    var a = restore_close;
    while (a > 0 and text[a - 1] != '\n') a -= 1;
    return a;
}

const sample =
    "#inherit CombatLevel\r\n" ++
    "function restore()\r\n" ++
    "{\r\n" ++
    "    PlaceActor(\"Sullivan\",4,3);\r\n" ++
    "    //PlaceActor(\"01h_sfinks\",1,6,5);\r\n" ++
    "    AIEnemyAppear(\"01h_sfinks\", 2, 10, 2, 6);\r\n" ++
    "    PlaceActor(\"01h_sfinks2\",10,9,5);\r\n" ++
    "    PlaceCombatActor(\"01h_pipe1\", 5.5, 7.0, -15);\r\n" ++
    "    if (x) { PlaceActor(\"late\",1,1); }\r\n" ++
    "    PlaceActor(\"Sullivan\", \"start\", 0);\r\n" ++
    "};\r\n" ++
    "function update()\r\n" ++
    "{\r\n" ++
    "    PlaceActor(\"wave\",3,3);\r\n" ++
    "};\r\n" ++
    "function CombatEnemiesAppear()\r\n" ++
    "{\r\n" ++
    "    if (killedEnemies >= 1) { AIEnemyAppear(\"late\", 3, 11, 3, 9); };\r\n" ++
    "    else\r\n" ++
    "    if(AIFreeTile(4,9))\r\n" ++
    "    if(AIFreeTile( 5, 10))\r\n" ++
    "    {\r\n" ++
    "        EnableObject(\"late\");\r\n" ++
    "        AIEnemyAppear(\"late\", 4, 11, 4, 9);\r\n" ++
    "    };\r\n" ++
    "};\r\n";

/// `Script` of `sample` compiled as the model does (its functions' IR).
fn testScan(gpa: Allocator, text: []const u8) !Script {
    const script = @import("opengorky").script;
    const import = script.classic.import;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Src = struct {
        a: Allocator,
        text: []const u8,
        fn unit(ctx: *anyopaque, file: []const u8, diag: *script.parser.Diagnostic) anyerror!import.Loaded {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!std.mem.eql(u8, file, "t.lev")) return error.ScriptNotFound;
            return .{ .unit = try script.parser.parse(self.a, self.text, diag), .key = file };
        }
        fn callee(_: *anyopaque, _: u32) import.Callee {
            return .{};
        }
    };
    var src: Src = .{ .a = a, .text = text };
    const env: import.Env = .{ .ctx = &src, .unit = Src.unit, .callee = Src.callee };
    var diag: script.parser.Diagnostic = .{};
    const u = try script.parser.parse(a, text, &diag);
    var fns: std.ArrayList(*const ir.Fn) = .empty;
    var restore: ?ir.Span = null;
    for (u.items) |*it| if (it.* == .function) {
        const func = try a.create(script.object.Func);
        func.* = .{ .ast = &it.function, .file = "t.lev" };
        const f = (try import.function(a, a, env, func)).ir;
        if (std.ascii.eqlIgnoreCase(f.name, "restore")) restore = f.span;
        try fns.append(a, f);
    };
    return build(gpa, text, try model.sitesOf(a, text, "t.lev", fns.items, &call_names), restore);
}

test "scan: calls, comments, restore depth" {
    const gpa = std.testing.allocator;
    var s = try testScan(gpa, sample);
    defer s.deinit(gpa);
    try std.testing.expectEqual(8, s.calls.len);
    try std.testing.expect(s.calls[6].in_appear and !s.calls[5].in_appear);
    try std.testing.expectEqual(0, s.calls[6].n_guards);
    try std.testing.expectEqual(2, s.calls[7].n_guards);
    try std.testing.expectEqualStrings("10", sample[s.calls[7].guards[1][1].start..s.calls[7].guards[1][1].end]);
    try std.testing.expectEqualStrings("Sullivan", s.calls[0].name);
    try std.testing.expectEqual(Func.enemy_appear, s.calls[1].func);
    try std.testing.expectEqual(10, s.calls[1].arg(sample, 1).?);
    try std.testing.expectEqual(-15, s.calls[3].arg(sample, 2).?);
    try std.testing.expect(s.calls[3].in_restore);
    try std.testing.expect(!s.calls[4].in_restore); // inside if
    try std.testing.expect(!s.calls[5].in_restore); // update()
    try std.testing.expectEqual('}', sample[s.restore_close.?]);
}

test "apply: move, delete, insert keep the rest" {
    const gpa = std.testing.allocator;
    var s = try testScan(gpa, sample);
    defer s.deinit(gpa);
    const sf2 = s.calls[2];
    var edits = [_]Edit{
        .{ .span = sf2.args[0], .text = "7" },
        .{ .span = sf2.args[1], .text = "8" },
        .{ .span = lineOf(sample, s.calls[0].stmt), .text = "" },
        .{ .span = .{ .start = insertPoint(sample, s.restore_close.?), .end = insertPoint(sample, s.restore_close.?) }, .text = "    PlaceActor(\"new\", 1, 2, 0);\r\n" },
    };
    const out = try apply(gpa, sample, &edits);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "PlaceActor(\"01h_sfinks2\",7,8,5);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Sullivan\",4,3") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    PlaceActor(\"new\", 1, 2, 0);\r\n};\r\nfunction update") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "{\r\n    //PlaceActor") != null);
}

test "remapTiles: a shrunk grid's tiles onto its edge, a split grid's scaled" {
    const gpa = std.testing.allocator;
    var s = try testScan(gpa, sample);
    defer s.deinit(gpa);
    const r = (try remapTiles(gpa, sample, s, .{ 12, 12 }, .{ 4, 4 }, false)).?;
    defer gpa.free(r.text);
    try std.testing.expectEqual(6, r.moved);
    try std.testing.expectEqualStrings("Sullivan", r.first);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "PlaceActor(\"Sullivan\",3,3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "PlaceActor(\"01h_sfinks2\",3,3,5);") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "PlaceActor(\"wave\",3,3);") != null);
    try std.testing.expectEqual(null, try remapTiles(gpa, sample, s, .{ 12, 12 }, .{ 20, 20 }, false));
    // 12 → 6 cells over the same floor: tile 10 → 5, 4 → 2.
    const sp = (try remapTiles(gpa, sample, s, .{ 12, 12 }, .{ 6, 6 }, true)).?;
    defer gpa.free(sp.text);
    try std.testing.expectEqual(0, sp.moved);
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "PlaceActor(\"01h_sfinks2\",5,4,5);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "PlaceActor(\"Sullivan\",2,1);") != null);
    // Appearing enemies: an off-grid start stays as far off; targets and guards scale.
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "AIEnemyAppear(\"late\", 1, 5, 1, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "AIFreeTile(2,4)") != null and std.mem.indexOf(u8, sp.text, "AIFreeTile( 2, 5)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp.text, "PlaceCombatActor(\"01h_pipe1\", 2.5, 3.25,") != null);
    const sh = (try remapTiles(gpa, sample, s, .{ 12, 12 }, .{ 12, 10 }, false)).?;
    defer gpa.free(sh.text);
    try std.testing.expect(std.mem.indexOf(u8, sh.text, "AIEnemyAppear(\"late\", 4, 9, 4, 9);") != null);
}
