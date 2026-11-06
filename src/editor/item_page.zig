//! A weapon's, an ammo's, an item's and an enemy attack's constructor blocks
//! (entries.zig draws the page around them): the look (the model and textures picked,
//! edited on their pages), damage or the properties, the hero's strike, an attack's
//! enemies' strikes, effects, an attack's spins, a medicine's rules and the unused
//! fields; an item's inventory stage.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const c = @import("sdl");
const clay = @import("clay.zig");
const lay = @import("layout.zig");
const gui = @import("widgets.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const entry_rules = @import("entry_rules.zig");
const entry_attacks = @import("entry_attacks.zig");
const entry_tables = @import("entry_tables.zig");
const picker = @import("picker.zig");
const entries = @import("entries.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

const choiceRow = entries.choiceRow;
const fileOf = entries.fileOf;
const setString = entries.setString;

/// Item fields with a label; others show their script name.
const field_labels = [_]struct { []const u8, tx.Msg }{
    .{ "max_damage", tx.f_damage },     .{ "light_armor_pct", tx.f_light }, .{ "medium_armor_pct", tx.f_medium },
    .{ "heavy_armor_pct", tx.f_heavy }, .{ "bonus_experience", tx.f_exp },  .{ "ammo", tx.f_ammo },
    .{ "count", tx.f_count },           .{ "class", tx.f_class },           .{ "hp", tx.p_hp },
    .{ "armor", tx.p_armor },           .{ "resist_fire", tx.p_fire },      .{ "resist_electricity", tx.p_elect },
    .{ "resist_decoy", tx.p_dist },     .{ "resist_energy", tx.p_energy },  .{ "resist_freeze", tx.p_freeze },
    .{ "resist_sleep", tx.p_tranq },    .{ "resist_gas", tx.p_gas },
};
/// Item fields not shown as numbers (identity, placement, or picked from a list).
pub const hidden = [_][]const u8{ "classic_id", "action", "place", "kind", "damage_kind", "class", "ammo", "recharge" };

const WeaponClass = og.battle.weapon_class.WeaponClass;
/// The engine's weapon classes: values and names.
const class_tags = @typeInfo(WeaponClass).@"enum".field_names;
pub const class_values = blk: {
    const vs = @typeInfo(WeaponClass).@"enum".field_values;
    var out: [vs.len]i32 = undefined;
    for (vs, 0..) |x, i| out[i] = x;
    break :blk out;
};

/// Names of the player's weapon classes (1–24); monster ones show their engine name.
const class_names = [_]tx.Msg{
    tx.w_pistol,    tx.w_rifle, tx.w_dartgun,  tx.w_flame,  tx.w_rocket,   tx.w_ion,     tx.w_blaster, tx.w_satellite,
    tx.w_time_bomb, tx.w_melee, tx.w_grenade,  tx.w_knife,  tx.w_chaingun, tx.w_shotgun, tx.w_molotov, tx.w_napalm,
    tx.w_barrel,    tx.w_decoy, tx.w_nitrogen, tx.w_bottle, tx.w_matches,  tx.w_stun,    tx.w_gas,     tx.w_shocker,
};

pub fn classLabel(a: Allocator, v: ?f32) []const u8 {
    const n: i32 = @intFromFloat(v orelse return "—");
    if (n >= 1 and n <= class_names.len) return tx.alloc(a, tx.w_class_fmt, .{ n, tx.get(class_names[@intCast(n - 1)]) });
    for (class_values, class_tags) |cv, t| if (cv == n) return tx.alloc(a, tx.w_class_fmt, .{ n, t });
    return std.fmt.allocPrint(a, "{d}", .{n}) catch "?";
}

/// An OpenGorky weapon's class as its block writes it: the name (`pistol · Pistol`).
fn classWord(a: Allocator, v: ?f32) []const u8 {
    const n: i32 = @intFromFloat(v orelse return "—");
    const name = og.rules.weaponClassName(n) orelse return std.fmt.allocPrint(a, "{d}", .{n}) catch "?";
    if (n >= 1 and n <= class_names.len) return tx.alloc(a, tx.w_class_word, .{ name, tx.get(class_names[@intCast(n - 1)]) });
    return name;
}

/// Ammo item classes with their classic_id (what `ammo` names).
const Ammo = struct { id: i32, title: []const u8 };

fn ammoClasses(app: *App, a: Allocator) []const Ammo {
    var out: std.ArrayList(Ammo) = .empty;
    for (app.catalog.entries.items) |e| {
        if (e.kind != .ammo) continue;
        const f = fileOf(app, e) orelse continue;
        const id = model.get(app.store.text(f), "classic_id") orelse continue;
        out.append(a, .{ .id = @intFromFloat(id), .title = if (e.title.len > 0) e.title else e.id }) catch {};
    }
    return out.items;
}

fn ammoLabel(app: *App, a: Allocator, v: ?f32) []const u8 {
    const n: i32 = @intFromFloat(v orelse 0);
    if (n == 0) return tx.get(tx.a_none);
    if (n == -1) return tx.get(tx.a_self);
    for (ammoClasses(app, a)) |x| if (x.id == n) return x.title;
    return std.fmt.allocPrint(a, "{d}", .{n}) catch "?";
}

/// Weapon `type` (damage kind, battle/immunity.zig).
const damage_types = [_]struct { i32, tx.Msg }{
    .{ 1, tx.d_fire },  .{ 2, tx.d_freeze },  .{ 3, tx.d_electricity }, .{ 4, tx.d_teargas },    .{ 5, tx.d_gas },        .{ 6, tx.d_bullet }, .{ 7, tx.d_melee },
    .{ 9, tx.d_tranq }, .{ 11, tx.d_energy }, .{ 12, tx.d_attract },    .{ 13, tx.d_explosion }, .{ 14, tx.d_flammable },
};

/// An attack's spins: its first enemy's (`enemy`) strike (`special`) in animation slot `slot`.
const Spins = struct { special: i32, enemy: usize, slot: []const u8 };

/// The blocks of entry `idx` (not a fighter): `name_id` its classic_id, `fx` the strike in the
/// preview (a weapon's hero, an attack's enemy), `spins` an attack's.
pub fn props(app: *App, a: Allocator, idx: usize, file: usize, text: []const u8, name_id: i32, fx: ?@import("preview_fx.zig").Strike, spins: ?Spins) void {
    const e = app.catalog.entries.items[idx];
    const icon_shown = e.kind != .attack or model.getStr(text, "icon") != null;
    // Its identity in the rules (OpenGorky: by its class).
    const weapon_who: og.rules.Who = .{ .id = name_id, .class = if (app.ogLayout()) entry_rules.classOf(e) else "" };
    const mesh = model.getStr(text, "mesh");
    // Most enemy attacks have no icon or model (the human enemies' guns do).
    if ((icon_shown or e.kind == .weapon or mesh != null) and gui.block(app, "look", tx.get(tx.sec_look), .{})) {
        if (icon_shown) {
            if (choiceRow(app, 0, tx.get(tx.c_icon), model.getStr(text, "icon") orelse "—")) if (picker.listKey(app, a, entries.iconRows(app, a))) |v| setString(app, file, "icon", v) catch |err| app.failed(err);
            entries.artButtons(app, idx, &.{ .{ tx.b_icon_png, .png, entries.onIconIn }, .{ tx.b_export_icon, .png_out, entries.onIconOut } }, model.getStr(text, "icon"));
        }
        if (e.kind == .weapon) entry_tables.skillIconRow(app, idx, weapon_who);
        // The model and its textures picked, each edited on its page.
        if (mesh) |m| @import("char_page.zig").modelSlots(app, a, idx, m, file, true) else if (e.kind == .weapon) entries.meshRow(app, a, tx.c_mesh, file, null);
        gui.blockEnd();
    }
    const names = model.ownNumbers(app, a, file);
    const strikes = e.kind == .weapon or e.kind == .attack;
    if (gui.block(app, if (strikes) "damage" else "props", tx.get(if (strikes) tx.sec_damage else tx.sec_props), .{})) {
        if (strikes) {
            if (choiceRow(app, 3, tx.get(tx.c_damage), damageLabel(model.get(text, "damage_kind")))) dmg: {
                const rows = a.alloc(picker.Opt, damage_types.len) catch break :dmg;
                for (damage_types, rows) |d, *o| o.* = .{ .key = std.fmt.allocPrint(a, "{d}", .{d[0]}) catch "", .label = tx.get(d[1]) };
                if (picker.listKey(app, a, rows)) |v| model.set(app, file, &.{"damage_kind"}, v, "{") catch |err| app.failed(err);
            }
            // OpenGorky: the class by its name (`class = pistol`), the rules' classes.
            const words = app.ogLayout();
            const label: *const fn (Allocator, ?f32) []const u8 = if (words) &classWord else &classLabel;
            if (choiceRow(app, 4, tx.get(tx.f_class), label(a, model.get(text, "class")))) cls: {
                var rows: std.ArrayList(picker.Opt) = .empty;
                if (words) {
                    for (og.rules.active.patterns) |p| if (p.name.len > 0) rows.append(a, .{ .key = p.name, .label = classWord(a, @floatFromInt(p.classic_id)) }) catch break :cls;
                } else for (class_values) |v| rows.append(a, .{ .key = std.fmt.allocPrint(a, "{d}", .{v}) catch "", .label = classLabel(a, @floatFromInt(v)) }) catch break :cls;
                if (picker.listKey(app, a, rows.items)) |v| model.set(app, file, &.{"class"}, v, "{") catch |err| app.failed(err);
            }
            if (e.kind == .weapon and choiceRow(app, 5, tx.get(tx.f_ammo), ammoLabel(app, a, model.get(text, "ammo")))) {
                var rows: std.ArrayList(picker.Opt) = .empty;
                rows.appendSlice(a, &.{ .{ .key = "0", .label = tx.get(tx.a_none) }, .{ .key = "-1", .label = tx.get(tx.a_self) } }) catch {};
                for (ammoClasses(app, a)) |x| rows.append(a, .{ .key = std.fmt.allocPrint(a, "{d}", .{x.id}) catch continue, .label = std.fmt.allocPrint(a, "{s} ({d})", .{ x.title, x.id }) catch x.title }) catch {};
                if (picker.listKey(app, a, rows.items)) |v| model.set(app, file, &.{"ammo"}, v, "{") catch |err| app.failed(err);
            }
            // The hero's strike animation: the weapon's own field (OpenGorky); the exe
            // strikes by classic_id (a new one: attack_rifle, 0x48bda2).
            if (e.kind == .weapon and app.ogLayout()) {
                gui.fieldRow(tx.get(tx.c_attack_anim));
                if (picker.field(app, clay.idi("choice", 6), model.getStr(text, "attack_anim") orelse tx.get(tx.anim_strike_own), false)) if (picker.listKey(app, a, strikeAnims(app, a, file))) |v| strikeAnim(app, file, v) catch |err| app.failed(err);
                clay.close();
            }
            // OpenGorky: its class's row edited (every weapon of the class).
            if (!app.ogLayout()) rechargeRow(a, text);
            entry_tables.classRows(app, a, text);
        }
        // An attack's effects_from: its own row (OpenGorky) below.
        var shown: std.ArrayList([]const u8) = .empty;
        for (names) |n| if (!(isHidden(n) or unused(n) or (e.kind == .attack and std.ascii.eqlIgnoreCase(n, "effects_from")))) shown.append(a, n) catch {};
        @import("inspector.zig").fields(app, a, 2000, file, shown.items, labelOf, .{ .after = "{" });
        gui.blockEnd();
    }
    if (e.kind == .weapon) entry_tables.strikeSection(app, a, weapon_who, text);
    // An enemy weapon class: each enemy's strike with it (MonsterAttack rows).
    if (e.kind == .attack) entry_attacks.strikesSection(app, a, og.rules.stem(e.entry));
    if (strikes and gui.block(app, "effects", tx.get(tx.sec_effects), .{})) {
        if (!app.ogLayout()) effectRow(a, text);
        if (e.kind == .weapon) flashRows(app, a, text);
        entry_attacks.effectsRows(app, a, file, idx);
        if (e.kind == .weapon) entry_tables.flagRows(app, weapon_who);
        if (e.kind == .weapon or e.kind == .attack) @import("fxdesc.zig").section(app, a, entry_rules.classOf(e), fx);
        // An attack: its enemy's own strike spins (FighterStrike); the port's fx_as (the
        // strike's flash, projectile and hit of another weapon classic_id, battle/generic.zig;
        // the exe ignores it).
        if (spins) |sp| if (sp.special != 0) entry_attacks.spinSummary(app, a, sp.special, sp.enemy, sp.slot);
        if (e.kind == .attack and app.ogLayout()) {
            // A number, or a weapon archetype (`~w"weapons::x"`): its classic_id.
            const as_id: i32 = if (model.get(text, "effects_from")) |v| @intFromFloat(v) else if (model.field(app, file, "effects_from").og_expr) |x| og.core.entity.idOf(og.core.schema.text(x) orelse "") orelse 0 else 0;
            const as_now = std.fmt.allocPrint(a, "{d}", .{as_id}) catch "0";
            const as_pick = entry_attacks.gameWeapon(null, false);
            gui.fieldRow(tx.get(tx.wp_fx_as));
            const open = picker.field(app, clay.idi("choice", 11), as_pick.label(app, a, as_now), false);
            clay.close();
            if (open) if (picker.listKey(app, a, as_pick.rows(app, a, as_now))) |v| model.set(app, file, &.{"effects_from"}, v, "max_damage") catch |err| app.failed(err);
        }
        gui.blockEnd();
    }
    // Beside the description, the preview in sight.
    if (strikes and e.kind == .weapon) @import("fxmaterial.zig").block(app, a);
    if (e.kind == .item and model.get(text, "kind") == 20) entry_tables.medicineSection(app, a, weapon_who);
    // Fields the classes fill but no battle code reads, the exe's (effect_time,
    // effect_power: burning and poison are 3 turns, 15/10/5, 0x4900f0/0x4903d0) nor ours.
    var n_unused: usize = 0;
    for (names) |n| n_unused += @intFromBool(unused(n));
    if (n_unused > 0 and gui.block(app, "unused", tx.get(tx.unused_title), .{ .folded = true, .summary = std.fmt.allocPrint(a, "{d}", .{n_unused}) catch "" })) {
        gui.note(tx.get(tx.unused_hint));
        for (names) |n| {
            if (!unused(n)) continue;
            gui.fieldRow(n);
            gui.txt(app_mod.fmtNum(a, model.get(text, n)), .label, theme.dim, font_mod.regular);
            clay.close();
        }
        gui.blockEnd();
    }
}

/// Turns to recharge after a strike: set by the weapon's class in the exe.
fn rechargeRow(a: Allocator, text: []const u8) void {
    const n = og.battle.rules.rechargeTurns(@intFromFloat(model.get(text, "class") orelse 0));
    gui.fieldRow(tx.get(tx.f_recharge));
    gui.txt(std.fmt.allocPrint(a, "{d}", .{n}) catch "?", .label, theme.dim, font_mod.regular);
    gui.txtWrap(tx.get(tx.f_recharge_class), .caption, theme.dim, font_mod.regular);
    clay.close();
}

/// Declared in Weapon.s and filled in the classes, read by neither the exe nor the port.
const unused_fields = [_][]const u8{ "effect_time", "effect_power", "blast_radius", "range", "max_range", "min_damage", "accuracy_bonus", "range_effect", "dist_effect", "near_effect", "move_penalty" };

fn unused(n: []const u8) bool {
    for (unused_fields) |u| if (std.ascii.eqlIgnoreCase(u, n)) return true;
    return false;
}

fn isHidden(n: []const u8) bool {
    for (hidden) |h| if (std.ascii.eqlIgnoreCase(h, n)) return true;
    return false;
}

fn labelOf(n: []const u8) []const u8 {
    for (field_labels) |l| if (std.ascii.eqlIgnoreCase(l[0], n)) return tx.get(l[1]);
    return n;
}

/// State the weapon's class applies by itself (the exe's, rules.weaponEffect).
fn classEffect(text: []const u8) ?tx.Msg {
    const cls = model.get(text, "class") orelse return null;
    const e = og.battle.rules.weaponEffect(@intFromFloat(cls)) orelse return null;
    return switch (e) {
        .burn => tx.e_burn,
        .freeze => tx.e_freeze,
        .gas, .bite => tx.e_poison,
        .soak => tx.e_soak,
        .sleep => tx.e_sleep,
        .defend => null,
    };
}

/// Effect on hit: set by the weapon's class in the exe.
fn effectRow(a: Allocator, text: []const u8) void {
    gui.fieldRow(tx.get(tx.c_effect));
    // Wrapped: "by its class: soaks with fuel" ran past a narrow panel's edge.
    gui.txtWrap(if (classEffect(text)) |m| tx.alloc(a, tx.e_class, .{tx.get(m)}) else "—", .body, theme.dim, font_mod.regular);
    clay.close();
}

/// The shot's muzzle flash: where and how the exe attaches it is its built-in effect
/// description by the weapon's classic_id (0x48bda2…0x48ce33, core/effect.zig) — shown as is;
/// the effect itself (its frames, `.dsc`) is data: edited on its page.
fn flashRows(app: *App, a: Allocator, text: []const u8) void {
    const id: i32 = @intFromFloat(model.get(text, "classic_id") orelse return);
    gui.fieldRow(tx.get(tx.c_flash));
    const f = og.fx.hits.flashFor(id, 0) orelse {
        gui.txt(tx.get(tx.flash_none), .body, theme.dim, font_mod.regular);
        return clay.close();
    };
    gui.txtWrap(tx.alloc(a, tx.flash_of, .{ f.effect, f.link, f.ticks.ticks() }), .body, theme.text, font_mod.regular);
    clay.close();
    gui.fieldNote(tx.alloc(a, tx.flash_note, .{ f.offset[0], f.offset[1], f.offset[2], f.scale }), theme.dim);
    gui.valueLine();
    if (gui.smallButton(app, clay.id("flash_edit"), tx.get(tx.flash_edit))) {
        @import("doctabs.zig").openKept(app, .effects, f.effect);
    }
    clay.close();
}

pub fn damageLabel(v: ?f32) []const u8 {
    const t: i32 = @intFromFloat(v orelse return "—");
    for (damage_types) |d| if (d[0] == t) return tx.get(d[1]);
    return "?";
}

/// The hero strikes' animations in force, then the weapons (but `file`'s) whose strike
/// to fork (strikeAnim).
fn strikeAnims(app: *App, a: Allocator, file: usize) []picker.Opt {
    var out: std.ArrayList(picker.Opt) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (og.rules.active.hero_attacks) |r| if (!(seen.getOrPut(a, r.anim) catch continue).found_existing) out.append(a, .{ .key = r.anim, .label = r.anim }) catch {};
    for (app.catalog.entries.items, 0..) |e, k| if (e.kind == .weapon and e.name_id != null and fileOf(app, e) != file) {
        out.append(a, .{ .key = std.fmt.allocPrint(a, "fork:{d}", .{k}) catch continue, .label = tx.alloc(a, tx.anim_fork, .{if (e.title.len > 0) e.title else e.id}) }) catch {};
    };
    return out.items;
}

/// The weapon of `file`'s strike: animation `value` (its `attack_anim`), or `fork:<entry>`:
/// that weapon's strike rows (animation, timing, flash, sound) made this one's by its class.
fn strikeAnim(app: *App, file: usize, value: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    if (!std.mem.startsWith(u8, value, "fork:")) return setString(app, file, "attack_anim", value);
    const from = app.catalog.entries.items[try std.fmt.parseInt(usize, value[5..], 10)];
    const to = og.rules.stem(app.store.files.items[file].entry);
    const id: i32 = @intFromFloat(model.get(app.store.text(file), "classic_id") orelse 0);
    try entry_rules.writeOwn(app, .{ .id = from.name_id orelse 0, .class = entry_rules.classOf(from) }, .{ .id = id, .class = to }, false);
    app.setStatus(tx.st_strike_forked, .{ from.id, to });
}

/// An item on the stage as the inventory shows it: its icon in one inventory cell
/// (whole pixels).
pub fn inventoryStage(app: *App, icon: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.space.xs, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
    const t = app.icon(icon);
    var w: f32 = 32;
    var h: f32 = 32;
    if (t) |tt| _ = c.SDL_GetTextureSize(tt, &w, &h);
    // One cell about a slider's width, up to 3×.
    const k = @max(1, @floor(@min(3, lay.width.slider / @max(1, @max(w, h)))));
    const cell = @max(w, h) * k + 2 * lay.space.xs;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(cell), .height = clay.fixed(cell) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(lay.radius.md), .border = .{ .color = theme.line, .width = .{ .left = lay.border.line, .right = lay.border.line, .top = lay.border.line, .bottom = lay.border.line } } });
    if (t) |tt| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w * k), .height = clay.fixed(h * k) } }, .image = .{ .imageData = tt } });
    clay.close();
    gui.txt(tx.get(tx.inv_stage), .caption, theme.dim, font_mod.regular);
    clay.close();
}
