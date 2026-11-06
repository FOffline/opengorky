//! What the centre shows, as a value: a document's kind (`Tab`) and its unique key. No
//! SDL here (its tests run): the tab strip and opening are doctabs.zig.

const std = @import("std");

pub const Tab = enum {
    battles,
    locations,
    /// Enemies and heroes, one list (a character may be both).
    characters,
    items,
    scenes,
    sounds,
    videos,
    music,
    texts,
    fonts,
    effects,
    sprites,
    /// adjust.kdt: the engine's tuning values.
    adjust,
    /// The game (OpenGorky; src/game.ogs): new game, party, videos, music, experience,
    /// formulas, fighter states; the hooks.
    campaign,
    /// The interface (OpenGorky; src/ui.ogs): main menu, windows, panel, its sounds,
    /// effects and sprites.
    ui,
    /// Rules pages (OpenGorky; rulespages.zig): exp levels, special values, AI profiles,
    /// actions; the frame's post-processing (postpage.zig).
    exp_levels,
    values,
    ai_profiles,
    actions,
    post,
    /// The Reference (F1): script functions, callbacks, hooks, rules calls, settings.
    reference,
    /// The test kit (OpenGorky; testkit.zig): what the test room's heroes carry.
    testkit,
    history,
    settings,
    /// Only a document tab's kind (code in the centre over any tab), never `app.tab`.
    code,
    /// A look's assets (look_pages.zig): a model (`gfx_3d\<key>.msh`), the animations a
    /// look script binds (`archive|entry`: an enemy's `act_*.ss`, a hero's file), a
    /// texture (`gfx_3d\textures\<key>`).
    models,
    anims,
    textures,
    /// A trait (traitpage.zig; OpenGorky): the engine's (`Fighter`) or the project's code's
    /// (`abilities::Shielded`), by name.
    traits,
    /// A component: the project's code's (`abilities::EnergyShield`) or a native one
    /// (`Guard`), by name.
    components,
};

/// Tab named `s` (the command line's): `enemies` and `heroes` are `characters`.
pub fn parse(s: []const u8) ?Tab {
    if (std.mem.eql(u8, s, "enemies") or std.mem.eql(u8, s, "heroes")) return .characters;
    return std.meta.stringToEnum(Tab, s);
}

/// An archive path, `|` and an entry name (112 bytes at most) fit.
const max_key = 160;

pub const DocTab = struct {
    tab: Tab,
    /// Kept (edited in, or its tab clicked again); else a preview the next document
    /// opened replaces, as in Zed and VS Code (browsing does not pile up tabs).
    keep: bool = false,
    /// Unique per document: a level's name, `archive|entry` (entries, code, sprites), a
    /// file's name (sounds, scenes…), "" (pages of their own: the history, the settings).
    key_buf: [max_key]u8 = undefined,
    len: usize = 0,

    pub fn key(self: *const DocTab) []const u8 {
        return self.key_buf[0..self.len];
    }

    /// Null when `s` is too long for a tab (a cut key would open another document).
    pub fn of(tab: Tab, s: []const u8) ?DocTab {
        if (s.len > max_key) return null;
        var d: DocTab = .{ .tab = tab };
        d.len = s.len;
        @memcpy(d.key_buf[0..d.len], s);
        return d;
    }

    pub fn is(self: *const DocTab, tab: Tab, k: []const u8) bool {
        return self.tab == tab and std.ascii.eqlIgnoreCase(self.key(), k);
    }

    pub fn same(self: *const DocTab, o: DocTab) bool {
        return self.is(o.tab, o.key());
    }

    /// Its files' mark in the store (Store.doc, SFile.doc).
    pub fn mark(self: *const DocTab) u64 {
        var lower: [max_key]u8 = undefined;
        return std.hash.Wyhash.hash(@backingInt(self.tab), std.ascii.lowerString(&lower, self.key()));
    }
};

/// The `archive|entry` key of a store file (`split` takes it apart).
pub fn join(a: std.mem.Allocator, archive: []const u8, entry: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}|{s}", .{ archive, entry });
}

/// The name after the last `\` of a store entry (`rules\abilities.ss` → `abilities.ss`).
pub fn baseName(entry: []const u8) []const u8 {
    return entry[if (std.mem.lastIndexOfScalar(u8, entry, '\\')) |k| k + 1 else 0..];
}

/// `archive|entry` apart; null for another kind of key.
pub fn split(k: []const u8) ?struct { []const u8, []const u8 } {
    const bar = std.mem.indexOfScalar(u8, k, '|') orelse return null;
    return .{ k[0..bar], k[bar + 1 ..] };
}

test DocTab {
    const a = DocTab.of(.code, "01_port/other.dat|exit_are.are").?;
    try std.testing.expect(a.same(DocTab.of(.code, "01_PORT/other.dat|Exit_are.are").?));
    // Same entry name, another level: another document (and another store mark).
    const b = DocTab.of(.code, "01_port_castle/other.dat|exit_are.are").?;
    try std.testing.expect(!a.same(b));
    try std.testing.expect(a.mark() != b.mark());
    try std.testing.expect(!a.same(DocTab.of(.items, a.key()).?));
    try std.testing.expect(DocTab.of(.history, "").?.is(.history, ""));
    try std.testing.expect(DocTab.of(.sprites, &@as([max_key + 1]u8, @splat('a'))) == null);
    try std.testing.expect(DocTab.of(.sprites, &@as([max_key]u8, @splat('a'))) != null);
}

test parse {
    try std.testing.expectEqual(Tab.characters, parse("enemies").?);
    try std.testing.expectEqual(Tab.characters, parse("heroes").?);
    try std.testing.expectEqual(Tab.items, parse("items").?);
    try std.testing.expect(parse("nope") == null);
}

test split {
    const p = split("01_port/sprite.dat|icons\\x.spr").?;
    try std.testing.expectEqualStrings("01_port/sprite.dat", p[0]);
    try std.testing.expectEqualStrings("icons\\x.spr", p[1]);
    try std.testing.expect(split("garcia") == null);
    try std.testing.expectEqualStrings("x.spr", baseName(p[1]));
    try std.testing.expectEqualStrings("garcia", baseName("garcia"));
}
