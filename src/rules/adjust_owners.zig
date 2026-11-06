//! Where an OpenGorky project writes each engine setting (rules/adjust_defaults.zig): a
//! field of a record in the interface (`PopupColors(hp_loss = [247, 83, 16]);` in ui.ogs)
//! or of a record field of the game block (`blood = Blood(count = 15);`). The rules
//! loader makes them the setting's value (loaders/rules_text.zig ownedRows), the
//! converter writes a value that differs from the engine's there. No `settings` block:
//! each value lives with what it tunes. The player's own choices (frame rate, shadows,
//! the dialogue sound) are no project's: not here.

const std = @import("std");

const Owner = enum {
    /// A row of ui.ogs (`PopupColors(…)`).
    ui,
    /// The game block's field `slot` (`blood = Blood(…)`).
    game,
};

pub const Field = struct {
    owner: Owner,
    /// The record (`PopupColors`, `Blood`).
    record: []const u8,
    /// The game block's field holding it ("" for a ui row).
    slot: []const u8 = "",
    field: []const u8,
    /// The engine's setting.
    name: []const u8,
};

fn ui(record: []const u8, fields: []const [2][]const u8) []const Field {
    var out: [fields.len]Field = undefined;
    for (fields, &out) |f, *o| o.* = .{ .owner = .ui, .record = record, .field = f[0], .name = f[1] };
    const r = out;
    return &r;
}

fn game(slot: []const u8, record: []const u8, fields: []const [2][]const u8) []const Field {
    var out: [fields.len]Field = undefined;
    for (fields, &out) |f, *o| o.* = .{ .owner = .game, .record = record, .slot = slot, .field = f[0], .name = f[1] };
    const r = out;
    return &r;
}

pub const table: []const Field = ui("PopupColors", &.{
    .{ "exp_gain", "cfcExpGain" },         .{ "skill_gain", "cfcSkillGain" },    .{ "miss", "cfcMiss" },       .{ "critical", "cfcCriticalhit" },
    .{ "protection", "cfcProt" },          .{ "hp_loss", "cfcHpLoss" },          .{ "hp_gain", "cfcHpGain" },  .{ "level_gain", "cfcLevelGain" },
    .{ "no_ammo", "cfcNoammo" },           .{ "out_of_range", "cfcOutofrange" }, .{ "counter", "cfcCounter" }, .{ "player_turn", "cfcPlayerTurn" },
    .{ "monster_turn", "cfcMonsterTurn" },
}) ++ ui("PopupText", &.{
    .{ "height", "teff_height" }, .{ "step1", "teff_m1_step" }, .{ "step2", "teff_m2_step" }, .{ "hold2", "teff_m2_timelen" }, .{ "step3", "teff_m3_step" },
}) ++ ui("BattleColors", &.{
    .{ "ai_attack", "cftAiAttackRange" },         .{ "ai_walk", "cftAiWalkRange" },                 .{ "attack", "cftAttackRange" },      .{ "effect", "cftEffectRange" },
    .{ "enemy_walk", "cftEnemyWalkRange" },       .{ "fighter_area", "cftFighterArea" },            .{ "free_tile", "cftFreeTileFrame" }, .{ "player_walk", "cftPlayerWalkRange" },
    .{ "selected_tile", "cftSelectedTileFX" },    .{ "tile_cross", "cftTilePGCross" },              .{ "victory", "cftVictory" },         .{ "game_over", "cftGameOver" },
    .{ "game_over_choose", "cftGameOverChoose" }, .{ "game_over_selected", "cftGameOverSelected" },
}) ++ ui("BattleGrid", &.{
    .{ "color", "grid_color" }, .{ "mode", "grid_mode" }, .{ "width", "grid_width" }, .{ "flash_speed", "tile_flash_speed" }, .{ "flash_min", "tile_flash_min" }, .{ "flash_max", "tile_flash_max" },
}) ++ ui("MenuLight", &.{
    .{ "color", "menu_light_color" },     .{ "flare_width", "menu_flare_width" },         .{ "flare_height", "menu_flare_height" },     .{ "flare_intensity", "menu_flare_intensity" },
    .{ "lens_size", "menu_lens_size" },   .{ "lens_dist", "menu_lens_dist" },             .{ "lens_intensity", "menu_lens_intensity" }, .{ "lens2_size", "menu_lens2_size" },
    .{ "lens2_dist", "menu_lens2_dist" }, .{ "lens2_intensity", "menu_lens2_intensity" }, .{ "fade_size", "menu_fade_size" },           .{ "fade_intensity", "menu_fade_intensity" },
}) ++ ui("CreditsColors", &.{
    .{ "normal", "cftCreditsNormal" }, .{ "title", "cftCreditsTitle" },
}) ++ ui("SafeLock", &.{
    .{ "start_x", "safe_key_start_x" }, .{ "start_y", "safe_key_start_y" }, .{ "key_width", "safe_key_width" }, .{ "key_height", "safe_key_height" },
}) ++ ui("Cinema", &.{
    .{ "bar_height", "gui_panorama_height" },
}) ++ game("sound", "Sound", &.{
    .{ "volume_start", "sound_volume_start" }, .{ "volume_falloff", "sound_volume_falloff" }, .{ "pan_start", "sound_pan_start" }, .{ "pan_factor", "sound_pan_factor" },
}) ++ game("motion", "Motion", &.{
    .{ "fighter_fade_speed", "fighter_fade_speed" }, .{ "actor_fade_delay", "actor_fade_delay" }, .{ "zoom_speed", "zoom_speed" }, .{ "gravity", "gravity" }, .{ "stunned_level", "fighter_stunned_level" },
}) ++ game("blood", "Blood", &.{
    .{ "count", "blood_particle_count" },              .{ "size", "blood_particle_size" },                 .{ "speed", "blood_speed" },             .{ "speed_delta", "blood_speed_delta" },
    .{ "vspeed", "blood_vspeed" },                     .{ "vspeed_delta", "blood_vspeed_delta" },          .{ "start_level", "blood_start_level" }, .{ "flash_level", "attack_redlight_flash_level" },
    .{ "flash_range", "attack_redlight_flash_range" }, .{ "flash_time", "attack_redlight_flash_timeout" },
}) ++ game("sparks", "Sparks", &.{
    .{ "count", "flare_particle_count" }, .{ "size", "flare_particle_size" },        .{ "speed", "flare_speed" },                    .{ "speed_delta", "flare_speed_delta" },
    .{ "vspeed", "flare_vspeed" },        .{ "vspeed_delta", "flare_vspeed_delta" }, .{ "fade_speed", "flare_particle_fade_speed" },
}) ++ game("particles", "Particles", &.{
    .{ "blend_start", "particle_blend_start" }, .{ "rest_time", "particle_rest_time" },
}) ++ game("explosion", "Explosion", &.{
    .{ "speed", "explosion_speed" }, .{ "scale", "explosion_scale" }, .{ "rise", "attack_grenade_exp" },
}) ++ game("fire", "Fire", &.{
    .{ "intensity", "fighter_fire_intensity" },
}) ++ game("morph", "Morph", &.{
    .{ "add", "morf_add" },     .{ "delay", "morf_delay" }, .{ "dr", "morf_dr" },   .{ "gr", "morf_gr" },       .{ "life", "morf_life" },
    .{ "life2", "morf_life2" }, .{ "sint", "morf_sint" },   .{ "alpha", "morf_a" }, .{ "scale", "morf_scale" }, .{ "scale_z", "morf_scale_z" },
}) ++ game("shot_flash", "ShotFlash", &.{
    .{ "range", "flash_range" }, .{ "min", "flash_min" }, .{ "speed", "flash_speed" },
}) ++ game("shock", "Shock", &.{
    .{ "light_range", "attack_shocker_light_range" }, .{ "light_level", "attack_shocker_light_level" }, .{ "time", "attack_shocker_shocked_timeout" },
}) ++ game("flame", "Flame", &.{
    .{ "add", "attack_flame_add" }, .{ "color", "attack_flame_col" }, .{ "color_new", "attack_flame_col2" }, .{ "range", "attack_flame_range" }, .{ "scale", "attack_flame_scale" },
}) ++ game("rocket_trail", "RocketTrail", &.{
    .{ "length", "rocket1_trail_len" },       .{ "period", "rocket1_trail_update_speed" }, .{ "size", "rocket1_trail_size" }, .{ "size_fade", "rocket1_trail_size_fade" },
    .{ "fade", "rocket1_trail_fade_factor" }, .{ "spread", "rocket1_trail_disp_factor" },  .{ "back", "rocket1_trail_disp" },
}) ++ game("ball", "Ball", &.{
    .{ "countdown", "attack_ball_exp" }, .{ "scale", "attack_ball_ms" },
}) ++ game("grenade", "Grenade", &.{
    .{ "angle", "attack_grenade_angle" },
});

