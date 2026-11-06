//! The level page on an OpenGorky project: its camera and a
//! battle's placement live in the level's own block (`src/battles/<b>/battle.ogs`,
//! `src/locations/<l>/level.ogs`), edited through the OG backend (model_og.zig), never in
//! the installed game's files. The camera is the block's `camera = Camera(…)`; a placed
//! object's tile its inner block's `tile = [x, y]`, a hero's its Place in `placement`.
//! The page's world is still read from the installed game (level.Doc): the block's values
//! are laid over it on load (`overlay`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const ir = og.script.ir;
const schema = og.core.schema;
const model = @import("model.zig");
const model_og = model.model_og;
const store_mod = @import("store.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const App = @import("app.zig").App;

/// The level's block file (null: not an OpenGorky project, or no such block).
pub fn blockFile(d: *const Doc) ?usize {
    const app = d.app();
    if (app.store.root == null) return null;
    var buf: [256]u8 = undefined;
    const battle = d.world.battle != null or std.mem.indexOf(u8, d.name, "__") != null;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ if (battle) "battles" else "locations", d.name, if (battle) "battle.ogs" else "level.ogs" }) catch return null;
    const f = app.store.file(store_mod.og_src, path) catch return null;
    return if (model_og.blockOf(app, app.frame.allocator(), f) != null) f else null;
}

/// The block's `camera` record (null: none).
fn camera(app: *App, f: usize) ?ir.Call {
    const e = model.field(app, f, "camera").og_expr orelse return null;
    return if (e.kind == .call) e.kind.call else null;
}

/// Camera key `key` of the block's record (null: it gives none).
pub fn camValue(d: *const Doc, f: usize, key: []const u8) ?f32 {
    const c = camera(d.app(), f) orelse return null;
    return schema.number(schema.recordField(c, key) orelse return null);
}

/// Camera keys `kv` set in the block's record (the others kept): one undo step.
pub fn setCamera(d: *const Doc, f: usize, kv: []const struct { []const u8, f32 }) !void {
    const app = d.app();
    const a = app.frame.allocator();
    var named: std.ArrayList(ir.Named) = .empty;
    if (camera(app, f)) |c| try named.appendSlice(a, c.named);
    for (kv) |x| {
        const v = try model_og.parseValue(a, try std.fmt.allocPrint(a, "{d:.6}", .{x[1]}));
        for (named.items) |*n| {
            if (std.mem.eql(u8, n.name, x[0])) {
                n.value = v;
                break;
            }
        } else try named.append(a, .{ .name = x[0], .value = v });
    }
    const rec = try a.create(ir.Expr);
    rec.* = .{ .line = 0, .kind = .{ .call = .{ .id = 0, .text = "Camera", .args = &.{}, .named = named.items } } };
    try model_og.setExpr(app, f, "camera", rec);
}

/// Name `w` of a Place's `who` (`@Sullivan`, `@"05in_x"`).
fn whoName(a: Allocator, w: *const ir.Expr) []const u8 {
    const t = model_og.exprText(a, w);
    return std.mem.trim(u8, std.mem.trimStart(u8, t, "@"), "\"");
}

/// The tile the block gives object `name` (its inner block's `tile`, else its Place in
/// `placement`); null: none.
fn tileOf(app: *App, a: Allocator, f: usize, name: []const u8) ?[2]i32 {
    if (innerBlock(app, a, f, name)) |of| if (model_og.blockOf(app, a, of)) |b| for (b.e.fields) |x| {
        if (std.mem.eql(u8, x.name, "tile")) return pair(x.value);
    };
    const pl = model.field(app, f, "placement").og_expr orelse return null;
    if (pl.kind != .list) return null;
    for (pl.kind.list) |p| if (p.kind == .call) {
        const who = schema.recordField(p.kind.call, "who") orelse continue;
        if (!std.ascii.eqlIgnoreCase(whoName(a, who), name)) continue;
        return pair(schema.recordField(p.kind.call, "tile") orelse return null);
    };
    return null;
}

