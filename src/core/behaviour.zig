//! Fighter behaviour (the "fighter behaviour" core module, core/modules.zig `Fighters`):
//! every fighter, hero or enemy, fights as the ordinary one plus its abilities
//! ("extra abilities": `Abilities`, one rules row of parts with their parameters, the
//! schema of the native components core/natives.zig attaches to it as it is made: the
//! battle asks their traits); `Strike` by the rules'
//! MonsterAttack `strike` (generic.Fx), `Scoring` by the AI profile's `scoring`. The
//! engine knows the parts, not the fighters: which fighter has which is data — the
//! original's in core/classic.zig (the exe's per-classType virtual methods, factory
//! 0x4bc6c0, and its classic_id / object-name special cases), an OpenGorky project's
//! `rules\fighters.ss`/`ai.ss` rows over them (composition: loaders/rules_text.zig).
//! A project's own behaviour is a scripted ability (`Abilities.scripts`): an OGS component
//! `for fighter` of its rules' code attached to the fighter for the battle, its params by
//! name, its handlers called at the battle's events (script/traits.zig, combat/events.zig)
//! after the natives'. A new native ability: a field here, its component in
//! core/natives.zig, its methods in combat/natives.zig, a trait query where the battle does
//! that thing.

const std = @import("std");
const Num = @import("../rules.zig").rows.Num;
const AiEval = @import("../rules.zig").AiEval;

/// A battle tile (battle/grid.zig Tile).
pub const Tile = [2]i32;

/// A tile relative to a fighter (`relTile`): x tiles to its right, y ahead (its facing on
/// the grid, its `stand` angle when it has one); from its tile (a big one's top-left).
pub const Rel = [2]i32;

/// Struck from the front and sides (under `cone` radians from its gaze) the damage is /`div`,
/// at least `min`, before the side bonus, armour and defence (Puppet +0xcc 0x4e1bb0).
const Guard = struct { div: i32, min: i32, cone: f32 };

/// Arms on tiles a box can block (relative, `Rel`): no strike with an arm whose tile holds an
/// obstacle (the weapon kinds messiah_left/right), both blocked: `blocked` after its move.
const Arms = struct { left: Rel, right: Rel, blocked: []const u8 };

