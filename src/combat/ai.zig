//! Battle AI, recovered from gorky17.exe (AI turn 0x498d30).
//!
//! 1. Targets are live fighters of the other side; with `aiMode` 1 only the
//!    AITargetLock target; `aiMode` 2 never walks.
//! 2. Threat map (0x49af80): for each opponent, the tiles it can reach with a full
//!    walk budget and its weapons' hit tiles from there; a tile keeps the maximum
//!    `pct × max_damage / 100` per opponent, and the tile threat is the sum over
//!    opponents (0x494f90).
//! 3. Every path (0x498ed0) within `walk_range`: straight step 1, diagonal 1.5.
//!    Each path tile is scored (0x499170); the best over all paths is kept, the
//!    shorter path on a tie.
//! 4. Execution (0x499770): walk to the strike tile, strike, walk the rest.
//!
//! Tile score (`aic*` are fighter variables):
//! - strike: for each weapon and aim tile, the sum over fighters on hit tiles:
//!   opponent `(max_damage + 5) × pct / 100` (AITargetLock target ×100), ally
//!   `−10 ×` the same; × `aicAttack`. The best strike carries down the path;
//! - `− aicDefense × tile threat`;
//! - without a strike: `− aicPlayerDist × distance to the nearest opponent`
//!   (with `aiMode` 3, `− aicGuardDist ×` distance to the guard point);
//!   with a strike: `+ aicPlayerDist ×` distance (step away after striking).
//!
//! Special fighters (`classType` 1, 6–18; method +0xe0) score their own way
//! (`Scoring`): based on "scoring A" (0x4dcb40), no decoy, no +5 to damage and no ×2
//! for `classType` 5; on top, rules for Garcia, Smoke Rider, Grandma and children,
//! Incubus, Cripple, Guard, Schizo and Messiah. The scorings are the "AI" core module
//! (core/modules.zig `Ai`, core/behaviour.zig `scorings` by the rules' AiProfile `scoring`):
//! records of the pieces run here.

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const anim = @import("anim.zig");
const natives = @import("natives.zig");
const events = @import("events.zig");
const strike = @import("strike.zig");
const weapons = @import("weapons.zig");
const battle_mod = @import("../battle.zig").battle;
const modules = @import("../core.zig").modules;
const immunity = @import("../battle.zig").immunity;
const Battle = battle_mod.Battle;
const Fighter = @import("../battle.zig").fighter.Fighter;
const World = @import("../state.zig").world.World;
const object = @import("../script.zig").object;
const value = @import("../script.zig").value;
const Object = object.Object;
const rules = @import("../battle.zig").rules;
const weaponKind = @import("../core.zig").modules.weaponKind;
const grid = @import("../battle.zig").grid;
const generic = @import("../battle.zig").generic;
/// The rows of the plan's distance buffer (Battle.ai_scratch.dist).
const Rows = battle_mod.AiScratch;

const Tile = grid.Tile;
/// Best strike found higher up the path (passed down by value).
const Carry = struct {
    score: i32 = 0,
    depth: usize = 0,
    weapon: ?*Object = null,
    aim: grid.Target = undefined,
};

const Profile = @import("../rules.zig").AiProfile;

/// The scoring and its constants (rules ai.ss): heroes (autoplay) score as an ordinary
/// monster; the generic fighter by its `ai` field (battle/generic.zig).
fn profileOf(f: Fighter) Profile {
    return generic.aiProfile(f.obj, f.side == .enemy);
}

/// The fighter's profile and scoring this plan: the rules' (its profile's `scoring` the
/// core module `Ai`'s row), then an enemy's code's: its Enemy.AiProfile() answer (an
/// `AiProfile(…)` record, the fields it gives over them: a scoring by name and its parts too).
const Mind = struct { prof: Profile, ev: Scoring };

pub fn mindOf(w: *World, f: Fighter) Mind {
    var m: Mind = .{ .prof = profileOf(f), .ev = undefined };
    var over: ?value.Value.Map = null;
    if (f.side == .enemy and f.obj.implementsC("AiProfile")) if (natives.ask(w, f.obj, "Enemy.AiProfile", .{}) catch null) |v| if (v == .map) {
        over = v.map.*;
    };
    if (over) |mp| for (mp.keys, mp.values) |k, v| if (k == .string and std.mem.eql(u8, k.string, "scoring") and v == .string) {
        m.prof.scoring = v.string;
    };
    m.ev = modules.aiScoring(m.prof.scoring.?).*;
    const mp = over orelse return m;
    for (mp.keys, mp.values) |k, v| {
        if (k != .string or v == .nil) continue;
        const n = k.string;
        inline for (@typeInfo(Profile).@"struct".field_names) |fname| if (comptime !std.mem.eql(u8, fname, "scoring")) if (std.mem.eql(u8, n, fname)) {
            const T = @FieldType(Profile, fname);
            if (T == ?i32) @field(m.prof, fname) = v.toInt();
            if (T == ?bool) @field(m.prof, fname) = v.truth();
        };
        if (std.mem.eql(u8, n, "wakeful")) m.ev.wakeful = v.truth();
        if (std.mem.eql(u8, n, "near") and v == .string) m.ev.near = v.string;
        if (v == .string) {
            if (std.mem.eql(u8, n, "keep")) if (std.meta.stringToEnum(@TypeOf(m.ev.keep), v.string)) |x| {
                m.ev.keep = x;
            };
            if (std.mem.eql(u8, n, "occupant")) if (std.meta.stringToEnum(@TypeOf(m.ev.occupant), v.string)) |x| {
                m.ev.occupant = x;
            };
            if (std.mem.eql(u8, n, "tile")) if (std.meta.stringToEnum(@TypeOf(m.ev.tile), v.string)) |x| {
                m.ev.tile = x;
            };
        }
    }
    return m;
}

