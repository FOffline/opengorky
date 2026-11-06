//! Attack visuals at the hit (callback 0x4863c0): the effect descriptions' parts
//! (core/effect.zig) as effect objects — muzzle flashes, smoke, beams, streams, flames,
//! special monster attacks — and weapon sounds.

const std = @import("std");
const vec = @import("../vec.zig");
const fields = @import("../fields.zig");
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;
const generic = @import("../battle.zig").generic;
const Fx = generic.Fx;
const camera = @import("../actor.zig").camera;
const core = @import("../core.zig");
const modules = core.modules;
const desc = core.effect;
const place = @import("place.zig");
const explosion = @import("explosion.zig");
const batch = @import("../effects.zig").batch;
const rules = @import("../rules.zig");

/// Flash rotation (chaingun 0x48ca21…0x48cb0b; rifle and shotgun only Ry):
/// Rz(z)·Ry(y), exe row-major matrices (as in rotationXYZ), product 0x47cd30(out, Rz, Ry).
fn zyRot(z: f32, y: f32) [9]f32 {
    const cz = @cos(z);
    const sz = @sin(z);
    const cy = @cos(y);
    const sy = @sin(y);
    const rz = [9]f32{ cz, -sz, 0, sz, cz, 0, 0, 0, 1 };
    const ry = [9]f32{ cy, 0, -sy, 0, 1, 0, sy, 0, cy };
    var o: [9]f32 = undefined;
    for (0..3) |i| for (0..3) |j| {
        o[i * 3 + j] = rz[i * 3] * ry[j] + rz[i * 3 + 1] * ry[3 + j] + rz[i * 3 + 2] * ry[6 + j];
    };
    return o;
}

fn rotOf(r: desc.Rot) [9]f32 {
    return switch (r) {
        .matrix => |m| m,
        .xyz => |a| camera.rotationXYZ(a),
        .zy => |a| zyRot(a[0], a[1]),
    };
}

/// The hero's muzzle flash of `weapon` (its description's attached effect; the editor's page).
pub fn flashFor(weapon: i32, attacker: i32) ?desc.Attach {
    const d = modules.weaponFx(weapon, attacker) orelse return null;
    for (d.flash) |p| if (p == .attach) return p.attach;
    return null;
}

/// Point at the barrel (callback 11, 0x4863c0): position + aS·(10 right, 220 forward, 530 up).
fn muzzle(o: *Object, as: f32) [3]f32 {
    return place.offsetPoint(o, as, .{ 220, 10, 530 });
}

/// Strike of `who` with weapon `wpn` at point `target` (aim tile centre on the floor).
/// `second`: second hit of a series (Headnail's right saw).
pub fn onHit(w: *World, who: *Object, wpn: *Object, target: [3]f32, second: bool) void {
    onHitFx(w, who, generic.fxOf(who, wpn), target, second);
}

/// Same by weapon classic_id (every stage its, the attacker's classic_id's specials).
pub fn onHitAs(w: *World, who: *Object, id: i32, target: [3]f32, second: bool) void {
    onHitFx(w, who, .same(id, fields.classicId(who)), target, second);
}

/// Same by stages (generic.Fx): the monster's shot flash by `flash`, the fighter's own by
/// `special` (with the weapon `hit`), the hit's effects by `hit`.
pub fn onHitFx(w: *World, who: *Object, fx: Fx, target: [3]f32, second: bool) void {
    if (modules.weaponFx(fx.flash, fields.classicId(who))) |d| run(w, who, d.shot, target, fx.weapon);
    if (modules.fighterFx(fx.special, fx.hit)) |f| run(w, who, if (second and f.second.len > 0) f.second else f.hit, target, fx.weapon);
    hitEffects(w, who, fx, target);
}

/// Before the hit (MonsterAttack.flash_delay, HeroAttack.pre): the fighter's own (with the weapon
/// `flash`) instead of the weapon's (Garcia's burst, Schizo's bell gas, the ion rifle
/// beam, the blaster streams).
pub fn preFlash(w: *World, who: *Object, fx: Fx, target: [3]f32) void {
    if (modules.fighterFx(fx.special, fx.flash)) |f| if (f.pre.len > 0) return run(w, who, f.pre, target, fx.weapon);
    if (modules.weaponFx(fx.flash, fields.classicId(who))) |d| run(w, who, d.pre, target, fx.weapon);
}

