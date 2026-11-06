//! Host schemas: the fields the engine gives every object of a kind, from
//! the original's base classes (`common/other.dat: classes\gameobject.s actor.s …`), plus
//! the port's own fields (`only_og`). A field's default is its type's initial value (the
//! exe declares, never initialises, them). `gorky-tool roundtrip` checks the Classic
//! fields against the game's base classes, name, type and order. OG Script's data blocks
//! are checked against these (`script/ogs/link.zig`): a field's type of the engine's
//! prelude (`engine.ogs`: the enum `ItemPlace` of `place = hand`, the struct `Place` of
//! `placement = [Place(…)]`; foundation/types.ogs), a reference's kind.

const std = @import("std");
const script = @import("../script.zig");
const ir = script.ir;
const Type = script.ir.Type;
const Value = script.value.Value;
const link = script.ogs.link;
const classic_names = script.classic.names;

pub const Field = struct {
    name: []const u8,
    type: Type,
    /// Not the exe's: read by the port only (an OpenGorky project or the generic fighter).
    only_og: bool = false,
    /// The exe's, not OG Script's: the object has it, a block cannot set it (a weapon's
    /// `ammo` number: OG Script's `ammo` is a reference, or `thrown`).
    only_classic: bool = false,
    /// OG Script data: the type of the prelude it takes (`ItemPlace`: an int field's enum,
    /// its values' numbers, other numbers stay valid; `list<Place>`, `Camera`: the OG
    /// reader's records, a value of the struct as the object's variable too).
    type_name: []const u8 = "",
    /// OG Script data: the field names a block of this kind (`explodeWeapon = weapons::x`).
    ref: script.ir.Sigil = .none,
    /// The ancestor's field it takes the place of (a weapon's `damage_kind`, an item's
    /// `kind`: the exe's one `type`).
    replaces: []const u8 = "",
    /// An int the exe reads as 0/1: OG Script writes `true`/`false` (the converter, the
    /// editor).
    flag: bool = false,
    /// `only_classic` whose value OpenGorky does not carry: no reader (`ctrlPoint*`, a level's `scale`, `grid`, `range_effect`…), or
    /// carried as another field (`attackEffectDelay`: the generic fighter's weapon's
    /// `hit_delay`). The converter writes none, `convert-check` compares none.
    dropped: bool = false,
    /// OG Script data: a shape the OG reader reads itself (`tile = [2, 9]`; world/start.zig),
    /// no object variable's value.
    check: ?link.Check = null,
    /// OG Script data: rules rows of the block (`report_icon = "garcia"`, `ai = AiProfile(…)`,
    /// `strikes = [MonsterAttack(…)]`): the OG reader makes them rows keyed by the block
    /// (loaders/rules_text.zig block_rows), no object variable.
    rows: bool = false,

    pub fn default(self: Field) Value {
        return .initial(self.type);
    }
};

pub const Host = struct {
    /// The base class (`fighter` is `classes\fighter.s`).
    name: []const u8,
    /// Its `#inherit`: its fields come first.
    parent: ?[]const u8,
    /// Own fields in the base class's order, then the port's.
    fields: []const Field,
};

fn f(name: []const u8, t: Type) Field {
    return .{ .name = name, .type = t };
}

fn og(name: []const u8, t: Type) Field {
    return .{ .name = name, .type = t, .only_og = true };
}