/// How a fighter weighs its strikes and its place (core/behaviour.zig `Scoring`): the
/// pieces it names are run here.
const Scoring = @import("../core.zig").behaviour.Scoring;

const Params = struct {
    attack: i32,
    defense: i32,
    player_dist: i32,
    guard_dist: i32,
    mode: i32,
};

/// Weapon for the search (script fields read once).
const WInfo = struct {
    pat: ?*const @import("../rules.zig").Pattern,
    md: i32,
    class: i32,
    secondary: bool,
    /// Damage kind code (immunity.damageCode), for the heroes' autoplay.
    dcode: ?immunity.Resist,
    /// Aims at most that many tiles away (0: any; rules MonsterAttack `range`).
    range: i32 = 0,
    /// The weapon's CanAim is asked at each aim (OpenGorky: one of its components has it).
    can_aim: bool = false,
};

/// Fighter for scoring hit tiles.
const FInfo = struct {
    /// A Monitor (its native: core/natives.zig).
    monitor: bool,
    hp: i32,
    name_id: i32,
    /// Its kind for what the heroes have discovered of it (immunity.Known).
    who: @import("../rules.zig").Who,
    /// Effect of its weapon in hand (rules.weaponEffect).
    weff: ?rules.Effect,
};

fn weaponInfo(wpn: *Object) WInfo {
    const class = wpn.getInt("class");
    return .{
        .pat = @import("../battle.zig").weapon_class.pattern(wpn),
        .md = wpn.getInt("max_damage"),
        .class = class,
        .secondary = wpn.getInt("secondary") != 0,
        .dcode = immunity.damageCode(.from(wpn.getInt("damage_kind"))),
    };
}

const Search = struct {
    b: *Battle,
    w: *World,
    who: u16,
    me: Fighter,
    p: Params,
    foes: [battle_mod.max_fighters]u16 = undefined,
    n_foes: usize = 0,
    weapons: [16]*Object = undefined,
    n_weapons: usize = 0,
    /// Weapon and fighter fields read once per plan: the path search changes neither
    /// fighters nor items (only the fighter's own tiles on the grid).
    winfo: [16]WInfo = undefined,
    finfo: [battle_mod.max_fighters]FInfo = undefined,
    danger: []u16,
    path: [battle_mod.max_path]Tile = undefined,
    best: battle_mod.Plan = .{},
    can_attack: bool,
    can_move: bool,
    locked: ?u16 = null,
    guard: ?Tile = null,
    targets_buf: [512]grid.Target = undefined,
    /// Path length (0x49a630) from a tile to opponent `k` and to the guard point,
    /// cached per tile (NaN = not computed yet): the fighter stands on the scored tile,
    /// so the path from it depends only on the tile.
    foe_dist: [][]f32,
    guard_dist: []f32,
    foe_tile: [battle_mod.max_fighters]Tile = undefined,
    decoy_tile: [Rows.max_decoys]Tile = undefined,
    /// Wave 0x49a630 buffers: visited tiles and the queue.
    visited: []u8,
    queue: []grid.QEntry,
    /// Decoys on the field and distances to them (0x499620): an attracted enemy
    /// doesn't strike and walks to the nearest, `−2000 × aicPlayerDist × path`.
    decoy_dist: [Rows.max_decoys][]f32 = undefined,
    n_decoys: usize = 0,
    ev: *const Scoring,
    /// The profile's constants (rules ai.ss, all set).
    prof: Profile = .{},
    /// Grandma (for the children): distance field to her.
    grandma_dist: ?[]f32 = null,
    /// Its ScoreTarget is asked at each fighter scored (OpenGorky: a component has it).
    score_target: bool = false,
    score_tile: bool = false,
    /// The best strike from each tile, this plan's (AiScratch.strikes).
    strikes: []battle_mod.TileStrike = &.{},
    /// Calls of the hot points this plan, noted when any.
    score_calls: u32 = 0,
    aim_calls: u32 = 0,
};