/// Object `name`'s block inside the level's block file `f` (null: none).
fn innerBlock(app: *App, a: Allocator, f: usize, name: []const u8) ?usize {
    const of = model_og.innerFile(app, f, name) catch return null;
    return if (model_og.blockOf(app, a, of) != null) of else null;
}

fn pair(e: *const ir.Expr) ?[2]i32 {
    if (e.kind != .list or e.kind.list.len < 2) return null;
    return .{ schema.int(e.kind.list[0]) orelse return null, schema.int(e.kind.list[1]) orelse return null };
}

/// The block's tiles laid over the battle's objects the installed game placed (the page
/// shows the project's placement).
pub fn overlay(d: *Doc, f: usize) void {
    const app = d.app();
    const cm = d.world.map.combat orelse return;
    for (d.objects.items) |*o| {
        if (o.tile == null or o.later != null) continue;
        const t = tileOf(app, app.frame.allocator(), f, o.name) orelse continue;
        o.tile = t;
        o.pos = d.tilePos(cm, t, o.size);
    }
}

/// A free tile of battle `d` for a new fighter ("+ fighter"): the cell nearest the grid's
/// middle that the grid does not block and no object on it covers; null: none (or no grid).
fn freeTile(d: *const Doc) ?[2]i32 {
    const cm = d.world.map.combat orelse return null;
    const mid: [2]i32 = .{ @intCast(cm.width / 2), @intCast(cm.height / 2) };
    var best: ?[2]i32 = null;
    var best_d: i32 = std.math.maxInt(i32);
    for (0..cm.height) |y| next: for (0..cm.width) |x| {
        if (cm.blocked[y * cm.width + x]) continue;
        const t: [2]i32 = .{ @intCast(x), @intCast(y) };
        const dist = (t[0] - mid[0]) * (t[0] - mid[0]) + (t[1] - mid[1]) * (t[1] - mid[1]);
        if (dist >= best_d) continue;
        for (d.objects.items) |o| if (o.tile) |ot| {
            const n: i32 = @intCast(o.size);
            if (t[0] >= ot[0] and t[0] < ot[0] + n and t[1] >= ot[1] and t[1] < ot[1] + n) continue :next;
        };
        best = t;
        best_d = dist;
    };
    return best;
}

/// "+ fighter" on battle block file `f`: a fighter of archetype `base` (`characters::x`,
/// named `x_<n>`) in its objects, standing on a free tile (freeTile) when the battle is
/// the level shown; the page shows it (the project read anew, the level reloaded). One
/// undo step; its name.
pub fn addFighter(app: *App, f: usize, base: []const u8) ![]const u8 {
    const a = app.frame.allocator();
    const objs = model_og.levelObjects(app, a, f);
    const stem = base[if (std.mem.lastIndexOf(u8, base, "::")) |i| i + 2 else 0..];
    var n: usize = 1;
    const name = while (n < 1000) : (n += 1) {
        const x = try std.fmt.allocPrint(a, "{s}_{d}", .{ stem, n });
        for (objs) |o| {
            if (std.ascii.eqlIgnoreCase(o.name, x)) break;
        } else break x;
    } else return error.NoName;
    {
        app.store.group();
        defer app.store.endGroup("+ {s}", .{name});
        try model_og.addInner(app, f, "fighter", name, base);
        const d = app.doc orelse return name;
        if (blockFile(d) != f) return name;
        const t = freeTile(d) orelse return name;
        try model_og.set(app, try model_og.innerFile(app, f, name), &.{"tile"}, try std.fmt.allocPrint(a, "[{d}, {d}]", .{ t[0], t[1] }));
    }
    @import("entry_rules.zig").sync(app);
    app.reloadLevel();
    return name;
}

