//! The rules' row types (one per table, with its call name, file, key fields and the
//! comment written above the table), `Num` (a number that may follow adjust.kdt) and
//! the enums rows use. src/rules.zig is the interface; the built-in rows are the
//! files next to this one. Their text forms are composition's (loaders/codec.zig).
//! shortcut: the rows keep their text schema here (`call`, `file`, `doc`), not their
//! parsing; move it to composition if a second rules format appears.

const std = @import("std");
const adjust = @import("adjust.zig");

/// An adjust.kdt value (the exe's globals) by name, `d` the shipped one.
pub const Adj = struct { name: []const u8, d: i32, neg: bool = false };

/// A number that may follow adjust.kdt: `c` plus up to two adjust values. Rules files
/// write it `adjust("name", default) + c` (loaders/codec.zig), so an adjust.kdt edit
/// still reaches the rule.
pub const Num = struct {
    c: i32 = 0,
    a: ?Adj = null,
    b: ?Adj = null,

    pub fn n(c: i32) Num {
        return .{ .c = c };
    }

    pub fn adj(name: []const u8, d: i32) Num {
        return .{ .a = .{ .name = name, .d = d } };
    }

    /// Ticks: each adjust value clamped at 0 (as attacks.zig `ticks` reads them).
    pub fn ticks(self: Num) u32 {
        var t: i32 = self.c;
        inline for (.{ self.a, self.b }) |x| if (x) |v| {
            const g: i32 = @max(0, adjust.getInt(v.name, v.d));
            t += if (v.neg) -g else g;
        };
        return @intCast(@max(0, t));
    }

    /// Signed (adjust values as they are: the wdelay_* shifts).
    pub fn int(self: Num) i32 {
        var t: i32 = self.c;
        inline for (.{ self.a, self.b }) |x| if (x) |v| {
            const g = adjust.getInt(v.name, v.d);
            t += if (v.neg) -g else g;
        };
        return t;
    }
};

// ---------------------------------------------------------------- rows

/// Monster strike (0x4896b0, table 0x48d618) by fighter classic_id and weapon classic_id.
pub const MonsterAttack = struct {
    pub const call = "MonsterAttack";
    pub const file = "attacks";
    pub const keys = .{ "fighter", "weapon" };
    pub const doc =
        \\Monster strikes (branches 0x4896b0, table 0x48d618), by fighter and weapon classic_id.
        \\A fighter with any row here uses this table; others (heroes, allies, 103, 104, 111,
        \\112, 134) the HeroAttack table (0x48bda2). weapon = 0: any other weapon.
        \\  anim: logical animation; hit_delay: ticks until the hit; after_delay: wait
        \\  after it until the attack ends; second_delay: a second hit that many ticks
        \\  later; react_delay: the target's reaction again without damage that many ticks
        \\  later; flash_delay: flash or beam at that tick before the hit; vanish_delay:
        \\  Invisible fades out that many ticks after the hit; lift_delay/drop_delay: the
        \\  victim lifted on "hand" at that tick and dropped that many ticks after the hit.
        \\  strike: the fighter classic_id whose own effects the strike has (its Strike
        \\  record: Medusa's beam, the Guard's lasers, Headnail's saws...; the exe's code
        \\  by classic_id; 0: its own). OpenGorky: or that fighter's archetype,
        \\  strike = ~c"characters::medusa" (its classic_id).
        \\  gas: the aimed tile and its 8 neighbours get gas (Schizo 1078, 0x4885a8).
        \\  linked_anim: its second linked actor plays that (Smoke Rider 1004, 0x487698).
        \\OpenGorky (the exe has none of these; 0 / "": as the exe):
        \\  give: the fighter gets this weapon at battle entry (weapon = a class: a wp_
        \\  script, included as a .wpn includes it): a new attack.
        \\  effects_from: the game weapon classic_id whose effects the strike has (flash,
        \\  projectile, hit, sound); flash_from, launch_from, hit_from: that stage's alone
        \\  (-1: none); each a number or a weapon archetype, ~w"weapons::rocket_launcher"
        \\  (its classic_id); sound: the hit's sound.
        \\  attack_zone: the weapon class (its name) whose reach and hit tiles it uses;
        \\  max_damage, damage_kind (fire freeze electricity teargas gas bullet melee tranq
        \\  energy attract explosion flammable): the weapon's; recharge_turns: turns after a shot;
        \\  range: the AI strikes only within that many tiles.
        \\  Weapon class fields override a row: attack_anim, hit_delay, after_delay,
        \\  second_delay, react_delay, flash_delay (as the generic fighter).
    ;
    fighter: i32,
    fighter_class: []const u8 = "",
    weapon: i32 = 0,
    weapon_class: []const u8 = "",
    anim: []const u8,
    hit_delay: Num,
    after_delay: Num = .{},
    second_delay: Num = .{},
    react_delay: u32 = 0,
    flash_delay: ?Num = null,
    vanish_delay: u32 = 0,
    lift_delay: u32 = 0,
    drop_delay: u32 = 0,
    strike: i32 = 0,
    strike_class: []const u8 = "",
    gas: bool = false,
    linked_anim: []const u8 = "",
    give: bool = false,
    effects_from: i32 = 0,
    effects_from_class: []const u8 = "",
    flash_from: i32 = 0,
    flash_from_class: []const u8 = "",
    launch_from: i32 = 0,
    launch_from_class: []const u8 = "",
    hit_from: i32 = 0,
    hit_from_class: []const u8 = "",
    sound: []const u8 = "",
    attack_zone: []const u8 = "",
    max_damage: i32 = 0,
    damage_kind: DamageKind = .none,
    recharge_turns: i32 = 0,
    range: i32 = 0,
    note: []const u8 = "",
};

