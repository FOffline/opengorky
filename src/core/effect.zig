//! Effect descriptions (the «effects» core module, core/modules.zig `Tables` weapon_fx,
//! fighter_fx): what a strike shows, as data — the exe's hit and launch code by weapon
//! classic_id (callback 0x4863c0, branches 0x4896b0, projectiles 0x49b0a0…0x4a8ca0) as
//! built-in records (core/classic.zig `weapon_fx`, `fighter_fx`), run by fx/hits.zig and fx/launch.zig. The rules pick a record per stage (Classic's FxAs; an
//! OpenGorky weapon's `effects_from`/`flash_from`/`launch_from`/`hit_from`; MonsterAttack `effects_from`/`flash_from`/`launch_from`/`hit_from`/`strike`: generic.Fx); the hit's sound stays
//! the rules' WeaponSound. Numbers named after adjust.kdt globals follow it (`Val`, `Num`).
//! An OpenGorky project's `rules\fx.ss` rows (`WeaponFx`, `FighterFx`) write over them
//! (composition: loaders/rules_text.zig). What the exe computes per frame or from the
//! battle (ion, blaster, flame streams, gas cloud, ball, orbital rocket) is data too: each
//! part fills one of the effect objects (effects/*.zig: `Flame`, `Stream`, `Beam`, `Spin`,
//! `Cloud`, `Projectile`) that tick in their lists; `Code`/`LaunchCode` stay readable as
//! names of the built-in presets (old rules files; loaders/rules_text.zig writes them out
//! as their parts as it reads them, so the runners never see one).

const std = @import("std");
const adjust = @import("../rules.zig").adjust;
const Num = @import("../rules.zig").rows.Num;
const effects = @import("../effects.zig");
const Bitmap = effects.bitmap.Bitmap;
const Beam = effects.beam.Beam;
const Projectile = effects.projectile.Projectile;
const Spin = effects.beam.Spin;
const Cloud = effects.flame.Cloud;
const StreamLook = effects.projectile.StreamLook;

/// A float that may follow adjust.kdt (`getFloat(adj, d)`; `int`: `getInt`, as the exe
/// reads it), divided by `div` (−1: negated), `trunc`: cut to an integer (the exe's
/// ftol), then plus each of `sum` in order.
pub const Val = struct {
    d: f32,
    adj: []const u8 = "",
    int: bool = false,
    div: f32 = 1,
    trunc: bool = false,
    sum: []const Val = &.{},

    pub fn n(d: f32) Val {
        return .{ .d = d };
    }

    pub fn a(name: []const u8, d: f32) Val {
        return .{ .d = d, .adj = name };
    }

    pub fn get(v: Val) f32 {
        const x = if (v.adj.len == 0) v.d else if (v.int) @as(f32, @floatFromInt(adjust.getInt(v.adj, @intFromFloat(v.d)))) else adjust.getFloat(v.adj, v.d);
        var y = x / v.div;
        if (v.trunc) y = @trunc(y);
        for (v.sum) |s| y += s.get();
        return y;
    }

    /// A plain number (the text writes it bare).
    pub fn plain(v: Val) bool {
        return v.adj.len == 0 and !v.int and v.div == 1 and !v.trunc and v.sum.len == 0;
    }
};

