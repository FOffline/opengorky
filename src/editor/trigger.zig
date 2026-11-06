//! New trigger areas: a polygon appended to the level's `.ar` and a block in its `.lev`
//! update() that runs once when a hero walks in — the game's own pattern
//! (`if(trupy && HeroInArea("trupy")) { trupy = 0; … };` in 01_port.lev). The `.ar` is
//! data (no 's' flag); the exe finds the area by name, ignoring case.

const std = @import("std");
const Allocator = std.mem.Allocator;
const placement = @import("placement.zig");
const lineStart = @import("code.zig").lineStart;
const lineAfter = @import("code.zig").lineAfter;
const funcBody = @import("box.zig").funcBody;
const og = @import("opengorky");
const ir = og.script.ir;

/// A free area name `<prefix><n>` (from 1) in `ar` (the text of `<level>.ar`).
pub fn freeName(buf: []u8, ar: []const u8, prefix: []const u8) []const u8 {
    return @import("freename.zig").freeName(buf, prefix, .{ .sep = "", .bare = false, .from = 1 }, ar, hasArea) catch prefix;
}

pub fn hasArea(ar: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, ar, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "areaName:") and std.ascii.eqlIgnoreCase(std.mem.trim(u8, l["areaName:".len..], " \t"), name)) return true;
    }
    return false;
}

/// `ar` with area `name` (points in background pixels) added and `areaCnt` raised;
/// its control point (where a hero walks to use it) `control`, else the middle.
pub fn addArea(gpa: Allocator, ar: []const u8, name: []const u8, pts: []const [2]i32, control: ?[2]i32) ![]u8 {
    const nl = placement.newline(ar);
    const key = "areaCnt=";
    const k = std.mem.indexOf(u8, ar, key) orelse return error.NoAreaCount;
    var e = k + key.len;
    while (e < ar.len and std.ascii.isDigit(ar[e])) e += 1;
    const cnt = try std.fmt.parseInt(u32, ar[k + key.len .. e], 10);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{s}{s}{d}", .{ ar[0..k], key, cnt + 1 });
    try out.appendSlice(gpa, std.mem.trimEnd(u8, ar[e..], " \t\r\n"));
    try out.print(gpa, "{s}areaName: {s}{s}pointCnt={d}{s}", .{ nl, name, nl, pts.len, nl });
    var c: [2]i64 = .{ 0, 0 };
    for (pts) |p| {
        try out.print(gpa, "{d},{d},0.000000{s}", .{ p[0], p[1], nl });
        c = .{ c[0] + p[0], c[1] + p[1] };
    }
    const n: i64 = @intCast(@max(1, pts.len));
    const cp: [2]i64 = if (control) |q| .{ q[0], q[1] } else .{ @divTrunc(c[0], n), @divTrunc(c[1], n) };
    try out.print(gpa, "controlPoint: {d},{d},0.000000{s}", .{ cp[0], cp[1], nl });
    return out.toOwnedSlice(gpa);
}

/// `lev` with a one-shot trigger on area `name`: `int ready_<name>;` declared before
/// init(), set to 1 first in init(), and the block at the end of update() (a new
/// update() if there is none). `at`: where the block's body line is, for the cursor.
pub fn addTrigger(gpa: Allocator, lev: []const u8, name: []const u8) !struct { text: []u8, at: usize } {
    const nl = placement.newline(lev);
    const init_head = std.mem.indexOf(u8, lev, "function init(") orelse return error.NoInit;
    const init_body = funcBody(lev, "init") orelse return error.NoInit;
    const after_open = lineAfter(lev, init_body.start - 1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, lev[0..init_head]);
    try out.print(gpa, "int ready_{s};   // trigger made in the editor{s}{s}", .{ name, nl, nl });
    try out.appendSlice(gpa, lev[init_head..after_open]);
    try out.print(gpa, "  ready_{s} = 1;{s}", .{ name, nl });
    var at: usize = 0;
    if (funcBody(lev, "update")) |ub| {
        // Before update()'s closing brace.
        try out.appendSlice(gpa, lev[after_open..ub.end]);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(gpa, nl);
        at = try block(gpa, &out, name, nl);
        try out.appendSlice(gpa, lev[ub.end..]);
    } else {
        try out.appendSlice(gpa, std.mem.trimEnd(u8, lev[after_open..], " \t\r\n"));
        try out.print(gpa, "{s}{s}function update(){s}{{{s}", .{ nl, nl, nl, nl });
        at = try block(gpa, &out, name, nl);
        try out.print(gpa, "}};{s}", .{nl});
    }
    return .{ .text = try out.toOwnedSlice(gpa), .at = at };
}

/// A name the scripts and `.ar` take as is: letters, digits, `_`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

/// Where area `name`'s block is in `ar`: its `areaName:` line up to the next one (or the end).
fn areaSpan(ar: []const u8, name: []const u8) ?[2]usize {
    var i: usize = 0;
    var start: ?usize = null;
    while (i < ar.len) {
        const e = lineAfter(ar, i);
        const l = std.mem.trim(u8, ar[i..e], " \t\r\n");
        if (std.mem.startsWith(u8, l, "areaName:")) {
            if (start) |st| return .{ st, i };
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l["areaName:".len..], " \t"), name)) start = i;
        }
        i = e;
    }
    return if (start) |st| .{ st, ar.len } else null;
}

/// `ar` with `areaCnt` changed by `delta` and `mid` put over `span`.
fn rebuild(gpa: Allocator, ar: []const u8, span: [2]usize, mid: []const u8, delta: i32) ![]u8 {
    const key = "areaCnt=";
    const k = std.mem.indexOf(u8, ar, key) orelse return error.NoAreaCount;
    var e = k + key.len;
    while (e < ar.len and std.ascii.isDigit(ar[e])) e += 1;
    const cnt = try std.fmt.parseInt(i32, ar[k + key.len .. e], 10);
    return std.fmt.allocPrint(gpa, "{s}{s}{d}{s}{s}{s}", .{ ar[0..k], key, cnt + delta, ar[e..span[0]], mid, ar[span[1]..] });
}

/// `ar` without area `name`.
pub fn removeArea(gpa: Allocator, ar: []const u8, name: []const u8) ![]u8 {
    return rebuild(gpa, ar, areaSpan(ar, name) orelse return error.NoArea, "", -1);
}