/// A fighter's abilities: the ordinary fighter (every field at its default) plus the parts
/// set. Keyed by classType, or by one fighter (`fighter`: its classic_id, a class script
/// "ft_wasp" or a placed object's name), whose row is all of its own (over its classType's).
pub const Abilities = struct {
    pub const call = "Abilities";
    pub const file = "fighters";
    pub const keys = .{ "fighter", "class", "class_name" };
    pub const doc =
        \\A fighter's abilities in battle, hero or enemy alike: the ordinary fighter plus the
        \\parts set (the original's: the exe's virtual methods by classType, factory 0x4bc6c0,
        \\and its special cases by classic_id or object name). A row by fighter (fighter = "ft_wasp",
        \\a classic_id or a placed object's name) is that fighter's whole own, over its classType's.
        \\  double_turn: acts twice per turn; first_in_mode: acts first on a level of this
        \\  levelMode; immobile: never walks; stand / stand_after_move: the angle it stands at
        \\  (after its move too); guard: damage /div (at least min) from the front cone;
        \\  open_from / dodge / arms: struck only from that tile, else it dodges, arms on tiles
        \\  a box blocks (tiles list(right, ahead) from its own); monitor; kill_credit; pairs /
        \\  double_strike: weapon pairs by its counter, two strikes into a tile; heals / avenger:
        \\  the fighter (object name) it heals by its damage / that avenges it; invisible: starts
        \\  unseen; leaves: leaves the battle after each enemy round; no_push; no_hands: no
        \\  give/receive, no fist; battle_only: never picked outside a battle.
        \\  scripts (OpenGorky): scripted abilities, list(Name(param = value, …), …): the
        \\  project's OGS components `for fighter` (its rules' code, rules\abilities.ss),
        \\  attached in this order for each battle, params by name (the rest their defaults;
        \\  a fighter param: an object name).
    ;
    /// One fighter's own row (as AiProfile's `fighter`); 0 and "": by classType.
    fighter: i32 = 0,
    fighter_class: []const u8 = "",
    class: i32 = 0,
    /// The class by name (an OpenGorky row's `class_name = "puppet"`; rules fighterClassId).
    class_name: []const u8 = "",
    /// Acts twice in a row per turn, a full walk budget each (Incubus, Cripple: +0x24908);
    /// a hero the player leads: two strikes, the walk budget anew after the first.
    double_turn: bool = false,
    /// Acts first in the enemy turn on a level of this levelMode (Grandma in the
    /// citadel: 2, 0x498288); 0: list order.
    first_in_mode: i32 = 0,
    /// Never walks ("nailed down"; as `moveLock`, but for good).
    immobile: bool = false,
    /// "Stand properly" (+0xd0) at this angle (Puppet 0x4e1b80, Messiah 0x4df8d0);
    /// null: face the nearest opponent (0x48ef10).
    stand: ?f32 = null,
    /// Stands properly at the end of its own move too (Puppet 0x4e17b0, Messiah 0x4dfdd4).
    stand_after_move: bool = false,
    guard: ?Guard = null,
    /// Struck only from this tile (`Rel`): elsewhere a miss (0x4cee33), it dodges with
    /// `dodge` before the shot (0x47c4c0), the heroes' autoplay doesn't aim at it (Messiah).
    open_from: ?Rel = null,
    dodge: []const u8 = "",
    arms: ?Arms = null,
    /// A monitor (0x4bcf70, +0xcc 0x4bcff0): a hit only deals damage — no side bonus,
    /// last attacker, reaction or blood; the AI weighs it by its profile's `monitor`.
    monitor: bool = false,
    /// Its kill counts: exp bonus and the report line (+0xd8: 0x48e7f0; heroes, monitors
    /// and ally Lamar 0x492420 = 0).
    kill_credit: bool = true,
    /// Strikes twice into one tile, with weapon pairs by classic_id by its counter (Schizo
    /// 0x4e0d70: +0x24af4); without all of them, twice with the planned weapon.
    pairs: []const [2]i32 = &.{},
    /// An OpenGorky project's: each pair's two weapons by path ("" a number's place), in
    /// pairs' order flat (`pairs = list(list(~w"weapons::schizo1", ~w"weapons::schizo2"))`).
    pairs_class: []const []const u8 = &.{},
    double_strike: bool = false,
    /// Heals the live fighter of this object name by the damage it deals (the Judge's
    /// child 0x4dd010).
    heals: []const u8 = "",
    /// Its death makes its last attacker the target (+0x24af8) of the fighter of this
    /// object name (Grandma's child 0x4e08d0).
    avenger: []const u8 = "",
    /// Starts the battle unseen and is never hovered (the Invisible 0x48e890).
    invisible: bool = false,
    /// Leaves the grid at the end of each enemy round and is gone at the next enemy turn
    /// start, not a death (the Invisible that bites McFadden, 0x4985fb → 0x49839f).
    leaves: bool = false,
    /// Pushes nothing (Medusa: the push button 0x4b1907).
    no_push: bool = false,
    /// No hands: gives and takes no items (0x42e485, 0x4b23dc, 0x450872), no fist when
    /// unarmed in battle (0x4b299f) (Medusa).
    no_hands: bool = false,
    /// Fights in battles only: never picked outside one, its portrait grey there
    /// (Medusa: 0x481ce0, 0x4b2761, 0x4b1df1).
    battle_only: bool = false,
    /// Scripted abilities (OpenGorky; `Script`), attached in this order.
    scripts: []const Script = &.{},
};