/// Run a description's parts for `who` striking at `target` (aim tile centre on the floor).
fn run(w: *World, who: *Object, parts: []const desc.Part, target: [3]f32, wpn: ?*Object) void {
    const e = &w.effects;
    const gpa = w.gpa;
    const as = w.actorScale();
    for (parts) |part| switch (part) {
        .attach => |a| e.attach(gpa, .{ .actor = who, .effect = a.effect, .link = a.link, .offset = a.offset, .rot = rotOf(a.rot), .scale = a.scale, .start = 0, .left = a.ticks.ticks() }),
        .bitmap => |b| {
            var x = b.b;
            x.pos = if (b.at == .muzzle) muzzle(who, as) else lifted(target, b.lift, as);
            if (b.size) |v| x.size = v.get();
            if (b.rgb) |c| x.rgb = c.get();
            explosion.bitmap(w, x);
        },
        .explosion => |l| explosion.explosion(w, .{ target[0], target[1], target[2] + l.get() * as }),
        .light => |l| {
            var pos = place.offsetPoint(who, as, .{ l.at[0].get(), l.at[1].get(), l.at[2].get() });
            if (l.toward) |t| {
                const q = place.at(w, who, t, target);
                const d = vec.normalize(.{ q[0] - pos[0], q[1] - pos[1], q[2] - pos[2] });
                pos = .{ pos[0] + d[0] * l.ahead * as, pos[1] + d[1] * l.ahead * as, pos[2] + d[2] * l.ahead * as };
            }
            e.addLight(gpa, .{ .pos = pos, .color = l.color orelse l.rgb.get(), .range = if (l.range_as) l.range * as else l.range, .left = l.ticks });
        },
        .beam => |r| {
            const from = if (r.from) |a| place.at(w, who, a, target) else lifted(target, r.lift, as);
            var rb: [128]Run = undefined;
            for (if (r.to) |a| runs(w, who, from, a, target, &rb) else &[1]Run{.{ .from = from, .to = from }}) |rn| beam(w, who, r, rn);
        },
        .sound => |snd| w.out.delayed_sounds.append(gpa, .{ .name = snd.name, .pos = w.screenPos(who), .ticks = snd.ticks }) catch {},
        .shake => |t| w.out.earthquake = t.ticks(),
        .emitter => |m| {
            var rb: [128]Run = undefined;
            for (runs(w, who, place.at(w, who, m.at, target), m.aim, target, &rb)) |rn| emitter(w, who, m, rn, wpn);
        },
        .ribbon => |rb| {
            var buf: [128]Run = undefined;
            for (runs(w, who, place.at(w, who, rb.from, target), rb.to, target, &buf)) |rn| stream(w, rn.from, rn.to, rb, rn.delay);
        },
        .mesh => |m| {
            var s = m.s;
            s.pos = place.at(w, who, m.at, target);
            e.spins.append(gpa, s) catch {};
        },
        .cloud => |c| {
            var cl = c.c;
            cl.pos = place.at(w, who, c.at, target);
            e.clouds.append(gpa, cl) catch {};
            for (0..c.rand_draws) |_| _ = w.crt().next();
        },
        // Read as its parts (loaders/rules_text.zig dataForm): none reaches here.
        .code => {},
    };
}

/// One run of a part: from, to, ticks after the strike.
const Run = struct { from: [3]f32, to: [3]f32, delay: u32 = 0 };

/// The runs of a part from `from` to the points of `to` (`place.points`): one each; a
/// chain's from the link before, each its `delay` after it.
fn runs(w: *World, who: *Object, from: [3]f32, to: desc.At, target: [3]f32, out: *[128]Run) []Run {
    var buf: [128][3]f32 = undefined;
    var pts = place.points(w, who, to, target, &buf);
    if (to == .chain) pts = place.chainOrder(from, pts, to.chain.n);
    var prev = from;
    for (pts, 0..) |p, i| {
        out[i] = .{ .from = prev, .to = p };
        if (to == .chain) {
            out[i].delay = @intCast(i * to.chain.delay);
            prev = p;
        }
    }
    return out[0..pts.len];
}

