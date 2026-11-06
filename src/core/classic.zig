//! The original's fighters as data: what the exe decides in code by a fighter's classType
//! (its virtual methods, factory 0x4bc6c0), classic_id or object name, as the engine's
//! ability rows (core/behaviour.zig `Abilities`), with its AI scorings and own strikes.
//! The engine reads only the rows (core/modules.zig): Classic plays by these exactly,
//! an OpenGorky project starts from them (rules-dump) and changes them in its own rules.
//! Script fields a fighter's file sets that are abilities (the generic fighter's `ai`)
//! are read here too (`fromFields`), nowhere else.
//! The rest of what the exe hard-codes is here too, as the engine's rows: the interface's and shell's (`ui`: core/ui.zig), the battle's scripted
//! events by levelMode, devices and states (core/fight.zig), the strike effects by weapon
//! and fighter (core/effect.zig: `weapon_fx`, `fighter_fx`, `preset`), and the special cases kept as
//! functions (`liftPose`, `blastShown`). No engine code names the game's levels, objects,
//! sounds or numbers (scripts/magiccheck.sh).

const ui_text = @import("ui_text.zig");
const std = @import("std");
const behaviour = @import("behaviour.zig");
const Abilities = behaviour.Abilities;
const Object = @import("../script.zig").object.Object;
const ui_mod = @import("ui.zig");
const fight = @import("fight.zig");
const Who = @import("../rules.zig").Who;

/// The exe's fighters with abilities (battle/fighter.zig Class names the classTypes).
pub const abilities = [_]Abilities{
    .{ .class = 2, .kill_credit = false },
    .{ .class = 3, .kill_credit = false },
    .{ .class = 4, .kill_credit = false },
    .{ .class = 5, .monitor = true, .kill_credit = false },
    .{ .class = 7, .first_in_mode = 2 },
    .{ .class = 8, .avenger = "grandma" },
    .{ .class = 11, .double_turn = true },
    .{ .class = 12, .double_turn = true },
    .{ .class = 13, .stand = -1.57, .stand_after_move = true, .guard = .{ .div = 10, .min = 4, .cone = 0.7125 * std.math.pi } },
    .{ .class = 16, .heals = "01_judge" },
    .{ .class = 17, .pairs = &.{ .{ 1077, 1078 }, .{ 1077, 1079 }, .{ 1078, 1079 } }, .double_strike = true },
    // Messiah (04__elevator_messiah: tile 11,18 facing 3.14; moveLock in ft_messiah.ss):
    // open only from 10,18 (0x4cee33), arms on 10,19 and 10,17 (0x4dfdd4) — the tile in
    // front of him and the two beside it. He never turns but to stand (the exe's classic_id
    // 139 check in 0x48ef10 is his class's `stand`).
    .{ .class = 18, .stand = 3.14, .stand_after_move = true, .open_from = .{ 0, 1 }, .dodge = "unik", .arms = .{ .left = .{ -1, 1 }, .right = .{ 1, 1 }, .blocked = "atakB" } },
    .{ .class = 19, .kill_credit = false },
    // Medusa (classic_id 119, classType 0): fights only in battles (0x481ce0, 0x4b2761,
    // 0x4b1df1), no give/receive or fist (0x42e485, 0x4b23dc, 0x450872, 0x4b299f), no push
    // (0x4b1907).
    .{ .fighter = 119, .class = 0, .no_push = true, .no_hands = true, .battle_only = true },
    // The Invisible (classic_id 120, classType 0): starts unseen, not hovered (0x48e890).
    .{ .fighter = 120, .class = 0, .invisible = true },
    // The one that bites McFadden (04__city_mfd) leaves after the enemy round: the exe
    // looks it up by this name (0x42b140 in 0x4985fb, 0x49839f).
    .{ .fighter_class = "04mf_invisible1", .class = 0, .invisible = true, .leaves = true },
};

/// The exe's scorings, one per AiProfile `scoring` (the first is the generic one).
pub const scorings = [_]behaviour.Scoring{
    .{ .eval = "generic", .occupant = .generic },
    .{ .eval = "a", .occupant = .a },
    .{ .eval = "garcia", .occupant = .a, .keep = .by_health },
    .{ .eval = "smokerider", .occupant = .a, .wakeful = true },
    .{ .eval = "grandma", .occupant = .avenge },
    .{ .eval = "grandma_child", .occupant = .a, .near = "grandma" },
    .{ .eval = "incubus", .occupant = .none, .tile = .whole },
    .{ .eval = "cripple", .occupant = .no_lock },
    .{ .eval = "guard", .occupant = .sleep_hunter },
    .{ .eval = "schizo", .occupant = .heroes_only, .keep = .first },
    .{ .eval = "messiah", .occupant = .foes, .keep = .free_arms },
};

/// Headnail (0x48a72b): the left saw after attack_headnail_delay1 (30), the right 5 later.
pub const strikes = [_]behaviour.Strike{
    .{ .special = 118, .spins = &.{ .{ .link = "pila lewa", .at = .{ .a = headnail_delay1 }, .anim = "obrot" }, .{ .link = "pila prawa", .at = .{ .c = 5, .a = headnail_delay1 }, .anim = "obrot" } } },
};
const headnail_delay1: @import("../rules.zig").rows.Adj = .{ .name = "attack_headnail_delay1", .d = 30 };

/// The generic fighter (classType 100, battle/generic.zig) with `ai = "stationary"`.
const stationary: Abilities = .{ .class = 100, .immobile = true };

/// Abilities fighter `o`'s own script fields give it, when it has no row of its own: the
/// generic fighter's `ai = "stationary"` never walks.
pub fn fromFields(o: *Object) ?*const Abilities {
    if (o.getInt("battle_class") != 100 or !std.ascii.eqlIgnoreCase(o.getString("ai"), "stationary")) return null;
    return &stationary;
}

const P = ui_mod.Place;