/// The engine's enum `name` (`ItemPlace`) as the prelude declares it (script/traits.zig
/// `types`, parsed in `a`); null: none.
pub fn engineEnum(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?*const ir.Enum {
    var d: script.ogs.parser.Diagnostic = .{};
    const u = script.ogs.parser.parse(a, script.traits.types, "engine.ogs", &d) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // the prelude parses (tests/script.zig)
    };
    for (u.modules[0].enums) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// A field of a type of the prelude (`typed("place", .int, "ItemPlace")`).
fn typed(name: []const u8, t: Type, type_name: []const u8) Field {
    return .{ .name = name, .type = t, .type_name = type_name, .only_og = t == .any };
}

fn ints(comptime names: []const []const u8) [names.len]Field {
    var out: [names.len]Field = undefined;
    for (names, &out) |n, *o| o.* = f(n, .int);
    return out;
}

/// Fields OpenGorky does not carry (`Field.dropped`).
fn dropped(comptime t: Type, comptime names: []const []const u8) [names.len]Field {
    var out: [names.len]Field = undefined;
    for (names, &out) |n, *o| o.* = .{ .name = n, .type = t, .only_classic = true, .dropped = true };
    return out;
}

/// Ints the exe reads as 0/1 (`Field.flag`).
fn flags(comptime names: []const []const u8) [names.len]Field {
    var out: [names.len]Field = undefined;
    for (names, &out) |n, *o| o.* = .{ .name = n, .type = .int, .flag = true };
    return out;
}

fn floats(comptime names: []const []const u8) [names.len]Field {
    var out: [names.len]Field = undefined;
    for (names, &out) |n, *o| o.* = f(n, .float);
    return out;
}

const resist_names = [_][]const u8{ "resist_fire", "resist_electricity", "resist_decoy", "resist_energy", "resist_freeze", "resist_sleep", "resist_gas" };
/// Worn armour's protections (inventory/equipment.zig armorProtects: the `pr*` fields).
const resist = ints(&.{"armor"}) ++ flags(&resist_names);
/// A fighter's: its armour; the exe's `pr*` it keeps from Fighter.s no reader (its
/// resistances are its Resist row, `immunity`).
const fighter_resist = [_]Field{typed("armor", .int, "ArmorClass")} ++ dropped(.int, &resist_names);
const xyz = floats(&.{ "x", "y", "z", "angle", "scale" });

/// Most derived first (`hostOf` picks the first a class declares completely).
pub const hosts = [_]Host{
    // The grid fields: no reader (the grid is the `.cm`'s, core/map.zig CombatMap).
    // `isCombat`: the exe's class marker (a battle level's `.lev` declares it); OpenGorky's
    // is the block's kind `battle`.
    .{ .name = "combatlevel", .parent = "level", .fields = &([_]Field{rowsField("transform")} ++ ints(&.{ "grid_columns", "grid_rows" }) ++ floats(&.{ "grid_origin_x", "grid_origin_y", "grid_origin_z", "grid_rotation_radians", "grid_width", "grid_height" }) ++
        [_]Field{.{ .name = "isCombat", .type = .int, .only_classic = true }} ++ ints(&.{ "turn", "enemies_killed" })) },
    .{
        .name = "level",
        .parent = "gameobject",
        // The exe's, no reader (Classic only): `ctrlPoint*` (a debug triangle), `scale`, `grid`.
        .fields = &(dropped(.float, &.{ "ctrlPoint1X", "ctrlPoint1Y", "ctrlPoint1Z", "ctrlPoint2X", "ctrlPoint2Y", "ctrlPoint2Z", "ctrlPoint3X", "ctrlPoint3Y", "ctrlPoint3Z" }) ++
            flags(&.{"perspective"}) ++
            floats(&.{ "near_plane", "far_plane", "ortho_rotation_radians", "eye_x", "eye_y", "eye_z", "target_x", "target_y", "target_z", "fov" }) ++ dropped(.float, &.{"scale"}) ++
            floats(&.{ "actor_scale", "speed_scale", "floor_z", "camera_scale", "aspect_ratio", "camera_bank" }) ++
            dropped(.int, &.{"grid"}) ++ ints(&.{ "progress", "mode" }) ++ flags(&.{ "shadows", "boss" }) ++ [_]Field{ rowsField("grid_floor"), rowsField("music") } ++
            // The OG reader's: initCamera()'s values as one record, restore()'s PlaceActor as `placement`.
            [_]Field{ typed("camera", .any, "Camera"), typed("placement", .any, "list<Place>"), entry_field, dialog_field }),
    },
    .{
        .name = "weapon",
        .parent = "item",
        // No reader: `min_damage`, `range`, `max_range`, `blast_radius`, `move_penalty`,
        // `accuracy_bonus`; the exe's, Classic only (no reader, meaning unknown):
        // `range_effect`, `dist_effect`, `near_effect`. `attackEffectDelay`:
        // read for the generic fighter only (battle/attacks.zig genericAttack), OpenGorky's
        // is its weapon's `hit_delay` (the converter's).
        .fields = &(class_fields ++ flags(&.{"secondary"}) ++ ints(&.{ "max_damage", "min_damage", "range", "max_range", "blast_radius" }) ++
            floats(&.{"move_penalty"}) ++
            ints(&.{"accuracy_bonus"}) ++ dropped(.int, &.{ "range_effect", "dist_effect", "near_effect" }) ++ flags(&.{"long_attack"}) ++ dropped(.int, &.{"attackEffectDelay"}) ++
            [_]Field{.{ .name = "ammo", .type = .int, .only_classic = true }} ++
            ints(&.{ "bonus_experience", "light_armor_pct", "medium_armor_pct", "heavy_armor_pct" }) ++
            // battle/weapon_class.zig (rules MonsterAttack attack_zone), battle/generic.zig.
            // combat/devices.zig: a barrel holding it shows its blast (fields.zig explodable).
            [_]Field{ .{ .name = "attack_zone", .type = .any, .only_og = true, .check = checkWeaponClass }, effectsField("effects_from"), og("explodable", .int), rowsField("skill_icon"), rowsField("weapon_sound"), rowsField("flags"), rowsField("fx"), rowsField("hero_attack"), rowsField("class_rules"), rowsField("class_zone"), rowsField("device"), rowsField("flame"), rowsField("rocket_trail"), rowsField("ball"), rowsField("grenade"), rowsField("shock") } ++
            // Its strike's stages each of another weapon (Classic: the rules' FxAs row).
            [_]Field{ effectsField("flash_from"), effectsField("launch_from"), effectsField("hit_from"), og("hit_sound", .string) } ++
            // The exe's one `type`: an item's kind, a weapon's damage kind (battle/immunity.zig DamageType).
            [_]Field{.{ .name = "damage_kind", .type = .int, .type_name = "WeaponKind", .replaces = "kind" }} ++
            // Its ammo by archetype (`ammo = ~i"items::riffleammo"`) or `thrown = true`: the
            // OG reader sets the number `ammo` to that item's classic_id, or −1 (world/start.zig).
            [_]Field{ ammo_field, thrown_field }),
    },
    // Kept as the exe's: `two_handed` (0, 1, and 2 on monsters' weapons: not a flag); the
    // exe's, Classic only: `effect_time` (no reader).
    .{ .name = "item", .parent = "gameobject", .fields = &(xyz ++ [_]Field{rowsField("medicine")} ++ ints(&.{"walk_block_radius"}) ++
        [_]Field{ f("owner", .string), f("icon", .string), f("mesh", .string), f("use_anim", .string) } ++
        ints(&.{ "approach_x", "approach_y" }) ++ floats(&.{"approach_angle"}) ++
        [_]Field{ typed("place", .int, "ItemPlace"), f("two_handed", .int), typed("kind", .int, "ItemKind") } ++ resist ++
        flags(&.{"resist_flammable"}) ++ ints(&.{ "hp", "count" }) ++ dropped(.int, &.{"effect_time"}) ++ ints(&.{"effect_power"}) ++ flags(&.{"visible"}) ++ actionFields(0)) },
    .{
        .name = "fighter",
        .parent = "actor",
        // Kept as the exe's: `calmness` (no reader); Classic only: `actRot`
        // (no reader).
        .fields = &([_]Field{
            // A key of the rules rows: Classic the exe's classType, OpenGorky the class's name
            // (`battle_class = smokerider`; rules.fighterClassId numbers it, world/start.zig).
            .{ .name = "battle_class", .type = .int, .only_classic = true },
            .{ .name = "battle_class", .type = .any, .only_og = true, .check = checkFighterClass },
            rowsField("report_icon"),
            rowsField("immunity"),
            rowsField("ai"),
            rowsField("class_ai"),
            // Its AI profile (`ai_profile = ai::garcia`: that block's AiProfile row by it).
            rowsField("ai_profile"),
            rowsField("abilities"),
            rowsField("class_abilities"),
            rowsField("glow"),
            rowsField("device"),
            rowsField("strikes"),
            rowsField("strike_fx"),
            rowsField("chatter"),
            rowsField("hidden_weapons"),
            rowsField("spins"),
            rowsField("extra_wait"),
            rowsField("bonus"),
        } ++ ints(&.{ "hp", "max_hp", "walk_range" }) ++
            floats(&.{ "accuracy", "luck", "counter_attack" }) ++
            ints(&.{ "rage", "max_rage", "experience", "level", "calmness", "footprint_tiles" }) ++ flags(&.{ "movable", "explosive" }) ++
            [_]Field{.{ .name = "blast_weapon", .type = .string, .ref = .weapon }} ++
            dropped(.int, &.{"actRot"}) ++ [_]Field{typed("ai_mode", .int, "AiMode")} ++ flags(&.{ "move_locked", "attack_locked", "outside_party" }) ++
            ints(&.{ "ai_threat_weight", "ai_attack_weight", "ai_guard_distance_weight", "ai_opponent_distance_weight" }) ++ fighter_resist ++
            // fields.zig explodable, battle/generic.zig ai; resistances and armour class: `immunity` (Resist).
            [_]Field{ og("explodable", .int), og("ai", .string) }),
    },
    .{
        .name = "actor",
        .parent = "gameobject",
        .fields = &(xyz ++ floats(&.{"turn_speed"}) ++ [_]Field{ f("portrait", .string), f("mesh", .string), typed("gender", .int, "Gender") } ++
            // The OG reader's: its look, its battle tile (PlaceActor in restore()).
            [_]Field{ .{ .name = "look", .type = .string, .only_og = true, .ref = .look }, tile_field, at_field, rowsField("report_icon") }),
    },
    .{ .name = "activebitmapanimation", .parent = "bitmapanimation", .fields = &(ints(&.{"state"}) ++ flags(&.{"one_shot"})) },
    .{ .name = "bitmapanimation", .parent = "gameobject", .fields = &(ints(&.{ "pos_x", "pos_y", "frames_per_second", "frame" }) ++ [_]Field{ f("sprite", .string), f("depth_sprite", .string), f("prev_frame", .int) }) },
    .{ .name = "activearea", .parent = "gameobject", .fields = &([_]Field{f("areaName", .string)} ++ ints(&.{"isLevelSwitch"}) ++ actionFields(0) ++ flags(&.{ "hint_hidden", "examine_hidden" }) ++ actionFields(1) ++ actionFields(2) ++ actionFields(3)) },
    .{ .name = "animation", .parent = null, .fields = &ints(&.{"x"}) },
    .{ .name = "model", .parent = null, .fields = &ints(&.{"x"}) },
    .{ .name = "gameobject", .parent = null, .fields = &(ints(&.{"classic_id"}) ++ [_]Field{ textField("name"), textField("examine"), same_as_field, pickable_field }) },
};

pub fn host(name: []const u8) ?*const Host {
    for (&hosts) |*h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h;
    return null;
}

/// A host's fields with its ancestors' first, as the base class declares them after its
/// `#inherit` (`only_og`: as OG Script sees them: the port's too, no `only_classic` one).
pub fn fields(a: std.mem.Allocator, h: *const Host, only_og: bool) std.mem.Allocator.Error![]const Field {
    var out: std.ArrayList(Field) = .empty;
    if (h.parent) |p| try out.appendSlice(a, try fields(a, host(p).?, only_og));
    // A field the host declares again (a weapon's `type`) takes its ancestor's place.
    for (h.fields) |x| if (if (only_og) !x.only_classic else !x.only_og) for (out.items) |*y| {
        if (std.ascii.eqlIgnoreCase(y.name, x.name) or std.mem.eql(u8, y.name, x.replaces)) {
            y.* = x;
            break;
        }
    } else try out.append(a, x);
    return out.items;
}

/// A look (`look grandma`, the Classic `act_*.ss`): an actor's model and animations, put
/// on the actor before its archetype's fields (world/start.zig). No base class of the
/// exe's (not in `hosts`): `mesh`, `portrait`, `turn_speed` are the actor's;
/// `walk`, `idles`, `slots` are ActorSetWalkSpeed, RegisterIdleAnimation, RegisterAnimation;
/// `not_in_place`, `reference` a hero's NotInPlaceAnimation, ReferenceAnimation.
/// Its battle tile: restore()'s PlaceActor(name, x, y[, direction]) as data (`[x, y]` or
/// `[x, y, direction]`; world/start.zig placeModel).
const tile_field: Field = .{ .name = "tile", .type = .any, .only_og = true, .check = checkTile };
/// Where on the battle grid a prop stands: restore()'s PlaceCombatActor (`battle::PlaceProp`)
/// as data, `[x, y, angle]` (grid units, a tile's corner whole; degrees; placeModel).
const at_field: Field = .{ .name = "at", .type = .any, .only_og = true, .check = checkAt };

/// An `obstacle` block (`.obs`: an actor of the runtime, of no Classic base class of its
/// own): its object's fields are `var`s, its battle placement the actor's (`tile`,
/// `at`). Not in `hosts`: no class declares it (`hostOf`, the schema check).
const obstacle_host: Host = .{ .name = "obstacle", .parent = "gameobject", .fields = &.{ tile_field, at_field } };

const look_host: Host = .{
    .name = "look",
    .parent = null,
    .fields = &[_]Field{
        og("mesh", .string),
        og("portrait", .string),
        og("turn_speed", .float),
        typed("walk", .any, "list<Speed>"),
        typed("idles", .any, "list<Idle>"),
        typed("slots", .any, "list<Slot>"),
        // A hero's postinit(): NotInPlaceAnimation("a") each, ReferenceAnimation("r").
        typed("not_in_place", .any, "list<string>"),
        og("reference", .string),
    },
};

// ---------------------------------------------------------------- structured OG data

fn checkTile(v: *const ir.Expr) ?[]const u8 {
    if (v.kind != .list or v.kind.list.len < 2 or v.kind.list.len > 3) return "expected [x, y] or [x, y, direction]";
    for (v.kind.list) |x| if (int(x) == null) return "expected [x, y] or [x, y, direction]: ints";
    return null;
}

/// An item's or area's menu action `action` (`k` > 0: an area's further one, `action<k>`,
/// world/areas.zig actionId): the core's number of its rules Action row (Classic
/// `funcID`), OG Script's the row's name as a word (`action = Take`; `none`, `walk`: no
/// row); the OG reader sets the number (world/start.zig).
fn actionFields(comptime k: u8) [if (k == 0) 2 else 1]Field {
    const name = if (k == 0) "action" else std.fmt.comptimePrint("action{d}", .{k});
    const og_field: Field = .{ .name = name, .type = .any, .only_og = true, .check = checkAction };
    // `action1`…: an area's own variable in Classic (`int funcID1;`), no schema field.
    return if (k == 0) .{ .{ .name = name, .type = .int, .only_classic = true }, og_field } else .{og_field};
}

fn checkAction(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .word and std.mem.indexOf(u8, v.kind.word, "::") == null) return null;
    return "expected an action's name (Take), none or walk";
}