/// Where a part stands, worked out at the strike (the parts that follow model points do
/// that each tick themselves: an emitter's `link`, a beam's actor links).
pub const At = union(enum) {
    /// pos + aS·(forward, right, up) by the striker's angle.
    self: [3]Val,
    /// The striker's centre moved `r`·aS toward the target (lifted 250·aS), at height
    /// `up`·aS (the blaster's muzzle, callback 0x1c 0x487aee).
    toward: Toward,
    /// The aim (the tile centre on the floor; a launch's: its target) this much ·aS higher.
    target: f32,
    /// Each fighter on the strike's hit tiles, once each (enemies, allies, boxes), this
    /// much ·aS above it (blaster 0x4a37c0); a ribbon's `to`: a ribbon to each.
    each_hit: f32,
    /// Orbital rocket's start (0x4a8ca0 → 0x4a8450): from the target toward the striker
    /// (x + 0.1·aS), at `h`·aS, `dist`·aS away.
    sky: Sky,
    /// A mod's (not in the exe): the fighters of `each_hit` as a chain — each the nearest
    /// not yet reached to the one before (the first to the part's start), at most `n` (0:
    /// all), each link `delay` ticks after the last; a part's `to`/`aim` runs from link to link.
    chain: ChainAt,
};
const Toward = struct { r: Val, up: Val };
const ChainAt = struct { lift: f32 = 0, n: u32 = 0, delay: u32 = 0 };
const Sky = struct { h: Val, dist: Val };

/// A flame emitter (`effects.flame.Flame`, 0x4a06f0, tick 0x49faa0): from `at` toward `aim`
/// (as at the strike), a particle `ahead`·aS along the way, speed `speed`·aS, one per tick
/// while the object timer `timer` runs, at most `max` (the exe clamps it to 0…180), each
/// living `life` ticks; drawn with the fire look (attack_flame_*, a preset). With `link`
/// it re-aims every tick from the striker's model: from `at` toward that point turned by
/// `rot` around the vertical, or with `link2` from `link` to `link2`. `holds_attack`: the
/// fighter's attack waits for the object (flamethrower 0x49fd70).
pub const Emitter = struct {
    at: At,
    aim: At = .{ .target = 130 },
    ahead: Val = .n(0),
    speed: Val = .n(35),
    timer: Val = .n(90),
    max: Val = .n(74),
    life: Val = .n(16),
    link: []const u8 = "",
    link2: []const u8 = "",
    rot: f32 = 0,
    holds_attack: bool = false,
    /// Ticks before it starts.
    delay: u32 = 0,
    /// A mod's (`effects.flame.Flame`; not in the exe): scatter of each particle's
    /// direction (the shared rand()), its fall and speed loss per tick, its look by age
    /// (null: the fire look).
    spread: f32 = 0,
    gravity: f32 = 0,
    drag: f32 = 0,
    look: ?FlameLook = null,
    material: []const u8 = "",
};
const FlameLook = effects.flame.Look;

/// A ribbon (`effects.projectile.Stream`, the blaster's 0x4a28e0) from `from` to each point
/// of `to`; its jitter draws the game's shared rand().
pub const Ribbon = struct {
    from: At,
    to: At,
    look: StreamLook = .{},
    delay: u32 = 0,
};

/// A mesh effect (`effects.beam.Spin`, the satellite beam 0x4a7020) at `at`.
pub const Mesh = struct {
    at: At,
    s: Spin = .{},
};

/// A looping sprite on the target (`effects.flame.Cloud`, Schizo's gas 0x4a95d0) that
/// lasts while its tile has gas; `rand_draws`: its constructor's rand() calls (the shared
/// stream, 0x4a9685).
const CloudPart = struct {
    at: At,
    c: Cloud = .{},
    rand_draws: u32 = 0,
};

/// A segment run of an ion beam (`effects.beam.Chain`): `start` from adjust.kdt.
pub const Chain = struct { start: Val, step: f32, n: u32 };

/// A colour from adjust.kdt (`getRgb`) as 0…1.
pub const Rgb = struct {
    adj: []const u8 = "",
    d: [3]u8,

    pub fn get(c: Rgb) [3]f32 {
        const v = adjust.getRgb(c.adj, c.d);
        return .{ @as(f32, @floatFromInt(v[0])) / 255.0, @as(f32, @floatFromInt(v[1])) / 255.0, @as(f32, @floatFromInt(v[2])) / 255.0 };
    }
};