/// The interface and shell (core/ui.zig): the exe's panel table 0x52b388, windows
/// 0x4af020…, main menu 0x4134e0, videos 0x40fd06, and what its code names.
pub const ui: ui_mod.Ui = .{
    .panel = .{ .places = &[_]P{
        .{ .button = .inventory, .rect = .{ 4, 21, 35, 61 }, .hint = ui_text.keyName(.hint_inventory), .pressed = .{ .frame = 35, .dx = 4 }, .shutter = .{ 4, 9 } },
        .{ .button = .give, .rect = .{ 40, 21, 73, 61 }, .hint = ui_text.keyName(.give), .pressed = .{ .frame = 36, .dx = 4 }, .shutter = .{ 4, 9 } },
        .{ .button = .hand, .rect = .{ 85, 5, 153, 60 }, .hint = ui_text.keyName(.hint_hand), .shutter = .{ 10, 21 } },
        .{ .button = .short_list, .rect = .{ 155, 6, 175, 60 }, .hint = ui_text.keyName(.hint_short_list), .pressed = .{ .frame = 37, .dx = 1 } },
        .{ .button = .push, .rect = .{ 188, 21, 218, 61 }, .hint = ui_text.keyName(.push), .pressed = .{ .frame = 38, .dx = 4 }, .shutter = .{ 4, 9 } },
        .{ .button = .defend, .rect = .{ 224, 21, 257, 61 }, .hint = ui_text.keyName(.hint_defend), .pressed = .{ .frame = 39, .dx = 4 }, .shutter = .{ 4, 9 } },
        .{ .button = .portrait(0), .rect = .{ 270, 5, 313, 52 }, .shutter = .{ 29, 34 } },
        .{ .button = .portrait(1), .rect = .{ 320, 5, 363, 52 }, .shutter = .{ 29, 34 } },
        .{ .button = .portrait(2), .rect = .{ 370, 5, 413, 52 }, .shutter = .{ 29, 34 } },
        .{ .button = .portrait(3), .rect = .{ 420, 5, 463, 52 }, .shutter = .{ 29, 34 } },
        .{ .button = .portrait(4), .rect = .{ 470, 5, 513, 52 }, .shutter = .{ 29, 34 } },
        .{ .button = .turn, .rect = .{ 524, 21, 565, 60 }, .hint = ui_text.keyName(.hint_turn), .shutter = .{ 22, 28 } },
        .{ .button = .end_turn, .rect = .{ 574, 21, 602, 60 }, .hint = ui_text.keyName(.hint_end_turn), .pressed = .{ .frame = 40, .dx = 2 }, .shutter = .{ 4, 9 } },
        .{ .button = .skills, .rect = .{ 609, 20, 633, 41 }, .hint = ui_text.keyName(.hint_skills), .pressed = .{ .frame = 41, .dx = 3 } },
        .{ .button = .stats, .rect = .{ 608, 44, 633, 60 }, .hint = ui_text.keyName(.hint_stats), .pressed = .{ .frame = 42, .dx = 3 } },
    } },
    .windows = .{
        .skills = .{ .at = .{ 5, 40 }, .from = .{ -150, 40 }, .size = .{ 143, 323 } },
        .skills_inventory = .{ 16, 75 },
        .stats = .{ .at = .{ 450, 60 }, .from = .{ 700, 50 }, .size = .{ 185, 336 } },
        .stats_inventory = .{ 450, 10 },
        .level_up = .{ 250, 40 },
    },
    .menu = .{
        .model = "menu",
        .anim = "menu",
        .light = "gorky-light.3df",
        .circle = "white_circle.3df",
        .flare = "menuflare.3df",
        .lens = "lens.3df",
        .lens2 = "lens2.3df",
        .arrow = "strzalka.3df",
        .cursor = "kursor.3df",
        .font = "3d_menu",
        .glow = "3d_menug",
        .start_y = .{ .name = "MENU_START_Y", .d = 220 },
        .h_space = .{ .name = "MENU_H_SPACE", .d = 47 },
    },
    .videos = &.{
        .{ .name = "introkon.avi", .x = 0, .y = 60, .double = true, .caption = true },
        .{ .name = "logo1.avi", .x = -1000, .y = 0, .double = false },
        .{ .name = "monolith.avi", .x = 0, .y = 0x43, .double = false },
        .{ .name = "topware.avi", .x = 0, .y = 0x50, .double = false },
        .{ .name = "logo.avi", .x = 0x50, .y = 0x64, .double = false },
        .{ .name = "presents.avi", .x = 0xa0, .y = 0xa0, .double = false },
        .{ .name = "intro.avi", .x = 0, .y = 0x3c, .double = true },
    },
    .music = .{
        .level_up = "upgradeparameters",
        .battle_enter = "screenoff4",
        .victory = "victory",
        .game_over = "gameover",
        .statistics = "statistics",
        .battle = "battle battle2",
        .boss = "battle3",
        .enemy_suffix = "_enemy",
    },
    // 0x41f9b0: only these two districts share their music.
    .districts = &.{ .{ .prefix = "03_museum_", .track = "03_museum" }, .{ .prefix = "01_port_", .track = "01_port" } },
    .sounds = .{
        .select_hero = "selecthero",
        .give = "invgive",
        .item_choose = "Itemchoose",
        .item_put = "Itemput",
        .item_select = "invselect",
        .weapons_tab = "invbuttonweapons",
        .items_tab = "invbuttonitems",
        .keys_tab = "invbuttonkeys",
        .explosion = "granat",
        .no_ammo = "battle_noammo",
        .set_points = "upgrade_setpoints",
        .take_items = "takeitems1",
        .safe_key = "safekey",
        .heal = "health2",
        .menu_slide_in = "battle_menuslide_in",
        .menu_slide_out = "battle_menuslide_out",
        .push_barrel = "pull_barell",
        .push_box = "pull_wood_box",
        .click = "click",
        .keyboard = "keyboard",
        .menu_open = "menu1",
        .key_accept = "keyaccept",
        // 0x4cf392, 0x4b24ee; the click marker's.
        .miss = "miss01 miss02",
        .walk_ok = "setway",
        .walk_bad = "setway-wrong",
        .inventory_open = "menu_open",
        .inventory_close = "menu_close",
        .silence = "silents",
        // 0x4ccdd1.
        .blood = "blood1 blood2 blood3",
    },
    // 0x45a8b0 (STOP_HEROES 0x47885a, a hero selected in battle 0x455490).
    .anims = .{ .fight_look = "fightlook", .fight_look_two_handed = "g_fightlook", .hide_back = "hide_back" },
    // 0x4260a0 (morph sparks), 0x49bfb0 (chaingun.msh: two crossed planes along +X).
    .effects = .{ .morph_sparks = "poswiata", .morph_sparks_size = 80, .morph_sparks_rgb = .{ 0.5, 0.5, 0.8 }, .effect_mesh = "chaingun", .explosion = "explosion1", .select_marker = "sel.3df", .facing_arrow = "facingArrow.3df", .click_marker = "disturb.3df", .area_marker = "strzalki.3df", .shock = "current.3df", .grid = "combatGrid.3df" },
    // The interface's own files (viewer/gui.zig, inventory.zig, menu.zig, gui/safe.zig).
    .assets = .{
        .panel = "sprites/game_box.spr",
        .cursor = "sprites/mouse.spr",
        .fighter_info = "sprites/FighterInfo.spr",
        .border = "sprites/border.spr",
        .spinner = "other/pila.spr",
        .atlas = "sprites/fonts.spr",
        .skills = "sprites/WeaponSkill.spr",
        .intro = "sprites/intro.spr",
        .hero_stats = "sprites/HeroStats.spr",
        .dialog_box = "sprites/dialog_box.spr",
        .report = "sprites/raport.spr",
        .item_list = "sprites/item_list.spr",
        .scrollbar = "sprites/GScrollBar.spr",
        .inventory = "sprites/inventory.spr",
        .give_man = "sprites/GiveMan.spr",
        .examine = "sprites/ebox.spr",
        .examine_box = "sprites/examine_box.spr",
        .safe = "sprites/sejf.spr",
        .save = "sprites/save.spr",
        .credits = "sprites/credits.spr",
        .hp_font = "02_hp",
        .safe_font = "03_sejf",
        .msg_font = "3d_msg",
        .credits_font = "01_credits",
        .dialog_font = "02_dialog",
        .small_font = "03_small",
        .system_font = "04_system",
    },
    // 0x42b050, 0x42b0c0, 0x42b300: weapon hold points.
    .holds = .{ .one_hand = "one_hand", .two_hands = "two_hands", .back = "back" },
    // 0x459180: HQ, and any Lamar* (Lamare's own icon).
    .speakers = &.{ .{ .name = "HQ", .portrait = "Head Quarters" }, .{ .name = "Lamar", .portrait = "Lamare", .prefix = true } },
    // 0x454e6e: [0x651ca0] = -30 in the hotel entrance (0x47d0e0, 0x47cf70).
    .grid_floors = &.{.{ .level = "04__city_hotelentrance", .z = -30 }},
};

