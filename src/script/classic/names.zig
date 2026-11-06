//! The original's field names: the one table between the names of the exe's
//! base classes (`classes\fighter.s int charSize;`) and the engine's (`footprint_tiles`).
//! The core, OG Script, the editor and saves know only the new names; the Classic reader
//! renames as it reads (a class's variables, `runtime.declareVars`; a name in its code,
//! `import.zig`; a `.var` entry, `runtime.applyVar`), the Classic writer keeps the old
//! spelling (an IR name keeps its text, `ir.Name`), the converter writes the new one. A
//! name is renamed by its host: a weapon's `type` is `damage_kind`, an item's `kind`.
//! Values do not change here: the converter writes an OG field's value by its schema type
//! (`core/schema.zig`: a flag's 0/1 as `false`/`true`, an enum's number as its word).

const std = @import("std");

/// The exe's base classes that have fields (`classes\<name>.s`), as `core/schema.zig` names
/// its hosts.
pub const Host = enum {
    gameobject,
    level,
    combatlevel,
    actor,
    fighter,
    item,
    weapon,
    activearea,
    bitmapanimation,
    activebitmapanimation,

    pub fn parent(h: Host) ?Host {
        return switch (h) {
            .gameobject => null,
            .level, .actor, .item, .activearea, .bitmapanimation => .gameobject,
            .combatlevel => .level,
            .fighter => .actor,
            .weapon => .item,
            .activebitmapanimation => .bitmapanimation,
        };
    }

    fn depth(h: Host) u8 {
        var d: u8 = 0;
        var at = h.parent();
        while (at) |p| : (at = p.parent()) d += 1;
        return d;
    }

    /// The host of a base class's script file (`classes\weapon.s`, `level.s`); null: none.
    pub fn ofFile(file: []const u8) ?Host {
        const base = file[if (std.mem.lastIndexOfAny(u8, file, "\\/")) |k| k + 1 else 0..];
        if (!std.ascii.endsWithIgnoreCase(base, ".s")) return null;
        var buf: [32]u8 = undefined;
        if (base.len - 2 > buf.len) return null;
        return std.meta.stringToEnum(Host, std.ascii.lowerString(&buf, base[0 .. base.len - 2]));
    }

    pub fn byName(name: []const u8) ?Host {
        var buf: [32]u8 = undefined;
        if (name.len > buf.len) return null;
        return std.meta.stringToEnum(Host, std.ascii.lowerString(&buf, name));
    }

    /// The more derived of `a` and `b` (a class including `weapon.s` after `item.s`).
    pub fn deeper(a: ?Host, b: Host) Host {
        const x = a orelse return b;
        return if (b.depth() > x.depth()) b else x;
    }
};

const Rename = struct { host: Host, old: []const u8, new: []const u8 };