/// Turn plan of fighter `who`.
pub fn plan(b: *Battle, w: *World, who: u16) !battle_mod.Plan {
    const me = b.fighters.items[who];
    const n = b.width * b.height;
    try b.ai_scratch.ensure(b.gpa, n);
    const danger = b.ai_scratch.danger;
    const dist_all = b.ai_scratch.dist;
    @memset(dist_all, std.math.nan(f32));
    var dist_rows: [battle_mod.max_fighters][]f32 = undefined;
    for (&dist_rows, 0..) |*r, i| r.* = dist_all[i * n ..][0..n];
    const visited = b.ai_scratch.visited;
    const queue = b.ai_scratch.queue;
    var mind = mindOf(w, me);
    const prof = mind.prof;
    var s: Search = .{
        .b = b,
        .w = w,
        .who = who,
        .me = me,
        .p = params(me, prof),
        .danger = danger,
        .foe_dist = &dist_rows,
        .guard_dist = dist_all[Rows.guard_row * n ..][0..n],
        .visited = visited,
        .queue = queue,
        .can_attack = me.obj.getInt("attack_locked") == 0 and !me.disabled(),
        .can_move = me.canWalk(),
        .ev = &mind.ev,
        .prof = prof,
    };
    const nat = World.nativeOf(me.obj);
    if (s.p.mode == 3) s.guard = nat.fight.guard_point;
    for (b.fighters.items, 0..) |f, i| {
        if (f.side == me.side or f.side == .neutral or !f.alive() or f.appear_to != null) continue;
        if (s.p.mode == 1 and nat.fight.target_lock.len > 0) {
            if (!std.ascii.eqlIgnoreCase(f.obj.name, nat.fight.target_lock)) continue;
            s.locked = @intCast(i);
        }
        s.foes[s.n_foes] = @intCast(i);
        s.n_foes += 1;
    }
    // Its target (Grandma's child's killer; a script's FighterSetTarget) weighs as
    // AITargetLock's where the scoring weighs one (Grandma's `avenge` reads it itself).
    if (s.locked == null) if (me.grandma_target) |t| for (s.foes[0..s.n_foes]) |o| if (o == t) {
        s.locked = t;
    };
    // OpenGorky: its PreferTarget() (Enemy), a fighter it weighs so this plan.
    if (s.locked == null and me.obj.implementsC("PreferTarget")) if (try natives.ask(w, me.obj, "Enemy.PreferTarget", .{})) |v| if (v == .ref) {
        if (b.fighterOf(Object.of(v.ref))) |t| for (s.foes[0..s.n_foes]) |o| if (o == t) {
            s.locked = t;
            battle_mod.note(b, "  PreferTarget {s}: {s}", .{ me.obj.name, b.fighters.items[t].obj.name });
        };
    };
    s.score_target = me.obj.implementsC("ScoreTarget");
    s.strikes = b.ai_scratch.strikes;
    @memset(s.strikes, .{});
    s.score_tile = me.side == .enemy and me.obj.implementsC("ScoreTile");
    s.n_weapons = weapons.weaponsOf(w, me, &s.weapons).len;
    filterWeapons(&s);
    for (s.weapons[0..s.n_weapons], 0..) |wpn, i| {
        s.winfo[i] = weaponInfo(wpn);
        // OpenGorky: the attack's reach for the AI (rules MonsterAttack `range`).
        if (generic.rowOf(me.obj, wpn)) |r| s.winfo[i].range = r.range;
        s.winfo[i].can_aim = wpn.implementsC("CanAim");
    }
    for (b.fighters.items, 0..) |f, i| s.finfo[i] = .{
        .monitor = f.obj.implementsC("Monitor"),
        .hp = f.hp(),
        .name_id = fields.classicId(f.obj),
        .who = @import("../rules.zig").who(f.obj),
        .weff = if (f.weapon) |fw| rules.weaponEffect(fw.getInt("class")) else null,
    };
    try buildDanger(&s);

    // Path search; the fighter is "moved" along the path tiles.
    const g = b.grid();
    g.remove(me.tile, me.size);
    for (s.foes[0..s.n_foes], 0..) |fi, k| s.foe_tile[k] = b.fighters.items[fi].tile;
    // Grandma's child stays close to her (0x4e0602).
    if (s.ev.near.len > 0) for (b.fighters.items) |f| {
        if (!f.alive() or !std.ascii.eqlIgnoreCase(f.obj.name, s.ev.near)) continue;
        const d = dist_all[Rows.near_row * n ..][0..n];
        distanceField(&s, d, f.tile, f.size);
        s.grandma_dist = d;
        break;
    };
    // Decoys affect enemies (heroes have no AI in the original).
    // Fighters resistant to decoys (code 3, 0x498d4d) are not attracted.
    if (s.prof.decoys.? and me.side == .enemy and me.attracted and !w.immunity.immune(@import("../rules.zig").who(me.obj), .attract)) {
        for (b.decoys.items) |d| {
            if (s.n_decoys == s.decoy_dist.len) break;
            s.decoy_dist[s.n_decoys] = dist_all[(Rows.decoy_row + s.n_decoys) * n ..][0..n];
            s.decoy_tile[s.n_decoys] = d.tile;
            s.n_decoys += 1;
        }
        if (s.n_decoys > 0) s.can_attack = false;
    }
    defer {
        g.place(me.tile, me.size, who);
    }
    search(&s, 0, me.tile, me.budget(), .{});
    s.best.foe_dist = nearestFoe(&s, me.tile);
    if (s.score_calls > 0) battle_mod.note(b, "  ScoreTarget {s}: {d} calls", .{ me.obj.name, s.score_calls });
    if (s.aim_calls > 0) battle_mod.note(b, "  CanAim {s}: {d} calls", .{ me.obj.name, s.aim_calls });
    return s.best;
}