/// The exe's special AI scorings as OG Script (0x4dfc10…0x4e2b50; combat/ai.zig has the
/// same in Zig for Classic): the converter writes them into the project
/// (`components/ai_scoring/*.ogs`), and the AiScoring rows of these occupants and tiles name
/// them (`script`). Each answers Enemy.ScoreTile for a hit tile.
pub const ai_scoring_ogs =
    \\module ai_scoring {
    \\    // Strikes only its target, its child's killer (Grandma).
    \\    component Avenge for Enemy {
    \\        fn ScoreTile(tile, occupant, weapon, here, aim, damage, pct) {
    \\            if (occupant != nil and occupant == host.avenging) return damage * pct;
    \\            return 0;
    \\        }
    \\    }
    \\    // The melee weapon (secondary) on a sleeping hero, the sleep shot on an awake one (the Guard).
    \\    component SleepHunter for Enemy {
    \\        fn ScoreTile(tile, occupant, weapon, here, aim, damage, pct) {
    \\            if (occupant == nil or occupant.side != "hero") return 0;
    \\            if (weapon.secondary) {
    \\                if (occupant.asleep) return 100;
    \\                return 0;
    \\            }
    \\            if (occupant.asleep) return 0;
    \\            return 1;
    \\        }
    \\    }
    \\    // +10 a hero, −100 anyone else (Schizo).
    \\    component HeroesOnly for Enemy {
    \\        fn ScoreTile(tile, occupant, weapon, here, aim, damage, pct) {
    \\            if (occupant == nil) return 0;
    \\            if (occupant.side == "hero") return 10;
    \\            return -100;
    \\        }
    \\    }
    \\    // The hit tiles whole (Incubus): an occupied one −10×; an empty one, on the first
    \\    // activation 200 − damage·pct·d/100 (d: the nearest hero, dx² + dy²), on the second
    \\    // (here − aim)² · damage·pct/100.
    \\    component WholeTile for Enemy {
    \\        fn ScoreTile(tile, occupant, weapon, here, aim, damage, pct) {
    \\            if (occupant != nil) return -10 * damage * pct / 100;
    \\            if (!host.second_turn) {
    \\                var d = 100;
    \\                var h = battle::Nearest(tile, "hero");
    \\                if (h != nil) {
    \\                    var dx = h.tile[0] - tile[0];
    \\                    var dy = h.tile[1] - tile[1];
    \\                    d = dx * dx + dy * dy;
    \\                    if (d <= 0) d = 100;
    \\                }
    \\                return 200 - damage * pct * d / 100;
    \\            }
    \\            var ex = here[0] - aim[0];
    \\            var ey = here[1] - aim[1];
    \\            return (ex * ex + ey * ey) * damage * pct / 100;
    \\        }
    \\    }
    \\}
;

/// The AiScoring occupant (or tile) each of ai_scoring_ogs's components stands for.
pub const ai_scoring_parts = [_]struct { []const u8, []const u8 }{
    .{ "avenge", "ai_scoring::Avenge" }, .{ "sleep_hunter", "ai_scoring::SleepHunter" }, .{ "heroes_only", "ai_scoring::HeroesOnly" }, .{ "whole", "ai_scoring::WholeTile" },
};

/// The exe's scripted battle events (0x47c464, 0x4b4afc; 0x4985fb): the girl turns into
/// Lilith (levelMode 8) 100 ticks after the first hero strike, the dialog 80 later.
pub const transforms = [_]fight.Transform{
    .{ .mode = 8, .who = "03ch_lilith1", .into = "03ch_lilith_m.mtm", .anim = "lilith", .idle = "dech", .sound = "transformation", .delay = 100, .dialog = "03__museum_child_2", .dialog_file = "03__museum_child2.dlg", .dialog_delay = 80 },
};

/// levelMode 7 after the first enemy turn (McFadden's death), 10 after the second (the
/// helicopter in the museum).
pub const mid_dialogs = [_]fight.MidDialog{
    .{ .mode = 7, .turn = 1, .dialog = "04__city_mfd", .dialog_file = "04__city_mfd.dlg" },
    .{ .mode = 10, .turn = 2, .dialog = "03__museum_chopper_2", .dialog_file = "03__museum_chopper2.dlg" },
};

/// Hero bomb (0x4bd8c0, clock 0x4bdc93), PutLargeTimeBomb (0x4bea30), decoy (0x4bdb40),
/// the bomb's blast weapon (0x4bdd7b: classic_id 1002, class 9, damage 40).
pub const devices = [_]fight.Device{
    .{ .kind = .time_bomb, .archetype = "ft_time_bomb.ss", .prefix = "TimeBomb", .timer = 2 },
    .{ .kind = .large_bomb, .archetype = "ft_time_bomb_large.ss", .prefix = "TimeBombLarge", .timer = 6 },
    .{ .kind = .decoy, .archetype = "ft_distractor.ss", .prefix = "Distractor" },
    .{ .kind = .blast, .archetype = "wp_timebomb_explode.s", .prefix = "TimeBombExplode" },
};

/// 0x4900f0: burn 3 turns, freeze 2, gas 3, soak 3, sleep 2; fire and gas 15/10/5 by the
/// turns left 3/2/1 (0x4903d0); the Invisible's bite 20 every turn.
pub const states = [_]fight.StateEffect{
    .{ .effect = .burn, .turns = 3, .damage = &.{ 15, 10, 5 } },
    .{ .effect = .freeze, .turns = 2 },
    .{ .effect = .gas, .turns = 3, .damage = &.{ 15, 10, 5 } },
    .{ .effect = .soak, .turns = 3 },
    .{ .effect = .sleep, .turns = 2 },
    .{ .effect = .bite, .damage = &.{20} },
};

/// The idle a lifted victim plays (state 3, 0x496f1f): McFadden 24 and Hutchens 29
/// "deliriumA" (0x423355); the rest the raw "delirium".
pub fn liftPose(w: Who) []const u8 {
    return if (w.id == 24 or w.id == 29) "deliriumA" else "delirium";
}

/// A barrel whose `explodeWeapon` has classic_id `weapon` blows up with an explosion and its
/// sound (0x4ceb72: only 1002, every barrel in the game); OpenGorky: its `explodable`.
pub fn blastShown(weapon: i32) bool {
    return weapon == 1002;
}

/// A level named as a battle (the exe's rule, 0x41f219: "__" in the name): entering it from
/// a location plays the saw transition and draws its stripes.
pub fn battleNamed(level: []const u8) bool {
    return std.mem.indexOf(u8, level, "__") != null;
}

/// A port fix (the player's request), not the exe: in museum-slavsky Slavsky stays on his
/// knees for a sway or two, not every repeat of `ANIMATION("Slavsky","knee_idle",20)`
/// (≈53 s of silence in the exe, 20 × 80 frames, 0x4266e7). While the scene waits for
/// the actor (WAITFORACTOR), repeats of the animation are cut (scene/scenario.zig).
pub const repeat_trims = [_]ui_mod.RepeatTrim{
    .{ .scene = "museum-slavsky", .actor = "Slavsky", .anim = "knee_idle" },
};

test "relative tiles: the Messiah's, from his own tile and stance" {
    const m = for (abilities) |r| {
        if (r.class == 18) break r;
    } else unreachable;
    // 04__elevator_messiah: tile 11,18, stand 3.14 on an unturned grid (the exe's absolute
    // 10,18 open, arms 10,19 left and 10,17 right).
    const fwd = behaviour.ahead(m.stand.?, 0);
    try std.testing.expectEqual(behaviour.Tile{ 10, 18 }, behaviour.relTile(.{ 11, 18 }, fwd, m.open_from.?));
    try std.testing.expectEqual(behaviour.Tile{ 10, 19 }, behaviour.relTile(.{ 11, 18 }, fwd, m.arms.?.left));
    try std.testing.expectEqual(behaviour.Tile{ 10, 17 }, behaviour.relTile(.{ 11, 18 }, fwd, m.arms.?.right));
    // Anywhere, any facing: "the tile in front of it".
    try std.testing.expectEqual(behaviour.Tile{ 3, 6 }, behaviour.relTile(.{ 3, 5 }, behaviour.ahead(std.math.pi / 2.0, 0), .{ 0, 1 }));
    try std.testing.expectEqual(behaviour.Tile{ 4, 5 }, behaviour.relTile(.{ 3, 5 }, behaviour.ahead(1.6, std.math.pi / 2.0), .{ 0, 1 }));
    try std.testing.expectEqual(behaviour.Tile{ 2, 4 }, behaviour.relTile(.{ 3, 5 }, behaviour.ahead(-1.57, 0), .{ -1, 1 }));
}

test "the exe's panel: 5 portrait slots, the controls once each" {
    try std.testing.expectEqual(5, ui.panel.portraits());
    for (std.enums.values(ui_mod.Button)) |b| {
        var n: usize = 0;
        for (ui.panel.places) |p| n += @intFromBool(p.button == b);
        try std.testing.expectEqual(1, n);
    }
    try std.testing.expectEqual(3, ui_mod.Button.portrait(3).slot().?);
    try std.testing.expect(ui_mod.Button.stats.slot() == null);
}