/// Hero strike (0x48bda2) by weapon classic_id (and attacker).
pub const HeroAttack = struct {
    pub const call = "HeroAttack";
    pub const file = "attacks";
    pub const keys = .{ "weapon", "hero" };
    pub const doc =
        \\Hero strikes (0x48bda2, transitions 0x48d6b8) by weapon classic_id; hero = 0: anyone,
        \\else that attacker only; weapon = 0: every other weapon. The exe ignores the
        \\weapon's useAnim.
        \\  anim, wait: animation and ticks until the hit; extra: added to wait for the
        \\  WdelayHero fighters only (wdelay_*, 0x4896f4...0x48973c); until_end: the hit
        \\  after the animation ends, then animation `then`; after: wait after the hit
        \\  (flashes); pre: the beam's tick before the hit (ion rifle, blaster).
        \\OpenGorky: weapon class fields override a row: attack_anim, hit_delay,
        \\after_delay, flash_delay.
    ;
    weapon: i32,
    weapon_class: []const u8 = "",
    hero: i32 = 0,
    hero_class: []const u8 = "",
    anim: []const u8,
    wait: Num,
    extra: Num = .{},
    until_end: bool = false,
    then: []const u8 = "",
    after: Num = .{},
    pre: ?Num = null,
    note: []const u8 = "",
};

/// Heroes whose strikes take HeroAttack `extra` (McFadden, Hutchens).
pub const WdelayHero = struct {
    pub const call = "WdelayHero";
    pub const file = "attacks";
    pub const keys = .{"hero"};
    pub const doc = "Heroes whose HeroAttack waits take `extra` (0x4896f4...0x48973c: McFadden 24, Hutchens 29).";
    hero: i32,
    hero_class: []const u8 = "",
    note: []const u8 = "",
};

/// Resistance words: fire electricity attract energy freeze tranq gas flammable.
pub const Flags = struct {
    bits: [8]u1 = @splat(0),

    pub const words = [8][]const u8{ "fire", "electricity", "attract", "energy", "freeze", "tranq", "gas", "flammable" };

    /// "fire, gas" (the generic fighter's `resist` words and synonyms).
    pub fn parse(s: []const u8) ?Flags {
        var f: Flags = .{};
        var it = std.mem.tokenizeAny(u8, s, ", ;\t");
        while (it.next()) |word| f.bits[(resistIndex(word) orelse return null)] = 1;
        return f;
    }
};

