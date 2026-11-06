//! A weapon class's damage zone on the entry pages: the exe's reach pattern
//! (rules `Pattern` rows, src/rules/patterns.zig) as tiles around the shooter, as battle/grid.zig targets()
//! reads it on an open field.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rules = @import("opengorky").rules;

pub const Cell = struct {
    /// Best damage percent of the ray entries reaching the tile.
    pct: u8 = 0,
    /// Hit tile set (Weapon.effects index) of the first entry reaching it.
    effect: u8 = 0,
    /// Reached only along a ray: an obstacle on a tile before it cuts it.
    chain: bool = false,
    /// Only the second tile of a wide ray (2×2 fighters): struck, not aimed at.
    side: bool = false,
};

const Zone = struct {
    cells: std.AutoArrayHashMapUnmanaged([2]i32, Cell) = .empty,
    /// Bounds of the cells and the shooter.
    lo: [2]i32 = .{ 0, 0 },
    hi: [2]i32 = .{ 0, 0 },
    /// The shooter's side in tiles from (0, 0).
    size: i32 = 1,
    /// Hit tile sets the rays use.
    used: [4]bool = @splat(false),
};

pub fn build(a: Allocator, w: *const rules.Pattern) !Zone {
    var z: Zone = .{};
    var side: [2]i32 = .{ 0, 0 };
    for (w.rays.items) |r| {
        switch (r.kind) {
            .side_x => side = .{ 1, 0 },
            .side_y => side = .{ 0, 1 },
            .start, .chain => {
                const t: [2]i32 = .{ r.dx, r.dy };
                try put(a, &z, t, .{ .pct = r.pct, .effect = r.effect, .chain = r.kind == .chain });
                if (w.wide and (side[0] != 0 or side[1] != 0)) try put(a, &z, .{ t[0] + side[0], t[1] + side[1] }, .{ .pct = r.pct, .effect = r.effect, .chain = r.kind == .chain, .side = true });
                if (r.effect < z.used.len) z.used[r.effect] = true;
            },
        }
    }
    // shortcut: the pattern does not name the shooter's size; a wide ray's, or rays
    // starting a tile off (wp_incubus' 1008), are a 2×2 fighter's. Upgrade if a
    // pattern of a 1×1 fighter ever skips its neighbours.
    const near = [_][2]i32{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    var touches = false;
    for (near) |t| touches = touches or z.cells.contains(t);
    if (w.wide or (z.cells.count() > 0 and !touches and (z.cells.contains(.{ 2, 0 }) or z.cells.contains(.{ 0, 2 })))) z.size = 2;
    z.hi = .{ @max(z.hi[0], z.size - 1), @max(z.hi[1], z.size - 1) };
    return z;
}

/// Tile `t` reached by entry `c`: a start beats a chain and an aim a side tile there;
/// the first entry's hit set stays.
fn put(a: Allocator, z: *Zone, t: [2]i32, c: Cell) !void {
    const g = try z.cells.getOrPut(a, t);
    if (!g.found_existing) {
        g.value_ptr.* = c;
        z.lo = .{ @min(z.lo[0], t[0]), @min(z.lo[1], t[1]) };
        z.hi = .{ @max(z.hi[0], t[0]), @max(z.hi[1], t[1]) };
        return;
    }
    const v = g.value_ptr;
    v.pct = @max(v.pct, c.pct);
    v.chain = v.chain and c.chain;
    v.side = v.side and c.side;
}

/// Bounds of hit set `set` around the target (0, 0).
pub fn setBounds(set: []const [2]i8) [2][2]i32 {
    var b: [2][2]i32 = .{ .{ 0, 0 }, .{ 0, 0 } };
    for (set) |d| for (0..2) |k| {
        b[0][k] = @min(b[0][k], d[k]);
        b[1][k] = @max(b[1][k], d[k]);
    };
    return b;
}

// ---- Editing (OpenGorky projects: zone_edit.zig writes the row)

/// Ray entries the battle aims with: its target list (battle.zig `max_targets`; a wide
/// ray's two tiles take two) — the exe has room for 1000 entries (+0x3a8…+0x1730).
pub const max_targets = 512;
pub const max_entries = 1000;
/// Tiles of a hit set: the exe's four sets of 100 (+0x1734, 0xc8 bytes each).
pub const max_hits = 100;
/// Damage percent of a ray tile (the exe's is a byte; past 100 a tile would hit harder
/// than the weapon).
pub const max_pct = 100;

const Limit = error{ TooManyRays, TooManyHits, TooHighPct };

/// `p` within what the battle and the exe hold (`pct` and the offsets are bytes).
pub fn check(p: rules.Pattern) Limit!void {
    var aims: usize = 0;
    for (p.rays.items) |r| {
        aims += if (!aim(r)) 0 else if (p.wide) 2 else 1;
        if (r.pct > max_pct) return error.TooHighPct;
    }
    if (aims > max_targets or p.rays.items.len > max_entries) return error.TooManyRays;
    for (p.effects.sets) |s| if (s.len > max_hits) return error.TooManyHits;
}

fn aim(r: rules.rows.Ray) bool {
    return r.kind == .start or r.kind == .chain;
}

/// The first aim entry at tile `t`.
pub fn find(rays: []const rules.rows.Ray, t: [2]i8) ?usize {
    for (rays, 0..) |r, i| if (aim(r) and r.dx == t[0] and r.dy == t[1]) return i;
    return null;
}

/// The side marker in force at entry `i` (0, 0: none).
pub fn sideAt(rays: []const rules.rows.Ray, i: usize) [2]i8 {
    var k = i;
    while (k > 0) {
        k -= 1;
        switch (rays[k].kind) {
            .side_x => return .{ 1, 0 },
            .side_y => return .{ 0, 1 },
            else => {},
        }
    }
    return .{ 0, 0 };
}

fn withRays(p: rules.Pattern, l: []const rules.rows.Ray) rules.Pattern {
    var out = p;
    out.rays = .{ .items = l };
    return out;
}

/// Tile `t` added or, when there, removed: a tile next to a ray's (away from the shooter)
/// continues that ray, at its end (the tiles before keep their cuts); else it starts a
/// new one at the list's end. A removed ray start hands it to its next tile.
pub fn toggleTile(a: Allocator, p: rules.Pattern, t: [2]i8) !rules.Pattern {
    var l: std.ArrayList(rules.rows.Ray) = .empty;
    try l.appendSlice(a, p.rays.items);
    if (find(l.items, t)) |i| {
        const r = l.orderedRemove(i);
        if (r.kind == .start and i < l.items.len and l.items[i].kind == .chain) l.items[i].kind = .start;
        return withRays(p, l.items);
    }
    const back: [2]i8 = .{ t[0] - std.math.sign(t[0]), t[1] - std.math.sign(t[1]) };
    if (find(l.items, back)) |i| {
        var j = i + 1;
        while (j < l.items.len and l.items[j].kind == .chain) j += 1;
        try l.insert(a, j, .{ .dx = t[0], .dy = t[1], .kind = .chain, .effect = l.items[i].effect, .pct = l.items[i].pct });
    } else try l.append(a, .{ .dx = t[0], .dy = t[1], .kind = .start, .effect = 0, .pct = 100 });
    return withRays(p, l.items);
}

/// Entry at tile `t` as `r` gives (its kind start or chain, its hit set, its percent).
pub fn setRay(a: Allocator, p: rules.Pattern, t: [2]i8, r: rules.rows.Ray) !rules.Pattern {
    const i = find(p.rays.items, t) orelse return p;
    const l = try a.dupe(rules.rows.Ray, p.rays.items);
    l[i] = r;
    return withRays(p, l);
}

/// A wide ray's second tile `side` (x: to the right, y: below) from the ray of tile `t`
/// on, as the exe reads its markers: until the next marker.
pub fn setSide(a: Allocator, p: rules.Pattern, t: [2]i8, side: enum { x, y }) !rules.Pattern {
    var s = find(p.rays.items, t) orelse return p;
    while (s > 0 and p.rays.items[s].kind == .chain and aim(p.rays.items[s - 1])) s -= 1;
    var l: std.ArrayList(rules.rows.Ray) = .empty;
    try l.appendSlice(a, p.rays.items);
    const m: rules.rows.Ray = .{ .dx = 0, .dy = 0, .kind = if (side == .x) .side_x else .side_y, .effect = 0, .pct = 0 };
    if (s > 0 and !aim(l.items[s - 1])) l.items[s - 1] = m else try l.insert(a, s, m);
    return withRays(p, l.items);
}

/// Hit set `k`'s tile `d` (from the target) added or, when there, removed.
pub fn toggleHit(a: Allocator, p: rules.Pattern, k: usize, d: [2]i8) !rules.Pattern {
    var l: std.ArrayList([2]i8) = .empty;
    try l.appendSlice(a, p.effects.sets[k]);
    const at = for (l.items, 0..) |x, i| {
        if (x[0] == d[0] and x[1] == d[1]) break i;
    } else null;
    if (at) |i| _ = l.orderedRemove(i) else try l.append(a, d);
    var out = p;
    out.effects.sets[k] = l.items;
    return out;
}

test build {
    const a = std.testing.allocator;
    // Pistol (1): four rays, 100 % near, 25 % at 6 tiles; past the first tile chained.
    var p = try build(a, rules.pattern(1).?);
    defer p.cells.deinit(a);
    try std.testing.expectEqual(1, p.size);
    try std.testing.expectEqual(Cell{ .pct = 100 }, p.cells.get(.{ 1, 0 }).?);
    try std.testing.expectEqual(Cell{ .pct = 25, .chain = true }, p.cells.get(.{ 0, -6 }).?);
    try std.testing.expect(p.cells.get(.{ 1, 1 }) == null);
    try std.testing.expectEqual([2]i32{ -6, -6 }, p.lo);
    // Flamethrower (4): a hit set per side.
    var f = try build(a, rules.pattern(4).?);
    defer f.cells.deinit(a);
    try std.testing.expectEqual(3, f.cells.get(.{ 0, -1 }).?.effect);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, f.used);
    // A 2×2 fighter's wide rays (102): the side tile after a marker, the shooter 2×2.
    var w = try build(a, rules.pattern(102).?);
    defer w.cells.deinit(a);
    try std.testing.expectEqual(2, w.size);
    try std.testing.expect(!w.cells.get(.{ 0, -1 }).?.side);
    try std.testing.expect(w.cells.get(.{ 1, -1 }).?.side);
    try std.testing.expectEqual(1, w.cells.get(.{ 2, 0 }).?.effect);
    // wp_incubus (1008): not wide, but its rays start past a 2×2 body.
    var inc = try build(a, rules.pattern(1008).?);
    defer inc.cells.deinit(a);
    try std.testing.expectEqual(2, inc.size);
    try std.testing.expectEqual([2][2]i32{ .{ -1, -1 }, .{ 1, 1 } }, setBounds(rules.pattern(17).?.effects.sets[0]));
}