// ---------------------------------------------------------------- strike effects (the exe's)

// The effects module's built-in records (core/effect.zig is their schema): the exe's hit
// and launch code by weapon classic_id (callback 0x4863c0, branches 0x4896b0, projectiles
// 0x49b0a0…0x4a8ca0) and by fighter (table 0x48d618).

const effect = @import("effect.zig");
const Val = effect.Val;
const Part = effect.Part;
const Attach = effect.Attach;
const Rgb = effect.Rgb;
const Rot = effect.Rot;
const At = effect.At;
const Set = effect.Set;
const Launch = effect.Launch;
const Num = @import("../rules.zig").rows.Num;
const Bitmap = @import("../effects.zig").bitmap.Bitmap;
const Projectile = @import("../effects.zig").projectile.Projectile;

fn disp(comptime pre: []const u8, comptime level: []const u8, d: [3]f32) [3]Val {
    return .{ .a(pre ++ "y_disp", d[0]), .a(pre ++ "x_disp", d[1]), .a(level, d[2]) };
}

const smoke_scale: Val = .a("attack_dartgun_smoke_scale", 200);

/// smoke2 puff at the barrel.
fn smoke(delay: u32) Part {
    return .{ .bitmap = .{ .b = .{ .effect = "smoke2", .pos = @splat(0), .size = 0, .step = 1, .delay = delay }, .at = .muzzle, .size = smoke_scale } };
}

/// Muzzle light (kind 6, 0x4885fc): shot_light_displacement (200) forward, at
/// shot_light_level (400), range 350, 3 ticks.
const shot_light: Part = .{ .light = .{ .at = .{ .a("shot_light_displacement", 200), .n(0), .a("shot_light_level", 400) }, .range = 350, .ticks = 3 } };

/// Muzzle flash (kind 1, chaingun.msh + chaingun.dsc, 0x48bda2): light, flash, and
/// for pistols, rifle and shotgun a smoke2 puff after it.
fn flash(a: Attach, smoked: bool) []const Part {
    const f = muzzle(a);
    return if (smoked) &.{ shot_light, .{ .attach = f }, smoke(5) } else &.{ shot_light, .{ .attach = f } };
}

/// `a` with the exe's muzzle flash effect where it names none.
fn muzzle(a: Attach) Attach {
    var x = a;
    if (x.effect.len == 0) x.effect = "chaingun";
    return x;
}

/// Monster shot (0x48d618): flash on its own point, smoke2 at the barrel, the light.
fn shot(link: []const u8, ticks: Num) []const Part {
    return &.{ .{ .attach = .{ .effect = "chaingun", .link = link, .ticks = ticks } }, smoke(0), shot_light };
}

fn bitmap(b: Bitmap, lift: f32, size: ?Val, rgb: ?Rgb) Part {
    return .{ .bitmap = .{ .b = b, .lift = lift, .size = size, .rgb = rgb } };
}

fn bm(name: []const u8, size: f32, step: f32) Bitmap {
    return .{ .effect = name, .pos = @splat(0), .size = size, .step = step };
}

const zero: Projectile = .{ .pos = @splat(0), .start = @splat(0), .target = @splat(0) };

/// Rocket: speed 7 → 15 (acceleration 0.7 after 10 ticks), "Rocket1" and exhaust,
/// trail "Trail1" (0x49bfb0, 0x49d987).
fn rocket(size: f32) Projectile {
    var x = zero;
    x.speed = 7;
    x.max_speed = 15;
    x.accel = 0.7;
    x.accel_delay = 10;
    x.effect = "Rocket1";
    x.size = size;
    x.rocket = true;
    x.trail = "Trail1";
    return x;
}

fn arc(mesh: []const u8, spin: f32) Projectile {
    var x = zero;
    x.arc = true;
    x.mesh = mesh;
    x.spin = spin;
    return x;
}

fn with(p: anytype, comptime f: []const u8, v: anytype) @TypeOf(p) {
    var x = p;
    @field(x, f) = v;
    return x;
}

const grenade_start = disp("attack_grenade_", "attack_grenade_start_level", .{ 0, 0, 400 });
const stone_start = disp("attack_stone_", "attack_stone_start_level", .{ 0, -100, 400 });
const grandma: Launch = .{
    .pr = with(with(with(zero, "effect", "trucizna"), "bullet", true), "trail", "Trail1"),
    .rocket_trail = true,
    .set = &.{ .{ .f = .speed, .v = .a("attack_grandma_speed", 12) }, .{ .f = .mesh_scale, .v = .a("attack_grandma_scale", 1.3) } },
    .trail_rgb = .{ .adj = "attack_grandma_col", .d = .{ 80, 255, 80 } },
};
const ball: Projectile = .{ .pos = @splat(0), .start = @splat(0), .target = @splat(0), .effect = "kula", .light_range = 1100, .light_rgb = @splat(0.1), .size = 130 };

/// The ball (0x4a5840): created at the fighter's position (0x4883cf: pos), held at its
/// hands ("kula1"/"kula2", `hold` ticks), grows from 0.1 to its scale by attack_ball_ds
/// (codes 42, 44); drawn as the ball look.
fn ballLaunch(pr: Projectile, set: []const Set) Launch {
    return .{ .pr = pr, .set = set, .start_at = .{ .self = .{ .n(0), .n(0), .n(0) } }, .hold = .{ "kula1", "kula2" }, .grow = .a("attack_ball_ds", 0.08), .look = .ball };
}

/// Orbital rocket (0x4a8ca0 → 0x4a8450): starts at the target + unit vector (attacker −
/// target in x + 0.1·aS, in y; rv2_h·aS − target z) × attack_rv2_dist (6000)·aS; trail
/// point period rv2_trail_update_speed (1).
const orbital_start: At = .{ .sky = .{ .h = .a("rv2_h", 1400), .dist = .a("attack_rv2_dist", 6000) } };
const orbital_period: Set = .{ .f = .trail_period, .v = .a("rv2_trail_update_speed", 1) };

/// The launch with its preset's fields (`code`, old rules files); `extra`: a preset's set
/// value after `set`.
pub fn withCode(l: Launch) struct { l: Launch, extra: ?Set } {
    var x = l;
    x.code = .none;
    switch (l.code) {
        .none => return .{ .l = l, .extra = null },
        .ball => {
            const b = ballLaunch(l.pr, l.set);
            inline for (.{ "start_at", "hold", "grow", "look" }) |f| @field(x, f) = @field(b, f);
            return .{ .l = x, .extra = null };
        },
        .orbital => {
            x.start_at = orbital_start;
            return .{ .l = x, .extra = orbital_period };
        },
    }
}

// The exe's per-frame behaviour as parts (the `Code` presets).

/// attack_flame_time (90) and attack_flame_tab (74): the flame object's timer and particle
/// limit (0x4a0764…0x4a0789), shared by the flamethrower and the Stinger.
const flame_time: Val = .{ .d = 90, .adj = "attack_flame_time", .int = true };
const flame_tab: Val = .{ .d = 74, .adj = "attack_flame_tab", .int = true };

/// Ion rifle (0x4a1600): an "ion" ribbon from the two_hands point along its x axis (each
/// frame, 0x4a18d0, 0x429ca0) turned by `turn` (−0.09; Slavsky 0.4), at the barrel height
/// pos.z + attack_ion_start_level (465)·aS (callback 0x1a, 0x487a69); without a model from
/// the actor's centre toward the target (lifted 250·aS). Two runs of 25 segments of
/// 220·aS (0x50aac0): forward from 155·aS ahead (−attack_ion_vs, loop 0x4a2172), back with
/// a reversed step (0x4a233d) from the end of the first less attack_ion_vk 5922 (0x4a235b,
/// loop 0x4a2490). 27 ticks, half-width attack_ion_size 30.
fn ion(turn: f32) [1]Part {
    const chains = [_]effect.Chain{
        .{ .start = .{ .d = -155, .adj = "attack_ion_vs", .div = -1 }, .step = 220, .n = 25 },
        .{ .start = .{ .d = -155, .adj = "attack_ion_vs", .div = -1, .sum = &.{ .n(25 * 220), .{ .d = 5922, .adj = "attack_ion_vk", .div = -1 } } }, .step = -220, .n = 25 },
    };
    return .{.{ .beam = .{
        .b = .{ .kind = .ion, .effect = "ion", .from = @splat(0), .to = @splat(0), .size = 0, .left = 0, .link = "two_hands", .turn = turn },
        .from = .{ .self = .{ .n(0), .n(0), .a("attack_ion_start_level", 465) } },
        .to = .{ .target = 250 },
        .chains = &chains,
        .size = .a("attack_ion_size", 30),
        .ticks = .adj("attack_ion_life", 27),
        .actor = true,
    } }};
}
const ion_parts = ion(-0.09);
const ion_slavsky = ion(0.4);