/// Monster resistances (0x6d2070).
pub const Resist = struct {
    pub const call = "Resist";
    pub const file = "resist";
    pub const keys = .{"fighter"};
    pub const doc =
        \\Monster resistances (table 0x6d2070, filled at 0x4c91c0, check 0x4caa80) by fighter
        \\classic_id. resist: words fire electricity attract (decoy) energy freeze tranq gas
        \\flammable; armor: armour class -1 light, -2 medium, -3 heavy (0: none).
        \\New fighters: add a row. The table's order is the saves' (discovered bits).
        \\OpenGorky: a fighter block's `immunity = Resist(…)` (Classic's generic fighter's
        \\fields `resist`, `armor_class` become it).
    ;
    fighter: i32,
    fighter_class: []const u8 = "",
    resist: Flags = .{},
    armor: i32 = 0,
    note: []const u8 = "",
};

/// The after-battle report's kill icon (0x523f00).
pub const KillIcon = struct {
    pub const call = "KillIcon";
    pub const file = "ui";
    pub const keys = .{"fighter"};
    pub const doc =
        \\Kill icons of the after-battle report (table 0x523f00) by fighter classic_id (not by
        \\spriteFile: a fighter missing here, as the shoggoth 117, shows none).
    ;
    fighter: i32,
    fighter_class: []const u8 = "",
    icon: []const u8,
    note: []const u8 = "",
};

/// An actor's glow (0x42a620: the Incubus's): bitmap effect `effect` on its model's link
/// points `links`, `size` half-size (× the actor scale), colour `rgb`.
pub const Glow = struct {
    pub const call = "Glow";
    pub const file = "ui";
    pub const keys = .{"fighter"};
    pub const doc =
        \\An actor's glow (0x42a620, the Incubus's): bitmap effect `effect` on its model's
        \\link points `links` ("t1 t2"), `size` half-size (by the actor scale), colour rgb.
    ;
    fighter: i32,
    fighter_class: []const u8 = "",
    effect: []const u8 = "poswiata",
    links: []const u8 = "t1 t2 t3 t4 t5 t6",
    size: f32 = 46,
    rgb: [3]f32 = .{ 0.5, 0.4, 1.0 },
    note: []const u8 = "",
};

/// The skills window's row icon (0x52a3a8).
pub const SkillIcon = struct {
    pub const call = "SkillIcon";
    pub const file = "ui";
    pub const keys = .{"weapon"};
    pub const doc =
        \\Weapon skills window rows (table 0x52a3a8) by weapon classic_id: a weapon without an
        \\icon here is not listed.
    ;
    weapon: i32,
    weapon_class: []const u8 = "",
    icon: []const u8,
    note: []const u8 = "",
};

/// Weapon sound at the hit (0x4327f0 calls in the weapon effects).
pub const WeaponSound = struct {
    pub const call = "WeaponSound";
    pub const file = "fx";
    pub const keys = .{"weapon"};
    pub const doc =
        \\Weapon sounds at the hit (0x4327f0 calls in the effects, 0x487afd...0x4a8e31) by
        \\weapon classic_id (after FxAs).
    ;
    weapon: i32,
    weapon_class: []const u8 = "",
    sound: []const u8,
    note: []const u8 = "",
};

/// Weapon `weapon` gets the effects (flash, projectile, hit, sound) of game weapon `as`.
pub const FxAs = struct {
    pub const call = "FxAs";
    pub const file = "fx";
    pub const keys = .{"weapon"};
    pub const doc =
        \\Flashes, projectiles and hit effects are effect descriptions per game weapon
        \\classic_id (core/effect.zig), the hit's sound WeaponSound. FxAs(weapon = new, as =
        \\game weapon) gives a weapon another one's; none built in. The weapon class fields `fx_as` / `projectile` do
        \\the same for one weapon. Each stage alone (game weapon classic_id, -1: none):
        \\flash (muzzle flash, beam before the hit), launch (projectile), hit (the hit's
        \\effects); sound: the hit's sound (else WeaponSound). The battle takes the stages
        \\in an OpenGorky project only, where the row is no more: there the weapon's fields
        \\effects_from, flash_from, launch_from, hit_from, hit_sound (the converter's).
    ;
    weapon: i32,
    weapon_class: []const u8 = "",
    as: i32 = 0,
    flash: i32 = 0,
    launch: i32 = 0,
    hit: i32 = 0,
    sound: []const u8 = "",
    note: []const u8 = "",
};