/// `ar` with area `name`'s points moved by `d` (background pixels) and its control
/// point at `control`; the heights stay as written.
pub fn moveArea(gpa: Allocator, ar: []const u8, name: []const u8, d: [2]i32, control: [2]i32) ![]u8 {
    const sp = areaSpan(ar, name) orelse return error.NoArea;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, ar[0..sp[0]]);
    var i = sp[0];
    while (i < sp[1]) {
        const e = lineAfter(ar, i);
        const line = ar[i..e];
        const body = std.mem.trimEnd(u8, line, "\r\n");
        const tail = line[body.len..];
        const cp = "controlPoint:";
        const is_cp = std.mem.startsWith(u8, std.mem.trim(u8, body, " \t"), cp);
        var f = std.mem.splitScalar(u8, if (is_cp) std.mem.trim(u8, std.mem.trim(u8, body, " \t")[cp.len..], " \t") else body, ',');
        const xs = f.next() orelse "";
        const ys = f.next() orelse "";
        const rest = f.rest();
        const x = std.fmt.parseFloat(f32, std.mem.trim(u8, xs, " \t")) catch null;
        const y = std.fmt.parseFloat(f32, std.mem.trim(u8, ys, " \t")) catch null;
        if (x == null or y == null or std.mem.indexOfScalar(u8, body, '=') != null) {
            try out.appendSlice(gpa, line);
        } else if (is_cp) {
            try out.print(gpa, "controlPoint: {d},{d},{s}{s}", .{ control[0], control[1], rest, tail });
        } else {
            const nx: i32 = @as(i32, @intFromFloat(@round(x.?))) + d[0];
            const ny: i32 = @as(i32, @intFromFloat(@round(y.?))) + d[1];
            try out.print(gpa, "{d},{d},{s}{s}", .{ nx, ny, rest, tail });
        }
        i = e;
    }
    try out.appendSlice(gpa, ar[sp[1]..]);
    return out.toOwnedSlice(gpa);
}

/// `ar` with area `old` named `new`.
pub fn renameArea(gpa: Allocator, ar: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const sp = areaSpan(ar, old) orelse return error.NoArea;
    const e = lineAfter(ar, sp[0]);
    const nl = if (std.mem.endsWith(u8, ar[sp[0]..e], "\r\n")) "\r\n" else "\n";
    const line = try std.fmt.allocPrint(gpa, "areaName: {s}{s}", .{ new, nl });
    defer gpa.free(line);
    return rebuild(gpa, ar, .{ sp[0], e }, line, 0);
}

/// `lev` without the trigger `addTrigger` made for `name` (its variable, arming line
/// and block); the same text if there is none.
pub fn removeTrigger(gpa: Allocator, lev: []const u8, name: []const u8) ![]u8 {
    var out = try gpa.dupe(u8, lev);
    errdefer gpa.free(out);
    var vb: [64]u8 = undefined;
    const v = try std.fmt.bufPrint(&vb, "ready_{s}", .{name});
    // The block: from its `if(ready_<name> && …` line to its closing `};`.
    var ib: [80]u8 = undefined;
    if (std.mem.indexOf(u8, out, try std.fmt.bufPrint(&ib, "if({s} &&", .{v}))) |at| {
        const ls = lineStart(out, at);
        const i = closeOf(out, std.mem.indexOfScalarPos(u8, out, at, '{') orelse return out);
        const end = lineAfter(out, i);
        out = try cut(gpa, out, ls, end);
    }
    // `ready_<name> = 1;` and `int ready_<name>;` lines (with the blank line after it).
    var k: usize = 0;
    while (k < out.len) {
        const e = lineAfter(out, k);
        const l = std.mem.trim(u8, out[k..e], " \t\r\n");
        const assign = std.mem.startsWith(u8, l, v) and std.mem.endsWith(u8, std.mem.trim(u8, l[v.len..], " "), "= 1;");
        const rest = if (std.mem.startsWith(u8, l, "int ")) std.mem.trimStart(u8, l[4..], " \t") else "";
        const decl = std.mem.startsWith(u8, rest, v) and rest.len > v.len and rest[v.len] == ';';
        if (assign or decl) {
            var to = e;
            if (decl and to < out.len and std.mem.trim(u8, out[to..lineAfter(out, to)], " \t\r\n").len == 0) to = lineAfter(out, to);
            out = try cut(gpa, out, k, to);
            continue;
        }
        k = e;
    }
    return out;
}

/// `text` with `"old"` (any case) as `"new"` and the variable `ready_old` as `ready_new`.
pub fn renameRefs(gpa: Allocator, text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    return rename(gpa, text, old, new, true);
}

/// `text` with `"old"` (any case) as `"new"` only (a scene's name in the scripts).
pub fn renameQuoted(gpa: Allocator, text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    return rename(gpa, text, old, new, false);
}

fn rename(gpa: Allocator, text: []const u8, old: []const u8, new: []const u8, vars: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var ob: [64]u8 = undefined;
    const ov = try std.fmt.bufPrint(&ob, "ready_{s}", .{old});
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"' and i + old.len + 1 < text.len and text[i + old.len + 1] == '"' and std.ascii.eqlIgnoreCase(text[i + 1 .. i + 1 + old.len], old)) {
            try out.print(gpa, "\"{s}\"", .{new});
            i += old.len + 2;
            continue;
        }
        const ident_before = i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_');
        const after = i + ov.len;
        if (vars and !ident_before and std.mem.startsWith(u8, text[i..], ov) and (after >= text.len or !(std.ascii.isAlphanumeric(text[after]) or text[after] == '_'))) {
            try out.print(gpa, "ready_{s}", .{new});
            i = after;
            continue;
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The `}` matching the `{` at `open` (quoted text skipped); the end if there is none.
fn closeOf(text: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        '"' => i = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse text.len - 1,
        else => {},
    };
    return text.len;
}

fn cut(gpa: Allocator, text: []u8, a: usize, b: usize) ![]u8 {
    const r = try std.mem.concat(gpa, u8, &.{ text[0..a], text[b..] });
    gpa.free(text);
    return r;
}

fn block(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, nl: []const u8) !usize {
    try out.print(gpa, "  if(ready_{s} && HeroInArea(\"{s}\")){s}  {{{s}    ready_{s} = 0;{s}", .{ name, name, nl, nl, name, nl });
    const at = out.items.len;
    try out.print(gpa, "    // what happens, e.g. a hero joins (02_serwers.lev): EnableObject(\"Medusa\"); HERO_EnableEnumerate(\"Medusa\",1); StartScriptlet(\"scene1\");{s}  }};{s}", .{ nl, nl });
    return at;
}

// ------------------------------------------------------------ party

/// The level-script calls the game makes for a hero joining or leaving the party.
/// Joining as McFadden in 02_serwers.lev: shown, then in the party (HERO_EnableEnumerate
/// 0x4c1970 sets avoidEnumerate and rebuilds the party, 0x481ce0). Leaving as Medusa in
/// 03_museum_observator.lev, then gone for good as the scenes' DELETEOBJECT
/// (museum-slavsky_out.scr; DeleteObject 0x4c0540 only marks it, so the party goes first).
pub fn partyCalls(buf: []u8, hero: []const u8, join: bool, nl: []const u8) ![]const u8 {
    return if (join)
        std.fmt.bufPrint(buf, "    EnableObject(\"{s}\");   // joins the party{s}    HERO_EnableEnumerate(\"{s}\",1);{s}", .{ hero, nl, hero, nl })
    else
        std.fmt.bufPrint(buf, "    HERO_EnableEnumerate(\"{s}\",0);   // leaves the party{s}    DeleteObject(\"{s}\");{s}", .{ hero, nl, hero, nl });
}

