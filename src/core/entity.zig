//! Core entities: a hero, enemy, weapon or item as one record. The original scatters
//! each over its script (`.hro`, `ft_*.ss`/`.ftr`, `cw_*.s`/`.wpn`, `ci_*.s`/`.itm`: the
//! object's fields), string.tab (the name by classic_id) and the exe's tables (the rules
//! rows: built-ins = the exe, an OpenGorky project's files over them). The core instance
//! is the cache: composition (src/compose.zig) fills `texts` and the rules once at
//! startup, nothing here reads files. A record by identity (`heroOf(who)`…: classic_id and,
//! OpenGorky, class) is made from them and stored: every one composition lists (`fill`:
//! the game's classes and heroes, loaders/classic/entities.zig) up front, made again at once when
//! new rules or texts come (the editor's reload: `rules.version`, `useTexts`). By object (`hero(o)`…): the
//! stored record of the object's identity plus its fields, which are core state too — a
//! script changing classic_id or a field is seen at the next lookup, nothing goes stale.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rules = @import("../rules.zig");
const Who = rules.Who;
const Object = @import("../script.zig").object.Object;

/// The classic_id registry: the text of each classic_id (string.tab), as the composition layer
/// hands it over; empty: no names.
const Texts = struct {
    map: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    /// The edition's language number (0x45a1d0, string.tab line 950: 0 English, 5
    /// Russian): which lines of a dialog the edition cuts (formats/dialog.zig editionCut).
    language: u8 = 0,
    /// The examine texts: of items and weapons by classic_id (`items.inf`), of areas
    /// (`activeareas.inf`); composition's `loadExamine`, kept by `useTexts`.
    examine: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    areas: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,

    pub fn get(self: Texts, id: i32) ?[]const u8 {
        return self.map.get(id);
    }
};

/// The texts in force (process-wide; compose.setTexts through `useTexts`).
pub var texts: Texts = .{};

/// A font as the core needs it: each glyph's width (0: none), for line widths (0x47b5e0)
/// and subtitle pages; the pixels stay with whoever draws.
pub const Font = struct {
    widths: [256]u32 = @splat(0),

    /// Line width (0x47b5e0): sum of (width − 1) — the exe uses −1 letter spacing
    /// (0x47b4fb); characters without a glyph are skipped.
    pub fn measure(self: Font, text: []const u8) u32 {
        var w: u32 = 0;
        for (text) |ch| w += self.widths[ch] -| 1;
        return w;
    }

    /// Length of the first line of `text` no wider than `max_w`: breaks at the last
    /// space; a word wider than the line goes whole.
    pub fn lineCut(self: Font, text: []const u8, max_w: u32) usize {
        var cut = text.len;
        while (self.measure(text[0..cut]) > max_w) {
            cut = std.mem.lastIndexOfScalar(u8, text[0 .. cut - 1], ' ') orelse break;
        }
        return cut;
    }
};

/// The dialog font (`02_dialog` + the language's letters: subtitle pages); null: one
/// page per line (loaders.loadDialogFont).
pub var dialog_font: ?Font = null;

/// The interface fonts: `03_small` (hints, the panel, the inventory's boxes) and
/// `04_system` (labels, window names) with the language's letters (loaders.loadUiFonts).
pub var small_font: ?Font = null;
pub var system_font: ?Font = null;

/// `t` as the texts in force (the stored records' names change: dropped).
pub fn useTexts(t: Texts) void {
    texts = t;
    drop();
}

// ---------------------------------------------------------------- stored records

/// What a record is of.
/// `other`: a block with a number and no record (an actor's, an area's: its texts by it).
pub const Kind = enum { hero, enemy, weapon, item, other };

/// A record composition lists: its kind and identity.
pub const Listed = struct { kind: Kind, who: Who };

/// The arenas a reload let go of (`drop`, `fill`): what was made of them (a record's name,
/// a class) may still be on screen this frame — the editor reloads on an edit mid-frame and
/// Clay measures its texts at the frame's end — so they are freed by `release` (the
/// editor's, at a frame's start), else the oldest past `retired.len`.
var retired: [8]?std.heap.ArenaAllocator = @splat(null);
var retired_next: usize = 0;

fn retire(arena: *std.heap.ArenaAllocator) void {
    if (retired[retired_next]) |*old| old.deinit();
    retired[retired_next] = arena.*;
    retired_next = (retired_next + 1) % retired.len;
    arena.* = .init(std.heap.page_allocator);
}

