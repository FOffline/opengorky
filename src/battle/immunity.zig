//! Monster resistances (table 0x6d2070, filled at 0x4c91c0; check 0x4caa80): by
//! fighter `classic_id`, immunity to codes 1–8 and armour class (code 9).
//! Codes: 1 fire, 2 electricity, 3 decoy (Dist), 4 energy, 5 cold,
//! 6 tranquilizer, 7 gas, 8 fuel, same as the hero armour `pr*` fields.
//! The table was extracted by emulating 0x4c91c0 (35 entries).

const std = @import("std");

const rules = @import("../rules.zig");
const entity = @import("../core.zig").entity;
const Entry = rules.Resist;

/// The built-in rows (rules resist.ss, src/rules/resist.zig); the saves keep discovered
/// bits in this order.
pub const table = rules.builtin.resist[0..rules.resist_count].*;

/// Resistance code (table 0x6d2070 flag; 9 is armour class, discovery bit only).
pub const Resist = enum(u4) {
    fire = 1,
    electricity = 2,
    /// Decoy (Dist).
    attract = 3,
    energy = 4,
    freeze = 5,
    tranq = 6,
    gas = 7,
    flammable = 8,
    /// Armour class (0x4caaf7): discovery bit only.
    armor = 9,

    pub fn index(r: Resist) usize {
        return @backingInt(r) - 1;
    }
};

/// Weapon damage kind, the .wpn `type` field (parsed at 0x491056…0x49120f).
/// Kinds without a resistance (bullets, blades, blast) hit everyone.
pub const DamageType = enum(i32) {
    fire = 1,
    freeze = 2,
    electricity = 3,
    gas = 5,
    bullet = 6,
    melee = 7,
    tranq = 9,
    energy = 11,
    attract = 12,
    explosion = 13,
    flammable = 14,
    _,

    pub fn from(t: i32) DamageType {
        return @fromBackingInt(@intCast(t));
    }
};

/// Hero armour `pr*` fields by code (item offsets +0x378…+0x394).
pub const pr_fields = [8][]const u8{ "resist_fire", "resist_electricity", "resist_decoy", "resist_energy", "resist_freeze", "resist_sleep", "resist_gas", "resist_flammable" };

