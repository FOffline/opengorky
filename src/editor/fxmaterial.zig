//! A weapon page's Materials block (OpenGorky rules fx.ss `Material`, effects/material.zig),
//! under its effect description so the model preview stays in sight: the materials in
//! force listed, one added, renamed or deleted, its program, blend and tracks typed as
//! the rules write them (the tracks graphed). A part's `material` is picked from them
//! (fxdesc's part fields). Renaming or deleting one that parts name is refused, its users
//! listed: no part is left naming nothing. Every edit writes the row (rules_rows, one
//! undo step); the preview draws with it at once. Classic: locked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const fxdesc = @import("fxdesc.zig");
const rules_rows = @import("rules_rows.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const picker = @import("picker.zig");
const desc = og.core.effect;
const codec = og.loaders.codec;
const M = desc.Material;

/// The block's state (`app.material`): the material shown.
pub const State = struct { sel: app_mod.Name(64) = .{} };

/// The ticks a material's tracks are graphed over (a part's age; theirs differ).
const graph_life = 60;
const blends = [_][]const u8{ "keep", "add", "alpha", "screen" };

/// The `material` field of a part (its own, else its payload's one level down: a bitmap's
/// `b`, a ribbon's `look`); null: it has none.
fn materialOf(p: desc.Part) ?[]const u8 {
    return switch (p) {
        inline else => |v| get(@TypeOf(v), v, 1),
    };
}

fn get(comptime T: type, v: T, comptime depth: u8) ?[]const u8 {
    if (@typeInfo(T) != .@"struct") return null;
    if (@hasField(T, "material")) return v.material;
    if (depth == 0) return null;
    inline for (@typeInfo(T).@"struct".field_names) |f| if (get(@FieldType(T, f), @field(v, f), depth - 1)) |m| return m;
    return null;
}

/// Part `p` naming material `name` (where `materialOf` reads it).
fn withMaterial(p: desc.Part, name: []const u8) desc.Part {
    var out = p;
    switch (out) {
        inline else => |*v| _ = set(@TypeOf(v.*), v, name, 1),
    }
    return out;
}

fn set(comptime T: type, v: *T, name: []const u8, comptime depth: u8) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasField(T, "material")) {
        v.material = name;
        return true;
    }
    if (depth == 0) return false;
    inline for (@typeInfo(T).@"struct".field_names) |f| if (set(@FieldType(T, f), &@field(v, f), name, depth - 1)) return true;
    return false;
}

/// The parts of `records` naming material `name`, as "WeaponFx 1037 hit 1".
fn usersIn(a: Allocator, out: *std.ArrayList([]const u8), records: anytype, name: []const u8) void {
    for (records) |r| {
        const R = @TypeOf(r);
        inline for (@typeInfo(R).@"struct".field_names) |f| if (@FieldType(R, f) == []const desc.Part) for (@field(r, f), 1..) |p, k| {
            const m = materialOf(p) orelse continue;
            if (!std.mem.eql(u8, m, name)) continue;
            const key = if (R == desc.Weapon) std.fmt.allocPrint(a, "{s} {d}", .{ R.call, r.id }) else std.fmt.allocPrint(a, "{s} {d}:{d}", .{ R.call, r.fighter, r.weapon });
            out.append(a, std.fmt.allocPrint(a, "{s} {s} {d}", .{ key catch continue, f, k }) catch continue) catch {};
        };
    }
}

/// The parts in force naming material `name`.
fn users(a: Allocator, name: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const t = og.core.modules.tables();
    usersIn(a, &out, t.weapon_fx, name);
    usersIn(a, &out, t.fighter_fx, name);
    return out.items;
}

fn put(app: *App, at: M, m: M) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    try rules_rows.putAt(app, M, at, m);
    app.setStatus(tx.st_rules_row, .{std.fmt.allocPrint(app.frame.allocator(), "Material \"{s}\"", .{m.name}) catch m.name});
}

/// A new material under a free name ("material", "material2"…), shown.
pub fn add(app: *App) !void {
    var b: [32]u8 = undefined;
    var n: usize = 1;
    const name = while (true) : (n += 1) {
        const s = if (n == 1) "material" else try std.fmt.bufPrint(&b, "material{d}", .{n});
        if (og.core.modules.material(s) == null) break s;
    };
    app.material.sel.set(name);
    try put(app, .{ .name = name }, .{ .name = name });
}

