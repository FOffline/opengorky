//! Core modules: behaviour the exe keeps as code, not tables, behind one interface each.
//! `builtin_tables` is the exe's behaviour bit for bit; `tables()` is the set in force (as
//! rules.active): the heroes' classic_id special cases and the weapon class behaviour of
//! the battle code; the battle's turn and end rules; the strike effects as descriptions
//! (core/effect.zig); the fighter classes' behaviour (core/behaviour.zig) and the AI's
//! tile scorings (core/behaviour.zig `Scoring`, run by combat/ai.zig); the interface and
//! shell (core/ui.zig).
//! The records of the effects, fighters, AI and interface modules are data (`Tables`):
//! an OpenGorky project's rules files write over them (composition: loaders/rules_text.zig
//! → `use`), in force with the rules they came with (`rules.version`).
//! shortcut: the heroes' and battle's are the exe's functions only (the weapon kinds, the
//! panel order and the outcome rule are rules rows now); a project's own (data or hooks)
//! comes when a project needs it.

const std = @import("std");
const Who = @import("../rules.zig").Who;
const effect = @import("effect.zig");
const behaviour = @import("behaviour.zig");
const classic = @import("classic.zig");
const ui_mod = @import("ui.zig");
const fight = @import("fight.zig");
const rules = @import("../rules.zig");

/// A weapon class's own code in the battle: its rules WeaponClass row's `kind`.
pub const WeaponKind = rules.rows.WeaponKind;

/// A battle's fighters as its end rule counts them.
pub const Count = struct {
    /// Live heroes the player controls.
    heroes: usize,
    dead_heroes: usize,
    /// Live enemies.
    enemies: usize,
    /// The playthrough's rule (gorky-tool): only the whole party's death loses.
    lenient: bool,
};

const Outcome = enum { none, won, lost };

/// The modules' records as rules tables (one row each for the single ones).
pub const Tables = struct {
    weapon_fx: []const effect.Weapon,
    fighter_fx: []const effect.Fighter,
    classes: []const behaviour.Abilities,
    strikes: []const behaviour.Strike,
    scorings: []const behaviour.Scoring,
    places: []const ui_mod.Place,
    windows: []const ui_mod.Windows,
    menu: []const ui_mod.Menu,
    videos: []const ui_mod.Video,
    music: []const ui_mod.Music,
    materials: []const effect.Material,
    post: []const effect.PostChain,
    districts: []const ui_mod.District,
    sounds: []const ui_mod.Sounds,
    anims: []const ui_mod.Anims,
    effects: []const ui_mod.Effects,
    assets: []const ui_mod.Assets,
    holds: []const ui_mod.Holds,
    speakers: []const ui_mod.Speaker,
    grid_floors: []const ui_mod.GridFloor,
    transforms: []const fight.Transform,
    mid_dialogs: []const fight.MidDialog,
    devices: []const fight.Device,
    states: []const fight.StateEffect,
    repeat_trims: []const ui_mod.RepeatTrim,
    canvases: []const ui_mod.Canvas = &.{},
};

pub const builtin_tables: Tables = .{
    .weapon_fx = &classic.weapon_fx,
    .fighter_fx = &classic.fighter_fx,
    .classes = &classic.abilities,
    .strikes = &classic.strikes,
    .scorings = &classic.scorings,
    .places = classic.ui.panel.places,
    .windows = &.{classic.ui.windows},
    .menu = &.{classic.ui.menu},
    .videos = classic.ui.videos,
    .music = &.{classic.ui.music},
    .materials = &.{},
    .post = &.{.{}},
    .districts = classic.ui.districts,
    .sounds = &.{classic.ui.sounds},
    .anims = &.{classic.ui.anims},
    .effects = &.{classic.ui.effects},
    .assets = &.{classic.ui.assets},
    .holds = &.{classic.ui.holds},
    .speakers = classic.ui.speakers,
    .grid_floors = classic.ui.grid_floors,
    .transforms = &classic.transforms,
    .mid_dialogs = &classic.mid_dialogs,
    .devices = &classic.devices,
    .states = &classic.states,
    .repeat_trims = &classic.repeat_trims,
};

/// A project's tables (their rows in the rules' arena), in force with the rules in force;
/// `loaded_ui` is made from them, the one place of record being `Tables`.
var loaded_ui: ui_mod.Ui = classic.ui;
var loaded_tables: Tables = builtin_tables;
var loaded_version: ?u32 = null;