/// `p` as the rules files write it, read back over its built-in row (as rules_text applies it).
fn roundTrip(a: Allocator, p: rules.Pattern) !rules.Pattern {
    const og = @import("opengorky");
    var aw: std.Io.Writer.Allocating = .init(a);
    try og.loaders.codec.write(rules.Pattern, &aw.writer, p);
    return og.loaders.codec.read(rules.Pattern, a, og.loaders.codec.oneRow(a, aw.written()).?, if (rules.pattern(p.classic_id)) |b| b.* else null);
}

test toggleTile {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    // Pistol (1) parsed: its right ray grows at its end (25 % as there), a tile off the
    // rays starts one at the list's end.
    var p = try toggleTile(a, try roundTrip(a, rules.pattern(1).?.*), .{ 7, 0 });
    const i = find(p.rays.items, .{ 7, 0 }).?;
    try t.expectEqual(find(p.rays.items, .{ 6, 0 }).? + 1, i);
    try t.expectEqual(rules.rows.Ray{ .dx = 7, .dy = 0, .kind = .chain, .effect = 0, .pct = 25 }, p.rays.items[i]);
    p = try toggleTile(a, p, .{ 5, 5 });
    try t.expectEqual(.start, p.rays.items[p.rays.items.len - 1].kind);
    // The ray's start removed: its next tile starts it; again: the tile back.
    p = try toggleTile(a, p, .{ 1, 0 });
    try t.expect(find(p.rays.items, .{ 1, 0 }) == null);
    try t.expectEqual(.start, p.rays.items[find(p.rays.items, .{ 2, 0 }).?].kind);
    // A side from the down ray on: a marker before its start, replaced the second time.
    p.wide = true;
    p = try setSide(a, p, .{ 0, 3 }, .y);
    const n = p.rays.items.len;
    p = try setSide(a, p, .{ 0, 1 }, .x);
    try t.expectEqual(n, p.rays.items.len);
    try t.expectEqual(.side_x, p.rays.items[find(p.rays.items, .{ 0, 1 }).? - 1].kind);
    try t.expectEqual([2]i8{ 1, 0 }, sideAt(p.rays.items, find(p.rays.items, .{ 0, 6 }).?));
    p = try setRay(a, p, .{ 0, 2 }, .{ .dx = 0, .dy = 2, .kind = .start, .effect = 3, .pct = 40 });
    p = try toggleHit(a, p, 3, .{ 1, 0 });
    try t.expectEqual(1, p.effects.sets[3].len);
    // Written and parsed back: the same row.
    try t.expectEqualDeep(p, try roundTrip(a, p));
    try t.expectEqual(0, (try toggleHit(a, p, 3, .{ 1, 0 })).effects.sets[3].len);
    // Emptied and narrowed over the built-in wide row: stays so.
    try t.expectEqualDeep(rules.Pattern{ .name = "garcia_long", .classic_id = 102 }, try roundTrip(a, .{ .name = "garcia_long", .classic_id = 102 }));
    // Limits: 512 targets (a wide ray's tiles two each), 100 tiles a hit set.
    try check(p);
    const many = try a.alloc(rules.rows.Ray, 257);
    @memset(many, .{ .dx = 1, .dy = 0, .kind = .start, .effect = 0, .pct = 100 });
    try t.expectError(error.TooManyRays, check(.{ .name = "pistol", .classic_id = 1, .wide = true, .rays = .{ .items = many } }));
    try check(.{ .name = "pistol", .classic_id = 1, .rays = .{ .items = many } });
    var sets: rules.rows.Effects = .{};
    sets.sets[2] = try a.alloc([2]i8, max_hits + 1);
    try t.expectError(error.TooManyHits, check(.{ .name = "pistol", .classic_id = 1, .effects = sets }));
    many[0].pct = max_pct + 1;
    try t.expectError(error.TooHighPct, check(.{ .name = "pistol", .classic_id = 1, .rays = .{ .items = many } }));
}