/// Material `from` renamed `to`: refused while a part names it (its users listed) or the
/// name is taken.
pub fn rename(app: *App, from: []const u8, to: []const u8) !void {
    const m = (og.core.modules.material(from) orelse return error.NoSuchMaterial).*;
    const name = std.mem.trim(u8, to, " \"");
    if (name.len == 0) return error.EmptyName;
    if (std.mem.eql(u8, name, from)) return;
    if (og.core.modules.material(name) != null) return error.NameTaken;
    try refuseUsed(app, from);
    var r = m;
    r.name = try app.frame.allocator().dupe(u8, name);
    try put(app, m, r);
    app.material.sel.set(name);
}

/// Material `name`'s row dropped: refused while a part names it.
pub fn delete(app: *App, name: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    try refuseUsed(app, name);
    if (!try rules_rows.drop(app, M, .{ .name = name })) return error.NotInFxSs;
    app.material.sel.set("");
}

fn refuseUsed(app: *App, name: []const u8) !void {
    const us = users(app.frame.allocator(), name);
    if (us.len == 0) return;
    app.setStatus(tx.st_mat_used, .{ name, us.len, us[0] });
    return error.MaterialInUse;
}

/// Field `field` of material `name` typed as `text` (as the rules write it; a bare word
/// quoted), its row written (`--material`).
pub fn setText(app: *App, name: []const u8, field: []const u8, text: []const u8) !void {
    const m = (og.core.modules.material(name) orelse return error.NoSuchMaterial).*;
    const a = app.frame.allocator();
    inline for (.{ "program", "blend", "rgb", "alpha", "k" }) |f| if (std.mem.eql(u8, field, f)) {
        const T = @FieldType(M, f);
        const U = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        const t = std.mem.trim(u8, text, " ");
        var r = m;
        @field(r, f) = if (@typeInfo(T) == .optional and (t.len == 0 or std.mem.eql(u8, t, "keep"))) null else try codec.readText(T, a, if (@typeInfo(U) == .@"enum" and t[0] != '"') try std.fmt.allocPrint(a, "\"{s}\"", .{t}) else t, &app.rule_why);
        return put(app, m, r);
    };
    return error.NoSuchField;
}

