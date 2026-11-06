//! The game's texts in common/lang.dat, as rows by number: `string.tab` (`id=text`
//! under `//===` section headers: names by `classic_id`, interface words), `items.inf`
//! (`ITEM_EXAMINE: id` and the indented description, examining an item) and
//! `activeareas.inf` (`AREA_EXAMINE: id`, examining an area). A row edited keeps the
//! file's layout (one line changed, Windows lines, the game's code page); a new row goes
//! at the end (string.tab: under an `EDITOR` section). The exe sizes its string table by
//! the largest number (0x40f5ce), so any free number works; a line is at most 900 bytes.
//!
//! An OpenGorky project has no lang.dat: its texts are rows of `src/texts/` (UTF-8,
//! loaders/ogs.zig `loadTexts`): `UiText(id = N, text = "…");` the names and interface
//! words (`texts/ui.ogs`), `Examine`/`AreaExamine` the examine texts (`texts/examine.ogs`),
//! one a line as the OG writer writes them. The same API reads and edits them there. A
//! number a block owns (its own `classic_id`) is that block's text instead:
//! `name = "…"` (`string.tab`'s), `examine = "…"` (`items.inf`'s, an area's
//! `activeareas.inf`'s), read and written on every block owning it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const code = @import("code.zig");
const tx = @import("text.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const common_archive = @import("store.zig").common_archive;
const og_src = @import("store.zig").og_src;
const lexer = og.script.ogs.lexer;

pub const archive = "common/lang.dat";

pub const File = enum {
    strings,
    items,
    areas,

    pub fn entry(self: File) []const u8 {
        return switch (self) {
            .strings => "string.tab",
            .items => "items.inf",
            .areas => "activeareas.inf",
        };
    }

    fn key(self: File) []const u8 {
        return switch (self) {
            .strings => "",
            .items => "ITEM_EXAMINE:",
            .areas => "AREA_EXAMINE:",
        };
    }
};

/// A row: its number, text (UTF-8), the section or comment above it, and where its text
/// is in the file (the value's bytes; `.inf`: from the key line to the block's end).
pub const Row = struct { id: i32, text: []const u8, section: []const u8, start: usize, end: usize };

/// The longest line the exe reads.
const max_line = 900;

pub fn fileOf(app: *App, f: File) ?usize {
    if (app.store.root != null) return app.store.file(og_src, ogPath(f)) catch null;
    return app.store.file(archive, f.entry()) catch null;
}

/// An OpenGorky project's file of `f`'s rows (compose/og/write.zig's layout) and its row's call.
fn ogPath(f: File) []const u8 {
    return if (f == .strings) "texts/ui.ogs" else "texts/examine.ogs";
}

fn ogCall(f: File) []const u8 {
    return switch (f) {
        .strings => "UiText",
        .items => "Examine",
        .areas => "AreaExamine",
    };
}

/// The rows of `f` as the Store has it now (texts in `a`).
pub fn rows(app: *App, a: Allocator, f: File) []const Row {
    const fi = fileOf(app, f) orelse return if (app.store.root != null) ogRows(app, a, "", f) catch &.{} else &.{};
    if (app.store.root != null) return ogRows(app, a, app.store.text(fi), f) catch &.{};
    return parse(a, app.store.text(fi), f, app.catalog.cyrillic) catch &.{};
}

/// An OpenGorky project's texts of `f`: those on its blocks (one per number, `start` and
/// `end` 0), then the rows of its texts file `t` of numbers no block holds.
fn ogRows(app: *App, a: Allocator, t: []const u8, f: File) ![]const Row {
    var out: std.ArrayList(Row) = .empty;
    var seen: std.AutoHashMapUnmanaged(i32, void) = .empty;
    for (spotsOf(app)) |x| if (x.f == f) if (x.text) |text| if (!(try seen.getOrPut(a, x.id)).found_existing)
        try out.append(a, .{ .id = x.id, .text = text, .section = "", .start = 0, .end = 0 });
    for (try parseOg(a, t, f)) |r| if (!seen.contains(r.id)) try out.append(a, r);
    return out.items;
}

/// An OpenGorky texts file's rows of `f`: lines `<Call>(id = N, text = "…");` (`start`,
/// `end`: the string literal's bytes, quotes in). A row written otherwise is not listed.
fn parseOg(a: Allocator, t: []const u8, f: File) ![]const Row {
    var out: std.ArrayList(Row) = .empty;
    const head = try std.fmt.allocPrint(a, "{s}(id = ", .{ogCall(f)});
    // An interface text by its key (`UiText(key = miss, …)`, core/ui_text.zig): its number.
    const key_head = try std.fmt.allocPrint(a, "{s}(key = \"", .{ogCall(f)});
    var pos: usize = 0;
    while (pos < t.len) {
        const le = std.mem.indexOfScalarPos(u8, t, pos, '\n') orelse t.len;
        defer pos = @min(le + 1, t.len);
        const ls = pos + (t[pos..le].len - std.mem.trimStart(u8, t[pos..le], " \t").len);
        const by_key = std.mem.startsWith(u8, t[ls..le], key_head);
        if (!by_key and !std.mem.startsWith(u8, t[ls..le], head)) continue;
        var p = ls + (if (by_key) key_head.len else head.len);
        const ns = p;
        while (p < le and (std.ascii.isAlphanumeric(t[p]) or t[p] == '_' or t[p] == '-')) p += 1;
        const id = if (by_key) og.core.ui_text.id(og.core.ui_text.named(t[ns..p]) orelse continue) else std.fmt.parseInt(i32, t[ns..p], 10) catch continue;
        if (by_key) {
            if (p >= le or t[p] != '"') continue;
            p += 1;
        }
        if (!std.mem.startsWith(u8, t[p..le], ", text = \"")) continue;
        const qs = p + ", text = ".len;
        var q = qs + 1;
        while (q < le and t[q] != '"') : (q += 1) {
            if (t[q] == '\\') q += 1;
        }
        if (q >= le) continue;
        try out.append(a, .{ .id = id, .text = try lexer.stringValue(a, t[qs .. q + 1]), .section = "", .start = qs, .end = q + 1 });
    }
    return out.items;
}

/// Row `id` of `f` in an OpenGorky project says `text`: its literal replaced, else a new
/// line at the file's end (the file made when the project has none); one undo step.
fn setOg(app: *App, f: File, id: i32, text: []const u8) !void {
    const a = app.frame.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    try lexer.writeString(&w.writer, std.mem.trim(u8, text, " \t\r\n"));
    const lit = w.written();
    var lb: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "{s} {d}", .{ ogCall(f), id }) catch ogCall(f);
    // An interface text's key in place of its number (core/ui_text.zig).
    var kb: [48]u8 = undefined;
    const key = if (f == .strings) (if (og.core.ui_text.keyOf(id)) |k| std.fmt.bufPrint(&kb, "key = \"{t}\"", .{k}) catch null else null) else null;
    var ib: [32]u8 = undefined;
    const head = key orelse std.fmt.bufPrint(&ib, "id = {d}", .{id}) catch "";
    const fi = fileOf(app, f) orelse {
        const nt = try std.fmt.allocPrint(app.gpa, "{s}({s}, text = {s});\n", .{ ogCall(f), head, lit });
        errdefer app.gpa.free(nt);
        _ = try app.store.addNew(&.{.{ .archive = og_src, .entry = ogPath(f), .text = nt }});
        return;
    };
    const t = app.store.text(fi);
    for (try parseOg(a, t, f)) |r| if (r.id == id) {
        return app.store.replaceLabeled(fi, try std.mem.concat(app.gpa, u8, &.{ t[0..r.start], lit, t[r.end..] }), label);
    };
    const nl = if (t.len == 0 or t[t.len - 1] == '\n') "" else "\n";
    try app.store.replaceLabeled(fi, try std.fmt.allocPrint(app.gpa, "{s}{s}{s}({s}, text = {s});\n", .{ t, nl, ogCall(f), head, lit }), label);
}