/// The core's number of OG Script's words for an object without an Action row: `none` 0 (a click just walks there), `walk` −1 (an exit opens no
/// examine menu; an area with a `WalkPath` walks it: world/actions.zig).
pub fn noAction(word: []const u8) ?i32 {
    if (std.mem.eql(u8, word, "none")) return 0;
    if (std.mem.eql(u8, word, "walk")) return -1;
    return null;
}

/// A weapon's class: the exe's number `class` (Classic `classType`), OG Script's the name
/// of its rules WeaponClass/Pattern rows (`class = pistol`); the OG reader sets the
/// number (world/start.zig).
const class_fields = [_]Field{
    .{ .name = "class", .type = .int, .only_classic = true },
    .{ .name = "class", .type = .any, .only_og = true, .check = checkWeaponClass },
};

/// A field of the block's rules rows (Field.rows): any value the rows' calls read (the
/// rules loader says what is wrong in it).
fn rowsField(comptime name: []const u8) Field {
    return .{ .name = name, .type = .any, .only_og = true, .check = anyRows, .rows = true };
}

fn anyRows(_: *const ir.Expr) ?[]const u8 {
    return null;
}

/// How block `kind`'s field `name` comes from its `same_as` block (`import X;`) when
/// neither it nor its archetypes set it: `value` the world's (world/start.zig fromSameAs:
/// a value, an engine enum's word, `look`, `class`/`action`/`battle_class` words), `text`
/// through the one number they share (loaders/ogs.zig loadTexts: `name`, `examine`), `rows`
/// its rules rows (rules.sameThing: a row by one names the group); `no`: its identity
/// (`classic_id`, `same_as`, `pickable`) and the rest, written in each block.
pub const SameAs = enum { no, value, text, rows };