/// `t` in force, with the rules now in force (new rules: the built-ins again).
pub fn use(t: Tables) void {
    loaded_ui = .{
        // No row: the exe's 640×480.
        .canvas = if (t.canvases.len > 0) t.canvases[t.canvases.len - 1] else .{},
        .panel = .{ .places = t.places },
        .windows = last(t.windows, builtin_tables.windows),
        .menu = last(t.menu, builtin_tables.menu),
        .videos = t.videos,
        .music = last(t.music, builtin_tables.music),
        .districts = t.districts,
        .sounds = last(t.sounds, builtin_tables.sounds),
        .anims = last(t.anims, builtin_tables.anims),
        .effects = last(t.effects, builtin_tables.effects),
        .assets = last(t.assets, builtin_tables.assets),
        .holds = last(t.holds, builtin_tables.holds),
        .speakers = t.speakers,
        .grid_floors = t.grid_floors,
    };
    loaded_tables = t;
    loaded_version = rules.version;
    @import("../effects.zig").material.lookup = material;
}

fn last(xs: anytype, d: @TypeOf(xs)) @typeInfo(@TypeOf(xs)).pointer.child {
    if (xs.len > 0) return xs[xs.len - 1];
    rules.classicPath("modules.use: a built-in single row");
    return d[0];
}

/// The tables in force (the rules dump).
pub fn tables() Tables {
    if (loaded_version == rules.version) return loaded_tables;
    rules.classicPath("modules.tables: the built-ins");
    return builtin_tables;
}

/// The idle a lifted victim plays (state 3, 0x496f1f; the swap at 0x423355).
pub fn liftPose(w: Who) []const u8 {
    rules.classicPath("modules.liftPose");
    return classic.liftPose(w);
}

/// By the class's WeaponClass row (no row: plain).
pub fn weaponKind(class: i32) WeaponKind {
    return rules.weaponClass(class).kind;
}

/// The battle's end rule (combat/turns.zig asks it): won, lost or going on, checked at
/// every turn step (0x490620, 0x4983d0).
pub fn battleOutcome(c: Count) Outcome {
    return exeOutcome(c);
}

/// Fighter state `e`'s row (no row: it lasts no turns and deals nothing).
pub fn stateEffect(e: rules.Effect) fight.StateEffect {
    for (tables().states) |r| if (r.effect == e) return r;
    return .{ .effect = e };
}

/// The dialog after enemy turn `turn` on a battle of levelMode `mode`; null: none.
pub fn midDialog(mode: i32, turn: i32) ?*const fight.MidDialog {
    for (tables().mid_dialogs) |*r| if (r.mode == mode and r.turn == turn) return r;
    return null;
}

/// The transformation on a battle of levelMode `mode`; null: none.
pub fn transform(mode: i32) ?*const fight.Transform {
    for (tables().transforms) |*r| if (r.mode == mode) return r;
    return null;
}

/// The device of kind `k` (null: the battle places none).
pub fn device(k: fight.DeviceKind) ?*const fight.Device {
    for (tables().devices) |*r| if (r.kind == k) return r;
    return null;
}

/// A barrel's blast shows (explosion, sound) by its weapon's classic_id (classic.blastShown),
/// when the barrel has no `explodable` of its own.
pub fn blastShown(weapon: i32) bool {
    rules.classicPath("modules.blastShown");
    return classic.blastShown(weapon);
}

/// An OpenGorky project's answer to battleNamed (loaders/ogs.zig `isBattle`: its `battle`
/// blocks); null: Classic.
pub var battle_named: ?*const fn ([]const u8) bool = null;

/// Level `lv` is a battle by its name (classic.battleNamed: the exe's "__"; an OpenGorky
/// project: a `battle` block), before it loads.
pub fn battleNamed(lv: []const u8) bool {
    if (rules.og) if (battle_named) |f| return f(lv);
    rules.classicPath("modules.battleNamed");
    return classic.battleNamed(lv);
}

/// Scenes' animation repeats the port cuts (RepeatTrim rows; scene/scenario.zig).
pub fn repeatTrims() []const ui_mod.RepeatTrim {
    return tables().repeat_trims;
}

/// Speaker `name`'s portrait when it has no actor (the first Speaker row that fits).
pub fn speakerPortrait(name: []const u8) ?[]const u8 {
    for (ui().speakers) |r| if (if (r.prefix) std.ascii.startsWithIgnoreCase(name, r.name) else std.ascii.eqlIgnoreCase(name, r.name)) return r.portrait;
    return null;
}

/// Battle `lv`'s grid floor offset for the cell highlights (0: none).
pub fn gridFloor(lv: []const u8) f32 {
    for (ui().grid_floors) |r| if (std.ascii.eqlIgnoreCase(r.level, lv)) return r.z;
    return 0;
}