/// Behaviour the exe keeps by weapon classic_id in its battle code.
pub const WeaponFlags = struct {
    pub const call = "WeaponFlags";
    pub const file = "weapon_classes";
    pub const keys = .{"weapon"};
    pub const doc =
        \\What the exe's battle code does by weapon classic_id (a weapon missing here: none).
        \\  no_counter: in a hero's hand, no counter-attack roll (0x491444...0x4914d0).
        \\  shock: a hit puts "current" on the target (0x491c91). sparks: a hit gives
        \\  the flare's sparks (0x491e5e). silent_frames: a hero's strike mutes the
        \\  animation's frame sounds (0x48c1cb, the dartgun's own plays at the shot).
    ;
    weapon: i32,
    weapon_class: []const u8 = "",
    no_counter: bool = false,
    shock: bool = false,
    sparks: bool = false,
    silent_frames: bool = false,
    note: []const u8 = "",
};

/// Battle AI tile scoring by fighter class (table 0x4bcbb0), with its constants.
pub const AiProfile = struct {
    pub const call = "AiProfile";
    pub const file = "ai";
    pub const keys = .{ "fighter", "class", "class_name" };
    pub const doc =
        \\Battle AI (combat/ai.zig, 0x498d30) by fighter classType (table 0x4bcbb0; class 0:
        \\every class not listed, an ordinary monster). A row by fighter (OpenGorky: its
        \\archetype, fighter = ~c"characters::garcia", or a classic_id) overrides the fields
        \\it writes over its class's; an enemy's only, as its class's row (a non-enemy: class 0's).
        \\  scoring: the scoring (generic: ordinary, a: "scoring A" 0x4dcb40, garcia,
        \\  smokerider, grandma, grandma_child, incubus, cripple, guard 0x4e2260, schizo,
        \\  messiah).
        \\  attack_weight, threat_weight, opponent_distance_weight, guard_distance_weight,
        \\  mode: over the fighter's ai_attack_weight, ai_threat_weight,
        \\  ai_opponent_distance_weight, ai_guard_distance_weight, ai_mode.
        \\  damage_bonus: added to max_damage (+5); ally_penalty: an ally on a hit tile
        \\  scores -that/100 of it (10); lock: the AITargetLock target x that/100 (100);
        \\  monitor: a monitor (classType 5) x that (2); decoy_pull: a decoy's path weight
        \\  (2000); decoys: attracted by decoys; step_away: steps away after a strike;
        \\  threat: weighs the threat map (0x494f90). (Never walking is the fighter's ability,
        \\  Abilities `immobile`, not its AI's.)
    ;
    fighter: i32 = 0,
    fighter_class: []const u8 = "",
    class: i32 = 0,
    /// The class by name (an OpenGorky row's `class_name = "stinger"`; rules fighterClassId).
    class_name: []const u8 = "",
    /// The generic fighter's `ai` (focused, sleep_hunter) that takes this class's row.
    generic_ai: []const u8 = "",
    /// OpenGorky: the `ai_profile` block the row is made of (`ai::garcia`; rules_text).
    profile: []const u8 = "",
    scoring: ?AiEval = null,
    attack_weight: ?i32 = null,
    threat_weight: ?i32 = null,
    opponent_distance_weight: ?i32 = null,
    guard_distance_weight: ?i32 = null,
    mode: ?i32 = null,
    damage_bonus: ?i32 = null,
    ally_penalty: ?i32 = null,
    lock: ?i32 = null,
    monitor: ?i32 = null,
    decoy_pull: ?i32 = null,
    decoys: ?bool = null,
    step_away: ?bool = null,
    threat: ?bool = null,
    note: []const u8 = "",
};

/// A tile scoring's name (an AiScoring row's `eval`, an AiProfile's `scoring`): data.
pub const AiEval = []const u8;