/// Object `i` of the battle moved to tile `t` in the block: its inner block's `tile`, or
/// (a hero) its Place in `placement`; the line of the battle's code that placed it
/// (`actor::Place("<name>", …);` in its logic) taken out, so the data places it. One undo
/// step. error.Scripted: the code walks it in (fighter::Appear), the page cannot move it.
pub fn move(d: *Doc, f: usize, i: usize, t: [2]i32) !void {
    const app = d.app();
    const a = app.frame.allocator();
    const name = d.objects.items[i].name;
    const logic = codeLine(d, name);
    if (logic) |l| if (l.appear) return error.Scripted;
    app.store.group();
    defer app.store.endGroup("{s} → {d},{d}", .{ name, t[0], t[1] });
    const tile = try std.fmt.allocPrint(a, "[{d}, {d}]", .{ t[0], t[1] });
    if (innerBlock(app, a, f, name)) |of| {
        try model_og.set(app, of, &.{"tile"}, tile);
    } else try setPlace(app, a, f, name, tile);
    if (logic) |l| {
        const text = app.store.text(l.file);
        try app.store.replace(l.file, try std.mem.concat(app.gpa, u8, &.{ text[0..l.start], text[l.end..] }));
    }
}

/// `placement` with `name`'s Place at `tile` (a new Place when it has none).
fn setPlace(app: *App, a: Allocator, f: usize, name: []const u8, tile: []const u8) !void {
    var items: std.ArrayList(*const ir.Expr) = .empty;
    if (model.field(app, f, "placement").og_expr) |pl| if (pl.kind == .list) try items.appendSlice(a, pl.kind.list);
    const tv = try model_og.parseValue(a, tile);
    for (items.items) |*p| if (p.*.kind == .call) {
        const c = p.*.kind.call;
        const who = schema.recordField(c, "who") orelse continue;
        if (!std.ascii.eqlIgnoreCase(whoName(a, who), name)) continue;
        var named: std.ArrayList(ir.Named) = .empty;
        for (c.named) |n| if (!std.mem.eql(u8, n.name, "at") and !std.mem.eql(u8, n.name, "point")) try named.append(a, n);
        for (named.items) |*n| {
            if (std.mem.eql(u8, n.name, "tile")) {
                n.value = tv;
                break;
            }
        } else try named.append(a, .{ .name = "tile", .value = tv });
        const np = try a.create(ir.Expr);
        np.* = .{ .line = 0, .kind = .{ .call = .{ .id = 0, .text = c.text, .args = &.{}, .named = named.items } } };
        p.* = np;
        break;
    } else try items.append(a, try model_og.parseValue(a, try std.fmt.allocPrint(a, "Place(who = @\"{s}\", tile = {s})", .{ name, tile })));
    const l = try a.create(ir.Expr);
    l.* = .{ .line = 0, .kind = .{ .list = items.items } };
    try model_og.setExpr(app, f, "placement", l);
}

/// The line of the battle's logic placing `name` (`actor::Place("<name>", …);` or a walk-in
/// `fighter::Appear(…)`): its file and bytes (with its line end).
const Line = struct { file: usize, start: usize, end: usize, appear: bool };

fn codeLine(d: *const Doc, name: []const u8) ?Line {
    const app = d.app();
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "battles/{s}/logic.ogs", .{d.name}) catch return null;
    const f = app.store.file(store_mod.og_src, path) catch return null;
    const text = app.store.text(f);
    for ([_][]const u8{ "actor::Place(\"", "fighter::Appear(\"" }, [_]bool{ false, true }) |key, appear| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, key)) |k| : (at = k + 1) {
            const n = k + key.len;
            if (n + name.len >= text.len or !std.ascii.eqlIgnoreCase(text[n .. n + name.len], name) or text[n + name.len] != '"') continue;
            const start = if (std.mem.lastIndexOfScalar(u8, text[0..k], '\n')) |s| s + 1 else 0;
            const end = if (std.mem.indexOfScalarPos(u8, text, k, '\n')) |e| e + 1 else text.len;
            return .{ .file = f, .start = start, .end = end, .appear = appear };
        }
    }
    return null;
}