/// Level `lv`'s district music (the first DistrictMusic row whose prefix its name
/// contains); null: none.
pub fn districtMusic(lv: []const u8) ?[]const u8 {
    for (ui().districts) |r| if (if (r.level.len > 0) std.ascii.eqlIgnoreCase(r.level, lv) else r.prefix.len > 0 and std.mem.indexOf(u8, lv, r.prefix) != null) return r.track;
    return null;
}

/// The effects of game weapon `id` for attacker classic_id `who` (the first record that fits).
pub fn weaponFx(id: i32, who: i32) ?*const effect.Weapon {
    for (tables().weapon_fx) |*r| if (num(r.id, r.id_class) == id and (num(r.who, r.who_class) == 0 or num(r.who, r.who_class) == who)) return r;
    return null;
}

/// A row's key: its number, or the core's number of the archetype it names instead (an
/// OpenGorky project's, entity.idOf; an archetype the project lacks: none, −1).
fn num(n: i32, class: []const u8) i32 {
    if (class.len == 0) return n;
    return @import("entity.zig").idOf(class) orelse -1;
}

/// Material `name` (a mod's; core/effect.zig Material), the last row of that name.
pub fn material(name: []const u8) ?*const effect.Material {
    const ms = tables().materials;
    var i = ms.len;
    while (i > 0) : (i -= 1) if (std.mem.eql(u8, ms[i - 1].name, name)) return &ms[i - 1];
    return null;
}

/// The frame's post-processing steps on level `lv`: its own PostChain row, else (a battle)
/// its location's own, else the global one; none built in, so none in Classic.
pub fn postSteps(lv: []const u8) []const effect.Post {
    return stepsIn(tables().post, starts, lv);
}

/// Level `lv`'s own PostChain row ("": the global one); null: none.
pub fn postChain(lv: []const u8) ?*const effect.PostChain {
    return chainIn(tables().post, lv);
}

/// Battle `lv`'s location's own PostChain row (`locationOf`); null: not a battle started
/// from a location's scripts, or its location has none.
pub fn postLocation(lv: []const u8) ?*const effect.PostChain {
    return locationIn(tables().post, starts, lv);
}

/// A battle level and a location whose scripts start it: LEVEL_Load / LEVEL_LoadAB of it,
/// or StartScriptlet of a scene that LOADLEVELs it (a battle started from a battle: that
/// battle's location). loaders.openGame reads them from the game's scripts.
pub const Start = struct { battle: []const u8, location: []const u8 };

/// The loaded game's battle starts, in level order (none: Classic, which needs none).
pub var starts: []const Start = &.{};

/// Battle `lv`'s location: the first (in level order) whose scripts start it; null: none.
pub fn locationOf(lv: []const u8) ?[]const u8 {
    return startIn(starts, lv);
}

fn startIn(ss: []const Start, lv: []const u8) ?[]const u8 {
    for (ss) |s| if (std.ascii.eqlIgnoreCase(s.battle, lv)) return s.location;
    return null;
}

fn chainIn(rows: []const effect.PostChain, lv: []const u8) ?*const effect.PostChain {
    for (rows) |*r| if (std.ascii.eqlIgnoreCase(r.level, lv)) return r;
    return null;
}

fn locationIn(rows: []const effect.PostChain, ss: []const Start, lv: []const u8) ?*const effect.PostChain {
    return chainIn(rows, startIn(ss, lv) orelse return null);
}

fn stepsIn(rows: []const effect.PostChain, ss: []const Start, lv: []const u8) []const effect.Post {
    return (chainIn(rows, lv) orelse locationIn(rows, ss, lv) orelse chainIn(rows, "") orelse return &.{}).steps;
}