/// Weapon class (classType) properties (subclass methods of factory 0x4b4c00), by name.
pub const WeaponClass = struct {
    pub const call = "WeaponClass";
    pub const file = "weapon_classes";
    pub const keys = .{"name"};
    pub const doc =
        \\Weapon classes (classType; factory 0x4b4c00, subclass methods) by name: a weapon
        \\names its class (`class = pistol`); a class missing here has every property off.
        \\  classic_id: the exe's classType (only the built-in classes need it; a new name
        \\  gets a free number, the same as its Pattern row's).
        \\  rolls_to_hit: firearms roll to hit (+0xc4); effect: the state a hit applies
        \\  (+0xf0 -> 0x4900f0): burn freeze gas soak sleep bite; recharge: turns after a
        \\  shot (+0xc8); ignites_soaked: sets a fuel-soaked target on fire.
        \\  kind: the class's own battle code (plain satellite time_bomb decoy napalm
        \\  barrel nitrogen energy sleep_ball messiah_left messiah_right).
    ;
    name: []const u8,
    classic_id: i32 = 0,
    rolls_to_hit: bool = false,
    effect: ?Effect = null,
    /// OpenGorky: the states a hit applies, in order (`effects = [sleep, burn]`); over
    /// `effect` (Classic's one) when given.
    effects: []const Effect = &.{},
    recharge: i32 = 0,
    ignites_soaked: bool = false,
    kind: WeaponKind = .plain,
    note: []const u8 = "",
};

/// A weapon's damage kind (MonsterAttack `damage_kind`): the prelude's WeaponKind, the
/// numbers of a weapon's `damage_kind` (battle/immunity.zig DamageType); none: the weapon's.
pub const DamageKind = enum(i32) { none = 0, fire = 1, freeze = 2, electricity = 3, teargas = 4, gas = 5, bullet = 6, melee = 7, tranq = 9, energy = 11, attract = 12, explosion = 13, flammable = 14 };

/// A weapon class's own code in the battle (reach, strike, damage), beyond its other
/// WeaponClass fields (the built-ins: the exe's classTypes).
pub const WeaponKind = enum {
    plain,
    /// Any open tile of the field, 100 % (class 8, +0x104 0x4b8e90).
    satellite,
    /// Planted on a free neighbouring tile, explodes later (class 9, 0x4b9200).
    time_bomb,
    /// No skill; places a decoy on a free tile (class 18, 0x4b9750).
    decoy,
    /// Sets every hit tile on fire for 3 turns (class 16, +0xf4 0x4cf7a0).
    napalm,
    /// Barrel blast: no exp, sets off barrels (class 17).
    barrel,
    /// Puts out fire before the cold check (class 19, 0x4bbcb0).
    nitrogen,
    /// Stopped whole by resistance to energy (ion rifle 6, blaster 7: 0x4b84f0, 0x4b8a40).
    energy,
    /// The Stinger's ball: only sleep, no damage (class 1005, 0x4d87a0).
    sleep_ball,
    /// The Messiah's arms: kept still by the obstacle at (10, 19) / (10, 17) (1019, 1020).
    messiah_left,
    messiah_right,
};

/// Weapon class reach and hit tiles (patterns.zig), by the class's name.
pub const Pattern = struct {
    pub const call = "Pattern";
    pub const file = "patterns";
    pub const keys = .{"name"};
    pub const doc =
        \\Weapon class reach and hit tiles (factory 0x4b4c00, pattern writer 0x4b6340), by
        \\the class's name (as WeaponClass); classic_id: the exe's classType (built-ins only).
        \\  wide: a two-tile-wide ray (2x2 fighters, mode +0x1a64).
        \\  rays: "dx,dy,kind,effect,pct ..." tiles from the shooter; kind s: a ray start,
        \\  c: continues the previous ray (stops at obstacles), x/y: the side of a wide
        \\  fighter's second tile; effect: the hit tile set; pct: damage percent there.
        \\  effects: up to 4 hit tile sets "dx,dy ... | dx,dy ..." from the target tile.
    ;
    // Its built-in rows get it from weapon_classes.zig `names`.
    name: []const u8 = "",
    classic_id: i32 = 0,
    wide: bool = false,
    rays: Rays = .{},
    effects: Effects = .{},
    note: []const u8 = "",
};

/// Medicine effect (0x48ff50) by item classic_id.
pub const Medicine = struct {
    pub const call = "Medicine";
    pub const file = "items";
    pub const keys = .{"item"};
    pub const doc =
        \\Medicine effects (0x48ff50) by item classic_id; any other medicine heals.
        \\  kind: heal rage calm ungas wake; random: acts as one of these items
        \\  (rand & 3, 0x48ff76).
    ;
    item: i32,
    item_class: []const u8 = "",
    kind: MedicineKind = .heal,
    random: []const i32 = &.{},
    /// OpenGorky: each of `random` naming an item archetype instead (`random =
    /// list(~i"items::pills", …)`; "": that place's number); none: all numbers.
    random_class: []const []const u8 = &.{},
    note: []const u8 = "",
};