fn parse(a: Allocator, t: []const u8, f: File, cyrillic: bool) ![]const Row {
    var out: std.ArrayList(Row) = .empty;
    var section: []const u8 = "";
    var pos: usize = 0;
    while (pos < t.len) {
        const le = std.mem.indexOfScalarPos(u8, t, pos, '\n') orelse t.len;
        const line = std.mem.trimEnd(u8, t[pos..le], "\r");
        const next = @min(le + 1, t.len);
        if (f == .strings) {
            if (std.mem.startsWith(u8, line, "//")) {
                section = try code.fromGame(a, std.mem.trim(u8, line[2..], " =/"), cyrillic);
            } else if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                if (std.fmt.parseInt(i32, std.mem.trim(u8, line[0..eq], " \t"), 10)) |id| {
                    try out.append(a, .{ .id = id, .text = try code.fromGame(a, line[eq + 1 ..], cyrillic), .section = section, .start = pos + eq + 1, .end = pos + line.len });
                } else |_| {}
            }
            pos = next;
            continue;
        }
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#")) section = try code.fromGame(a, std.mem.trim(u8, line, " \t#"), cyrillic);
        if (std.mem.startsWith(u8, line, f.key())) {
            const id = std.fmt.parseInt(i32, std.mem.trim(u8, line[f.key().len..], " \t"), 10) catch -1;
            // The description: the indented lines up to an empty line, a comment or a key.
            var text: std.ArrayList(u8) = .empty;
            var p = next;
            while (p < t.len) {
                const e = std.mem.indexOfScalarPos(u8, t, p, '\n') orelse t.len;
                const l = std.mem.trim(u8, t[p..e], " \t\r");
                if (l.len == 0 or l[0] == '#' or std.mem.startsWith(u8, l, f.key())) break;
                if (text.items.len > 0) try text.append(a, ' ');
                try text.appendSlice(a, l);
                p = @min(e + 1, t.len);
            }
            if (id >= 0) try out.append(a, .{ .id = id, .text = try code.fromGame(a, text.items, cyrillic), .section = section, .start = pos, .end = p });
            pos = p;
            continue;
        }
        pos = next;
    }
    return out.items;
}

