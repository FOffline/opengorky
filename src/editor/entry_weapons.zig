//! An enemy's weapons: swapped for this enemy or its whole class (its page's block is
//! char_arsenal.zig), the reach of each shown on a grid, and the resistances the exe
//! gives its classic_id.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const classLabel = @import("item_page.zig").classLabel;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const picker = @import("picker.zig");
const catalog = @import("catalog.zig");
const Entry = catalog.Entry;
const common_archive = @import("store.zig").common_archive;
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const zone = @import("zone.zig");

/// A battle enemy's weapon (`.wpn` Store file `wpn`, its class `class`): the class it
/// includes, and on a click the other enemy weapon classes of the same reach (close or
/// long, as the attack animation goes by it) to swap in — this enemy only.
pub fn weaponChoice(app: *App, a: Allocator, wpn: usize, class: ?usize) void {
    const cur = if (class) |ci| baseName(app.store.files.items[ci].entry) else "?";
    const cur_long = if (class) |ci| (model.get(app.store.text(ci), "long_attack") orelse 0) != 0 else false;
    gui.fieldNote(tx.alloc(a, tx.wp_class_of, .{ cur, tx.get(if (cur_long) tx.wp_long else tx.wp_short) }), theme.dim);
    var ib: [24]u8 = undefined;
    if (gui.footer(app, std.fmt.bufPrint(&ib, "wpn_cls{d}", .{wpn}) catch "wpn_cls", &.{pickerLabel(app, changeId(wpn), tx.wp_change)}, null) != null) picker.toggle(app, changeId(wpn));
    const new = weaponPicker(app, a, changeId(wpn), cur, cur_long) orelse return;
    swapWeapon(app, wpn, cur, new) catch |err| app.failed(err);
}

/// The button opening battle weapon `wpn`'s class list.
pub fn changeId(wpn: usize) ui.Clay_ElementId {
    var ib: [24]u8 = undefined;
    return clay.idi(std.fmt.bufPrint(&ib, "wpn_cls{d}", .{wpn}) catch "wpn_cls", 0);
}

/// What the button opening list `id` says (Cancel while open).
pub fn pickerLabel(app: *App, id: ui.Clay_ElementId, action: tx.Msg) []const u8 {
    return tx.get(if (picker.isOpen(app, id)) tx.cancel else action);
}

/// While list `id` is open: the other enemy weapon classes of the same reach as `cur`
/// (close or long by `cur_long`: the attack animation goes by it). Returns the one clicked.
pub fn weaponPicker(app: *App, a: Allocator, id: ui.Clay_ElementId, cur: []const u8, cur_long: bool) ?[]const u8 {
    if (!picker.isOpen(app, id)) return null;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (weaponClasses(app, a)) |entry| {
        const f = app.store.file(common_archive, entry) catch continue;
        const t = app.store.text(f);
        if (((model.get(t, "long_attack") orelse 0) != 0) != cur_long) continue;
        const name = app.store.files.items[f].entry["classes\\".len..];
        if (std.ascii.eqlIgnoreCase(name, cur)) continue;
        rows.append(a, .{ .key = name, .label = name[0 .. name.len - 3], .note = tx.alloc(a, tx.wp_option, .{ classLabel(a, model.get(t, "class")), model.get(t, "max_damage") orelse 0 }) }) catch {};
    }
    return rows.items[picker.list(app, a, rows.items) orelse return null].key;
}

/// The enemy weapon classes (`classes\\wp_*.ss`), the game's and the editor's copies.
pub fn weaponClasses(app: *App, a: Allocator) []const []const u8 {
    return app.store.listing(a, common_archive, struct {
        fn f(e: []const u8) bool {
            return std.ascii.startsWithIgnoreCase(e, "classes\\wp_") and std.ascii.endsWithIgnoreCase(e, ".ss");
        }
    }.f, false);
}