/// A scripted ability: component `component` (OGS, `for fighter`; a path `abilities::Rage`
/// as code names it) with `params` by name, the rest at their defaults. Rules text:
/// `Rage(below_pct = 30, factor = 2.5)`.
pub const Script = struct {
    component: []const u8,
    params: []const Param = &.{},

    pub const Param = struct { name: []const u8, value: Lit };
    /// A param's literal (a fighter param: its object name, a string).
    pub const Lit = union(enum) { int: i32, float: f32, bool: bool, string: []const u8 };

    pub fn param(s: Script, name: []const u8) ?Lit {
        for (s.params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }
};

/// The ordinary fighter: no abilities (0x48e7f0).
pub const plain: Abilities = .{ .class = 0 };

/// Grid direction a fighter at `angle` faces on a grid turned by `rotation` (its x axis'
/// world angle, core/map.zig toWorld): the nearest quarter turn.
pub fn ahead(angle: f32, rotation: f32) Tile {
    const q: i32 = @intFromFloat(@round((angle - rotation) / (std.math.pi / 2.0)));
    return switch (@mod(q, 4)) {
        0 => .{ 1, 0 },
        1 => .{ 0, 1 },
        2 => .{ -1, 0 },
        else => .{ 0, -1 },
    };
}

/// Tile `rel` (`Rel`) of a fighter on `tile` facing grid direction `fwd` (`ahead`): its
/// right is a quarter turn on from its ahead in the grid's order (the exe's Messiah's
/// right arm on 10,17 facing −x).
pub fn relTile(tile: Tile, fwd: Tile, rel: Rel) Tile {
    const right: Tile = .{ -fwd[1], fwd[0] };
    return .{ tile[0] + right[0] * rel[0] + fwd[0] * rel[1], tile[1] + right[1] * rel[0] + fwd[1] * rel[1] };
}

/// A saw spun on a link point at strike tick `at` + 1: the link's mesh plays `anim` once
/// (0x48d760 → 0x44f910; Headnail's "obrot").
pub const Spin = struct { link: []const u8, at: Num, anim: []const u8 = "" };

/// What a strike of a fighter's own (`special`) does in its own code.
pub const Strike = struct {
    pub const call = "FighterStrike";
    pub const file = "fighters";
    pub const keys = .{"special"};
    pub const doc =
        \\A fighter's own strike (MonsterAttack `strike`) in its own code: saws spun on its
        \\model's link points at a strike tick (Headnail 0x48d760).
    ;
    special: i32 = 0,
    /// The fighter by archetype (an OpenGorky row's `special = ~c"characters::headnail"`).
    special_class: []const u8 = "",
    spins: []const Spin = &.{},
};

/// How a fighter's AI weighs its strikes and its place (the "AI" core module: a tile
/// scoring, method +0xe0 by classType, table 0x4bcbb0; rules AiProfile `scoring` picks it).
/// combat/ai.zig runs the pieces it names; a new scoring combines them.
/// shortcut: the pieces are the exe's code, a project's own scoring function (a hook)
/// comes when a project needs one.
pub const Scoring = struct {
    pub const call = "AiScoring";
    pub const file = "ai";
    pub const keys = .{"eval"};
    pub const doc =
        \\The AI's tile scoring by AiProfile `scoring` (method +0xe0 by classType, table 0x4bcbb0):
        \\  keep: the weapons it plans with (all, by_health, first, free_arms); occupant: a fighter's
        \\  worth on a hit tile (generic, a, no_lock, avenge, sleep_hunter, heroes_only, foes,
        \\  none); tile: occupants or whole (the tile whole); wakeful: plans asleep; near: stays
        \\  within 3 tiles of this fighter (object name); script: a component (rules code, for
        \\  Enemy) whose ScoreTile scores the hit tiles.
    ;
    eval: AiEval,
    keep: Keep = .all,
    occupant: Occupant,
    /// A strike's hit tiles scored whole in place of their occupants (Incubus 0x4e2b50).
    tile: enum { occupants, whole } = .occupants,
    /// Tries its weapons without "can strike" too: asleep it sees only a ±π/4 cone of
    /// its gaze, unable to walk it prefers the farthest aim (Smoke Rider 0x4de890); it
    /// gets a turn asleep.
    wakeful: bool = false,
    /// Stays within 3 tiles of the fighter of this object name (Grandma's child 0x4e0602).
    near: []const u8 = "",
    /// A component of the rules' code (`for Enemy`) attached to a fighter of this scoring
    /// in battle (combat/events.zig): its ScoreTile scores the hit tiles (an OpenGorky
    /// project's own scoring; the converter writes the exe's special ones so).
    script: []const u8 = "",
};

/// Weapons it plans with: all; the long one (`secondaryWeapon`) only below half health
/// (Garcia 0x4dfe8d); only the first (Schizo); `free_arms` as all (the Messiah's: the arm a
/// box blocks is his CanUse, native Arms, which the AI asks of every fighter). Always the
/// ones the fighter's CanUse allows.
const Keep = enum { all, by_health, first, free_arms };

/// A fighter's worth on a hit tile: `generic` the ordinary monster's (0x499170: +5 to
/// damage, a monitor ×2, an ally −10×, the profile's constants); `a` "scoring A"
/// (0x4dcb40); `no_lock` scoring A without the AITargetLock ×100 (Cripple); `avenge`
/// only its target (Grandma); `sleep_hunter` sleeping heroes for melee, awake for the sleep
/// shot (the Guard, 0x4e2260); `heroes_only` +10 a hero, −100 others (Schizo); `foes`
/// damage·pct/100 opponents only (Messiah); `none` 0.
const Occupant = enum { generic, a, no_lock, avenge, sleep_hunter, heroes_only, foes, none };
