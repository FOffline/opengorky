//! Integration tests of `Game`: level switch, cache, battle, save/load, scenes, on the
//! hand-written fixture data (`fixture.zig`).

const std = @import("std");
const fields = @import("../fields.zig");
const game = @import("../game.zig");
const Game = game.Game;
const save_mod = @import("../world.zig").saved;
const save_file = @import("../compose.zig").save;
const scenes = @import("../scene.zig").scenes;
const crt_rand = @import("../crt_rand.zig");
const battle_tick = @import("../combat.zig").tick;
const immunity = @import("../battle.zig").immunity;
const items = @import("../inventory.zig");
const fixture = @import("fixture.zig");
const natives = @import("../core.zig").natives;

const TestGame = struct {
    tmp: std.testing.TmpDir,
    opener: @import("../loaders.zig").world.Opener,
    game: Game,

    /// 01_a ↔ 01_b (plain) and 01__fight (combat, no grid); hero Sullivan.
    fn init(self: *TestGame) !void {
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        const d = self.tmp.dir;
        try fixture.writeCommon(d);
        try fixture.writeLevel(d, "01_a",
            \\int order; int visits; int mark; int classic_id; string lastBattle;
            \\function init() { order = order * 10 + 1; };
            \\function restore() { order = order * 10 + 2; visits = visits + 1; };
            \\function AfterBattle(string s) { lastBattle = s; };
            \\function go() { LEVEL_Load("01_b"); FadeIn(); };
            \\function goTwice() { LEVEL_Load("01_b"); LEVEL_Load("01_a"); FadeIn(); };
        );
        try fixture.writeLevel(d, "01_b", "int visits;\nfunction restore() { visits = visits + 1; };");
        try fixture.writeLevel(d, "01__fight", "#inherit combatlevel\n");
        self.opener = .{ .io = std.testing.io, .dat = d };
        self.game = .{ .io = std.testing.io, .gpa = std.testing.allocator, .worlds = self.opener.factory(), .models = null };
        _ = try self.game.open("01_a", .{ .hero = "Sullivan" }, null);
    }

    fn deinit(self: *TestGame) void {
        self.game.deinit();
        self.tmp.cleanup();
    }

    fn go(self: *TestGame, name: []const u8) !Game.Switch {
        const sw = try self.game.switchTo(name);
        try self.game.finish(sw);
        return sw;
    }

    fn level(self: *TestGame) *@import("../script.zig").object.Object {
        return self.game.world.?.level.?;
    }

    fn hero(self: *TestGame) *@import("../script.zig").object.Object {
        return self.game.world.?.actorObject("Sullivan").?;
    }
};

test "create: level init() before restore()" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expectEqual(12, t.level().getInt("order"));
    try std.testing.expectEqualStrings("Sullivan", t.game.world.?.selected_hero);
}

test "switchTo/finish: there and back through the world cache" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const a = t.game.world.?;
    t.level().setInt("mark", 7);
    var sw = try t.go("01_b");
    try std.testing.expect(!sw.restored and !sw.destroyed);
    try std.testing.expectEqualStrings("01_b", t.game.world.?.level_name);
    try std.testing.expectEqualStrings("01_a", t.game.prev.?);
    try std.testing.expect(t.game.cache.get("01_a") == a);
    sw = try t.go("01_a");
    // Same world object, state kept, restore() called again (0x411cd0).
    try std.testing.expect(sw.restored);
    try std.testing.expect(t.game.world.? == a);
    try std.testing.expectEqual(7, t.level().getInt("mark"));
    try std.testing.expectEqual(2, t.level().getInt("visits"));
    try std.testing.expectEqualStrings("Sullivan", t.game.world.?.selected_hero);
    try std.testing.expect(t.game.cache.get("01_b") != null);
}

test "a joined hero is a hero-class object in a new location: HERO_EnableEnumerate takes him out (0x4c1970)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    // Medusa joins in 01_m (SETHERO); 01_n is entered for the first time, so the party
    // creates her there. Its trigger is the observatory's crazy-Medusa one: she leaves the
    // party (HERO_EnableEnumerate 0) and GUI_IsHero must say so, or the scene and its
    // battle come again after the win.
    try fixture.writeArchive(t.tmp.dir, "01_m/other.dat", &.{
        .{ "01_m.lev", "" },
        .{ "Medusa.hro", "int classic_id; int outside_party;" },
    });
    try fixture.writeArchive(t.tmp.dir, "01_m/sprite.dat", &.{});
    try fixture.writeLevel(t.tmp.dir, "01_n", "int was; int now;\nfunction leave() { was = GUI_IsHero(\"Medusa\"); HERO_EnableEnumerate(\"Medusa\",0); now = GUI_IsHero(\"Medusa\"); };");
    _ = try t.go("01_m");
    const m = t.game.world.?.actorObject("Medusa").?;
    @TypeOf(t.game.world.?.*).nativeOf(m).hero = true;
    _ = try t.go("01_n");
    _ = try t.game.world.?.rt.callIfExists(t.level(), "leave", &.{});
    try std.testing.expectEqual(1, t.level().getInt("was"));
    try std.testing.expectEqual(0, t.level().getInt("now"));
}

test "battle: not cached, AfterBattle on return, retry restores the entry party" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    fields.setHp(t.hero(), 50);
    _ = try t.go("01__fight");
    try std.testing.expect(t.game.world.?.isCombat());
    try std.testing.expect(t.game.entry_party != null);
    // Retry after a loss: the battle again with the party as it entered; immunities found
    // in the lost battle are forgotten (the exe reloads the "battle" save, 0x4542c0).
    fields.setHp(t.hero(), 1);
    _ = t.game.immunity.discover(.{ .id = immunity.table[0].fighter }, .gas);
    _ = try t.game.retry();
    try std.testing.expectEqual(50, fields.hp(t.hero()));
    try std.testing.expect(!t.game.immunity.isKnown(.{ .id = immunity.table[0].fighter }, .gas));
    // Victory: back to where the battle started (no backLevel → prev).
    try std.testing.expect(t.game.leaveBattle());
    const sw = try t.go(t.game.pendingLevel().?);
    try std.testing.expect(sw.destroyed and sw.restored and sw.after_battle);
    try std.testing.expectEqualStrings("01__fight", t.level().getString("lastBattle"));
    try std.testing.expect(t.game.cache.get("01__fight") == null);
}

test "battle save: game over outside battle re-enters the last battle as it was entered" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expect(t.game.battle_save == null);
    t.level().setInt("mark", 7);
    fields.setHp(t.hero(), 50);
    const id = immunity.table[0].fighter;
    _ = t.game.immunity.discover(.{ .id = id }, .fire);
    _ = try t.go("01__fight");
    try std.testing.expect(t.game.battle_save != null);
    _ = t.game.immunity.discover(.{ .id = id }, .gas);
    try std.testing.expect(t.game.leaveBattle());
    _ = try t.go(t.game.pendingLevel().?);
    t.level().setInt("mark", 9);
    fields.setHp(t.hero(), 1);
    // GUI_GAMEOVER "Yes" (0x4542c0): the battle again, the rest as the save had it.
    const w = try t.game.reloadBattle();
    try std.testing.expect(w.isCombat());
    try std.testing.expectEqual(50, fields.hp(t.hero()));
    try std.testing.expect(t.game.prev == null);
    // Immunities as the battle was entered (table 0x6d2070 is in the save, 0x4722a5).
    try std.testing.expect(t.game.immunity.isKnown(.{ .id = id }, .fire) and !t.game.immunity.isKnown(.{ .id = id }, .gas));
    _ = try t.go("01_a");
    try std.testing.expectEqual(7, t.level().getInt("mark"));
}

test "snapshot + load: current and cached locations come back from the save" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    t.level().setInt("mark", 7);
    _ = try t.go("01_b");
    fields.setHp(t.hero(), 33);
    @TypeOf(t.game.world.?.*).nativeOf(t.hero()).actor.forced_idle = "medicine";
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    {
        var sv: save_mod.Save = .init(std.testing.allocator);
        defer sv.deinit();
        try t.game.snapshot(&sv);
        try save_file.write(&sv, &text.writer);
    }
    const w = try t.game.load(try save_file.parse(std.testing.allocator, text.written()));
    try std.testing.expectEqualStrings("01_b", w.level_name);
    try std.testing.expectEqual(33, fields.hp(t.hero()));
    // idleAnimOverride (+0x30ed) is part of the actor's saved properties (0x46a691).
    try std.testing.expectEqualStrings("medicine", @TypeOf(w.*).nativeOf(t.hero()).actor.forced_idle.?);
    try std.testing.expect(t.game.cache.count() == 0 and t.game.prev == null);
    // 01_a was only in the cache: its saved state, not a fresh init().
    _ = try t.go("01_a");
    try std.testing.expectEqual(7, t.level().getInt("mark"));
    // A cut-off save never reaches the game.
    const cut = text.written()[0 .. text.written().len - 4];
    try std.testing.expectError(error.BadSave, save_file.parse(std.testing.allocator, cut));
}

test "deferred LEVEL_Load steps run on the new location; a LEVEL_Load among them defers the rest" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    // FadeIn after LEVEL_Load in the same call refers to the new location.
    _ = try t.game.world.?.rt.callIfExists(t.level(), "go", &.{});
    try std.testing.expectEqual(0, t.game.world.?.scene.fade);
    _ = try t.go(t.game.pendingLevel().?);
    try std.testing.expectEqualStrings("01_b", t.game.world.?.level_name);
    try std.testing.expectEqual(1, t.game.world.?.scene.fade);
    try std.testing.expect(t.game.world.?.flow.pending_level == null);
    // Back, then two loads in one call: on 01_b the replayed LEVEL_Load("01_a") is
    // pending again and FadeIn waits for 01_a.
    _ = try t.go("01_a");
    _ = try t.game.world.?.rt.callIfExists(t.level(), "goTwice", &.{});
    _ = try t.go(t.game.pendingLevel().?);
    const w = t.game.world.?;
    try std.testing.expectEqualStrings("01_b", w.level_name);
    try std.testing.expectEqualStrings("01_a", w.flow.pending_level.?);
    try std.testing.expectEqual(1, w.flow.load_steps.items.len);
    try std.testing.expectEqual(.fade_in, w.flow.load_steps.items[0].kind);
}

test "a scene with LOADLEVEL continues on the new location" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const a = t.game.world.?;
    try scenes.startScriptlet(a, "move");
    try scenes.tick(a);
    try std.testing.expectEqualStrings("01_b", t.game.pendingLevel().?);
    _ = try t.go(t.game.pendingLevel().?);
    // Left location no longer runs it; the new one resumes after LOADLEVEL.
    try std.testing.expect(a.scene.runner == null);
    const sc = t.game.world.?.scene.runner.?;
    try std.testing.expectEqualStrings("move", sc.name);
    try std.testing.expectEqual(1, sc.pc);
    try scenes.tick(t.game.world.?);
    try std.testing.expectEqual(1, t.game.world.?.scene.fade_target);
}