/// Blaster (0x4a37c0): a "blaster" stream to each fighter on the strike's hit tiles (weapon
/// +0xe8 = 0x4cebe0: +0x108 → the set's tiles), to pos + 300·aS (0x4a3876); from the
/// actor's centre at attack_blaster_start_level (450)·aS moved toward the target by
/// attack_blaster_r (120)·aS (callback 0x1c, 0x487aee). No fighters, no streams.
const blaster_parts = [_]Part{.{ .ribbon = .{ .from = .{ .toward = .{ .r = .a("attack_blaster_r", 120), .up = .a("attack_blaster_start_level", 450) } }, .to = .{ .each_hit = 300 } } }};

/// Medusa's current (0x4a44e0, also VOLTAGE): two "blaster" arcs current1→current3 and
/// current2→current4 (0x4a3c30), 45 ticks, half-width attack_luk_scale 300.
fn currentArc(from: []const u8, to: []const u8) Part {
    return .{ .beam = .{ .b = .{ .kind = .current, .effect = "blaster", .from = @splat(0), .to = @splat(0), .size = 0, .left = 0, .link = from, .link2 = to }, .size = .a("attack_luk_scale", 300), .ticks = .n(45), .actor = true } };
}
const current_parts = [_]Part{ currentArc("current1", "current3"), currentArc("current2", "current4") };

/// Schizo (0x48b914): cloud "gas2" on the target + 130·aS (kind 49, 0x4a95d0) while the
/// tile has gas; its constructor draws (rand() % 10) · 0.1 (0x4a9685, shared stream).
const cloud_parts = [_]Part{.{ .cloud = .{ .at = .{ .target = 130 }, .c = .{ .effect = "gas2" }, .rand_draws = 1 } }};

/// Pain God (kind 30, callback 0x1e 0x487bd1 → 0x4a1430 → class 0x4a0900, tick 0x4a0bf0):
/// from pos + aS·(80 right, 600 up) (attack_paingod_x_disp) to the target + 300·aS
/// (0x4863c0); a particle 250·aS along, speed attack_flame_pg_speed (35)·aS, one per tick
/// for 30 ticks, at most 70, life attack_flame_pg_life (10); light (1, 0.3, 0.3) 600·aS
/// along the direction (0x50a934), range 700·aS (0x50a86c), 30 ticks.
const pain_src = [3]Val{ .n(0), .a("attack_paingod_x_disp", 80), .n(600) };
const pain_god_parts = [_]Part{
    .{ .emitter = .{ .at = .{ .self = pain_src }, .aim = .{ .target = 300 }, .ahead = .n(250), .timer = .n(31), .max = .n(70), .life = .{ .d = 10, .adj = "attack_flame_pg_life", .int = true }, .speed = .a("attack_flame_pg_speed", 35) } },
    .{ .light = .{ .at = pain_src, .toward = .{ .target = 300 }, .ahead = 600, .color = .{ 1, 0.3, 0.3 }, .range = 700, .range_as = true, .ticks = 30 } },
};

/// Stinger (127) melee: a flame jet (kind 43, 0x4a06f0) from model point t1 toward t2,
/// forward by attack_stinger_d (30)·aS. Its time shift ftol(attack_stinger_dtime) (−55,
/// 0x487cb9) goes into both the object timer (attack_flame_time + shift = 35) and the
/// particle limit (attack_flame_tab + shift = 19; 0x4a0764…0x4a0789).
const stinger_dt: Val = .{ .d = -55, .adj = "attack_stinger_dtime", .trunc = true };
const stinger_parts = [_]Part{.{ .emitter = .{
    .at = .{ .self = .{ .n(0), .n(0), .n(360) } },
    .ahead = .a("attack_stinger_d", 30),
    .timer = with(flame_time, "sum", &.{stinger_dt}),
    .max = with(flame_tab, "sum", &.{stinger_dt}),
    .link = "t1",
    .link2 = "t2",
} }};

/// Flamethrower (kind 25, 0x4a06f0 → tick 0x49fdc0): a point at the fighter at height
/// attack_flameth_start_level (360)·aS; each tick the direction points at the two_hands
/// point of the current frame, turned by −0.8 rad; a particle at 250·aS along it, speed
/// attack_flame_speed (35)·aS; attack_flame_time 90, attack_flame_tab 74. Its queue
/// (0x48cdd6) has no attack-end command: the stream holds the attack.
const flamethrower_parts = [_]Part{.{ .emitter = .{
    .at = .{ .self = .{ .n(0), .n(0), .a("attack_flameth_start_level", 360) } },
    .ahead = .n(250),
    .speed = .a("attack_flame_speed", 35),
    .timer = flame_time,
    .max = flame_tab,
    .link = "two_hands",
    .rot = -0.8,
    .holds_attack = true,
} }};

/// Satellite energy beam (0x4a74a0): mesh "beam" at the target (`effects.beam.Spin`).
const spin_parts = [_]Part{.{ .mesh = .{ .at = .{ .target = 0 } } }};

/// The parts of preset `c` (Slavsky's ion, turned the other way, is his own WeaponFx
/// row's parts: `weapon_fx` 1029, who 26).
pub fn preset(c: effect.Code) []const Part {
    return switch (c) {
        .ion => &ion_parts,
        .blaster => &blaster_parts,
        .current => &current_parts,
        .cloud => &cloud_parts,
        .pain_god => &pain_god_parts,
        .stinger_flame => &stinger_parts,
        .flamethrower => &flamethrower_parts,
        .spin => &spin_parts,
    };
}

/// The monster shot flash's time (Fatman, Lucy).
const rifle_flash: Num = .adj("attack_rifle_flash_timeout", 5);

fn rocketLaunch(size: f32, start: [3]Val, scale: ?[]const u8) Launch {
    return .{ .pr = rocket(size), .start = start, .rocket_trail = true, .set = if (scale) |s| &.{.{ .f = .mesh_scale, .v = .a(s, 2) }} else &.{} };
}