test "post chain: a level's own, else its location's (a battle), else the global one; none built in" {
    const g = [_]effect.Post{.{ .program = .vignette }};
    const own = [_]effect.Post{ .{ .program = .grade }, .{ .program = .scanlines } };
    const bat = [_]effect.Post{ .{ .program = .grade }, .{ .program = .grade }, .{ .program = .grade } };
    const rows = [_]effect.PostChain{ .{ .steps = &g }, .{ .level = "01_port_castle", .steps = &bat }, .{ .level = "01_port", .steps = &own }, .{ .level = "01__port_heavy", .steps = &bat } };
    // Started by scripts, not by name: 01__port_park from 01_port (first), 03__museum_chopper
    // from 03_museum_observator (no row), not from 03_museum.
    const ss = [_]Start{ .{ .battle = "01__port_park", .location = "01_port" }, .{ .battle = "01__port_park", .location = "01_port_castle" }, .{ .battle = "03__museum_chopper", .location = "03_museum_observator" } };
    try std.testing.expectEqual(@as(usize, 2), stepsIn(&rows, &ss, "01_PORT").len);
    try std.testing.expectEqual(@as(usize, 1), stepsIn(&rows, &ss, "03_museum").len);
    // A battle with no row of its own: its first location's, its own first.
    try std.testing.expectEqual(@as(usize, 2), stepsIn(&rows, &ss, "01__PORT_PARK").len);
    try std.testing.expectEqualStrings("01_port", locationIn(&rows, &ss, "01__port_park").?.level);
    try std.testing.expectEqual(@as(usize, 3), stepsIn(&rows, &ss, "01__port_heavy").len);
    // Its location without a row, or no script starting it: the global one; a location has no location.
    try std.testing.expectEqual(@as(usize, 1), stepsIn(&rows, &ss, "03__museum_chopper").len);
    try std.testing.expectEqualStrings("03_museum_observator", startIn(&ss, "03__museum_chopper").?);
    try std.testing.expectEqual(@as(usize, 1), stepsIn(&rows, &ss, "01__port_barge").len);
    try std.testing.expect(locationIn(&rows, &ss, "01_port_castle") == null);
    try std.testing.expect(chainIn(&rows, "03_museum") == null);
    // Classic (the built-ins): nothing on any level.
    try std.testing.expectEqual(@as(usize, 0), stepsIn(builtin_tables.post, &ss, "01_port").len);
    try std.testing.expectEqual(@as(usize, 0), stepsIn(builtin_tables.post, &ss, "01__port_park").len);
    try std.testing.expectEqual(@as(usize, 0), stepsIn(builtin_tables.post, &ss, "").len);
}

/// Fighter classic_id `fighter`'s own effects with weapon `weapon` (a 0 record: any weapon).
pub fn fighterFx(fighter: i32, weapon: i32) ?*const effect.Fighter {
    for (tables().fighter_fx) |*r| if (num(r.fighter, r.fighter_class) == fighter and (num(r.weapon, r.weapon_class) == 0 or num(r.weapon, r.weapon_class) == weapon)) return r;
    return null;
}

/// The interface and shell (core/ui.zig: the panel, windows, main menu, videos, music).
pub fn ui() *const ui_mod.Ui {
    if (loaded_version == rules.version) return &loaded_ui;
    rules.classicPath("modules.ui: the built-ins");
    return &classic.ui;
}

/// Fighter object `o`'s Abilities row, hero or enemy: its own (by its object name — Classic
/// too —, class or classic_id), else what its script fields give (classic.fromFields), else its
/// classType's (an ordinary fighter when none). Read where its components are attached
/// from it (core/natives.zig as the object is made, combat/events.zig its scripted ones for
/// a battle); the battle asks their traits, not the row.
pub fn abilityRow(o: *@import("../script.zig").object.Object) *const behaviour.Abilities {
    var w = rules.who(o);
    w.obj = o.name;
    if (ownAbilities(w)) |r| return r;
    // OpenGorky: no field rule of the exe's; the converter writes such a fighter's row.
    if (!rules.og) if (classic.fromFields(o)) |r| return r;
    return abilities(w, o.getInt("battle_class"));
}

/// Fighter `w`'s own abilities row (its object's, class's, then classic_id's), else its
/// classType `class`'s (an ordinary fighter when none).
pub fn abilities(w: Who, class: i32) *const behaviour.Abilities {
    if (ownAbilities(w)) |r| return r;
    for (tables().classes) |*r| if (r.fighter == 0 and r.fighter_class.len == 0 and rules.rowClass(r.*) == class) return r;
    return &behaviour.plain;
}

fn ownAbilities(w: Who) ?*const behaviour.Abilities {
    var own: ?*const behaviour.Abilities = null;
    var score: u2 = 0;
    for (tables().classes) |*r| if (r.fighter != 0 or r.fighter_class.len > 0) if (rules.keyMatch(r.*, "fighter", w)) |m| if (m > score) {
        own = r;
        score = m;
    };
    return own;
}

/// A fighter's own strike `special`'s behaviour (null: none).
pub fn fighterStrike(special: i32) ?*const behaviour.Strike {
    for (tables().strikes) |*r| if (@import("entity.zig").refId(r.special, r.special_class) == special) return r;
    return null;
}

/// The AI's scoring for profile `eval`.
pub fn aiScoring(e: rules.AiEval) *const behaviour.Scoring {
    for (tables().scorings) |*r| if (std.ascii.eqlIgnoreCase(r.eval, e)) return r;
    rules.classicPath("modules.aiScoring: the built-in default");
    return &classic.scorings[0];
}