/// Frees what reloads let go of (`retire`): call where nothing made of the old records is
/// in use any more (the editor: before a frame's layout).
pub fn release() void {
    for (&retired) |*r| if (r.*) |*x| {
        x.deinit();
        r.* = null;
    };
}

/// The records by identity, per kind; keys' classes are copies in `arena`.
/// shortcut: an identity composition didn't list (a level object whose own script sets
/// another classic_id, a class a script makes at run time) is stored at its first lookup;
/// its inputs are the core's own, loaded once, so the record is the same.
const Store = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    /// The listed identities (`fill`), their classes in `listed_arena`.
    listed: []const Listed = &.{},
    listed_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    heroes: std.HashMapUnmanaged(Who, Hero, WhoCtx, 80) = .empty,
    enemies: std.HashMapUnmanaged(Who, Enemy, WhoCtx, 80) = .empty,
    weapons: std.HashMapUnmanaged(Who, Weapon, WhoCtx, 80) = .empty,
    items: std.HashMapUnmanaged(Who, Item, WhoCtx, 80) = .empty,
    version: u32 = 0,
};
var store: Store = .{};

const WhoCtx = struct {
    pub fn hash(_: WhoCtx, w: Who) u64 {
        var h = std.hash.Wyhash.init(@as(u32, @bitCast(w.id)));
        for (w.class) |c| h.update(&.{std.ascii.toLower(c)});
        h.update("/");
        for (w.obj) |c| h.update(&.{std.ascii.toLower(c)});
        return h.final();
    }
    pub fn eql(_: WhoCtx, a: Who, b: Who) bool {
        return a.id == b.id and std.ascii.eqlIgnoreCase(a.class, b.class) and std.ascii.eqlIgnoreCase(a.obj, b.obj);
    }
};

/// The stored records dropped and every listed one made again.
fn drop() void {
    retire(&store.arena);
    store.heroes = .empty;
    store.enemies = .empty;
    store.weapons = .empty;
    store.items = .empty;
    store.version = rules.version;
    for (store.listed) |l| switch (l.kind) {
        .hero => _ = heroOf(l.who),
        .enemy => _ = enemyOf(l.who),
        .weapon => _ = weaponOf(l.who),
        .item => _ = itemOf(l.who),
        .other => {},
    };
}

/// `list` as the records up front (copied; replaces the last list), each made now.
pub fn fill(list: []const Listed) Allocator.Error!void {
    retire(&store.listed_arena);
    store.listed = &.{};
    party_order = &.{};
    const a = store.listed_arena.allocator();
    const own = try a.alloc(Listed, list.len);
    for (own, list) |*o, l| o.* = .{ .kind = l.kind, .who = .{ .id = l.who.id, .class = try a.dupe(u8, l.who.class) } };
    store.listed = own;
    drop();
}

/// An OpenGorky project's heroes in the party's order (the `game` block's `party_order`:
/// Classic's by classic_id, 20 Sullivan, 21 Ovitz…), their paths in `listed_arena`.
var party_order: []const []const u8 = &.{};

/// `party_order` made `paths` (copied).
pub fn setPartyOrder(paths: []const []const u8) Allocator.Error!void {
    const a = store.listed_arena.allocator();
    const own = try a.alloc([]const u8, paths.len);
    for (own, paths) |*o, p| o.* = try a.dupe(u8, p);
    party_order = own;
}

/// Where hero `w` stands in the party's order: its place in `party_order` (an OpenGorky
/// project's), else its classic_id (Classic's order); a hero not listed after the listed.
pub fn heroRank(w: Who) i64 {
    if (party_order.len == 0) return w.id;
    for (party_order, 0..) |p, i| if (std.ascii.eqlIgnoreCase(p, w.class)) return @intCast(i);
    return @as(i64, @intCast(party_order.len)) + w.id;
}

/// The classic_id listed for class `class` (an OpenGorky archetype's: its own or the one the
/// OG reader gave it); null: not listed.
pub fn idOf(class: []const u8) ?i32 {
    for (store.listed) |l| if (std.ascii.eqlIgnoreCase(l.who.class, class)) return l.who.id;
    return null;
}

/// The class listed with number `id` (an OpenGorky archetype's path); null: none.
pub fn classOf(id: i32) ?[]const u8 {
    for (store.listed) |l| if (l.who.id == id and l.who.class.len > 0) return l.who.class;
    return null;
}

