//! The one writer of rules rows (og.rules) into an OpenGorky project's rules files
//! (common/rules.dat `rules\<Row.file>.ss`): a row is put by its key (the row of that key
//! replaced where it stands, else appended) or dropped by it, one undo step per file, and
//! the editor's rules in force follow (entry_rules.sync). The key an edit for an entity
//! writes is `ownKey`'s; rows made an entity's own from another's ("Make own rules",
//! copies) are keyed by rules_text.cloneRows and put here too: no key is written twice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const code = @import("code.zig");
const entry_rules = @import("entry_rules.zig");
const og = @import("opengorky");
const App = @import("app.zig").App;
const tx = @import("text.zig");
const rules = og.rules;
const rules_text = og.loaders.rules_text;
const codec = og.loaders.codec;

/// `Row`'s rules file in an OpenGorky project's `src/` (`rules/attacks.ogs`, store.og_src;
/// the OG writer's layout, compose/og/write.zig).
pub fn entryOf(comptime Row: type) []const u8 {
    return comptime rules.ogPath(Row.file);
}

/// Row `r`'s rules file in `src/` (rules.rowFile: the game-wide AI profile's settings.ogs).
pub fn entryOfRow(comptime Row: type, r: Row) []const u8 {
    return if (std.mem.eql(u8, rules.rowFile(Row, r), "settings")) dir ++ "settings.ogs" else entryOf(Row);
}

/// The rules files' folder under `src/`.
pub const dir = "rules/";
const og_src = @import("store.zig").og_src;

/// Byte span in `text` of the row with `row`'s key: its lines (a `//` note after it on its
/// last line too), or from its call through its `;` (its line's end too when nothing
/// follows) when it shares its line; null when none. Strings and comments are no part of the rows' text (code.skipOver).
/// A keyless row (`Windows`, `MainMenu`…) is the file's last: the one in force (modules.zig `last`).
pub fn span(a: Allocator, comptime Row: type, text: []const u8, row: Row) ?[2]usize {
    var diag: og.script.ogs.parser.Diagnostic = .{};
    var line: u32 = 0;
    var nth: usize = 0;
    var found: ?[2]usize = null;
    for (codec.parseRows(a, text, &diag) orelse return null) |ex| {
        if (!std.ascii.eqlIgnoreCase(ex.kind.call.text, Row.call)) continue;
        // Which of its line's `Row.call`s it is.
        nth = if (ex.line == line) nth + 1 else 0;
        line = ex.line;
        // Read over `row`: keys come from the call only.
        const got = codec.read(Row, a, ex.kind.call, row) catch continue;
        if (!codec.sameKey(Row, got, row)) continue;
        found = callSpan(text, ex.line, Row.call, nth);
        if (Row.keys.len > 0) return found;
    }
    return found;
}

/// The span (`span`) of call `name`'s `nth` statement on line `line` (1-based).
fn callSpan(t: []const u8, line: u32, name: []const u8, nth: usize) ?[2]usize {
    var ls: usize = 0;
    for (1..line) |_| ls = (std.mem.indexOfScalarPos(u8, t, ls, '\n') orelse return null) + 1;
    const le = code.lineEnd(t, ls);
    var s: code.Scan = .{};
    var n = nth;
    var k = ls;
    while (std.ascii.findIgnoreCasePos(t[0..le], k, name)) |at| : (k = at + 1) {
        if (at > 0 and code.isIdent(t[at - 1])) continue;
        var p = at + name.len;
        while (p < le and (t[p] == ' ' or t[p] == '\t')) p += 1;
        if (p >= le or t[p] != '(') continue;
        s.to(t, at);
        if (s.in != .code) continue;
        if (n > 0) {
            n -= 1;
            continue;
        }
        var e = (code.argsEnd(t, p) orelse return null) + 1;
        while (e < t.len and (t[e] == ' ' or t[e] == '\t')) e += 1;
        if (e >= t.len or t[e] != ';') return null;
        e += 1;
        const rest = std.mem.trim(u8, t[e..code.lineEnd(t, e)], " \t");
        const alone = std.mem.trim(u8, t[ls..at], " \t").len == 0;
        if (alone and (rest.len == 0 or std.mem.startsWith(u8, rest, "//"))) {
            const nl = std.mem.indexOfScalarPos(u8, t, e, '\n') orelse t.len;
            return .{ ls, @min(t.len, nl + 1) };
        }
        return .{ if (alone) ls else at, e };
    }
    return null;
}

