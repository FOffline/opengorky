//! OpenGorky: a free reimplementation of the Gorky 17 (Odium) engine.
//! Module `og`: one export per subsystem, through its folder entry file.

pub const formats = @import("formats.zig");
/// The shared base picture (RGBA image), used by parsers, render and clients.
pub const image = @import("image.zig");
pub const script = @import("script.zig");
/// Script builtins with their signatures (the Classic importer, the editor's help).
pub const builtins = @import("builtins.zig");
pub const fields = @import("fields.zig");
pub const num = @import("num.zig");
pub const vec = @import("vec.zig");
pub const effects = @import("effects.zig");
pub const popup = @import("popup.zig");
pub const outbox = @import("outbox.zig");
pub const actor = @import("actor.zig");
pub const render = @import("render.zig");
pub const audio = @import("audio.zig");
pub const battle = @import("battle.zig");
pub const state = @import("state.zig");
pub const inventory = @import("inventory.zig");
pub const world = @import("world.zig");
pub const scene = @import("scene.zig");
pub const combat = @import("combat.zig");
pub const fx = @import("fx.zig");
pub const save = @import("save.zig");
pub const modcheck = @import("modcheck.zig");
pub const game = @import("game.zig");
/// The exe-internal tables (attacks, resistances, …) as one seam; OpenGorky projects load them.
pub const rules = @import("rules.zig");
/// The world model's entities and behaviour modules (no file access).
pub const core = @import("core.zig");
/// What reads a game into the core, one loader per kind (OG Script, the original's files).
pub const loaders = @import("loaders.zig");
/// The packer over the loaders: the converter, the OG writer and build, models, saves.
pub const compose = @import("compose.zig");
/// Headless runs over game.tick (they use game.zig, so they are not part of it).
pub const scene_check = @import("game/scene_check.zig");
pub const logic_trace = @import("game/logic_trace.zig");
pub const console = @import("console.zig");
/// The input layer: GUI modes that pick the core command a click issues (over the core).
pub const input = @import("input.zig");

test {
    _ = formats;
    _ = image;
    _ = script;
    _ = fields;
    _ = effects;
    _ = fx;
    _ = popup;
    _ = actor;
    _ = render;
    _ = @import("actor/motion.zig");
    _ = @import("crt_rand.zig");
    _ = audio;
    _ = battle;
    _ = state;
    _ = inventory;
    _ = world;
    _ = scene;
    _ = combat;
    _ = @import("builtins.zig");
    _ = save;
    _ = game;
    _ = console;
    _ = input;
    _ = rules;
    _ = core;
    _ = loaders;
    _ = compose;
    _ = modcheck;
    _ = logic_trace;
    _ = @import("tests/combat.zig");
    _ = @import("tests/game.zig");
    _ = @import("tests/script.zig");
    _ = @import("tests/world.zig");
}