/// A rules value naming an entity by classic_id `n`, or by archetype `class` when that is
/// set (an OpenGorky row's `strike = ~c"characters::medusa"`, codec `_class`): the number
/// (0: no such archetype).
pub fn refId(n: i32, class: []const u8) i32 {
    return if (class.len == 0) n else idOf(class) orelse 0;
}

/// The stored record of `w` in `field`, made by `make` the first time.
fn stored(comptime field: []const u8, w: Who, comptime make: anytype) @TypeOf(make(w)) {
    if (store.version != rules.version) drop();
    const map = &@field(store, field);
    if (map.get(w)) |r| return r;
    const r = make(w);
    const a = store.arena.allocator();
    // Out of memory: not stored, made again next time (the same record).
    const key: Who = .{ .id = w.id, .class = a.dupe(u8, w.class) catch return r, .obj = a.dupe(u8, w.obj) catch return r };
    map.put(a, key, r) catch {};
    return r;
}

const Hero = struct {
    who: Who,
    /// string.tab by classic_id ("" unknown; by object: else the object's name).
    name: []const u8,
    /// `icons\<portrait>.spr`: `spriteFile`, else the object's name (by object only).
    portrait: []const u8 = "",
    /// Strikes by its own MonsterAttack rows (Medusa), not the hero table (0x4896b0).
    own_attacks: bool,
    /// wdelay_* shifts its strikes (WdelayHero: McFadden, Hutchens).
    wdelay: bool,
    /// Heal bonus in percent of its medicine (HealBonus: McFadden 15); not 0: the stats
    /// window's "special skill: healing +<pct>%" line (exe: classic_id 24's, 0x52ac28).
    heal_pct: i32,
    /// Its other bonuses (HealBonus, OpenGorky; 0: the exe's): hit chance points,
    /// damage percent, walk range tiles.
    hit_bonus: i32,
    damage_bonus: i32,
    walk_bonus: i32,
    idle: ?*const rules.IdleChatter,
    /// Weapons it doesn't draw in hand (HiddenWeapons).
    hidden: ?*const rules.HiddenWeapons,
};

pub const Enemy = struct {
    who: Who,
    name: []const u8,
    /// Strikes by its MonsterAttack rows; without them by the hero table (0x4896b0).
    own_attacks: bool,
    resist: ?*const rules.Resist,
    /// The after-battle report's icon (KillIcon).
    kill_icon: ?[]const u8,
};

pub const Weapon = struct {
    who: Who,
    name: []const u8,
    /// Inventory icon (`spriteFile`) and held model (`meshFile`), by object only.
    icon: []const u8 = "",
    model: []const u8 = "",
    /// `classType` (by object only) and its own code in the battle (modules.Weapons).
    class: i32 = 0,
    kind: rules.rows.WeaponKind = .plain,
    /// The game weapon whose effects it uses (Classic's FxAs; its own classic_id without a row).
    fx_as: i32,
    /// The hit sound of a WeaponSound row by its class (OpenGorky).
    class_sound: ?[]const u8,
    skill_icon: ?[]const u8,
    /// WeaponFlags.
    no_counter: bool,
    shock: bool,
    sparks: bool,
    silent_frames: bool,
};

pub const Item = struct {
    who: Who,
    name: []const u8,
    icon: []const u8 = "",
    /// Its effect if it is medicine (Medicine; else a plain heal).
    medicine: rules.Medicine,
};

fn nameOf(w: Who) []const u8 {
    return texts.get(w.id) orelse "";
}

fn objectName(o: *Object) []const u8 {
    return texts.get(o.getInt("classic_id")) orelse o.name;
}

fn makeHero(w: Who) Hero {
    return .{
        .who = w,
        .name = nameOf(w),
        .own_attacks = rules.hasMonsterAttack(w),
        .wdelay = rules.wdelayHero(w),
        .heal_pct = rules.healBonusPct(w),
        .hit_bonus = rules.heroBonus(w).hit,
        .damage_bonus = rules.heroBonus(w).damage,
        .walk_bonus = rules.heroBonus(w).walk,
        .idle = rules.idleChatter(w),
        .hidden = rules.hiddenWeapons(w),
    };
}

pub fn heroOf(w: Who) Hero {
    return stored("heroes", w, makeHero);
}

pub fn hero(o: *Object) Hero {
    var h = heroOf(rules.who(o));
    h.name = objectName(o);
    const sf = o.getString("portrait");
    h.portrait = if (sf.len > 0) sf else o.name;
    return h;
}