/// `text` with `row` put by its key: the row of its key replaced where it stands, else
/// appended (its note not written; `gpa` owns the result).
pub fn putText(a: Allocator, gpa: Allocator, comptime Row: type, text: []const u8, row: Row) ![]u8 {
    return putTextAt(a, gpa, Row, text, row, row);
}

/// `putText` with `row` in place of the row of `at`'s key (a row re-keyed where it stands).
pub fn putTextAt(a: Allocator, gpa: Allocator, comptime Row: type, text: []const u8, at: Row, row: Row) ![]u8 {
    var r = row;
    if (@hasField(Row, "note")) r.note = "";
    var aw: std.Io.Writer.Allocating = .init(a);
    try codec.write(Row, &aw.writer, r);
    // As the OG writer prints it: too long a row on several lines.
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const line = if (codec.parseRows(a, aw.written(), &diag)) |xs| if (xs.len == 1) blk: {
        var pw: std.Io.Writer.Allocating = .init(a);
        // Its note's `// …` lines above it as written (comments are no part of the row).
        const raw = aw.written();
        var body: usize = 0;
        while (std.mem.startsWith(u8, raw[body..], "//")) body = (std.mem.indexOfScalarPos(u8, raw, body, '\n') orelse break) + 1;
        pw.writer.writeAll(raw[0..body]) catch break :blk raw;
        og.script.ogs.print.row(&pw.writer, xs[0]) catch break :blk raw;
        break :blk pw.written();
    } else aw.written() else aw.written();
    return if (span(a, Row, text, at)) |sp|
        // In its place on a line it shares: without the line end.
        try std.mem.concat(gpa, u8, &.{ text[0..sp[0]], if (text[sp[1] - 1] == '\n') line else line[0 .. line.len - 1], text[sp[1]..] })
    else
        try std.mem.concat(gpa, u8, &.{ text, if (text.len > 0 and text[text.len - 1] != '\n') "\n" else "", line });
}

/// Row `row` in its rules file by its key (one undo step; the file made when missing).
pub fn put(app: *App, comptime Row: type, row: Row) !void {
    return putAt(app, Row, row, row);
}

/// `put` with `row` in place of the row of `at`'s key (re-keyed where it stands).
pub fn putAt(app: *App, comptime Row: type, at: Row, row: Row) !void {
    if (try putSetting(app, Row, at, row)) return entry_rules.sync(app);
    try putIn(app, rules.rowFile(Row, at), try putTextAt(app.frame.allocator(), app.gpa, Row, if (app.store.file(og_src, entryOfRow(Row, at))) |f| app.store.text(f) else |_| "", at, row));
    entry_rules.sync(app);
}

/// The row of `row`'s key is in its rules file (the project's own).
pub fn has(app: *App, comptime Row: type, row: Row) bool {
    const f = app.store.file(og_src, entryOfRow(Row, row)) catch return false;
    return span(app.frame.allocator(), Row, app.store.text(f), row) != null;
}

/// Rules file `name` (`attacks`) made `text` (taken): one undo step, made when missing.
pub fn putIn(app: *App, name: []const u8, text: []u8) !void {
    const entry = rules.ogPath(name);
    if (app.store.file(og_src, entry)) |f| return app.store.replace(f, text) else |_| {}
    defer app.gpa.free(text);
    _ = try app.store.addNew(&.{.{ .archive = og_src, .entry = entry, .text = try app.gpa.dupe(u8, text) }});
}