/// `lev` with `calls` last in the block that runs when a hero walks into area `area`:
/// the first `if(… HeroInArea("<area>"))` block, addTrigger's or the game's own.
pub fn addToAreaBlock(gpa: Allocator, lev: []const u8, area: []const u8, calls: []const u8) ![]u8 {
    return addToBlockOf(gpa, lev, "HeroInArea", area, calls);
}

/// `addToAreaBlock` of a level's OG Script (`hero::AnyInArea("<area>")`).
pub fn addToAreaBlockOg(gpa: Allocator, logic: []const u8, area: []const u8, calls: []const u8) ![]u8 {
    return addToBlockOf(gpa, logic, "hero::AnyInArea", area, calls);
}

fn addToBlockOf(gpa: Allocator, lev: []const u8, call: []const u8, area: []const u8, calls: []const u8) ![]u8 {
    var qb: [128]u8 = undefined;
    const at = std.ascii.findIgnoreCase(lev, try std.fmt.bufPrint(&qb, "{s}(\"{s}\")", .{ call, area })) orelse return error.NoTrigger;
    const close = closeOf(lev, std.mem.indexOfScalarPos(u8, lev, at, '{') orelse return error.NoTrigger);
    if (close == lev.len) return error.NoTrigger;
    // Before the closing brace's line when the brace starts it.
    const ls = lineStart(lev, close);
    const ins = if (std.mem.trim(u8, lev[ls..close], " \t").len == 0) ls else close;
    return std.mem.concat(gpa, u8, &.{ lev[0..ins], calls, lev[ins..] });
}

/// `lev` with hero `stem` hidden first in post_init() until a script shows it, as the
/// game's level heroes (`DisableObject("MacFadden");` in 02_serwers.lev).
pub fn hideHero(gpa: Allocator, lev: []const u8, stem: []const u8) ![]u8 {
    const pb = funcBody(lev, "post_init") orelse return error.NoPostInit;
    const at = lineAfter(lev, pb.start);
    return std.fmt.allocPrint(gpa, "{s}  DisableObject(\"{s}\");   // hero added in the editor: hidden until a scene shows it\r\n{s}", .{ lev[0..at], stem, lev[at..] });
}

test "partyCalls into a trigger block; hideHero" {
    const gpa = std.testing.allocator;
    const lev = "function post_init()\r\n{\r\n  a();\r\n};\r\nfunction update()\r\n{\r\n  if(ready_t1 && HeroInArea(\"t1\"))\r\n  {\r\n    ready_t1 = 0;\r\n  };\r\n};\r\n";
    var buf: [256]u8 = undefined;
    const out = try addToAreaBlock(gpa, lev, "T1", try partyCalls(&buf, "bt_2", false, "\r\n"));
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    ready_t1 = 0;\r\n    HERO_EnableEnumerate(\"bt_2\",0);   // leaves the party\r\n    DeleteObject(\"bt_2\");\r\n  };\r\n};") != null);
    try std.testing.expectError(error.NoTrigger, addToAreaBlock(gpa, lev, "t2", "x"));
    const h = try hideHero(gpa, lev, "bt_2");
    defer gpa.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "function post_init()\r\n{\r\n  DisableObject(\"bt_2\");"));
    try std.testing.expectEqualStrings("    EnableObject(\"x\");   // joins the party\n    HERO_EnableEnumerate(\"x\",1);\n", try partyCalls(&buf, "x", true, "\n"));
}

// ------------------------------------------------------------ exits

/// Hints an exit can show over it (string.tab ids of the game's active areas).
pub const exit_labels = [_]u16{ 218, 243, 200, 202, 205, 214, 267 };

/// Script of a clickable exit on area `area`, as the game's (`store_enter_are.are`):
/// clicked, the hero walks to the area's control point, then LevelSwitch() loads
/// `target`. `enable`: heroes the level disabled come back first (a small room's
/// DisableHeroes(), as 01_port_worker's exit). isLevelSwitch only needs to be > 0: the
/// exe's exit cursor is one (0x45135e).
pub fn exitScript(gpa: Allocator, area: []const u8, label: u16, target: []const u8, enable: bool) ![]u8 {
    return std.fmt.allocPrint(gpa, "#include ActiveArea.s\r\n\r\n\r\nfunction init()\r\n{{\r\n  nameID={d};\r\n  areaName=\"{s}\";\r\n\r\n  funcID = -1;\r\n  isLevelSwitch = 1;\r\n}};\r\n\r\nfunction LevelSwitch()\r\n{{\r\n{s}  LEVEL_Load(\"{s}\");\r\n}};\r\n", .{ label, area, if (enable) "  EnableHeroes();\r\n" else "", target });
}

/// Script `text` is the exit of area `area` (its `areaName` and a LevelSwitch()).
pub fn isExitOf(text: []const u8, area: []const u8) bool {
    if (std.mem.indexOf(u8, text, "function LevelSwitch") == null) return false;
    const k = std.mem.indexOf(u8, text, "areaName") orelse return false;
    const q = std.mem.indexOfScalarPos(u8, text, k, '"') orelse return false;
    const e = std.mem.indexOfScalarPos(u8, text, q + 1, '"') orelse return false;
    return std.ascii.eqlIgnoreCase(text[q + 1 .. e], area);
}

/// The level an exit script loads (its first LEVEL_Load), if any.
pub fn exitTarget(text: []const u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, text, "LEVEL_Load(\"") orelse return null;
    const s = k + "LEVEL_Load(\"".len;
    const e = std.mem.indexOfScalarPos(u8, text, s, '"') orelse return null;
    return text[s..e];
}

/// `text` without the lines that are a single call naming `name` first
/// (`EnableObject("Medusa");`, `HERO_EnableEnumerate("Medusa",1);   // …`); every
/// other line as it is.
pub fn dropCallsOf(gpa: Allocator, text: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const e = lineAfter(text, i);
        if (!isCallOf(text[i..e], name)) try out.appendSlice(gpa, text[i..e]);
        i = e;
    }
    return out.toOwnedSlice(gpa);
}

fn isCallOf(line: []const u8, name: []const u8) bool {
    var l = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.indexOf(u8, l, "//")) |k| l = std.mem.trimEnd(u8, l[0..k], " \t");
    if (!std.mem.endsWith(u8, l, ");")) return false;
    const open = std.mem.indexOfScalar(u8, l, '(') orelse return false;
    for (l[0..open]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    const arg = std.mem.trimStart(u8, l[open + 1 ..], " \t");
    return arg.len > name.len + 1 and arg[0] == '"' and std.ascii.eqlIgnoreCase(arg[1 .. name.len + 1], name) and arg[name.len + 1] == '"';
}