test "give: nothing to or from Medusa (0x42e485, 0x450872)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const other = t.level(); // stands in for a second hero; only classic_id matters
    try std.testing.expect(items.give.canGive(w, t.level(), t.hero(), other));
    // Her natives (NoHands) come with the object: made as Medusa (classic_id 119).
    fields.setClassicId(other, 119);
    try natives.attach(&w.rt, other);
    try std.testing.expect(!items.give.canGive(w, t.level(), t.hero(), other));
    try std.testing.expect(!items.give.canGive(w, t.level(), other, t.hero()));
}

test "give: the backpack's items go before the worn one" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const worn = (try items.create.giveItem(w, "vest.s", "Sullivan", null)).?;
    const spare = (try items.create.giveItem(w, "vest.s", "Sullivan", null)).?;
    items.item.setPlace(worn, .armor);
    items.give.transfer(w, t.hero(), t.level(), worn, 1);
    try std.testing.expect(fields.ownerIs(spare, t.level().name));
    try std.testing.expect(fields.ownerIs(worn, "Sullivan"));
    try std.testing.expectEqual(items.item.Place.armor, items.item.placeOf(worn));
}

test "Medusa can't be picked by the player outside a battle (0x4b2761, 0x451467)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expect(t.game.world.?.playerCanSelect(t.hero()));
    // Made as Medusa (classic_id 119): her native BattleOnly.
    fields.setClassicId(t.hero(), 119);
    try natives.attach(&t.game.world.?.rt, t.hero());
    try std.testing.expect(!t.game.world.?.playerCanSelect(t.hero()));
    _ = try t.go("01__fight");
    try std.testing.expect(t.game.world.?.playerCanSelect(t.hero()));
}

test "battle music is drawn at level load: rand() % 2 == 0 is battle" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    crt_rand.global.seed(7);
    var copy = crt_rand.global;
    const want: []const u8 = if (copy.below(2) == 0) "battle" else "battle2";
    _ = try t.go("01__fight");
    try std.testing.expectEqualStrings(want, t.game.world.?.battle_music.?);
    try std.testing.expectEqualStrings(want, game.levelMusic(t.game.world.?).combat.?);
    // Plain levels draw nothing.
    try std.testing.expect(t.game.cache.count() == 1 and t.game.cache.get("01_a").?.battle_music == null);
}

test "a mid-line page turn keeps the voice; ending the line cuts it" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    w.scene.subtitle = .{ .speaker = "Sullivan", .text = "Hello" };
    w.scene.line_open = true;
    w.scene.subtitle_pages = 2;
    try std.testing.expect(scenes.skipLine(w));
    try std.testing.expect(!w.out.voice_cut);
    try std.testing.expect(scenes.skipLine(w));
    try std.testing.expect(w.out.voice_cut);
}

test "selectHero: outside_party heroes are skipped; plays the sound" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    w.selected_hero = "";
    t.hero().setInt("outside_party", 1);
    game.selectHero(w, "Sullivan");
    try std.testing.expectEqualStrings("", w.selected_hero);
    t.hero().setInt("outside_party", 0);
    game.selectHero(w, "Sullivan");
    try std.testing.expectEqualStrings("Sullivan", w.selected_hero);
    try std.testing.expectEqualStrings("selecthero", w.out.sound_events.items[w.out.sound_events.items.len - 1].name);
}

test "switchTo: a selected hero not in the new location's party list gives way to its first (0x481ce0)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    // Medusa picked in a battle: on a location she is not a selectable party hero.
    t.game.world.?.selected_hero = "Medusa";
    _ = try t.go("01_b");
    try std.testing.expectEqualStrings("Sullivan", t.game.world.?.selected_hero);
}

test "battle end: the engine queues victory or gameover music 90 ticks later (0x454880, 0x454350)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    var tb: fixture.TestBattle = .init();
    defer tb.deinit();
    const b = &tb.b;
    b.phase = .lost;
    for (0..89) |_| try battle_tick.tick(b, w);
    for (w.out.music_events.items) |m| try std.testing.expect(!std.mem.eql(u8, m.name, "gameover"));
    try battle_tick.tick(b, w);
    try std.testing.expectEqualStrings("gameover", w.out.music_events.items[w.out.music_events.items.len - 1].name);
}

test "world cache keys ignore case (scripts write level names in any case)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const a = t.game.world.?;
    _ = try t.go("01_b");
    const sw = try t.go("01_A");
    try std.testing.expect(sw.restored and t.game.world.? == a);
}

test "a removed actor's current and morph glow end with it, not on return to the level" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const h = t.hero();
    // VOLTAGE("Medusa") … DELETEOBJECT("Medusa") (museum-medusa_crazy.scr); ACTOR_MORPH Bt …
    // DELETEOBJECT("Bt") (lab-lamare_dying.scr).
    @import("../fx.zig").hits.current(w, h);
    var m = @import("../effects.zig").bitmap.Morph.init(.{ 0, 0, 0 }, 0, "bt", "", 1, w.crt());
    m.owner = h;
    try w.effects.morphs.append(w.gpa, m);
    h.enabled = false;
    @TypeOf(w.*).nativeOf(h).deleted = true;
    try game.tick(w);
    _ = try t.go("01_b");
    _ = try t.go("01_a");
    try std.testing.expectEqual(0, w.effects.beams.items.len);
    try std.testing.expectEqual(0, w.effects.morphs.items.len);
}

test "mod scene commands and builtins: IDLE_OFF, ZOOM, GUI_GAMEOVER, Actor_QueueState, AttachActors" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const h = t.hero();
    const a = @import("../state.zig").world.actorOf(h);
    try scenes.startScriptlet(w, "modcmds");
    try scenes.tick(w);
    // IDLE_OFF is queued (command 0x26) and runs with the queue; ZOOM clamps to 200 %.
    try std.testing.expect(a.idle_off);
    try std.testing.expectEqual(@as(f32, 2), w.out.zoom.?.to);
    try std.testing.expectEqual(@as(?f32, 10), w.out.zoom.?.time);
    try std.testing.expectEqual(@as(?u32, 0), w.flow.defeat_ticks);
    // The scene's end turns idles back on (0x479093).
    for (0..8) |_| try game.tick(w);
    try std.testing.expect(w.scene.runner == null and !a.idle_off);
    for (0..90) |_| try game.tick(w);
    var music = false;
    for (w.out.music_events.items) |m| music = music or std.mem.eql(u8, m.name, "gameover");
    try std.testing.expect(music);
    // Actor_QueueState(…, 4) (command 0x22): links off, then the state.
    const bi = @import("../builtins.zig").actors;
    try a.links.append(w.gpa, .{ .link = "back", .mesh = "m" });
    _ = try bi.biActorQueueState(w, &w.rt, h, &.{ .{ .string = "Sullivan" }, .{ .int = 4 } });
    try @import("../world.zig").queue.runQueue(w, h, a);
    try std.testing.expectEqual(4, a.state);
    try std.testing.expect(a.links.items.len == 0 and a.weapon_detached);
    // AttachActors: offset (a, b, c) in world units → mesh x = b, y = c, z = a over the scale.
    _ = try bi.biAttachActors(w, &w.rt, h, &.{ .{ .string = "Sullivan" }, .{ .string = "Sullivan" }, .{ .float = 1 }, .{ .float = 2 }, .{ .float = 3 }, .{ .float = 0.5 } });
    const s = w.actorScale() * 24;
    try std.testing.expectApproxEqAbs(2 / s, a.link_offset[0], 1e-6);
    try std.testing.expectApproxEqAbs(3 / s, a.link_offset[1], 1e-6);
    try std.testing.expectApproxEqAbs(1 / s, a.link_offset[2], 1e-6);
    try std.testing.expectEqual(@as(f32, 0.5), a.link_angle);
    a.attached_to = null;
}