/// The row of `row`'s key out of its rules file (one undo step); false: none there.
pub fn drop(app: *App, comptime Row: type, row: Row) !bool {
    if (try putSetting(app, Row, row, null)) {
        entry_rules.sync(app);
        return true;
    }
    const f = app.store.file(og_src, entryOfRow(Row, row)) catch return false;
    const old = app.store.text(f);
    const sp = span(app.frame.allocator(), Row, old, row) orelse return false;
    try app.store.replace(f, try std.mem.concat(app.gpa, u8, &.{ old[0..sp[0]], old[sp[1]..] }));
    entry_rules.sync(app);
    return true;
}

/// OpenGorky: a Value's, Setting's or ExpLevel's row is a field of the project's `settings`
/// block in rules/settings.ogs (rules_text settingsRows): `at`'s made `row`'s, or (null)
/// dropped. False: not such a row, or no such block (its row is then put as any).
fn putSetting(app: *App, comptime Row: type, at: Row, row: ?Row) !bool {
    if (Row != rules.Value and Row != rules.Setting and Row != rules.ExpLevel) return false;
    if (!app.ogLayout()) return false;
    const f = app.store.file(og_src, dir ++ "settings.ogs") catch return false;
    const mo = @import("model_og.zig");
    const a = app.frame.allocator();
    if (mo.blockOf(app, a, f) == null) return false;
    var w: std.Io.Writer.Allocating = .init(a);
    if (Row == rules.ExpLevel) {
        // The whole list: each level's exp in order, this one's changed (added, dropped).
        try w.writer.writeAll("[");
        var n: usize = 0;
        for (rules.active.exp_levels) |r| {
            if (r.level == at.level and row == null) continue;
            const v = if (r.level == at.level) row.?.exp else r.exp;
            try w.writer.print("{s}{d}", .{ if (n > 0) ", " else "", v });
            n += 1;
        }
        if (row) |r| if (at.level == rules.active.exp_levels.len) try w.writer.print("{s}{d}", .{ if (n > 0) ", " else "", r.exp });
        try w.writer.writeAll("]");
        try mo.set(app, f, &.{"exp_levels"}, w.written());
        return true;
    }
    const name = if (Row == rules.Value) @tagName(at.name) else at.name;
    const r = row orelse {
        mo.edit(app, f, .{ .field = .{ .name = name, .value = null } }) catch |err| if (err != error.NoSuchBlock) return err;
        return true;
    };
    if (Row == rules.Value) try w.writer.print("{d}", .{r.value}) else if (r.int) |x| try w.writer.print("{d}", .{x}) else if (r.float) |x| {
        // A float as one (`1.0`): its kind is the setting's.
        try w.writer.print("{d}", .{x});
        if (std.mem.indexOfAny(u8, w.written(), ".en") == null) try w.writer.writeAll(".0");
    } else if (r.rgba) |c| try w.writer.print("[{d}, {d}, {d}]", .{ c[0], c[1], c[2] }) else return false;
    try mo.set(app, f, &.{name}, w.written());
    return true;
}

/// `put` of `base` with field `field` made `text` (as the rules file writes it).
pub fn putField(app: *App, comptime Row: type, base: Row, field: []const u8, text: []const u8) !void {
    try put(app, Row, try rules_text.withField(app.frame.allocator(), Row, base, field, text, &app.rule_why));
}

/// `put` in an OpenGorky project, said in the status line (the row as written).
pub fn putSaid(app: *App, comptime Row: type, row: Row) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    try put(app, Row, row);
    app.setStatus(tx.st_rules_row, .{rowText(app.frame.allocator(), Row, row)});
}

/// `cur` (the row in force, else a new one) keyed for `who` (ownKey) and written with
/// `edit`'s change.
pub fn putOwn(app: *App, comptime Row: type, comptime key: []const u8, cur: Row, who: rules.Who, comptime edit: anytype, arg: anytype) !void {
    var r = ownKey(app, Row, key, cur, who);
    try edit(&r, arg);
    try put(app, Row, r);
    app.setStatus(tx.st_rule_set, .{ Row.call, if (who.class.len > 0) who.class else "?" });
}