/// The text of number `id` in `f` (null: none).
pub fn get(app: *App, a: Allocator, f: File, id: i32) ?[]const u8 {
    for (rows(app, a, f)) |r| if (r.id == id) return r.text;
    return null;
}

/// Number `id` of `f` says `text` (UTF-8): its row changed, or a new row; one undo step.
pub fn set(app: *App, f: File, id: i32, text: []const u8) !void {
    if (app.store.root != null) {
        // On the entities owning the number, else a row.
        if (try setOnBlocks(app, f, id, text)) return;
        return setOg(app, f, id, text);
    }
    const fi = fileOf(app, f) orelse return error.NoFile;
    const a = app.frame.allocator();
    const game = try code.toGame(a, std.mem.trim(u8, text, " \t\r\n"), app.catalog.cyrillic);
    if (game.len > max_line - 16) return error.TooLong;
    const t = app.store.text(fi);
    const rs = try parse(a, t, f, app.catalog.cyrillic);
    const row: ?Row = for (rs) |r| {
        if (r.id == id) break r;
    } else null;
    const piece = if (f == .strings) game else try std.fmt.allocPrint(a, "{s} {d}\r\n  {s}\r\n", .{ f.key(), id, game });
    const new = if (row) |r|
        try std.mem.concat(app.gpa, u8, &.{ t[0..r.start], piece, t[r.end..] })
    else
        try appended(app.gpa, t, f, id, game);
    errdefer app.gpa.free(new);
    var lb: [96]u8 = undefined;
    try app.store.replaceLabeled(fi, new, std.fmt.bufPrint(&lb, "{s} {d}", .{ f.entry(), id }) catch f.entry());
    // A character the edition's code page lacks became '?'.
    if (std.mem.count(u8, game, "?") > std.mem.count(u8, text, "?")) {
        app.setStatus(tx.st_text_lost, .{});
    } else if (unshown(app, game)) |b| app.setStatus(tx.st_text_unshown, .{try code.fromGame(a, &.{b}, app.catalog.cyrillic)});
}