/// Every fighter of enemy class `class` in every battle (the game's and the ones added
/// in the editor) gets weapon class `new` for `cur` (one undo step); the editor's
/// built attack (shogoth) follows. Returns how many weapons changed.
pub fn swapClassWeapon(app: *App, class: []const u8, cur: []const u8, new: []const u8) !usize {
    const a = app.frame.allocator();
    const ft = try std.fmt.allocPrint(a, "ft_{s}.ss", .{class});
    // Every battle's `.wpn`: one undo step.
    app.store.group();
    defer app.store.endGroup("{s}: {s} → {s}", .{ class, cur, new });
    var n: usize = 0;
    for (app.levels) |lvl| {
        if (!lvl.battle) continue;
        const path = try std.fmt.allocPrint(a, "{s}/other.dat", .{lvl.name});
        const names = app.store.listing(a, path, null, false);
        for (names) |fe| {
            if (!std.ascii.endsWithIgnoreCase(fe, ".ftr")) continue;
            const fi = app.store.file(path, fe) catch continue;
            if (std.ascii.findIgnoreCase(app.store.text(fi), ft) == null) continue;
            const q = try std.fmt.allocPrint(a, "\"{s}\"", .{fe[0 .. fe.len - 4]});
            for (names) |we| {
                if (!std.ascii.endsWithIgnoreCase(we, ".wpn")) continue;
                const wi = app.store.file(path, we) catch continue;
                const t = app.store.text(wi);
                if (std.ascii.findIgnoreCase(t, q) == null) continue;
                swapWeapon(app, wi, cur, new) catch continue;
                n += 1;
            }
        }
    }
    for (app.templates) |*t| if (t.weapon != null and std.ascii.eqlIgnoreCase(t.class, class) and std.ascii.eqlIgnoreCase(t.weapon.?, cur)) {
        t.weapon = try app.catalog.arena.allocator().dupe(u8, new);
        n += 1;
    };
    // The class page lists the new one.
    for (app.catalog.entries.items) |*e| if (e.kind == .enemy and std.ascii.eqlIgnoreCase(e.id, class)) {
        for (e.weapons.items) |*w| if (std.ascii.eqlIgnoreCase(w.*, cur)) {
            w.* = try app.catalog.arena.allocator().dupe(u8, new);
        };
    };
    return n;
}

/// `.wpn` file `wpn` includes class `new` instead of `cur` (one undo step).
pub fn swapWeapon(app: *App, wpn: usize, cur: []const u8, new: []const u8) !void {
    var ob: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    try app.store.replaceText(wpn, try std.fmt.bufPrint(&ob, "#include {s}", .{cur}), try std.fmt.bufPrint(&nb, "#include {s}", .{new}));
    // The enemy's files are read again (its weapon class changed).
    app.enemy_of = null;
}

/// Resistances of `who` from its core record, a block's subgroup: ticks in as many
/// columns as fit. In an OpenGorky project a tick writes its Resist row by class, or for
/// a placed fighter (`who.obj`) by that fighter if so chosen (rules\\resist.ss); in
/// Classic read-only (the exe keys them by classic_id in its code).
pub fn resistBlock(app: *App, a: Allocator, who_in: og.rules.Who) void {
    var who = who_in;
    const editable = app.ogLayout() and who.class.len > 0;
    if (editable and who.obj.len > 0) {
        gui.fieldRow(tx.get(tx.r_scope));
        if (gui.segmented(app, "resist_scope", &.{ tx.get(tx.r_scope_obj), tx.get(tx.r_scope_class) }, @intFromBool(!app.resist_own))) |k| app.resist_own = k == 0;
        clay.close();
    }
    if (!app.resist_own or !editable) who.obj = "";
    var flags: [8]bool = @splat(false);
    if (og.core.entity.enemyOf(who).resist) |e| for (&flags, e.resist.bits) |*f, x| {
        f.* = x != 0;
    };
    gui.subhead(std.fmt.allocPrint(a, "{s} · {s}", .{ tx.get(tx.r_title), if (editable) tx.alloc(a, tx.r_rows, .{if (who.obj.len > 0) who.obj else who.class}) else tx.get(tx.r_game) }) catch tx.get(tx.r_title));
    const names = [8]tx.Msg{ tx.p_fire, tx.p_elect, tx.r_decoy, tx.p_energy, tx.p_freeze, tx.p_tranq, tx.p_gas, tx.r_flammable };
    const gid = clay.id("resist");
    const cols = @min(4, if (clay.box(gid)) |b| lay.autoFit(b.width, lay.space.xs, lay.width.label_sm) else 3);
    clay.open(.{ .id = gid, .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    var i: usize = 0;
    while (i < names.len) : (i += cols) {
        gui.row(lay.space.xs);
        for (i..i + cols) |k| {
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.small) }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            // Read-only (Classic): the tick shows, a click does nothing.
            if (k < names.len) if (gui.check(app, if (editable) clay.idi("resist_tick", @intCast(k)) else .{}, flags[k], tx.get(names[k])[std.mem.indexOf(u8, tx.get(names[k]), ": ").? + 2 ..]) and editable)
                toggleResist(app, who, k) catch |err| app.failed(err);
            clay.close();
        }
        clay.close();
    }
    clay.close();
    @import("entry_tables.zig").armorRow(app, a, who, editable);
}