pub fn sameAsOf(kind: []const u8, name: []const u8) SameAs {
    for ([_][]const u8{ "classic_id", "same_as", "pickable" }) |x| if (std.mem.eql(u8, x, name)) return .no;
    if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "examine")) return .text;
    const h = blockHost(kind) orelse return .no;
    const fd = ogField(h, name) orelse return .no;
    if (fd.rows) return .rows;
    if (fd.ref != .none and fd.ref != .look) return .no;
    // A checked field the world reads itself (world/start.zig applyWords); any other checked one is not inherited.
    if (fd.check != null and !(std.mem.eql(u8, name, "class") or std.mem.eql(u8, name, "battle_class") or std.mem.startsWith(u8, name, "action"))) return .no;
    return .value;
}

/// The world takes field `name` of block `kind` from its `same_as` block (sameAsOf `value`).
pub fn sameAsField(kind: []const u8, name: []const u8) bool {
    return sameAsOf(kind, name) == .value;
}

fn checkFighterClass(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .word and std.mem.indexOf(u8, v.kind.word, "::") == null) return null;
    if (int(v) != null) return null;
    return "expected a fighter class's name (smokerider)";
}

fn checkWeaponClass(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .word and std.mem.indexOf(u8, v.kind.word, "::") == null) return null;
    return "expected a weapon class's name (pistol)";
}