/// Muzzle light colour (shot_light_color 255,128,64).
const shot_color: Rgb = .{ .adj = "shot_light_color", .d = .{ 255, 128, 64 } };

/// An effect mesh's rotation: a matrix, Rx·Ry·Rz by angles (camera.rotationXYZ) or
/// Rz(z)·Ry(y) (0x47cd30), worked out when shown (as the exe does).
pub const Rot = union(enum) {
    matrix: [9]f32,
    xyz: [3]f32,
    zy: [2]f32,
};

/// Effect on a link point of the striker's model (command 0x20, 0x427ce0).
pub const Attach = struct {
    /// The effect (Classic's muzzle flash: "chaingun", core/classic.zig flash).
    effect: []const u8 = "",
    link: []const u8,
    offset: [3]f32 = .{ 0, 0, 0 },
    rot: Rot = .{ .matrix = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    scale: f32 = 0.5,
    ticks: Num = .n(5),
};

/// Where a placed effect stands: the barrel (pos + aS·(220 forward, 10 right, 530 up),
/// callback 11) or the target (aim tile centre) `lift`·aS higher.
const Where = enum { muzzle, target };

/// One-shot bitmap (0x4cb600): `b` with its place, size and colour.
const Placed = struct {
    b: Bitmap,
    at: Where = .target,
    lift: f32 = 0,
    size: ?Val = null,
    rgb: ?Rgb = null,
};

/// Short light at pos + aS·`at` (forward, right, up) by the striker's angle, moved `ahead`·aS
/// toward `toward`; colour `color` (else `rgb`), range ×aS when `range_as`.
pub const Light = struct {
    at: [3]Val,
    rgb: Rgb = shot_color,
    color: ?[3]f32 = null,
    toward: ?At = null,
    ahead: f32 = 0,
    range: f32,
    range_as: bool = false,
    ticks: u32,
};

/// Beam `b` from `from` (null: the target `lift`·aS higher) to `to` (null: the same);
/// `actor`: on the striker's link points; `chains`: an ion beam's runs (`b.chains`).
pub const Ray = struct {
    b: Beam,
    from: ?At = null,
    to: ?At = null,
    chains: []const Chain = &.{},
    lift: f32 = 0,
    size: ?Val = null,
    ticks: ?Num = null,
    actor: bool = false,
};

/// The built-in presets by name (core/classic.zig `preset`): old rules files write `code("ion")`.
pub const Code = enum {
    /// Ion rifle ribbon (0x4a1600).
    ion,
    /// Blaster streams to each fighter on the hit tiles (0x4a37c0).
    blaster,
    /// Medusa's current (0x4a44e0).
    current,
    /// Schizo's gas cloud on the target (0x4a95d0).
    cloud,
    /// Pain God's flame stream and light (0x4a0900).
    pain_god,
    /// Stinger's flame jet (0x4a06f0).
    stinger_flame,
    /// Flamethrower (0x49fdc0).
    flamethrower,
    /// Satellite energy beam (0x4a74a0).
    spin,
};

pub const Part = union(enum) {
    attach: Attach,
    bitmap: Placed,
    /// Explosion (0x4d0610) at the target this much ·aS higher.
    explosion: Val,
    light: Light,
    beam: Ray,
    /// Sound at the striker after `ticks`.
    sound: struct { name: []const u8, ticks: u32 },
    /// Screen shake for this many ticks.
    shake: Num,
    emitter: Emitter,
    ribbon: Ribbon,
    mesh: Mesh,
    cloud: CloudPart,
    /// A built-in preset's parts (core/classic.zig `preset`; read as them: loaders/rules_text.zig).
    code: Code,
};

/// The effects of a game weapon classic_id, by stage (generic.Fx names one per stage).
pub const Weapon = struct {
    pub const call = "WeaponFx";
    pub const file = "fx";
    pub const keys = .{ "id", "who" };
    pub const doc =
        \\What a strike shows by the game weapon classic_id a stage names (FxAs, a weapon's or
        \\MonsterAttack effects_from/flash_from/launch_from/hit_from): parts before the hit
        \\(pre), the monster's shot flash (shot), the hero's muzzle flash (flash), the hit
        \\(hit), the projectile (launch); who: only for that
        \\attacker classic_id (0 any). Parts: attach (an effect on a link point), bitmap, explosion,
        \\light, beam, sound, shake, emitter (flame particles), ribbon (blaster stream), mesh
        \\(a spinning mesh), cloud (gas on the target), code (a built-in preset by name). Points:
        \\self(list(forward, right, up)), toward(r = .., up = ..), target(lift), each_hit(lift),
        \\sky(h = .., dist = ..), chain(lift = .., n = .., delay = ..) (mods: each fighter hit in turn,
        \\the nearest next). Emitters of mods: spread, gravity, drag, look = Look(sprite, size =
        \\Track(..), rgb = list(Track, Track, Track), alpha = Track(..)). Numbers may follow adjust.kdt: Val(d = default, adj = "name", int = 1,
        \\div = 7, trunc = 1, sum = list(...)).
    ;
    id: i32,
    /// OpenGorky: the weapon archetype instead of the number (`id = ~w"weapons::riffle"`;
    /// a project has no classic_id: modules.weaponFx asks the core's number of it).
    id_class: []const u8 = "",
    /// Only for this attacker classic_id (0: any; the first matching record wins).
    who: i32 = 0,
    who_class: []const u8 = "",
    /// Before the hit (HeroAttack `pre`, MonsterAttack `flash_delay`).
    pre: []const Part = &.{},
    /// At the hit, before the fighter's own: the monster's shot flash.
    shot: []const Part = &.{},
    /// At the hit, after them: the hero's muzzle flash.
    flash: []const Part = &.{},
    /// The hit's own (after the sound).
    hit: []const Part = &.{},
    launch: ?Launch = null,
};

/// A fighter's own effects (MonsterAttack `strike`, table 0x48d618) with a weapon (0: any).
pub const Fighter = struct {
    pub const call = "FighterFx";
    pub const file = "fx";
    pub const keys = .{ "fighter", "weapon" };
    pub const doc =
        \\A fighter's own effects (MonsterAttack strike, table 0x48d618) with a weapon classic_id
        \\(0 any): pre in place of the weapon's, hit, the second hit of a series (second).
    ;
    fighter: i32,
    fighter_class: []const u8 = "",
    weapon: i32 = 0,
    weapon_class: []const u8 = "",
    /// Instead of the weapon's `pre`.
    pre: []const Part = &.{},
    hit: []const Part = &.{},
    /// The second hit of a series (empty: `hit`).
    second: []const Part = &.{},
};

/// A projectile field set from adjust.kdt (`u32`: `getInt` clamped at 0).
pub const Set = struct { f: std.meta.FieldEnum(Projectile), v: Val };

/// The built-in launch presets by name (old rules files; core/classic.zig `withCode`).
pub const LaunchCode = enum { none, ball, orbital };

/// A projectile's look besides its mesh and effect: `ball` — the Incubus/Stinger ball
/// (two "kula" frames cross-fading and "poswiata", 0x4a6280; a preset).
pub const Look = enum { plain, ball };

/// A projectile (0x49b0a0 straight, 0x49c840 arc): template `pr`, then `set` over it;
/// `max_speed` 0 is the speed; `light_range` is ×aS.
pub const Launch = struct {
    pr: Projectile,
    /// Launch point (forward, right, up)·aS; null: (100, 0, 400).
    start: ?[3]Val = null,
    /// The second projectile's (Jet Elmer's second rocket).
    start2: ?[3]Val = null,
    /// rocket1_trail_* look (fx/launch.zig rocketTrail).
    rocket_trail: bool = false,
    set: []const Set = &.{},
    trail_rgb: ?Rgb = null,
    /// Launch point instead of `start` (worked out last: `target` is the projectile's).
    start_at: ?At = null,
    /// Held at the midpoint of these link points of the striker for `pr.hold` ticks, then
    /// flies from there (the ball, 0x4a5cac).
    hold: ?[2][]const u8 = null,
    /// Grows from `grow_from` to its scale by this per tick (attack_ball_ds).
    grow: ?Val = null,
    grow_from: f32 = 0.1,
    look: Look = .plain,
    code: LaunchCode = .none,
};

pub const Material = effects.material.Material;
pub const PostChain = effects.material.PostChain;
pub const Post = effects.material.Post;

/// A new part of each kind (the editor's "add"): a start to edit, at the striker's
/// barrel height or on the target.
pub const templates = [_]Part{
    .{ .emitter = .{ .at = .{ .self = .{ .n(0), .n(0), .n(400) } }, .ahead = .n(100) } },
    .{ .ribbon = .{ .from = .{ .toward = .{ .r = .n(120), .up = .n(450) } }, .to = .{ .target = 300 } } },
    .{ .beam = .{ .b = .{ .effect = "ray", .from = @splat(0), .to = @splat(0), .size = 50, .left = 30 }, .from = .{ .self = .{ .n(0), .n(0), .n(450) } }, .to = .{ .target = 300 } } },
    .{ .mesh = .{ .at = .{ .target = 0 } } },
    .{ .bitmap = .{ .b = .{ .effect = "smoke2", .pos = @splat(0), .size = 400, .step = 1 }, .lift = 250 } },
    .{ .light = .{ .at = .{ .n(200), .n(0), .n(400) }, .range = 600, .ticks = 20 } },
    .{ .attach = .{ .link = "two_hands" } },
    .{ .explosion = .n(250) },
    .{ .cloud = .{ .at = .{ .target = 130 } } },
    .{ .sound = .{ .name = "", .ticks = 0 } },
    .{ .shake = .n(10) },
};

/// When a part shows after its stage starts and how long (ticks; null: while its frames
/// or its cause last), by its fields: the editor's timeline.
pub fn span(p: Part) struct { delay: u32 = 0, len: ?u32 = null } {
    return switch (p) {
        .attach => |x| .{ .len = x.ticks.ticks() },
        .bitmap => |x| .{ .delay = x.b.delay },
        .explosion, .cloud, .code => .{},
        .light => |x| .{ .len = x.ticks },
        .beam => |x| .{ .delay = x.b.delay, .len = if (x.ticks) |t| t.ticks() else x.b.left },
        .sound => |x| .{ .delay = x.ticks, .len = 0 },
        .shake => |x| .{ .len = x.ticks() },
        // The timer, then its last particles' life.
        .emitter => |x| .{ .delay = x.delay, .len = @intFromFloat(@max(0, x.timer.get() + x.life.get())) },
        .ribbon => |x| .{ .delay = x.delay, .len = x.look.life },
        .mesh => |x| .{ .delay = x.s.delay, .len = x.s.left },
    };
}

test span {
    for (templates) |t| _ = span(t);
}

pub const Stage = enum { flash, launch, hit };

/// Game weapon classic_ids among `ws` with a description of `stage` (the editor's pickers:
/// the records in force, `modules.tables().weapon_fx`), in table order.
pub fn ids(a: std.mem.Allocator, ws: []const Weapon, stage: Stage) ![]i32 {
    var out: std.ArrayList(i32) = .empty;
    for (ws) |w| {
        const has = switch (stage) {
            .flash => w.pre.len + w.shot.len + w.flash.len > 0,
            .launch => w.launch != null,
            .hit => w.hit.len > 0,
        };
        if (has and std.mem.indexOfScalar(i32, out.items, w.id) == null) try out.append(a, w.id);
    }
    return out.toOwnedSlice(a);
}