/// The first byte of `game` the dialogue font has no glyph for (`02_dialog_1.fnt` and
/// the edition's language set over it, as edited): the game draws nothing there.
/// shortcut: the dialogue font stands for all; the system and small sets cover the same letters.
fn unshown(app: *App, game: []const u8) ?u8 {
    var nb: [48]u8 = undefined;
    var have: [256]bool = @splat(false);
    var any = false;
    // The edition's language: the core's texts (string.tab as composition read it).
    // shortcut: an unsaved edit of line 950 counts after the save; read the buffer if
    // editing the language line becomes a thing.
    for ([_]?[]const u8{ "02_dialog_1", og.formats.lang.setName(&nb, "02_dialog", og.core.entity.texts.language) }) |name| {
        var fb: [64]u8 = undefined;
        const fi = app.store.file(common_archive, std.fmt.bufPrint(&fb, "{s}.fnt", .{name orelse continue}) catch continue) catch continue;
        const font = og.formats.font.parse(app.store.text(fi)) catch continue;
        for (font.glyphs, &have) |g, *h| h.* = h.* or g != null;
        any = true;
    }
    if (!any) return null;
    for (game) |b| if (!have[b]) return b;
    return null;
}

/// `t` with a new row for `id` at its end (string.tab: in the editor's section).
fn appended(gpa: Allocator, t: []const u8, f: File, id: i32, game: []const u8) ![]u8 {
    const nl = if (t.len == 0 or std.mem.endsWith(u8, t, "\n")) "" else "\r\n";
    var ib: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&ib, "{d}", .{id}) catch "";
    if (f != .strings) return std.mem.concat(gpa, u8, &.{ t, nl, "\r\n", f.key(), " ", ids, "\r\n  ", game, "\r\n" });
    const head = if (std.mem.indexOf(u8, t, editor_section) == null) "\r\n//" ++ editor_section ++ "\r\n" else "";
    return std.mem.concat(gpa, u8, &.{ t, nl, head, ids, "=", game, "\r\n" });
}

const editor_section = "=========== EDITOR ===========";

/// A number no row of `f` has, from `from` on (new names: past the game's largest, 1081).
pub fn freeId(app: *App, f: File, from: i32) i32 {
    var id = from;
    const rs = rows(app, app.frame.allocator(), f);
    while (for (rs) |r| {
        if (r.id == id) break true;
    } else false) id += 1;
    return id;
}

/// Row `id` of `f` taken out (one undo step); an OpenGorky project's text on its blocks
/// taken off them.
pub fn remove(app: *App, f: File, id: i32) !void {
    if (app.store.root != null) if (try setOnBlocks(app, f, id, null)) return;
    return removeRow(app, f, id);
}