/// Heal bonus of a healer (0x48ffee).
pub const HealBonus = struct {
    pub const call = "HealBonus";
    pub const file = "items";
    pub const keys = .{"healer"};
    pub const doc =
        \\Character bonuses: a healer's (0x48ffee) floor(hp x pct / 100) more (McFadden 15%,
        \\0x50a218); pct not 0 shows "special skill: healing +pct%" in its stats window (0x52ac28).
        \\OpenGorky (the exe has none of these; 0 = as the exe): hit: points added to its hit
        \\chance (0x4cedc2); damage: percent more damage on its hits (after the strike roll,
        \\0x4ced30); walk: tiles more of its walk range in battle.
    ;
    healer: i32,
    healer_class: []const u8 = "",
    pct: i32,
    hit: i32 = 0,
    damage: i32 = 0,
    walk: i32 = 0,
    note: []const u8 = "",
};

/// Item and area action (0x4564b0), by its name.
pub const Action = struct {
    pub const call = "Action";
    pub const file = "actions";
    pub const keys = .{"name"};
    pub const doc =
        \\Item and area actions (0x4564b0) by name: the menu row and what it does. A new
        \\name is a new row; objects name it in `action` (`action1`... an area's further
        \\menu rows): OpenGorky by the name, Classic (funcID) by its classic_id.
        \\  name: the script function it calls on the object (with the hero's name), also
        \\  the row's text when string.tab has none; classic_id: the exe's number of it
        \\  (only the built-in actions need it; OpenGorky gives a new name a free number);
        \\  text: the menu row's string.tab id (0: the built-in classic_id's own, a new
        \\  action's name); label: its text by interface key (OpenGorky: "open"); kind: call (just
        \\  that), take (Take, else UniversalTake, ammo merged), explore (the box window).
        \\  auto_open: on an object with items (cnt_itm > 0) no examine menu; the box
        \\  window opens by itself after the action (0x457340, 0x45b04f; 7 Explore).
        \\  on_exit: on an exit (isLevelSwitch > 0) the action runs instead of
        \\  LevelSwitch, and the cursor is no exit's (1 Open).
        \\  walk_click: a left click on an area (not an exit) only walks there (2 Close).
        \\An object's action -1 and 0 (no row: OpenGorky `walk`, `none`) are the exe's code:
        \\walk (an exit: no examine menu; with a WalkPath, walks it), none (just walks there).
    ;
    name: []const u8,
    classic_id: i32 = 0,
    text: i32 = 0,
    /// The menu row's text by interface key (core/ui_text.zig: "open"; an OpenGorky row's).
    label: []const u8 = "",
    kind: ActionKind = .call,
    auto_open: bool = false,
    on_exit: bool = false,
    walk_click: bool = false,
    note: []const u8 = "",
};

const ActionKind = enum { call, take, explore };

/// Exp per hero level (0x528c3c).
pub const ExpLevel = struct {
    pub const call = "ExpLevel";
    pub const file = "party";
    pub const keys = .{"level"};
    pub const doc = "Exp thresholds (table 0x528c3c, 0x48f9c0): the level grows while exp exceeds its level's.";
    level: i32,
    exp: i32,
    note: []const u8 = "",
};

/// Weapons a fighter doesn't draw in hand (0x5270a0).
pub const HiddenWeapons = struct {
    pub const call = "HiddenWeapons";
    pub const file = "party";
    pub const keys = .{"hero"};
    pub const doc = "Weapons a fighter (classic_id) can't use or draw in hand (table 0x5270a0, 0x481f50): weapon classic_ids.";
    hero: i32,
    hero_class: []const u8 = "",
    weapons: []const i32,
    /// OpenGorky: each of `weapons` naming a weapon archetype instead ("": its number).
    weapons_class: []const []const u8 = &.{},
    note: []const u8 = "",
};