/// A weapon's effects (battle/generic.zig fxId, fxOf): `effects_from` all of a game weapon's,
/// `flash_from`/`launch_from`/`hit_from` one stage's (−1: none); a classic_id, or the
/// archetype (`effects_from = ~w"weapons::rocket_launcher"`): the OG reader
/// sets the number (world/start.zig).
fn effectsField(comptime name: []const u8) Field {
    return .{ .name = name, .type = .any, .only_og = true, .check = checkEffectsFrom };
}

fn checkEffectsFrom(v: *const ir.Expr) ?[]const u8 {
    if (int(v) != null) return null;
    if (v.kind == .lit and v.kind.lit == .string and v.sigil == .weapon) return null;
    return "expected a weapon (~w\"…\") or a classic_id";
}

/// A weapon's ammo: the item archetype it takes (`~i"items::x"`); the sigil's check finds it.
const ammo_field: Field = .{ .name = "ammo", .type = .string, .only_og = true, .ref = .item, .check = checkAmmo };

fn checkAmmo(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .lit and v.kind.lit == .string and v.sigil == .item) return null;
    return "expected an item (~i\"…\")";
}

/// Where the selected hero stands when the level is entered or re-entered: an area point
/// of the level (`entry = "capt_start"`), placed right before `Level.OnRestore` as its
/// `actor::Place(hero::GetSelected(), "capt_start", 0)` did (world/start.zig placeEntry).
/// OG Script data: the level's own dialog (`dialog = ~d"01__port_barge"`), what its code
/// plays as `scene::Dialog(host.dialog)` (a battle's before the fight; the exe's
/// `DialogInit(GetName(), GetName())`, `<its name>.dlg`).
const dialog_field: Field = .{ .name = "dialog", .type = .string, .only_og = true, .ref = .dialog };