/// The game weapons' effects (the exe's code by classic_id; comments: its addresses).
pub const weapon_fx = [_]effect.Weapon{
    // Pistol and revolver (revolver x ×1.5): rotation Rx(−0.3)·Ry(−0.6)·Rz(−2.1) (0x482010).
    .{ .id = 49, .flash = flash(.{ .link = "one_hand", .offset = .{ -30, -40, 50 }, .rot = .{ .xyz = .{ -0.3, -0.6, -2.1 } } }, true) },
    .{ .id = 50, .flash = flash(.{ .link = "one_hand", .offset = .{ -45, -40, 50 }, .rot = .{ .xyz = .{ -0.3, -0.6, -2.1 } } }, true) },
    // Rifle (0x48c6fa) and shotgun (0x48cc06): Ry(−0.2) and Ry(−0.1).
    .{ .id = 98, .flash = flash(.{ .link = "two_hands", .offset = .{ 150, 10, -40 }, .rot = .{ .zy = .{ 0, -0.2 } } }, true) },
    .{ .id = 1023, .flash = flash(.{ .link = "two_hands", .offset = .{ 140, 17, -20 }, .rot = .{ .zy = .{ 0, -0.1 } } }, true) },
    // Chaingun (uzi, 0x48c8b5): attack_chaingun_flash_disp (−8, −40, 44), Rz(−1.82)·Ry(0.3);
    // Slavsky (26) (7, −21, −35), Rz(−0.32)·Ry(−0.2). 80 ticks.
    .{ .id = 1022, .who = 26, .flash = flash(.{ .link = "two_hands", .offset = .{ 7, -21, -35 }, .ticks = .n(80), .rot = .{ .zy = .{ -0.32, -0.2 } } }, false) },
    .{ .id = 1022, .flash = flash(.{ .link = "two_hands", .offset = .{ -8, -40, 44 }, .ticks = .n(80), .rot = .{ .zy = .{ -1.82, 0.3 } } }, false) },
    // Nitrogen gun: "nitro" 80 ticks (nitro_timeout), Ry(π − 0.1) (0x48ce33…0x48cebe):
    // the mesh points back, so the jet goes from attack_nitro_disp to the barrel.
    .{ .id = 1025, .flash = flash(.{ .effect = "nitro", .link = "two_hands", .offset = .{ 490, 20, -50 }, .scale = 1, .ticks = .n(80), .rot = .{ .zy = .{ 0, std.math.pi - 0.1 } } }, false) },
    // Monster shots (between the two 0x427ce0 calls of 0x4896b0): Fatman (1076, 0x48aed0),
    // Lucy (1058, 0x48ad0f), Cripple (1065, 0x48b12c), Puppet (1068, 0x48b50a), Schizo
    // attack_3 (1079, 0x48bb5f).
    .{ .id = 1076, .shot = shot("chaingun", rifle_flash) },
    .{ .id = 1058, .shot = shot("chaingun", rifle_flash) },
    .{ .id = 1065, .shot = shot("chaingun1", .n(5)) },
    .{ .id = 1068, .shot = shot("chaingun", .adj("attack_puppet_l_timeout", 16)) },
    .{ .id = 1079, .shot = shot("chaingun", .adj("attack_schizo_r_delay2", 35)) },
    // Ion rifle beam and blaster streams before the damage (HeroAttack.pre).
    .{ .id = 1029, .who = 26, .pre = &ion_slavsky },
    .{ .id = 1029, .pre = &ion_parts },
    .{ .id = 1037, .pre = &blaster_parts },
    // Garcia (0x489823…0x489881): "chaingun" 30 ticks and the barrel light (state 1,
    // 0x496e1a): (200 forward, 100 right, 400 up)·aS, range 1000.
    .{ .id = 67, .pre = &.{ .{ .attach = .{ .effect = "chaingun", .link = "chaingun", .ticks = .n(30) } }, .{ .light = .{ .at = .{ .n(200), .n(100), .n(400) }, .range = 1000, .ticks = 30 } } } },
    // Schizo (0x48b9df…0x48baba): "gas3" from the bell "dmuchawa" (attack_schizo_g_disp
    // 460, g_scale 1.5), Rz(π) (0x48b9e4…0x48ba67), g_delay2 + g_delay3 (98 + 30).
    .{ .id = 1078, .pre = &.{.{ .attach = .{ .effect = "gas3", .link = "dmuchawa", .offset = .{ 460, 0, 0 }, .rot = .{ .matrix = .{ -1, 0, 0, 0, -1, 0, 0, 0, 1 } }, .scale = 1.5, .ticks = .n(98 + 30) } }} },
    // Darts (code 39, 0x48813f): puff at the barrel and the light after (0x4882c8).
    .{ .id = 45, .hit = &.{ smoke(0), shot_light } },
    // Flare gun: puff at the barrel; sparks come in the target's reaction (fx.flare).
    .{ .id = 46, .hit = &.{smoke(0)}, .launch = .{ .pr = with(zero, "effect", "flare1"), .set = &.{ .{ .f = .speed, .v = .a("attack_flaregun_speed", 10) }, .{ .f = .size, .v = .a("attack_flaregun_scale", 300) } } } },
    // Ball: "KulaExpl" (0x4d0780), no lift, no delay. Hangs at the fighter for attack_ball_life
    // (88) / attack_stinger_ball_life (70) ticks, grows by attack_ball_ds, flies at
    // speed·aS (0x4a60f7); no mesh drawn (vtable 0x50adf8 +0x50 is `ret`), own light
    // 1100·aS colour 0.1 (0x4a593f); the Incubus's (kind 0) lies as a charge (0x4a5fe1).
    .{ .id = 1070, .hit = &.{bitmap(bm("KulaExpl", 1000, 0.5), 250, null, null)}, .launch = ballLaunch(with(ball, "charge", true), &.{ .{ .f = .speed, .v = .{ .d = 70, .adj = "attack_ball_speed", .div = 7 } }, .{ .f = .mesh_scale, .v = .a("attack_ball_ms", 0.8) }, .{ .f = .hold, .v = .a("attack_ball_life", 88) } }) },
    .{ .id = 1072, .hit = &.{bitmap(bm("KulaExpl", 1000, 0.5), 250, null, null)}, .launch = ballLaunch(ball, &.{ .{ .f = .speed, .v = .{ .d = 130, .adj = "attack_stinger_ball_speed", .int = true, .div = 7 } }, .{ .f = .mesh_scale, .v = .a("attack_stinger_ball_ms", 1) }, .{ .f = .hold, .v = .a("attack_stinger_ball_life", 70) } }) },
    // Grenade (0x49cc30, arc 0x49e220): explosion at the landing point + attack_grenade_exp
    // (250)·aS. The Sister's brain (0x4a4b20 → 0x4a4650) uses the same blast: from
    // attack_sister_* (390 forward, −30 right, 300 up), speed attack_brain_speed (80)·aS.
    .{ .id = 1051, .hit = &.{.{ .explosion = .a("attack_grenade_exp", 250) }}, .launch = .{ .pr = with(zero, "mesh", "brain"), .start = disp("attack_sister_", "attack_sister_start_level", .{ 390, -30, 300 }), .set = &.{ .{ .f = .speed, .v = .{ .d = 80, .adj = "attack_brain_speed", .div = 7.0 } }, .{ .f = .mesh_scale, .v = .a("attack_brain_scale", 0.7) }, .{ .f = .spin, .v = .a("attack_brain_rot", 0.5) } } } },
    .{ .id = 35, .hit = &.{.{ .explosion = .a("attack_grenade_exp", 250) }}, .launch = .{ .pr = arc("grenade", 0), .start = grenade_start, .set = &.{.{ .f = .mesh_scale, .v = .a("attack_grenade_scale", 1) }} } },
    // Rockets (0x49c720; launcher, Jet Elmer, Fang, Smoke Rider): explosion at the arrival,
    // tile centre + 300·aS (0x48643d). Own launch points (0x48736b and neighbours); every
    // 0x49d8d0 rocket uses rocket1_trail_* (0x4834f0…0x483a90).
    .{ .id = 57, .hit = &.{.{ .explosion = .n(300) }}, .launch = .{ .pr = rocket(160), .rocket_trail = true, .start = disp("attack_jetelmer_rocket1_", "attack_jetelmer_rocket_start_level", .{ 100, 100, 670 }), .start2 = disp("attack_jetelmer_rocket2_", "attack_jetelmer_rocket_start_level", .{ 100, -144, 670 }) } },
    .{ .id = 91, .hit = &.{.{ .explosion = .n(300) }}, .launch = rocketLaunch(160, disp("fang_attack_rocket2_", "fang_attack_rocket2_start_level", .{ 500, -150, 360 }), "fang_attack_rocket_scale") },
    .{ .id = 1003, .hit = &.{.{ .explosion = .n(300) }}, .launch = rocketLaunch(160, disp("smokerider_attack_rocket1_", "smokerider_attack_rocket1_start_level", .{ 700, 175, 400 }), "smokerider_attack_rocket_scale") },
    // Smoke Rider, second kind (code 20, 0x487589).
    .{ .id = 1004, .hit = &.{.{ .explosion = .n(300) }}, .launch = rocketLaunch(160, disp("smokerider_attack2_rocket1_", "smokerider_attack2_rocket1_start_level", .{ 235, -100, 900 }), "smokerider_attack2_rocket_scale") },
    // Launcher (code 23, 0x48781c): attack_rocketl_scale 2 (+0x358, 0x48790b).
    .{ .id = 1024, .hit = &.{.{ .explosion = .n(300) }}, .launch = rocketLaunch(120, disp("attack_rocketl_", "attack_rocketl_start_level", .{ 300, 0, 270 }), "attack_rocketl_scale") },
    // Stun grenade: "stun" flash 900 (rate 0.2), 5 ticks later smoke1 600; arc without spin
    // (0x49e2f0, +0x344 = 0).
    .{ .id = 33, .hit = &.{ bitmap(with(with(bm("stun", 900, 0), "alpha", 0), "flash_rate", 0.2), 250, null, null), bitmap(with(bm("smoke1", 600, 1), "delay", 5), 250, null, null) }, .launch = .{ .pr = with(arc("bomb_stun", 0), "mesh_scale", 1), .start = grenade_start } },
    // Gas grenade: green smoke1 600 (attack_gasgr_col 100,255,0).
    .{ .id = 1027, .hit = &.{bitmap(bm("smoke1", 600, 1), 250, null, .{ .adj = "attack_gasgr_col", .d = .{ 100, 255, 0 } })}, .launch = .{ .pr = with(arc("bomb_stun", 0), "mesh_scale", 1), .start = grenade_start } },
    // Molotov (0x49d7d0, 0x49e8b0): "molotov" attack_molotov_scale 800 at the landing point
    // + 800·aS, colour (1, 0.9, 0.9); flame and light behind the bottle (0x4321b0), range
    // 800·aS, (1, 0.3, 0.3). Vodka, petrol and stone (bottle class 0x49e7c0, 0x49e7f0):
    // only the bottle sound; the stone mesh is missing from the data, so invisible.
    .{ .id = 86, .hit = &.{bitmap(with(bm("molotov", 0, 0.5), "rgb", .{ 1, 0.9, 0.9 }), 800, .a("attack_molotov_scale", 800), null)}, .launch = .{ .pr = with(with(with(with(arc("molotov", 0.2), "mesh_scale", 1), "flame", true), "light_range", 800), "light_rgb", .{ 1, 0.3, 0.3 }), .start = stone_start } },
    .{ .id = 1032, .launch = .{ .pr = with(arc("vodka", 0.2), "mesh_scale", 1), .start = stone_start } },
    .{ .id = 1030, .launch = .{ .pr = with(arc("butlagas", 0.2), "mesh_scale", 1), .start = stone_start } },
    .{ .id = 41, .launch = .{ .pr = with(arc("stone", 0.2), "mesh_scale", 1), .start = stone_start } },
    // Napalm launcher (callback 0x2d, 0x488447…0x4884b1).
    .{ .id = 1028, .launch = .{ .pr = arc("napalmcan", 0.2), .start = disp("attack_napalmth_", "attack_napalmth_start_level", .{ 70, 0, 300 }), .set = &.{.{ .f = .mesh_scale, .v = .a("attack_napalmth_scale", 0.4) }} } },
    // Cutter Pill bullet (kind 13, 0x49e070 → 0x49dd70): damage on arrival.
    .{ .id = 89, .launch = .{ .pr = with(with(zero, "effect", "arrows"), "bullet", true), .start = disp("attack_cutterpill_long_", "attack_cutterpill_long_start_level", .{ 400, -60, 500 }), .set = &.{ .{ .f = .speed, .v = .a("attack_cutterpillbullet_speed", 15) }, .{ .f = .mesh_scale, .v = .a("attack_cutterpillbullet_scale", 0.6) } } } },
    // Throwing knife (code 4, 0x4867f6).
    .{ .id = 40, .launch = .{ .pr = with(zero, "mesh", "knife_throwing"), .start = disp("attack_knife_", "attack_knife_start_level", .{ 200, -100, 500 }), .set = &.{ .{ .f = .speed, .v = .a("attack_knife_speed", 15) }, .{ .f = .mesh_scale, .v = .a("attack_knife_scale", 1.2) }, .{ .f = .spin, .v = .a("attack_knife_rotation_speed", 0.6) } } } },
    // Grandma's poison (0x49eac0, 0x49efc0): chaingun mesh with "trucizna", trail coloured
    // attack_grandma_col; grandma_mad_gun (1006) spits from attack_grandma_* (command 0x16).
    .{ .id = 1005, .launch = grandma },
    .{ .id = 1006, .launch = with(grandma, "start", disp("attack_grandma_", "attack_grandma_start_level", .{ 550, -55, 240 })) },
    // Satellite energy beam (0x4a74a0): "beam" mesh at the target.
    .{ .id = 1038, .hit = &spin_parts },
    // Satellite lightning (0x4a7710): "LStrike" above the target, half-width 130, 8 ticks.
    .{ .id = 1039, .hit = &.{.{ .beam = .{ .b = .{ .kind = .lightning, .effect = "LStrike", .from = @splat(0), .to = @splat(0), .size = 130, .left = 8, .div = 1 } } }} },
    // Orbital rocket (0x4a8c70, 0x4a8ca0 → 0x4a8450): explosion at the arrival, target +
    // 300·aS; speed attack_rv2_speed, trail rv2_trail_* (0x4a84cb), from the sky.
    .{ .id = 1040, .hit = &.{.{ .explosion = .n(300) }}, .launch = .{ .pr = with(with(zero, "mesh", "pocisk"), "trail", "Trail1"), .rocket_trail = true, .start_at = orbital_start, .set = &.{ .{ .f = .speed, .v = .a("attack_rv2_speed", 24) }, .{ .f = .trail_size, .v = .a("rv2_trail_size", 200) }, .{ .f = .trail_fade, .v = .a("rv2_trail_fade_factor", 0.8) }, .{ .f = .trail_back, .v = .a("rv2_trail_disp", 800) }, orbital_period } } },
    // Flamethrower (kind 25, 0x4a06f0 → tick 0x49fdc0).
    .{ .id = 1026, .hit = &flamethrower_parts },
};

