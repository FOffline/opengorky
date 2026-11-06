//! Entry point of `combat/` for other engine folders. Combat turn logic on top of the battle model and the world.
//! Files not exported here are internal to the folder.

pub const ai = @import("combat/ai.zig");
pub const ai_turn = @import("combat/ai_turn.zig");
pub const anim = @import("combat/anim.zig");
pub const control = @import("combat/control.zig");
pub const debug = @import("combat/debug.zig");
pub const devices = @import("combat/devices.zig");
/// A fighter's events in battle (scripted abilities) and the battle's variables.
pub const events = @import("combat/events.zig");
/// The engine's code of the native abilities (core/natives.zig).
pub const natives = @import("combat/natives.zig");
/// FighterDamage's damage (combat/strike.zig: the battle's damage).
pub const scriptDamage = @import("combat/strike.zig").scriptDamage;
/// Whether killing the fighter gives the kill bonus (Enemy.reward()).
pub const killCredit = @import("combat/strike.zig").killCredit;
/// A strike's hits (combat/strike.zig: the tests drive the battle's points through it).
pub const resolveAttack = @import("combat/strike.zig").resolveAttack;
pub const roster = @import("combat/roster.zig");
pub const states = @import("combat/states.zig");
pub const tick = @import("combat/tick.zig");
pub const turns = @import("combat/turns.zig");
pub const weapons = @import("combat/weapons.zig");

test {
    _ = anim;
    _ = @import("combat/strike.zig");
    _ = @import("combat/bombs.zig");
    _ = tick;
    _ = turns;
    _ = roster;
    _ = events;
    _ = weapons;
    _ = ai;
}