const entry_field: Field = .{ .name = "entry", .type = .string, .only_og = true, .check = checkEntry };

/// OG Script data: this block is the same thing as block `same_as` (`actor nato { same_as =
/// characters::c_nato; }`: the location's actor and the battle's fighter): one identity,
/// its texts, rules rows and the core's number (loaders/ogs.zig `idOf`; no classic_id in a project: a block's path is its identity).
const same_as_field: Field = .{ .name = "same_as", .type = .string, .only_og = true, .check = checkSameAs };

fn checkSameAs(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .word and std.mem.indexOf(u8, v.kind.word, "::") != null) return null;
    // A level's own object of no archetype: "<level>/<name>" (a battle's card the location's).
    if (v.kind == .lit and v.kind.lit == .string and v.sigil == .none and std.mem.indexOfScalar(u8, v.kind.lit.string, '/') != null) return null;
    return "expected a block's path (characters::c_nato) or a level's object (\"03_museum/card\")";
}

fn checkEntry(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .lit and v.kind.lit == .string and v.sigil == .none) return null;
    return "expected a point's name (\"capt_start\")";
}

/// An entity's texts: `name = "Grandma";` its name
/// in the game (the Classic `string.tab` line of its classic_id: names, area hints), `examine
/// = "…";` what examining it says (`items.inf`, an area's `activeareas.inf`). The OG reader
/// makes them the core's texts by the block's classic_id (loaders/ogs.zig loadTexts); no
/// object variable.
fn textField(comptime name: []const u8) Field {
    return .{ .name = name, .type = .string, .only_og = true, .check = checkText };
}

fn checkText(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .lit and v.kind.lit == .string and v.sigil == .none) return null;
    return "expected a text (\"…\")";
}

/// Not picked by the pointer (decor, a used cover, an exit not yet open; the core's classic_id
/// −1: the exe's pick 0x450fa0, world/areas.zig): `pickable = false`.
const pickable_field: Field = .{ .name = "pickable", .type = .bool, .only_og = true, .check = checkThrown };

/// A weapon thrown (used up as it hits: the core's `ammo` −1): `thrown = true`.
const thrown_field: Field = .{ .name = "thrown", .type = .bool, .only_og = true, .check = checkThrown };

fn checkThrown(v: *const ir.Expr) ?[]const u8 {
    if (v.kind == .lit and v.kind.lit == .bool) return null;
    return "expected true or false";
}

fn checkAt(v: *const ir.Expr) ?[]const u8 {
    if (v.kind != .list or v.kind.list.len != 3) return "expected [x, y, angle]";
    for (v.kind.list) |x| if (number(x) == null) return "expected [x, y, angle]: numbers";
    return null;
}

/// Field `name` of a struct value written `c` (`Place(who = …)`), if given.
pub fn recordField(c: ir.Call, name: []const u8) ?*const ir.Expr {
    for (c.named) |n| if (std.mem.eql(u8, n.name, name)) return n.value;
    return null;
}