test dropCallsOf {
    const gpa = std.testing.allocator;
    const t = "a();\r\n  EnableObject(\"Medusa\");\r\n  HERO_EnableEnumerate( \"medusa\",1);   // x\r\n  if(HeroInArea(\"Medusa\")){\r\n  Foo(\"MedusaX\");\r\n";
    const out = try dropCallsOf(gpa, t, "Medusa");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a();\r\n  if(HeroInArea(\"Medusa\")){\r\n  Foo(\"MedusaX\");\r\n", out);
}

test exitScript {
    const gpa = std.testing.allocator;
    const t = try exitScript(gpa, "exit1", 218, "01_port", true);
    defer gpa.free(t);
    try std.testing.expect(isExitOf(t, "EXIT1"));
    try std.testing.expect(!isExitOf(t, "exit2"));
    try std.testing.expectEqualStrings("01_port", exitTarget(t).?);
    try std.testing.expect(std.mem.indexOf(u8, t, "  EnableHeroes();\r\n  LEVEL_Load") != null);
}

test "addArea: counted, appended as the game writes them" {
    const gpa = std.testing.allocator;
    const ar = "areaCnt=1\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\n";
    var buf: [32]u8 = undefined;
    const name = freeName(&buf, ar, "trigger");
    try std.testing.expectEqualStrings("trigger1", name);
    const out = try addArea(gpa, ar, name, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 20 } }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("areaCnt=2\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\n" ++
        "areaName: trigger1\r\npointCnt=3\r\n0,0,0.000000\r\n10,0,0.000000\r\n10,20,0.000000\r\ncontrolPoint: 6,6,0.000000\r\n", out);
    try std.testing.expect(hasArea(out, "TRIGGER1"));
}

test "addTrigger: declared, armed in init, checked in update" {
    const gpa = std.testing.allocator;
    const lev = "int a;\r\nfunction init()\r\n{\r\n  a = 1;\r\n};\r\nfunction update()\r\n{\r\n  if(a) { a = 0; };\r\n};\r\n";
    const r = try addTrigger(gpa, lev, "t1");
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings("int a;\r\nint ready_t1;   // trigger made in the editor\r\n\r\nfunction init()\r\n{\r\n  ready_t1 = 1;\r\n  a = 1;\r\n};\r\nfunction update()\r\n{\r\n  if(a) { a = 0; };\r\n" ++
        "  if(ready_t1 && HeroInArea(\"t1\"))\r\n  {\r\n    ready_t1 = 0;\r\n    // what happens, e.g. a hero joins (02_serwers.lev): EnableObject(\"Medusa\"); HERO_EnableEnumerate(\"Medusa\",1); StartScriptlet(\"scene1\");\r\n  };\r\n};\r\n", r.text);
    try std.testing.expect(std.mem.startsWith(u8, r.text[r.at..], "    // what happens"));
}

test "removeArea, renameArea: the block and the count" {
    const gpa = std.testing.allocator;
    const ar = "areaCnt=2\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\nareaName: t1\r\npointCnt=1\r\n3,4,0.000000\r\ncontrolPoint: 3,4,0.000000\r\n";
    const r = try removeArea(gpa, ar, "T1");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("areaCnt=1\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\n", r);
    const r2 = try removeArea(gpa, ar, "a");
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("areaCnt=1\r\nareaName: t1\r\npointCnt=1\r\n3,4,0.000000\r\ncontrolPoint: 3,4,0.000000\r\n", r2);
    const n = try renameArea(gpa, ar, "t1", "gate2");
    defer gpa.free(n);
    try std.testing.expect(hasArea(n, "gate2") and !hasArea(n, "t1"));
    try std.testing.expectEqual(ar.len + 3, n.len);
}