test "hooks: an OpenGorky project's game components (game.ogs) after the level's; nil skipped, OnItemUse true stops; Classic calls none" {
    const rules = @import("../rules.zig");
    const hooks = @import("../state.zig").hooks;
    const og = @import("../loaders.zig").ogs;
    const io = std.testing.io;
    defer {
        og.close();
        rules.reset();
    }
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/dat");
    for ([_][2][]const u8{
        .{ "opengorky.mod", "format = ogs\nid = t\ngame = game\n" },
        .{ "src/rules/campaign.ogs", "Campaign(level = \"01_port\", leader = \"Sullivan\", party = \"\", panel_first = \"Sullivan\", area = \"\", point = 0, scene = \"\", intro = \"\", startup = \"\", menu_logo = \"\", menu_music = \"\", credits_music = \"\", credits = \"\", credits_video = \"\");" },
        .{ "src/ui.ogs", @embedFile("og/port/src/ui.ogs") },
        .{ "src/shell.ogs", "ExeAnims(fight_look = \"fightlook\");\nHoldPoints(one_hand = \"one_hand\");\n" },
        .{ "src/locations/a/level.ogs", "level a { }" },
        .{
            "src/game.ogs",
            \\component Hooks for game {
            \\    var int turns; var int used; var int wins; var string order = "";
            \\    fn OnTurnStart(side, turn) { turns = turn; }
            \\    fn OnTurnEnd(side, turn) { order = order + "g"; }
            \\    fn OnDamage(a, t, w, amount) { if (a == @a and t == w) return amount + 1; }
            \\    fn OnItemUse(u, i, t) { if (t == nil) used = 1; return used == 1; }
            \\    fn OnBattleEnd(won) { if (won == true) wins += 1; }
            \\    fn OnLevelEnter(level) { if (level == @a) order = order + "L"; }
            \\}
            \\component More for game { fn OnDamage(a, t, w, amount) { return amount * 10; } }
            \\component Quiet for game { fn OnDamage(a, t, w, amount) { } fn OnResist(t, k, amount) { return; } }
        },
        .{
            "src/components/Fight.ogs",
            \\component Fight for battle {
            \\    var string order = ""; var int appear; var int turn_end; var string vars = ""; var int last;
            \\    fn OnTurnEnd(side, turn) { order = order + side; turn_end = turn; }
            \\    fn OnDamage(a, t, w, amount) { return amount + 3; }
            \\    fn OnResist(t, kind, amount) { }
            \\    fn OnBattleEnd(won) { order = order + "e"; }
            \\    fn OnEnemiesAppear() { appear += 1; }
            \\    fn OnVar(name, value) { vars = vars + name; last = value; }
            \\}
            \\component NotTheGame for fighter { fn OnDamage(a, t, w, amount) { return 0; } }
        },
    }) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    {
        var dat = try og.open(io, tmp.dir);
        defer dat.close(io);
        var g: Game = .{ .io = io, .gpa = std.testing.allocator, .worlds = og.factory(), .models = null };
        defer g.deinit();
        const w = try g.open("a", .{}, null);
        const l = w.level.?;
        try hooks.turnStart(w, "hero", 3);
        const game_hooks = w.hooks.?.components.items;
        try std.testing.expectEqual(3, game_hooks.len);
        try std.testing.expectEqual(3, game_hooks[0].getInt("turns"));
        // Hooks +1, then More ×10; Quiet's nil changes nothing.
        try std.testing.expectEqual(60, try hooks.damage(w, l, l, l, 5));
        try std.testing.expectEqual(0, try hooks.resist(w, l, "gas", 7));
        try std.testing.expect(try hooks.itemUse(w, l, l, null));
        try std.testing.expectEqual(1, game_hooks[0].getInt("used"));
        // The level's components before the game's: +3, +1 (the refs: attacker, target,
        // weapon), ×10. Fight's nil OnResist leaves it to the game's (none: 0).
        const fight = try w.rt.attach(l, (try w.rt.ogs.component(w.rt.arena(), null, "Fight")).?, &.{});
        try std.testing.expectEqual(90, try hooks.damage(w, l, l, l, 5));
        try std.testing.expectEqual(0, try hooks.resist(w, l, "gas", 7));
        try hooks.turnEnd(w, "hero", 4);
        try hooks.battleEnd(w, true);
        try hooks.battleEnd(w, false);
        try std.testing.expectEqualStrings("heroee", fight.getVar("order").?.value.string);
        try std.testing.expectEqual(4, fight.getInt("turn_end"));
        // OnLevelEnter(level) ran once at the opening.
        try std.testing.expectEqualStrings("Lg", game_hooks[0].getVar("order").?.value.string);
        try std.testing.expectEqual(1, game_hooks[0].getInt("wins"));
        try hooks.levelEnter(w);
        try std.testing.expectEqualStrings("LgL", game_hooks[0].getVar("order").?.value.string);
        // The battle's own events: OnEnemiesAppear, OnVar after the fighters'.
        const battle_mod = @import("../battle.zig").battle;
        var b: battle_mod.Battle = .{ .gpa = std.testing.allocator, .blocked = &.{}, .occupant = &.{}, .reach_left = &.{}, .fire = &.{}, .gas = &.{}, .width = 0, .height = 0 };
        defer b.deinit();
        // The enemies' round ends (none here): OnTurnEnd("enemy") of the battle and the
        // game, then OnEnemiesAppear.
        b.turn = 7;
        try @import("../combat.zig").ai_turn.enemiesActed(&b, w);
        try std.testing.expectEqualStrings("heroeeenemy", fight.getVar("order").?.value.string);
        try std.testing.expectEqual(7, fight.getInt("turn_end"));
        try std.testing.expectEqualStrings("LgLg", game_hooks[0].getVar("order").?.value.string);
        try @import("../combat.zig").events.setVar(&b, w, "x", .{ .int = 2 });
        try std.testing.expectEqual(1, fight.getInt("appear"));
        try std.testing.expectEqualStrings("x", fight.getVar("vars").?.value.string);
        try std.testing.expectEqual(2, fight.getInt("last"));
    }
    // Classic: no game object, every hook the built-in value (a level's function of a
    // hook's name is no hook).
    og.close();
    rules.reset();
    var fx = std.testing.tmpDir(.{ .iterate = true });
    defer fx.cleanup();
    try fixture.writeCommon(fx.dir);
    try fixture.writeLevel(fx.dir, "01_a", "int turns;\nfunction OnTurnStart(string side, int turn) { turns = turn; };\nfunction OnDamage(string a, string t, string w, int amount) { return amount * 2; };");
    var opener: @import("../loaders.zig").world.Opener = .{ .io = io, .dat = fx.dir };
    var g: Game = .{ .io = io, .gpa = std.testing.allocator, .worlds = opener.factory(), .models = null };
    defer g.deinit();
    _ = try g.open("01_a", .{ .hero = "Sullivan" }, null);
    const w = g.world.?;
    const l = w.level.?;
    try hooks.turnStart(w, "hero", 3);
    try std.testing.expect(w.hooks == null);
    try std.testing.expectEqual(0, l.getInt("turns"));
    try std.testing.expectEqual(5, try hooks.damage(w, l, l, l, 5));
    try std.testing.expect(!try hooks.itemUse(w, l, l, null));
}

test "OpenGorky: the world's events reach the components attached to its objects (level, actor, area, item, anim); nil changes nothing" {
    const rules = @import("../rules.zig");
    const world = @import("../world.zig");
    const hooks = @import("../state.zig").hooks;
    const Object = @import("../script.zig").object.Object;
    defer rules.reset();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture.writeCommon(tmp.dir);
    try fixture.writeArchive(tmp.dir, "01_a/other.dat", &.{
        .{ "01_a.lev", "int x;" },
        .{ "door.are", "int action; int opened;\nfunction init() { action = 1; };\nfunction Open(string h) { opened = opened + 1; };" },
        .{ "box.itm", "int action; string itm_1;\nfunction init() { action = 7; itm_1 = \"nowhere\"; };" },
        .{ "lamp.ba", "int speed;" },
    });
    try fixture.writeArchive(tmp.dir, "01_a/sprite.dat", &.{});
    try fixture.writeLevel(tmp.dir, "01__fight", "#inherit combatlevel\n");
    const hooks_text =
        \\component Lv for level {
        \\    var string seen = "";
        \\    fn OnCamera() { seen = seen + "K"; }
        \\    fn OnCreate() { seen = seen + "C"; }
        \\    fn OnRestore() { seen = seen + "R"; }
        \\    fn OnStart() { seen = seen + "S"; }
        \\    fn OnShown() { seen = seen + "W"; }
        \\    fn OnEnter() { seen = seen + "E"; }
        \\    fn OnUpdate() { seen = seen + "U"; }
        \\    fn OnAfterBattle(battle) { seen = seen + "/" + battle; }
        \\}
        \\component Act for actor {
        \\    var string seen = "";
        \\    fn OnCreate() { seen = seen + "C"; }
        \\    fn OnActorReady() { seen = seen + "A"; }
        \\}
        \\component Door for area {
        \\    var string seen = ""; var int code;
        \\    fn OnAction(name, hero) { if (hero == @Sullivan) seen = seen + name; }
        \\    fn OnExit() { seen = seen + "X"; }
        \\    fn OnCode(c) { code = c; }
        \\    fn OnUseItem(item, user) { if (item == @box and user == @Sullivan) seen = seen + "U"; }
        \\}
        \\component Lock for area { fn OnAction(name, hero) { return true; } }
        \\component Box for item {
        \\    var string seen = "";
        \\    fn OnAction(name, hero) { seen = seen + name; }
        \\    fn OnFirstOpen(hero) { if (hero == @Sullivan) seen = seen + "F"; }
        \\}
        \\component Shown for anim { var int n; fn OnRestore() { n += 1; } fn CanRender() { } }
        \\component Hidden for anim { fn CanRender() { return false; } }
    ;
    rules.scripts = &.{.{ .name = "hooks.ogs", .data = hooks_text }};
    rules.og = true;
    var opener: @import("../loaders.zig").world.Opener = .{ .io = std.testing.io, .dat = tmp.dir };
    var g: Game = .{ .io = std.testing.io, .gpa = std.testing.allocator, .worlds = opener.factory(), .models = null };
    defer g.deinit();
    _ = try g.open("01_a", .{ .hero = "Sullivan" }, null);
    const w = g.world.?;
    const T = struct {
        fn attach(wo: anytype, o: *Object, name: []const u8) !*Object {
            return wo.rt.attach(o, (try wo.rt.ogs.component(wo.rt.arena(), null, name)).?, &.{});
        }
        fn seen(c: *Object) []const u8 {
            return c.getVar("seen").?.value.string;
        }
    };
    // No game component: no game object (the prelude and the abilities' texts alone).
    try std.testing.expect(w.hooks == null);
    const hero = w.rt.findObject("Sullivan").?;
    const door = w.rt.findObject("door").?;
    const box = w.rt.findObject("box").?;
    const lamp = w.rt.findObject("lamp").?;
    const lv = try T.attach(w, w.level.?, "Lv");
    const act = try T.attach(w, hero, "Act");
    const dc = try T.attach(w, door, "Door");
    const bc = try T.attach(w, box, "Box");
    const shown = try T.attach(w, lamp, "Shown");
    // The location made again with the components there: OnCamera before the level's
    // OnCreate, OnRestore, OnStart, OnShown at the load's end, OnEnter, a tick's OnUpdate.
    try world.start.startInit(w);
    try world.start.startRestore(w);
    try world.levels.afterSelectGui(w);
    try hooks.levelEnter(w);
    try game.life.tickObjects(w);
    try std.testing.expectEqualStrings("KCRSWEU", T.seen(lv));
    try std.testing.expectEqualStrings("CA", T.seen(act));
    try std.testing.expectEqual(1, shown.getInt("n"));
    // CanRender: nil draws it, a false hides it.
    try std.testing.expect(@TypeOf(w.*).nativeOf(lamp).visible);
    _ = try T.attach(w, lamp, "Hidden");
    try world.start.updateVisibility(w, lamp);
    try std.testing.expect(!@TypeOf(w.*).nativeOf(lamp).visible);
    // The area: OnAction's nil lets Open run, Lock's true skips it; OnExit, OnUseItem, OnCode.
    w.act.interaction = .{ .hero = hero, .area = door };
    try world.actions.runInteraction(w);
    try std.testing.expectEqual(1, door.getInt("opened"));
    _ = try T.attach(w, door, "Lock");
    w.act.interaction = .{ .hero = hero, .area = door };
    try world.actions.runInteraction(w);
    try std.testing.expectEqual(1, door.getInt("opened"));
    w.act.interaction = .{ .hero = hero, .area = door, .mode = .level_switch };
    try world.actions.runInteraction(w);
    w.act.interaction = .{ .hero = hero, .area = door, .use = box };
    try world.actions.runInteraction(w);
    w.act.safe_box = door;
    try world.actions.enterSafeCode(w, 1234);
    try std.testing.expectEqualStrings("OpenOpenXU", T.seen(dc));
    try std.testing.expectEqual(1234, dc.getInt("code"));
    // The box: OnAction (nil: explored), OnFirstOpen while its contents are not there.
    try items.box.itemOperation(w, box, hero);
    try std.testing.expectEqualStrings("ExploreF", T.seen(bc));
    // Back from a won battle: OnRestore, OnShown, OnEnter again, then OnAfterBattle(name).
    try g.finish(try g.switchTo("01__fight"));
    try std.testing.expect(g.leaveBattle());
    try g.finish(try g.switchTo(g.pendingLevel().?));
    try std.testing.expect(g.world.? == w);
    try std.testing.expectEqualStrings("KCRSWEURWE/01__fight", T.seen(lv));
}

