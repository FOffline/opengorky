//! Item actions on the field and boxes (action, 0x4564b0).

const std = @import("std");
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const hooks = @import("../state.zig").hooks;
const Object = @import("../script.zig").object.Object;
const Value = @import("../script.zig").value.Value;
const item_mod = @import("item.zig");
const rules = @import("../rules.zig");

/// Item action by `action` (rules actions.ss; string.tab names: 1 Open, 2 Close, 3
/// Take, 4 Use, 7 Explore). Take without its own function uses UniversalTake; Explore
/// opens the box window (`exploring`).
pub fn itemOperation(self: *World, item: *Object, hero: *Object) !void {
    const arg = [_]Value{.{ .string = hero.name }};
    const a = rules.action(item.getInt("action")) orelse return;
    var on_action = [_]Value{ .{ .string = a.name }, hero.ref() };
    if (try hooks.on(self, item, "Item.OnAction", &on_action)) |v| if (v.truth()) return;
    switch (a.kind) {
        .take => {
            // OpenGorky: the hero's CanCarry(item), then the item's CanTake(hero): a no
            // leaves it there.
            var by = [_]Value{hero.ref()};
            var what = [_]Value{item.ref()};
            if (hero.implementsC("CanCarry")) if (try hooks.on(self, hero, "Hero.CanCarry", &what)) |v| if (!v.truth()) return;
            if (item.implementsC("CanTake")) if (try hooks.on(self, item, "Item.CanTake", &by)) |v| if (!v.truth()) return;
            if (try self.rt.callIfExists(item, a.name, &arg) == null) {
                _ = try self.rt.callIfExists(item, "UniversalTake", &arg);
            }
            item_mod.mergeAmmo(self, item);
            // OpenGorky: its OnTaken(hero), then the hero's OnPickUp(item).
            if (item.implementsC("OnTaken")) _ = try hooks.on(self, item, "Item.OnTaken", &by);
            if (hero.implementsC("OnPickUp")) _ = try hooks.on(self, hero, "Hero.OnPickUp", &what);
        },
        .explore => try exploreBox(self, item, hero),
        .call => _ = try self.rt.callIfExists(item, a.name, &arg),
    }
}

/// With items, its action opens the box window by itself (rules Action `auto_open`: 7
/// Explore; 0x457340, 0x45b04f).
pub fn opensItself(o: *Object) bool {
    return o.getInt("cnt_itm") > 0 and rules.actionFlag(o.getInt("action"), .auto_open);
}

/// Box exploration (action 7): post_init_box() creates the contents on first look; the
/// host shows the list (`exploring`).
pub fn exploreBox(self: *World, box: *Object, hero: *Object) !void {
    var first = std.mem.splitScalar(u8, box.getString("itm_1"), ',');
    const first_name = std.mem.trim(u8, first.next() orelse "", " ");
    if (first_name.len > 0 and self.rt.findObject(first_name) == null) {
        _ = try self.rt.callIfExists(box, "post_init_box", &.{});
        var args = [_]Value{hero.ref()};
        _ = try hooks.on(self, box, "Item.OnFirstOpen", &args);
    }
    self.act.exploring = .{ .box = box, .hero = hero };
}

pub fn closeBox(self: *World) void {
    self.act.exploring = null;
}

/// Untaken box items over slots `itm_1..itm_13` (0x4564b0).
fn boxContents(self: *World, box: *Object, out: []*Object) []*Object {
    var n: usize = 0;
    for (1..14) |k| n += boxSlot(self, box, k, out[n..]).len;
    return out[0..n];
}

/// Untaken items of box slot `itm_k` (comma-separated names).
pub fn boxSlot(self: *World, box: *Object, k: usize, out: []*Object) []*Object {
    var name_buf: [8]u8 = undefined;
    const field = std.fmt.bufPrint(&name_buf, "itm_{d}", .{k}) catch return out[0..0];
    const v = box.getVarDyn(field) orelse return out[0..0];
    if (v.value != .string) return out[0..0];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, v.value.string, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0 or n == out.len) continue;
        const o = self.rt.findObject(name) orelse continue;
        if (World.nativeOf(o).deleted or fields.owner(o).len > 0) continue;
        out[n] = o;
        n += 1;
    }
    return out[0..n];
}

/// Take one item from a box (Take Selected); an emptied box can only be closed.
pub fn takeFromBox(self: *World, box: *Object, item: *Object, hero: *Object) !void {
    fields.setOwner(item, hero.name);
    item_mod.setPlace(item, .backpack);
    self.out.sound(self.gpa, @import("../core.zig").modules.ui().sounds.take_items, null);
    item_mod.mergeAmmo(self, item);
    var buf: [64]*Object = undefined;
    const left = boxContents(self, box, &buf).len;
    box.setInt("cnt_itm", @intCast(left));
    if (left == 0) box.setInt("action", 2);
}

pub fn takeAllFromBox(self: *World, box: *Object, hero: *Object) !void {
    var buf: [64]*Object = undefined;
    for (boxContents(self, box, &buf)) |o| try takeFromBox(self, box, o, hero);
}