/// Weapons by the scoring (`Scoring.keep`) the fighter's CanUse allows.
fn filterWeapons(s: *Search) void {
    var n: usize = 0;
    for (s.weapons[0..s.n_weapons]) |wpn| {
        const keep = switch (s.ev.keep) {
            .all, .free_arms => true,
            .by_health => keepByHealth(s, wpn),
            .first => n == 0,
        };
        if (!keep or !canUse(s, wpn)) continue;
        s.weapons[n] = wpn;
        n += 1;
    }
    s.n_weapons = n;
}

/// Garcia's long one (`secondaryWeapon`) only below half health (0x4dfe8d).
fn keepByHealth(s: *const Search, wpn: *Object) bool {
    return (wpn.getInt("secondary") != 0) == (s.me.hp() * 2 < fields.maxHp(s.me.obj));
}

/// Its CanUse(weapon): native Arms, the Messiah's, not the arm a box blocks (1019 by
/// (10,19), 1020 by (10,17)). Out of memory reads as may (no error path here).
fn canUse(s: *const Search, wpn: *Object) bool {
    const v = (natives.ask(s.w, s.me.obj, "Fighter.CanUse", .{wpn.ref()}) catch return true) orelse return true;
    return v.truth();
}

fn params(f: Fighter, prof: Profile) Params {
    var p: Params = .{
        .attack = prof.attack_weight orelse f.obj.getInt("ai_attack_weight"),
        .defense = prof.threat_weight orelse f.obj.getInt("ai_threat_weight"),
        .player_dist = prof.opponent_distance_weight orelse f.obj.getInt("ai_opponent_distance_weight"),
        .guard_dist = prof.guard_distance_weight orelse f.obj.getInt("ai_guard_distance_weight"),
        .mode = prof.mode orelse f.obj.getInt("ai_mode"),
    };
    // Heroes without their own parameters (autobattle) act as an ordinary monster.
    if (p.attack == 0 and p.defense == 0 and p.player_dist == 0) p = .{ .attack = 10, .defense = 2, .player_dist = 100, .guard_dist = 100, .mode = 0 };
    return p;
}

/// Threat map from opponents (0x49af80, 0x4ce930).
fn buildDanger(s: *Search) !void {
    const b = s.b;
    @memset(s.danger, 0);
    const slot = b.ai_scratch.slot;
    const left = b.ai_scratch.left;
    const g = b.grid();
    for (s.foes[0..s.n_foes]) |fi| {
        const f = b.fighters.items[fi];
        @memset(slot, 0);
        var list: [16]*Object = undefined;
        const ws = weapons.threatWeaponsOf(s.w, f, &list);
        grid.reach(g, left, f.tile, f.size, fi, @floatFromInt(f.walkRange()));
        var wi: [16]WInfo = undefined;
        for (ws, 0..) |wpn, i| wi[i] = weaponInfo(wpn);
        for (0..b.height) |y| for (0..b.width) |x| {
            if (left[y * b.width + x] < 0) continue;
            const from: Tile = .{ @intCast(x), @intCast(y) };
            for (wi[0..ws.len]) |info| {
                const pat = info.pat orelse continue;
                const md = info.md;
                for (grid.targets(g, pat, from, fi, false, false, &s.targets_buf)) |aim| {
                    var eff: [128]Tile = undefined;
                    // 0x494f20: a tile is a byte; larger values store the low byte
                    // (`mov byte ptr [eax], cl`), no saturation.
                    const v: i32 = @divTrunc(@as(i32, aim.pct) * md, 100);
                    for (grid.effectTiles(g, pat, aim, &eff)) |t| {
                        const k = grid.tileIndex(b.width, t);
                        if (v > slot[k]) slot[k] = @truncate(@as(u32, @bitCast(v)));
                    }
                }
            }
        };
        for (s.danger, slot) |*d, v| d.* += v;
    }
}