/// Old name → new, by the host that declares it (the fields kept as they
/// are have no row).
pub const table = [_]Rename{
    // gameobject: every object's, a class including no base class's too.
    .{ .host = .gameobject, .old = "nameID", .new = "classic_id" },
    // An item's and an area's menu action (rules Action), and a box's (an
    // obstacle including `fighter.s`, its own variable); an area's further ones `funcID1`…
    // (a lift's second button; state/world.zig max_actions) are its own variables.
    .{ .host = .gameobject, .old = "funcID", .new = "action" },
    .{ .host = .gameobject, .old = "funcID1", .new = "action1" },
    .{ .host = .gameobject, .old = "funcID2", .new = "action2" },
    .{ .host = .gameobject, .old = "funcID3", .new = "action3" },
    // level; kept: `ctrlPoint*`, `scale`, `grid` (no reader),
    // `perspective`.
    .{ .host = .level, .old = "frontPlane", .new = "near_plane" },
    .{ .host = .level, .old = "backPlane", .new = "far_plane" },
    .{ .host = .level, .old = "rotxy", .new = "ortho_rotation_radians" },
    .{ .host = .level, .old = "viewX", .new = "eye_x" },
    .{ .host = .level, .old = "viewY", .new = "eye_y" },
    .{ .host = .level, .old = "viewZ", .new = "eye_z" },
    .{ .host = .level, .old = "aimX", .new = "target_x" },
    .{ .host = .level, .old = "aimY", .new = "target_y" },
    .{ .host = .level, .old = "aimZ", .new = "target_z" },
    .{ .host = .level, .old = "angle", .new = "fov" },
    .{ .host = .level, .old = "actorScale", .new = "actor_scale" },
    .{ .host = .level, .old = "speedScale", .new = "speed_scale" },
    .{ .host = .level, .old = "zLevel", .new = "floor_z" },
    .{ .host = .level, .old = "cameraScale", .new = "camera_scale" },
    .{ .host = .level, .old = "aspectRatio", .new = "aspect_ratio" },
    .{ .host = .level, .old = "camBan", .new = "camera_bank" },
    .{ .host = .level, .old = "advVar", .new = "progress" },
    .{ .host = .level, .old = "levelMode", .new = "mode" },
    .{ .host = .level, .old = "shadowActive", .new = "shadows" },
    .{ .host = .level, .old = "bossmonsterLevel", .new = "boss" },
    // combatlevel; `isCombat` keeps its name: the exe's class marker.
    .{ .host = .combatlevel, .old = "xSize", .new = "grid_columns" },
    .{ .host = .combatlevel, .old = "ySize", .new = "grid_rows" },
    .{ .host = .combatlevel, .old = "centerX", .new = "grid_origin_x" },
    .{ .host = .combatlevel, .old = "centerY", .new = "grid_origin_y" },
    .{ .host = .combatlevel, .old = "centerZ", .new = "grid_origin_z" },
    .{ .host = .combatlevel, .old = "rotation", .new = "grid_rotation_radians" },
    .{ .host = .combatlevel, .old = "width", .new = "grid_width" },
    .{ .host = .combatlevel, .old = "height", .new = "grid_height" },
    .{ .host = .combatlevel, .old = "turnNo", .new = "turn" },
    .{ .host = .combatlevel, .old = "killedEnemies", .new = "enemies_killed" },
    // actor.
    .{ .host = .actor, .old = "rotSpeed", .new = "turn_speed" },
    .{ .host = .actor, .old = "spriteFile", .new = "portrait" },
    .{ .host = .actor, .old = "meshFile", .new = "mesh" },
    .{ .host = .actor, .old = "sex", .new = "gender" },
    // fighter; kept: `calmness`, `actRot` (no reader).
    .{ .host = .fighter, .old = "classType", .new = "battle_class" },
    .{ .host = .fighter, .old = "counterAttack", .new = "counter_attack" },
    .{ .host = .fighter, .old = "charSize", .new = "footprint_tiles" },
    .{ .host = .fighter, .old = "explodeWeapon", .new = "blast_weapon" },
    .{ .host = .fighter, .old = "aiMode", .new = "ai_mode" },
    .{ .host = .fighter, .old = "moveLock", .new = "move_locked" },
    .{ .host = .fighter, .old = "attackLock", .new = "attack_locked" },
    .{ .host = .fighter, .old = "avoidEnumerate", .new = "outside_party" },
    .{ .host = .fighter, .old = "aicAttack", .new = "ai_attack_weight" },
    .{ .host = .fighter, .old = "aicDefense", .new = "ai_threat_weight" },
    .{ .host = .fighter, .old = "aicPlayerDist", .new = "ai_opponent_distance_weight" },
    .{ .host = .fighter, .old = "aicGuardDist", .new = "ai_guard_distance_weight" },
    .{ .host = .fighter, .old = "prFire", .new = "resist_fire" },
    .{ .host = .fighter, .old = "prElect", .new = "resist_electricity" },
    .{ .host = .fighter, .old = "prDist", .new = "resist_decoy" },
    .{ .host = .fighter, .old = "prEnergy", .new = "resist_energy" },
    .{ .host = .fighter, .old = "prFreeze", .new = "resist_freeze" },
    .{ .host = .fighter, .old = "prTranq", .new = "resist_sleep" },
    .{ .host = .fighter, .old = "prGas", .new = "resist_gas" },
    // item; kept: `effect_time` (no reader), `two_handed` (0/1/2).
    .{ .host = .item, .old = "radius", .new = "walk_block_radius" },
    .{ .host = .item, .old = "Owner", .new = "owner" },
    .{ .host = .item, .old = "spriteFile", .new = "icon" },
    .{ .host = .item, .old = "meshFile", .new = "mesh" },
    .{ .host = .item, .old = "useAnim", .new = "use_anim" },
    .{ .host = .item, .old = "walk_x", .new = "approach_x" },
    .{ .host = .item, .old = "walk_y", .new = "approach_y" },
    .{ .host = .item, .old = "walk_angle", .new = "approach_angle" },
    .{ .host = .item, .old = "type", .new = "kind" },
    .{ .host = .item, .old = "prFire", .new = "resist_fire" },
    .{ .host = .item, .old = "prElect", .new = "resist_electricity" },
    .{ .host = .item, .old = "prDist", .new = "resist_decoy" },
    .{ .host = .item, .old = "prEnergy", .new = "resist_energy" },
    .{ .host = .item, .old = "prFreeze", .new = "resist_freeze" },
    .{ .host = .item, .old = "prTranq", .new = "resist_sleep" },
    .{ .host = .item, .old = "prGas", .new = "resist_gas" },
    .{ .host = .item, .old = "prFlam", .new = "resist_flammable" },
    .{ .host = .item, .old = "counter", .new = "count" },
    // weapon; kept: `range_effect`, `dist_effect`, `near_effect` (no reader),
    // `attackEffectDelay` (the OG weapon's `hit_delay` overrides its row: one name would
    // change the converted battles). `ammo` is the core's number, OG Script's a reference
    // to an item archetype (or `thrown`; core/schema.zig).
    .{ .host = .weapon, .old = "ammoUsed", .new = "ammo" },
    .{ .host = .weapon, .old = "classType", .new = "class" },
    .{ .host = .weapon, .old = "type", .new = "damage_kind" },
    .{ .host = .weapon, .old = "secondaryWeapon", .new = "secondary" },
    .{ .host = .weapon, .old = "effect_range", .new = "blast_radius" },
    .{ .host = .weapon, .old = "move_range_effect", .new = "move_penalty" },
    .{ .host = .weapon, .old = "accuracy_effect", .new = "accuracy_bonus" },
    .{ .host = .weapon, .old = "longAttack", .new = "long_attack" },
    .{ .host = .weapon, .old = "extraExperience", .new = "bonus_experience" },
    .{ .host = .weapon, .old = "lightArmor", .new = "light_armor_pct" },
    .{ .host = .weapon, .old = "mediumArmor", .new = "medium_armor_pct" },
    .{ .host = .weapon, .old = "heavyArmor", .new = "heavy_armor_pct" },
    // bitmapanimation, activebitmapanimation.
    .{ .host = .bitmapanimation, .old = "speed", .new = "frames_per_second" },
    .{ .host = .bitmapanimation, .old = "cur_frame", .new = "frame" },
    .{ .host = .bitmapanimation, .old = "old_frame", .new = "prev_frame" },
    .{ .host = .bitmapanimation, .old = "spriteFile", .new = "sprite" },
    .{ .host = .bitmapanimation, .old = "zbufFile", .new = "depth_sprite" },
    .{ .host = .activebitmapanimation, .old = "unistate", .new = "one_shot" },
    // activearea; kept: `areaName`, `isLevelSwitch` (OG writes `polygon`, `exit`).
    .{ .host = .activearea, .old = "noHint", .new = "hint_hidden" },
    .{ .host = .activearea, .old = "noExamine", .new = "examine_hidden" },
};