/// The player's own choices: read by the engine, set by no project.
const players = [_][]const u8{ "disable_shadows", "dialog_sound_control" };

/// Record `record`'s field `field`.
pub fn of(record: []const u8, field: []const u8) ?*const Field {
    for (table) |*f| if (std.mem.eql(u8, f.record, record) and std.mem.eql(u8, f.field, field)) return f;
    return null;
}

/// Setting `name`'s place.
pub fn byName(name: []const u8) ?*const Field {
    for (table) |*f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// The effect records a weapon block may hold too (its own values for the effects it
/// makes: `flame = Flame(…)`); rules.weaponFloat reads them.
const weapon_records = [_][]const u8{ "Flame", "RocketTrail", "Ball", "Grenade", "Shock" };

pub fn isWeaponRecord(record: []const u8) bool {
    for (weapon_records) |r| if (std.mem.eql(u8, r, record)) return true;
    return false;
}

/// Record `record` is one of the table's (of `owner`).
pub fn isRecord(owner: Owner, record: []const u8) bool {
    for (table) |f| if (f.owner == owner and std.mem.eql(u8, f.record, record)) return true;
    return false;
}

test "every engine setting has one place, or is the player's" {
    for (@import("adjust_defaults.zig").table) |d| {
        var n: usize = 0;
        for (table) |f| n += @intFromBool(std.mem.eql(u8, f.name, d[0]));
        const player = for (players) |p| {
            if (std.mem.eql(u8, p, d[0])) break true;
        } else false;
        if (n != @intFromBool(!player)) {
            std.debug.print("setting {s}: {d} places\n", .{ d[0], n });
            return error.TestUnexpectedResult;
        }
    }
    for (table) |f| if (@import("adjust.zig").defaultOf(f.name) == null) {
        std.debug.print("place {s}.{s}: no setting {s}\n", .{ f.record, f.field, f.name });
        return error.TestUnexpectedResult;
    };
}
