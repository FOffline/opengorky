//! Weapon class (`classType` in .wpn and cw_*.s / wp_*.ss classes): the factory
//! 0x4b4c00 picks the weapon subclass by it (tables 0x4b5d24 for 1…25, 0x4b5d84
//! for 101…, 0x4b5dec for 1001…). Tile patterns are rules `Pattern` rows (src/rules/patterns.zig), subclass
//! properties in `rules.zig`; the classes' names: rules/weapon_classes.zig `Class`
//! (values outside the list are allowed, `_`).

const Object = @import("../script.zig").object.Object;
const rules = @import("../rules.zig");

/// Reach and hit tiles of the weapon's classType; in an OpenGorky project those of class
/// `attack_zone` when it has one (set from rules MonsterAttack `attack_zone`, or its class field).
pub fn pattern(o: *Object) ?*const rules.Pattern {
    const z = if (rules.og) o.getInt("attack_zone") else 0;
    return rules.pattern(if (z > 0) z else o.getInt("class"));
}

/// The exe's weapon classes by name (rules/weapon_classes.zig: the one table of the names).
pub const WeaponClass = rules.WeaponClassName;

test "the core's weapon kinds are these classes" {
    const kind = @import("../core.zig").modules.weaponKind;
    const t = @import("std").testing;
    const want = [_]struct { WeaponClass, @TypeOf(kind(0)) }{
        .{ .satellite, .satellite },       .{ .time_bomb, .time_bomb },         .{ .decoy, .decoy },
        .{ .napalm_launcher, .napalm },    .{ .barrel_blast, .barrel },         .{ .nitrogen_thrower, .nitrogen },
        .{ .ion_rifle, .energy },          .{ .blaster, .energy },              .{ .stinger_long, .sleep_ball },
        .{ .messiah_left, .messiah_left }, .{ .messiah_right, .messiah_right }, .{ .rifle, .plain },
    };
    for (want) |x| try t.expectEqual(x[1], kind(@backingInt(x[0])));
}