/// The new name of field `old` (any case) of an object of host `h` (its ancestors' too;
/// no host: a gameobject's); null: not renamed.
pub fn toNew(h: ?Host, old: []const u8) ?[]const u8 {
    var at: ?Host = h orelse .gameobject;
    while (at) |x| : (at = x.parent()) {
        for (table) |r| if (r.host == x and std.ascii.eqlIgnoreCase(r.old, old)) return r.new;
    }
    return null;
}

/// The exe's name of field `new` of host `h` (its ancestors' too); null: not renamed.
fn toOld(host: ?Host, new: []const u8) ?[]const u8 {
    const h = host orelse .gameobject;
    var at: ?Host = h;
    while (at) |x| : (at = x.parent()) {
        for (table) |r| if (r.host == x and std.mem.eql(u8, r.new, new)) {
            // A field the host renames again (a weapon's `type`) has no ancestor's name.
            if (x != h and toNew(h, r.old) != null and !std.mem.eql(u8, toNew(h, r.old).?, new)) return null;
            return r.old;
        };
    }
    return null;
}

/// The exe's spelling of engine name `new` on whichever host has it (one: no two old names
/// get the same new one; `sprite`, `icon`, `portrait` are all `spriteFile`): the editor
/// reads and writes a Classic file's text by it.
pub fn anyOld(new: []const u8) ?[]const u8 {
    for (table) |r| if (std.mem.eql(u8, r.new, new)) return r.old;
    return null;
}

/// `old` as the engine calls it on host `h`.
pub fn engine(h: ?Host, old: []const u8) []const u8 {
    return toNew(h, old) orelse old;
}

/// `new` as the exe's files spell it on host `h`.
pub fn classic(h: ?Host, new: []const u8) []const u8 {
    return toOld(h, new) orelse new;
}

test "names: by host, ancestors, back" {
    // Exercised with the real rows once they exist; the walk itself:
    try std.testing.expectEqual(Host.weapon, Host.ofFile("classes\\Weapon.s").?);
    try std.testing.expectEqual(Host.weapon, Host.deeper(.item, .weapon));
    try std.testing.expectEqual(Host.weapon, Host.deeper(.weapon, .item));
    try std.testing.expect(Host.ofFile("ft_grandma.ss") == null);
    for (table) |r| {
        // `anyOld` holds: one old name per new one.
        try std.testing.expect(std.ascii.eqlIgnoreCase(r.old, anyOld(r.new).?));
        try std.testing.expectEqualStrings(r.new, toNew(r.host, r.old).?);
        try std.testing.expectEqualStrings(r.old, toOld(r.host, r.new).?);
    }
}