fn removeRow(app: *App, f: File, id: i32) !void {
    const fi = fileOf(app, f) orelse return error.NoFile;
    const a = app.frame.allocator();
    const t = app.store.text(fi);
    if (app.store.root != null) {
        // Its whole line.
        const r = for (try parseOg(a, t, f)) |r| {
            if (r.id == id) break r;
        } else return error.NotFound;
        const e = @min(t.len, (std.mem.indexOfScalarPos(u8, t, r.end, '\n') orelse t.len - 1) + 1);
        return app.store.replaceLabeled(fi, try std.mem.concat(app.gpa, u8, &.{ t[0..code.lineStart(t, r.start)], t[e..] }), null);
    }
    const rs = try parse(a, t, f, app.catalog.cyrillic);
    const r = for (rs) |r| {
        if (r.id == id) break r;
    } else return error.NotFound;
    // The whole line (string.tab) or the key line and its description.
    var s0 = if (f == .strings) code.lineStart(t, r.start) else r.start;
    var e = r.end;
    if (f == .strings) e = @min(t.len, (std.mem.indexOfScalarPos(u8, t, r.end, '\n') orelse t.len - 1) + 1);
    if (f != .strings and s0 > 0) {
        // Its `# comment` line just above goes with it.
        const ps = code.lineStart(t, s0 - 1);
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, t[ps..s0], " \t"), "#")) s0 = ps;
    }
    const new = try std.mem.concat(app.gpa, u8, &.{ t[0..s0], t[e..] });
    var lb: [96]u8 = undefined;
    try app.store.replaceLabeled(fi, new, std.fmt.bufPrint(&lb, "- {s} {d}", .{ f.entry(), id }) catch f.entry());
}

// ---------------------------------------------------------------- texts on the entities

/// A block of an OpenGorky project with its own `classic_id` (the texts on the
/// entities): the field of `f` it holds (`name` of `.strings`, `examine`
/// of `.items`, an area's of `.areas`), its text (null: none yet), where it is written.
const Spot = struct { f: File, id: i32, text: ?[]const u8, file: usize, ns: []const u8, names: []const []const u8 };

/// The project's spots as of Store revision `rev` (read again after any edit).
var spots: struct { rev: u64 = std.math.maxInt(u64), arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator), list: []const Spot = &.{} } = .{};

fn spotsOf(app: *App) []const Spot {
    if (spots.rev == app.store.rev) return spots.list;
    // The OG reader's numbers of the blocks without classic_id (collect).
    @import("entry_rules.zig").sync(app);
    _ = spots.arena.reset(.retain_capacity);
    const a = spots.arena.allocator();
    var out: std.ArrayList(Spot) = .empty;
    for (app.store.listing(a, og_src, null, true)) |p| {
        const fi = app.store.file(og_src, p) catch continue;
        var diag: og.script.ogs.parser.Diagnostic = .{};
        const u = og.script.ogs.parser.parse(a, a.dupe(u8, app.store.text(fi)) catch continue, p, &diag) catch continue;
        for (u.modules) |m| for (m.entities) |*e| collect(a, &out, fi, m.path, e, &.{}) catch {};
    }
    spots.list = out.items;
    spots.rev = app.store.rev;
    return spots.list;
}

fn collect(a: Allocator, out: *std.ArrayList(Spot), file: usize, ns: []const u8, e: *const og.script.ir.Entity, above: []const []const u8) !void {
    const names = try std.mem.concat(a, []const u8, &.{ above, &.{e.name} });
    for (e.children) |*c| try collect(a, out, file, ns, c, names);
    var id: ?i32 = null;
    var name: ?[]const u8 = null;
    var examine: ?[]const u8 = null;
    for (e.fields) |f| {
        if (std.mem.eql(u8, f.name, "classic_id")) id = og.core.schema.int(f.value);
        if (std.mem.eql(u8, f.name, "name")) name = og.core.schema.text(f.value);
        if (std.mem.eql(u8, f.name, "examine")) examine = og.core.schema.text(f.value);
    }
    // No classic_id (a converted project's): the OG reader's number of a block of no
    // archetype, by its path (`items::x`) or, a level's own, `<level>/<name>`.
    if (id == null and e.base.len == 0) {
        var kb: [256]u8 = undefined;
        const key = if (above.len == 0)
            (if (ns.len > 0) std.fmt.bufPrint(&kb, "{s}::{s}", .{ ns, e.name }) catch null else e.name)
        else if (above.len == 1) std.fmt.bufPrint(&kb, "{s}/{s}", .{ above[0], e.name }) catch null else null;
        if (key) |k| id = og.core.entity.idOf(k);
    }
    const n = id orelse return;
    try out.append(a, .{ .f = .strings, .id = n, .text = name, .file = file, .ns = ns, .names = names });
    try out.append(a, .{ .f = if (std.mem.eql(u8, e.kind, "area")) .areas else .items, .id = n, .text = examine, .file = file, .ns = ns, .names = names });
}