/// Field `field` of `cur` made `text` for `who` (keyed as `putOwn`).
pub fn setOwn(app: *App, comptime Row: type, comptime key: []const u8, cur: Row, who: rules.Who, field: []const u8, text: []const u8) !void {
    try putField(app, Row, ownKey(app, Row, key, cur, who), field, text);
    app.setStatus(tx.st_rule_set, .{ field, if (who.class.len > 0) who.class else "?" });
}

/// A value of `what` that did not write, in the status line (why a row does not read).
pub fn failed(app: *App, what: []const u8, err: anyerror) void {
    app.setStatus(tx.st_rule_bad, .{ what, if (err == error.BadRow) @import("rulescheck.zig").why(app.rule_why) else @errorName(err) });
}

/// The row of `row`'s key in table `table` of the rules in force, if any.
pub fn inForce(comptime Row: type, comptime table: []const u8, row: Row) ?Row {
    for (@field(rules.active.*, table)) |r| if (codec.sameKey(Row, r, row)) return r;
    return null;
}

/// The row of `table` whose key `key` names `who` best (as rules.zig looks rows up).
pub fn bestFor(comptime Row: type, comptime table: []const u8, comptime key: []const u8, who: rules.Who) ?Row {
    var best: ?Row = null;
    var score: u2 = 0;
    for (@field(rules.active.*, table)) |r| if (rules.keyMatch(r, key, who)) |m| if (m > score) {
        best = r;
        score = m;
    };
    return best;
}

/// `row` is the game's own (a built-in row of its key with its fields; its note and
/// `give` aside).
pub fn isBuiltin(comptime Row: type, comptime table: []const u8, row: Row) bool {
    for (@field(rules.builtin, table)) |r| if (codec.sameKey(Row, r, row)) {
        var x = r;
        if (@hasField(Row, "note")) x.note = row.note;
        if (@hasField(Row, "give")) x.give = row.give;
        return codec.same(Row, x, row);
    };
    return false;
}

/// `row` as the rules file writes it (without its note and `;`).
pub fn rowText(a: Allocator, comptime Row: type, row: Row) []const u8 {
    var r = row;
    if (@hasField(Row, "note")) r.note = "";
    var aw: std.Io.Writer.Allocating = .init(a);
    codec.write(Row, &aw.writer, r) catch return "";
    return std.mem.trimEnd(u8, aw.written(), ";\n");
}

/// Field `name` of `row` as the rules files write it (a key by class: the class).
pub fn fieldText(a: Allocator, comptime Row: type, row: Row, comptime name: []const u8) []const u8 {
    if (@hasField(Row, name ++ "_class")) if (@field(row, name ++ "_class").len > 0) return @field(row, name ++ "_class");
    var aw: std.Io.Writer.Allocating = .init(a);
    const v = @field(row, name);
    const T = @TypeOf(v);
    if (@typeInfo(T) == .optional and v == null) return "";
    codec.writeValue(T, &aw.writer, v) catch return "";
    return std.mem.trim(u8, aw.written(), "\"");
}

/// The modules' table `table` (core/modules.zig builtin_tables) has a row of `row`'s key:
/// dropping the project's row brings that one back, not none.
pub fn builtinKey(comptime Row: type, comptime table: []const u8, row: Row) bool {
    for (@field(og.core.modules.builtin_tables, table)) |r| if (codec.sameKey(Row, r, row)) return true;
    return false;
}

