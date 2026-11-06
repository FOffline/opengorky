//! OpenGorky's test room: a hidden battle (`og__testroom`, made again on each use) where a character fights. Its grid, lights and picture are 04__city_passing's
//! (the smallest battle: one enemy on an 8×14 grid, the heroes placed), its script a clean
//! battle's; the character is the enemy (its roles row: as_enemy, or no row), an extra on
//! the heroes' side too (as_hero; the puppet is then the enemy when it is not one). Not
//! in the level lists (level_templates.listLevels). Only in the OG layout (App.ogLayout);
//! an OpenGorky project of OG Script plays the build's room instead (`play`).
//! The heroes go in with the test kit's things, the enemy with its weapon (testkit.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const tx = @import("text.zig");
const levelops = @import("levelops.zig");
const newlevel = @import("newlevel.zig");
const entries = @import("entries.zig");
const ea = @import("entry_attacks.zig");
const App = @import("app.zig").App;

pub const name = @import("level_templates.zig").test_room;
const template = "04__city_passing";
const template_enemy = "puppet";
const enemy = "og_test_enemy";
const testkit = @import("testkit.zig");
const extra = testkit.extra;

/// The test room for character entry `idx` (an enemy class), written over the last one;
/// `attack_class` (a weapon class): the one it holds there (an attack's page), else the test
/// kit's, else its own.
pub fn make(app: *App, idx: usize, attack_class: ?[]const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    // shortcut: an OpenGorky project's room is the build's (`play`); the kit and this
    // room's archives (the installed game's `dat`) are not written for it.
    if (app.store.root != null) return error.BuiltRoomOnly;
    const e = app.catalog.entries.items[idx];
    if (e.kind != .enemy) return error.NotACharacter;
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Read before the room's folder goes (the kit file is in it).
    const kit = testkit.load(app, a);
    const weapon_class = attack_class orelse kit.enemy;
    const who = entries.enemyWho(app, e, app.store.text(entries.fileOf(app, e) orelse return error.NotFound));
    const roles = og.rules.character(who);
    const as_enemy = if (roles) |r| r.as_enemy else true;
    const as_hero = if (roles) |r| r.as_hero else false;
    const class = og.rules.stem(e.entry);

    const sprites = try levelops.copySprites(app, a, template, name);
    var other: std.ArrayList(og.formats.archive.File) = .empty;
    const tpl = template ++ "/other.dat";
    inline for (.{ "cm", "lts", "ar" }) |ext| {
        if (app.store.file(tpl, template ++ "." ++ ext)) |f| try other.append(a, .{ .name = name ++ "." ++ ext, .data = app.store.text(f) }) else |_| {}
    }
    var places: std.ArrayList(u8) = .empty;
    if (as_enemy) {
        try other.append(a, .{ .name = enemy ++ ".ftr", .data = try fighter(a, class, "") });
        // Its weapons: those its fighters hold in the battles (the given ones come by the
        // rules at battle entry), else the one the editor builds it with.
        var k: usize = 0;
        if (weapon_class) |w| {
            try other.append(a, .{ .name = enemy ++ "_0.wpn", .data = try weapon(a, w) });
            k = 1;
        } else for (ea.attacksOf(app, a, e, who)) |at| if (!at.given) {
            try other.append(a, .{ .name = try std.fmt.allocPrint(a, enemy ++ "_{d}.wpn", .{k}), .data = try weapon(a, at.class) });
            k += 1;
        };
        if (k == 0) for (app.templates) |t| if (t.weapon) |w| if (std.ascii.eqlIgnoreCase(t.class, e.base orelse e.id)) {
            try other.append(a, .{ .name = enemy ++ "_0.wpn", .data = try weapon(a, og.rules.stem(w)) });
            break;
        };
        try places.appendSlice(a, "    PlaceActor(\"" ++ enemy ++ "\", 3,6);\r\n");
    } else {
        inline for (.{ ".ftr", "_a.wpn" }) |ext| {
            const n = template_enemy ++ ext;
            try other.append(a, .{ .name = n, .data = app.store.text(try app.store.file(tpl, n)) });
        }
        try places.appendSlice(a, "    PlaceActor(\"" ++ template_enemy ++ "\", 3,6);\r\n");
    }
    if (as_hero) {
        try other.append(a, .{ .name = extra ++ ".hro", .data = try fighter(a, class, "  avoidEnumerate = 1;\r\n") });
        try places.appendSlice(a, "    PlaceActor(\"" ++ extra ++ "\", 4,2);\r\n");
    }
    try places.appendSlice(a, try testkit.calls(a, kit));
    if (testkit.fileIndex(app)) |f| try other.append(a, .{ .name = testkit.entry, .data = app.store.text(f) });
    const lev = app.store.text(try app.store.file(tpl, template ++ ".lev"));
    const clean = try newlevel.battleLevText(a, lev, &.{template_enemy});
    const head = "function restore()\r\n{\r\n";
    const at = (std.mem.indexOf(u8, clean, head) orelse return error.NoTemplate) + head.len;
    try other.append(a, .{ .name = name ++ ".lev", .data = try std.mem.concat(a, u8, &.{ clean[0..at], places.items, clean[at..] }) });

    app.store.dat.deleteTree(app.io, name) catch {};
    try levelops.writeArchives(app, a, name, sprites, other.items);
    app.setStatus(tx.st_test_room, .{ name, e.id });
}