const neighbours = [8]struct { d: Tile, cost: f32 }{
    .{ .d = .{ -1, -1 }, .cost = grid.diagonal_cost_ai }, .{ .d = .{ 0, -1 }, .cost = 1 },
    .{ .d = .{ 1, -1 }, .cost = grid.diagonal_cost_ai },  .{ .d = .{ 1, 0 }, .cost = 1 },
    .{ .d = .{ 1, 1 }, .cost = grid.diagonal_cost_ai },   .{ .d = .{ 0, 1 }, .cost = 1 },
    .{ .d = .{ -1, 1 }, .cost = grid.diagonal_cost_ai },  .{ .d = .{ -1, 0 }, .cost = 1 },
};

/// 0x498ed0: tile `t` at depth `depth`, walk budget left `budget`.
fn search(s: *Search, depth: usize, t: Tile, budget: f32, carry_in: Carry) void {
    if (budget < 0 or depth >= battle_mod.max_path or !s.b.grid().inside(t)) return;
    s.path[depth] = t;
    const g = s.b.grid();
    g.place(t, s.me.size, s.who);
    var carry = carry_in;
    evaluate(s, depth, t, &carry);
    g.remove(t, s.me.size);
    if (!s.can_move) return;
    for (neighbours) |n| {
        const nt: Tile = .{ t[0] + n.d[0], t[1] + n.d[1] };
        if (!g.fits(nt, s.me.size, s.who)) continue;
        search(s, depth + 1, nt, budget - n.cost, carry);
    }
}

/// 0x499170: tile score.
fn evaluate(s: *Search, depth: usize, t: Tile, carry: *Carry) void {
    const b = s.b;
    // Smoke Rider tries its weapons even without "can strike" (0x4de890).
    const try_attack = s.can_attack or s.ev.wakeful;
    if (try_attack) {
        // The best strike from `t` is the tile's alone (not the path's): computed once a
        // plan; the path's carry takes it as the exe's aim loop would (strictly better).
        const c = &s.strikes[grid.tileIndex(b.width, t)];
        if (!c.done) c.* = attackFrom(s, t);
        if (c.weapon != null and c.score > carry.score) carry.* = .{ .score = c.score, .depth = depth, .weapon = c.weapon, .aim = c.aim };
    }
    // The Guard ignores threat (no call to 0x494f90): profile `threat`.
    const danger: i32 = if (!s.prof.threat.?) 0 else s.danger[grid.tileIndex(b.width, t)];
    var score = carry.score -% s.p.defense *% danger;
    if (s.grandma_dist) |gd| {
        const d = at(s, gd, t);
        if (d > 3) score -%= s.p.guard_dist *% value.floatToInt(d);
    }
    if (s.n_decoys > 0) score -%= s.prof.decoy_pull.? *% s.p.player_dist *% value.floatToInt(nearestDecoy(s, t));
    if (carry.weapon == null) {
        if (s.p.mode == 3 and s.guard != null) {
            const d = pathLen(s, s.guard_dist, s.guard.?, t);
            score -%= if (d >= 0) s.p.guard_dist *% value.floatToInt(d) else 100 *% s.p.guard_dist;
        } else {
            score -%= s.p.player_dist *% value.floatToInt(nearestFoe(s, t));
        }
    } else if (s.me.side == .enemy and s.prof.step_away.?) {
        // After the strike, step away (the Guard stays).
        score +%= s.p.player_dist *% value.floatToInt(nearestFoe(s, t));
    }
    // Heroes in autoplay don't step away after striking (enemies do, per the exe).
    if (score > s.best.score or (score == s.best.score and depth + 1 < s.best.len)) {
        s.best = .{ .score = score, .len = depth + 1, .weapon = carry.weapon, .aim = carry.aim };
        s.best.attack_at = if (carry.weapon != null) carry.depth else null;
        @memcpy(s.best.path[0 .. depth + 1], s.path[0 .. depth + 1]);
    }
}

