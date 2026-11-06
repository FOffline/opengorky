//! The interface texts the exe names in its code, each by a key. Classic: the edition's
//! `string.tab` line of the key's number (the enum's value, the exe's); an OpenGorky project:
//! its `UiText(key = miss, text = "…")` row (loaders/ogs.zig loadTexts gives the core that
//! number, the converter writes the key). Groups in a row (`armor_light`…, `resist_fire`…)
//! are the exe's ranges (`of`).

const std = @import("std");

pub const Key = enum(i32) {
    /// String 0: what a speaker of no number shows (scene/scenes.zig speakerName).
    not_defined = 0,
    /// The objects' actions (rules Action: action N's text is N's).
    open = 1,
    close = 2,
    take = 3,
    use = 4,
    cancel = 5,
    ok = 6,
    explore = 7,
    take_all = 8,
    take_selected = 9,
    turn_on = 10,
    turn_off = 11,
    switch_on = 12,
    switch_off = 13,
    pull_on = 14,
    pull_off = 15,
    up = 16,
    down = 17,
    heal = 18,
    /// The main and game menus (viewer/menu/items.zig).
    menu_new_game = 300,
    menu_save = 301,
    menu_options = 302,
    menu_credits = 303,
    menu_exit = 304,
    menu_back = 306,
    menu_main = 305,
    menu_load = 307,
    menu_options_title = 308,
    menu_sound = 309,
    menu_graphics = 310,
    /// A save slot without a save ("empty N").
    menu_empty = 311,
    menu_shadows = 312,
    shadows_off = 313,
    shadows_simple = 314,
    shadows_real = 315,
    menu_music_volume = 316,
    menu_sfx_volume = 317,
    menu_on = 319,
    menu_off = 320,
    menu_volume = 321,
    menu_gamma = 322,
    menu_resume = 323,
    menu_disable = 324,
    menu_enable = 325,
    menu_disabled = 326,
    menu_enabled = 327,
    menu_voice_volume = 328,
    /// The hero stats window (viewer/gui/stats.zig).
    experience = 350,
    stat_hp = 351,
    stat_walk_range = 352,
    stat_luck = 353,
    stat_accuracy = 354,
    stat_counter = 355,
    stat_calmness = 356,
    stat_level = 360,
    game_over = 500,
    victory = 501,
    /// The party panel's buttons (core/classic.zig places).
    hint_inventory = 502,
    give = 503,
    hint_hand = 504,
    hint_short_list = 505,
    push = 506,
    hint_defend = 507,
    hint_turn = 508,
    hint_end_turn = 509,
    hint_skills = 510,
    hint_stats = 511,
    accept = 512,
    no_ammo = 513,
    out_of_range = 514,
    cannot_use = 515,
    counterattack = 516,
    player_turn = 517,
    enemy_turn = 518,
    luck = 519,
    miss = 520,
    skill_up = 521,
    to = 522,
    on = 523,
    level_up = 524,
    recharging = 525,
    /// A fighter's states in the battle hud (viewer/battle/hud.zig).
    state_tranquilized = 526,
    state_gassed = 527,
    state_bitten = 528,
    state_flammable = 529,
    state_enraged = 530,
    /// The defeat window: repeat the battle, yes, no (viewer/battle/gui.zig).
    retry_battle = 531,
    yes = 532,
    no = 533,
    /// The inventory: its places, tabs (weapons, medicine, other), buttons.
    torso = 550,
    hand = 551,
    picture = 552,
    tab_weapons = 553,
    tab_medicine = 554,
    tab_other = 555,
    exit = 556,
    weapons_skill = 557,
    /// An item's lines: health, armour, its protections (battle/immunity.zig pr_fields' order).
    hp = 560,
    armor = 561,
    protects_fire = 562,
    protects_electricity = 563,
    protects_decoy = 564,
    protects_energy = 565,
    protects_freeze = 566,
    protects_sleep = 567,
    protects_gas = 568,
    counter = 569,
    /// A weapon's lines: damage, then by armour class (light, medium, heavy); an armour
    /// class revealed in battle.
    damage = 570,
    armor_light = 571,
    armor_medium = 572,
    armor_heavy = 573,
    hp_short = 576,
    level_short = 577,
    special_skill = 574,
    healing = 575,
    exp = 578,
    /// A resistance revealed in battle (battle/immunity.zig Resist's order).
    resist_fire = 801,
    resist_electricity = 802,
    resist_attract = 803,
    resist_energy = 804,
    resist_freeze = 805,
    resist_tranq = 806,
    resist_gas = 807,
    resist_flammable = 808,
    /// The exe's system messages (its message boxes; OpenGorky shows none of them).
    sys_title = 900,
    sys_no_video = 901,
    sys_continue = 902,
    sys_sprites_failed = 904,
    sys_no_audio = 905,
    sys_continue_audio = 906,
    sys_loading = 907,
    sys_converting = 908,
    sys_out_of_memory = 909,
    sys_insert_disc = 910,
    sys_retry = 911,
    sys_abort = 912,
    sys_directx_failed = 913,
    sys_no_directx = 914,
    sys_no_hw_scaling = 915,
    sys_ok = 916,
    sys_cancel = 917,
    /// The edition's language number (formats/strtab.zig, formats/lang.zig).
    language = 950,
};

/// The core's number of `k` (its text's in entity.texts).
pub fn id(k: Key) i32 {
    return @backingInt(k);
}

/// The key's name (a project's `UiText(key = …)`, a `PanelPlace` hint).
pub fn keyName(k: Key) []const u8 {
    return @tagName(k);
}

/// The number of the text key `n` names (null: no such key).
pub fn idNamed(n: []const u8) ?i32 {
    return id(named(n) orelse return null);
}

/// The number of the `i`-th text of the group `first` starts (`of(.armor_light, 1)`: medium).
pub fn of(first: Key, i: usize) i32 {
    return id(first) + @as(i32, @intCast(i));
}

/// The key of number `n` (the converter's), if it is one.
pub fn keyOf(n: i32) ?Key {
    inline for (@typeInfo(Key).@"enum".field_names) |f| if (@backingInt(@field(Key, f)) == n) return @field(Key, f);
    return null;
}

/// The key named `name` (a project's `UiText(key = …)`), any case.
pub fn named(name: []const u8) ?Key {
    inline for (@typeInfo(Key).@"enum".field_names) |f| if (std.ascii.eqlIgnoreCase(f, name)) return @field(Key, f);
    return null;
}

test "groups follow the exe's ranges" {
    try std.testing.expectEqual(id(.armor_heavy), of(.armor_light, 2));
    try std.testing.expectEqual(id(.resist_flammable), of(.resist_fire, 7));
    try std.testing.expectEqual(id(.tab_other), of(.tab_weapons, 2));
    try std.testing.expectEqual(Key.miss, keyOf(520).?);
    try std.testing.expectEqual(Key.miss, named("Miss").?);
    try std.testing.expectEqual(@as(?i32, 502), idNamed(keyName(.hint_inventory)));
}
