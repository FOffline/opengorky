//! The project: a game folder opened for editing (loaders.openGame, its levels and
//! battle templates) and its format (formats/manifest.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const level = @import("level.zig");

/// A game folder open for editing, or none (no levels; the built-in rules).
const Opened = struct {
    game: ?og.loaders.Game,
    /// Owned by the caller from here (App.deinit frees them).
    levels: []level.LevelEntry,
    templates: []level.Template,

    /// Its `dat` (none: the working folder, which nothing reads).
    pub fn dat(self: *const Opened) Io.Dir {
        return if (self.game) |g| g.dat else Io.Dir.cwd();
    }
};

/// Game folder `path` (null: none) read as the game reads it (manifest, adjust.kdt,
/// rules, dat), then its levels and battle templates listed.
pub fn open(io: Io, gpa: Allocator, path: ?[]const u8) !Opened {
    var game: ?og.loaders.Game = if (path) |p| try og.loaders.openGame(io, p) else null;
    errdefer if (game) |*g| g.close(io);
    if (game == null) og.rules.reset();
    const listed = if (game) |g| try level.listLevels(io, gpa, g.dat) else try gpa.alloc(level.LevelEntry, 0);
    // An OpenGorky project: the levels made in its src/ too.
    const levels = if (game) |g| (if (g.manifest.format == .ogs) try level.withOwnLevels(io, gpa, g.root, listed) else listed) else listed;
    errdefer {
        for (levels) |e| gpa.free(e.name);
        gpa.free(levels);
    }
    const templates = if (game) |g| try level.listTemplates(io, gpa, g.dat, levels) else try gpa.alloc(level.Template, 0);
    return .{ .game = game, .levels = levels, .templates = templates };
}
