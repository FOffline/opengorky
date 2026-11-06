//! A weapon's effect description on its page (OpenGorky; core/effect.zig `Weapon`, the
//! records the strike's stages name): per stage its parts — added from a template,
//! removed, moved, each field typed as the rules files write it — and the launch's
//! fields; every edit writes the record's `WeaponFx` row into rules\fx.ss (one undo
//! step) and the preview strikes with it at once. Under the preview a timeline: a track
//! per part from its delay over its life (core/effect.zig `span`), the strike's frames
//! marked, a click shows that frame. An enemy's attack card (its strike shown) has the
//! same editor with its own stages too (`FighterFx`, by its classic_id and the weapon); a
//! record starts from a built-in one copied; a part's tracks are graphed over its life.
//! Classic: locked (the exe keeps them in its code).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const entry_attacks = @import("entry_attacks.zig");
const entry_rules = @import("entry_rules.zig");
const rules_rows = @import("rules_rows.zig");
const picker = @import("picker.zig");
const fx_ = @import("preview_fx.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const desc = og.core.effect;
const codec = og.loaders.codec;
const Track = og.effects.beam.Track;

/// A description's stages, in the order a strike runs them (the hit's three at its
/// landing), then the striker's own (FighterFx: its pre in place of the weapon's, its hit
/// with the weapon's, a series' second hit).
pub const Stage = enum { pre, launch, shot, flash, hit, own_pre, own_hit, second };
const stage_names = [_][]const u8{ "pre", "launch", "shot", "flash", "hit", "own pre", "own hit", "second" };
/// The weapon's stages (WeaponFx) before the striker's own.
const n_weapon = 5;

/// The weapon record a stage of strike `fx` runs (the own ones: the weapon their record
/// goes with): pre, shot and flash by its flash id.
fn idOf(fx: og.battle.generic.Fx, st: Stage) i32 {
    return switch (st) {
        .pre, .shot, .flash, .own_pre => fx.flash,
        .launch => fx.launch,
        .hit, .own_hit, .second => fx.hit,
    };
}

/// The record field of a stage's parts ("": the launch, not parts).
fn field(comptime st: Stage) []const u8 {
    return switch (st) {
        .launch => "",
        .own_pre => "pre",
        .own_hit => "hit",
        else => @tagName(st),
    };
}

/// The record a stage edits: a weapon's (WeaponFx) or the striker's own (FighterFx).
const Rec = union(enum) {
    weapon: desc.Weapon,
    fighter: desc.Fighter,

    fn parts(r: Rec, st: Stage) []const desc.Part {
        return switch (r) {
            inline else => |x| switch (st) {
                inline else => |s| if (comptime @hasField(@TypeOf(x), field(s))) @field(x, field(s)) else &.{},
            },
        };
    }

    fn with(r: Rec, st: Stage, ps: []const desc.Part) Rec {
        var out = r;
        switch (out) {
            inline else => |*x| switch (st) {
                inline else => |s| if (comptime @hasField(@TypeOf(x.*), field(s))) {
                    @field(x, field(s)) = ps;
                } else unreachable,
            },
        }
        return out;
    }

    fn id(r: Rec) i32 {
        return switch (r) {
            .weapon => |w| w.id,
            .fighter => |f| f.fighter,
        };
    }
};

/// The record stage `st` of strike `s` edits (null: none — no id, no own effects).
fn recordOf(s: fx_.Strike, st: Stage) ?Rec {
    const id = idOf(s.fx, st);
    if (@backingInt(st) < n_weapon) return if (id <= 0) null else .{ .weapon = record(id, s.hero) };
    if (s.fx.special <= 0) return null;
    return .{ .fighter = ownRecord(s.fx.special, id) };
}

/// Fighter `fighter`'s own record in force with weapon `weapon` (none yet: an empty one for it).
fn ownRecord(fighter: i32, weapon: i32) desc.Fighter {
    return if (og.core.modules.fighterFx(fighter, weapon)) |r| r.* else .{ .fighter = fighter, .weapon = weapon };
}

/// The record in force for `id` struck by `hero` (none yet: an empty one of that id).
fn record(id: i32, hero: i32) desc.Weapon {
    return if (og.core.modules.weaponFx(id, hero)) |r| r.* else .{ .id = id };
}

/// Record `w` with stage `st` made `parts`, written as its row; the preview strikes anew.
fn putParts(app: *App, w: Rec, st: Stage, parts: []const desc.Part) !void {
    try put(app, w.with(st, parts));
}

fn put(app: *App, r: Rec) !void {
    switch (r) {
        inline else => |x| try rules_rows.put(app, @TypeOf(x), x),
    }
    restrike(app);
    app.setStatus(tx.st_fx_set, .{r.id()});
}

/// The preview's strike made again from the rules in force (an edit not saved yet).
fn restrike(app: *App) void {
    if (app.preview.sim) |sm| sm.destroy();
    app.preview.sim = null;
}

/// The "Description" part of a weapon's Effects block: the strike `s`'s records by stage.
/// `class` null: an enemy's attack card (no new record; the striker's own stages too).
pub fn section(app: *App, a: Allocator, class: ?[]const u8, s: ?fx_.Strike) void {
    const title = tx.get(if (class == null) tx.fxd_own_title else tx.fxd_title);
    if (!app.ogLayout()) return;
    gui.subhead(title);
    if (class) |cls| if (gui.footer(app, "fxd_new", &.{tx.get(tx.fxd_new)}, null) != null) {
        _ = newRecord(app, cls) catch |err| app.failed(err);
    };
    const strike = s orelse return;
    const n_st: usize = if (class == null) stage_names.len else n_weapon;
    const st: Stage = @fromBackingInt(@intCast(@min(app.fx_stage, n_st - 1)));
    const at = @backingInt(st);
    if (gui.segmented(app, "fxd_stage", stage_names[0..n_weapon], at)) |k| {
        app.fx_stage = @intCast(k);
        app.fx_part = null;
    }
    if (class == null) if (gui.segmented(app, "fxd_own", stage_names[n_weapon..], at -% n_weapon)) |k| {
        app.fx_stage = @intCast(n_weapon + k);
        app.fx_part = null;
    };
    const w = recordOf(strike, st) orelse return gui.note(tx.get(tx.fxd_none));
    switch (w) {
        .weapon => |r| gui.note(tx.alloc(a, tx.fxd_record, .{ r.id, @tagName(st) })),
        .fighter => |r| gui.note(tx.alloc(a, tx.fxd_own_record, .{ r.fighter, r.weapon, @tagName(st) })),
    }
    copyRows(app, a, w);
    if (st == .launch) return launchRows(app, a, w.weapon);
    const parts = w.parts(st);
    for (parts, 0..) |p, k| {
        const sel = app.fx_part == k;
        if (gui.listRow(app, clay.idi("fxd_part", @intCast(k)), .{ .selected = sel, .h = lay.height.small, .rounded = false, .bg = theme.bg })) app.fx_part = if (sel) null else k;
        gui.txt(@tagName(p), .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.txtClip(summary(a, p), .caption, theme.dim, font_mod.regular);
        clay.close();
    }
    if (parts.len == 0) gui.note(tx.get(tx.fxd_empty));
    // A new part from a template.
    gui.fieldRow(tx.get(tx.fxd_add));
    const open = picker.field(app, clay.id("fxd_add"), tx.get(tx.fxd_add_pick), false);
    clay.close();
    if (open) add: {
        const rows = a.alloc(picker.Opt, desc.templates.len) catch return;
        for (desc.templates, rows) |t, *o| o.* = .{ .label = @tagName(t) };
        const j = picker.list(app, a, rows) orelse break :add;
        const out = std.mem.concat(a, desc.Part, &.{ parts, &.{desc.templates[j]} }) catch return;
        putParts(app, w, st, out) catch |err| return app.failed(err);
        app.fx_part = parts.len;
    }
    const k = app.fx_part orelse return;
    if (k >= parts.len) return;
    gui.subhead(tx.alloc(a, tx.fxd_part, .{ k + 1, @tagName(parts[k]) }));
    partFields(app, a, w, st, parts, k);
    if (@import("fxmaterial.zig").materialRow(app, a, parts[k])) |np| {
        const out = a.dupe(desc.Part, parts) catch return;
        out[k] = np;
        putParts(app, w, st, out) catch |err| app.failed(err);
    }
    const labels = [_][]const u8{ tx.get(tx.fxd_up), tx.get(tx.fxd_down), tx.get(tx.fxd_remove) };
    if (gui.footer(app, "fxd_ops", &labels, null)) |b| {
        const out = a.dupe(desc.Part, parts) catch return;
        switch (b) {
            0 => if (k > 0) {
                std.mem.swap(desc.Part, &out[k], &out[k - 1]);
                app.fx_part = k - 1;
            },
            1 => if (k + 1 < out.len) {
                std.mem.swap(desc.Part, &out[k], &out[k + 1]);
                app.fx_part = k + 1;
            },
            else => app.fx_part = null,
        }
        const kept = if (b == 2) std.mem.concat(a, desc.Part, &.{ out[0..k], out[k + 1 ..] }) catch return else out;
        putParts(app, w, st, kept) catch |err| app.failed(err);
    }
}

/// A part's fields as the rules files write it, cut short (the list's second line).
fn summary(a: Allocator, p: desc.Part) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    codec.writeValue(desc.Part, &aw.writer, p) catch return "";
    const t = aw.written();
    const open = (std.mem.indexOfScalar(u8, t, '(') orelse return t) + 1;
    return t[open..@min(t.len, open + 48)];
}

/// A value's text field: `v` as the rules write it; the typed text read back (a bare
/// word for a string or a name is quoted).
pub fn valueField(app: *App, a: Allocator, comptime T: type, key: []const u8, v: T) ?T {
    var aw: std.Io.Writer.Allocating = .init(a);
    codec.writeValue(T, &aw.writer, v) catch return null;
    const typed = gui.textField(app, key, aw.written(), 0, "—") orelse return null;
    const U = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    const t = std.mem.trim(u8, typed, " ");
    const quote = (U == []const u8 or @typeInfo(U) == .@"enum") and !std.mem.startsWith(u8, t, "\"");
    const src = if (quote) std.fmt.allocPrint(a, "\"{s}\"", .{t}) catch return null else t;
    // An optional left empty: none.
    if (@typeInfo(T) == .optional and t.len == 0) return @as(T, null);
    return codec.readText(T, a, src, &app.rule_why) catch |err| {
        rules_rows.failed(app, key, err);
        return null;
    };
}

/// Part `k`'s fields, each written back into the stage on its own; its tracks graphed.
fn partFields(app: *App, a: Allocator, w: Rec, st: Stage, parts: []const desc.Part, k: usize) void {
    const life = lifeOf(parts[k]);
    switch (parts[k]) {
        inline else => |v, tag| {
            const T = @TypeOf(v);
            const got: ?T = if (@typeInfo(T) == .@"struct") blk: {
                var out: ?T = null;
                inline for (@typeInfo(T).@"struct".field_names) |f| {
                    gui.fieldRow(f);
                    if (valueField(app, a, @FieldType(T, f), "fxd_f_" ++ f, @field(v, f))) |x| {
                        var nv = v;
                        @field(nv, f) = x;
                        out = nv;
                    }
                    clay.close();
                    graphs(a, @FieldType(T, f), @field(v, f), f, life, 1);
                }
                break :blk out;
            } else blk: {
                gui.fieldRow(@tagName(tag));
                defer clay.close();
                break :blk valueField(app, a, T, "fxd_f_" ++ @tagName(tag), v);
            };
            if (got) |nv| {
                const out = a.dupe(desc.Part, parts) catch return;
                out[k] = @unionInit(desc.Part, @tagName(tag), nv);
                putParts(app, w, st, out) catch |err| app.failed(err);
            }
        },
    }
}

/// The launch's fields (a projectile), or a new one.
fn launchRows(app: *App, a: Allocator, w: desc.Weapon) void {
    const l = w.launch orelse {
        gui.note(tx.get(tx.fxd_no_launch));
        if (gui.footer(app, "fxd_launch_new", &.{tx.get(tx.fxd_launch_add)}, null) != null) {
            var r = w;
            r.launch = .{ .pr = .{ .pos = @splat(0), .start = @splat(0), .target = @splat(0), .effect = "flare1" } };
            put(app, .{ .weapon = r }) catch |err| app.failed(err);
        }
        return;
    };
    var got: ?desc.Launch = null;
    inline for (@typeInfo(desc.Launch).@"struct".field_names) |f| {
        gui.fieldRow(f);
        if (valueField(app, a, @FieldType(desc.Launch, f), "fxd_l_" ++ f, @field(l, f))) |x| {
            var nl = l;
            @field(nl, f) = x;
            got = nl;
        }
        clay.close();
    }
    if (gui.footer(app, "fxd_launch_ops", &.{tx.get(tx.fxd_remove)}, null) != null) {
        var r = w;
        r.launch = null;
        return put(app, .{ .weapon = r }) catch |err| app.failed(err);
    }
    if (got) |nl| {
        var r = w;
        r.launch = nl;
        put(app, .{ .weapon = r }) catch |err| app.failed(err);
    }
}

/// A new effect description under a free classic_id (no text row, class, nor record has it):
/// a flash of the effect the Effects tab shows (else "flare1") at the hit, weapon
/// `class`'s every stage made it (its block's `effects_from`). Returns the id.
pub fn newRecord(app: *App, class: []const u8) !i32 {
    if (!app.ogLayout()) return error.ClassicProject;
    var id = entry_rules.freshClassicId(app);
    while (og.core.modules.weaponFx(id, 0) != null) id += 1;
    const sel = app.effect.sel.get();
    const effect = if (sel.len > 0) try app.frame.allocator().dupe(u8, sel) else "flare1";
    try put(app, .{ .weapon = .{ .id = id, .hit = &.{.{ .bitmap = .{ .b = .{ .effect = effect, .pos = @splat(0), .size = 400, .step = 0.5 }, .lift = 250 } }} } });
    var b: [16]u8 = undefined;
    try entry_attacks.setFx(app, class, "effects_from", try std.fmt.bufPrint(&b, "{d}", .{id}));
    restrike(app);
    app.fx_stage = @backingInt(Stage.hit);
    app.fx_part = 0;
    return id;
}

/// The record in force by its key as the scripted edits write it: "ID" a weapon's
/// (WeaponFx, any attacker), "FIGHTER:WEAPON" a fighter's own (FighterFx).
fn keyed(key: []const u8) !Rec {
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return .{ .weapon = record(try std.fmt.parseInt(i32, key, 10), 0) };
    return .{ .fighter = ownRecord(try std.fmt.parseInt(i32, key[0..colon], 10), try std.fmt.parseInt(i32, key[colon + 1 ..], 10)) };
}

/// Part `text` (as the rules write it) after record `key`'s (`keyed`) parts of stage
/// `stage` (the editor's scripted edits, `--fx-put`).
pub fn putText(app: *App, key: []const u8, stage: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const a = app.frame.allocator();
    const st = std.meta.stringToEnum(Stage, stage) orelse return error.BadStage;
    const w = try keyed(key);
    // A weapon's stages for a WeaponFx record, the own ones for a FighterFx one.
    if (st == .launch or (@backingInt(st) < n_weapon) != (w == .weapon)) return error.BadStage;
    const p = try codec.readText(desc.Part, a, text, &app.rule_why);
    try putParts(app, w, st, try std.mem.concat(a, desc.Part, &.{ w.parts(st), &.{p} }));
}

/// The built-in record `from` copied under record `to`'s key (its row; the editor's
/// "Copy from built-in", `--fx-copy`).
fn copyBuiltin(app: *App, to: Rec, from: Rec) !void {
    var r = from;
    switch (r) {
        .weapon => |*x| {
            x.id = to.weapon.id;
            x.who = to.weapon.who;
        },
        .fighter => |*x| {
            x.fighter = to.fighter.fighter;
            x.weapon = to.fighter.weapon;
        },
    }
    try put(app, r);
    app.fx_part = null;
}

/// `--fx-copy TO FROM`: built-in record FROM (`keyed`, the first of that key in the
/// game's table) copied as record TO's row; both of one kind.
pub fn copyText(app: *App, to: []const u8, from: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const dst = try keyed(to);
    const src = try keyed(from);
    if (std.meta.activeTag(dst) != std.meta.activeTag(src)) return error.BadKey;
    const got: Rec = switch (src) {
        .weapon => |k| for (og.core.modules.builtin_tables.weapon_fx) |r| {
            if (r.id == k.id) break .{ .weapon = r };
        } else return error.NoBuiltin,
        .fighter => |k| for (og.core.modules.builtin_tables.fighter_fx) |r| {
            if (r.fighter == k.fighter and r.weapon == k.weapon) break .{ .fighter = r };
        } else return error.NoBuiltin,
    };
    try copyBuiltin(app, dst, got);
}

/// "Copy from built-in": the game's records of `w`'s kind, one picked copied over it.
fn copyRows(app: *App, a: Allocator, w: Rec) void {
    gui.fieldRow(tx.get(tx.fxd_copy));
    const open = picker.field(app, clay.id("fxd_copy"), tx.get(tx.fxd_copy_pick), false);
    clay.close();
    if (!open) return;
    const n = switch (w) {
        .weapon => og.core.modules.builtin_tables.weapon_fx.len,
        .fighter => og.core.modules.builtin_tables.fighter_fx.len,
    };
    const srcs = a.alloc(Rec, n) catch return;
    const rows = a.alloc(picker.Opt, n) catch return;
    for (srcs, rows, 0..) |*src, *o, j| {
        src.* = switch (w) {
            .weapon => .{ .weapon = og.core.modules.builtin_tables.weapon_fx[j] },
            .fighter => .{ .fighter = og.core.modules.builtin_tables.fighter_fx[j] },
        };
        o.* = .{ .label = switch (src.*) {
            .weapon => |r| std.fmt.allocPrint(a, "WeaponFx {d}{s}", .{ r.id, if (r.who != 0) std.fmt.allocPrint(a, " · who {d}", .{r.who}) catch "" else "" }),
            .fighter => |r| std.fmt.allocPrint(a, "FighterFx {d} · {d}", .{ r.fighter, r.weapon }),
        } catch "" };
    }
    const j = picker.list(app, a, rows) orelse return;
    copyBuiltin(app, w, srcs[j]) catch |err| app.failed(err);
}

/// The ticks a part's tracks run over: an emitter's particle life, else its span (60: open).
fn lifeOf(p: desc.Part) u32 {
    return switch (p) {
        .emitter => |x| @intFromFloat(@max(1, x.life.get())),
        else => desc.span(p).len orelse 60,
    };
}

/// A graph of each track in `v` (one, an optional, an array, or a struct's fields
/// `depth` levels down), under its field.
pub fn graphs(a: Allocator, comptime T: type, v: T, name: []const u8, life: u32, comptime depth: u8) void {
    if (T == Track) return graph(a, name, v, life);
    switch (@typeInfo(T)) {
        .optional => |o| if (v) |x| graphs(a, o.child, x, name, life, depth),
        .array => |ar| for (v, 0..) |x, i| graphs(a, ar.child, x, std.fmt.allocPrint(a, "{s} {d}", .{ name, i }) catch name, life, depth),
        .@"struct" => |s| if (depth > 0) inline for (s.field_names) |f| graphs(a, @FieldType(T, f), @field(v, f), f, life, depth - 1),
        else => {},
    }
}

/// Track `t`'s values over `life` ticks as bars, its range beside.
fn graph(a: Allocator, name: []const u8, t: Track, life: u32) void {
    var vs: [48]f32 = undefined;
    const n: usize = @min(life, vs.len);
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    for (vs[0..n], 0..) |*v, i| {
        v.* = t.after(@intCast(i * life / n), life);
        lo = @min(lo, v.*);
        hi = @max(hi, v.*);
    }
    gui.fieldRow(std.fmt.allocPrint(a, "  {s}", .{name}) catch name);
    const h = lay.height.small;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(h) }, .childGap = 1, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } }, .backgroundColor = theme.field });
    for (vs[0..n]) |v| {
        // A flat track: half height.
        const f = if (hi > lo) (v - lo) / (hi - lo) else 0.5;
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(@max(1, f * h)) } }, .backgroundColor = theme.accent_hover });
    }
    clay.close();
    gui.txt(std.fmt.allocPrint(a, " {d:.2}…{d:.2} / {d}", .{ lo, hi, life }) catch "", .caption, theme.dim, font_mod.regular);
    clay.close();
}

