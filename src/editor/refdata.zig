//! The Reference's articles (reference.zig shows them): the script functions the engine
//! runs (api.zig) by what they act on, the callbacks it calls (callbacks.zig), the
//! OpenGorky hooks (trait Game, script/traits.zig), the rules calls (rulesapi.zig), the engine settings
//! (adjustdoc.zig), the data block kinds and their fields (foundation/hosts.ogs) — read
//! from the tables the code editor's hints use.

const std = @import("std");
const og = @import("opengorky");
const tx = @import("text.zig");
const search = @import("search.zig");
pub const api = @import("api.zig");
pub const callbacks = @import("callbacks.zig");
pub const rulesapi = @import("rulesapi.zig");
const adjustdoc = @import("adjustdoc.zig");

pub const hooks = og.script.traits.hooks;

pub const Kind = enum { builtin, callback, hook, rules, block, setting };
pub const Article = struct { kind: Kind, i: usize };

pub const cbs = callbacks.exe ++ callbacks.actions;

pub const sections = [_]struct { Kind, tx.Msg }{
    .{ .builtin, tx.ref_s_builtins },
    .{ .callback, tx.ref_s_callbacks },
    .{ .hook, tx.ref_s_hooks },
    .{ .rules, tx.ref_s_rules },
    .{ .block, tx.ref_s_blocks },
    .{ .setting, tx.ref_s_settings },
};

/// Script functions by OG Script's package (`fighter`, og.script.ogs.link.packages); the
/// last group: the root's core and the Classic-only ones.
const Group = struct { package: []const u8, title: tx.Msg };
pub const groups = [_]Group{
    .{ .package = "object", .title = tx.ref_g_object },
    .{ .package = "sound", .title = tx.ref_g_sound },
    .{ .package = "actor", .title = tx.ref_g_actor },
    .{ .package = "path", .title = tx.ref_g_path },
    .{ .package = "level", .title = tx.ref_g_level },
    .{ .package = "hero", .title = tx.ref_g_hero },
    .{ .package = "scene", .title = tx.ref_g_scene },
    .{ .package = "gui", .title = tx.ref_g_gui },
    .{ .package = "item", .title = tx.ref_g_item },
    .{ .package = "battle", .title = tx.ref_g_battle },
    .{ .package = "fighter", .title = tx.ref_g_fighter },
    .{ .package = "events", .title = tx.ref_g_events },
    .{ .package = "", .title = tx.ref_g_core },
};

/// The group of script function `name` (its Classic or OG Script name).
pub fn groupOf(name: []const u8) ?usize {
    const f = api.find(name) orelse return null;
    for (groups, 0..) |g, k| if (std.mem.eql(u8, g.package, api.package(f))) return k;
    return null;
}

/// Articles a link joins both ways (besides siblings by name).
pub const pairs = [_][2][]const u8{
    .{ "OnItemUse", "UseItem" },
    .{ "LevelSwitch", "LEVEL_Load" },
    .{ "AfterBattle", "LEVEL_LoadAB" },
    .{ "CombatEnemiesAppear", "AIEnemyAppear" },
    .{ "OnTurnStart", "AIGetTurnNo" },
    .{ "OnDamage", "FighterGetHp" },
    .{ "post_init_box", "Item_New" },
    .{ "class_init", "Item_New" },
    .{ "Setting", "adjust" },
};

pub fn count(k: Kind) usize {
    return switch (k) {
        .builtin => api.all.len,
        .callback => cbs.len,
        .hook => hooks().len,
        .rules => rulesapi.all.len,
        .block => blocks().len,
        .setting => adjustdoc.list.len,
    };
}

pub fn nameOf(r: Article) []const u8 {
    return switch (r.kind) {
        .builtin => api.all[r.i].name,
        .callback => cbs[r.i].name,
        .hook => hooks()[r.i].name,
        .rules => rulesapi.all[r.i].name,
        .block => blocks()[r.i],
        .setting => adjustdoc.list[r.i].name,
    };
}