fn makeEnemy(w: Who) Enemy {
    return .{ .who = w, .name = nameOf(w), .own_attacks = rules.hasMonsterAttack(w), .resist = rules.resist(w), .kill_icon = rules.killIcon(w) };
}

pub fn enemyOf(w: Who) Enemy {
    return stored("enemies", w, makeEnemy);
}

fn makeWeapon(w: Who) Weapon {
    return .{
        .who = w,
        .name = nameOf(w),
        .fx_as = rules.fxAs(w),
        .class_sound = rules.classWeaponSound(w),
        .skill_icon = rules.skillIcon(w),
        .no_counter = rules.weaponFlag(w, .no_counter),
        .shock = rules.weaponFlag(w, .shock),
        .sparks = rules.weaponFlag(w, .sparks),
        .silent_frames = rules.weaponFlag(w, .silent_frames),
    };
}

pub fn weaponOf(w: Who) Weapon {
    return stored("weapons", w, makeWeapon);
}

fn makeItem(w: Who) Item {
    return .{ .who = w, .name = nameOf(w), .medicine = rules.medicineOf(w) };
}

pub fn itemOf(w: Who) Item {
    return stored("items", w, makeItem);
}

pub fn item(o: *Object) Item {
    var r = itemOf(rules.who(o));
    r.name = objectName(o);
    r.icon = o.getString("icon");
    return r;
}

test "entity: records are the rules rows and the names in force" {
    defer useTexts(.{});
    var m: std.AutoHashMapUnmanaged(i32, []const u8) = .empty;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", heroOf(.{ .id = 24 }).name);
    try m.put(std.testing.allocator, 24, "Joan McFadden");
    // New texts drop the stored records.
    useTexts(.{ .map = m });
    const mf = heroOf(.{ .id = 24 });
    try std.testing.expectEqualStrings("Joan McFadden", mf.name);
    try std.testing.expect(mf.wdelay and mf.heal_pct == 15 and heroOf(.{ .id = 29 }).heal_pct == 0);
    try std.testing.expectEqualStrings("", heroOf(.{ .id = 20 }).name);
    // Medusa strikes by her own branch; the Guard by its rows; 103 by the hero table.
    try std.testing.expect(heroOf(.{ .id = 119 }).own_attacks and enemyOf(.{ .id = 131 }).own_attacks and !enemyOf(.{ .id = 103 }).own_attacks);
    try std.testing.expectEqual(rules.resist(.{ .id = 128 }), enemyOf(.{ .id = 128 }).resist);
    const w = weaponOf(.{ .id = 45 });
    try std.testing.expect(w.no_counter and w.silent_frames and !w.shock and w.fx_as == 45);
    try std.testing.expect(weaponOf(.{ .id = 52 }).shock);
}

test "entity: listed records are made up front and again after new rules" {
    defer rules.reset();
    defer fill(&.{}) catch {};
    rules.reset();
    try fill(&.{ .{ .kind = .weapon, .who = .{ .id = 45 } }, .{ .kind = .enemy, .who = .{ .id = 128, .class = "ft_hornet" } } });
    try std.testing.expectEqual(1, store.weapons.count());
    try std.testing.expectEqual(1, store.enemies.count());
    rules.reset();
    _ = itemOf(.{ .id = 1 });
    try std.testing.expect(store.weapons.count() == 1 and store.enemies.count() == 1 and store.items.count() == 1);
    try std.testing.expectEqual(2, store.listed.len);
}

test "entity: a record is stored once; new rules in force drop the stored ones" {
    defer rules.reset();
    rules.reset();
    _ = weaponOf(.{ .id = 45 });
    _ = weaponOf(.{ .id = 45, .class = "CW_X" });
    _ = weaponOf(.{ .id = 45, .class = "cw_x" });
    try std.testing.expectEqual(2, store.weapons.count());
    rules.reset();
    try std.testing.expect(weaponOf(.{ .id = 52 }).shock);
    try std.testing.expectEqual(1, store.weapons.count());
}

test "entity: a reload keeps the old records' memory until release (shown mid-frame)" {
    defer release();
    try fill(&.{.{ .kind = .other, .who = .{ .id = 7, .class = "characters::old_one" } }});
    const old = store.listed[0].who.class;
    try fill(&.{.{ .kind = .other, .who = .{ .id = 8, .class = "characters::new_one" } }});
    try std.testing.expectEqualStrings("characters::old_one", old);
    try std.testing.expectEqualStrings("characters::new_one", store.listed[0].who.class);
    try fill(&.{});
}
