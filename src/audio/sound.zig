//! Engine sound logic (no output device): sound bank, volume and pan by screen
//! position, ambients, music choice. Reconstructed from gorky17.exe. The core reads no
//! files: the bank asks its `Source` (composition, compose/sounds.zig) for decoded sounds.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Parameters from adjust.kdt (defaults from the game file).
pub const Params = struct {
    volume_start: f32 = 320,
    volume_falloff: f32 = 0.004,
    pan_start: f32 = 320,
    pan_factor: f32 = 0.0008,
    /// adjust.kdt `dialog_sound_control`: 0 — no voice, lines advance by click.
    dialog_sound: bool = true,
};

/// Sounds quieter than this do not start (0x432608, constant 0.1).
pub const min_volume = 0.1;

pub const Positional = struct { volume: f32, pan: f32 };

/// Volume and pan of a sound at `pos` (background pixels) for a screen centred at
/// `center` (0x432a70). The original projects the point with the 3D camera; on
/// exploration levels these are background coordinates.
pub fn positional(pos: [2]f32, center: [2]f32, p: Params) Positional {
    const dx = pos[0] - center[0];
    const dy = pos[1] - center[1];
    const d = @max(0, @sqrt(dx * dx + dy * dy) - p.volume_start);
    const volume = std.math.clamp(1 - d * p.volume_falloff, 0, 1);
    var pan: f32 = 0;
    if (@abs(dx) > p.pan_start) {
        pan = (if (dx < 0) dx + p.pan_start else dx - p.pan_start) * p.pan_factor;
        pan = std.math.clamp(pan, -0.8, 0.8);
    }
    return .{ .volume = volume, .pan = pan };
}

/// Music candidates for a level in check order (0x41f9b0):
/// `<level>.mp3`, then the district's shared music for sublevels (rules DistrictMusic).
pub fn musicCandidates(level: []const u8, buf: *[2][]const u8) [][]const u8 {
    buf[0] = level;
    const district = @import("../core.zig").modules.districtMusic(level) orelse return buf[0..1];
    buf[1] = district;
    return buf[0..2];
}

/// A decoded sound: s16 PCM (composition decodes the files, compose/sounds.zig).
pub const Sound = struct {
    channels: u32,
    rate: u32,
    /// Interleaved samples, `frames * channels` of them.
    samples: []i16,

    pub fn frames(self: Sound) usize {
        return self.samples.len / self.channels;
    }

    pub fn deinit(self: *Sound, gpa: Allocator) void {
        gpa.free(self.samples);
        self.* = undefined;
    }
};

/// The archive a sound is in: effects (`common/sound.dat`) or music and speech (`voice.dat`).
pub const Which = enum { sounds, voices };

/// Where sounds come from (composition: compose/sounds.zig). Null functions: nothing there.
pub const Source = struct {
    ctx: ?*anyopaque = null,
    /// Size in bytes of file `name` (case-insensitive); null: no such file.
    size: ?*const fn (ctx: ?*anyopaque, which: Which, name: []const u8) ?u32 = null,
    /// File `name` decoded, its samples in `gpa`.
    load: ?*const fn (ctx: ?*anyopaque, gpa: Allocator, which: Which, name: []const u8) anyerror!Sound = null,
    /// Release what composition holds (the bank's deinit).
    close: ?*const fn (ctx: ?*anyopaque) void = null,

    fn sizeOf(self: Source, which: Which, name: []const u8) ?u32 {
        return (self.size orelse return null)(self.ctx, which, name);
    }
};

/// Longest file name asked (an archive entry name).
const name_max = 112;

