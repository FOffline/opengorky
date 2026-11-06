//! A level's background `.cfg` (`background\<level>.cfg` of its sprite.dat, parsed by
//! 0x41cc70 / 0x41cf07 in the exe). The rest of what a location is drawn with — the
//! picture, `.zbf` depth (zbuffer.zig), `.lts` lights (level_files.zig) — has its own
//! parsers; composition makes the core's record of them (core/map.zig `Backdrop`).

const std = @import("std");

/// Background parameters of an orthographic level. `frontPlane`/`backPlane` lines are
/// skipped: the camera takes them from the level object's vars (viewer/level/depth.zig).
pub const OrthoCfg = struct {
    gscale: f32 = 200,
    g0: f32 = 57088,
    g1: f32 = 27904,
};

/// `.cfg` of a perspective level: eye (vx, vy, vz), target (tx, ty, tz), scene depth `tl`.
const PerspCfg = struct {
    eye: [3]f32 = .{ 0, 0, 0 },
    target: [3]f32 = .{ 0, 0, 0 },
    tl: f32 = -1,
};

/// Background `.cfg` keys: `name value` per line. null for a perspective level (`tl`).
pub fn parseCfg(text: []const u8) ?OrthoCfg {
    var cfg: OrthoCfg = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\r");
        const key = it.next() orelse continue;
        const val = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        if (std.mem.eql(u8, key, "tl")) return null;
        if (std.mem.eql(u8, key, "gscale")) cfg.gscale = val;
        if (std.mem.eql(u8, key, "g0")) cfg.g0 = val;
        if (std.mem.eql(u8, key, "g1")) cfg.g1 = val;
    }
    return cfg;
}

/// Perspective `.cfg`: vx vy vz tx ty tz tl.
pub fn parsePerspCfg(text: []const u8) ?PerspCfg {
    var cfg: PerspCfg = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\r");
        const key = it.next() orelse continue;
        const val = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        const keys = [_][]const u8{ "vx", "vy", "vz", "tx", "ty", "tz" };
        for (keys, 0..) |k, i| if (std.mem.eql(u8, key, k)) {
            if (i < 3) cfg.eye[i] = val else cfg.target[i - 3] = val;
        };
        if (std.mem.eql(u8, key, "tl")) cfg.tl = val;
    }
    return if (cfg.tl > 0) cfg else null;
}

test parsePerspCfg {
    const c = parsePerspCfg("vx 0\nvy 3\nvz -4\ntx 0\nty 0\ntz 0\ntl 2\n").?;
    try std.testing.expectEqual([3]f32{ 0, 3, -4 }, c.eye);
    try std.testing.expectEqual(2, c.tl);
}

test parseCfg {
    const c = parseCfg("bkg 01_port\r\nfrontPlane 600.000000\r\ngscale 253.000000\r\ng0 57088\r\ng1 27904\r\n").?;
    try std.testing.expectEqual(253, c.gscale);
    try std.testing.expectEqual(57088, c.g0);
    try std.testing.expectEqual(null, parseCfg("vx -10.851\ntl 6.96675\n"));
}