/// Resistance `k` of `who` flipped: its Resist row in force (else none) written in place
/// when the project's and its own, else as a new row by its object (a placed fighter's),
/// its classic_id or its class (rules_rows.ownKey).
fn toggleResist(app: *App, who: og.rules.Who, k: usize) !void {
    if (!app.ogLayout() or who.class.len == 0) return error.ClassicProject;
    const rr = @import("rules_rows.zig");
    var r = rr.ownKey(app, og.rules.Resist, "fighter", if (og.core.entity.enemyOf(who).resist) |e| e.* else .{ .fighter = 0 }, who);
    r.resist.bits[k] ^= 1;
    try rr.put(app, og.rules.Resist, r);
    app.setStatus(tx.st_rule_set, .{ og.rules.rows.Flags.words[k], if (who.obj.len > 0) who.obj else who.class });
}

/// The damage zone of weapon class `class_f`, from the exe's patterns (zone.zig): the
/// tiles around the shooter with the damage percent at each (outlined: a ray's first
/// tile; the others are cut by an obstacle before them), a wide ray's second tiles, and
/// the tiles each hit covers around the target. `id` tells several maps apart.
pub fn reachMap(app: *App, a: Allocator, class_f: ?f32, id: u32) void {
    const class: i32 = @intFromFloat(class_f orelse 0);
    // In a block (an enemy's weapon): a card of its own surface.
    _ = gui.block(app, null, tx.alloc(a, tx.reach_title, .{classLabel(a, class_f)}), .{ .inner = id != 0 });
    defer gui.blockEnd();
    const w = og.rules.pattern(class) orelse return gui.txt(tx.get(tx.reach_none), .caption, theme.dim, font_mod.regular);
    switch (og.core.modules.weaponKind(class)) {
        .satellite => gui.txt(tx.get(tx.reach_satellite), .caption, theme.text, font_mod.regular),
        .time_bomb => gui.txt(tx.get(tx.reach_bomb), .caption, theme.text, font_mod.regular),
        else => {},
    }
    const z = zone.build(a, w) catch return;
    var sets: usize = 0;
    for (z.used) |u| sets += @intFromBool(u);
    if (z.cells.count() > 0) {
        gui.txtWrap(tx.alloc(a, tx.reach_hint, .{ if (w.wide) tx.get(tx.reach_wide) else "", if (sets > 1) tx.get(tx.reach_sets) else "" }), .caption, theme.dim, font_mod.regular);
        clay.open(.{ .id = clay.idi("reach", id * 8), .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.border.line } });
        var y = z.lo[1];
        while (y <= z.hi[1]) : (y += 1) {
            clay.open(.{ .layout = .{ .childGap = lay.border.line } });
            var x = z.lo[0];
            while (x <= z.hi[0]) : (x += 1) {
                if (x >= 0 and y >= 0 and x < z.size and y < z.size) {
                    cellBox(shooter_col, false, "", "");
                    continue;
                }
                const v = z.cells.get(.{ x, y }) orelse {
                    cellBox(theme.viewport, false, "", "");
                    continue;
                };
                const shade = 90 + @as(f32, @floatFromInt(v.pct)) * 1.2;
                const bg: clay.Color = if (v.side) .{ .r = 40, .g = shade * 0.6, .b = 60, .a = 255 } else .{ .r = 40, .g = shade, .b = 70, .a = 255 };
                cellBox(bg, !v.chain and !v.side, std.fmt.allocPrint(a, "{d}", .{v.pct}) catch "", if (sets > 1) std.fmt.allocPrint(a, "{d}", .{v.effect + 1}) catch "" else "");
            }
            clay.close();
        }
        clay.close();
    }
    // The hit sets the rays use (satellite: none, its one set).
    clay.open(.{ .layout = .{ .childGap = lay.space.lg } });
    for (w.effects.sets, 0..) |eff, k| {
        if (eff.len == 0 or (z.cells.count() > 0 and !z.used[k])) continue;
        clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.space.xs } });
        if (eff.len == 1 and eff[0][0] == 0 and eff[0][1] == 0) {
            gui.txt(tx.alloc(a, tx.reach_single, .{k + 1}), .caption, theme.dim, font_mod.regular);
            clay.close();
            continue;
        }
        gui.txt(tx.alloc(a, tx.reach_area, .{ k + 1, eff.len }), .caption, theme.dim, font_mod.regular);
        const b = zone.setBounds(eff);
        clay.open(.{ .id = clay.idi("reach", id * 8 + 1 + @as(u32, @intCast(k))), .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = lay.border.line } });
        var y = b[0][1];
        while (y <= b[1][1]) : (y += 1) {
            clay.open(.{ .layout = .{ .childGap = lay.border.line } });
            var x = b[0][0];
            while (x <= b[1][0]) : (x += 1) {
                const hit = for (eff) |d| {
                    if (d[0] == x and d[1] == y) break true;
                } else false;
                cellBox(if (x == 0 and y == 0) target_col else if (hit) hit_col else theme.viewport, false, "", "");
            }
            clay.close();
        }
        clay.close();
        clay.close();
    }
    clay.close();
    legend();
}