/// What it is.
pub fn desc(r: Article) @import("text.zig").Msg {
    var buf: [8]callbacks.Param = undefined;
    return switch (r.kind) {
        .builtin => api.all[r.i].doc,
        .callback => cbs[r.i].doc,
        .hook => (callbacks.hook(&buf, hooks()[r.i].name) orelse return .{ .en = "", .ru = "" }).doc,
        .rules => rulesapi.all[r.i].doc,
        .block => tx.ref_block_desc,
        .setting => adjustdoc.list[r.i].doc,
    };
}

/// Only an OpenGorky project has it (the original exe neither runs nor reads it).
pub fn ogOnly(r: Article) bool {
    return switch (r.kind) {
        .builtin => api.portOnly(&api.all[r.i]),
        .hook, .rules, .block => true,
        .callback, .setting => false,
    };
}

/// Article `n` (case aside): a script function first, then a callback, a hook, a rules
/// call, a setting.
pub fn find(n: []const u8) ?Article {
    if (api.find(n)) |f| return .{ .kind = .builtin, .i = f - &api.all[0] };
    for (sections) |s| for (0..count(s[0])) |i| {
        const r: Article = .{ .kind = s[0], .i = i };
        if (std.ascii.eqlIgnoreCase(nameOf(r), n)) return r;
    };
    return null;
}

/// The data block kinds a project writes (`fighter`, `hero`, `weapon`…: core/schema.zig's
/// with a host, whose fields foundation/hosts.ogs declares), in the schema's order.
pub fn blocks() []const []const u8 {
    const S = struct {
        var buf: [og.core.schema.block_kinds.len][]const u8 = undefined;
        var n: ?usize = null;
    };
    if (S.n == null) {
        var n: usize = 0;
        for (og.core.schema.block_kinds) |k| if (og.core.schema.blockHost(k)) |h| if (og.script.hosts.host(h.name) != null) {
            S.buf[n] = k;
            n += 1;
        };
        S.n = n;
    }
    return S.buf[0..S.n.?];
}

/// `q` in its name or either description, any case (Cyrillic too).
pub fn matches(r: Article, q: []const u8) bool {
    const d = desc(r);
    const ogs = if (r.kind == .builtin) api.ogsName(&api.all[r.i]) else "";
    return search.matches(q, &.{ nameOf(r), ogs, d.en, d.ru });
}

/// A name's family: up to its first `_` (`Actor_`, `LEVEL_`, `cft`…), else its first
/// capitalised word (`Actor` of ActorDelay, `Play` of PlaySound).
pub fn stem(n: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, n, '_')) |k| return n[0 .. k + 1];
    var k: usize = 1;
    while (k < n.len and !std.ascii.isUpper(n[k])) k += 1;
    return if (k < n.len) n[0..k] else "";
}

test "reference: every script function in a group, lookups across the sources" {
    for (&api.all) |*f| {
        if (groupOf(f.name) == null) std.debug.print("reference.zig: {s} has no group\n", .{f.name});
        try std.testing.expect(groupOf(f.name) != null);
    }
    try std.testing.expectEqual(2, groupOf("Actor_SetAnimation").?);
    try std.testing.expectEqual(10, groupOf("AIGuardPoint").?);
    try std.testing.expectEqual(10, groupOf("fighter::GuardTile").?);
    try std.testing.expectEqual(groups.len - 1, groupOf("GetName").?);
    try std.testing.expectEqual(Kind.builtin, find("fighter::SetHp").?.kind);
    // One group a package.
    for (og.script.ogs.link.packages, 0..) |p, k| try std.testing.expectEqualStrings(p, groups[k].package);
    try std.testing.expectEqual(Kind.callback, find("useitem").?.kind);
    try std.testing.expectEqual(Kind.hook, find("OnDamage").?.kind);
    try std.testing.expectEqual(Kind.rules, find("AiProfile").?.kind);
    try std.testing.expectEqual(Kind.setting, find("gravity").?.kind);
    try std.testing.expectEqual(Kind.block, find("weapon").?.kind);
    try std.testing.expectEqual(Kind.block, find("hero").?.kind);
    try std.testing.expectEqualStrings("Actor_", stem("Actor_SetAnimation"));
    try std.testing.expectEqualStrings("Play", stem("PlaySound"));
    try std.testing.expectEqualStrings("", stem("print"));
}