/// Medusa beam mesh rotation: Rz(π)·Rx(π/2) (0x47cd30, row-major).
const medusa_beam_rot: Rot = .{ .matrix = .{ -1, 0, 0, 0, 0, 1, 0, 1, 0 } };

fn saw(link: []const u8, offset: [3]f32) []const Part {
    return &.{.{ .attach = .{ .effect = "sparks", .link = link, .offset = offset, .rot = medusa_beam_rot, .scale = 2, .ticks = .adj("attack_headnail_delay4", 5) } }};
}

/// The fighters' own (branches of table 0x48d618).
pub const fighter_fx = [_]effect.Fighter{
    // Medusa (0x48a465): weapon 1021 is the mouth gas (0x48a498…0x48a615): on "paszcza",
    // attack_medusa_s_disp (700, 40, −10), scale 2, attack_medusa_s_timeout 72; otherwise
    // current (0x4a3960).
    .{ .fighter = 119, .weapon = 1021, .hit = &.{.{ .attach = .{ .effect = "gas", .link = "paszcza", .offset = .{ 700, 40, -10 }, .rot = medusa_beam_rot, .scale = 2, .ticks = .adj("attack_medusa_s_timeout", 72) } }} },
    .{ .fighter = 119, .hit = &current_parts },
    // Guard (0x48afae), 1063: "ray" lasers from eyes oko1/oko2 to the target + 120·aS
    // (code 0x23 → 0x488025, 0x4a5580: attack_laser_life 54, attack_laser_scale 50), no
    // damage; with damage (code 0x24 → 0x48809c) smoke2 200 on the target + 120·aS.
    .{
        .fighter = 131,
        .weapon = 1063,
        .pre = &.{
            .{ .beam = .{ .b = .{ .kind = .laser, .effect = "ray", .from = @splat(0), .to = @splat(0), .size = 0, .left = 0, .link = "oko1" }, .lift = 120, .size = .a("attack_laser_scale", 50), .ticks = .adj("attack_laser_life", 54), .actor = true } },
            .{ .beam = .{ .b = .{ .kind = .laser, .effect = "ray", .from = @splat(0), .to = @splat(0), .size = 0, .left = 0, .link = "oko2" }, .lift = 120, .size = .a("attack_laser_scale", 50), .ticks = .adj("attack_laser_life", 54), .actor = true } },
        },
        .hit = &.{bitmap(bm("smoke2", 200, 1), 120, null, null)},
    },
    // Headnail (0x48a8c9, 0x48aab9): sparks on the left saw (549, 137, 0), on the second hit
    // the right (575, 112, 0); removed attack_headnail_delay4 (5) after the hit.
    .{ .fighter = 118, .hit = saw("pila lewa", .{ 549, 137, 0 }), .second = saw("pila prawa", .{ 575, 112, 0 }) },
    // Reverend Insect (0x48ab82, no weapon check): after attack_revinsect_delay (45) "nitro"
    // on the chaingun point, offset (320, 0, 0), Ry(π) (0x48aba1…0x48ac43), until delay2 +
    // delay3 (20 + 64); the hit is the freezer (kind 24, 0x49f670): its sound at the target.
    .{ .fighter = 126, .pre = &.{.{ .attach = .{ .effect = "nitro", .link = "chaingun", .offset = .{ 320, 0, 0 }, .rot = .{ .zy = .{ 0, std.math.pi } }, .scale = 1, .ticks = .n(20 + 64) } }}, .hit = &.{.{ .sound = .{ .name = "weapons\\zamrazacz", .ticks = 20 } }} },
    // Schizo (0x48b914): cloud "gas2" on the target for 1078 (code 49 → 0x4aa360).
    .{ .fighter = 136, .weapon = 1078, .hit = &cloud_parts },
    // Pain God (kind 30, callback 0x1e 0x487bd1 → 0x4a1430).
    .{ .fighter = 121, .hit = &pain_god_parts },
    // Stinger (127): melee (weapon 1071) is a flame jet (kind 43, 0x4a06f0).
    .{ .fighter = 127, .weapon = 1071, .hit = &stinger_parts },
    // Squeaker (kind 27, 0x4205a0): screen shake attack_sq_life (30).
    .{ .fighter = 133, .hit = &.{.{ .shake = .adj("attack_sq_life", 30) }} },
};

