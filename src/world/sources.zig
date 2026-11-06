//! Location script sources: the world's source (level and common files), mods, and
//! classes brought from other locations (`extra_sources`).

const World = @import("../state.zig").world.World;

/// Script source lookup: extra sources, mods, then the world's source (the level's files,
/// then the common `classes\`, `scriptlets\`, `gamestart\`).
pub fn fetchSource(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
    const self: *World = @ptrCast(@alignCast(ctx));
    if (self.res.extra_sources.get(name)) |src| return src;
    if (self.res.source.loadMod(self.arena_state.allocator(), name)) |src| return src;
    return self.res.source.loadScript(self.arena_state.allocator(), name);
}

/// Script source from this location's own files (to carry a class elsewhere).
pub fn localSource(self: *World, name: []const u8) ?[]const u8 {
    // A class the party brought from another location isn't in common either.
    if (self.res.extra_sources.get(name)) |src| return src;
    if (!self.res.source.levelHas(name)) return null;
    return self.res.source.loadScript(self.arena_state.allocator(), name) catch null;
}

/// Class of an item picked up elsewhere (`gloves.itm`, the matrix, notes): source from that
/// location's own files. Exe objects are global; our saves only keep the class name.
pub fn addForeignSource(self: *World, name: []const u8) !bool {
    const src = try self.res.source.loadForeign(self.arena_state.allocator(), null, name) orelse return false;
    try addSource(self, name, src);
    return true;
}

/// Add a script source (name case-insensitive).
pub fn addSource(self: *World, name: []const u8, src: []const u8) !void {
    const a = self.arena_state.allocator();
    try self.res.extra_sources.put(a, try a.dupe(u8, name), try a.dupe(u8, src));
}