/// The selected hero's idle line (0x451110).
pub const IdleChatter = struct {
    pub const call = "IdleChatter";
    pub const file = "party";
    pub const keys = .{"hero"};
    pub const doc = "Idle lines (0x451110): after idle_ticks without input the selected hero (classic_id) plays anim, then says dialog.";
    hero: i32,
    hero_class: []const u8 = "",
    dialog: []const u8,
    anim: []const u8 = "",
    note: []const u8 = "",
};

/// A character's roles (OpenGorky): one class script (`ft_x.ss`) that may be an enemy (a
/// battle's `.ftr` includes it) and a hero (a `.hro` includes it). No built-in rows:
/// without one, the roles are its files' (the editor shows them so; the game reads none).
pub const Character = struct {
    pub const call = "Character";
    pub const file = "fighters";
    pub const keys = .{"fighter"};
    pub const doc =
        \\A character's roles (OpenGorky) by its class script (fighter = "ft_wasp"): as_enemy (a
        \\battle's .ftr includes it), as_hero (a .hro includes it); both: one class, rules by
        \\class shared. A class without a row: its files' roles. Where it fights is the
        \\battles' and scripts' (they place it), not this row's.
    ;
    fighter: i32 = 0,
    fighter_class: []const u8 = "",
    // Not `hero`: that word is a hero key (rules.entity_keys).
    as_hero: bool = false,
    as_enemy: bool = false,
    note: []const u8 = "",
};

/// A special ID or limit the exe keeps in its code (rules/consts.zig).
pub const Value = struct {
    pub const call = "Value";
    pub const file = "party";
    pub const keys = .{"name"};
    pub const doc =
        \\Special IDs, limits and battle formula numbers the exe keeps in its code
        \\(rules/rows.zig Const says where each is used; _pm: per mille).
    ;
    name: Const,
    value: i32,
    note: []const u8 = "",
};

/// The game's start and shell (rules/campaign.zig): the exe's hard-coded new game. One
/// row, no key: a file's Campaign(...) writes its fields over the built-in one.
pub const Campaign = struct {
    pub const call = "Campaign";
    pub const file = "campaign";
    pub const keys = .{};
    pub const doc =
        \\The campaign: what a new game starts with and the main menu's shell (the exe:
        \\0x413386 new game, 0x40fd06 videos before the menu, 0x431550 gamestart heroes).
        \\  level: the location a new game opens; leader: the hero selected at the start.
        \\  party: hero scripts the game has from the start, "a.hro b.hro" (gamestart\ of
        \\  common/other.dat, else any location's; a hero copy's file): every location makes
        \\  these, in this order; "" = every gamestart\*.hro, as the exe.
        \\  panel_first: heroes (object names) the party panel shows first, in this order,
        \\  then those who joined ("Sullivan Ovitz Trantigne", the exe's).
        \\  area, point: the party put at that area's points from `point` on arrival
        \\  ("" = where the location's own init puts them); scene: a scriptlet started then.
        \\  intro: videos before a new game ("a.avi b.mp4"; any format FFmpeg plays);
        \\  startup: videos before the main menu.
        \\  menu_logo: the logo texture (gfx_3d\textures); menu_music, credits_music:
        \\  music tracks; credits: the credits text (common/lang.dat); credits_video: a
        \\  video before the credits ("" none). The menu's title is the manifest's.
    ;
    level: []const u8,
    leader: []const u8,
    party: []const u8,
    panel_first: []const u8,
    area: []const u8,
    point: i32,
    scene: []const u8,
    intro: []const u8,
    startup: []const u8,
    menu_logo: []const u8,
    menu_music: []const u8,
    credits_music: []const u8,
    credits: []const u8,
    credits_video: []const u8,
    note: []const u8 = "",
};

/// An engine tuning value (an OpenGorky project's rules\adjust.ss; a Classic game's
/// adjust.kdt holds the same names), typed as the file has it.
pub const Setting = struct {
    pub const call = "Setting";
    pub const file = "adjust";
    pub const keys = .{ "name", "weapon" };
    pub const doc =
        \\The engine's tuning values: one row per name, int = n, float = x or
        \\rgba = list(r, g, b). A name without a row is the engine's built-in value. The rules rows hold their own numbers (conversion wrote each
        \\adjust("name", d) out); one an older file still writes reads its value here.
    ;
    name: []const u8,
    /// OpenGorky: one weapon's own value (`Setting(name = …, weapon = ~w"weapons::flame_thrower")`,
    /// its block's `flame = Flame(…)`): the effects it makes take it over the project's.
    weapon: i32 = 0,
    weapon_class: []const u8 = "",
    int: ?i32 = null,
    float: ?f32 = null,
    rgba: ?[3]u8 = null,
    note: []const u8 = "",

    pub fn of(name: []const u8, v: adjust.Value) Setting {
        return switch (v) {
            .int => |x| .{ .name = name, .int = x },
            .float => |x| .{ .name = name, .float = x },
            .rgba => |x| .{ .name = name, .rgba = x },
        };
    }

    /// Its value (null: a row without one).
    pub fn value(r: Setting) ?adjust.Value {
        if (r.int) |x| return .{ .int = x };
        if (r.float) |x| return .{ .float = x };
        if (r.rgba) |x| return .{ .rgba = x };
        return null;
    }
};