/// When each stage starts in the strike (frames from the animation's first): the flash
/// before the hit, the launch at the hit, the rest where it lands.
fn stageAt(s: fx_.Strike, landed: u32, st: Stage) u32 {
    return switch (st) {
        .pre, .own_pre => s.pre orelse s.hit,
        .launch => s.hit,
        .shot, .flash, .hit, .own_hit, .second => landed,
    };
}

/// Stage `st`'s record as the strike runs it (null: not run): the weapon's pre gives way
/// to the striker's own.
/// shortcut: a series' second hit isn't shown (the preview strikes one), upgrade with series strikes.
fn runs(s: fx_.Strike, st: Stage) ?Rec {
    if (st == .second) return null;
    if (st == .pre) if (recordOf(s, .own_pre)) |o| if (o.fighter.pre.len > 0) return null;
    return recordOf(s, st);
}

/// The timeline rows of stage `st`: its parts, the launch one.
fn rowsOf(r: Rec, st: Stage) usize {
    return if (st == .launch) @intFromBool(r.weapon.launch != null) else r.parts(st).len;
}

/// Under the preview: a track per part of every stage over the strike's frames (the
/// preview's), the frame shown marked; a click shows that frame (stopped).
pub fn timeline(app: *App, a: Allocator, s: fx_.Strike) void {
    if (!app.ogLayout()) return;
    const sim = app.preview.sim orelse return;
    const n = @max(app.preview.frames, 1);
    const tid = clay.id("fxd_timeline");
    const inset = lay.space.md;
    const row_h = lay.height.small;
    const w_px = if (clay.box(tid)) |b| b.width - 2 * inset else lay.width.page;
    const step = w_px / @as(f32, @floatFromInt(n));
    var rows: usize = 0;
    for (std.enums.values(Stage)) |st| if (runs(s, st)) |r| {
        rows += rowsOf(r, st);
    };
    clay.open(.{ .id = tid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(@as(f32, @floatFromInt(rows + 1)) * row_h + lay.space.sm) } }, .backgroundColor = theme.field, .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } }, .clip = .{ .horizontal = true, .vertical = true } });
    const over = clay.hovered();
    const bar = struct {
        fn f(x0: f32, x1: f32, y: f32, h: f32, col: clay.Color) void {
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(@max(lay.border.mark, x1 - x0)), .height = clay.fixed(h) } }, .backgroundColor = col, .cornerRadius = clay.radius(lay.radius.sm), .floating = .{ .offset = .{ .x = x0, .y = y }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT } });
        }
    }.f;
    const xOf = struct {
        fn f(fr: u32, st_: f32) f32 {
            return inset + @as(f32, @floatFromInt(fr)) * st_;
        }
    }.f;
    // The strike's frames: the flash before the hit, the hit, the landing.
    const marks = [_]?u32{ s.pre, s.hit, sim.landed };
    for (marks) |m| if (m) |fr| bar(xOf(fr, step), xOf(fr, step), 0, @as(f32, @floatFromInt(rows + 1)) * row_h, theme.field_border);
    var y: f32 = lay.space.xs;
    for (std.enums.values(Stage)) |st| {
        const r = runs(s, st) orelse continue;
        const at = stageAt(s, sim.landed, st);
        if (st == .launch) {
            if (rowsOf(r, st) == 0) continue;
            label(a, "launch", "", y);
            bar(xOf(at, step), xOf(sim.landed, step), y + lay.space.xs, row_h - 2 * lay.space.xs, theme.accent_hover);
            y += row_h;
            continue;
        }
        for (r.parts(st), 0..) |p, k| {
            const sp = desc.span(p);
            const from = at + sp.delay;
            const to = if (sp.len) |l| from + l else n;
            const sel = @backingInt(st) == app.fx_stage and app.fx_part == k;
            bar(xOf(from, step), xOf(@min(to, n), step), y + lay.space.xs, row_h - 2 * lay.space.xs, if (sel) theme.accent else if (sp.len == null) theme.field_border else theme.accent_hover);
            label(a, stage_names[@backingInt(st)], @tagName(p), y);
            y += row_h;
        }
    }
    // The frame shown.
    bar(xOf(app.preview.at, step), xOf(app.preview.at, step) + lay.border.mark, 0, @as(f32, @floatFromInt(rows + 1)) * row_h, theme.accent);
    clay.close();
    if (over and app.clicked) if (clay.box(tid)) |b| {
        const f = (app.mouse[0] - b.x - inset) / step;
        app.preview.paused = @intFromFloat(std.math.clamp(@floor(f), 0, @as(f32, @floatFromInt(n - 1))));
    };
}

fn label(a: Allocator, st: []const u8, kind: []const u8, y: f32) void {
    clay.open(.{ .floating = .{ .offset = .{ .x = lay.space.sm, .y = y }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT, .zIndex = 2 } });
    gui.txt(std.fmt.allocPrint(a, "{s} {s}", .{ st, kind }) catch "", .caption, theme.text, font_mod.regular);
    clay.close();
}