/// An int literal (`-3` too).
pub fn int(e: *const ir.Expr) ?i32 {
    return switch (e.kind) {
        .lit => |v| if (v == .int) v.int else null,
        .unary => |u| if (u.op == .neg) if (int(u.operand)) |n| -n else null else null,
        else => null,
    };
}

/// A number literal (`-1.5` too).
pub fn number(e: *const ir.Expr) ?f32 {
    return switch (e.kind) {
        .lit => |v| switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |x| x,
            else => null,
        },
        .unary => |u| if (u.op == .neg) if (number(u.operand)) |n| -n else null else null,
        else => null,
    };
}

/// A string literal or the name of an `@obj` reference.
pub fn text(e: *const ir.Expr) ?[]const u8 {
    return switch (e.kind) {
        .lit => |v| if (v == .string) v.string else null,
        .ref => |r| r,
        else => null,
    };
}

/// OG Script data block kinds and their hosts ("": no schema yet, the fields are not
/// checked; shortcut: until the OG reader gives them one).
/// The kinds of OG Script data blocks (`fighter`, `weapon`, …).
pub const block_kinds = blk: {
    var out: [kinds.len][]const u8 = undefined;
    for (&out, kinds) |*o, k| o.* = k[0];
    break :blk out;
};

const kinds = [_]struct { []const u8, []const u8 }{
    .{ "fighter", "fighter" },   .{ "hero", "fighter" },         .{ "item", "item" },                         .{ "weapon", "weapon" }, .{ "actor", "actor" },
    .{ "area", "activearea" },   .{ "anim", "bitmapanimation" }, .{ "active_anim", "activebitmapanimation" }, .{ "level", "level" },   .{ "battle", "combatlevel" },
    .{ "obstacle", "obstacle" }, .{ "path", "" },                .{ "look", "look" },                         .{ "scene", "" },        .{ "dialog", "" },
    .{ "speaker", "" },          .{ "game", "" },                .{ "ai_profile", "" },                       .{ "action", "" },
};

/// Field `name` of OG Script data blocks of kind `kind` (`ogs/link.zig Env.schema`).
pub fn blockField(kind: []const u8, name: []const u8) link.Lookup {
    const k = for (kinds) |k| {
        if (std.mem.eql(u8, k[0], kind)) break k;
    } else return .unknown_kind;
    if (k[1].len == 0) return .no_schema;
    const fd = ogField(kindHost(k[1]), name) orelse return .no_field;
    return .{ .field = .{ .name = fd.name, .type = fd.type, .type_name = fd.type_name, .ref = fd.ref, .check = fd.check, .rows = fd.rows } };
}

fn kindHost(name: []const u8) *const Host {
    if (std.mem.eql(u8, name, "obstacle")) return &obstacle_host;
    return if (std.mem.eql(u8, name, "look")) &look_host else host(name).?;
}

/// The schema of host kind `kind` as OG Script writes it (`fighter`, `area`; the editor's
/// completion after `host.`); null: none (yet) or no such kind.
pub fn blockHost(kind: []const u8) ?*const Host {
    for (kinds) |k| if (std.mem.eql(u8, k[0], kind)) return if (k[1].len == 0) null else kindHost(k[1]);
    return null;
}

/// A host's field by name (any case), its ancestors' too (not one it `replaces`).
pub fn field(h: *const Host, name: []const u8) ?Field {
    var at: ?*const Host = h;
    while (at) |x| : (at = if (x.parent) |p| host(p) else null) {
        for (x.fields) |y| {
            if (std.ascii.eqlIgnoreCase(y.name, name)) return y;
            if (std.ascii.eqlIgnoreCase(y.replaces, name)) return null;
        }
    }
    return null;
}

/// A host's field as OG Script writes it (`field`, without the `only_classic` ones: a
/// weapon's `action` is the core's number, OG Script's a name).
pub fn ogField(h: *const Host, name: []const u8) ?Field {
    var at: ?*const Host = h;
    while (at) |x| : (at = if (x.parent) |p| host(p) else null) {
        for (x.fields) |y| {
            if (y.only_classic) continue;
            if (std.ascii.eqlIgnoreCase(y.name, name)) return y;
            if (std.ascii.eqlIgnoreCase(y.replaces, name)) return null;
        }
    }
    return null;
}