/// `cur` (the row in force for `who`, its fields as they are to be written) keyed for
/// writing by entity key `key`: by its own key when that row is the project's and names
/// `who` alone (edited in place: a converted `fighter = 102` row stays by classic_id, no
/// second row beside it); else by `who`: the placed fighter (`who.obj`), its classic_id when
/// no other class has it (as the converted files key rows), else its class.
pub fn ownKey(app: *App, comptime Row: type, comptime key: []const u8, cur: Row, who: rules.Who) Row {
    const kc = key ++ "_class";
    const by: []const u8 = @field(cur, kc);
    // OpenGorky: an archetype is named by its path, never its number (no
    // classic_id in a project); Classic: by number where only it has it.
    const by_path = app.ogLayout() and std.mem.indexOf(u8, who.class, "::") != null;
    const unique = !by_path and who.id > 0 and idOnlyOf(app, who);
    const names_who = if (who.obj.len > 0) std.ascii.eqlIgnoreCase(by, who.obj) else if (by.len > 0) std.ascii.eqlIgnoreCase(by, who.class) else unique and @field(cur, key) == who.id;
    if (names_who) if (app.store.file(og_src, entryOfRow(Row, cur))) |f| {
        if (span(app.frame.allocator(), Row, app.store.text(f), cur) != null) return cur;
    } else |_| {};
    var r = cur;
    @field(r, key) = 0;
    @field(r, kc) = "";
    if (who.obj.len > 0) @field(r, kc) = who.obj else if (unique) @field(r, key) = who.id else @field(r, kc) = who.class;
    return r;
}

/// No entry of another class has `who`'s classic_id.
pub fn idOnlyOf(app: *App, who: rules.Who) bool {
    for (app.catalog.entries.items) |e| if (e.name_id == who.id and !std.ascii.eqlIgnoreCase(entry_rules.classOf(e), who.class)) return false;
    return true;
}

test putText {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const R = rules.Resist;
    // By classic_id, by class, both: each key's own row replaced, comments and the other kept.
    const text =
        \\// Sphinx (a ");" here, and Resist(fighter = 102);)
        \\Resist(fighter = 102, armor = -1); // note
        \\Resist(fighter = "ft_sphinx", resist = "fire", armor = -1);
        \\
    ;
    const by_id = try putText(a, a, R, text, .{ .fighter = 102, .armor = -2 });
    try std.testing.expectEqualStrings(
        \\// Sphinx (a ");" here, and Resist(fighter = 102);)
        \\Resist(fighter = 102, armor = -2);
        \\Resist(fighter = "ft_sphinx", resist = "fire", armor = -1);
        \\
    , by_id);
    const by_class = try putText(a, a, R, by_id, .{ .fighter = 0, .fighter_class = "FT_SPHINX", .armor = -3 });
    try std.testing.expectEqualStrings(
        \\// Sphinx (a ");" here, and Resist(fighter = 102);)
        \\Resist(fighter = 102, armor = -2);
        \\Resist(fighter = "FT_SPHINX", armor = -3);
        \\
    , by_class);
    // Twice the same: no second row; a new key appended.
    try std.testing.expectEqualStrings(by_class, try putText(a, a, R, by_class, .{ .fighter = 0, .fighter_class = "FT_SPHINX", .armor = -3 }));
    try std.testing.expect(std.mem.endsWith(u8, try putText(a, a, R, "Resist(fighter = 1);", .{ .fighter = 7 }), "Resist(fighter = 1);\nResist(fighter = 7);\n"));
    // Re-keyed in place: the classic_id row becomes the class row (no second row).
    try std.testing.expectEqualStrings("Resist(fighter = \"ft_x\", armor = -2);\nResist(fighter = 3);\n", try putTextAt(a, a, R, "Resist(fighter = 1, armor = -2);\nResist(fighter = 3);\n", .{ .fighter = 1 }, .{ .fighter = 0, .fighter_class = "ft_x", .armor = -2 }));
    // Two on a line: the second's own text; a `);` in a string is no end.
    const K = rules.KillIcon;
    const two = "KillIcon(fighter = 1, icon = \"a);\"); KillIcon(fighter = 2, icon = \"b\");\nKillIcon(fighter = 3, icon = \"c\");\n";
    try std.testing.expectEqualStrings("KillIcon(fighter = 1, icon = \"a);\"); KillIcon(fighter = 2, icon = \"x\");\nKillIcon(fighter = 3, icon = \"c\");\n", try putText(a, a, K, two, .{ .fighter = 2, .icon = "x" }));
    try std.testing.expectEqualStrings("KillIcon(fighter = 1, icon = \"y\"); KillIcon(fighter = 2, icon = \"b\");\nKillIcon(fighter = 3, icon = \"c\");\n", try putText(a, a, K, two, .{ .fighter = 1, .icon = "y" }));
}