/// The test room for `idx` (holding `weapon_class`) played in the port (its edits saved
/// first, play.playIn).
pub fn play(app: *App, idx: usize, weapon_class: ?[]const u8) void {
    // An OpenGorky project of OG Script: the build's room, a battle block in dist/play.ogp, its
    // fighter of the entry's archetype (shortcut: no weapon of the attack's page).
    if (app.project.format == .ogs) return playOg(app, app.catalog.entries.items[idx].class);
    make(app, idx, weapon_class) catch |err| return app.setStatus(tx.st_test_room_failed, .{err});
    @import("play.zig").playIn(app, name, null);
}

/// An OpenGorky project's test room for fighter archetype `character`: the room's battle
/// the template's when the project has it (the smallest: one enemy), else its first.
pub fn playOg(app: *App, character: []const u8) void {
    @import("play.zig").playRoom(app, .{ .test_room = .{ .character = character, .battle = ogBattle(app) } });
}

pub fn ogBattle(app: *App) []const u8 {
    const path = "battles/" ++ template ++ "/battle.ogs";
    return if (app.store.file(@import("store.zig").og_src, path)) |_| template else |_| "";
}

/// A battle fighter of class script `class` (`.ftr`; with `avoidEnumerate` a `.hro`
/// extra on the heroes' side), as the game's are.
fn fighter(a: Allocator, class: []const u8, more: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "#include Fighter.s\r\n\r\nint initok;\r\n\r\nfunction init()\r\n{{\r\n#include {s}.ss\r\n{s}}};\r\n\r\nfunction post_init()\r\n{{\r\n}};\r\n\r\nfunction update()\r\n{{\r\n}};\r\n", .{ class, more });
}

/// The enemy's weapon of class `class` (`wp_*.ss`; a `cw_` one `.s`), held (place 11).
fn weapon(a: Allocator, class: []const u8) ![]u8 {
    const ext = if (std.ascii.startsWithIgnoreCase(class, "cw_")) ".s" else ".ss";
    return std.fmt.allocPrint(a, "#include Weapon.s\r\n\r\n\r\nint funcID;\r\n\r\nfunction init()\r\n{{\r\n#include {s}{s}\r\n\r\n  Owner=\"" ++ enemy ++ "\";\r\n  place=11;\r\n}};\r\n\r\nfunction update()\r\n{{\r\n}};\r\n", .{ class, ext });
}