test "OpenGorky: the items' and areas' points — Accepts, CanTake, OnTaken, CanCarry, OnPickUp, CanGive, OnUse, OnEnter, OnLeave" {
    const rules = @import("../rules.zig");
    const world = @import("../world.zig");
    const hooks = @import("../state.zig").hooks;
    const Object = @import("../script.zig").object.Object;
    defer rules.reset();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture.writeCommon(tmp.dir);
    try fixture.writeArchive(tmp.dir, "01_a/other.dat", &.{
        .{ "01_a.lev", "int x;" },
        .{ "door.are", "string use_item_1; string use_item_2; string areaName;\nfunction init() { use_item_1 = \"key\"; use_item_2 = \"coin\"; areaName = \"doorA\"; };\nfunction UseItem(string i, string h) { };" },
        .{ "key.itm", "string Owner; int place;\nfunction init() { Owner = \"Sullivan\"; place = 1; };" },
        .{ "coin.itm", "string Owner; int place;\nfunction init() { Owner = \"Sullivan\"; place = 1; };" },
        .{ "gem.itm", "int action; int taken;\nfunction init() { action = 3; };\nfunction Take(string h) { taken = taken + 1; };" },
    });
    try fixture.writeArchive(tmp.dir, "01_a/sprite.dat", &.{});
    const hooks_text =
        \\component Door for area {
        \\    var string seen = "";
        \\    fn Accepts(item, user) { if (item == @coin) return false; }
        \\    fn OnEnter(hero) { seen += "+" + hero.name; }
        \\    fn OnLeave(hero) { seen += "-" + hero.name; }
        \\}
        \\component Gem for item {
        \\    var int no = 1; var string seen = "";
        \\    fn CanTake(hero) { if (no > 0) { no -= 1; return false; } }
        \\    fn OnTaken(hero) { seen += "T"; }
        \\    fn CanGive(from, to) { return false; }
        \\    fn OnUse(user, target) { seen += "U"; return true; }
        \\}
        \\component Porter for fighter {
        \\    var string seen = "";
        \\    fn CanCarry(item) { }
        \\    fn OnPickUp(item) { seen += item.name; }
        \\}
    ;
    rules.scripts = &.{.{ .name = "hooks.ogs", .data = hooks_text }};
    rules.og = true;
    var opener: @import("../loaders.zig").world.Opener = .{ .io = std.testing.io, .dat = tmp.dir };
    var g: Game = .{ .io = std.testing.io, .gpa = std.testing.allocator, .worlds = opener.factory(), .models = null };
    defer g.deinit();
    _ = try g.open("01_a", .{ .hero = "Sullivan" }, null);
    const w = g.world.?;
    const T = struct {
        fn attach(wo: anytype, o: *Object, name: []const u8) !*Object {
            return wo.rt.attach(o, (try wo.rt.ogs.component(wo.rt.arena(), null, name)).?, &.{});
        }
    };
    const hero = w.rt.findObject("Sullivan").?;
    const door = w.rt.findObject("door").?;
    const gem = w.rt.findObject("gem").?;
    // Accepts as the examine menu opens: the key's row stays (nil), the coin's goes.
    var rows: [8]@TypeOf(w.*).ExamineEntry = undefined;
    w.act.interaction = .{ .hero = hero, .area = door, .mode = .examine };
    try world.actions.runInteraction(w);
    try std.testing.expectEqual(3, world.actions.examineEntries(w, door, &rows).len);
    const dc = try T.attach(w, door, "Door");
    w.act.interaction = .{ .hero = hero, .area = door, .mode = .examine };
    try world.actions.runInteraction(w);
    const menu = world.actions.examineEntries(w, door, &rows);
    try std.testing.expectEqual(2, menu.len);
    try std.testing.expectEqual(w.rt.findObject("key").?, menu[0].use);
    // Take: CanTake's first false leaves it (no Take()), then nil lets it; OnTaken, OnPickUp.
    const gc = try T.attach(w, gem, "Gem");
    const pc = try T.attach(w, hero, "Porter");
    try items.box.itemOperation(w, gem, hero);
    try std.testing.expectEqual(0, gem.getInt("taken"));
    try items.box.itemOperation(w, gem, hero);
    try std.testing.expectEqual(1, gem.getInt("taken"));
    try std.testing.expectEqualStrings("T", gc.getString("seen"));
    try std.testing.expectEqualStrings("gem", pc.getString("seen"));
    // CanGive false: not to another; OnUse true: the use done (the game's not asked).
    try std.testing.expect(!items.give.canGive(w, gem, hero, door));
    try std.testing.expect(items.give.canGive(w, door, hero, gem));
    try std.testing.expect(try hooks.itemUse(w, hero, gem, null));
    try std.testing.expectEqualStrings("TU", gc.getString("seen"));
    // OnEnter / OnLeave: Sullivan walks into its polygon, then out (the area moves away).
    @import("../state.zig").world.actorOf(hero).placed = true;
    const p = w.screenPos(hero);
    var near = [_][3]f32{ .{ p[0] - 50, p[1] - 50, 0 }, .{ p[0] + 50, p[1] - 50, 0 }, .{ p[0] + 50, p[1] + 50, 0 }, .{ p[0] - 50, p[1] + 50, 0 } };
    var far = [_][3]f32{ .{ -900, -900, 0 }, .{ -800, -900, 0 }, .{ -800, -800, 0 }, .{ -900, -800, 0 } };
    var area = [_]@import("../core.zig").map.Area{.{ .name = "doorA", .points = &near, .control = .{ 0, 0 } }};
    w.map.areas = &area;
    defer w.map.areas = &.{};
    for (0..2) |_| try game.life.tickObjects(w);
    area[0].points = &far;
    try game.life.tickObjects(w);
    try std.testing.expectEqualStrings("+Sullivan-Sullivan", dc.getString("seen"));
}

test "OpenGorky: scripted abilities in a battle — the brief's examples at the battle's events" {
    const rules = @import("../rules.zig");
    const rules_text = @import("../loaders.zig").rules_text;
    const combat = @import("../combat.zig");
    const ev = combat.events;
    const Battle = @import("../battle.zig").battle.Battle;
    const Value = @import("../script.zig").value.Value;
    const gpa = std.testing.allocator;
    defer rules.reset();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture.writeCommon(tmp.dir);
    try fixture.writeLevel(tmp.dir, "01_a", "int enemies_killed;");
    // Rows by object name: the kids report to granny, granny rages, Sullivan reflects and
    // is invulnerable for his first turn; the rooted kid never walks.
    try rules_text.apply(&.{
        .{ .name = "rules\\abilities.ss", .data = @import("../script.zig").ogs.print.examples ++
            \\component Reflect for fighter {
            \\    param int pct = 30;
            \\    fn OnHit(attacker, weapon, amount) {
            \\        if (attacker != nil and attacker != host) fighter::Damage(attacker, amount * pct / 100, from: host, kind: "reflect");
            \\        return amount;
            \\    }
            \\}
            \\component Rooted for fighter { fn CanWalk() { return false; } fn OnSpawn() { battle::SetVar("rooted", host.side); } }
        },
        .{ .name = "rules\\fighters.ss", .data =
        \\Abilities(fighter = "kid1", class = 0, scripts = list(Avenger(avenger = "granny"), Rooted()));
        \\Abilities(fighter = "kid2", class = 0, scripts = list(Avenger(avenger = "granny")));
        \\Abilities(fighter = "granny", class = 0, scripts = list(GrandmaRage(), Rage(below_pct = 50, factor = 2.5)));
        \\Abilities(fighter = "Sullivan", class = 0, scripts = list(Reflect(pct = 50), Invulnerable(turns = 1)));
        },
    });
    try std.testing.expectEqual(1, rules.scripts.len);
    rules.og = true;
    var opener: @import("../loaders.zig").world.Opener = .{ .io = std.testing.io, .dat = tmp.dir };
    var g: Game = .{ .io = std.testing.io, .gpa = gpa, .worlds = opener.factory(), .models = null };
    defer g.deinit();
    _ = try g.open("01_a", .{ .hero = "Sullivan" }, null);
    const w = g.world.?;
    const cls = try w.rt.arena().create(@import("../script.zig").object.Class);
    cls.* = .{ .name = "t.ftr", .parent = null };
    var objs: [4]*@import("../script.zig").object.Object = undefined;
    objs[0] = w.rt.findObject("Sullivan").?;
    for ([_][]const u8{ "granny", "kid1", "kid2" }, objs[1..]) |n, *o| {
        o.* = try w.addObject(n, cls, .{ .kind = .actor });
        for ([_][]const u8{ "hp", "max_hp" }) |v| try o.*.declare(w.rt.arena(), v, .{ .type = .int, .value = .{ .int = 100 } });
    }
    objs[0].setInt("hp", 100);
    const n = 16;
    w.battle = Battle{ .gpa = gpa, .blocked = try gpa.alloc(bool, n), .occupant = try gpa.alloc(u16, n), .reach_left = try gpa.alloc(f32, n), .fire = try gpa.alloc(u8, n), .gas = try gpa.alloc(u8, n), .width = 4, .height = 4 };
    const b = &w.battle.?;
    defer {
        b.deinit();
        w.battle = null;
    }
    @memset(b.blocked, false);
    @memset(b.occupant, 0xffff);
    for (objs, 0..) |o, i| try b.fighters.append(gpa, .{ .obj = o, .side = if (i == 0) .hero else .enemy, .tile = .{ @intCast(i), 0 }, .size = 1 });
    try ev.spawn(b, w, 0);
    try std.testing.expectEqual(2, objs[0].components.items.len);
    try std.testing.expectEqual(objs[1], @import("../script.zig").object.Object.of(objs[2].components.items[0].getVar("avenger").?.value.ref));
    try std.testing.expectEqualStrings("enemy", ev.getVar(b, "rooted").string);
    // Invulnerable for its own first turn: nothing, Reflect still returns half to the kid.
    try std.testing.expectEqual(0, try ev.hit(b, w, 2, 0, objs[1], 20));
    try std.testing.expectEqual(90, objs[2].getInt("hp"));
    try ev.turnStart(b, w, .enemy);
    try std.testing.expect(b.fighters.items[2].stuck and !b.fighters.items[3].stuck and !b.fighters.items[2].canWalk());
    try std.testing.expectEqual(0, try ev.hit(b, w, 2, 0, objs[1], 20));
    try ev.turnStart(b, w, .hero);
    try std.testing.expectEqual(20, try ev.hit(b, w, 2, 0, objs[1], 20));
    try std.testing.expectEqual(70, objs[2].getInt("hp"));
    // The kids die by Sullivan: granny's target, the counter, at 2 her rage.
    for ([_]u16{ 2, 3 }) |k| {
        try combat.scriptDamage(b, w, k, 200, "", 0);
    }
    try std.testing.expect(b.fighters.items[2].dead and b.fighters.items[3].dead);
    try std.testing.expectEqual(@as(?u16, 0), b.fighters.items[1].grandma_target);
    try std.testing.expectEqual(Value{ .int = 2 }, ev.getVar(b, "grandma_kids"));
    try std.testing.expectEqual(99, b.fighters.items[1].berserk);
    // Rage: below half its health granny strikes ×2.5 (_ftol), above it as it is.
    try std.testing.expectEqual(7, try ev.hit(b, w, 1, 0, objs[1], 7));
    objs[1].setInt("hp", 40);
    try std.testing.expectEqual(17, try ev.hit(b, w, 1, 0, objs[1], 7));
    // Host fields and the builtins' battle side.
    try std.testing.expectEqual(Value{ .bool = false }, ev.hostField(w, objs[2], "alive").?);
    try std.testing.expect(ev.addState(b, &b.fighters.items[0], "freeze", 2) and b.fighters.items[0].frozen == 2);
    try std.testing.expect(!ev.addState(b, &b.fighters.items[0], "nap", 2));
}

