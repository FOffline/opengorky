//! Trigger window (right click on an area of a location): the area's own script
//! (`.are` of the object naming it) and every place of the level's scripts that names
//! the area (`HeroInArea("cutscene_crazy")`…), each block can be turned off and on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const scenes = @import("scenes.zig");
const scenepage = @import("scenepage.zig");
const trigger = @import("trigger.zig");
const areas = @import("areas.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

pub fn panel(app: *App, a: Allocator, name: []const u8) void {
    const d = app.doc orelse return;
    if (gui.modal(app, "triggerpanel", .{ .h = lay.height.window, .bg = theme.bg, .title = tx.alloc(a, tx.tr_title, .{name}) }) == .close) app.trigger = null;
    clay.openScrollColumn(.{ .id = clay.id("trigger_body"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = lay.space.lg, .right = lay.space.lg, .bottom = lay.space.lg }, .childGap = lay.space.sm } });

    // Places naming it, in every script of the level.
    _ = gui.block(app, null, tx.get(if (app.ogLayout()) tx.tr_refs_og else tx.tr_refs), .{});
    var n: u32 = 0;
    // OpenGorky: the level's OG Script texts (areas.levelTexts).
    for (areas.levelTexts(app, d, a)) |fi| {
        const entry = app.store.files.items[fi].entry;
        // An area block's own `areaName` is no block to turn off (its script is below).
        if (app.ogLayout() and std.mem.endsWith(u8, entry, "/objects.ogs")) continue;
        const cs = scenes.refs(a, app.store.text(fi), name) catch continue;
        for (cs, 0..) |call, k| {
            n += 1;
            scenepage.card(app, a, fi, d.name, entry, call, @intCast(n * 16 + k), tx.tr_turn_off);
        }
    }
    if (n == 0) gui.txt(tx.get(tx.tr_no_refs), .body, theme.dim, font_mod.regular);
    gui.blockEnd();

    // Heroes joining or leaving here: the party heroes and this level's own.
    _ = gui.block(app, null, tx.get(tx.tr_party), .{});
    gui.note(tx.get(if (app.ogLayout()) tx.tr_party_hint_og else tx.tr_party_hint));
    for (app.catalog.entries.items, 0..) |e, k| {
        const here = std.mem.eql(u8, e.archive, d.level_archive);
        if (e.kind != .hero or (e.ally and !here)) continue;
        gui.row(lay.space.sm);
        gui.txt(std.fmt.allocPrint(a, "{s} ({s})", .{ if (e.title.len > 0) e.title else e.id, e.id }) catch e.id, .body, theme.text, font_mod.regular);
        gui.spacer();
        // Joining needs the hero's object here: a level hero of this location.
        if (here and gui.button(app, std.fmt.allocPrint(a, "tp_join{d}", .{k}) catch "tp_join", tx.get(tx.tr_join), false)) partyCall(app, name, e.id, true) catch |err| app.failed(err);
        if (gui.button(app, std.fmt.allocPrint(a, "tp_leave{d}", .{k}) catch "tp_leave", tx.get(tx.tr_leave), false)) partyCall(app, name, e.id, false) catch |err| app.failed(err);
        clay.close();
    }
    gui.blockEnd();

    // The area object's own script (`areaName` = this area): its functions run on use;
    // on OpenGorky its component in the level's logic.ogs.
    if (app.ogLayout()) ownOg(app, a, d, name) else for (d.world.rt.objects.items) |o| {
        if (!std.ascii.eqlIgnoreCase(o.getString("areaName"), name)) continue;
        var buf: [128]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "{s}.are", .{o.name}) catch continue;
        const fi = app.store.file(d.level_archive, entry) catch continue;
        _ = gui.block(app, null, tx.alloc(a, tx.tr_own, .{entry}), .{});
        var lines = std.mem.splitScalar(u8, app.store.text(fi), '\n');
        while (lines.next()) |raw| {
            const l = std.mem.trimEnd(u8, raw, " \t\r");
            // Tabs as spaces (the font has no tab glyph).
            if (l.len > 0) gui.txt(std.mem.replaceOwned(u8, a, l, "\t", "    ") catch continue, .caption, theme.text, font_mod.regular);
        }
        gui.blockEnd();
    }
    clay.closeScrollColumn();
    clay.close();
}

