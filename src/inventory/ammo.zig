//! Ammo packs and counts (0x47d880, 0x4ce250).

const std = @import("std");
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const item_mod = @import("item.zig");
const create = @import("create.zig");

/// `hero`'s ammo pack of kind `like` (classic_id) (0x47d880: first by classic_id and owner). If
/// missing, an empty one of class `like` named `<hero>_am_<classic_id>` is created (deviation:
/// in the exe every hero starts with packs of all kinds from his .hro).
pub fn ammoPackOf(self: *World, hero: *Object, like: *Object) ?*Object {
    const id = fields.classicId(like);
    for (self.rt.objects.items) |o| {
        if (world.isItem(o) and item_mod.typeOf(o) == .ammo and fields.classicId(o) == id and fields.ownerIs(o, hero.name)) return o;
    }
    var nb: [96]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "{s}_am_{d}", .{ hero.name, id }) catch return null;
    // An OpenGorky pack's class is its archetype (`items::riffleammo`).
    const class = if (self.block_item != null) like.class.ident orelse like.class.name else like.class.name;
    return create.newItem(self, name, class, hero.name, 0, .item) catch null;
}

/// `owner`'s first item with this `classic_id` other than `skip` (0x47d880: object order,
/// owner case-insensitive).
pub fn heroAmmo(self: *World, owner: []const u8, name_id: i32, skip: *Object) ?*Object {
    for (self.rt.objects.items) |o| {
        if (o == skip) continue;
        if (!world.isItem(o)) continue;
        if (fields.classicId(o) != name_id) continue;
        if (fields.ownerIs(o, owner)) return o;
    }
    return null;
}

/// Ammo of kind `id` (pack classic_id) held by `owner`: sum of `counter` (0x4ce250, panel
/// 0x4b21e8).
pub fn ammoCount(self: *World, owner: []const u8, id: i32) i32 {
    var sum: i32 = 0;
    for (self.rt.objects.items) |o| {
        if (world.isItem(o) and fields.classicId(o) == id and fields.ownerIs(o, owner)) sum += fields.counter(o);
    }
    return sum;
}

/// Units available to give: ammo `counter`, otherwise the number of items with the same
/// classic_id and owner.
pub fn unitsOf(self: *World, hero: *Object, item: *Object) i32 {
    if (item_mod.typeOf(item) == .ammo) return fields.counter(item);
    var n: i32 = 0;
    for (self.rt.objects.items) |o| {
        if (!world.isItem(o)) continue;
        if (fields.classicId(o) == fields.classicId(item) and fields.ownerIs(o, hero.name) and o.getInt("place") > 0) n += 1;
    }
    return n;
}
