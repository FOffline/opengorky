//! A fighter in battle: side, tile, states (sleep, gas, fire, freeze, rage,
//! Invisible's poison), kill count.

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const Object = @import("../script.zig").object.Object;
const grid = @import("grid.zig");
const Tile = grid.Tile;

/// Fighter class (`classType`, factory 0x4bc6c0): a key of the rules rows (Abilities,
/// AiProfile); the exe's by name are a Classic piece (rules/fighter_classes.zig), an
/// OpenGorky project's its own names (rules.fighterClassId). The core knows one: `generic`,
/// the port's fighter whose attacks, AI and resistances come from its fields (battle/generic.zig).
pub const Class = enum(i32) {
    generic = 100,
    _,

    pub fn of(o: *Object) Class {
        return @fromBackingInt(@intCast(o.getInt("battle_class")));
    }
};

/// Battle sides; `neutral` are obstacles (`.obs`, `.obs_i`): they occupy tiles and
/// block shots, never move and don't count for victory (0x48e7f0). OpenGorky: `civilian`, a
/// fighter of neither side (BattleSpawnCivilian): both sides' opponent, acting by AI on the
/// enemies' turn, not counted for victory or defeat.
pub const Side = enum { hero, enemy, neutral, civilian };

pub const Fighter = struct {
    obj: *Object,
    side: Side,
    tile: Tile,
    /// Square side in tiles (`charSize` 4 → 2×2, 9 → 3×3; 0x48eb70).
    size: u32,
    /// Barrel obstacle (`explosive`): explodes from fire, bullets, energy, blasts.
    explosive: bool = false,
    /// Pushable obstacle (`movable`, 0x47bb60).
    movable: bool = false,
    /// Last attacker (+0x24aec): barrel blasts are on its behalf; the killer of
    /// Grandma's child becomes her target.
    last_attacker: ?u16 = null,
    /// Grandma's target (+0x24af8): the killer of her child; OpenGorky: any fighter's by a
    /// script's FighterSetTarget (combat/ai.zig weighs it as AITargetLock's).
    grandma_target: ?u16 = null,
    /// Second activation this turn (+0x24908: Incubus and Cripple act twice).
    second: bool = false,
    /// Weapon pair counter (Schizo +0x24af4; core module Fighters `pairs`).
    pair_turn: u8 = 0,
    /// Walked this turn (0x2460c); turn budget is `walk_range − used`.
    used: f32 = 0,
    acted: bool = false,
    dead: bool = false,
    /// Rage (+0x248fc), an action counter: while > 0, accuracy ½ (0x4cede9) and
    /// damage ×2 (0x4cf0d7). Each action and the heroes' turn end take 1 (0x48f790);
    /// accumulated rage gives 1 (0x491434), Drugs 2 (0x48ffcc).
    berserk: i32 = 0,
    /// Selected weapon (`.wpn` object).
    weapon: ?*Object = null,
    /// Where to walk in on appearance (AIEnemyAppear) while not on the grid.
    appear_to: ?Tile = null,
    /// Counter-attack rolled (+0x24900).
    counter: bool = false,
    /// States (0x4900f0), in turns: burning (+0x248dc), frozen (+0x248e0), gassed
    /// (+0x248e4), soaked with fuel (+0x248ec), asleep (+0x248f4).
    burning: i32 = 0,
    frozen: i32 = 0,
    gassed: i32 = 0,
    soaked: i32 = 0,
    asleep: i32 = 0,
    /// Invisible's bite (effect 8, +0x248e8): weapon WeaponInvisibleSpecialMFD
    /// (class 125, +0xdc 0x4d1f20 → 0x4900f0(8), no resistance check). 20 damage at
    /// every turn start until the battle ends; never decreases (0x490477), can't be
    /// cured (medicine 0x48ff50 only removes gas), reset only with the fighter
    /// (0x48e695, 0x48f6a5). Popup string.tab 528 "poisoned" (0x4dc92a).
    bitten: bool = false,
    /// A scripted ability's CanWalk said false at this turn's start (OpenGorky,
    /// combat/events.zig turnStart).
    stuck: bool = false,
    /// A scripted WalkRange's answer at this turn's start (OpenGorky, combat/events.zig
    /// turnStart); null: its `walk_range`.
    walk_range: ?i32 = null,
    /// Defending (+0x248f0, 0x48f7e0): damage ×0.5 until its next turn.
    defending: bool = false,
    /// Attracted by a decoy (+0x24904): set at the side's turn start; while a decoy
    /// is on the field it doesn't strike and walks to it (0x499188, 0x499620, 0x499c2f).
    attracted: bool = true,
    /// Exp for the current strike (+0x245d4).
    pending_exp: i32 = 0,
    /// For the after-battle report (0x451d70): exp this battle (+0x2490c) and kills
    /// by kind (+0x24910: monster classic_id and count).
    exp_gained: i32 = 0,
    /// By kind: classic_id and (OpenGorky) class (rules.Who: the report's KillIcon by class).
    kills: [10]struct { id: i32, class: []const u8 = "", n: i32 } = undefined,
    kills_n: u8 = 0,

    pub fn addKill(self: *Fighter, who: @import("../rules.zig").Who) void {
        for (self.kills[0..self.kills_n]) |*k| if (k.id == who.id and std.ascii.eqlIgnoreCase(k.class, who.class)) {
            k.n += 1;
            return;
        };
        if (self.kills_n == self.kills.len) return;
        self.kills[self.kills_n] = .{ .id = who.id, .class = who.class, .n = 1 };
        self.kills_n += 1;
    }

    pub fn enraged(self: Fighter) bool {
        return self.berserk > 0;
    }

    /// End of an action (0x48f790): rage −1.
    pub fn spendRage(self: *Fighter) void {
        if (self.berserk > 0) self.berserk -= 1;
    }

    /// Can't walk or strike (0x48f960, 0x48f990): frozen or asleep.
    pub fn disabled(self: Fighter) bool {
        return self.frozen > 0 or self.asleep > 0;
    }

    pub fn alive(self: Fighter) bool {
        return !self.dead;
    }

    /// A hero the player controls: not an extra with `avoidEnumerate` (the singer
    /// on the barge), who can't be selected (0x45acb0) but fights on the hero side.
    pub fn controllable(self: Fighter) bool {
        return self.side == .hero and self.obj.getInt("outside_party") == 0;
    }

    /// Acts on side `s`'s turn: its own; a civilian with the enemies (combat/ai_turn.zig).
    pub fn actsOn(self: Fighter, s: Side) bool {
        return self.side == s or (s == .enemy and self.side == .civilian);
    }

    pub fn hp(self: Fighter) i32 {
        return fields.hp(self.obj);
    }

    /// May walk this turn (0x48f960): no `moveLock`, not Immobile (a native, core/natives.zig),
    /// not `stuck` (a scripted CanWalk), not asleep or frozen.
    pub fn canWalk(self: Fighter) bool {
        return !fields.moveLock(self.obj) and !self.obj.implementsC("Immobile") and !self.stuck and !self.disabled();
    }

    /// Its walk range this turn: a scripted WalkRange's, else `walk_range`.
    pub fn walkRange(self: Fighter) i32 {
        return self.walk_range orelse fields.walkRange(self.obj);
    }

    pub fn budget(self: Fighter) f32 {
        // A hero's walk bonus (HealBonus walk; OpenGorky, 0 in the exe's rules).
        const more = if (self.side == .hero) @import("../core.zig").entity.heroOf(@import("../rules.zig").who(self.obj)).walk_bonus else 0;
        return num.toF32(self.walkRange() + more) - self.used;
    }
};