test "removeTrigger takes back addTrigger; renameRefs" {
    const gpa = std.testing.allocator;
    const lev = "int a;\r\nfunction init()\r\n{\r\n  a = 1;\r\n};\r\nfunction update()\r\n{\r\n  if(a) { a = 0; };\r\n};\r\n";
    const added = try addTrigger(gpa, lev, "t1");
    defer gpa.free(added.text);
    const renamed = try renameRefs(gpa, added.text, "t1", "door");
    defer gpa.free(renamed);
    try std.testing.expect(std.mem.indexOf(u8, renamed, "ready_door && HeroInArea(\"door\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, renamed, "t1") == null);
    const back = try removeTrigger(gpa, renamed, "door");
    defer gpa.free(back);
    try std.testing.expectEqualStrings(lev, back);
    const none = try removeTrigger(gpa, lev, "zz");
    defer gpa.free(none);
    try std.testing.expectEqualStrings(lev, none);
}

test moveArea {
    const gpa = std.testing.allocator;
    const ar = "areaCnt=2\r\nareaName: a\r\npointCnt=2\r\n1,2,0.000000\r\n3,4,3.059999\r\ncontrolPoint: 1,2,0.000000\r\nareaName: b\r\npointCnt=1\r\n5,6,0.000000\r\ncontrolPoint: 5,6,0.000000\r\n";
    const out = try moveArea(gpa, ar, "A", .{ 10, -1 }, .{ 7, 8 });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("areaCnt=2\r\nareaName: a\r\npointCnt=2\r\n11,1,0.000000\r\n13,3,3.059999\r\ncontrolPoint: 7,8,0.000000\r\nareaName: b\r\npointCnt=1\r\n5,6,0.000000\r\ncontrolPoint: 5,6,0.000000\r\n", out);
}

// ------------------------------------------------------------ OpenGorky (OG Script)
// A location's code on an OpenGorky project: its block's own code, the part `level "<l>" {
// fn … }` of `src/locations/<l>/logic.ogs` (script/ogs/levels.zig: one block with its
// level.ogs and objects.ogs), and its area components (an `exit`'s) in its namespace
// there. The same one-shot pattern as `addTrigger`, in OG Script.

/// A component's or a method's `{` … `}` in a text of OG Script and its first line's
/// indent (leading blanks; none when it does not start its line).
const OgBlock = struct { start: usize, open: usize, close: usize, indent: []const u8 };

fn ogBlock(text: []const u8, open: u32, span: ir.Span) OgBlock {
    const ls = lineStart(text, span.start);
    const lead = text[ls..span.start];
    return .{ .start = span.start, .open = open, .close = span.end - 1, .indent = if (std.mem.trim(u8, lead, " \t").len == 0) lead else "" };
}

/// Component `comp` of `logic` (`host`: one of its hosts; "": any) and, `method` given,
/// that method of it, by the parser's spans (a header split over lines, comments in it are
/// found too); null: none. error.LogicNotParsed: the text has a syntax error.
fn findOg(logic: []const u8, comp: []const u8, host: []const u8, method: ?[]const u8) error{LogicNotParsed}!?OgBlock {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var diag: og.script.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(arena.allocator(), logic, "logic.ogs", &diag) catch return error.LogicNotParsed;
    for (u.modules) |m| for (m.components) |c| {
        if (!std.mem.eql(u8, c.name, comp)) continue;
        if (host.len > 0) for (c.hosts) |h| {
            if (std.mem.eql(u8, h, host)) break;
        } else continue;
        const f = method orelse return ogBlock(logic, c.open, c.span);
        for (c.methods) |fm| if (std.mem.eql(u8, fm.name, f)) return ogBlock(logic, fm.open, fm.span);
        return null;
    };
    return null;
}

/// The last component's block in `logic` (a new one goes after it), if any.
fn lastComponentOg(logic: []const u8) !?OgBlock {
    // (No path asked: nothing allocated.)
    return (try lastOg(std.heap.page_allocator, logic, false)).block;
}

/// The namespace (`locations::_01_port`, in `a`) of the last component of `logic`: where
/// `addExitOg` puts a new one.
pub fn exitModuleOg(a: Allocator, logic: []const u8) ![]const u8 {
    const l = try lastOg(a, logic, true);
    return if (l.module.len == 0) error.NoLogic else l.module;
}

/// The text of a new `logic.ogs` of level `level` (`top`: `locations` or `battles`): its
/// module alone (`locations::_01_port`: as the converter names it, a `_` before a leading
/// digit, other signs as `_`). A level has none until a trigger or an exit needs it.
pub fn newLogicOg(gpa: Allocator, top: []const u8, level: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "module {s}::", .{top});
    if (level.len == 0 or std.ascii.isDigit(level[0])) try out.append(gpa, '_');
    for (level) |ch| try out.append(gpa, if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_');
    try out.appendSlice(gpa, " {\n}\n");
    return out.toOwnedSlice(gpa);
}

/// `logic` with the level's namespace (`newLogicOg`'s, at its end) when it has no module:
/// its part of own code alone (no component of an area yet).
pub fn withModuleOg(gpa: Allocator, logic: []const u8, top: []const u8, level: []const u8) ![]u8 {
    const l = try lastOg(gpa, logic, true);
    defer gpa.free(l.module);
    if (l.module.len > 0) return gpa.dupe(u8, logic);
    const m = try newLogicOg(gpa, top, level);
    defer gpa.free(m);
    const sep = if (logic.len > 0 and logic[logic.len - 1] != '\n') "\n" else "";
    return std.mem.concat(gpa, u8, &.{ logic, sep, m });
}

/// Where a new component of `logic` goes: after its last component (at its indent), else
/// (none yet) before its module's closing `}`.
fn componentSlotOg(logic: []const u8) !struct { at: usize, indent: []const u8 } {
    if (try lastComponentOg(logic)) |last| return .{ .at = lineAfter(logic, last.close), .indent = last.indent };
    // shortcut: the first `module … {` of the text, found as text (a new or empty logic.ogs).
    const m = std.mem.indexOf(u8, logic, "module ") orelse return error.NoLogic;
    const open = std.mem.indexOfScalarPos(u8, logic, m, '{') orelse return error.NoLogic;
    const close = ogsClose(logic, open);
    if (close == logic.len) return error.NoLogic;
    const ls = lineStart(logic, close);
    return .{ .at = if (std.mem.trim(u8, logic[ls..close], " \t").len == 0) ls else close, .indent = "    " };
}

fn lastOg(a: Allocator, logic: []const u8, path: bool) error{ LogicNotParsed, OutOfMemory }!struct { block: ?OgBlock, module: []const u8 } {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var diag: og.script.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(arena.allocator(), logic, "logic.ogs", &diag) catch return error.LogicNotParsed;
    var last: ?OgBlock = null;
    // No component yet: the text's first module (a new logic.ogs).
    var module: []const u8 = for (u.modules) |m| {
        if (m.path.len > 0) break m.path;
    } else "";
    // A level's own code (its part at the root) is no component of its namespace.
    for (u.modules) |m| for (m.components) |c| if (!c.own) {
        if (last == null or c.span.end > last.?.close) {
            last = ogBlock(logic, c.open, c.span);
            module = m.path;
        }
    };
    return .{ .block = last, .module = if (path) try a.dupe(u8, module) else "" };
}

/// The `}` matching the `{` at `open` in OG Script (strings, `//` comments skipped).
fn ogsClose(text: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        '"' => {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) if (text[i] == '\\') {
                i += 1;
            };
        },
        '/' => if (i + 1 < text.len and text[i + 1] == '/') {
            i = lineAfter(text, i) - 1;
        },
        else => {},
    };
    return text.len;
}

/// The part of level `level` (`kind`: `level` or `battle`) at the root of `logic` (its own
/// code there: `level "01_port" { fn … }`) and, `method` given, that method of its own
/// code, by the parser's spans; null: none. error.LogicNotParsed: the text has a syntax error.
fn levelCodeOg(logic: []const u8, kind: []const u8, level: []const u8, method: ?[]const u8) error{LogicNotParsed}!?OgBlock {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var diag: og.script.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(arena.allocator(), logic, "logic.ogs", &diag) catch return error.LogicNotParsed;
    for (u.modules) |m| if (m.path.len == 0) for (m.entities) |e| {
        if (!std.mem.eql(u8, e.kind, kind) or !std.mem.eql(u8, e.name, level)) continue;
        const f = method orelse {
            // Its `{`: after its header (`level "01_port"`, a name of no braces).
            const open = std.mem.indexOfScalarPos(u8, logic, e.span.start, '{') orelse return null;
            return ogBlock(logic, @intCast(open), e.span);
        };
        const c = e.own orelse return null;
        for (c.methods) |fm| if (std.mem.eql(u8, fm.name, f)) return ogBlock(logic, fm.open, fm.span);
        return null;
    };
    return null;
}

/// `logic` with level `level`'s part (an empty one at its end when it has none).
fn withLevelCodeOg(gpa: Allocator, logic: []const u8, kind: []const u8, level: []const u8) ![]u8 {
    if (try levelCodeOg(logic, kind, level, null) != null) return gpa.dupe(u8, logic);
    const word = level.len > 0 and !std.ascii.isDigit(level[0]) and for (level) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') break false;
    } else true;
    const sep = if (logic.len > 0 and logic[logic.len - 1] != '\n') "\n" else "";
    return if (word) std.fmt.allocPrint(gpa, "{s}{s}{s} {s} {{\n}}\n", .{ logic, sep, kind, level }) else std.fmt.allocPrint(gpa, "{s}{s}{s} \"{s}\" {{\n}}\n", .{ logic, sep, kind, level });
}