/// A beam part on one run.
fn beam(w: *World, who: *Object, r: desc.Ray, run_: Run) void {
    const as = w.actorScale();
    var b = r.b;
    b.from = run_.from;
    b.to = run_.to;
    b.delay += run_.delay;
    for (r.chains[0..@min(r.chains.len, b.chains.len)], 0..) |c, i| b.chains[i] = .{ .start = c.start.get(), .step = c.step, .n = c.n };
    if (r.size) |v| b.size = v.get();
    if (r.ticks) |t| b.left = t.ticks();
    if (r.actor) b.actor = who;
    // An ion beam's axis without a model: from the barrel toward `to` turned by
    // `turn` (0x4a1600; each frame the viewer takes the link point's).
    if (b.kind == .ion) {
        const d = place.dirTo(who, muzzle(who, as), b.to);
        const a = b.turn;
        b.dir = .{ d[0] * @cos(a) - d[1] * @sin(a), d[0] * @sin(a) + d[1] * @cos(a), 0 };
    }
    w.effects.beams.append(w.gpa, b) catch {};
}

const lifted = place.lifted;

/// Hit effects by weapon classic_id (monster flashes excluded).
pub fn onHitId(w: *World, who: *Object, id: i32, target: [3]f32) void {
    hitEffects(w, who, .same(id, fields.classicId(who)), target);
}

/// The hero flash by `fx.flash`, the sound and the hit's effects by `fx.hit`.
fn hitEffects(w: *World, who: *Object, fx: Fx, target: [3]f32) void {
    if (modules.weaponFx(fx.flash, fields.classicId(who))) |d| run(w, who, d.flash, target, fx.weapon);
    // Weapon sound on hit (0x4327f0 calls in weapon effects, 0x487afd…0x4a8e31).
    if (fx.sound orelse @import("../rules.zig").weaponSound(fx.hit)) |snd| {
        const q = w.cam.project(target);
        w.out.sound(w.gpa, snd, .{ q.x, q.y });
    }
    if (modules.weaponFx(fx.hit, fields.classicId(who))) |d| run(w, who, d.hit, target, fx.weapon);
}