/// The best strike from tile `t` (the first of the highest score; none: weapon null).
fn attackFrom(s: *Search, t: Tile) battle_mod.TileStrike {
    const g = s.b.grid();
    var best: battle_mod.TileStrike = .{ .done = true, .score = std.math.minInt(i32) };
    for (s.weapons[0..s.n_weapons], s.winfo[0..s.n_weapons]) |wpn, *wi| {
        const pat = wi.pat orelse continue;
        const md = wi.md;
        for (grid.targets(g, pat, t, s.who, true, false, &s.targets_buf)) |aim| {
            if (wi.range > 0 and @max(@abs(aim.tile[0] - t[0]), @abs(aim.tile[1] - t[1])) > wi.range) continue;
            // A sleeping Smoke Rider sees only a ±π/4 cone from its facing.
            if (s.ev.wakeful and !s.can_attack and !inCone(s, t, aim.tile)) continue;
            if (wi.can_aim and !canAim(s, wpn, aim.tile)) continue;
            var eff: [128]Tile = undefined;
            var sum: i32 = 0;
            if (s.ev.wakeful and !s.can_move) sum = dist2(t, aim.tile);
            for (grid.effectTiles(g, pat, aim, &eff)) |et| {
                const o = g.at(et);
                // OpenGorky: its scoring's component scores the tile (Enemy.ScoreTile).
                if (s.score_tile) if (tileScore(s, et, o, wpn, t, aim, md)) |v| {
                    sum +%= if (o != grid.Grid.none and s.score_target) scoreTarget(s, o, wpn, v) else v;
                    continue;
                };
                if (s.ev.tile == .whole) {
                    sum +%= classic(incubusTile(s, o, et, t, aim, md));
                    continue;
                }
                if (o == grid.Grid.none) continue;
                // Heroes' autoplay (gorky-tool only; in the game the player controls heroes):
                // the Messiah is hurt only from tile (10,18) (0x4cee33: `open_from`), so from
                // other tiles he isn't a target, or the heroes would shoot past him all battle.
                if (s.me.side == .hero and s.b.fighters.items[o].obj.implementsC("CanBeStruck")) if (strike.closedTo(s.w, s.b.fighters.items[o], t)) continue;
                // A 2×2 fighter covers several tiles; the original counts each.
                const sc = occupantScore(s, o, wi, md, aim.pct);
                sum +%= if (s.score_target) scoreTarget(s, o, wpn, sc) else sc;
            }
            const score = s.p.attack *% sum;
            if (score > best.score) best = .{ .done = true, .score = score, .weapon = wpn, .aim = aim };
        }
    }
    return best;
}

/// The weapon's CanAim(user, tile) for an aim at `tile` (a hot point, counted). Out of
/// memory reads as may (no error path here).
fn canAim(s: *Search, wpn: *Object, tile: Tile) bool {
    s.aim_calls += 1;
    const xy = events.tileList(s.w, tile) catch return true;
    const v = (natives.ask(s.w, wpn, "Weapon.CanAim", .{ s.me.obj.ref(), value.Value{ .list = xy } }) catch return true) orelse return true;
    return v.truth();
}

/// Its ScoreTile(tile, occupant, weapon, here, aim, damage, pct) for hit tile `et` (fighter
/// `o` on it or none) of an aim from `here`: the answer, null for none (the scoring's own).
/// Out of memory reads as no answer.
fn tileScore(s: *Search, et: Tile, o: u16, wpn: *Object, here: Tile, aim: grid.Target, md: i32) ?i32 {
    const w = s.w;
    const occ: value.Value = if (o == grid.Grid.none) .nil else s.b.fighters.items[o].obj.ref();
    const args = .{ value.Value{ .list = events.tileList(w, et) catch return null }, occ, wpn.ref(), value.Value{ .list = events.tileList(w, here) catch return null }, value.Value{ .list = events.tileList(w, aim.tile) catch return null }, value.Value{ .int = md }, value.Value{ .int = aim.pct } };
    const v = (natives.ask(w, s.me.obj, "Enemy.ScoreTile", args) catch return null) orelse return null;
    return v.toInt();
}

/// Its ScoreTarget(occupant, weapon, score) over the scoring's `score` of fighter `o` (a
/// hot point, counted). Out of memory reads as no answer.
fn scoreTarget(s: *Search, o: u16, wpn: *Object, score: i32) i32 {
    s.score_calls += 1;
    const v = (natives.ask(s.w, s.me.obj, "Enemy.ScoreTarget", .{ s.b.fighters.items[o].obj.ref(), wpn.ref(), value.Value{ .int = score } }) catch return score) orelse return score;
    return v.toInt();
}

/// Contribution of fighter `o` on a hit tile, by scoring (`Scoring.occupant`).
fn occupantScore(s: *const Search, o: u16, wi: *const WInfo, md: i32, pct: u8) i32 {
    return switch (s.ev.occupant) {
        .generic => occupantGeneric(s, o, wi, md, pct),
        .a => occupantA(s, o, wi, md, pct),
        .no_lock => occupantNoLock(s, o, wi, md, pct),
        .avenge => classic(occupantAvenge(s, o, md, pct)),
        .sleep_hunter => classic(occupantSleepHunter(s, o, wi)),
        .heroes_only => classic(if (s.b.fighters.items[o].side == .hero) @as(i32, 10) else -100),
        .foes => if (isFoe(s, o)) @divTrunc(md *% @as(i32, pct), 100) else 0,
        .none => 0,
    };
}

/// A Classic piece's score `v` (the exe's special scorings: an OpenGorky project's are its
/// components' ScoreTile, the converter's): counted where an OpenGorky project uses it.
fn classic(v: i32) i32 {
    if (@import("../rules.zig").og) @import("../rules.zig").classicPath("ai: a Classic scoring piece");
    return v;
}

