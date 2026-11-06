//! An enemy's "Weapons & attacks" block: assigned only, edited on the weapon's page. Per
//! weapon class it holds (every battle's `.wpn`) or a rule gives: the attack done with
//! it (its MonsterAttack row in force, one line), its damage (the class's, or this
//! character's own override, OpenGorky), what it is worth to the AI, › to the weapon's
//! page; its class swapped (Classic-safe: the `.wpn` includes), a weapon given or taken
//! back (OpenGorky). Then how the AI chooses among them, read from the AI profile in
//! force and those numbers (static text, combat/ai.zig's scoring; no simulation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const picker = @import("picker.zig");
const entries = @import("entries.zig");
const ea = @import("entry_attacks.zig");
const ew = @import("entry_weapons.zig");
const Entry = @import("catalog.zig").Entry;
const common_archive = @import("store.zig").common_archive;
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;

/// One assigned weapon as the AI weighs it: its class text, damage in force, and worth.
const Weapon = struct { at: ea.Attack, text: []const u8, damage: i32, worth: ?i32 };

pub fn block(app: *App, a: Allocator, e: Entry, who: rules.Who, text: []const u8) void {
    var list = ea.attacksOf(app, a, e, who);
    // No fighter of it in the game's battles (shogoth): the attack the editor gives it.
    var built = false;
    if (list.len == 0) for (app.templates) |t| if (t.weapon) |w| if (std.ascii.eqlIgnoreCase(t.class, e.base orelse e.id)) {
        list = a.dupe(ea.Attack, &.{.{ .class = rules.stem(w), .id = ea.weaponId(app, rules.stem(w)), .given = false }}) catch list;
        built = true;
    };
    const class: i32 = @intFromFloat(model.get(text, "battle_class") orelse 0);
    const prof = rules.aiProfile(who, class);
    const scoring = og.core.modules.aiScoring(prof.scoring.?);
    const attack = prof.attack_weight orelse @as(i32, @intFromFloat(model.get(text, "ai_attack_weight") orelse 0));
    if (!gui.block(app, "weapons", tx.get(tx.sec_arsenal), .{ .summary = tx.alloc(a, tx.sum_arsenal, .{ list.len, prof.scoring.? }) })) return;
    defer gui.blockEnd();
    gui.txtWrap(tx.get(if (built) tx.wp_built else tx.wp_hint), .caption, if (built) theme.warn else theme.dim, font_mod.regular);
    if (list.len == 0) gui.note(tx.get(tx.wp_none));
    const ws = a.alloc(Weapon, list.len) catch return;
    var n: usize = 0;
    for (list) |at| {
        var buf: [128]u8 = undefined;
        const ext = if (std.ascii.startsWithIgnoreCase(at.class, "cw_")) ".s" else ".ss";
        const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}{s}", .{ at.class, ext }) catch continue) catch continue;
        const t = app.store.text(f);
        const row = ea.attackRow(who, at);
        // OpenGorky: the row's damage is the weapon's at battle entry (roster.prepareAttacks).
        const own_dmg = if (app.ogLayout()) if (row) |r| r.max_damage else 0 else 0;
        const dmg = if (own_dmg > 0) own_dmg else @as(i32, @intFromFloat(model.get(t, "max_damage") orelse 0));
        ws[n] = .{ .at = at, .text = t, .damage = dmg, .worth = if (scoring.occupant == .generic) (dmg + prof.damage_bonus.?) * attack else null };
        weaponCard(app, a, e, who, ws[n], row, own_dmg, @intCast(n), built);
        n += 1;
    }
    // A new weapon: an enemy weapon class given to it (a `give` row).
    if (list.len > 0 and !built and app.ogLayout()) {
        gui.fieldRow(tx.get(tx.attack_add));
        if (ea.attackRow(who, list[0]) != null) {
            const open = picker.field(app, clay.id("atk_add"), tx.get(tx.attack_add_pick), false);
            if (open) {
                const rows = ea.weaponClassRows(app, a);
                if (picker.list(app, a, rows)) |j| ea.addAttack(app, who, list[0], app.catalog.arena.allocator().dupe(u8, rows[j].key) catch return clay.close()) catch |err| app.failed(err);
            }
        }
        clay.close();
    }
    howItChooses(a, prof, scoring, attack, text, ws[0..n]);
}