/// `logic` (a location's logic.ogs; level `level` of `kind`) with a one-shot trigger on area
/// `name`: the block last in its own OnUpdate() (the part and the method made when missing).
/// Its variable `ready_<name>` is the level block's (`addLevelVarOg`).
/// `at`: where the block's body line is.
pub fn addTriggerOg(gpa: Allocator, logic_in: []const u8, kind: []const u8, level: []const u8, name: []const u8) !struct { text: []u8, at: usize } {
    const logic = try withLevelCodeOg(gpa, logic_in, kind, level);
    defer gpa.free(logic);
    const c = try levelCodeOg(logic, kind, level, null) orelse return error.NoLogic;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const after_open = lineAfter(logic, c.open);
    try out.appendSlice(gpa, logic[0..after_open]);
    var at: usize = 0;
    if (try levelCodeOg(logic, kind, level, "OnUpdate")) |u| {
        const ins = lineStart(logic, u.close);
        try out.appendSlice(gpa, logic[after_open..ins]);
        at = try blockOg(gpa, &out, name, u.indent);
        try out.appendSlice(gpa, logic[ins..]);
    } else {
        const ins = lineStart(logic, c.close);
        try out.appendSlice(gpa, logic[after_open..ins]);
        try out.print(gpa, "{s}    fn OnUpdate() {{\n", .{c.indent});
        const ind = try std.fmt.allocPrint(gpa, "{s}    ", .{c.indent});
        defer gpa.free(ind);
        at = try blockOg(gpa, &out, name, ind);
        try out.print(gpa, "{s}    }}\n", .{c.indent});
        try out.appendSlice(gpa, logic[ins..]);
    }
    return .{ .text = try out.toOwnedSlice(gpa), .at = at };
}

fn blockOg(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, fn_indent: []const u8) !usize {
    try out.print(gpa, "{s}    if (ready_{s} and hero::AnyInArea(\"{s}\")) {{\n{s}        ready_{s} = false;\n", .{ fn_indent, name, name, fn_indent, name });
    const at = out.items.len;
    try out.print(gpa, "{s}        // what happens, e.g. a hero joins: object::Enable(\"Medusa\"); hero::SetInParty(\"Medusa\", 1); scene::Start(~e\"scene1\");\n{s}    }}\n", .{ fn_indent, fn_indent });
    return at;
}

/// `logic` without the trigger `addTriggerOg` made for `name` (its block; an OnUpdate() it
/// made stays, empty; a variable of an older editor's in the component goes too); the same
/// text if there is none.
pub fn removeTriggerOg(gpa: Allocator, logic: []const u8, name: []const u8) ![]u8 {
    var out = try gpa.dupe(u8, logic);
    errdefer gpa.free(out);
    var ib: [96]u8 = undefined;
    if (std.mem.indexOf(u8, out, try std.fmt.bufPrint(&ib, "if (ready_{s} and ", .{name}))) |at| {
        const close = ogsClose(out, std.mem.indexOfScalarPos(u8, out, at, '{') orelse return out);
        out = try cut(gpa, out, lineStart(out, at), lineAfter(out, close));
    }
    var vb: [96]u8 = undefined;
    const decl = try std.fmt.bufPrint(&vb, "var bool ready_{s} = ", .{name});
    if (std.mem.indexOf(u8, out, decl)) |at| out = try cut(gpa, out, lineStart(out, at), lineAfter(out, at));
    return out;
}

/// The `{` of the level block (`level "01_port" {`) of `level` (a location's level.ogs).
fn levelOpenOg(level: []const u8) error{LogicNotParsed}!?usize {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var diag: og.script.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(arena.allocator(), level, "level.ogs", &diag) catch return error.LogicNotParsed;
    for (u.modules) |m| for (m.entities) |e| if ((std.mem.eql(u8, e.kind, "level") or std.mem.eql(u8, e.kind, "battle")) and !e.span.none()) {
        return std.mem.indexOfScalarPos(u8, level, e.span.start, '{');
    };
    return null;
}

/// `level` (a location's level.ogs) with the trigger's `var bool ready_<name> = true;` first
/// in its level block: the level's variable, shown in "Fields".
pub fn addLevelVarOg(gpa: Allocator, level: []const u8, name: []const u8) ![]u8 {
    const open = try levelOpenOg(level) orelse return error.NoSuchBlock;
    const ins = lineAfter(level, open);
    return std.fmt.allocPrint(gpa, "{s}    var bool ready_{s} = true;\n{s}", .{ level[0..ins], name, level[ins..] });
}

/// `level` without the declaration of variable `name` (its line); the same text if none.
pub fn removeLevelVarOg(gpa: Allocator, level: []const u8, name: []const u8) ![]u8 {
    const v = levelVarOg(level, name) orelse return gpa.dupe(u8, level);
    return std.mem.concat(gpa, u8, &.{ level[0..lineStart(level, v.start)], level[lineAfter(level, v.start)..] });
}

/// The value of `var [type] <name> = <value>;` in `level` (a block's variable, a line of
/// its own as the converter and the editor write it): its bytes.
pub fn levelVarOg(level: []const u8, name: []const u8) ?struct { start: usize, end: usize } {
    var pos: usize = 0;
    while (pos < level.len) : (pos = lineAfter(level, pos)) {
        const end = lineAfter(level, pos);
        const l = level[pos..end];
        const lead = std.mem.indexOfNone(u8, l, " \t") orelse continue;
        if (!std.mem.startsWith(u8, l[lead..], "var ")) continue;
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        var words = std.mem.tokenizeAny(u8, l[lead + 4 .. eq], " \t");
        var last: []const u8 = "";
        while (words.next()) |w| last = w;
        if (!std.mem.eql(u8, last, name)) continue;
        const semi = std.mem.indexOfScalarPos(u8, l, eq, ';') orelse continue;
        const v = std.mem.trim(u8, l[eq + 1 .. semi], " \t");
        const s0 = pos + (std.mem.indexOfPos(u8, l, eq, v) orelse continue);
        return .{ .start = s0, .end = s0 + v.len };
    }
    return null;
}

/// The variable arming the block at `at` of `logic` (a trigger's `if (ready_x and …)`, the
/// converter's `if (readyF01 and …)`): the first name of its `if` condition, if it is
/// followed by `and` (null: the block has no such switch).
pub fn armOg(logic: []const u8, at: usize) ?[]const u8 {
    const sp = @import("scenes.zig").block(logic, at);
    var t = std.mem.trimStart(u8, logic[sp.start..sp.end], " \t");
    if (!std.mem.startsWith(u8, t, "if")) return null;
    t = std.mem.trimStart(u8, t[2..], " \t");
    if (t.len == 0 or t[0] != '(') return null;
    t = std.mem.trimStart(u8, t[1..], " \t");
    const n = std.mem.indexOfNone(u8, t, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") orelse return null;
    if (n == 0 or std.ascii.isDigit(t[0])) return null;
    return if (std.mem.startsWith(u8, std.mem.trimStart(u8, t[n..], " \t"), "and ")) t[0..n] else null;
}

/// Whether `text` sets variable `name` to anything but false/0 (`name = 1;`, `name = x;`):
/// a block it arms can be armed again by code, so its declaration alone does not turn it off.
pub fn rearmedOg(text: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, name)) |i| {
        pos = i + name.len;
        if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) continue;
        var r = std.mem.trimStart(u8, text[pos..], " \t");
        if (r.len < 2 or r[0] != '=' or r[1] == '=') continue;
        r = std.mem.trimStart(u8, r[1..], " \t");
        if (!(std.mem.startsWith(u8, r, "false") or std.mem.startsWith(u8, r, "0;") or std.mem.startsWith(u8, r, "0 "))) return true;
    }
    return false;
}

