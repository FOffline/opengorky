//! Interface and shell records (the "interface" core module, core/modules.zig `Ui`): the
//! party panel's buttons and portrait slots, the sliding windows' places, the main menu
//! scene's assets, the exe's video placements, its fixed music, sounds and animations,
//! speakers' portraits. The built-ins are the exe's, in the Classic reader
//! (core/classic.zig `ui`: table 0x52b388, 0x4af020…, 0x4134e0, 0x40fd06); the client draws them
//! (viewer/gui/panel.zig, gui/windows.zig, menu.zig, app/flow.zig).
//! An OpenGorky project's `rules\ui.ss` rows (`PanelPlace`, `Windows`, `MainMenu`,
//! `ExeVideo`, `ExeMusic`) write over them (composition: loaders/rules_text.zig).
//! shortcut: drawing offsets inside a button or window (health bar, hp text, rows) stay
//! the client's code.

const std = @import("std");

/// x0, y0, x1, y1 (inclusive; a panel's from its top).
pub const Rect = [4]f32;

/// A panel button: a control, or portrait slot `k` (`portrait(k)`: the k-th party member
/// in panel order, rules Campaign.panel_first).
pub const Button = enum(u8) {
    inventory,
    give,
    hand,
    short_list,
    push,
    defend,
    turn,
    end_turn,
    skills,
    stats,
    _,

    const portrait0 = 16;

    pub fn portrait(k: usize) Button {
        return @fromBackingInt(@as(u8, @intCast(portrait0 + k)));
    }

    /// The portrait slot (null: a control).
    pub fn slot(b: Button) ?usize {
        const i = @backingInt(b);
        return if (i >= portrait0) i - portrait0 else null;
    }
};

/// The frame drawn while pressed and its x offset (0x4b2380).
const Pressed = struct { frame: usize, dx: f32 };

pub const Place = struct {
    pub const call = "PanelPlace";
    pub const file = "ui";
    pub const keys = .{"button"};
    pub const doc =
        \\The party panel's places in the exe's order (table 0x52b388: hit test and drawing go
        \\in it): a control button or portrait slot "portrait0"…, its rectangle x0 y0 x1 y1, its
        \\hint (an interface text key, core/ui_text.zig), the frame drawn pressed and its x offset, the shutter frames over it.
    ;
    button: Button,
    rect: Rect,
    /// Hint: an interface text key (core/ui_text.zig: "hint_inventory"; "": none; a
    /// portrait shows the hero's name).
    hint: []const u8 = "",
    pressed: ?Pressed = null,
    /// Shutter frames min..max over it while inactive (0x6c6038), ±0.6 per tick.
    shutter: ?[2]f32 = null,
};

/// The bottom panel (0x4b1ab0/0x4b1d50/0x4b2440).
const Panel = struct {
    /// In the exe's order (hit test and drawing go in it). The portrait slots are as many
    /// as the places with `portrait(k)`: the exe's 5 (party members beyond them are in
    /// the party, rules Value `party_max` 6, not on the panel).
    places: []const Place,

    pub fn portraits(p: Panel) usize {
        var n: usize = 0;
        for (p.places) |pl| if (pl.button.slot() != null) {
            n += 1;
        };
        return n;
    }
};

/// A sliding window: opened at `at`, sliding in from `from` and back out to it (the
/// skills window only along x); `size` is its hit box.
pub const Window = struct { at: [2]f32, from: [2]f32, size: [2]f32 };

pub const Windows = struct {
    pub const call = "Windows";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\The sliding windows: skills and stats (where opened, slid from, their size), their
        \\places in the inventory and with level-up points.
    ;
    /// Weapon skills (`WeaponSkill.spr`, 0x4af020): from the panel; in the inventory at `skills_inventory`.
    skills: Window,
    skills_inventory: [2]f32,
    /// Hero stats (`HeroStats.spr`, 0x4af780): from the panel; in the inventory at
    /// `stats_inventory` (not sliding); with level-up points at `level_up`.
    stats: Window,
    stats_inventory: [2]f32,
    level_up: [2]f32,
};

