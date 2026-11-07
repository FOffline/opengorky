//! World sub-state groups: game resources, level-transition flow, open interactions,
//! debug state, plus load steps and walk-area records.

const std = @import("std");
const rules = @import("../rules.zig");
const Allocator = std.mem.Allocator;
const model_cache = @import("../actor.zig").model_cache;
const Object = @import("../script.zig").object.Object;
const Value = @import("../script.zig").value.Value;

/// Fighter shadow record (0x42af20: name, x, y, z, angle, floor +0x3190).
pub const Shadow = struct { name: []const u8, pos: [3]f32, angle: f32, map: u1 };

/// What happens when the hero arrives: operate (left click: an item's or area's operation),
/// examine menu (right click), LevelSwitch (exit).
const InteractMode = enum { operate, examine, level_switch };

pub const LoadStep = struct {
    kind: enum { level_load, place_heroes, place_actor, fade_in, disable_heroes },
    args: []Value,
};

pub const WalkArea = struct { name: []const u8, allow: bool, floor: i32 };

/// Game resources the world reads: its source, models, frame counts, foreign script sources.
pub const Res = struct {
    /// Where its scripts, variables and frame counts come from (composition: loaders/world.zig).
    source: @import("../core.zig").source.Source = .{},
    /// Frame count by sprite name (lowercase).
    frame_counts: std.StringHashMapUnmanaged(u32) = .empty,
    /// Actor models (animation lengths, root motion); optional.
    models: ?*model_cache.Cache = null,
    /// Where its scenes and dialogs come from (composition: loaders/world.zig).
    scenes: @import("../core.zig").scene.Source = .{},
    /// Script sources brought from other locations (heroes' item classes).
    extra_sources: std.StringHashMapUnmanaged([]const u8) = .empty,
};

/// Level-transition requests and LEVEL_Load replay; executed by the host (game.zig).
pub const Flow = struct {
    /// Scene PREVLEVEL: return to the previous location.
    want_prev_level: bool = false,
    /// The ending scene reached GUI_CREDITS / GUI_MENU: go to the menu.
    game_over: bool = false,
    /// GUI_GAMEOVER (0x45b3b0 → 0x454350, the battle defeat's screen): ticks since; at 90
    /// the "gameover" music and the "Repeat Battle" choice.
    defeat_ticks: ?u32 = null,
    /// Requested location change (LEVEL_Load).
    pending_level: ?[]const u8 = null,
    /// LEVEL_LoadAB: after switching, call AfterBattle(this location) on the new one.
    load_ab: bool = false,
    /// Calls made after LEVEL_Load in the same script. The exe switches synchronously
    /// (0x41f090), so they act on the new location (PlaceHeroes, PlaceActor, another
    /// LEVEL_Load); replayed there by `runLoadSteps`.
    load_steps: std.ArrayList(LoadStep) = .empty,
    /// Script call (`Runtime.top_call`) that issued LEVEL_Load.
    load_call: u64 = 0,
    /// Inside `runLoadSteps`: steps continue the same script call.
    replaying: bool = false,
};

/// Open interactions: walk-to-use, examine menu, box, safe keypad.
pub const Act = struct {
    /// Open safe keypad (GUI_SafeBox): the area that receives CheckCode.
    safe_box: ?*Object = null,
    /// Hero walking to an active area to use it (LevelSwitch etc.).
    interaction: ?struct { hero: *Object, area: *Object, use: ?*Object = null, action: u8 = 0, mode: InteractMode = .operate } = null,
    /// Open examine menu: object and the hero who reached it; `refused`: its `use_item_N`
    /// (bit N) its Accepts said no to as it opened (OpenGorky, world/actions.zig).
    examining: ?struct { obj: *Object, hero: *Object, refused: u16 = 0 } = null,
    /// Open box window (Explore).
    exploring: ?struct { box: *Object, hero: *Object } = null,
    /// Open the box window after `ticks` (0x45b04f: after an action that set action 7 with
    /// cnt_itm > 0; from the examine menu after 60 + 30 ticks).
    pending_explore: ?struct { box: *Object, hero: *Object, ticks: u32 } = null,
    /// The hero carrying out an action the player started (Open, Take, Use…): the player's
    /// clicks wait until its animations end and the windows it opened close
    /// (world/actions.zig `locked`).
    acting: ?*Object = null,
};

/// Console/debug state.
pub const Debug = struct {
    /// Objects scripts referenced but the location lacks (heroes, fighters, sounds), with counts.
    missing_objects: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Console `godmode`: heroes take no damage.
    god: bool = false,
    /// Name counter for console-spawned items.
    items: u32 = 0,
};

/// Action function name for `action`: string.tab 1–18 without spaces.
pub fn operationName(id: i32) ?[]const u8 {
    return if (rules.action(id)) |a| a.name else null;
}

pub fn freeLoadSteps(gpa: Allocator, steps: []const LoadStep) void {
    for (steps) |st| {
        for (st.args) |a| if (a == .string) gpa.free(a.string);
        gpa.free(st.args);
    }
}