/// `level` with variable `name`'s initial value on (true/1) or off (false/0), in its kind.
pub fn setLevelVarOg(gpa: Allocator, level: []const u8, name: []const u8, on: bool) ![]u8 {
    const v = levelVarOg(level, name) orelse return error.NoSuchVar;
    const old = level[v.start..v.end];
    const words = std.mem.eql(u8, old, "true") or std.mem.eql(u8, old, "false");
    const new: []const u8 = if (words) (if (on) "true" else "false") else (if (on) "1" else "0");
    return std.mem.concat(gpa, u8, &.{ level[0..v.start], new, level[v.end..] });
}

/// Whether the variable's initial value is on (anything but false/0).
pub fn levelVarOn(level: []const u8, name: []const u8) bool {
    const v = levelVarOg(level, name) orelse return true;
    const t = level[v.start..v.end];
    return !(std.mem.eql(u8, t, "false") or std.mem.eql(u8, t, "0"));
}

/// The OG Script calls for a hero joining or leaving the party (`partyCalls`), indented
/// `indent`.
pub fn partyCallsOg(buf: []u8, hero: []const u8, join: bool, indent: []const u8) ![]const u8 {
    return if (join)
        std.fmt.bufPrint(buf, "{s}object::Enable(\"{s}\");   // joins the party\n{s}hero::SetInParty(\"{s}\", 1);\n", .{ indent, hero, indent, hero })
    else
        std.fmt.bufPrint(buf, "{s}hero::SetInParty(\"{s}\", 0);   // leaves the party\n{s}object::Delete(\"{s}\");\n", .{ indent, hero, indent, hero });
}

/// An exit's component in OG Script (`exitScript`'s LevelSwitch() as the area's
/// `OnExit`): `comp` loads `target`, heroes the level disabled back first (`enable`).
/// Put last in the module of `logic` (before its closing `}`).
pub fn addExitOg(gpa: Allocator, logic: []const u8, comp: []const u8, target: []const u8, enable: bool) ![]u8 {
    const slot = try componentSlotOg(logic);
    const ins = slot.at;
    const i = slot.indent;
    return std.fmt.allocPrint(gpa, "{s}{s}component {s} for area {{\n{s}    fn OnExit() {{\n{s}{s}{s}        level::Load(~l\"{s}\");\n{s}    }}\n{s}}}\n{s}", .{
        logic[0..ins], i, comp, i, if (enable) i else "", if (enable) "        hero::EnableAll();\n" else "", i, target, i, i, logic[ins..],
    });
}

/// The `{`…`}` of component `comp`'s `fn OnExit(` in `logic`.
fn exitFnOg(logic: []const u8, comp: []const u8) ?[2]usize {
    const f = (findOg(logic, comp, "area", "OnExit") catch null) orelse return null;
    return .{ f.open, f.close };
}

/// The level component `comp`'s OnExit() loads (its first `level::Load(~l"…")`), if any.
pub fn exitTargetOg(logic: []const u8, comp: []const u8) ?[]const u8 {
    const f = exitFnOg(logic, comp) orelse return null;
    const k = std.mem.indexOf(u8, logic[f[0]..f[1]], "level::Load(~l\"") orelse return null;
    const s = f[0] + k + "level::Load(~l\"".len;
    const e = std.mem.indexOfScalarPos(u8, logic, s, '"') orelse return null;
    return logic[s..e];
}

/// `logic` with component `comp`'s OnExit() loading `target` instead.
pub fn setExitTargetOg(gpa: Allocator, logic: []const u8, comp: []const u8, target: []const u8) ![]u8 {
    const old = exitTargetOg(logic, comp) orelse return error.NoTarget;
    const s = @intFromPtr(old.ptr) - @intFromPtr(logic.ptr);
    return std.mem.concat(gpa, u8, &.{ logic[0..s], target, logic[s + old.len ..] });
}

/// Component `comp`'s lines in `logic` (from its line to its closing brace's), if any.
pub fn componentSpanOg(logic: []const u8, comp: []const u8) ?[2]usize {
    const c = (findOg(logic, comp, "", null) catch null) orelse return null;
    return .{ lineStart(logic, c.start), lineAfter(logic, c.close) };
}

/// `logic` without component `comp` (its lines).
pub fn removeComponentOg(gpa: Allocator, logic: []const u8, comp: []const u8) ![]u8 {
    const sp = componentSpanOg(logic, comp) orelse return gpa.dupe(u8, logic);
    return std.mem.concat(gpa, u8, &.{ logic[0..sp[0]], logic[sp[1]..] });
}

test "OG Script: a trigger added and taken back, its party calls, an exit's component" {
    const gpa = std.testing.allocator;
    const logic = "level \"l\" {\n    fn OnUpdate() {\n        if (a == 1) { a = 0; } // }\n    }\n}\nmodule locations::l {\n}\n";
    const r = try addTriggerOg(gpa, logic, "level", "l", "t1");
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings("level \"l\" {\n    fn OnUpdate() {\n        if (a == 1) { a = 0; } // }\n" ++
        "        if (ready_t1 and hero::AnyInArea(\"t1\")) {\n            ready_t1 = false;\n            // what happens, e.g. a hero joins: object::Enable(\"Medusa\"); hero::SetInParty(\"Medusa\", 1); scene::Start(~e\"scene1\");\n        }\n    }\n}\nmodule locations::l {\n}\n", r.text);
    try std.testing.expect(std.mem.startsWith(u8, r.text[r.at..], "            // what happens"));
    var buf: [256]u8 = undefined;
    const p = try addToAreaBlockOg(gpa, r.text, "T1", try partyCallsOg(&buf, "bt_2", true, "            "));
    defer gpa.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "scene1\");\n            object::Enable(\"bt_2\");   // joins the party\n            hero::SetInParty(\"bt_2\", 1);\n        }\n") != null);
    const back = try removeTriggerOg(gpa, r.text, "t1");
    defer gpa.free(back);
    try std.testing.expectEqualStrings(logic, back);
    // No OnUpdate(), no part of the level: both made (a battle's, by its word).
    const bare = "module m {\n    component c for area {\n    }\n}\n";
    const r2 = try addTriggerOg(gpa, bare, "battle", "b1", "x");
    defer gpa.free(r2.text);
    try std.testing.expect(std.mem.startsWith(u8, r2.text, bare ++ "battle b1 {\n    fn OnUpdate() {\n        if (ready_x and hero::AnyInArea(\"x\")) {\n"));
    // An exit: added, retargeted, removed.
    const ex = try addExitOg(gpa, bare, "exit1_are", "01_port", true);
    defer gpa.free(ex);
    try std.testing.expectEqualStrings("module m {\n    component c for area {\n    }\n    component exit1_are for area {\n        fn OnExit() {\n            hero::EnableAll();\n            level::Load(~l\"01_port\");\n        }\n    }\n}\n", ex);
    try std.testing.expectEqualStrings("01_port", exitTargetOg(ex, "exit1_are").?);
    const re = try setExitTargetOg(gpa, ex, "exit1_are", "04_city");
    defer gpa.free(re);
    try std.testing.expectEqualStrings("04_city", exitTargetOg(re, "exit1_are").?);
    const gone = try removeComponentOg(gpa, re, "exit1_are");
    defer gpa.free(gone);
    try std.testing.expectEqualStrings(bare, gone);
    try std.testing.expectError(error.LogicNotParsed, addTriggerOg(gpa, "module m {\n", "level", "l", "x"));
}