test "OpenGorky: native abilities live with the fighter, first; a battle re-attaches only the scripted ones" {
    const rules = @import("../rules.zig");
    const rules_text = @import("../loaders.zig").rules_text;
    const combat = @import("../combat.zig");
    const Battle = @import("../battle.zig").battle.Battle;
    const gpa = std.testing.allocator;
    defer rules.reset();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture.writeCommon(tmp.dir);
    try fixture.writeLevel(tmp.dir, "01_a", "int enemies_killed;");
    try rules_text.apply(&.{
        .{ .name = "rules\\abilities.ss", .data =
        \\component Once for fighter { var int n = 0; fn OnSpawn() { n += 1; } fn ExtraAction() { return false; } }
        },
        .{ .name = "rules\\fighters.ss", .data =
        \\Abilities(fighter = "kid", class = 0, double_turn = 1, monitor = 1, scripts = list(Once()));
        },
    });
    rules.og = true;
    var opener: @import("../loaders.zig").world.Opener = .{ .io = std.testing.io, .dat = tmp.dir };
    var g: Game = .{ .io = std.testing.io, .gpa = gpa, .worlds = opener.factory(), .models = null };
    defer g.deinit();
    _ = try g.open("01_a", .{ .hero = "Sullivan" }, null);
    const w = g.world.?;
    const cls = try w.rt.arena().create(@import("../script.zig").object.Class);
    cls.* = .{ .name = "t.ftr", .parent = null };
    const kid = try w.addObject("kid", cls, .{ .kind = .actor });
    // As the world makes it (world/start.zig actorHooks): its natives in the row's order.
    try natives.attach(&w.rt, kid);
    try natives.attach(&w.rt, kid);
    try std.testing.expectEqual(2, kid.components.items.len);
    try std.testing.expectEqualStrings("DoubleTurn", kid.components.items[0].name);
    try std.testing.expect(kid.implementsC("Monitor") and !kid.implementsC("Immobile"));
    const n = 4;
    w.battle = Battle{ .gpa = gpa, .blocked = try gpa.alloc(bool, n), .occupant = try gpa.alloc(u16, n), .reach_left = try gpa.alloc(f32, n), .fire = try gpa.alloc(u8, n), .gas = try gpa.alloc(u8, n), .width = 2, .height = 2 };
    const b = &w.battle.?;
    defer {
        b.deinit();
        w.battle = null;
    }
    try b.fighters.append(gpa, .{ .obj = kid, .side = .enemy, .tile = .{ 0, 0 }, .size = 1 });
    // Two battles: the natives stay, the scripted one is attached anew after them.
    for (0..2) |_| try combat.events.spawn(b, w, 0);
    try std.testing.expectEqual(3, kid.components.items.len);
    try std.testing.expectEqual(1, kid.components.items[2].getInt("n"));
    // ExtraAction: the native DoubleTurn answers first (Once's false is not asked).
    try std.testing.expect(try combat.natives.extraAction(w, kid));
    // The rules read again (the editor's edit): its natives anew, first; Once stays after.
    try rules_text.reload(&.{
        .{ .name = "rules\\abilities.ss", .data = "component Once for fighter { var int n = 0; fn OnSpawn() { n += 1; } fn ExtraAction() { return false; } }" },
        .{ .name = "rules\\fighters.ss", .data = "Abilities(fighter = \"kid\", class = 0, immobile = 1, scripts = list(Once()));" },
    });
    try natives.reattach(&w.rt, kid);
    try std.testing.expectEqual(2, kid.components.items.len);
    try std.testing.expectEqualStrings("Immobile", kid.components.items[0].name);
    try std.testing.expectEqual(1, kid.components.items[1].getInt("n"));
    try std.testing.expect(kid.implementsC("Immobile") and !kid.implementsC("Monitor"));
    try std.testing.expect(!try combat.natives.extraAction(w, kid));
}

test "OpenGorky: a native's params are its instance's variables (host.get(Stand)); a script changes what it does" {
    const rules = @import("../rules.zig");
    const rules_text = @import("../loaders.zig").rules_text;
    const combat = @import("../combat.zig");
    const Battle = @import("../battle.zig").battle.Battle;
    const gpa = std.testing.allocator;
    defer rules.reset();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture.writeCommon(tmp.dir);
    try fixture.writeLevel(tmp.dir, "01_a", "int enemies_killed;");
    try rules_text.apply(&.{
        .{ .name = "rules\\abilities.ss", .data =
        \\component Turn for fighter { fn OnSpawn() {
        \\    // `host.get(Stand)` names the native component as `fighter::Native` does.
        \\    var s = host.get(Stand);
        \\    if (!(host is Stand) or s != fighter::Native(host, "Stand")) return;
        \\    s.angle = 0.5; s.after_move = true;
        \\} }
        },
        .{ .name = "rules\\fighters.ss", .data =
        \\Abilities(fighter = "kid", class = 0, stand = 3.14, scripts = list(Turn()));
        },
    });
    rules.og = true;
    var opener: @import("../loaders.zig").world.Opener = .{ .io = std.testing.io, .dat = tmp.dir };
    var g: Game = .{ .io = std.testing.io, .gpa = gpa, .worlds = opener.factory(), .models = null };
    defer g.deinit();
    _ = try g.open("01_a", .{ .hero = "Sullivan" }, null);
    const w = g.world.?;
    const cls = try w.rt.arena().create(@import("../script.zig").object.Class);
    cls.* = .{ .name = "t.ftr", .parent = null };
    const kid = try w.addObject("kid", cls, .{ .kind = .actor });
    try natives.attach(&w.rt, kid);
    const stand = natives.find(kid, .stand).?;
    try std.testing.expectEqual(@as(f32, 3.14), stand.getVar("angle").?.value.float);
    try std.testing.expectEqual(@as(f32, 3.14), combat.natives.standAngle(w, kid, false).?);
    try std.testing.expect(combat.natives.standAngle(w, kid, true) == null);
    const n = 4;
    w.battle = Battle{ .gpa = gpa, .blocked = try gpa.alloc(bool, n), .occupant = try gpa.alloc(u16, n), .reach_left = try gpa.alloc(f32, n), .fire = try gpa.alloc(u8, n), .gas = try gpa.alloc(u8, n), .width = 2, .height = 2 };
    const b = &w.battle.?;
    defer {
        b.deinit();
        w.battle = null;
    }
    try b.fighters.append(gpa, .{ .obj = kid, .side = .enemy, .tile = .{ 0, 0 }, .size = 1 });
    // Its scripted Turn writes Stand's variables (fighter::Native): the engine reads them.
    try combat.events.spawn(b, w, 0);
    try std.testing.expectEqual(@as(f32, 0.5), combat.natives.standAngle(w, kid, false).?);
    try std.testing.expectEqual(@as(f32, 0.5), combat.natives.standAngle(w, kid, true).?);
}

/// A world of 01_a with Sullivan (hero) and `foes` (enemy fighters, 100 hp) in a 4×4
/// battle, the rules `abilities` (OGS components) loaded: the points' tests.
const PointsBattle = struct {
    tmp: std.testing.TmpDir,
    opener: @import("../loaders.zig").world.Opener,
    g: Game,
    log: std.Io.Writer.Allocating,
    gun: *@import("../script.zig").object.Object,

    const Object = @import("../script.zig").object.Object;
    const Battle = @import("../battle.zig").battle.Battle;

    fn init(self: *PointsBattle, abilities: []const u8, foes: []const []const u8) !void {
        const rules = @import("../rules.zig");
        const gpa = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        try fixture.writeCommon(self.tmp.dir);
        try fixture.writeLevel(self.tmp.dir, "01_a", "int enemies_killed; int levelMode;");
        try @import("../loaders.zig").rules_text.apply(&.{.{ .name = "rules\\abilities.ss", .data = abilities }});
        rules.og = true;
        self.opener = .{ .io = std.testing.io, .dat = self.tmp.dir };
        self.g = .{ .io = std.testing.io, .gpa = gpa, .worlds = self.opener.factory(), .models = null };
        _ = try self.g.open("01_a", .{ .hero = "Sullivan" }, null);
        const w = self.g.world.?;
        const cls = try w.rt.arena().create(@import("../script.zig").object.Class);
        cls.* = .{ .name = "t.ftr", .parent = null };
        const n = 16;
        w.battle = Battle{ .gpa = gpa, .blocked = try gpa.alloc(bool, n), .occupant = try gpa.alloc(u16, n), .reach_left = try gpa.alloc(f32, n), .fire = try gpa.alloc(u8, n), .gas = try gpa.alloc(u8, n), .width = 4, .height = 4 };
        const b = &w.battle.?;
        @memset(b.blocked, false);
        @memset(b.occupant, 0xffff);
        self.log = .init(gpa);
        b.log = &self.log.writer;
        const sul = w.rt.findObject("Sullivan").?;
        sul.setInt("hp", 100);
        try b.fighters.append(gpa, .{ .obj = sul, .side = .hero, .tile = .{ 0, 0 }, .size = 1 });
        for (foes, 1..) |name, i| {
            const o = try w.addObject(name, cls, .{ .kind = .actor });
            for ([_][]const u8{ "hp", "max_hp" }) |v| try o.declare(w.rt.arena(), v, .{ .type = .int, .value = .{ .int = 100 } });
            o.kind = @import("../script.zig").traits.ofHost("fighter");
            try b.fighters.append(gpa, .{ .obj = o, .side = .enemy, .tile = .{ @intCast(i), 0 }, .size = 1 });
        }
        for (b.fighters.items, 0..) |f, i| b.grid().place(f.tile, 1, @intCast(i));
        // A pistol (class 1: a pattern), no ammo needed, the first foe's (names
        // declared in lower case, as the scripts' are).
        const wcls = try w.rt.arena().create(@import("../script.zig").object.Class);
        wcls.* = .{ .name = "gun.wpn", .parent = null };
        self.gun = try w.addObject("gun", wcls, .{ .kind = .weapon });
        for ([_][]const u8{ "class", "max_damage", "ammoused", "nameid", "damage_kind", "light_armor_pct", "medium_armor_pct", "heavy_armor_pct" }, [_]i32{ 1, 30, 0, 9, 0, 0, 0, 0 }) |v, x| try self.gun.declare(w.rt.arena(), v, .{ .type = .int, .value = .{ .int = x } });
        try self.gun.declare(w.rt.arena(), "owner", .{ .type = .string, .value = .{ .string = if (foes.len > 0) foes[0] else "" } });
        try @import("../world.zig").party.syncRolesIn(w, b);
    }

    fn deinit(self: *PointsBattle) void {
        const w = self.g.world.?;
        w.battle.?.deinit();
        w.battle = null;
        self.log.deinit();
        self.g.deinit();
        self.tmp.cleanup();
        @import("../rules.zig").reset();
    }

    fn world(self: *PointsBattle) *@import("../state.zig").world.World {
        return self.g.world.?;
    }

    fn attach(self: *PointsBattle, o: *Object, name: []const u8) !void {
        const rt = &self.world().rt;
        _ = try rt.attach(o, (try rt.ogs.component(rt.arena(), null, name)).?, &.{});
    }

    /// `o`'s components dropped (the natives' too: none here).
    fn detach(o: *Object) void {
        o.components.clearRetainingCapacity();
        o.refreshImplements();
    }

    fn has(self: *PointsBattle, line: []const u8) bool {
        return std.mem.indexOf(u8, self.log.written(), line) != null;
    }
};