/// Stream from `from` to `to` (0x4a28e0; the blaster's 120 ticks).
fn stream(w: *World, from: [3]f32, to: [3]f32, rb: desc.Ribbon, delay: u32) void {
    const d = [3]f32{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    const len = vec.len(d);
    if (len <= 0) return;
    w.effects.streams.append(w.gpa, .{
        .start = from,
        .v = .{ d[0] / len, d[1] / len, d[2] / len },
        .len = len,
        .as = w.actorScale(),
        .look = rb.look,
        .left = rb.look.life,
        .delay = rb.delay + delay,
    }) catch {};
}

/// Medusa's current (0x4a44e0, also VOLTAGE): the `current` preset.
pub fn current(w: *World, who: *Object) void {
    run(w, who, core.classic.preset(.current), fields.pos(who), null);
}

/// Flame emitter (0x4a06f0): from `at` toward `aim`, the first particle `ahead`·aS along.
fn emitter(w: *World, who: *Object, m: desc.Emitter, run_: Run, wpn: ?*Object) void {
    const as = w.actorScale();
    const src = run_.from;
    const q = run_.to;
    const d = vec.normalize(.{ q[0] - src[0], q[1] - src[1], q[2] - src[2] });
    const ahead = m.ahead.get();
    const speed = m.speed.get();
    const start = [3]f32{ src[0] + d[0] * ahead * as, src[1] + d[1] * ahead * as, src[2] + d[2] * ahead * as };
    w.effects.flames.append(w.gpa, .{
        .src = start,
        .dir = .{ d[0] * speed * as, d[1] * speed * as, d[2] * speed * as },
        .timer = @intFromFloat(m.timer.get()),
        // The particle limit (0x4a0764…0x4a0789).
        .max = @intFromFloat(std.math.clamp(m.max.get(), 0, 180)),
        .life = @intFromFloat(@max(0, m.life.get())),
        .base = src,
        .ahead = ahead * as,
        .speed = speed * as,
        .actor = if (m.link.len > 0) who else null,
        .link = m.link,
        .link2 = m.link2,
        .rot = m.rot,
        .ends_attack = m.holds_attack,
        .delay = m.delay + run_.delay,
        .spread = m.spread,
        .gravity = m.gravity * as,
        .drag = m.drag,
        .look = m.look,
        .tune = if (wpn) |x| batch.flameTune(rules.who(x)) else null,
        .material = m.material,
    }) catch {};
}

// ---------------------------------------------------------------- tests

/// A world holding only effects (as the editor's preview) and a striker at `pos` facing
/// `angle`, classic_id `id`.
const TestWorld = struct {
    w: World,
    who: Object = .{ .name = "", .class = undefined },
    native: @import("../state.zig").object.Native = @import("../state.zig").object.nativeFor(".act"),

    fn init(t: *TestWorld, id: i32) !void {
        const gpa = std.testing.allocator;
        t.* = .{ .w = .{ .gpa = gpa, .io = std.testing.io, .arena_state = .init(gpa), .rt = undefined, .level_name = "", .res = .{}, .immunity = undefined, .fx_alone = true } };
        t.who.host = &t.native;
        for ([_][]const u8{ "x", "y", "z", "angle" }, [_]f32{ 120.5, -40.25, 3, 0.7 }) |n, v| try t.who.declare(gpa, n, .{ .type = .float, .value = .{ .float = v } });
        try t.who.declare(gpa, "nameid", .{ .type = .int, .value = .{ .int = id } });
    }

    fn deinit(t: *TestWorld) void {
        t.w.effects.deinit(t.w.gpa);
        t.w.out.deinit(t.w.gpa);
        t.who.vars.deinit(t.w.gpa);
        t.w.arena_state.deinit();
    }
};

test "presets: what each makes, the cloud's one rand() (0x4a9685)" {
    const crt = @import("../crt_rand.zig");
    const target = [3]f32{ -310.5, 655.25, 7 };
    // beams, streams, clouds, flames, spins, lights; rand() calls.
    const want = [_][7]usize{ .{ 1, 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 0, 0, 0, 0 }, .{ 2, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 1, 0, 0, 0, 1 }, .{ 0, 0, 0, 1, 0, 1, 0 }, .{ 0, 0, 0, 1, 0, 0, 0 }, .{ 0, 0, 0, 1, 0, 0, 0 }, .{ 0, 0, 0, 0, 1, 0, 0 } };
    for (std.enums.values(desc.Code), want) |c, n| {
        var t: TestWorld = undefined;
        try t.init(0);
        defer t.deinit();
        errdefer std.debug.print("preset {t}\n", .{c});
        crt.global = .{};
        crt.global.seed(42);
        run(&t.w, &t.who, core.classic.preset(c), target, null);
        var draws: usize = 0;
        var r: crt.Rand = .{};
        r.seed(42);
        while (!std.meta.eql(r, crt.global) and draws < 8) : (draws += 1) _ = r.next();
        const e = &t.w.effects;
        try std.testing.expectEqual(n, [7]usize{ e.beams.items.len, e.streams.items.len, e.clouds.items.len, e.flames.items.len, e.spins.items.len, e.lights.items.len, draws });
        if (c == .cloud) try std.testing.expectEqual(target[2] + 130 * t.w.actorScale(), e.clouds.items[0].pos[2]);
    }
    // The data records are the table's (spot checks).
    try std.testing.expectEqual(core.classic.preset(.blaster).ptr, modules.weaponFx(1037, 0).?.pre.ptr);
    try std.testing.expectEqual(core.classic.preset(.ion).ptr, modules.weaponFx(1029, 0).?.pre.ptr);
    try std.testing.expectEqual(0.4, modules.weaponFx(1029, 26).?.pre[0].beam.b.turn);
    try std.testing.expectEqual(core.classic.preset(.cloud).ptr, modules.fighterFx(136, 1078).?.hit.ptr);
}