/// OpenGorky: the components of the level's area objects naming area `name` (their
/// text in logic.ogs).
fn ownOg(app: *App, a: Allocator, d: *@import("level.zig").Doc, name: []const u8) void {
    const lf = @import("level_og.zig").blockFile(d) orelse return;
    for (@import("model_og.zig").levelObjects(app, a, lf)) |o| {
        if (!std.mem.eql(u8, o.kind, "area")) continue;
        const an = for (o.fields) |f| {
            if (std.mem.eql(u8, f.name, "areaName")) break @import("opengorky").core.schema.text(f.value) orelse continue;
        } else continue;
        if (!std.ascii.eqlIgnoreCase(an, name)) continue;
        for (o.attach) |x| {
            const comp = x.component[if (std.mem.lastIndexOf(u8, x.component, "::")) |k| k + 2 else 0..];
            const cf = @import("areas.zig").compFile(app, d, comp) orelse continue;
            const lt = app.store.text(cf);
            const sp = trigger.componentSpanOg(lt, comp) orelse continue;
            const fname = std.fs.path.basename(app.store.files.items[cf].entry);
            _ = gui.block(app, null, tx.alloc(a, tx.tr_own, .{std.fmt.allocPrint(a, "{s} · {s}", .{ o.name, fname }) catch o.name}), .{});
            var lines = std.mem.splitScalar(u8, lt[sp[0]..sp[1]], '\n');
            while (lines.next()) |raw| {
                const l = std.mem.trimEnd(u8, raw, " \t\r");
                if (l.len > 0) gui.txt(std.mem.replaceOwned(u8, a, l, "\t", "    ") catch continue, .caption, theme.text, font_mod.regular);
            }
            gui.blockEnd();
        }
    }
}

/// Hero `hero` joins or leaves the party when a hero walks into area `area` of the open
/// location: the game's calls (trigger.partyCalls) last in that area's block; one undo step.
pub fn partyCall(app: *App, area: []const u8, hero: []const u8, join: bool) !void {
    const d = app.doc orelse return error.NoLevel;
    if (app.ogLayout()) {
        // OpenGorky: into the area's block (its own text's, else the level's logic.ogs),
        // indented as its body.
        var qb: [128]u8 = undefined;
        const q = try std.fmt.bufPrint(&qb, "hero::AnyInArea(\"{s}\")", .{area});
        const f = for (@import("areas.zig").levelTexts(app, d, app.frame.allocator())) |x| {
            if (std.ascii.findIgnoreCase(app.store.text(x), q) != null) break x;
        } else return error.NoTrigger;
        const t = app.store.text(f);
        const at = std.ascii.findIgnoreCase(t, q).?;
        const ls = @import("code.zig").lineStart(t, at);
        var ib: [64]u8 = undefined;
        const lead = t[ls .. ls + (std.mem.indexOfNone(u8, t[ls..], " \t") orelse 0)];
        const ind = try std.fmt.bufPrint(&ib, "{s}    ", .{lead});
        var buf: [256]u8 = undefined;
        const out = try trigger.addToAreaBlockOg(app.gpa, t, area, try trigger.partyCallsOg(&buf, hero, join, ind));
        errdefer app.gpa.free(out);
        try app.store.replace(f, out);
        @import("entry_rules.zig").sync(app);
        return app.setStatus(tx.st_party_call, .{ hero, area });
    }
    const lev = app.store.text(d.lev);
    var buf: [256]u8 = undefined;
    const calls = try trigger.partyCalls(&buf, hero, join, @import("placement.zig").newline(lev));
    const out = try trigger.addToAreaBlock(app.gpa, lev, area, calls);
    errdefer app.gpa.free(out);
    try app.store.replace(d.lev, out);
    app.setStatus(tx.st_party_call, .{ hero, area });
}

/// `--trigger-off AREA`: the first block of the open level naming area `area` that has a
/// switch turned off — on OpenGorky its level variable (scenepage.ogSwitch), on Classic
/// its lines commented out (as "Turn this block off").
pub fn turnOff(app: *App, area: []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    const a = app.frame.allocator();
    for (areas.levelTexts(app, d, a)) |fi| {
        const text = app.store.text(fi);
        for (try scenes.refs(a, text, area)) |call| {
            if (app.ogLayout()) {
                const w = scenepage.ogSwitch(app, text, call.at) orelse continue;
                if (!w.on) continue;
                const t = try trigger.setLevelVarOg(app.gpa, app.store.text(w.file), w.name, false);
                errdefer app.gpa.free(t);
                return app.store.replace(w.file, t);
            }
            if (call.state != .on or !scenes.safe(text, call.at)) continue;
            const t = try scenes.turnOff(app.gpa, text, scenes.block(text, call.at));
            errdefer app.gpa.free(t);
            return app.store.replace(fi, t);
        }
    }
    return error.NoTrigger;
}