test "OpenGorky: the strike's points — a number changes the roll, the damage, the exp; nil changes nothing" {
    const strike = @import("../combat.zig");
    var t: PointsBattle = undefined;
    try t.init(
        \\component Gun for weapon {
        \\    fn HitChance(user, target, chance) { return 1000; }
        \\    fn BaseDamage(user, target, amount) { return 40; }
        \\    fn RechargeTurns(user, turns) { return 2; }
        \\    fn OnFired(user, tile) { if (user == @Sullivan) battle::AddVar("fired", tile[0] * 10 + tile[1]); }
        \\}
        \\component Aim for fighter { fn HitChance(target, weapon, chance) { return chance + 1; } }
        \\component Learner for fighter {
        \\    fn ExperienceGain(amount) { return amount + 100000; }
        \\    fn OnLevelUp(level) { battle::SetVar("level", level); }
        \\    fn OnSkillUp(weapon, level) { battle::SetVar("skill", level); }
        \\}
        \\component Target for fighter {
        \\    fn ChanceToBeHit(attacker, weapon, chance) { return chance + 1; }
        \\    fn Armor(attacker, weapon, armor) { return 3; }
        \\    fn KillReward(killer, amount) { return 7; }
        \\}
        \\component Miser for fighter { fn ExperienceGain(amount) { return -500; } }
        \\component Fight for battle { fn OnAttack(attacker, weapon, victims) { if (victims[0] == @tough) battle::AddVar("attacks", 1); } }
        \\component Quiet for weapon, fighter, battle {
        \\    fn HitChance(a, b, c) { } fn BaseDamage(a, b, c) { } fn RechargeTurns(a, b) { } fn ChanceToBeHit(a, b, c) { }
        \\    fn Armor(a, b, c) { } fn KillReward(a, b) { } fn ExperienceGain(a) { }
        \\}
    , &.{ "tough", "weak" });
    defer t.deinit();
    const w = t.world();
    const b = &w.battle.?;
    const sul = b.fighters.items[0].obj;
    const tough = b.fighters.items[1].obj;
    const weak = b.fighters.items[2].obj;
    weak.setInt("hp", 10);
    // nil everywhere: no change noted, no recharge (the pistol's class has none).
    for ([_]*PointsBattle.Object{ t.gun, sul, tough, w.level.? }) |o| try t.attach(o, "Quiet");
    try strike.resolveAttack(b, w, 0, t.gun, .{ .tile = .{ 1, 0 }, .effect = 0, .pct = 100 }, null, false);
    try std.testing.expect(!t.has(" -> "));
    try std.testing.expectEqual(0, @TypeOf(w.*).nativeOf(t.gun).fight.recharge);
    for ([_]*PointsBattle.Object{ t.gun, sul, tough, w.level.? }) |o| PointsBattle.detach(o);
    tough.setInt("hp", 100);
    // The numbers: weapon, attacker, target in one chain; the hit sure, 40 before armour 3.
    try t.attach(t.gun, "Gun");
    try t.attach(sul, "Aim");
    try t.attach(sul, "Learner");
    try t.attach(tough, "Target");
    try t.attach(weak, "Target");
    try t.attach(w.level.?, "Fight");
    for (0..2) |_| try strike.resolveAttack(b, w, 0, t.gun, .{ .tile = .{ 1, 0 }, .effect = 0, .pct = 100 }, null, false);
    for ([_][]const u8{
        "  HitChance gun: ",  " -> 1000\n",              "  HitChance Sullivan: 1000 -> 1001\n", "  ChanceToBeHit tough: 1001 -> 1002\n",
        "chance 1002%): hit", "  Armor tough: 0 -> 3\n", " -> 40\n",                             "  RechargeTurns gun: 0 -> 2\n",
        "  var fired = 10\n", "  var attacks = 2\n",     "  ExperienceGain Sullivan: ",          "  var level = ",
        "  var skill = 2\n",
    }) |line| if (!t.has(line)) {
        std.debug.print("missing {s} in:\n{s}\n", .{ line, t.log.written() });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(2, @TypeOf(w.*).nativeOf(t.gun).fight.recharge);
    try std.testing.expect(t.has("  Sullivan: +1000"));
    // The kill's reward: 7 instead of 0.2 × 100.
    try strike.resolveAttack(b, w, 0, t.gun, .{ .tile = .{ 2, 0 }, .effect = 0, .pct = 100 }, null, false);
    try std.testing.expect(t.has("  KillReward weak: 20 -> 7\n") and b.fighters.items[2].dead);
    // A negative answer gains nothing: experience never goes down.
    PointsBattle.detach(sul);
    try t.attach(sul, "Miser");
    const exp = sul.getInt("experience");
    try strike.resolveAttack(b, w, 0, t.gun, .{ .tile = .{ 1, 0 }, .effect = 0, .pct = 100 }, null, false);
    try std.testing.expect(t.has(" -> -500\n") and t.has("  Sullivan: +0 exp"));
    try std.testing.expectEqual(exp, sul.getInt("experience"));
}

test "OpenGorky: the battle's points and the AI's — Outcome, OnEnemyTurnOver, OnTick, WalkRange, PreferTarget, ScoreTarget, CanAim" {
    const combat = @import("../combat.zig");
    var t: PointsBattle = undefined;
    try t.init(
        \\component Fight for battle {
        \\    var string end = "";
        \\    fn Outcome() { if (end != "") return end; }
        \\    fn OnEnemyTurnOver(turn) { battle::SetVar("over", turn); }
        \\    fn OnTick() { battle::AddVar("ticks", 1); }
        \\}
        \\component Legs for fighter { fn WalkRange(range) { return 7; } }
        \\component Picky for fighter {
        \\    var int calls = 0;
        \\    fn PreferTarget() { return @Sullivan; }
        \\    fn ScoreTarget(occupant, weapon, score) { calls += 1; if (occupant == @Sullivan) return score + 1000; }
        \\}
        \\component Blind for weapon { fn CanAim(user, tile) { return false; } }
        \\component Quiet for fighter, battle { fn Outcome() { } fn WalkRange(r) { } fn ScoreTarget(o, w, s) { } fn PreferTarget() { } }
    , &.{"kid"});
    defer t.deinit();
    const w = t.world();
    const b = &w.battle.?;
    const kid = b.fighters.items[1].obj;
    const l = w.level.?;
    const plain = try combat.ai.plan(b, w, 1);
    try std.testing.expect(!t.has("calls"));
    try t.attach(l, "Quiet");
    try t.attach(kid, "Quiet");
    // nil: the engine's end (nobody died: not over), its walk range, its plan (the calls
    // counted all the same).
    try std.testing.expect(!try combat.turns.ended(b, w));
    try combat.events.turnStart(b, w, .enemy);
    try std.testing.expectEqual(null, b.fighters.items[1].walk_range);
    const quiet = try combat.ai.plan(b, w, 1);
    try std.testing.expect(quiet.score == plain.score and quiet.attack_at == plain.attack_at);
    try std.testing.expect(!t.has(" -> ") and t.has("  ScoreTarget kid: ") and !t.has("PreferTarget"));
    PointsBattle.detach(l);
    PointsBattle.detach(kid);
    try t.attach(l, "Fight");
    try t.attach(kid, "Legs");
    try t.attach(kid, "Picky");
    // Outcome: nil leaves it to the engine; "won" ends it so; another answer keeps it going
    // (Sullivan dead: the engine would say lost).
    try std.testing.expect(!try combat.turns.ended(b, w));
    b.fighters.items[0].dead = true;
    l.components.items[0].getVar("end").?.value = .{ .string = "on" };
    try std.testing.expect(!try combat.turns.ended(b, w));
    b.fighters.items[0].dead = false;
    try combat.turns.enemyTurnOver(b, w);
    try std.testing.expect(t.has("  var over = 1\n"));
    // WalkRange: 7 this turn (its budget), noted.
    try combat.events.turnStart(b, w, .enemy);
    try std.testing.expectEqual(7, b.fighters.items[1].walkRange());
    try std.testing.expect(t.has("  WalkRange kid: ") and b.fighters.items[1].budget() == 7);
    // The AI: PreferTarget noted, ScoreTarget counted in the log and changing the score; the
    // same plan again from the same state is the same.
    const p1 = try combat.ai.plan(b, w, 1);
    const calls = kid.components.items[1].getInt("calls");
    try std.testing.expect(calls > 0 and p1.score > plain.score);
    try std.testing.expect(t.has("  PreferTarget kid: Sullivan\n"));
    var buf: [64]u8 = undefined;
    try std.testing.expect(t.has(try std.fmt.bufPrint(&buf, "  ScoreTarget kid: {d} calls\n", .{calls})));
    const p2 = try combat.ai.plan(b, w, 1);
    try std.testing.expectEqual(p1.score, p2.score);
    try std.testing.expectEqual(p1.attack_at, p2.attack_at);
    try std.testing.expectEqual(2 * calls, kid.components.items[1].getInt("calls"));
    // CanAim false on every aim: no strike in its plan.
    try std.testing.expect(p1.attack_at != null);
    try t.attach(t.gun, "Blind");
    const p3 = try combat.ai.plan(b, w, 1);
    try std.testing.expect(p3.attack_at == null and t.has("  CanAim kid: "));
    // OnTick each battle tick; "won" ends the battle.
    b.phase = .won;
    try combat.tick.tick(b, w);
    try std.testing.expect(t.has("  var ticks = 1\n"));
    b.phase = .enemy;
    l.components.items[0].getVar("end").?.value = .{ .string = "won" };
    try std.testing.expect(try combat.turns.ended(b, w));
    try std.testing.expectEqual(.won, b.phase);
}

test "OpenGorky: CanDie — false keeps a fighter at 1 from any blow (a script's, a bomb's hp 0), nil lets it die" {
    const combat = @import("../combat.zig");
    var t: PointsBattle = undefined;
    try t.init(
        \\component Stubborn for fighter { var int lives = 2; fn CanDie(killer) { if (lives > 0) { lives -= 1; return false; } } }
        \\component Quiet for fighter { fn CanDie(killer) { } }
    , &.{ "kid", "imp" });
    defer t.deinit();
    const w = t.world();
    const b = &w.battle.?;
    try t.attach(b.fighters.items[1].obj, "Stubborn");
    try t.attach(b.fighters.items[2].obj, "Quiet");
    try combat.scriptDamage(b, w, 1, 500, "", 0);
    try std.testing.expect(!b.fighters.items[1].dead and b.fighters.items[1].hp() == 1 and t.has("  kid: CanDie false\n"));
    // As the large bomb kills (hp 0, then a blow of 1).
    fields.setHp(b.fighters.items[1].obj, 0);
    try combat.scriptDamage(b, w, 1, 1, "", 0);
    try std.testing.expect(!b.fighters.items[1].dead and b.fighters.items[1].hp() == 1);
    try combat.scriptDamage(b, w, 1, 500, "", 0);
    try std.testing.expect(b.fighters.items[1].dead);
    // A blow that leaves health is not asked; nil is no answer: it dies.
    try combat.scriptDamage(b, w, 2, 99, "", 0);
    try combat.scriptDamage(b, w, 2, 1, "", 0);
    try std.testing.expect(b.fighters.items[2].dead and !t.has("imp: CanDie"));
}

test "OpenGorky: BattleSpawnEnemy/Hero/Civilian put a fighter of a class key on a free tile (its side, abilities, OnSpawn, weapons); BattleLose from a civilian's OnDeath; FighterTransform morphs one: its health kept, its scripted abilities swapped" {
    const sources = @import("../world.zig").sources;
    const combat = @import("../combat.zig");
    const Value = @import("../script.zig").value.Value;
    const abilities =
        \\component Summoner for fighter {
        \\    fn run() {
        \\        var a = battle::SpawnEnemy("ft_boss", 3, 3);  // its name
        \\        var b = battle::SpawnEnemy("ft_boss", 3, 3);  // taken
        \\        var c = battle::SpawnEnemy("ft_none", 2, 2);  // no such class
        \\        var d = battle::SpawnEnemy("ft_boss", 9, 9);  // off the grid
        \\        var e = battle::SpawnHero("plain.ftr", 2, 3);
        \\        var f = battle::SpawnCivilian("plain.ftr", 3, 2);
        \\        var g = battle::SpawnCivilian("plain.ftr", 2, 2, ai: "normal");
        \\        var h = battle::SpawnCivilian("plain.ftr", 1, 3, ai: "smart");    // no such AI
        \\        var t = fighter::Transform("kid", "ft_boss");
        \\        fighter::SetHp("kid", 77);                         // before the morph ends: kept
        \\        return [a, b, c, d, e, f, g, h, t, fighter::Transform("kid", "ft_none")];
        \\    }
        \\}
        \\component Spawned for fighter { var int n = 0; fn OnSpawn() { n += 1; battle::AddVar("spawned", 1); } }
        \\component Old for fighter { }
        \\component Escort for fighter { fn OnDeath(killer) { battle::Lose(); } }
    ;
    var t: PointsBattle = undefined;
    try t.init(abilities, &.{"kid"});
    defer t.deinit();
    try @import("../loaders.zig").rules_text.reload(&.{
        .{ .name = "rules\\abilities.ss", .data = abilities },
        .{ .name = "rules\\fighters.ss", .data = "Abilities(fighter = \"ft_boss\", class = 0, immobile = 1, scripts = list(Spawned()));" },
    });
    const w = t.world();
    const b = &w.battle.?;
    var blocked: [16]bool = @splat(false);
    w.map.combat = .{ .center = .{ 0, 0, 0 }, .rotation = 0, .cell_size = .{ 1, 1 }, .width = 4, .height = 4, .blocked = &blocked, .heights = &.{} };
    defer w.map.combat = null;
    // ft_boss arms itself (its `weapons`); plain.ftr is of its class without them: copies.
    try sources.addSource(w, "Fighter.s", "float x; float y; float z; int hp; int max_hp; int classic_id; int charSize; int walk_range; string weapons;");
    try sources.addSource(w, "ft_boss.ss", "hp = 30; max_hp = 30; weapons = \"claw.wpn\";");
    try sources.addSource(w, "plain.ftr", "#include Fighter.s\nfunction init()\n{\n#include ft_boss.ss\nweapons = \"\";\n};");
    try sources.addSource(w, "claw.wpn", "string Owner; int place;");
    const kid = b.fighters.items[1].obj;
    // The kid's battle abilities before: Old (not in ft_boss's row) and Spawned (in it).
    for ([_][]const u8{ "Old", "Spawned" }) |c| {
        try t.attach(kid, c);
        kid.components.items[kid.components.items.len - 1].scope = .battle;
    }
    kid.components.items[1].getVar("n").?.value = .{ .int = 5 };
    try t.attach(b.fighters.items[0].obj, "Summoner");
    const got = (try w.rt.callIfExists(b.fighters.items[0].obj.components.items[0], "run", &.{})).?;
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{f}", .{got});
    try std.testing.expectEqualStrings("[\"ft_boss\", nil, nil, nil, \"plain\", \"plain_2\", \"plain_3\", nil, 1, 0]", aw.written());
    const at = struct {
        fn f(bt: *PointsBattle.Battle, ww: anytype, name: []const u8) *@import("../battle.zig").fighter.Fighter {
            return &bt.fighters.items[bt.fighterOf(ww.rt.findObject(name).?).?];
        }
    }.f;
    const boss = at(b, w, "ft_boss");
    const hero = at(b, w, "plain");
    const dummy = at(b, w, "plain_2");
    const civ = at(b, w, "plain_3");
    // Sides and who controls them: the enemy and the civilians act by AI on the enemies'
    // turn (a dummy never: aiMode 2), the hero is the player's.
    try std.testing.expect(boss.side == .enemy and boss.tile[0] == 3 and boss.tile[1] == 3 and boss.hp() == 30);
    try std.testing.expect(boss.actsOn(.enemy) and !boss.controllable());
    try std.testing.expect(hero.side == .hero and hero.controllable() and !hero.actsOn(.enemy));
    try std.testing.expect(dummy.side == .civilian and dummy.actsOn(.enemy) and !dummy.actsOn(.hero) and !dummy.controllable() and dummy.obj.getInt("ai_mode") == 2);
    try std.testing.expect(civ.side == .civilian and civ.obj.getInt("ai_mode") != 2);
    try std.testing.expectEqualStrings("civilian", combat.events.hostField(w, civ.obj, "side").?.string);
    try std.testing.expect(boss.obj.implementsC("Immobile") and hero.obj.implementsC("Immobile"));
    try std.testing.expectEqual(Value{ .int = 4 }, combat.events.getVar(b, "spawned"));
    try std.testing.expectEqualStrings("ft_boss", w.rt.findObject("ft_boss_claw").?.getString("owner"));
    try std.testing.expectEqualStrings("plain", w.rt.findObject("plain_ft_boss_claw").?.getString("owner"));
    // An OGS FighterSetHp is in the battle log.
    try std.testing.expect(t.has("  kid: hp set 77\n"));
    // The transform: the morph begun (the Transform row's path), then its class: Immobile,
    // the health the script set, ft_boss's scripted abilities (Spawned kept as it was, Old gone).
    try std.testing.expect(t.has("  kid: transform\n") and @TypeOf(w.*).nativeOf(kid).actor.morph != null);
    try std.testing.expect(!kid.implementsC("Immobile"));
    try combat.states.morphDone(w, kid);
    try std.testing.expect(kid.implementsC("Immobile") and kid.getInt("hp") == 77 and kid.getInt("max_hp") == 30);
    var spawned: usize = 0;
    for (kid.components.items) |c| {
        try std.testing.expect(!std.mem.eql(u8, c.name, "Old"));
        if (std.mem.eql(u8, c.name, "Spawned")) {
            spawned += 1;
            try std.testing.expectEqual(5, c.getInt("n"));
        }
    }
    try std.testing.expectEqual(1, spawned);
    // Civilians count neither way: the enemies dead, the heroes win with them alive.
    try combat.scriptDamage(b, w, 1, 500, "", null);
    try combat.scriptDamage(b, w, @intCast(b.fighterOf(boss.obj).?), 500, "", null);
    try std.testing.expect(try combat.turns.ended(b, w));
    try std.testing.expectEqual(.won, b.phase);
    // An escorted civilian's death declares the loss (BattleLose in its OnDeath).
    b.phase = .enemy;
    try t.attach(civ.obj, "Escort");
    try combat.scriptDamage(b, w, @intCast(b.fighterOf(civ.obj).?), 500, "", null);
    try std.testing.expect(try combat.turns.ended(b, w));
    try std.testing.expect(b.phase == .lost and t.has("  Declared: lost\n"));
}

test "OpenGorky: roles — Hero for the party and the heroes' side, Enemy for the battle; `for Hero` silent on an enemy" {
    const rules = @import("../rules.zig");
    const rules_text = @import("../loaders.zig").rules_text;
    const combat = @import("../combat.zig");
    const ev = combat.events;
    const party = @import("../world.zig").party;
    const script = @import("../script.zig");
    const Battle = @import("../battle.zig").battle.Battle;
    const Value = script.value.Value;
    const gpa = std.testing.allocator;
    defer rules.reset();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture.writeCommon(tmp.dir);
    try fixture.writeLevel(tmp.dir, "01_a", "int enemies_killed;");
    try rules_text.apply(&.{
        .{ .name = "rules\\abilities.ss", .data =
        \\use foundation;
        \\component Medic for Hero {
        \\    var int turns = 0;
        \\    var string got = "";
        \\    fn OnTurnStart(side, turn) { turns += 1; }
        \\    fn OnRoleGained(role) { got += "+" + role; }
        \\    fn OnRoleLost(role) { got += "-" + role; }
        \\}
        \\component Probe for fighter {
        \\    fn slot() { if (host is Hero) return host.as(Hero).party_slot(); return -1; }
        \\    fn reward() { if (host is Enemy) return host.as(Enemy).reward(); return -1; }
        \\    fn kinds(x: fighter) { return [host is Fighter, host is Actor, host is Item]; }
        \\}
        },
        .{ .name = "rules\\fighters.ss", .data =
        \\Abilities(fighter = "Sullivan", class = 0, scripts = list(Medic(), Probe()));
        \\Abilities(fighter = "singer", class = 0, scripts = list(Medic(), Probe()));
        \\Abilities(fighter = "kid", class = 0, scripts = list(Medic(), Probe()));
        },
    });
    rules.og = true;
    var opener: @import("../loaders.zig").world.Opener = .{ .io = std.testing.io, .dat = tmp.dir };
    var g: Game = .{ .io = std.testing.io, .gpa = gpa, .worlds = opener.factory(), .models = null };
    defer g.deinit();
    _ = try g.open("01_a", .{ .hero = "Sullivan" }, null);
    const w = g.world.?;
    const sul = w.rt.findObject("Sullivan").?;
    // The party's hero has Hero from the location's start.
    try std.testing.expect(sul.roles.contains(.hero) and !sul.roles.contains(.enemy));
    const cls = try w.rt.arena().create(script.object.Class);
    cls.* = .{ .name = "t.ftr", .parent = null };
    const singer = try w.addObject("singer", cls, .{ .kind = .actor, .hro = true });
    const kid = try w.addObject("kid", cls, .{ .kind = .actor });
    for ([_]*script.object.Object{ singer, kid }) |o| {
        for ([_][]const u8{ "hp", "max_hp" }) |v| try o.declare(w.rt.arena(), v, .{ .type = .int, .value = .{ .int = 100 } });
        // A fighter's class declares walk_range (World.hostKind); this bare one does not.
        o.kind = script.traits.ofHost("fighter");
    }
    try std.testing.expect(singer.roles.count() == 0 and kid.roles.count() == 0);
    const n = 16;
    w.battle = Battle{ .gpa = gpa, .blocked = try gpa.alloc(bool, n), .occupant = try gpa.alloc(u16, n), .reach_left = try gpa.alloc(f32, n), .fire = try gpa.alloc(u8, n), .gas = try gpa.alloc(u8, n), .width = 4, .height = 4 };
    const b = &w.battle.?;
    defer {
        b.deinit();
        w.battle = null;
    }
    @memset(b.blocked, false);
    @memset(b.occupant, 0xffff);
    for ([_]*script.object.Object{ sul, singer, kid }, 0..) |o, i| try b.fighters.append(gpa, .{ .obj = o, .side = if (i < 2) .hero else .enemy, .tile = .{ @intCast(i), 0 }, .size = 1 });
    try ev.spawn(b, w, 0);
    // The ally outside the party is Hero in the battle; the kid Enemy only.
    try std.testing.expect(singer.roles.contains(.hero) and kid.roles.contains(.enemy) and !kid.roles.contains(.hero));
    const medic = struct {
        fn of(o: *script.object.Object) *script.object.Object {
            return o.components.items[0];
        }
        fn probe(rt: *script.runtime.Runtime, o: *script.object.Object, f: []const u8, args: []const Value) !Value {
            return (try rt.callIfExists(o.components.items[1], f, args)).?;
        }
    };
    // Granted after the attach: the singer's Medic hears it; Sullivan had it already.
    try std.testing.expectEqualStrings("", medic.of(sul).getString("got"));
    try std.testing.expectEqualStrings("+Hero", medic.of(singer).getString("got"));
    try std.testing.expectEqualStrings("", medic.of(kid).getString("got"));
    // `for Hero` on the enemy: attached, silent.
    try ev.turnStart(b, w, .hero);
    try std.testing.expectEqual(1, medic.of(sul).getInt("turns"));
    try std.testing.expectEqual(1, medic.of(singer).getInt("turns"));
    try std.testing.expectEqual(0, medic.of(kid).getInt("turns"));
    // party_slot: 0 for Sullivan, nil for the ally outside the party; the kid's reward.
    try std.testing.expectEqual(Value{ .int = 0 }, try medic.probe(&w.rt, sul, "slot", &.{}));
    try std.testing.expectEqual(Value.nil, try medic.probe(&w.rt, singer, "slot", &.{}));
    try std.testing.expectEqual(Value{ .int = -1 }, try medic.probe(&w.rt, kid, "slot", &.{}));
    try std.testing.expectEqual(Value{ .int = 20 }, try medic.probe(&w.rt, kid, "reward", &.{}));
    // The host kind: a fighter is an Actor, no Item; a parameter of a kind is checked.
    const k = try medic.probe(&w.rt, kid, "kinds", &.{sul.ref()});
    try std.testing.expectEqualDeep(@as([]const Value, &.{ .{ .bool = true }, .{ .bool = true }, .{ .bool = false } }), k.list);
    try std.testing.expectError(error.ScriptFault, w.rt.callIfExists(kid.components.items[1], "kinds", &.{w.level.?.ref()}));
    try std.testing.expectEqualStrings("kinds: x is not Fighter", w.rt.fault.message);
    // The battle ends: Enemy goes, the ally's Hero goes; Sullivan keeps his.
    b.phase = .won;
    try party.syncRolesIn(w, b);
    try std.testing.expect(kid.roles.count() == 0 and singer.roles.count() == 0 and sul.roles.contains(.hero));
    try std.testing.expectEqualStrings("+Hero-Hero", medic.of(singer).getString("got"));
    try std.testing.expectEqual(Value{ .int = -1 }, try medic.probe(&w.rt, singer, "slot", &.{}));
    // Sullivan leaves the party (HERO_EnableEnumerate 0): no Hero.
    @TypeOf(w.*).nativeOf(sul).hero = false;
    try party.syncRoles(w);
    try std.testing.expect(!sul.roles.contains(.hero));
    try std.testing.expectEqualStrings("-Hero", medic.of(sul).getString("got"));
}

test "OpenGorky: the campaign's leader is the default hero; panel_first orders the party panel" {
    const rules = @import("../rules.zig");
    const rules_text = @import("../loaders.zig").rules_text;
    defer rules.reset();
    try rules_text.apply(&.{.{ .name = "rules\\campaign.ss", .data = "Campaign(leader = \"Ovitz\", panel_first = \"Medusa Sullivan\");" }});
    var sv: save_mod.Save = .init(std.testing.allocator);
    defer sv.deinit();
    try std.testing.expectEqualStrings("Ovitz", sv.hero);
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    // Nobody acted yet: the leader (the selected hero is the opened one, Sullivan).
    try std.testing.expectEqualStrings("Ovitz", t.game.world.?.scene.last_action_hero);
    try fixture.writeArchive(t.tmp.dir, "01_m/other.dat", &.{
        .{ "01_m.lev", "" },
        .{ "Medusa.hro", "int classic_id; int outside_party;" },
    });
    try fixture.writeArchive(t.tmp.dir, "01_m/sprite.dat", &.{});
    _ = try t.go("01_m");
    const w = t.game.world.?;
    @TypeOf(w.*).nativeOf(w.actorObject("Medusa").?).hero = true;
    const p = w.party();
    try std.testing.expectEqual(2, p.len);
    try std.testing.expectEqualStrings("Medusa", p.slice()[0].name);
    try std.testing.expectEqualStrings("Sullivan", p.slice()[1].name);
}

test "OpenGorky project: an archetype's nested blocks (an own one of the same name over it), a look under the archetype, the camera record" {
    const rules = @import("../rules.zig");
    const og = @import("../loaders.zig").ogs;
    const io = std.testing.io;
    defer {
        og.close();
        rules.reset();
    }
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/dat");
    for ([_][2][]const u8{
        .{ "opengorky.mod", "format = ogs\nid = t\ngame = game\n" },
        // The test project's single-record rows.
        .{ "src/rules/campaign.ogs", "Campaign(level = \"01_port\", leader = \"Sullivan\", party = \"\", panel_first = \"Sullivan\", area = \"\", point = 0, scene = \"\", intro = \"\", startup = \"\", menu_logo = \"\", menu_music = \"\", credits_music = \"\", credits = \"\", credits_video = \"\");" },
        .{ "src/ui.ogs", @embedFile("og/port/src/ui.ogs") },
        .{ "src/shell.ogs", "ExeAnims(fight_look = \"fightlook\");\nHoldPoints(one_hand = \"one_hand\");\n" },
        .{ "src/looks/kid.ogs", "module looks { look kid { mesh = \"wnuczek\"; turn_speed = 0.5; walk = [Speed(anim = \"walk\", speed = 3.5)]; idles = [Idle(anim = \"idle1\", weight = 100), Idle(state = 9, anim = \"no\", weight = 1)]; slots = [Slot(name = \"hit\", anim = \"au\")]; } }" },
        .{ "src/characters/kid.ogs", "module characters { fighter kid { look = looks::kid; hp = 5; weapon gun: weapons::stick { place = hand; } } fighter big: kid { hp = 9; } }" },
        .{ "src/weapons/w.ogs", "module weapons { weapon stick { max_damage = 1; } weapon axe { max_damage = 7; } }" },
        .{ "src/battles/b/battle.ogs", "battle b { camera = Camera(perspective = true, eye_x = 2.5, floor_z = -1); fighter f: characters::big { weapon gun: weapons::axe { place = hand; } } fighter g: characters::kid { mesh = \"own\"; } }" },
    }) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    var dat = try og.open(io, tmp.dir);
    defer dat.close(io);
    var g: Game = .{ .io = io, .gpa = std.testing.allocator, .worlds = og.factory(), .models = null };
    defer g.deinit();
    const w = try g.open("b", .{}, null);
    // f's own gun over its archetypes' (the object named as the inherited one), g's the archetype's.
    const fg = w.rt.findObject("f_gun").?;
    try std.testing.expectEqual(7, fg.getInt("max_damage"));
    try std.testing.expectEqualStrings("f", fields.owner(fg));
    try std.testing.expectEqual(1, w.rt.findObject("g_gun").?.getInt("max_damage"));
    try std.testing.expect(w.rt.findObject("gun") == null);
    // The look under the archetypes and the instance: g's own mesh wins; its animations registered.
    const f = w.actorObject("f").?;
    try std.testing.expectEqualStrings("wnuczek", fields.meshFile(f));
    try std.testing.expectEqual(9, f.getInt("hp"));
    try std.testing.expectApproxEqAbs(0.5, fields.getF(f, "turn_speed"), 1e-6);
    try std.testing.expectEqualStrings("own", fields.meshFile(w.actorObject("g").?));
    const a = @import("../state.zig").world.actorOf(f);
    try std.testing.expectEqualStrings("au", a.resolve("hit"));
    try std.testing.expectEqual(1, a.idle_count[0]);
    try std.testing.expectEqualStrings("idle1", a.idle[0][0].anim);
    // The camera record: the level's fields initCamera() sets.
    try std.testing.expectEqual(1, w.level.?.getInt("perspective"));
    try std.testing.expectApproxEqAbs(2.5, fields.getF(w.level.?, "eye_x"), 1e-6);
    try std.testing.expectApproxEqAbs(-1, fields.getF(w.level.?, "floor_z"), 1e-6);
}