/// Each one with where the port uses it.
pub const Const = enum {
    /// Ticks without input before the selected hero's idle chatter (game.zig, 0x451110).
    idle_ticks,
    /// Heroes in the party at most (state/world.zig party; the exe's 6; the port holds
    /// up to World.party_cap).
    party_max,
    /// Exp for a kill, per mille of the victim's max_hp (combat/strike.zig, 0x4cf3b1: 0.2).
    kill_exp_pm,
    /// Stat points per level gained (combat/strike.zig awardExp).
    level_points,
    /// Luck, accuracy and counterattack at most in the points window (viewer stats, 0x4b0980).
    stat_cap,
    /// Weapon skill percent per skill level (battle/rules.zig skillPercent, 0x48fe10).
    skill_step,
    /// Luck crit damage factor, per mille (battle/rules.zig strike, 0x4cf015: 1.2).
    crit_pm,
    /// Rage damage factor, per mille (battle/rules.zig strike, 0x4cf0d7: 2).
    rage_pm,
    /// Damage bonus of a strike from the side / the back (battle/rules.zig sideBonus, 0x490f9e).
    side_bonus,
    back_bonus,
    /// Counter-attack roll: rand % 1000 <= counterAttack x this (combat/strike.zig, 0x491444).
    counter_step,
    /// 1: any hero's death loses the battle (the exe, 0x490620); 0: only the whole party's.
    lose_on_hero_death,
};

/// Fighter state applied by 0x4900f0 (the number is the call argument).
pub const Effect = enum(u8) {
    burn = 1,
    freeze = 2,
    gas = 3,
    /// Soaked with fuel (if burning, 3 more turns of fire).
    soak = 4,
    defend = 5,
    sleep = 6,
    /// Invisible's poison in 04__city_mfd (+0x248e8), incurable.
    bite = 8,
};

/// Medicine effect (0x48ff50).
pub const MedicineKind = enum { heal, rage, calm, ungas, wake };

/// `resist` word → resistance index 0–7 (fire … flammable; codes 1–8), with synonyms.
pub fn resistIndex(word: []const u8) ?usize {
    const names = [_]struct { []const u8, usize }{
        .{ "fire", 0 },    .{ "electricity", 1 }, .{ "elect", 1 },  .{ "shock", 1 },     .{ "decoy", 2 },
        .{ "attract", 2 }, .{ "energy", 3 },      .{ "freeze", 4 }, .{ "cold", 4 },      .{ "tranq", 5 },
        .{ "sleep", 5 },   .{ "gas", 6 },         .{ "poison", 6 }, .{ "flammable", 7 }, .{ "flame", 7 },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(word, n[0])) return n[1];
    return null;
}

pub const Ray = struct {
    dx: i8,
    dy: i8,
    kind: Kind,
    effect: u8,
    pct: u8,

    const Kind = enum { start, chain, side_x, side_y };
    pub const letters = "scxy";
};

/// Rays, written "dx,dy,kind,effect,pct …" (kind s/c/x/y).
pub const Rays = struct {
    items: []const Ray = &.{},
};

/// Hit tile sets relative to the target tile (+0x1734, up to 4), written
/// "dx,dy … | dx,dy … | … " (empty sets at the end left out).
pub const Effects = struct {
    sets: [4][]const [2]i8 = @splat(&.{}),
};