/// The host of a class declaring `declared` (names as the exe's files spell them, any
/// case): the most derived one whose Classic fields it declares all (`#inherit` or
/// `#include` of the base class).
pub fn hostOf(declared: []const []const u8) ?*const Host {
    for (&hosts) |*h| {
        var at: ?*const Host = h;
        const all = chain: while (at) |x| : (at = if (x.parent) |p| host(p) else null) {
            for (x.fields) |y| if (!y.only_og and !has(declared, classic_names.classic(classic_names.Host.byName(x.name), y.name))) break :chain false;
        } else true;
        if (all) return h;
    }
    return null;
}

fn has(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, name)) return true;
    return false;
}

test "schemas: inheritance, lookup, the host of a class" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const w = try fields(arena.allocator(), host("weapon").?, false);
    try std.testing.expectEqualStrings("classic_id", w[0].name);
    try std.testing.expectEqualStrings("heavy_armor_pct", w[w.len - 1].name);
    try std.testing.expectEqualStrings("damage_kind", w[16].name);
    try std.testing.expect(field(host("weapon").?, "kind") == null);
    try std.testing.expect(field(host("item").?, "kind") != null);
    try std.testing.expectEqual(Type.string, field(host("fighter").?, "MESH").?.type);
    try std.testing.expect(field(host("weapon").?, "attack_zone").?.only_og);
    try std.testing.expectEqual(Value{ .int = 0 }, field(host("fighter").?, "hp").?.default());
    const decl = [_][]const u8{ "nameID", "areaName", "isLevelSwitch", "funcID", "noHint", "noExamine", "own" };
    // The engine's names are no Classic class's declarations.
    try std.testing.expectEqualStrings("gameobject", hostOf(&.{ "nameID", "areaName", "isLevelSwitch", "action", "hint_hidden", "examine_hidden" }).?.name);
    try std.testing.expectEqualStrings("activearea", hostOf(&decl).?.name);
    try std.testing.expectEqualStrings("gameobject", hostOf(&.{"nameid"}).?.name);
    try std.testing.expect(hostOf(&.{}) == null);
    try std.testing.expectEqualStrings("ItemPlace", field(host("weapon").?, "place").?.type_name);
}

/// A field OG Script writes (no Classic-only one, no dropped one).
pub fn shown(fd: Field) bool {
    // `same_as` has a statement of its own (`import x;`), no field of the language.
    return !fd.only_classic and !fd.dropped and !std.mem.eql(u8, fd.name, "same_as");
}

/// Field `f`'s type as the language declares it (foundation/hosts.ogs): its prelude type,
/// `bool`, the kind a reference names, else its value type.
fn declType(fd: Field) []const u8 {
    if (fd.type_name.len > 0) return fd.type_name;
    if (fd.flag) return "bool";
    if (fd.ref != .none) return @tagName(fd.ref);
    return @tagName(fd.type);
}

test "schema: foundation/hosts.ogs declares every field OG Script writes, of its type, and no other" {
    const decls = script.hosts;
    for (block_kinds) |k| {
        var at: ?*const Host = blockHost(k) orelse continue;
        while (at) |h| : (at = if (h.parent) |p| host(p) else null) {
            const d = decls.host(h.name) orelse {
                std.debug.print("foundation/hosts.ogs: no host {s}\n", .{h.name});
                return error.TestUnexpectedResult;
            };
            if (!std.mem.eql(u8, d.parent, h.parent orelse "")) {
                std.debug.print("foundation/hosts.ogs: host {s} : {s}, the schema's parent {s}\n", .{ h.name, d.parent, h.parent orelse "" });
                return error.TestUnexpectedResult;
            }
            for (h.fields) |hf| if (shown(hf)) {
                const df = d.field(hf.name) orelse {
                    std.debug.print("foundation/hosts.ogs: host {s} has no {s}\n", .{ h.name, hf.name });
                    return error.TestUnexpectedResult;
                };
                // A name of two forms (a fighter's `ai`) is declared once as the first.
                const first = for (h.fields) |g| {
                    if (shown(g) and std.mem.eql(u8, g.name, hf.name)) break g;
                } else hf;
                if (!std.mem.eql(u8, df.type_name, declType(first))) {
                    std.debug.print("foundation/hosts.ogs: {s}.{s} is {s}, the schema's {s}\n", .{ h.name, hf.name, df.type_name, declType(first) });
                    return error.TestUnexpectedResult;
                }
            };
            for (d.fields) |df| {
                const known = for (h.fields) |hf| {
                    if (shown(hf) and std.mem.eql(u8, hf.name, df.name)) break true;
                } else false;
                if (!known) {
                    std.debug.print("foundation/hosts.ogs: {s}.{s}: no such field in the schema\n", .{ h.name, df.name });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