/// The main menu's "flashlight" scene (0x4134e0, frame 0x416330): the breathing monster,
/// textures (`gfx_3d\textures\*.3df`; the logo is the campaign's), fonts (`<font>_<n>`
/// by the language's letters) and the item spacing (adjust.kdt `MENU_START_Y`,
/// `MENU_H_SPACE`).
pub const Menu = struct {
    pub const call = "MainMenu";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\The main menu's scene (0x4134e0): its model and animation, textures, fonts and the
        \\item spacing (adjust.kdt names and defaults).
    ;
    /// Model (`gfx_3d\<model>.msh`) and its animation.
    model: []const u8,
    anim: []const u8,
    light: []const u8,
    circle: []const u8,
    flare: []const u8,
    lens: []const u8,
    lens2: []const u8,
    arrow: []const u8,
    cursor: []const u8,
    font: []const u8,
    glow: []const u8,
    start_y: Adj,
    h_space: Adj,
};

/// An adjust.kdt integer and its default.
pub const Adj = struct { name: []const u8 = "", d: i32 };

/// Where the exe shows a video of its own (0x413386, 0x40fd06): screen place, doubled.
pub const Video = struct {
    pub const call = "ExeVideo";
    pub const file = "ui";
    pub const keys = .{"name"};
    pub const doc =
        \\Where the exe shows a video of its own (0x413386, 0x40fd06): screen place, doubled,
        \\with the caption (intro.spr frame 0).
    ;
    name: []const u8,
    x: i32,
    y: i32,
    double: bool,
    /// Shows the caption over it (intro.spr frame 0; the exe: introkon).
    caption: bool = false,
};

/// Music the exe names in its code.
pub const Music = struct {
    pub const call = "ExeMusic";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\Music the exe names in its code: the level-up window's, entering a battle, the
        \\battle's end jingles and report, a battle's music without its own or a district's
        \\(boss, else one of `battle` drawn: rand() % its count) and its enemy turn track.
    ;
    /// The level-up points window (0x48fa30).
    level_up: []const u8,
    /// Entering a battle from a location: the saw transition (0x41f0b0).
    battle_enter: []const u8,
    /// Battle over, 90 ticks later (combat/tick.zig): won, lost; the game-over screen too.
    victory: []const u8 = "",
    game_over: []const u8 = "",
    /// The after-battle report opens (viewer/battle/gui.zig).
    statistics: []const u8 = "",
    /// A battle's music when it has none of its own (game/life.zig, 0x41f9b0…0x41fab3):
    /// `boss` on a bossmonsterLevel, else one of `battle` ("a b": rand() % 2 in Classic).
    battle: []const u8 = "",
    boss: []const u8 = "",
    /// The drawn battle music's track during the enemy turn: its name and this (0x40edc0).
    enemy_suffix: []const u8 = "",
};

