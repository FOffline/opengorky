//! Built-in rules: ai.ss (combat/ai.zig): the tile scoring by fighter classType (table
//! 0x4bcbb0) with the constants the exe's scoring code holds.

const rows = @import("rows.zig");
const P = rows.AiProfile;

/// "Scoring A" (0x4dcb40) and the special scorings built on it: no +5 to the damage,
/// no x2 for monitors, no decoys.
fn special(class: i32, eval: rows.AiEval, note: []const u8) P {
    return .{ .class = class, .scoring = eval, .damage_bonus = 0, .ally_penalty = 10, .lock = 100, .monitor = 1, .decoy_pull = 2000, .decoys = false, .step_away = true, .threat = true, .note = note };
}

pub const profiles = [_]P{
    // An ordinary monster (0x499170): (max_damage + 5) x pct / 100, a monitor x2, an
    // ally -10x, attracted by decoys (-2000 x aicPlayerDist x path, 0x499620).
    .{ .class = 0, .scoring = "generic", .damage_bonus = 5, .ally_penalty = 10, .lock = 100, .monitor = 2, .decoy_pull = 2000, .decoys = true, .step_away = true, .threat = true, .note = "every other class: an ordinary monster (0x499170)" },
    special(1, "garcia", "Garcia: the long weapon (secondaryWeapon) only below half health (0x4dfe8d)"),
    special(6, "smokerider", "Smoke Rider: tries its weapons even asleep, in a pi/4 cone (0x4de890)"),
    special(7, "grandma", "Grandma: only her child's killer"),
    special(8, "grandma_child", "Grandma's child: stays within 3 of her (0x4e0602)"),
    blk: {
        // A generic fighter of ai = focused takes it (battle/generic.zig aiProfile).
        var s = special(9, "a", "Stinger: scoring A (0x4dcb40)");
        s.generic_ai = "focused";
        break :blk s;
    },
    special(10, "a", "Fatman"),
    special(11, "incubus", "Incubus (0x4e2b50)"),
    special(12, "cripple", "Cripple: no AITargetLock bonus"),
    special(13, "a", "Puppet"),
    blk: {
        var g = special(14, "guard", "Guard (0x4e2260): melee on sleepers, the sleep shot on the awake; no threat, stays after a strike");
        g.threat = false;
        g.step_away = false;
        g.generic_ai = "sleep_hunter";
        break :blk g;
    },
    special(15, "a", "Judge"),
    special(16, "a", "Judge's child"),
    special(17, "schizo", "Schizo: the first weapon only"),
    special(18, "messiah", "Messiah: not the hand a box blocks"),
};