fn isFoe(s: *const Search, o: u16) bool {
    const f = s.b.fighters.items[o];
    return f.side != s.me.side and f.side != .neutral;
}

/// The profile's constants (rules ai.ss): +5, ×100, a monitor ×2, an ally −10×.
fn occupantGeneric(s: *const Search, o: u16, wi: *const WInfo, md: i32, pct: u8) i32 {
    const p: i32 = pct;
    const base = (md +% s.prof.damage_bonus.?) *% p;
    if (s.locked != null and o == s.locked.?) return @divTrunc(base *% s.prof.lock.?, 100);
    if (isFoe(s, o)) {
        var k: i32 = if (s.finfo[o].monitor) s.prof.monitor.? else 1;
        if (s.me.side == .hero) k *= heroPriority(s.w.immunity, &s.finfo[o], wi, md);
        return @divTrunc(base *% k, 100);
    }
    return @divTrunc((0 -% base) *% s.prof.ally_penalty.?, 100);
}

/// Scoring A and its variants: damage × pct / 100, AITargetLock target ×100 (not for the
/// Cripple), others −10× (the profile's: no +5, a monitor ×1).
fn occupantA(s: *const Search, o: u16, wi: *const WInfo, md: i32, pct: u8) i32 {
    if (s.locked != null and o == s.locked.?) return @divTrunc((md +% s.prof.damage_bonus.?) *% @as(i32, pct) *% s.prof.lock.?, 100);
    return occupantNoLock(s, o, wi, md, pct);
}

fn occupantNoLock(s: *const Search, o: u16, _: *const WInfo, md: i32, pct: u8) i32 {
    const base = (md +% s.prof.damage_bonus.?) *% @as(i32, pct);
    if (isFoe(s, o)) return @divTrunc(base *% (if (s.finfo[o].monitor) s.prof.monitor.? else 1), 100);
    return @divTrunc((0 -% base) *% s.prof.ally_penalty.?, 100);
}

/// Grandma strikes only her target (her child's killer).
fn occupantAvenge(s: *const Search, o: u16, md: i32, pct: u8) i32 {
    return if (s.me.grandma_target != null and o == s.me.grandma_target.?) md *% @as(i32, pct) else 0;
}

/// Guard (0x4e2260): melee (`secondaryWeapon`) +100 per sleeping hero, the sleep shot +1
/// per awake one (0x4e2374…0x4e239b).
fn occupantSleepHunter(s: *const Search, o: u16, wi: *const WInfo) i32 {
    const f = s.b.fighters.items[o];
    if (f.side != .hero) return 0;
    const asleep = f.asleep > 0;
    return if (wi.secondary) (if (asleep) 100 else 0) else (if (asleep) 0 else 1);
}

/// Incubus (0x4e2b50) scores a hit tile: occupied −10×; empty, on the first
/// activation `200 − damage·pct·d/100` (d = nearest hero, dx² + dy²), on the second
/// `(path tile − aim)² · damage·pct/100`.
fn incubusTile(s: *const Search, o: u16, et: Tile, here: Tile, aim: grid.Target, md: i32) i32 {
    const p: i32 = aim.pct;
    if (o != grid.Grid.none) return @divTrunc(-10 *% md *% p, 100);
    if (!s.me.second) {
        var dmin: i32 = std.math.maxInt(i32);
        for (s.b.fighters.items) |f| if (f.side == .hero and f.alive()) {
            dmin = @min(dmin, dist2(et, f.tile));
        };
        if (dmin <= 0 or dmin == std.math.maxInt(i32)) dmin = 100;
        return 200 -% @divTrunc(md *% p *% dmin, 100);
    }
    return @divTrunc(dist2(here, aim.tile) *% md *% p, 100);
}

fn dist2(a: Tile, b: Tile) i32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return dx * dx + dy * dy;
}

/// Aim within a ±π/4 cone of the fighter's facing (0x50a210).
fn inCone(s: *Search, from: Tile, to: Tile) bool {
    const want = fields.facing(@floatFromInt(to[0] - from[0]), @floatFromInt(to[1] - from[1]));
    const cur = s.me.obj.getVar("angle").?.value.toFloat();
    const d = std.math.atan2(@sin(want - cur), @cos(want - cur));
    return @abs(d) <= std.math.pi * 0.25;
}

/// Heroes' autoplay only (in the original the player controls them): like a
/// player, hit those who freeze and put to sleep first (otherwise they lock a hero
/// out all battle), and finish off the wounded.
fn heroPriority(known: *immunity.Known, f: *const FInfo, wi: *const WInfo, max_damage: i32) i32 {
    // Target immune to the weapon's damage kind: pointless; like a player we know
    // only what was discovered.
    if (wi.dcode) |code| {
        if (known.isKnown(f.who, code)) return 0;
    }
    var k: i32 = 1;
    if (f.weff) |e| {
        if (e == .freeze or e == .sleep) k *%= 3;
    }
    if (f.hp <= max_damage) k *%= 2;
    return k;
}

