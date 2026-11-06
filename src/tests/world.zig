//! World tests that build actor models by hand (core model records, core/model.zig).

const std = @import("std");
const anim = @import("../core.zig").model;
const queue = @import("../world.zig").queue;
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;
const Runtime = @import("../script.zig").runtime.Runtime;
const actor_mod = @import("../actor.zig");
const fields = @import("../fields.zig");
const model_cache = @import("../actor.zig").model_cache;
const Model = model_cache.Model;
const crt_rand = @import("../crt_rand.zig");

test "justify position: drawn root bone minus the last frame's (0x4240b7)" {
    const gpa = std.testing.allocator;
    var o: Object = .{ .name = "t", .class = undefined };
    defer o.vars.deinit(gpa);
    inline for (.{ "x", "y", "z", "angle" }) |n|
        try o.declare(gpa, n, .{ .type = .float, .value = .{ .float = 0 } });
    // Angle π/2: model axes are world axes (modelAngle 0).
    fields.setAngle(&o, std.math.pi / 2.0);
    var mats = [_][12]f32{ @splat(0), @splat(0) };
    mats[0][9] = 3; // drawn frame 0: root x 3, height 1
    mats[0][10] = 1;
    mats[1][11] = 2; // last frame 1: root z 2
    var anims = [_]anim.Animation{.{ .name = "idle", .first = 0, .last = 1, .speed = 0, .sounds = &.{} }};
    var m: Model = undefined;
    m.anims = .{ .items = &anims };
    m.frames = .{ .frames = 2, .bones = 1, .matrices = &mats, .extra = &.{} };
    // Idle just started with a transition: drawn pose = blend start (frame 0).
    const a: actor_mod.Actor = .{ .anim = "idle", .anim_hold = actor_mod.Actor.blend_ticks, .blend_from = 0 };
    queue.justifyPosition(&o, &a, &m, 2);
    const p = fields.pos(&o);
    try std.testing.expectApproxEqAbs(@as(f32, 6), p[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -4), p[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 2), p[2], 1e-4);
}

test "reversed animation sounds follow the shown frame (0x44fb92)" {
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = undefined, .fetch = undefined });
    defer rt.deinit();
    var cls: @import("../script.zig").object.Class = .{ .name = "a.aba", .parent = null };
    try cls.vars.appendSlice(rt.arena(), &.{
        .{ .type = .float, .name = "x", .line = 0 },
        .{ .type = .float, .name = "y", .line = 0 },
        .{ .type = .float, .name = "z", .line = 0 },
    });
    const o = try rt.createObject("a", &cls);
    var cues = [_]anim.SoundCue{.{ .name = "step.wav", .frame = 13, .volume = 0 }};
    var anims = [_]anim.Animation{.{ .name = "go", .first = 10, .last = 13, .speed = 0, .sounds = &cues }};
    var m: model_cache.Model = undefined;
    m.anims = .{ .items = &anims };
    var w: World = undefined;
    w.gpa = std.testing.allocator;
    crt_rand.global = .{};
    w.out.sound_events = .empty;
    w.cam = .ortho;
    defer w.out.sound_events.deinit(w.gpa);
    // Reversed, the first shown frame is last (13), which has the sound.
    var a: actor_mod.Actor = .{ .anim = "go", .reverse = true, .loop = false };
    try queue.animCues(&w, o, &a, &m);
    try std.testing.expectEqual(1, w.out.sound_events.items.len);
    // Then 12, 11, 10 — silent.
    for (1..4) |t| {
        a.anim_ticks = @floatFromInt(t);
        try queue.animCues(&w, o, &a, &m);
    }
    try std.testing.expectEqual(1, w.out.sound_events.items.len);
}