test "strike effects: the presets' spans" {
    try std.testing.expectEqual(@as(?u32, 106), effect.span(flamethrower_parts[0]).len);
    try std.testing.expectEqual(@as(?u32, 200), effect.span(spin_parts[0]).len);
    try std.testing.expectEqual(@as(?u32, null), effect.span(cloud_parts[0]).len);
}

test "strike effects: one record per weapon and stage" {
    const a = std.testing.allocator;
    for ([_]effect.Stage{ .flash, .launch, .hit }, [_]usize{ 15, 22, 18 }) |st, n| {
        const xs = try effect.ids(a, &weapon_fx, st);
        defer a.free(xs);
        try std.testing.expectEqual(n, xs.len);
    }
    try std.testing.expectEqual(@as(f32, 80.0 / 7.0), (Val{ .d = 80, .adj = "none", .div = 7.0 }).get());
    // The ion's second run: −vs + 25·220 − vk in the viewer's float order.
    const vs: f32 = -155;
    const vk: f32 = 5922;
    try std.testing.expectEqual(-vs + 25 * 220 - vk, ion_parts[0].beam.chains[1].start.get());
    try std.testing.expectEqual(@as(f32, 35), stinger_parts[0].emitter.timer.get());
    // No built-in record names a preset: the dump writes data.
    for (weapon_fx) |w| inline for (.{ "pre", "shot", "flash", "hit" }) |f| for (@field(w, f)) |p| try std.testing.expect(p != .code);
    for (weapon_fx) |w| if (w.launch) |l| try std.testing.expect(l.code == .none);
    for (fighter_fx) |w| inline for (.{ "pre", "hit", "second" }) |f| for (@field(w, f)) |p| try std.testing.expect(p != .code);
}

/// The exe's logical animation slots (0x4280e0, actor/slots.zig): Classic only.
// 0x4280e0 (actor/slots.zig): "stair_up" lands in "stair_down"'s slot 13 (14 stays
// empty), an unknown name in 0, "appearEnd" in 1.
pub const look_slots = [_]ui_mod.LookSlot{
    .{ .name = "death", .slot = 23 },
    .{ .name = "push_start", .slot = 6 },
    .{ .name = "push_end", .slot = 8 },
    .{ .name = "push_walk", .slot = 7 },
    .{ .name = "walk", .slot = 2 },
    .{ .name = "stepping", .slot = 3 },
    .{ .name = "run", .slot = 4 },
    .{ .name = "ladder_start", .slot = 9 },
    .{ .name = "ladder_end", .slot = 11 },
    .{ .name = "ladder_walk", .slot = 10 },
    .{ .name = "strafe", .slot = 12 },
    .{ .name = "stair_down", .slot = 13 },
    .{ .name = "stair_up", .slot = 13 },
    .{ .name = "walk_footbridge", .slot = 15 },
    .{ .name = "jump_start", .slot = 16 },
    .{ .name = "jump_end", .slot = 17 },
    .{ .name = "jump_hang", .slot = 18 },
    .{ .name = "crouch", .slot = 19 },
    .{ .name = "defend", .slot = 5 },
    .{ .name = "defend_start", .slot = 65 },
    .{ .name = "defend_end", .slot = 66 },
    .{ .name = "scary", .slot = 20 },
    .{ .name = "dodge", .slot = 21 },
    .{ .name = "hit", .slot = 22 },
    .{ .name = "delirium", .slot = 24 },
    .{ .name = "delirium_up", .slot = 25 },
    .{ .name = "hide", .slot = 26 },
    .{ .name = "hide_back", .slot = 27 },
    .{ .name = "take_out", .slot = 28 },
    .{ .name = "pickup_start", .slot = 29 },
    .{ .name = "pickup_end", .slot = 30 },
    .{ .name = "pickup_wait", .slot = 31 },
    .{ .name = "use_aid", .slot = 32 },
    .{ .name = "use_medicine", .slot = 33 },
    .{ .name = "use_radio", .slot = 34 },
    .{ .name = "kneel_down", .slot = 35 },
    .{ .name = "kneel_idle", .slot = 36 },
    .{ .name = "kneel_up", .slot = 37 },
    .{ .name = "attack_axe", .slot = 38 },
    .{ .name = "attack_baseball", .slot = 39 },
    .{ .name = "attack_boxing", .slot = 40 },
    .{ .name = "attack_knife", .slot = 41 },
    .{ .name = "attack_butcher", .slot = 42 },
    .{ .name = "attack_dynamit", .slot = 43 },
    .{ .name = "attack_fireworks", .slot = 44 },
    .{ .name = "attack_grenade", .slot = 45 },
    .{ .name = "attack_bazooka", .slot = 46 },
    .{ .name = "attack_flame", .slot = 47 },
    .{ .name = "attack_machinegun", .slot = 48 },
    .{ .name = "attack_rifle", .slot = 49 },
    .{ .name = "attack_sniper", .slot = 50 },
    .{ .name = "attack_molotov", .slot = 51 },
    .{ .name = "attack_gun", .slot = 52 },
    .{ .name = "attack_shocker", .slot = 53 },
    .{ .name = "attack_stone", .slot = 54 },
    .{ .name = "attack_syringe", .slot = 55 },
    .{ .name = "attack_sabre", .slot = 56 },
    .{ .name = "attack_timebomb", .slot = 57 },
    .{ .name = "attack_chaingun", .slot = 58 },
    .{ .name = "attack_blaster", .slot = 59 },
    .{ .name = "attack_ionrifle", .slot = 60 },
    .{ .name = "short_attack", .slot = 61 },
    .{ .name = "long_attack", .slot = 62 },
    .{ .name = "attack_3", .slot = 63 },
    .{ .name = "ponton_out", .slot = 64 },
    .{ .name = "appearEnd", .slot = 1 },
};