pub const shooter_col: clay.Color = .{ .r = 70, .g = 140, .b = 255, .a = 255 };
pub const target_col: clay.Color = .{ .r = 200, .g = 60, .b = 60, .a = 255 };
pub const hit_col: clay.Color = .{ .r = 210, .g = 130, .b = 50, .a = 255 };
/// A zone map's tile, a legend's or a resistance's colour swatch.
pub const tile = 4 * lay.unit;
const swatch = lay.height.tick - lay.border.mark;

/// A tile of a zone map: `pct` over `set` (either may be empty); `edge` outlines it.
fn cellBox(bg: clay.Color, edge: bool, pct: []const u8, set: []const u8) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(tile), .height = clay.fixed(tile) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = bg,
        .border = if (edge) .{ .color = theme.text, .width = gui.edges(lay.border.mark) } else .{},
    });
    if (pct.len > 0) gui.txt(pct, .caption, theme.text, font_mod.regular);
    if (set.len > 0) gui.txt(set, .caption, theme.warn, font_mod.regular);
    clay.close();
}

/// What the colours of the zone maps mean.
pub fn legend() void {
    const items = [_]struct { clay.Color, bool, tx.Msg }{
        .{ shooter_col, false, tx.zl_shooter },                             .{ .{ .r = 40, .g = 210, .b = 70, .a = 255 }, true, tx.zl_start },
        .{ .{ .r = 40, .g = 180, .b = 70, .a = 255 }, false, tx.zl_chain }, .{ .{ .r = 40, .g = 126, .b = 60, .a = 255 }, false, tx.zl_side },
        .{ target_col, false, tx.zl_target },                               .{ hit_col, false, tx.zl_hit },
    };
    // One column: the enemy page shows it in its narrow values column too.
    for (items) |it| {
        gui.rowFit(lay.space.sm);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(swatch), .height = clay.fixed(swatch) } }, .backgroundColor = it[0], .border = if (it[1]) .{ .color = theme.text, .width = gui.edges(lay.border.mark) } else .{} });
        gui.txt(tx.get(it[2]), .caption, theme.dim, font_mod.regular);
        clay.close();
    }
}