/// The field of `f` on a block.
fn fieldName(f: File) []const u8 {
    return if (f == .strings) "name" else "examine";
}

/// Number `id` of `f` said `text` on each block owning that classic_id (and its row, if
/// any, gone: the text is the entities' now); `text` null: taken out of the blocks that
/// hold it. False: no block owns it (holds it).
fn setOnBlocks(app: *App, f: File, id: i32, text: ?[]const u8) !bool {
    const a = app.frame.allocator();
    var any = false;
    for (spotsOf(app)) |s| if (s.f == f and s.id == id and (text != null or s.text != null)) {
        any = true;
        break;
    };
    if (!any) return false;
    var v: ?*og.script.ir.Expr = null;
    if (text) |t| {
        v = try a.create(og.script.ir.Expr);
        v.?.* = .{ .line = 0, .kind = .{ .lit = .{ .string = try a.dupe(u8, std.mem.trim(u8, t, " \t\r\n")) } } };
    }
    // Copied: the edits below read the spots again.
    const list = try a.dupe(Spot, spotsOf(app));
    app.store.group();
    defer app.store.endGroup("{s} {d}", .{ ogCall(f), id });
    for (list) |s| if (s.f == f and s.id == id and (text != null or s.text != null)) {
        var diag: og.script.ogs.parser.Diagnostic = .{};
        const t = try og.compose.og_write.editBlock(a, app.store.text(s.file), app.store.files.items[s.file].entry, s.ns, s.names, .{ .field = .{ .name = fieldName(f), .value = v } }, &diag);
        try app.store.replace(s.file, try app.gpa.dupe(u8, t));
    };
    if (text != null) if (fileOf(app, f)) |fi| for (try parseOg(a, app.store.text(fi), f)) |r| if (r.id == id) {
        try removeRow(app, f, id);
        break;
    };
    return true;
}

test parse {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const s = "//=== HEROES ===\r\n1=Sullivan\r\n2=Ovitz\r\n";
    const rs = try parse(arena.allocator(), s, .strings, false);
    try std.testing.expectEqual(2, rs.len);
    try std.testing.expectEqualStrings("Ovitz", rs[1].text);
    try std.testing.expectEqualStrings("HEROES", rs[1].section);
    try std.testing.expectEqualStrings("Ovitz", s[rs[1].start..rs[1].end]);
    const inf = "# Box\r\nITEM_EXAMINE: 75\r\n  Small\r\n  box.\r\n\r\n# Pistol\r\nITEM_EXAMINE: 49\r\n  Gun.\r\n";
    const ri = try parse(arena.allocator(), inf, .items, false);
    try std.testing.expectEqual(2, ri.len);
    try std.testing.expectEqualStrings("Small box.", ri[0].text);
    try std.testing.expectEqualStrings("Box", ri[0].section);
    try std.testing.expectEqual(@as(i32, 49), ri[1].id);
}

test parseOg {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = "UiText(id = 1, text = \"Открыть\");\n// x\n    UiText(id = 2000, text = \"a \\\"b\\\"\");\nExamine(id = 3, text = \"no\");\n";
    const rs = try parseOg(arena.allocator(), t, .strings);
    try std.testing.expectEqual(2, rs.len);
    try std.testing.expectEqualStrings("Открыть", rs[0].text);
    try std.testing.expectEqualStrings("a \"b\"", rs[1].text);
    try std.testing.expectEqualStrings("\"a \\\"b\\\"\"", t[rs[1].start..rs[1].end]);
    try std.testing.expectEqual(@as(i32, 3), (try parseOg(arena.allocator(), t, .items))[0].id);
}