/// A district's shared music (0x41f9b0): a level without its own `<level>.mp3` whose name
/// contains `prefix` plays `track`; the first row that fits. OpenGorky: `level`, that one
/// level (its block's `music = "03_museum"`).
pub const District = struct {
    pub const call = "DistrictMusic";
    pub const file = "ui";
    pub const keys = .{ "prefix", "level" };
    pub const doc =
        \\A district's shared music (0x41f9b0): a level without its own music whose name
        \\contains `prefix` plays `track`; the first row that fits. level (OpenGorky, a
        \\level's `music` field): that level by name, not a prefix.
    ;
    prefix: []const u8 = "",
    level: []const u8 = "",
    track: []const u8,
};

/// Sounds the exe names in its code (`sounds\<name>`), by what plays them.
pub const Sounds = struct {
    pub const call = "UiSounds";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\Sounds the exe names in its code, by what plays them: hero selected, item given,
        \\picked, put, selected; the inventory's tabs; an explosion (barrel, bomb,
        \\a scene's rocket); no ammo; a stat point set; a box emptied; a safe key; healing
        \\(a man); the battle menus sliding in and out; a push (barrel, box); the main
        \\menu's click, typing, opening and accept.
    ;
    select_hero: []const u8 = "",
    give: []const u8 = "",
    item_choose: []const u8 = "",
    item_put: []const u8 = "",
    item_select: []const u8 = "",
    /// The inventory's tabs: weapons, items, keys.
    weapons_tab: []const u8 = "",
    items_tab: []const u8 = "",
    keys_tab: []const u8 = "",
    explosion: []const u8 = "",
    no_ammo: []const u8 = "",
    set_points: []const u8 = "",
    take_items: []const u8 = "",
    safe_key: []const u8 = "",
    /// Healing a man (`sex` 0; inventory/medicine.zig).
    heal: []const u8 = "",
    menu_slide_in: []const u8 = "",
    menu_slide_out: []const u8 = "",
    /// Pushing an explosive obstacle, any other (combat/devices.zig).
    push_barrel: []const u8 = "",
    push_box: []const u8 = "",
    click: []const u8 = "",
    keyboard: []const u8 = "",
    menu_open: []const u8 = "",
    key_accept: []const u8 = "",
    /// A miss, one of these at random ("miss01 miss02"; combat/strike.zig).
    miss: []const u8 = "",
    /// A walk click: a place the hero walks to, one it cannot (viewer/level.zig).
    walk_ok: []const u8 = "",
    walk_bad: []const u8 = "",
    /// The inventory button opening, closing (viewer/gui/panel.zig).
    inventory_open: []const u8 = "",
    inventory_close: []const u8 = "",
    /// An animation's sound cue that plays nothing (a silence placeholder; world/queue.zig).
    silence: []const u8 = "",
    /// Blood spilt (a hit's particles), one of these at random (fx/blood.zig).
    blood: []const u8 = "",
};

/// Effects the exe draws by name in its code (viewer/level/billboards.zig, effects_view.zig).
pub const Effects = struct {
    pub const call = "UiEffects";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\Effects the exe draws by name: a morph's sparks (0x4260a0: the effect, its half
        \\size by the actor scale, its colour); the mesh an effect frame is drawn on (a
        \\rocket's body and exhaust, 0x49bfb0).
    ;
    morph_sparks: []const u8 = "",
    morph_sparks_size: f32 = 80,
    morph_sparks_rgb: [3]f32 = .{ 1, 1, 1 },
    effect_mesh: []const u8 = "",
    /// An explosion's bitmap effect (fx/explosion.zig).
    explosion: []const u8 = "",
    /// Textures (`gfx_3d\\textures`): the selected hero's sparks, the facing arrows, the
    /// click and speaker marker, the active area's arrows, a shocked fighter's current,
    /// the battle grid.
    select_marker: []const u8 = "",
    facing_arrow: []const u8 = "",
    click_marker: []const u8 = "",
    area_marker: []const u8 = "",
    shock: []const u8 = "",
    grid: []const u8 = "",
};

/// The interface's own sprites and fonts the exe loads by name (asset paths: `sprites/…`,
/// `other/…`; fonts: `fonts/<name>.fnt`, a set's base `<name>_1` with the language's letters).
pub const Assets = struct {
    pub const call = "UiAssets";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\The interface's sprites and fonts the exe loads by name: the party panel, cursor,
        \\windows, inventory, the safe, the save and credits screens; the fonts (a set's
        \\base: `<name>_1.fnt` with the language's letters).
    ;
    panel: []const u8 = "",
    cursor: []const u8 = "",
    fighter_info: []const u8 = "",
    border: []const u8 = "",
    spinner: []const u8 = "",
    /// The glyph atlas the bitmap fonts below draw from.
    atlas: []const u8 = "",
    skills: []const u8 = "",
    intro: []const u8 = "",
    hero_stats: []const u8 = "",
    dialog_box: []const u8 = "",
    report: []const u8 = "",
    item_list: []const u8 = "",
    scrollbar: []const u8 = "",
    inventory: []const u8 = "",
    give_man: []const u8 = "",
    examine: []const u8 = "",
    examine_box: []const u8 = "",
    safe: []const u8 = "",
    save: []const u8 = "",
    credits: []const u8 = "",
    /// Fonts: health digits, the safe's, the 3D messages' set, the credits' set, the
    /// dialog's set, the small and system sets.
    hp_font: []const u8 = "",
    safe_font: []const u8 = "",
    msg_font: []const u8 = "",
    credits_font: []const u8 = "",
    dialog_font: []const u8 = "",
    small_font: []const u8 = "",
    system_font: []const u8 = "",
};

/// Animations the exe names in its code (raw names of the hero's model).
pub const Anims = struct {
    pub const call = "ExeAnims";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\Animations the exe plays by name: a hero selected in battle looks around (with a
        \\two-handed weapon in hand: the other), the party stops (STOP_HEROES).
    ;
    fight_look: []const u8 = "",
    fight_look_two_handed: []const u8 = "",
    /// A two-handed item put on the back and taken back (ActorPutBackItem, ActorPutFrontItem).
    hide_back: []const u8 = "",
};

/// The model's hold points (a `.msh` hold mode's name) the exe puts a weapon on: in one
/// hand, in both, on the back.
pub const Holds = struct {
    pub const call = "HoldPoints";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\The model's hold points the exe puts a weapon on: in one hand, in both, on the back.
    ;
    one_hand: []const u8 = "",
    two_hands: []const u8 = "",
    back: []const u8 = "",
};

/// A logical animation name and its slot (0x4280e0, any case): the actor's per-state
/// animation and walk speed tables (actor/slots.zig). Names of one slot are one animation
/// ("stair_up" in "stair_down"'s 13); a name of no row is slot 0.
pub const LookSlot = struct {
    name: []const u8,
    slot: u8,
};

/// A dialog speaker without an actor on the level: its portrait (`icons\<portrait>.spr`,
/// 0x459180); `prefix`: any speaker whose name starts with `name`.
pub const Speaker = struct {
    pub const call = "Speaker";
    pub const file = "ui";
    pub const keys = .{"name"};
    pub const doc =
        \\A dialog speaker without an actor on the level: its portrait (icons\<portrait>.spr,
        \\0x459180); prefix: any speaker whose name starts with `name`. The first that fits.
    ;
    name: []const u8,
    portrait: []const u8,
    prefix: bool = false,
};

/// A battle's grid floor for the cell highlights, `z` from the grid's own (0x454e6e).
pub const GridFloor = struct {
    pub const call = "GridFloor";
    pub const file = "ui";
    pub const keys = .{"level"};
    pub const doc =
        \\A battle level's grid floor for the cell highlights: z added to the grid's own
        \\(0x454e6e).
    ;
    level: []const u8,
    z: f32,
};

/// A port fix (not the exe's): in scene `scene`, while it waits for actor `actor`
/// (WAITFORACTOR), the repeats of its animation `anim` are cut (scene/scenario.zig).
pub const RepeatTrim = struct {
    pub const call = "RepeatTrim";
    pub const file = "ui";
    pub const keys = .{ "scene", "actor" };
    pub const doc =
        \\In scene `scene`, while it waits for actor `actor` (WAITFORACTOR), the repeats of
        \\its animation `anim` are cut: the loop playing ends, then the next command.
    ;
    scene: []const u8,
    actor: []const u8,
    anim: []const u8,
};

/// The interface's canvas (OpenGorky): the logical frame the world and the interface are
/// drawn in, scaled to the window. The exe's 640×480 art (the panel, the windows, the
/// menu, the inventory) keeps its pixels: the panel stands at the canvas's bottom, the
/// rest of the interface in a 640×480 box in its middle; the world fills the canvas.
pub const Canvas = struct {
    pub const call = "Canvas";
    pub const file = "ui";
    pub const keys = .{};
    pub const doc =
        \\The interface's canvas: the logical frame (at least 640×480) the world and the interface
        \\are drawn in, scaled to the window. The exe's art keeps its pixels: the bottom panel
        \\stands at the canvas's bottom centre, the other interface in the 640×480 box in its
        \\middle; the world fills the canvas (more of the background shows).
    ;
    width: i32 = 640,
    height: i32 = 480,
};

pub const Ui = struct {
    canvas: Canvas = .{},
    panel: Panel,
    windows: Windows,
    menu: Menu,
    videos: []const Video,
    music: Music,
    districts: []const District = &.{},
    sounds: Sounds = .{},
    anims: Anims = .{},
    effects: Effects = .{},
    assets: Assets = .{},
    holds: Holds = .{},
    speakers: []const Speaker = &.{},
    grid_floors: []const GridFloor = &.{},
};