/// Discovered resistances (the exe stores 2 in the same table, 0x4caa80): bit
/// `code` (1–9) per `table` entry, plus the entries of fighters outside it (`extra`:
/// generic fighters, OpenGorky class fields and rules rows; registered on battle
/// entry or first use). Entries are kept by classic_id and class (OpenGorky: two classes of
/// one classic_id have their own); discovery by classic_id (the first entry of it). One per game
/// (game.Game); `table` bits go into saves.
pub const Known = struct {
    table: [table.len]u16 = @splat(0),
    extra: [32]u16 = @splat(0),
    entries: [32]Entry = undefined,
    n: usize = 0,

    /// `who`'s entry: its classic_id and class (Classic: no class).
    fn extraIndex(self: *const Known, who: rules.Who) ?usize {
        for (self.entries[0..self.n], 0..) |e, i| if (e.fighter == who.id and std.ascii.eqlIgnoreCase(e.fighter_class, who.class)) return i;
        return null;
    }

    /// The first entry of the classic_id, whatever its class (discovery).
    fn idIndex(self: *const Known, name_id: i32) ?usize {
        for (self.entries[0..self.n], 0..) |e, i| if (e.fighter == name_id) return i;
        return null;
    }

    fn slot(self: *Known, who: rules.Who) ?*u16 {
        if (slotIndex(who)) |i| return &self.table[i];
        const name_id = who.id;
        if (self.idIndex(name_id) == null) if (entity.enemyOf(.{ .id = name_id, .class = who.class }).resist) |r| self.add(r.*);
        if (self.idIndex(name_id)) |i| return &self.extra[i];
        return null;
    }

    /// Mark a code discovered for `who`'s kind; true the first time (show the popup).
    pub fn discover(self: *Known, who: rules.Who, code: Resist) bool {
        const k = self.slot(kindOf(who)) orelse return false;
        const bit = @as(u16, 1) << @backingInt(code);
        if (k.* & bit != 0) return false;
        k.* |= bit;
        return true;
    }

    pub fn isKnown(self: *Known, who: rules.Who, code: Resist) bool {
        const k = self.slot(kindOf(who)) orelse return false;
        return k.* & (@as(u16, 1) << @backingInt(code)) != 0;
    }

    /// A registered entry first (in Classic only fighters outside the table have one),
    /// then the rules.
    fn find(self: *const Known, who: rules.Who) ?Entry {
        if (self.extraIndex(who)) |i| return self.entries[i];
        return if (entity.enemyOf(.{ .id = who.id, .class = who.class }).resist) |r| r.* else null;
    }

    /// A fighter's own entry: `resist` words separated by commas or spaces ("fire,
    /// gas"), `armor_class` 0 none, 1 light, 2 medium, 3 heavy; null keeps the rules'
    /// (none: nothing). Re-registering a classic_id and class replaces its entry. The exe table's
    /// ids only in an OpenGorky project (`og`: class fields override rules).
    pub fn register(self: *Known, who: rules.Who, resist: ?[]const u8, armor_class: ?i32, og: bool) void {
        if (!og and index(who.id) != null) return;
        // Its class's row (OpenGorky) or its classic_id's, kept by the classic_id and class.
        var e: Entry = if (entity.enemyOf(who).resist) |r| r.* else .{ .fighter = who.id };
        e.fighter = who.id;
        // Interned: the class name is the world's, the entry outlives it (out of memory: none).
        const names = @import("../script.zig").object;
        e.fighter_class = if (who.class.len == 0) "" else if (names.intern(who.class)) |id| names.nameOf(id) else |_| "";
        if (resist) |words| {
            e.resist = .{};
            var it = std.mem.tokenizeAny(u8, words, ", ;\t");
            while (it.next()) |w| if (codeOfWord(w)) |c| {
                e.resist.bits[c.index()] = 1;
            };
        }
        if (armor_class) |a| e.armor = -std.math.clamp(a, 0, 3);
        self.add(e);
    }

    fn add(self: *Known, e: Entry) void {
        if (self.extraIndex(.{ .id = e.fighter, .class = e.fighter_class })) |i| {
            self.entries[i] = e;
            return;
        }
        if (self.n == self.entries.len) return;
        self.entries[self.n] = e;
        self.n += 1;
    }

    /// A Resist row by this very fighter (OpenGorky: `fighter = "01pr_hornet02"`, the
    /// object's own name), over its classic_id's entry; discovery stays by classic_id.
    fn own(who: rules.Who) ?Entry {
        if (who.obj.len == 0) return null;
        const r = entity.enemyOf(who).resist orelse return null;
        return if (std.ascii.eqlIgnoreCase(r.fighter_class, who.obj)) r.* else null;
    }

    /// Monster `who` resists `code` (armour class `.armor` is not a resistance).
    pub fn immune(self: *const Known, who: rules.Who, code: Resist) bool {
        const e = own(who) orelse self.find(who) orelse return false;
        return code != .armor and e.resist.bits[code.index()] != 0;
    }

    /// Armour class by table: 0 light, 1 medium, 2 heavy (|value| − 1).
    pub fn armorClass(self: *const Known, who: rules.Who) ?i32 {
        const e = own(who) orelse self.find(who) orelse return null;
        if (e.armor == 0) return null;
        return @as(i32, @intCast(@abs(e.armor))) - 1;
    }
};

/// Popups on discovery: string.tab 801–808 and 571–573 (armour class).
pub const protection_text = [8][]const u8{ "Fire protection", "Electricity protection", "Attracting protection", "Energy protection", "Freezing protection", "Tranquilizing protection", "Poison protection", "Flammable protection" };
pub const armor_text = [3][]const u8{ "Light Armor", "Medium Armor", "Heavy Armor" };

/// Discovery is of a kind of fighter, not one object: `who` without its object.
fn kindOf(who: rules.Who) rules.Who {
    return .{ .id = who.id, .class = who.class };
}