/// Weapon `w` (card `k`): its page, the attack done with it, its damage, its AI worth;
/// show its strike or zone, change its class, take a given one back.
fn weaponCard(app: *App, a: Allocator, e: Entry, who: rules.Who, w: Weapon, row: ?rules.MonsterAttack, own_dmg: i32, k: u32, built: bool) void {
    const at = w.at;
    const long = (model.get(w.text, "long_attack") orelse 0) != 0;
    // Its title one line in a narrow panel: the class's behaviour is on its page.
    _ = gui.block(app, null, std.fmt.allocPrint(a, "{s} · {s}", .{ at.class, tx.get(if (long) tx.wp_long else tx.wp_short) }) catch at.class, .{ .inner = true });
    defer gui.blockEnd();
    // The weapon: edited on its page (›).
    gui.fieldRow(tx.get(tx.wa_weapon));
    gui.txtWrap(at.class, .label, theme.text, font_mod.regular);
    gui.spacer();
    if (entries.entryById(app, at.class)) |i| {
        if (gui.goButton(app, clay.idi("wpn_go", k))) entries.showEntry(app, i);
    } else |_| {}
    clay.close();
    // The attack done with it: its row in force, one line (edited on the weapon's page).
    gui.fieldRow(tx.get(tx.wa_attack));
    gui.txtWrap(if (row) |r| attackLine(a, r, at) else tx.get(tx.wa_hero_table), .body, theme.text, font_mod.regular);
    clay.close();
    // Damage: the class's (shared by every enemy holding it), or this one's own override.
    if (row != null and app.ogLayout()) {
        gui.fieldRow(tx.get(tx.wa_damage));
        var ib: [24]u8 = undefined;
        if (gui.textField(app, std.fmt.bufPrint(&ib, "atk_dmg{d}", .{k}) catch "atk_dmg", if (own_dmg > 0) std.fmt.allocPrint(a, "{d}", .{own_dmg}) catch "" else "", lay.width.number, app_mod.fmtNum(a, model.get(w.text, "max_damage")))) |t|
            ea.setAttack(app, who, at, "max_damage", if (std.mem.trim(u8, t, " ").len == 0) "0" else t) catch |err| @import("rules_rows.zig").failed(app, "max_damage", err);
        clay.close();
    }
    const users = holders(app, at.class);
    gui.fieldNote(if (own_dmg > 0) tx.alloc(a, tx.wa_dmg_own, .{ own_dmg, at.class, app_mod.fmtNum(a, model.get(w.text, "max_damage")) }) else if (app.ogLayout()) tx.alloc(a, tx.wa_dmg_class, .{ app_mod.fmtNum(a, model.get(w.text, "max_damage")), at.class, users }) else tx.alloc(a, tx.wa_dmg_class_classic, .{ app_mod.fmtNum(a, model.get(w.text, "max_damage")), at.class, users }), theme.dim);
    // What it is worth to the AI (best case, a foe at 100%).
    gui.fieldRow(tx.get(tx.wa_ai));
    gui.txtWrap(worthLine(a, w, row), .body, theme.text, font_mod.regular);
    clay.close();
    // Shown struck (OpenGorky) or its zone; its class swapped for every enemy of the
    // class (a held one: the `.wpn` includes); a given one taken back.
    const showing = app.enemy_strike != null and app.enemy_strike.? == k;
    const strike = app.ogLayout() and row != null and !built;
    const zone_open = app.reach_open != null and app.reach_open.? == k;
    var ib: [24]u8 = undefined;
    const fid = std.fmt.bufPrint(&ib, "wpn_acts{d}", .{k}) catch "wpn_acts";
    const key = clay.idi(fid, 1);
    const own = if (row) |r| !@import("rules_rows.zig").isBuiltin(rules.MonsterAttack, "monster_attacks", r) else false;
    const Act = enum { strike, zone, change, remove };
    var acts: [4]Act = undefined;
    var labels: [4][]const u8 = undefined;
    var n: usize = 0;
    for ([_]struct { Act, bool, []const u8 }{
        .{ .strike, strike, tx.get(if (showing) tx.attack_unshow else tx.attack_show) },
        .{ .zone, true, tx.get(if (zone_open) tx.reach_hide else tx.reach_show) },
        .{ .change, !at.given, ew.pickerLabel(app, key, tx.wp_change_class) },
        .{ .remove, app.ogLayout() and (at.given or own), tx.get(tx.attack_remove) },
    }) |b| if (b[1]) {
        acts[n] = b[0];
        labels[n] = b[2];
        n += 1;
    };
    if (gui.footer(app, fid, labels[0..n], null)) |b| switch (acts[b]) {
        .strike => app.enemy_strike = if (showing) null else k,
        .zone => app.reach_open = if (zone_open) null else k,
        .change => picker.toggle(app, key),
        .remove => ea.removeAttack(app, who, at) catch |err| app.failed(err),
    };
    if (zone_open) ew.reachMap(app, a, model.get(w.text, "class"), k + 1);
    // Its file name as the `.wpn` includes it (a held one: a wp_ script).
    const cur = std.fmt.allocPrint(a, "{s}.ss", .{at.class}) catch return;
    if (ew.weaponPicker(app, a, key, cur, long)) |new| {
        if (ew.swapClassWeapon(app, e.base orelse e.id, cur, new)) |c| app.setStatus(tx.st_weapon_class, .{ cur, new, c }) else |err| app.failed(err);
    }
    // Struck in the preview: its effect description, the fighter's own stages too.
    if (showing) if (ea.strikeShown(app, a, e, who)) |sh| @import("fxdesc.zig").section(app, a, null, sh.held.strike);
}