test "putText: the rules pages' rows (ExpLevel, Value, Action) round-trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try putText(a, a, rules.ExpLevel, "ExpLevel(level = 5, exp = 1385);\n", .{ .level = 5, .exp = 1500 });
    t = try putText(a, a, rules.ExpLevel, t, .{ .level = 20, .exp = 17909760 });
    t = try putText(a, a, rules.Value, t, .{ .name = .idle_ticks, .value = 900 });
    t = try putText(a, a, rules.Action, t, .{ .name = "Pray", .classic_id = 19, .text = 578, .kind = .take, .walk_click = true });
    t = try putText(a, a, rules.Action, t, .{ .name = "Pray", .classic_id = 20, .text = 578 });
    try std.testing.expectEqualStrings(
        \\ExpLevel(level = 5, exp = 1500);
        \\ExpLevel(level = 20, exp = 17909760);
        \\Value(name = "idle_ticks", value = 900);
        \\Action(name = "Pray", classic_id = 20, text = 578);
        \\
    , t);
    // Dropped by its key (rules_rows.drop's span): the others kept.
    const sp = span(a, rules.Action, t, .{ .name = "Pray", .classic_id = 0 }).?;
    try std.testing.expect(std.mem.endsWith(u8, t[0..sp[0]], "value = 900);\n") and sp[1] == t.len);
}

test "putText: a keyless row is the file's last (the one in force)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const M = og.core.ui.Music;
    const two = "ExeMusic(level_up = \"a\", battle_enter = \"b\");\nExeMusic(level_up = \"c\", battle_enter = \"d\");\n";
    // The last row is replaced (its other fields written out too), the first kept.
    var m = og.core.modules.builtin_tables.music[0];
    m.level_up = "x";
    m.battle_enter = "d";
    const out = try putText(a, a, M, two, m);
    // Too long a row for a line: a field a line (the OG writer's form).
    try std.testing.expect(std.mem.startsWith(u8, out, "ExeMusic(level_up = \"a\", battle_enter = \"b\");\nExeMusic(\n    level_up = \"x\",\n    battle_enter = \"d\",\n"));
    try std.testing.expect(std.mem.endsWith(u8, out, ");\n"));
    const sp = span(a, M, two, .{ .level_up = "", .battle_enter = "" }).?;
    try std.testing.expectEqual(two.len, sp[1]);
}

test builtinKey {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const S = og.core.behaviour.Strike;
    // Headnail's saws (118) are the exe's: its row kept empty; a project's special dropped whole.
    try std.testing.expect(builtinKey(S, "strikes", .{ .special = 118, .spins = &.{} }));
    try std.testing.expect(!builtinKey(S, "strikes", .{ .special = 4242, .spins = &.{} }));
    const t = try putText(a, a, S, "FighterStrike(special = 118, spins = list());\n", .{ .special = 4242, .spins = &.{.{ .link = "saw", .at = .{ .c = 3 } }} });
    const sp = span(a, S, t, .{ .special = 4242, .spins = &.{} }).?;
    try std.testing.expectEqualStrings("FighterStrike(special = 118, spins = list());\n", t[0..sp[0]]);
    try std.testing.expectEqual(t.len, sp[1]);
    // The panel: a control is the exe's, a fifth portrait slot the project's.
    const P = og.core.ui.Place;
    try std.testing.expect(builtinKey(P, "places", .{ .button = .stats, .rect = @splat(0) }));
    try std.testing.expect(!builtinKey(P, "places", .{ .button = .portrait(5), .rect = @splat(0) }));
}