/// `who`'s save slot: Classic's by classic_id in the built-in table's order; an OpenGorky
/// project's the place of the Resist row naming its kind (archetype or number: a project
/// has no classic_id), the converted rows kept in that order.
fn slotIndex(who: rules.Who) ?usize {
    if (!rules.og) return index(who.id);
    for (rules.active.resist, 0..) |r, i| {
        if (i >= table.len) break;
        if (rules.keyMatch(r, "fighter", who)) |_| return i;
    }
    // No Resist row of its kind: nothing to discover (the built-in table is Classic's).
    return null;
}

/// Save slot: the built-in table's order.
fn index(name_id: i32) ?usize {
    for (table, 0..) |e, i| if (e.fighter == name_id) return i;
    return null;
}

/// `resist` word → resistance code (1–8).
fn codeOfWord(word: []const u8) ?Resist {
    const i = rules.resistIndex(word) orelse return null;
    return @fromBackingInt(@as(u4, @intCast(i + 1)));
}

/// Resistance to the weapon damage kind (`type`, 0x491056…0x49120f).
pub fn damageCode(t: DamageType) ?Resist {
    return switch (t) {
        .fire => .fire,
        .electricity => .electricity,
        .attract => .attract,
        .energy => .energy,
        .freeze => .freeze,
        .tranq => .tranq,
        .gas => .gas,
        .flammable => .flammable,
        else => null,
    };
}

/// Resistance code for the weapon's state effect (0x4900f0): fire, cold, gas, fuel, sleep.
pub fn effectCode(kind: @import("rules.zig").Effect) ?Resist {
    return switch (kind) {
        .burn => .fire,
        .freeze => .freeze,
        .gas => .gas,
        .soak => .flammable,
        .sleep => .tranq,
        else => null,
    };
}

test "generic fighter resistances" {
    var k: Known = .{};
    k.register(.{ .id = 2001 }, "fire, gas", 2, false);
    try std.testing.expect(k.immune(.{ .id = 2001 }, .fire) and k.immune(.{ .id = 2001 }, .gas) and !k.immune(.{ .id = 2001 }, .freeze));
    try std.testing.expectEqual(@as(?i32, 1), k.armorClass(.{ .id = 2001 }));
    try std.testing.expect(k.discover(.{ .id = 2001 }, .fire) and !k.discover(.{ .id = 2001 }, .fire));
    k.register(.{ .id = 120 }, "", 0, false); // exe entries are not replaced in Classic
    try std.testing.expect(k.immune(.{ .id = 120 }, .fire));
    k.register(.{ .id = 120 }, "gas", null, true); // OpenGorky: class fields override
    try std.testing.expect(!k.immune(.{ .id = 120 }, .fire) and k.immune(.{ .id = 120 }, .gas));
    try std.testing.expectEqual(@as(?i32, 1), k.armorClass(.{ .id = 120 }));
    k = .{};
    try std.testing.expect(k.immune(.{ .id = 120 }, .fire));
}

test "OpenGorky: two classes of one classic_id keep their own Resist entries" {
    var k: Known = .{};
    k.register(.{ .id = 2001, .class = "ft_a" }, "fire", 1, true);
    k.register(.{ .id = 2001, .class = "ft_b" }, "gas", 3, true);
    try std.testing.expect(k.immune(.{ .id = 2001, .class = "ft_a" }, .fire) and !k.immune(.{ .id = 2001, .class = "ft_a" }, .gas));
    try std.testing.expect(k.immune(.{ .id = 2001, .class = "FT_B" }, .gas) and !k.immune(.{ .id = 2001, .class = "ft_b" }, .fire));
    try std.testing.expectEqual(@as(?i32, 0), k.armorClass(.{ .id = 2001, .class = "ft_a" }));
    try std.testing.expectEqual(@as(?i32, 2), k.armorClass(.{ .id = 2001, .class = "ft_b" }));
    // Discovery stays by classic_id.
    try std.testing.expect(k.discover(.{ .id = 2001 }, .fire) and k.isKnown(.{ .id = 2001 }, .fire));
}

test "invisible is immune to everything, incubus wears heavy armor" {
    const k: Known = .{};
    try std.testing.expect(k.immune(.{ .id = 120 }, .fire) and k.immune(.{ .id = 120 }, .flammable));
    try std.testing.expectEqual(@as(?i32, 2), k.armorClass(.{ .id = 138 }));
    try std.testing.expect(!k.immune(.{ .id = 100 }, .freeze));
}