/// Path to the nearest decoy (unreachable 10000, the initial 0x40c38800).
fn nearestDecoy(s: *Search, t: Tile) f64 {
    var best: f64 = 10000;
    for (s.decoy_dist[0..s.n_decoys], s.decoy_tile[0..s.n_decoys]) |d, dt| {
        var v = pathLen(s, d, dt, t);
        if (v < 0) v = 10000;
        best = @min(best, v);
    }
    return best;
}

/// Distance to the nearest opponent (by path; unreachable 100, none 10000).
fn nearestFoe(s: *Search, t: Tile) f64 {
    var best: f64 = 10000;
    for (0..s.n_foes) |k| {
        var d = pathLen(s, s.foe_dist[k], s.foe_tile[k], t);
        if (d < 0) d = 100;
        best = @min(best, d);
    }
    return best;
}

/// Path length from tile `t` to target `to` (0x49a630), cached per tile; −1 = unreachable.
fn pathLen(s: *Search, cache: []f32, to: Tile, t: Tile) f64 {
    // A tile outside the grid (a party hero the battle script didn't place stands at
    // its level coordinates) is unreachable; otherwise we'd index past the cache.
    if (t[0] < 0 or t[1] < 0 or t[0] >= s.b.width or t[1] >= s.b.height) return -1;
    const k = grid.tileIndex(s.b.width, t);
    if (std.math.isNan(cache[k])) cache[k] = wave(s, t, to);
    return cache[k];
}

/// 0x49a630: wave from fighter tile `from` (the fighter stands on it) to a tile
/// next to the target: the target's top-left corner in [x − 1, x + s + 1] on both
/// axes, s = ⌊√charSize − 1⌋ (0x49a64f…0x49a71b). The queue is in insertion
/// order: straight neighbours (↑ → ↓ ←, +1), then diagonal (↖ ↗ ↘ ↙, +1.5;
/// 0x49a730…0x49a897); a tile is marked visited after it's processed (0x49a89e)
/// and visited ones are skipped. The answer is the cost of the first matching tile
/// (0x49a8d5); an empty queue gives −1 (0x49a8c5).
fn wave(s: *Search, from: Tile, to: Tile) f32 {
    return grid.waveLen(s.b.grid(), s.visited, s.queue, s.me.size, from, to);
}

fn at(s: *Search, field: []const f32, t: Tile) f64 {
    const v = field[grid.tileIndex(s.b.width, t)];
    return if (v == std.math.inf(f32)) -1 else v;
}

/// 0x49a630 for all tiles at once: path length of the fighter to a tile next to
/// target `to` (of size `to_size`) (step 1, diagonal 1.5; start value
/// √charSize − 1). The wave runs from the target; infinity = unreachable.
fn distanceField(s: *Search, d: []f32, to: Tile, to_size: u32) void {
    const b = s.b;
    const g = b.grid();
    const size = s.me.size;
    @memset(d, std.math.inf(f32));
    const start: f32 = num.toF32(size) - 1;
    const si: i32 = @intCast(size);
    const ti: i32 = @intCast(to_size);
    // Tiles next to the target (rectangles touch, diagonals included).
    for (0..b.height) |y| for (0..b.width) |x| {
        const t: Tile = .{ @intCast(x), @intCast(y) };
        const near = to[0] <= t[0] + si and to[0] + ti >= t[0] and to[1] <= t[1] + si and to[1] + ti >= t[1];
        if (near and g.fits(t, size, s.who)) d[y * b.width + x] = start;
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (0..b.height) |y| for (0..b.width) |x| {
            const here = d[y * b.width + x];
            if (here == std.math.inf(f32)) continue;
            const t: Tile = .{ @intCast(x), @intCast(y) };
            for (neighbours) |n| {
                const nt: Tile = .{ t[0] + n.d[0], t[1] + n.d[1] };
                if (!g.inside(nt) or !g.fits(nt, size, s.who)) continue;
                const k = grid.tileIndex(b.width, nt);
                if (here + n.cost < d[k] - 1e-4) {
                    d[k] = here + n.cost;
                    changed = true;
                }
            }
        };
    }
}

test "distance rows: Grandma's child's row is none of the decoys' nor the guard's (4 decoys, OpenGorky)" {
    for (0..Rows.max_decoys) |k| try std.testing.expect(Rows.decoy_row + k != Rows.near_row and Rows.decoy_row + k > Rows.guard_row);
    try std.testing.expect(Rows.guard_row >= battle_mod.max_fighters and Rows.near_row < Rows.dist_rows);
    try std.testing.expectEqual(Rows.max_decoys, @typeInfo(@FieldType(Search, "decoy_dist")).array.len);
}