test "OG Script: a level without logic.ogs, the trigger's variable in the level block, a block switched off" {
    const gpa = std.testing.allocator;
    const fresh = try newLogicOg(gpa, "locations", "01_new-x");
    defer gpa.free(fresh);
    try std.testing.expectEqualStrings("module locations::_01_new_x {\n}\n", fresh);
    const r = try addTriggerOg(gpa, fresh, "level", "01_new-x", "t1");
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings("module locations::_01_new_x {\n}\nlevel \"01_new-x\" {\n    fn OnUpdate() {\n        if (ready_t1 and hero::AnyInArea(\"t1\")) {\n            ready_t1 = false;\n" ++
        "            // what happens, e.g. a hero joins: object::Enable(\"Medusa\"); hero::SetInParty(\"Medusa\", 1); scene::Start(~e\"scene1\");\n        }\n    }\n}\n", r.text);
    // A logic.ogs of the level's own code alone: its namespace made for an exit.
    const own_only = try withModuleOg(gpa, "level \"01_new-x\" {\n}\n", "locations", "01_new-x");
    defer gpa.free(own_only);
    try std.testing.expectEqualStrings("level \"01_new-x\" {\n}\nmodule locations::_01_new_x {\n}\n", own_only);
    const kept = try withModuleOg(gpa, fresh, "locations", "01_new-x");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings(fresh, kept);
    const mod = try exitModuleOg(gpa, fresh);
    defer gpa.free(mod);
    try std.testing.expectEqualStrings("locations::_01_new_x", mod);
    const ex = try addExitOg(gpa, fresh, "exit1_are", "01_port", false);
    defer gpa.free(ex);
    try std.testing.expectEqualStrings("module locations::_01_new_x {\n    component exit1_are for area {\n        fn OnExit() {\n            level::Load(~l\"01_port\");\n        }\n    }\n}\n", ex);
    // The variable: the level block's, first.
    const lev = "level \"01_new\" {\n    var int a = 1;\n    entry = \"capt_start\";\n}\n";
    const lv = try addLevelVarOg(gpa, lev, "t1");
    defer gpa.free(lv);
    try std.testing.expectEqualStrings("level \"01_new\" {\n    var bool ready_t1 = true;\n    var int a = 1;\n    entry = \"capt_start\";\n}\n", lv);
    // Switched off by its initial value (the block's own switch), on again.
    const at = std.mem.indexOf(u8, r.text, "\"t1\"").?;
    try std.testing.expectEqualStrings("ready_t1", armOg(r.text, at).?);
    try std.testing.expect(!rearmedOg(r.text, "ready_t1"));
    try std.testing.expect(rearmedOg("x = 1; ready_t1 = 1;", "ready_t1"));
    try std.testing.expect(levelVarOn(lv, "ready_t1"));
    const off = try setLevelVarOg(gpa, lv, "ready_t1", false);
    defer gpa.free(off);
    try std.testing.expect(!levelVarOn(off, "ready_t1") and std.mem.indexOf(u8, off, "var bool ready_t1 = false;\n") != null);
    const a0 = try setLevelVarOg(gpa, off, "a", false);
    defer gpa.free(a0);
    try std.testing.expect(std.mem.indexOf(u8, a0, "var int a = 0;") != null);
    const back = try removeLevelVarOg(gpa, lv, "ready_t1");
    defer gpa.free(back);
    try std.testing.expectEqualStrings(lev, back);
    try std.testing.expect(armOg("x();\nfoo(\"t1\");\n", 6) == null);
}

test "OG Script by the parser's spans: a header over lines, braces in comments and strings" {
    const gpa = std.testing.allocator;
    const logic = "// level \"l\" { (a comment)\nlevel \"l\"\n{\n    fn OnUpdate()\n    {\n        var string s = \"}\";\n    }\n}\nmodule locations::_l {\n    component exit1_are for area { fn OnExit() { level::Load(~l\"01_port\"); } }\n}\n";
    const r = try addTriggerOg(gpa, logic, "level", "l", "t1");
    defer gpa.free(r.text);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "\"}\";\n        if (ready_t1 and hero::AnyInArea(\"t1\")) {\n") != null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: og.script.parser.Diagnostic = .{};
    _ = try og.script.ogs.parser.parse(arena.allocator(), r.text, "logic.ogs", &diag);
    const back = try removeTriggerOg(gpa, r.text, "t1");
    defer gpa.free(back);
    try std.testing.expectEqualStrings(logic, back);
    // A component on one line: its target read and changed, it removed; a new one after it.
    try std.testing.expectEqualStrings("01_port", exitTargetOg(logic, "exit1_are").?);
    const re = try setExitTargetOg(gpa, logic, "exit1_are", "04_city");
    defer gpa.free(re);
    try std.testing.expectEqualStrings("04_city", exitTargetOg(re, "exit1_are").?);
    const ex = try addExitOg(gpa, logic, "exit2_are", "02_x", false);
    defer gpa.free(ex);
    try std.testing.expect(std.mem.endsWith(u8, ex, "} }\n    component exit2_are for area {\n        fn OnExit() {\n            level::Load(~l\"02_x\");\n        }\n    }\n}\n"));
    const gone = try removeComponentOg(gpa, logic, "exit1_are");
    defer gpa.free(gone);
    try std.testing.expect(std.mem.indexOf(u8, gone, "exit1_are") == null and std.mem.endsWith(u8, gone, "module locations::_l {\n}\n"));
    try std.testing.expect(componentSpanOg(logic, "exit1_are") != null);
    const mod = try exitModuleOg(gpa, logic);
    defer gpa.free(mod);
    try std.testing.expectEqualStrings("locations::_l", mod);
    // A text with a syntax error: none found, not a guess.
    try std.testing.expectError(error.LogicNotParsed, addTriggerOg(gpa, "level \"l\" {\n", "level", "l", "x"));
}