/// The Materials block of a weapon's page (Classic: its lock).
pub fn block(app: *App, a: Allocator) void {
    const ms = og.core.modules.tables().materials;
    if (!gui.block(app, "materials", tx.get(tx.mat_title), .{ .og = true, .summary = std.fmt.allocPrint(a, "{d}", .{ms.len}) catch "" })) return;
    defer gui.blockEnd();
    gui.note(tx.get(tx.mat_hint));
    const shown = app.material.sel.get();
    for (ms, 0..) |m, k| {
        const sel = std.mem.eql(u8, m.name, shown);
        if (gui.listRow(app, clay.idi("mat_row", @intCast(k)), .{ .selected = sel, .h = lay.height.small, .rounded = false, .bg = theme.bg })) app.material.sel.set(if (sel) "" else m.name);
        gui.txt(m.name, .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.txtClip(std.fmt.allocPrint(a, "{t} · {s}", .{ m.program, if (m.blend) |b| @tagName(b) else blends[0] }) catch "", .caption, theme.dim, font_mod.regular);
        clay.close();
    }
    if (ms.len == 0) gui.note(tx.get(tx.mat_empty));
    const cur = og.core.modules.material(shown);
    const labels = [_][]const u8{ tx.get(tx.mat_add), tx.get(tx.mat_delete) };
    if (gui.footer(app, "mat_ops", labels[0 .. @as(usize, 1) + @intFromBool(cur != null)], null)) |b| {
        const r = if (b == 0) add(app) else delete(app, shown);
        r catch |err| if (err != error.MaterialInUse) app.failed(err);
    }
    fields(app, a, (cur orelse return).*);
}

/// Material `m`'s fields, each written back on its own; its tracks graphed, its users listed.
fn fields(app: *App, a: Allocator, m: M) void {
    gui.subhead(tx.alloc(a, tx.mat_shown, .{m.name}));
    gui.fieldRow("name");
    if (gui.textField(app, "mat_name", m.name, 0, "—")) |t| rename(app, m.name, t) catch |err| if (err != error.MaterialInUse) app.failed(err);
    clay.close();
    var r = m;
    var changed = false;
    gui.fieldRow("program");
    if (gui.segmented(app, "mat_program", comptime std.meta.fieldNames(og.effects.material.Program), @backingInt(m.program))) |k| {
        r.program = @fromBackingInt(@intCast(k));
        changed = true;
    }
    clay.close();
    gui.fieldRow("blend");
    if (gui.segmented(app, "mat_blend", &blends, if (m.blend) |b| @backingInt(b) + 1 else 0)) |k| {
        r.blend = if (k == 0) null else @fromBackingInt(@intCast(k - 1));
        changed = true;
    }
    clay.close();
    inline for (.{ "rgb", "alpha", "k" }) |f| {
        gui.fieldRow(f);
        if (fxdesc.valueField(app, a, @FieldType(M, f), "mat_f_" ++ f, @field(m, f))) |x| {
            @field(r, f) = x;
            changed = true;
        }
        clay.close();
        fxdesc.graphs(a, @FieldType(M, f), @field(m, f), f, graph_life, 0);
    }
    if (changed) put(app, m, r) catch |err| app.failed(err);
    const us = users(a, m.name);
    gui.fieldRow(tx.get(tx.mat_users));
    gui.txtWrap(if (us.len == 0) tx.get(tx.mat_unused) else std.mem.join(a, ", ", us) catch "", .caption, theme.dim, font_mod.regular);
    clay.close();
}

/// Under a picked part's fields (OpenGorky): its material picked from the ones in force
/// (or none); the part as picked, else null. Parts without a material: nothing.
pub fn materialRow(app: *App, a: Allocator, p: desc.Part) ?desc.Part {
    const now = materialOf(p) orelse return null;
    gui.fieldRow("material");
    const missing = now.len > 0 and og.core.modules.material(now) == null;
    const open = picker.field(app, pickId(), if (now.len == 0) tx.get(tx.mat_none) else now, missing);
    clay.close();
    if (!open) return null;
    const ms = og.core.modules.tables().materials;
    const rows = a.alloc(picker.Opt, ms.len + 1) catch return null;
    for (rows, 0..) |*o, j| {
        const name = if (j == 0) "" else ms[j - 1].name;
        o.* = .{ .key = name, .label = if (j == 0) tx.get(tx.mat_none) else name, .selected = std.mem.eql(u8, name, now) };
    }
    const j = picker.list(app, a, rows) orelse return null;
    // Shown in the Materials block too.
    app.material.sel.set(rows[j].key);
    return withMaterial(p, a.dupe(u8, rows[j].key) catch return null);
}

/// The picked part's material field.
pub fn pickId() @import("ui").Clay_ElementId {
    return clay.id("fxd_mat");
}

test "a part's material: read and written where its kind keeps it" {
    const bm: desc.Part = .{ .bitmap = .{ .b = .{ .effect = "x", .pos = @splat(0), .size = 1, .step = 1 } } };
    try std.testing.expectEqualStrings("", materialOf(bm).?);
    const named = withMaterial(bm, "melt");
    try std.testing.expectEqualStrings("melt", named.bitmap.b.material);
    try std.testing.expectEqualStrings("melt", materialOf(named).?);
    const em = withMaterial(.{ .emitter = .{ .at = .{ .target = 0 } } }, "heat");
    try std.testing.expectEqualStrings("heat", em.emitter.material);
    // No material: a sound, a shake.
    try std.testing.expect(materialOf(.{ .shake = .n(3) }) == null);
}

test "materials: rows put, renamed in place, read back; users found" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try rules_rows.putText(a, a, M, "WeaponFx(id = 1);\n", .{ .name = "melt", .program = .dissolve, .blend = .add, .k = .{ .rate = 0.1, .max = 1 } });
    t = try rules_rows.putText(a, a, M, t, .{ .name = "glow" });
    t = try rules_rows.putTextAt(a, a, M, t, .{ .name = "melt" }, .{ .name = "melt2", .program = .heat });
    try std.testing.expectEqualStrings(
        \\WeaponFx(id = 1);
        \\Material(name = "melt2", program = "heat");
        \\Material(name = "glow");
        \\
    , t);
    // Read back as the rules read it: the fields as written, the rest their defaults.
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const got = try codec.read(M, a, codec.parseRows(a, t, &diag).?[1].kind.call, null);
    try std.testing.expect(got.program == .heat and got.blend == null and got.alpha.v == 1);
    try std.testing.expectEqualStrings("melt2", got.name);
    var out: std.ArrayList([]const u8) = .empty;
    const recs = [_]desc.Weapon{.{ .id = 7, .hit = &.{ .{ .shake = .n(1) }, withMaterial(.{ .emitter = .{ .at = .{ .target = 0 } } }, "glow") } }};
    usersIn(a, &out, &recs, "glow");
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("WeaponFx 7 hit 2", out.items[0]);
}
