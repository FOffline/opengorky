//! Giving items between heroes (0x42e3f0, 0x4b3630).

const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const item_mod = @import("item.zig");
const equipment = @import("equipment.zig");
const ammo = @import("ammo.zig");
const hooks = @import("../state.zig").hooks;
const Value = @import("../script.zig").value.Value;

/// Whether the carried `item` may be dropped on portrait `to` (0x42e3f0): not to self,
/// not to or from one NoHands (a native mark: Medusa; 0x42e485/0x42e495), in battle only
/// to a neighbour; OpenGorky: then the item's CanGive(from, to), asked as it is dropped.
/// Give mode never starts for her (0x4b23dc) and refuses her as recipient (0x450872).
/// shortcut: out of memory in CanGive reads as may (the callers are no error paths: the
/// viewer's drop); upgrade if it ever allocates more.
pub fn canGive(self: *World, item: *Object, from: *Object, to: *Object) bool {
    if (to == from or to.implementsC("NoHands") or from.implementsC("NoHands")) return false;
    if (self.battle) |*b| if (!b.adjacent(from, to)) return false;
    if (item.implementsC("CanGive")) {
        var args = [_]Value{ from.ref(), to.ref() };
        if (hooks.on(self, item, "Item.CanGive", &args) catch null) |v| return v.truth();
    }
    return true;
}

/// Give a single item: out of the giver's hand into the receiver's backpack; ammo
/// merges into the receiver's pack.
pub fn handOver(self: *World, from: *Object, to: *Object, item: *Object) void {
    if (item_mod.placeOf(item) == .hand) equipment.setHoldState(self, from, null);
    item_mod.setPlace(item, .backpack);
    fields.setOwner(item, to.name);
    item_mod.mergeAmmo(self, item);
}

/// Give `amount` units (0x4b3630): ammo moves between packs of the same kind (0x47d880 by
/// classic_id and owner); other items move `amount` equal items to the backpack. With no
/// receiving pack the exe does nothing (0x4b367e/0x4b3686) because every hero has all
/// packs; we create an empty one (`ammo.ammoPackOf`) instead of handing over the giver's pack.
pub fn transfer(self: *World, from: *Object, to: *Object, item: *Object, amount: i32) void {
    if (amount <= 0) return;
    if (item_mod.typeOf(item) == .ammo) {
        if (ammo.ammoPackOf(self, to, item)) |t| {
            const n = @min(amount, fields.counter(item));
            fields.setCounter(item, fields.counter(item) - n);
            fields.setCounter(t, fields.counter(t) + n);
        }
        if (fields.counter(item) < 1 and item_mod.placeOf(item) == .hand) {
            item_mod.setPlace(item, .backpack);
            equipment.setHoldState(self, from, null);
        }
        return;
    }
    // Not the exe (it takes the first found, 0x47d880, worn armour too): the backpack's
    // first, then what is held or worn.
    var left = amount;
    for ([_]bool{ false, true }) |worn| {
        var i: usize = 0;
        while (left > 0 and i < self.rt.objects.items.len) : (i += 1) {
            const o = self.rt.objects.items[i];
            if (!world.isItem(o)) continue;
            if (fields.classicId(o) != fields.classicId(item) or !fields.ownerIs(o, from.name) or o.getInt("place") <= 0) continue;
            if ((item_mod.placeOf(o) != .backpack) != worn) continue;
            if (item_mod.placeOf(o) == .hand) equipment.setHoldState(self, from, null);
            item_mod.setPlace(o, .backpack);
            fields.setOwner(o, to.name);
            left -= 1;
        }
    }
}
