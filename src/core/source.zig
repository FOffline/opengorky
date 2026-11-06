//! Where a world's own data comes from: the location's script files, the party's start
//! files, object variables (`.var`), scripts of other locations, mods, sprite frame
//! counts, the background size, its map and its scenes. The core reads no files:
//! composition (loaders/world.zig) owns the archives and answers; the client hands the
//! game a `Factory` (loaders/world.zig `Opener`) that opens a location's source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const map = @import("map.zig");
const scene = @import("scene.zig");

/// One `name=value` line of an object's `.var` (both as in the file).
pub const Var = struct { key: []const u8, value: []const u8 };

/// Null functions: nothing there.
/// shortcut: scripts, variables and frame counts are asked at first use (the VM loads a
/// class when a script names it; objects are created in order), each kept by the world
/// (VM classes, `Res.frame_counts`); the file lists are read at level entry.
pub const Source = struct {
    ctx: ?*anyopaque = null,
    /// The location's own files (`<level>/other.dat`) in archive order: its objects.
    level_files: []const []const u8 = &.{},
    /// An OpenGorky project's location: its OG Script block as the
    /// world's program keys it (`level 01_port`, `battle 01__port_citadel`); the objects
    /// are its nested blocks, the party the `game` block's (world/start.zig). "": Classic.
    level_block: []const u8 = "",
    /// The party's start files (`common/other.dat: gamestart\*`), without the folder.
    gamestart: []const []const u8 = &.{},
    /// Script `name`: the location's own, else the common classes, scriptlets, gamestart.
    script: ?*const fn (ctx: ?*anyopaque, a: Allocator, name: []const u8) anyerror!?[]const u8 = null,
    /// Script `name` of location `level`'s own files (null: the first location that has it).
    foreign: ?*const fn (ctx: ?*anyopaque, a: Allocator, level: ?[]const u8, name: []const u8) anyerror!?[]const u8 = null,
    /// Object `object`'s `.var` lines (text in `a`); null: none.
    vars: ?*const fn (ctx: ?*anyopaque, a: Allocator, object: []const u8) anyerror!?[]const Var = null,
    /// Frames of sprite `name` (`<name>.spr`); 0: none or not a sprite.
    frame_count: ?*const fn (ctx: ?*anyopaque, name: []const u8) u32 = null,
    /// The location background's pixel size.
    background_size: ?*const fn (ctx: ?*anyopaque) ?[2]u32 = null,
    /// Mod script `name` (not in the exe: mod folders over the archives) in `a`; null: none.
    mod: ?*const fn (ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]const u8 = null,
    /// The mods' own files of the location: objects made after the archive's (one the
    /// archive has already exists, `mod` swaps its source).
    mod_files: []const []const u8 = &.{},
    /// The location's map (its level files), in `a`; read once at level entry.
    map: ?*const fn (ctx: ?*anyopaque, a: Allocator) anyerror!map.Map = null,
    /// `common/voice.dat` has file `name` (a battle's own music).
    has_voice: ?*const fn (ctx: ?*anyopaque, name: []const u8) bool = null,
    /// The location's scenes and dialogs.
    scenes: scene.Source = .{},
    /// What the location is drawn with (the client's: background, depth, lights), in `a`.
    backdrop: ?*const fn (ctx: ?*anyopaque, a: Allocator) anyerror!map.Backdrop = null,
    /// Release what composition holds for the world (its destroy).
    close: ?*const fn (ctx: ?*anyopaque) void = null,

    /// The location has its own file `name` (case-insensitive).
    pub fn levelHas(self: Source, name: []const u8) bool {
        for (self.level_files) |f| if (std.ascii.eqlIgnoreCase(f, name)) return true;
        return false;
    }

    pub fn loadScript(self: Source, a: Allocator, name: []const u8) !?[]const u8 {
        return (self.script orelse return null)(self.ctx, a, name);
    }

    pub fn loadForeign(self: Source, a: Allocator, level: ?[]const u8, name: []const u8) !?[]const u8 {
        return (self.foreign orelse return null)(self.ctx, a, level, name);
    }

    pub fn loadVars(self: Source, a: Allocator, object: []const u8) !?[]const Var {
        return (self.vars orelse return null)(self.ctx, a, object);
    }

    pub fn frameCount(self: Source, name: []const u8) u32 {
        return (self.frame_count orelse return 0)(self.ctx, name);
    }

    pub fn backgroundSize(self: Source) ?[2]u32 {
        return (self.background_size orelse return null)(self.ctx);
    }

    pub fn loadMod(self: Source, a: Allocator, name: []const u8) ?[]const u8 {
        return (self.mod orelse return null)(self.ctx, a, name);
    }

    pub fn loadMap(self: Source, a: Allocator) !map.Map {
        return (self.map orelse return .{})(self.ctx, a);
    }

    pub fn loadBackdrop(self: Source, a: Allocator) !map.Backdrop {
        return (self.backdrop orelse return .{})(self.ctx, a);
    }

    pub fn hasVoice(self: Source, name: []const u8) bool {
        return (self.has_voice orelse return false)(self.ctx, name);
    }

    pub fn deinit(self: Source) void {
        if (self.close) |f| f(self.ctx);
    }
};

/// Opens location `level`'s source (the game's new worlds; composition: loaders/world.zig).
pub const Factory = struct {
    ctx: ?*anyopaque = null,
    open: ?*const fn (ctx: ?*anyopaque, gpa: Allocator, level: []const u8) anyerror!Source = null,

    pub fn openLevel(self: Factory, gpa: Allocator, level: []const u8) !Source {
        return (self.open orelse return error.NoSource)(self.ctx, gpa, level);
    }
};

test "level files are matched without case" {
    const s: Source = .{ .level_files = &.{ "01_Port.lev", "bt.hro" } };
    try std.testing.expect(s.levelHas("01_port.LEV") and !s.levelHas("bt.ftr"));
    try std.testing.expectEqual(0, s.frameCount("x"));
}