/// Any hero's death ends the game (0x490620 → GUI_GameOver; rules Value(lose_on_hero_death)
/// 0: only the whole party's), leniently only the whole party's; defeat is checked before
/// victory (a bomb); victory: no enemy alive (0x4983d0).
fn exeOutcome(c: Count) Outcome {
    const any = !c.lenient and rules.value(.lose_on_hero_death) != 0;
    const lost = (any and c.dead_heroes > 0) or c.heroes == 0;
    return if (lost) .lost else if (c.enemies == 0) .won else .none;
}

test "modules: the built-ins are the exe's special cases" {
    try std.testing.expectEqualStrings("deliriumA", liftPose(.{ .id = 29 }));
    try std.testing.expectEqualStrings("delirium", liftPose(.{ .id = 20 }));
    try std.testing.expectEqual(.energy, weaponKind(7));
    try std.testing.expectEqual(.sleep_ball, weaponKind(1005));
    try std.testing.expectEqual(.plain, weaponKind(2));
    try std.testing.expectEqual(.plain, weaponKind(4242));
    const burn = stateEffect(.burn);
    try std.testing.expectEqual([5]i32{ 15, 10, 5, 0, 0 }, [5]i32{ burn.damageAt(3), burn.damageAt(2), burn.damageAt(1), burn.damageAt(0), burn.damageAt(4) });
    try std.testing.expectEqual(20, stateEffect(.bite).damageAt(0));
    try std.testing.expectEqual(0, stateEffect(.defend).damageAt(1));
    try std.testing.expectEqualStrings("04__city_mfd.dlg", midDialog(7, 1).?.dialog_file);
    try std.testing.expect(midDialog(7, 2) == null and midDialog(10, 2) != null);
    try std.testing.expectEqual(100, transform(8).?.delay);
    try std.testing.expectEqualStrings("Lamare", speakerPortrait("LAMAR_2").?);
    try std.testing.expect(speakerPortrait("HQ2") == null);
    try std.testing.expectEqualStrings("01_port", districtMusic("01_port_silos").?);
    try std.testing.expect(districtMusic("04_city") == null);
    try std.testing.expectEqual(.lost, battleOutcome(.{ .heroes = 2, .dead_heroes = 1, .enemies = 0, .lenient = false }));
    try std.testing.expectEqual(.none, battleOutcome(.{ .heroes = 2, .dead_heroes = 1, .enemies = 1, .lenient = true }));
    try std.testing.expectEqual(.won, battleOutcome(.{ .heroes = 2, .dead_heroes = 1, .enemies = 0, .lenient = true }));
    try std.testing.expectEqual(26, weaponFx(1022, 26).?.who);
    try std.testing.expectEqual(0, weaponFx(1022, 20).?.who);
    try std.testing.expect(weaponFx(4242, 0) == null);
    try std.testing.expectEqual(.beam, std.meta.activeTag(fighterFx(119, 2).?.hit[0]));
    try std.testing.expectEqual(.attach, std.meta.activeTag(fighterFx(119, 1021).?.hit[0]));
    try std.testing.expect(fighterFx(131, 2) == null);
    try std.testing.expect(abilities(.{ .id = 1 }, 11).double_turn and !abilities(.{ .id = 1 }, 13).double_turn);
    try std.testing.expect(abilities(.{ .id = 0 }, 5).monitor and !abilities(.{ .id = 0 }, 5).kill_credit and abilities(.{ .id = 1 }, 100).kill_credit);
    // The exe's special cases by classic_id and object name are rows: Medusa, the Invisible.
    try std.testing.expect(abilities(.{ .id = 119 }, 0).no_push and abilities(.{ .id = 119 }, 0).battle_only and !abilities(.{ .id = 20 }, 0).no_push);
    try std.testing.expect(abilities(.{ .id = 120 }, 0).invisible and !abilities(.{ .id = 120 }, 0).leaves);
    try std.testing.expect(abilities(.{ .id = 120, .obj = "04MF_invisible1" }, 0).leaves and abilities(.{ .id = 120, .obj = "04mf_invisible1" }, 0).invisible);
    try std.testing.expectEqual(2, fighterStrike(118).?.spins.len);
    try std.testing.expect(fighterStrike(119) == null);
    try std.testing.expect(aiScoring("smokerider").wakeful and !aiScoring("generic").wakeful);
    try std.testing.expectEqual(.no_lock, aiScoring("cripple").occupant);
}