/// The enemies holding weapon class `class` in the battles.
fn holders(app: *App, class: []const u8) usize {
    var n: usize = 0;
    for (app.catalog.entries.items) |x| if (x.kind == .enemy) for (x.weapons.items) |w| {
        if (std.ascii.eqlIgnoreCase(rules.stem(w), class)) {
            n += 1;
            break;
        }
    };
    return n;
}

/// "short_attack · hit at 43 · 2nd hit +37 · given"
fn attackLine(a: Allocator, r: rules.MonsterAttack, at: ea.Attack) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, tx.alloc(a, tx.wa_hit_at, .{ r.anim, r.hit_delay.ticks() })) catch {};
    if (r.second_delay.ticks() > 0) out.appendSlice(a, tx.alloc(a, tx.wa_second, .{r.second_delay.ticks()})) catch {};
    const special = og.core.entity.refId(r.strike, r.strike_class);
    if (special != 0) out.appendSlice(a, tx.alloc(a, tx.wa_special, .{special})) catch {};
    if (at.given) out.appendSlice(a, tx.get(tx.wa_given)) catch {};
    return out.items;
}

/// "worth (25 + 5) × 10 = 300 per foe at 100% · range 4 · recharge 2 turns"
fn worthLine(a: Allocator, w: Weapon, row: ?rules.MonsterAttack) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, if (w.worth) |v| tx.alloc(a, tx.wa_worth, .{v}) else tx.get(tx.wa_worth_eval)) catch {};
    const range = if (row) |r| r.range else 0;
    if (range > 0) out.appendSlice(a, tx.alloc(a, tx.wa_range, .{range})) catch {};
    const rt = recharge(w, row);
    if (rt > 0) out.appendSlice(a, tx.alloc(a, tx.wa_recharge, .{rt})) catch {};
    return out.items;
}

/// Turns out after a shot: the row's (OpenGorky), else its class's (combat/weapons.zig).
fn recharge(w: Weapon, row: ?rules.MonsterAttack) i32 {
    if (row) |r| if (r.recharge_turns > 0) return r.recharge_turns;
    return og.battle.rules.rechargeTurns(@intFromFloat(model.get(w.text, "class") orelse 0));
}

/// The "How the AI chooses" lines: combat/ai.zig's tile score in words, with this
/// character's numbers (AI profile in force over its aic* fields) and its best weapon.
fn howItChooses(a: Allocator, prof: rules.AiProfile, scoring: *const og.core.behaviour.Scoring, attack: i32, text: []const u8, ws: []const Weapon) void {
    const f = struct {
        fn f(p: ?i32, t: []const u8, n: []const u8) i32 {
            return p orelse @as(i32, @intFromFloat(model.get(t, n) orelse 0));
        }
    }.f;
    const defense = f(prof.threat_weight, text, "ai_threat_weight");
    const dist = f(prof.opponent_distance_weight, text, "ai_opponent_distance_weight");
    const mode = f(prof.mode, text, "ai_mode");
    gui.subhead(tx.get(tx.ai_how));
    if (mode == 2) return gui.note(tx.get(tx.ai_how_skip));
    const lines = [_]?[]const u8{
        if (scoring.occupant == .generic) tx.alloc(a, tx.ai_how_try, .{ prof.damage_bonus.?, attack, prof.ally_penalty.? }) else tx.alloc(a, tx.ai_how_try_eval, .{prof.scoring.?}),
        tx.alloc(a, tx.ai_how_place, .{ if (prof.threat.?) tx.alloc(a, tx.ai_how_danger, .{defense}) else tx.get(tx.ai_how_no_danger), dist, if (prof.step_away.?) tx.get(tx.ai_how_away) else "" }),
        tx.get(tx.ai_how_one),
        if (mode == 1) tx.get(tx.ai_how_lock) else if (mode == 3) tx.get(tx.ai_how_guard) else null,
        switch (scoring.keep) {
            .all => null,
            .by_health => tx.get(tx.ai_how_by_health),
            .first => tx.get(tx.ai_how_first),
            .free_arms => tx.get(tx.ai_how_free_arms),
        },
        best(a, ws),
        tx.get(tx.ai_how_limits),
    };
    for (lines) |l| if (l) |s| gui.txtWrap(s, .caption, theme.text, font_mod.regular);
}

/// "Best case: wp_hornet (450) whenever a foe is in its reach; …" (two weapons or more).
fn best(a: Allocator, ws: []const Weapon) ?[]const u8 {
    if (ws.len < 2) return null;
    var top: ?Weapon = null;
    for (ws) |w| if (w.worth) |v| {
        if (top == null or v > top.?.worth.?) top = w;
    };
    const t = top orelse return null;
    return tx.alloc(a, tx.ai_how_best, .{ t.at.class, t.worth.? });
}
