//! The battle's own records (core/modules.zig `Tables`): its scripted events (a fighter's
//! transformation, dialogs after an enemy turn), the devices it places (bombs, decoy, the
//! bomb's blast) and the fighter states' turns and damage. The engine knows the parts,
//! not the game: the original's rows are the Classic reader's (core/classic.zig, the
//! exe's hard-coded ones by levelMode), an OpenGorky project's `rules\battle.ss` rows
//! over them (composition: loaders/rules_text.zig).

const Effect = @import("../rules.zig").Effect;

/// On a battle level of levelMode `mode`: the first hero strike on a non-hero arms
/// `delay` ticks, then fighter `who` (object name) loses moveLock and attackLock, turns
/// into `into` (its .mtm; animation `anim`, then idle `idle`) with `sound`, and
/// `dialog_delay` ticks later dialog `dialog` (scene, file `dialog_file`) starts.
pub const Transform = struct {
    pub const call = "Transform";
    pub const file = "battle";
    pub const keys = .{"mode"};
    pub const doc =
        \\A fighter's transformation in a battle of levelMode `mode`: the first hero strike
        \\on a non-hero arms `delay` ticks, then `who` (object name) is freed and turns into
        \\`into` (Classic its .mtm; OpenGorky its block, ~c"x"; model `anim`, "" the block's
        \\`mesh`; idle `idle`) with `sound`; `dialog_delay` ticks
        \\later dialog `dialog` (scene; its file `dialog_file`; OpenGorky: `dialog = ~d"x"`, the
        \\dialog block, no file) starts ("": none).
    ;
    mode: i32,
    who: []const u8,
    into: []const u8,
    anim: []const u8 = "",
    idle: []const u8,
    sound: []const u8 = "",
    delay: i32,
    dialog: []const u8 = "",
    dialog_file: []const u8 = "",
    dialog_delay: i32 = 0,
};

/// On a battle level of levelMode `mode`, after enemy turn `turn`: dialog `dialog`
/// (scene, file `dialog_file`).
pub const MidDialog = struct {
    pub const call = "MidDialog";
    pub const file = "battle";
    pub const keys = .{ "mode", "turn" };
    pub const doc =
        \\A dialog in a battle of levelMode `mode` after enemy turn `turn` (`turn`): scene
        \\`dialog`, its file `dialog_file`.
    ;
    mode: i32,
    turn: i32,
    dialog: []const u8,
    dialog_file: []const u8 = "",
};

/// What the battle places itself.
pub const DeviceKind = enum { time_bomb, large_bomb, decoy, blast };

/// A device the battle places: object `<prefix><N>` of script `archetype`; a bomb's clock
/// `timer` enemy turns.
pub const Device = struct {
    pub const call = "Device";
    pub const file = "battle";
    pub const keys = .{"kind"};
    pub const doc =
        \\A device the battle places: time_bomb (a hero's bomb), large_bomb (PutLargeTimeBomb),
        \\decoy, blast (the bomb's blast weapon): object <prefix><N> of script `archetype`;
        \\a bomb explodes after `timer` enemy turns.
    ;
    kind: DeviceKind,
    archetype: []const u8,
    prefix: []const u8,
    timer: i32 = 0,
};

/// A fighter state (0x4900f0): it lasts `turns` (one more applied in the enemy turn);
/// at a fighter's turn start with `left` turns left it deals `damage[turns - left]`
/// (none past the list); a state without turns (bite: for the battle) `damage[0]`.
pub const StateEffect = struct {
    pub const call = "StateEffect";
    pub const file = "battle";
    pub const keys = .{"effect"};
    pub const doc =
        \\A fighter state (0x4900f0): how many turns it lasts (one more applied in the enemy
        \\turn) and the damage at each turn start by the turns gone, list(first, second, …);
        \\a state without turns (bite) deals the first every turn.
    ;
    effect: Effect,
    turns: i32 = 0,
    damage: []const i32 = &.{},

    /// The damage at a turn start with `left` turns left (0: none).
    pub fn damageAt(s: StateEffect, left: i32) i32 {
        const i = if (s.turns == 0) 0 else s.turns - left;
        return if (i >= 0 and i < s.damage.len) s.damage[@intCast(i)] else 0;
    }
};
