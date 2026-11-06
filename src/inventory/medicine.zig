//! Medicine (0x48ff50): effects by classic_id, MacFadden's bonus, out-of-battle heal.

const std = @import("std");
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const Rand = @import("../crt_rand.zig").Rand;
const popup_mod = @import("../popup.zig");
const item_mod = @import("item.zig");
const rules = @import("../rules.zig");
const entity = @import("../core.zig").entity;
const hooks = @import("../state.zig").hooks;

/// Medicine effect (0x48ff50) by classic_id (rules items.ss).
const Medicine = rules.MedicineKind;

/// A `random` row picks with rand.below(len) (the exe: rand & 3 of 4); its pick's own
/// kind, one level only.
fn medicineKind(item: rules.Who, rand: *Rand) Medicine {
    const m = entity.itemOf(item).medicine;
    if (m.random.len == 0) return m.kind;
    const k = rand.below(@intCast(m.random.len));
    // An item archetype in that place (an OpenGorky project's): the core's number of it.
    const id = if (k < m.random_class.len and m.random_class[k].len > 0) entity.idOf(m.random_class[k]) orelse 0 else m.random[k];
    return entity.itemOf(.{ .id = id }).medicine.kind;
}

/// Heal bonus (0x48ffee): ⌊hp × pct / 100⌋ (hp > 0 here).
fn healBonus(healer: rules.Who, hp: i32) i32 {
    return @divFloor(hp * entity.heroOf(healer).heal_pct, 100);
}

/// Plain heal: item `hp`, capped at `max_hp`; consumes the item. False if not medicine.
/// No special effects — for gorky-tool `heal`; the game uses `medicine`.
pub fn use(hero: *Object, item: *Object) bool {
    if (item_mod.typeOf(item) != .medicine) return false;
    const hp = @min(fields.maxHp(hero), fields.hp(hero) + fields.hp(item));
    fields.setHp(hero, hp);
    item_mod.consume(item);
    return true;
}

/// Medicine `item` used by `healer` on `target` (0x48ff50). Item `hp` 0 only plays the
/// sound (gas antidote, 0x48ff66); otherwise the effect by classic_id (`medicineKind`)
/// and, for rage, Painkiller and plain heals, hp + MacFadden's bonus (0x48ffee) capped at
/// max_hp (0x4900b5). health2 plays only for males (`sex` 0, +0x24580; 0x4900cb). Battle
/// states (rage, gas, sleep) are handled by combat. The item is not consumed.
pub fn medicine(self: *World, healer: ?*Object, target: *Object, item: *Object) !?Healed {
    defer if (target.getInt("gender") == 0)
        self.out.sound(self.gpa, @import("../core.zig").modules.ui().sounds.heal, self.screenPos(target));
    const hp = fields.hp(item);
    if (hp == 0) return null;
    var h: Healed = .{ .kind = medicineKind(rules.who(item), self.crt()) };
    if (h.kind == .ungas or h.kind == .wake or hp < 0) return h;
    h.hp = hp;
    h.bonus = healBonus(if (healer) |o| rules.who(o) else .{ .id = -1 }, hp);
    fields.setHp(target, @min(fields.maxHp(target), fields.hp(target) + hp + h.bonus));
    return h;
}

/// Heal popup (0x492170): "hp" or "hp+bonus" ("%d+%d"), colour cfcHpGain.
pub fn healText(buf: []u8, h: Healed) []const u8 {
    return (if (h.bonus > 0) std.fmt.bufPrint(buf, "{d}+{d}", .{ h.hp, h.bonus }) else std.fmt.bufPrint(buf, "{d}", .{h.hp})) catch "";
}

/// Out-of-battle heal (0x450c6c → 0x47b900): `hero` uses medicine `item` (type 20) on
/// `target` by clicking the hero or his portrait. Runs 0x48ff50 (`medicine`) with a popup
/// if it healed; then the item leaves the hand (0x42b2d0) and is destroyed (+0x60) even
/// without effect, and the mode closes (0x450cc4 → 0x450e80). No animation. Rage, sleep
/// and gas need a battle fighter (recreated per battle, 0x48e0a0). True: used (the
/// "Use … on …" mode closes).
pub fn healWith(self: *World, hero: *Object, target: *Object, item: *Object) !bool {
    if (item_mod.typeOf(item) != .medicine) return false;
    if (try hooks.itemUse(self, hero, item, target)) return true;
    if (try medicine(self, hero, target, item)) |h| if (h.hp > 0) {
        var buf: [24]u8 = undefined;
        try self.popups.append(self.gpa, popup_mod.Popup.make(fields.pos(target), healText(&buf, h), .heal));
    };
    item_mod.consume(item);
    return true;
}

/// Medicine result (0x48ff50): effect, item `hp` and MacFadden's bonus (0 = no heal).
const Healed = struct { kind: Medicine, hp: i32 = 0, bonus: i32 = 0 };

test "medicine kinds and MacFadden's bonus follow 0x48ff50" {
    var rr: Rand = .{};
    const r = &rr;
    try std.testing.expectEqual(Medicine.rage, medicineKind(.{ .id = 1043 }, r));
    try std.testing.expectEqual(Medicine.calm, medicineKind(.{ .id = 83 }, r));
    try std.testing.expectEqual(Medicine.ungas, medicineKind(.{ .id = 1044 }, r));
    try std.testing.expectEqual(Medicine.wake, medicineKind(.{ .id = 1047 }, r));
    try std.testing.expectEqual(Medicine.heal, medicineKind(.{ .id = 1045 }, r));
    try std.testing.expectEqual(Medicine.heal, medicineKind(.{ .id = 71 }, r));
    // Unknown drugs: exactly four outcomes, all seen.
    var seen: [5]bool = @splat(false);
    for (0..64) |_| seen[@backingInt(medicineKind(.{ .id = 1049 }, r))] = true;
    try std.testing.expect(seen[@backingInt(Medicine.heal)] and seen[@backingInt(Medicine.rage)] and
        seen[@backingInt(Medicine.ungas)] and seen[@backingInt(Medicine.wake)] and !seen[@backingInt(Medicine.calm)]);
    try std.testing.expectEqual(@as(i32, 6), healBonus(.{ .id = 24 }, 40));
    try std.testing.expectEqual(@as(i32, 15), healBonus(.{ .id = 24 }, 100));
    // The integer form is the exe's ⌊hp × 0.15⌋ (a double) for every hp.
    for (1..200_000) |hp| try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(hp)) * 0.15))), healBonus(.{ .id = 24 }, @intCast(hp)));
    try std.testing.expectEqual(@as(i32, 0), healBonus(.{ .id = 1 }, 100));
}