/// Sounds by name from `common/sound.dat` (effects) and `common/voice.dat` (music,
/// speech), decoded at first use and kept.
pub const Bank = struct {
    gpa: Allocator,
    source: Source,
    /// Name (lowercase) → sound; null if missing or undecodable.
    cache: std.StringHashMapUnmanaged(?*Sound) = .empty,

    pub fn init(gpa: Allocator, source: Source) Bank {
        return .{ .gpa = gpa, .source = source };
    }

    pub fn deinit(self: *Bank) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) |s| {
                s.deinit(self.gpa);
                self.gpa.destroy(s);
            }
            self.gpa.free(e.key_ptr.*);
        }
        self.cache.deinit(self.gpa);
        if (self.source.close) |f| f(self.source.ctx);
    }

    /// Effect: `name` or `name.wav` (as the engine looks it up, 0x432627).
    pub fn effect(self: *Bank, name: []const u8) ?*const Sound {
        return self.get(.sounds, name, ".wav");
    }

    pub fn music(self: *Bank, name: []const u8) ?*const Sound {
        return self.get(.voices, name, ".mp3");
    }

    /// Speech: a `voice.dat` file by full name (`port_arriving_ov_00.wav`).
    pub fn voice(self: *Bank, name: []const u8) ?*const Sound {
        return self.get(.voices, name, "");
    }

    /// Voice file size in `voice.dat` (bytes; 0 if missing).
    pub fn voiceBytes(self: *Bank, name: []const u8) u32 {
        return self.source.sizeOf(.voices, name) orelse 0;
    }

    pub fn hasMusic(self: *Bank, name: []const u8) bool {
        var buf: [name_max]u8 = undefined;
        const file = std.fmt.bufPrint(&buf, "{s}.mp3", .{name}) catch return false;
        return self.source.sizeOf(.voices, file) != null;
    }

    fn get(self: *Bank, which: Which, name: []const u8, ext: []const u8) ?*const Sound {
        var key_buf: [name_max]u8 = undefined;
        if (name.len + ext.len > key_buf.len) return null;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.cache.get(key)) |s| return s;

        var file_buf: [name_max]u8 = undefined;
        const file = if (self.source.sizeOf(which, name) != null) name else if (std.fmt.bufPrint(&file_buf, "{s}{s}", .{ name, ext })) |f| (if (self.source.sizeOf(which, f) != null) f else null) else |_| return null;
        const snd: ?*Sound = if (file) |f| self.load(which, f) catch |err| blk: {
            std.log.warn("sound {s}: {t}", .{ name, err });
            break :blk null;
        } else blk: {
            std.log.warn("sound {s}: not found", .{name});
            break :blk null;
        };
        const owned = self.gpa.dupe(u8, key) catch return snd;
        self.cache.put(self.gpa, owned, snd) catch self.gpa.free(owned);
        return snd;
    }

    fn load(self: *Bank, which: Which, name: []const u8) !*Sound {
        const f = self.source.load orelse return error.NotFound;
        const s = try self.gpa.create(Sound);
        errdefer self.gpa.destroy(s);
        s.* = try f(self.source.ctx, self.gpa, which, name);
        return s;
    }
};

test positional {
    const p: Params = .{};
    // Within volume_start: full volume; inside the pan dead zone: center.
    try std.testing.expectEqual(Positional{ .volume = 1, .pan = 0 }, positional(.{ 100, 100 }, .{ 0, 0 }, p));
    // 570 px right: d = 250 → 1 - 250*0.004 = 0; pan (570-320)*0.0008 = 0.2.
    const r = positional(.{ 570, 0 }, .{ 0, 0 }, p);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.volume, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), r.pan, 1e-5);
    // Far left: pan clamps at -0.8.
    try std.testing.expectEqual(@as(f32, -0.8), positional(.{ -5000, 0 }, .{ 0, 0 }, p).pan);
}

test musicCandidates {
    var buf: [2][]const u8 = undefined;
    const a = musicCandidates("01_port_silos", &buf);
    try std.testing.expectEqual(2, a.len);
    try std.testing.expectEqualStrings("01_port", a[1]);
    try std.testing.expectEqual(1, musicCandidates("04_city", &buf).len);
}
