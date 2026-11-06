//! Rules as text (composition): the `rules\\*.ss` files of an OpenGorky project read over
//! the core's built-in tables (`apply`, `reload`), the tables in force written back
//! (`dumpTexts`), and the editor's row edits (`withField`, `rowFor`, `cloneRows`). The
//! files are OGS calls (codec.zig; script/ogs/parser.zig reads them to IR):
//! `Resist(fighter = 125, …);`. A row with a built-in
//! row's key overrides only the fields it writes (the rest stay built-in, so files from
//! older dumps keep newer fields), new keys add, whatever the files lack stays built-in.
//! The same for the core modules' records (effects, fighter classes, AI scorings, the
//! interface: core/modules.zig `Tables`), put in force with the rules.
//! The core (src/rules.zig, core/modules.zig) keeps only the tables and their lookups.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const script = @import("../script.zig");
const rules = @import("../rules.zig");
const modules = @import("../core.zig").modules;
const codec = @import("codec.zig");

/// The archive the rules files (`rules\<name>.ss`: rules-dump, the editor's OG layout)
/// are entries of and their folder there.
pub const archive_path = "common/rules.dat";
pub const entry_dir = "rules\\";

pub const Text = struct { name: []const u8, data: []const u8 };

pub const Match = enum { class, id };

/// Whether rules file call `c` is a row naming `w` (by its class or its classic_id); null:
/// not, or not a row.
pub fn rowFor(a: Allocator, c: script.ir.Call, w: rules.Who) ?Match {
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(rules.Set, f)).pointer.child;
        if (std.ascii.eqlIgnoreCase(c.text, Row.call)) {
            const row = codec.read(Row, a, c, null) catch return null;
            return if (rules.rowMatch(Row, row, w)) |m| (if (m == 2) .class else .id) else null;
        }
    }
    return null;
}

/// The rows in force naming `from`, made `to`'s (a class key where the table has one,
/// else `to.id`), each given to `sink.row(Row, row)` (`rules.files` order); classic_id rows
/// first, so the class ones (given after) win. `only_id`: without `from`'s class rows.
pub fn cloneRows(from: rules.Who, to: rules.Who, only_id: bool, sink: anytype) !void {
    for ([_]u2{ 1, 2 }) |pass| {
        if (pass == 2 and only_id) break;
        inline for (@typeInfo(rules.Set).@"struct".field_names) |f| {
            const Row = @typeInfo(@FieldType(rules.Set, f)).pointer.child;
            for (@field(rules.active.*, f)) |r| if (rules.rowMatch(Row, r, from) == pass) {
                var row = r;
                inline for (rules.entity_keys) |key| if (@hasField(Row, key)) {
                    const named = if (@hasField(Row, key ++ "_class")) rules.keyMatch(r, key, from) != null else @field(r, key) == from.id;
                    if (named) {
                        @field(row, key) = to.id;
                        if (@hasField(Row, key ++ "_class") and to.class.len > 0) {
                            @field(row, key) = 0;
                            @field(row, key ++ "_class") = to.class;
                        }
                    }
                };
                try sink.row(Row, row);
            };
        }
    }
}

/// `base` with field `field` set to `text` (a value as the rules files write it; a bare
/// word for a string field is quoted): the call `Name(<base>, field = text)` read back;
/// error.BadRow's reason in `reason`.
pub fn withField(a: Allocator, comptime Row: type, base: Row, field: []const u8, text: []const u8, reason: *codec.Why) (codec.Error || Io.Writer.Error)!Row {
    var b = base;
    if (@hasField(Row, "note")) b.note = "";
    var aw: Io.Writer.Allocating = .init(a);
    try codec.write(Row, &aw.writer, b);
    const call = std.mem.trimEnd(u8, aw.written(), ";\n");
    const t = std.mem.trim(u8, text, " ");
    // A key naming a class (`fighter = ft_wasp`) is a string; a classic_id a number.
    const class_key = isClassKey(Row, field) and (std.fmt.parseInt(i32, t, 10) catch null) == null;
    const quote = (isString(Row, field) or class_key) and !std.mem.startsWith(u8, t, "\"");
    const src = try std.fmt.allocPrint(a, "{s}, {s} = {s}{s}{s});", .{ call[0 .. call.len - 1], field, if (quote) "\"" else "", std.mem.trim(u8, text, " "), if (quote) "\"" else "" });
    return codec.readRow(Row, a, codec.oneRow(a, src) orelse return error.BadRow, null, reason);
}

fn isClassKey(comptime Row: type, field: []const u8) bool {
    inline for (@typeInfo(Row).@"struct".field_names) |n| if (std.mem.eql(u8, n, field)) return @hasField(Row, n ++ "_class");
    return false;
}

fn isString(comptime Row: type, field: []const u8) bool {
    inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |n, T| if (std.mem.eql(u8, n, field)) {
        const U = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        return U == []const u8 or @typeInfo(U) == .@"enum";
    };
    return false;
}

/// Why rules row call `c` would not be read as `apply` reads it (null: it would): a
/// named argument whose field or value does not read (`arg`: its index in `c.named`; a
/// positional one: `positional`), else the row as a whole
/// (over a built-in row with its keys, else alone: a field without a default missing).
/// shortcut: rows the files add before are no bases here (a row overriding one only
/// another file adds is reported as missing fields); upgrade if mods do that.
const RowProblem = struct { why: codec.Why, arg: ?usize = null, positional: bool = false };

pub fn rowProblem(a: Allocator, c: script.ir.Call) ?RowProblem {
    inline for (.{ rules.Set, modules.Tables }, .{ rules.builtin, modules.builtin_tables }) |S, b| inline for (@typeInfo(S).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(S, f)).pointer.child;
        if (std.ascii.eqlIgnoreCase(c.text, Row.call)) {
            if (c.args.len > 0) return .{ .why = .name_value, .positional = true };
            var why: codec.Why = .not_value;
            for (c.named, 0..) |arg, k| codec.readArg(Row, a, arg, &why) catch |err| return if (err == error.BadRow) .{ .why = why, .arg = k } else null;
            for (@field(b, f)) |r| {
                const over = codec.readRow(Row, a, c, r, &why) catch continue;
                if (codec.sameKey(Row, r, over)) return null;
            }
            _ = codec.readRow(Row, a, c, null, &why) catch |err| return if (err == error.BadRow) .{ .why = why } else null;
            return null;
        }
    };
    return null;
}

test rowProblem {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = struct {
        fn f(al: Allocator, src: []const u8) script.ir.Call {
            return codec.oneRow(al, src).?;
        }
    }.f;
    try std.testing.expect(rowProblem(a, one(a, "AiProfile(class = 1, scoring = \"garcia\");")) == null);
    try std.testing.expectEqual(0, rowProblem(a, one(a, "AiProfile(clas = 1);")).?.arg.?);
    // A scoring is a name of the data (editor/rulescheck.zig checks it against the AiScoring rows).
    try std.testing.expect(rowProblem(a, one(a, "AiProfile(class = 1, scoring = \"foo\");")) == null);
    try std.testing.expectEqual(codec.Why.number, rowProblem(a, one(a, "AiProfile(class = \"x\");")).?.why);
    // A new attack row must write its animation; one over a built-in row need not.
    try std.testing.expectEqual(codec.Why.missing, rowProblem(a, one(a, "MonsterAttack(fighter = 999, weapon = 0);")).?.why);
    try std.testing.expect(rowProblem(a, one(a, "AiProfile(1);")).?.positional);
}

/// Where field `field` of row call `c` came from when its built-in row (the same keys)
/// follows adjust there: that value as the built-ins write it (`adjust("name", d) + n`)
/// and its first name; null otherwise (the editor's hover over a converted number).
pub fn adjustOrigin(a: Allocator, c: script.ir.Call, field: []const u8) ?struct { text: []const u8, name: []const u8 } {
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(rules.Set, f)).pointer.child;
        if (std.ascii.eqlIgnoreCase(c.text, Row.call)) {
            for (@field(rules.builtin, f)) |r| {
                const over = codec.read(Row, a, c, r) catch continue;
                if (!codec.sameKey(Row, r, over)) continue;
                inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |n, T| if (T == rules.rows.Num or T == ?rules.rows.Num) {
                    const v: ?rules.rows.Num = @field(r, n);
                    if (std.mem.eql(u8, n, field)) if (v) |x| if (x.a) |adj| {
                        var aw: Io.Writer.Allocating = .init(a);
                        codec.writeValueAs(rules.rows.Num, &aw.writer, x, .keep) catch return null;
                        return .{ .text = aw.written(), .name = adj.name };
                    };
                };
                return null;
            }
            return null;
        }
    }
    return null;
}

test adjustOrigin {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = for (rules.builtin.monster_attacks) |x| {
        if (x.hit_delay.a != null and x.fighter_class.len == 0) break x;
    } else unreachable;
    const src = try std.fmt.allocPrint(a, "MonsterAttack(fighter = {d}, weapon = {d}, hit_delay = 3);", .{ r.fighter, r.weapon });
    const c = codec.oneRow(a, src).?;
    try std.testing.expectEqualStrings(r.hit_delay.a.?.name, adjustOrigin(a, c, "hit_delay").?.name);
    try std.testing.expect(std.mem.startsWith(u8, adjustOrigin(a, c, "hit_delay").?.text, "adjust(\""));
    try std.testing.expect(adjustOrigin(a, c, "anim") == null);
}

/// Every call rules files make (the tables' rows and `adjust`), for completion.
pub const calls: []const []const u8 = blk: {
    var out: []const []const u8 = &.{"adjust"};
    for (@typeInfo(rules.Set).@"struct".field_names) |f| out = out ++ &[_][]const u8{@typeInfo(@FieldType(rules.Set, f)).pointer.child.call};
    for (@typeInfo(modules.Tables).@"struct".field_names) |f| out = out ++ &[_][]const u8{@typeInfo(@FieldType(modules.Tables, f)).pointer.child.call};
    break :blk out;
};

// ---------------------------------------------------------------- dump

/// Rules file `name` (one of `files`) of the rules in force.
fn dump(w: *Io.Writer, name: []const u8, mode: codec.Mode) (Allocator.Error || Io.Writer.Error)!void {
    try w.print(
        \\// OpenGorky rules: {s}.ss. The exe keeps these in its code; the port reads them
        \\// from here in an OpenGorky project. A row with a built-in row's key overrides only
        \\// the fields it writes, the rest stay built-in (to clear one, write it: auto_open = 0);
        \\// a missing row stays built-in. Calls `Name(field = value, ...);`, `//` comments.
        \\// A fighter, weapon, hero, item or healer key may name a class instead of a classic_id
        \\// (every table with such a key): fighter = "ft_wasp" (the ft_ script a level's fighter includes),
        \\// weapon = "cw_laser" (wp_/cw_ scripts), hero = "ovitz". A class row beats the
        \\// classic_id one: a copy behaves on its own, its classic_id only names its texts.
        \\
    , .{name});
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(rules.Set, f)).pointer.child;
        if (std.mem.eql(u8, Row.file, name)) {
            try w.writeAll("\n");
            var it = std.mem.splitScalar(u8, Row.doc, '\n');
            while (it.next()) |l| try w.print("// {s}\n", .{l});
            // The tuning values in force (Classic: adjust.kdt's, in its order).
            if (Row == rules.Setting) {
                var vs = rules.adjust.values.iterator();
                while (vs.next()) |e| try codec.writeAs(Row, w, .of(e.key_ptr.*, e.value_ptr.*), mode);
            } else for (@field(rules.active.*, f)) |r| {
                // Rows read from files lost their comments: the built-in one's.
                var row = r;
                if (row.note.len == 0) for (@field(rules.builtin, f)) |x| if (codec.sameKey(Row, x, r)) {
                    row.note = x.note;
                    break;
                };
                try codec.writeAs(Row, w, row, mode);
            }
        }
    }
    // The core modules' records of this file (no comments of their own).
    const t = modules.tables();
    inline for (@typeInfo(modules.Tables).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(modules.Tables, f)).pointer.child;
        if (std.mem.eql(u8, Row.file, name)) {
            try w.writeAll("\n");
            var it = std.mem.splitScalar(u8, Row.doc, '\n');
            while (it.next()) |l| try w.print("// {s}\n", .{l});
            for (@field(t, f)) |r| try codec.writeAs(Row, w, r, mode);
        }
    }
}

/// Effect record `r` with its presets (`code(...)` of older files) written out as the
/// parts they name: the one place they are read (`apply`), so the runners and the dump
/// see data only.
fn dataForm(comptime Row: type, arena: Allocator, r: Row) Allocator.Error!Row {
    const effect = @import("../core.zig").effect;
    const classic = @import("../core.zig").classic;
    var x = r;
    inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |f, T| if (T == []const effect.Part) {
        var out: std.ArrayList(effect.Part) = .empty;
        for (@field(r, f)) |p| switch (p) {
            .code => |c| try out.appendSlice(arena, classic.preset(c)),
            else => try out.append(arena, p),
        };
        @field(x, f) = out.items;
    };
    if (Row == effect.Weapon) if (r.launch) |l| {
        const c = classic.withCode(l);
        var nl = c.l;
        if (c.extra) |st| nl.set = try std.mem.concat(arena, effect.Set, &.{ l.set, &.{st} });
        x.launch = nl;
    };
    return x;
}

test "rules: an older file's code(...) reads as the built-in parts and launches" {
    const effect = @import("../core.zig").effect;
    const classic = @import("../core.zig").classic;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ion = try dataForm(effect.Weapon, a, .{ .id = 1029, .pre = &.{.{ .code = .ion }} });
    try std.testing.expectEqualDeep(modules.weaponFx(1029, 0).?.pre, ion.pre);
    const gas = try dataForm(effect.Fighter, a, .{ .fighter = 136, .hit = &.{ .{ .code = .cloud }, .{ .shake = .n(3) } } });
    try std.testing.expectEqualDeep(classic.preset(.cloud)[0], gas.hit[0]);
    try std.testing.expectEqual(2, gas.hit.len);
    for ([_]i32{ 1070, 1072, 1040 }, [_]effect.LaunchCode{ .ball, .ball, .orbital }) |id, code| {
        const d = modules.weaponFx(id, 0).?.launch.?;
        // The record as an old rules file wrote it: the template, its sets and the code.
        var old = d;
        old.start_at = null;
        old.hold = null;
        old.grow = null;
        old.look = .plain;
        old.code = code;
        if (code == .orbital) old.set = d.set[0 .. d.set.len - 1];
        try std.testing.expectEqualDeep(d, (try dataForm(effect.Weapon, a, .{ .id = id, .launch = old })).launch.?);
    }
}

/// Every rules file (`rules\<name>.ss`), in `arena`: what an OpenGorky
/// project reads, so its numbers that follow adjust written as their values
/// (codec.Mode `resolve`).
pub fn dumpTexts(arena: Allocator) ![]Text {
    return dumpTextsAs(arena, .resolve);
}

/// `dumpTexts` with the numbers that follow adjust written as `mode` says (the tests keep
/// them named).
fn dumpTextsAs(arena: Allocator, mode: codec.Mode) ![]Text {
    var out: std.ArrayList(Text) = .empty;
    for (rules.files) |name| {
        var aw: Io.Writer.Allocating = .init(arena);
        try dump(&aw.writer, name, mode);
        try out.append(arena, .{ .name = try std.fmt.allocPrint(arena, entry_dir ++ "{s}.ss", .{name}), .data = aw.written() });
    }
    // Its code files as written (a rows file's name: its rows were written above).
    for (rules.scripts) |t| {
        const stem = t.name[if (std.mem.lastIndexOfScalar(u8, t.name, '\\')) |k| k + 1 else 0..];
        const rows_file = for (rules.files) |name| {
            if (stem.len == name.len + 3 and std.ascii.startsWithIgnoreCase(stem, name)) break true;
        } else false;
        if (!rows_file) try out.append(arena, .{ .name = t.name, .data = t.data });
    }
    return out.items;
}

/// The built-ins under `texts` (copied first: the editor's rules files, edited), the
/// project's format kept.
/// shortcut: the rules read before stay in the arena (what the editor drew from them may
/// still point there) until the next `reset`; upgrade if edits get frequent.
pub fn reload(texts: []const Text) Allocator.Error!void {
    rules.active = &rules.builtin;
    const a = rules.filesArena();
    const own = try a.alloc(Text, texts.len);
    for (own, texts) |*o, t| o.* = .{ .name = try a.dupe(u8, t.name), .data = try a.dupe(u8, t.data) };
    try apply(own);
}

/// An OpenGorky project's texts read again (the editor's edits, `reload` of `applyOg`):
/// the rules in force are theirs alone, as loaders/ogs.zig read them.
pub fn reloadOg(texts: []const Text) Allocator.Error!void {
    const a = rules.filesArena();
    const own = try a.alloc(Text, texts.len);
    for (own, texts) |*o, t| o.* = .{ .name = try a.dupe(u8, t.name), .data = try a.dupe(u8, t.data) };
    try applyOg(own);
}

/// Rules texts over the built-ins (they and their rows must outlive the rules: kept in
/// the rules' arena, `filesArena`).
pub fn apply(texts: []const Text) Allocator.Error!void {
    return applyOver(texts, false);
}

/// An OpenGorky project's texts (loaders/ogs.zig): their rows over empty
/// tables (no row of the exe's), and every text, its data blocks too, the worlds' program.
pub fn applyOg(texts: []const Text) Allocator.Error!void {
    return applyOver(texts, true);
}

fn applyOver(texts: []const Text, og: bool) Allocator.Error!void {
    const a = rules.filesArena();
    var lists: Lists(rules.Set) = .{};
    if (!og) inline for (@typeInfo(rules.Set).@"struct".field_names) |f| try @field(lists, f).appendSlice(a, @field(rules.builtin, f));
    var mods: Lists(modules.Tables) = .{};
    if (!og) inline for (@typeInfo(modules.Tables).@"struct".field_names) |f| try @field(mods, f).appendSlice(a, @field(modules.builtin_tables, f));
    var any_mod = og;
    var scripts: std.ArrayList(rules.Script) = .empty;
    // Parsed once: an OpenGorky project's blocks give their rows first (their fields
    // `report_icon`, `ai`, `strikes`…: block_rows), the files' rows over them.
    const Parsed = struct { name: []const u8, data: []const u8, u: script.ogs.parser.Unit };
    var parsed: std.ArrayList(Parsed) = .empty;
    for (texts) |t| {
        var diag: script.ogs.parser.Diagnostic = .{};
        const u = script.ogs.parser.parse(a, t.data, t.name, &diag) catch {
            std.log.warn("rules {s}:{d}: {s}", .{ t.name, diag.line, diag.message });
            continue;
        };
        try parsed.append(a, .{ .name = t.name, .data = t.data, .u = u });
    }
    // A class's row as each block of the class writes it (key_field): they must agree.
    var classes: std.StringHashMapUnmanaged([]const u8) = .empty;
    var profiles: Profiles = .{};
    if (og) for (parsed.items) |pt| for (pt.u.modules) |m| for (m.entities) |*e| if (std.mem.eql(u8, e.kind, "ai_profile")) {
        try profiles.blocks.put(a, try pathOf(a, m.path, e.name), .{ .ns = m.path, .e = e });
    };
    if (og) for (parsed.items) |pt| for (pt.u.modules) |m| for (m.entities) |e| {
        var made: std.ArrayList(script.ir.Call) = .empty;
        // Its AI profile first (its own `ai` row over it).
        try profiles.rowOf(a, m.path, e, &made);
        try settingsRows(a, e, &made);
        try gameRows(a, e, &made);
        if (std.mem.eql(u8, e.kind, "game")) for (e.fields) |f| if (f.value.kind == .call and rules.adjust_owners.isRecord(.game, f.value.kind.call.text)) try ownedSettings(a, f.value.kind.call, &made);
        // A weapon's own effect values (`flame = Flame(…)`: rules/adjust_owners.zig weapon_records).
        if (std.mem.eql(u8, e.kind, "weapon")) for (e.fields) |f| if (f.value.kind == .call and rules.adjust_owners.isWeaponRecord(f.value.kind.call.text))
            try ownedSettingsFor(a, f.value.kind.call, &made, try pathOf(a, m.path, e.name));
        try actionRow(a, e, &made);
        try blockRows(a, m.path, e, &made, .top);
        try nestedClassRows(a, e.children, &made);
        for (made.items) |c| {
            for (block_rows) |br| if (br.key_field.len > 0 and std.mem.eql(u8, c.text, br.call) and std.mem.eql(u8, c.named[0].name, br.key)) {
                var w: std.Io.Writer.Allocating = .init(a);
                const ex: script.ir.Expr = .{ .line = e.line, .kind = .{ .call = c } };
                script.ogs.print.expression(&w.writer, &ex) catch return error.OutOfMemory;
                var kw: std.Io.Writer.Allocating = .init(a);
                script.ogs.print.expression(&kw.writer, c.named[0].value) catch return error.OutOfMemory;
                const g = try classes.getOrPut(a, try std.fmt.allocPrint(a, "{s} {s}", .{ br.field, kw.written() }));
                if (g.found_existing and !std.mem.eql(u8, g.value_ptr.*, w.written()))
                    std.log.warn("rules {s}:{d}: {s} {s}: {s} differs from another block's of its {s} (the later one is in force)", .{ pt.name, e.line, e.kind, e.name, br.field, br.key_field });
                g.value_ptr.* = w.written();
            };
            const of_mods = !isRulesCall(c.text);
            var why: codec.Why = .not_value;
            (if (of_mods) addRow(modules.Tables, a, &mods, c, &why) else addRow(rules.Set, a, &lists, c, &why)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadRow => std.log.warn("rules {s}:{d}: {s} {s}: {s}: {s}", .{ pt.name, e.line, e.kind, e.name, c.text, why.text() }),
            };
        }
    };
    for (parsed.items) |pt| {
        const t: Text = .{ .name = pt.name, .data = pt.data };
        const u = pt.u;
        // Code (components, functions): the worlds load the whole text (state/hooks.zig).
        // shortcut: in a file named as a rows file (rules\fighters.ss) a dump keeps the rows only.
        const code = for (u.modules) |m| {
            if (m.fns.len + m.components.len > 0) break true;
        } else false;
        if (code or og) try scripts.append(a, .{ .name = t.name, .data = t.data });
        for (u.modules) |m| {
            if (m.entities.len > 0 and !og) std.log.warn("rules {s}: data blocks are not read (only rows and code)", .{t.name});
            for (m.rows) |e| {
                const c = e.kind.call;
                // The texts are the OG reader's (loaders/ogs.zig), no table's.
                if (og and isTextRow(c.text)) continue;
                // FxAs is Classic's: a weapon's own fields in OpenGorky.
                // A record of engine settings (`PopupColors(hp_loss = …)`, rules/adjust_owners.zig):
                // their Setting rows.
                if (og and rules.adjust_owners.isRecord(.ui, c.text)) {
                    var made: std.ArrayList(script.ir.Call) = .empty;
                    try ownedSettings(a, c, &made);
                    for (made.items) |sc| {
                        var why: codec.Why = .not_value;
                        addRow(rules.Set, a, &lists, sc, &why) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.BadRow => std.log.warn("rules {s}:{d}: {s}: {s}", .{ t.name, e.line, c.text, why.text() }),
                        };
                    }
                    continue;
                }
                if (og and std.mem.eql(u8, c.text, rules.FxAs.call)) {
                    std.log.warn("rules {s}:{d}: FxAs: no such row in OpenGorky (the weapon's effects_from, flash_from, launch_from, hit_from, hit_sound)", .{ t.name, e.line });
                    continue;
                }
                const of_mods = !isRulesCall(c.text);
                any_mod = any_mod or of_mods;
                var why: codec.Why = .not_value;
                (if (of_mods) addRow(modules.Tables, a, &mods, c, &why) else addRow(rules.Set, a, &lists, c, &why)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadRow => std.log.warn("rules {s}:{d}: {s}: {s}", .{ t.name, e.line, c.text, why.text() }),
                };
            }
        }
    }
    rules.scripts = scripts.items;
    numberRows(&lists, og);
    var set: rules.Set = undefined;
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| @field(set, f) = @field(lists, f).items;
    try rules.use(set);
    // After rules.use: the modules' tables are in force with these rules.
    if (any_mod) {
        for (mods.weapon_fx.items) |*r| r.* = try dataForm(@TypeOf(r.*), a, r.*);
        for (mods.fighter_fx.items) |*r| r.* = try dataForm(@TypeOf(r.*), a, r.*);
        var t: modules.Tables = undefined;
        inline for (@typeInfo(modules.Tables).@"struct".field_names) |f| @field(t, f) = @field(mods, f).items;
        modules.use(t);
    }
}

/// A block field holding rules rows (schema Field.rows): of blocks of `kinds`, rows of
/// `call` keyed by the block (`key` its path with `sigil`, a level's or a scene's name),
/// the value `arg`'s (`report_icon = "garcia"`: KillIcon icon) or, `arg` "", a record of
/// the call without its key, or a list of them (`strikes = [MonsterAttack(…), …]`).
/// `flag`: the row has its key alone, made when the field is `true` (`extra_wait = true`).
/// `key_field`: keyed by that field of the block instead (a weapon's `class = blaster`:
/// the class's row, the same in each weapon of the class).
/// `key` "": the rows key themselves (`states = [StateEffect(effect = burn, …)]`); `path`: the
/// key is the block's path as a string (`archetype = "characters::time_bomb"`); `child`: a
/// block inside a level or battle writes it too, keyed by its object name (`fighter
/// "04mf_invisible1"`'s `abilities`).
const BlockRow = struct { kinds: []const []const u8, field: []const u8, call: []const u8, key: []const u8, sigil: script.ir.Sigil = .none, arg: []const u8 = "", flag: bool = false, key_field: []const u8 = "", path: bool = false, child: bool = false };

const fighters = &[_][]const u8{ "fighter", "hero" };
pub const block_rows = [_]BlockRow{
    // Simple values.
    .{ .kinds = &.{ "fighter", "hero", "actor" }, .field = "report_icon", .call = "KillIcon", .key = "fighter", .sigil = .character, .arg = "icon", .child = true },
    .{ .kinds = fighters, .field = "hidden_weapons", .call = "HiddenWeapons", .key = "hero", .sigil = .character, .arg = "weapons" },
    .{ .kinds = &.{"weapon"}, .field = "skill_icon", .call = "SkillIcon", .key = "weapon", .sigil = .weapon, .arg = "icon" },
    .{ .kinds = &.{"weapon"}, .field = "weapon_sound", .call = "WeaponSound", .key = "weapon", .sigil = .weapon, .arg = "sound" },
    .{ .kinds = &.{ "battle", "level" }, .field = "grid_floor", .call = "GridFloor", .key = "level", .arg = "z" },
    .{ .kinds = &.{ "battle", "level" }, .field = "music", .call = "DistrictMusic", .key = "level", .arg = "track" },
    .{ .kinds = &.{"scene"}, .field = "repeat_trim", .call = "RepeatTrim", .key = "scene" },
    .{ .kinds = fighters, .field = "spins", .call = "FighterStrike", .key = "special", .sigil = .character, .arg = "spins" },
    .{ .kinds = fighters, .field = "extra_wait", .call = "WdelayHero", .key = "hero", .sigil = .character, .flag = true },
    .{ .kinds = fighters, .field = "bonus", .call = "HealBonus", .key = "healer", .sigil = .character },
    // Records.
    .{ .kinds = fighters, .field = "immunity", .call = "Resist", .key = "fighter", .sigil = .character },
    .{ .kinds = fighters, .field = "chatter", .call = "IdleChatter", .key = "hero", .sigil = .character },
    .{ .kinds = &.{"weapon"}, .field = "flags", .call = "WeaponFlags", .key = "weapon", .sigil = .weapon },
    .{ .kinds = &.{"item"}, .field = "medicine", .call = "Medicine", .key = "item", .sigil = .item },
    .{ .kinds = &.{"weapon"}, .field = "fx", .call = "WeaponFx", .key = "id", .sigil = .weapon },
    .{ .kinds = &.{"weapon"}, .field = "hero_attack", .call = "HeroAttack", .key = "weapon", .sigil = .weapon },
    .{ .kinds = fighters, .field = "ai", .call = "AiProfile", .key = "fighter", .sigil = .character },
    .{ .kinds = fighters, .field = "abilities", .call = "Abilities", .key = "fighter", .sigil = .character, .child = true },
    .{ .kinds = fighters, .field = "glow", .call = "Glow", .key = "fighter", .sigil = .character },
    .{ .kinds = &.{ "fighter", "hero", "weapon" }, .field = "device", .call = "Device", .key = "archetype", .path = true },
    .{ .kinds = &.{"game"}, .field = "states", .call = "StateEffect", .key = "" },
    .{ .kinds = fighters, .field = "strikes", .call = "MonsterAttack", .key = "fighter", .sigil = .character },
    .{ .kinds = fighters, .field = "strike_fx", .call = "FighterFx", .key = "fighter", .sigil = .character },
    .{ .kinds = &.{"weapon"}, .field = "class_rules", .call = "WeaponClass", .key = "name", .key_field = "class" },
    .{ .kinds = &.{"weapon"}, .field = "class_zone", .call = "Pattern", .key = "name", .key_field = "class" },
    .{ .kinds = fighters, .field = "class_ai", .call = "AiProfile", .key = "class_name", .key_field = "battle_class" },
    .{ .kinds = fighters, .field = "class_abilities", .call = "Abilities", .key = "class_name", .key_field = "battle_class" },
    .{ .kinds = &.{"battle"}, .field = "transform", .call = "Transform", .key = "mode", .key_field = "mode" },
};

/// The `game` block's start and shell as the Campaign row (rules.Campaign): `start =
/// ~l"01_port"` its level, `leader = @Sullivan`, `intro`/`startup` lists of videos,
/// `menu_logo`, `menu_music`, `credits`, `credits_music`, `credits_video`, `start_area`,
/// `start_point`, `start_scene`; the panel's first heroes its `party` in `party_order`'s
/// order (rules.Campaign.panel_first). No `start`: no row.
fn gameRows(a: Allocator, e: script.ir.Entity, out: *std.ArrayList(script.ir.Call)) !void {
    if (!std.mem.eql(u8, e.kind, "game") or fieldOf(e, "start") == null) return;
    const Str = struct {
        fn of(al: Allocator, v: ?*const script.ir.Expr) ![]const u8 {
            const x = v orelse return "";
            if (x.kind == .list) {
                var w: std.ArrayList(u8) = .empty;
                for (x.kind.list, 0..) |y, i| try w.print(al, "{s}{s}", .{ if (i > 0) " " else "", try of(al, y) });
                return w.items;
            }
            return switch (x.kind) {
                .lit => |l| if (l == .string) l.string else "",
                .ref => |r| r,
                .word => |wd| if (std.mem.lastIndexOf(u8, wd, "::")) |k| wd[k + 2 ..] else wd,
                // `Video(name = "intro.avi", …)`: its name.
                .call => |c| for (c.named) |n| {
                    if (std.mem.eql(u8, n.name, "name")) break try of(al, n.value);
                } else "",
                else => "",
            };
        }
    };
    // The party's heroes in `party_order`'s order, then the rest of it.
    var panel: std.ArrayList(u8) = .empty;
    const party = if (fieldOf(e, "party")) |v| if (v.kind == .list) v.kind.list else &.{} else &.{};
    const order = if (fieldOf(e, "party_order")) |v| if (v.kind == .list) v.kind.list else &.{} else &.{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for ([_][]const *const script.ir.Expr{ order, party }) |list| for (list) |x| {
        if (x.kind != .word) continue;
        const in_party = for (party) |y| {
            if (y.kind == .word and std.mem.eql(u8, y.kind.word, x.kind.word)) break true;
        } else false;
        if (!in_party or (try seen.getOrPut(a, x.kind.word)).found_existing) continue;
        try panel.print(a, "{s}{s}", .{ if (panel.items.len > 0) " " else "", try Str.of(a, x) });
    };
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "level", "start" },         .{ "leader", "leader" },   .{ "area", "start_area" },
        .{ "scene", "start_scene" },   .{ "intro", "intro" },     .{ "startup", "startup" },
        .{ "menu_logo", "menu_logo" }, .{ "credits", "credits" }, .{ "credits_video", "credits_video" },
    };
    var named: std.ArrayList(script.ir.Named) = .empty;
    for (fields) |f| {
        const v = try a.create(script.ir.Expr);
        v.* = .{ .line = e.line, .kind = .{ .lit = .{ .string = try Str.of(a, fieldOf(e, f[1])) } } };
        try named.append(a, .{ .name = f[0], .value = v });
    }
    // `music = Music(menu = "menu", credits = "credits", level_up = …, battle = ["battle", …])`:
    // the menu's and the credits' the Campaign's, the rest the ExeMusic row (core/ui.zig Music).
    const music: []const script.ir.Named = if (fieldOf(e, "music")) |v| (if (v.kind == .call) v.kind.call.named else &.{}) else &.{};
    var exe_music: std.ArrayList(script.ir.Named) = .empty;
    for ([_][]const u8{ "level_up", "battle_enter" }) |req| {
        const v = try a.create(script.ir.Expr);
        v.* = .{ .line = e.line, .kind = .{ .lit = .{ .string = "" } } };
        try exe_music.append(a, .{ .name = req, .value = v });
    }
    for ([_][]const u8{ "menu_music", "credits_music" }) |mf| {
        const v = try a.create(script.ir.Expr);
        v.* = .{ .line = e.line, .kind = .{ .lit = .{ .string = "" } } };
        try named.append(a, .{ .name = mf, .value = v });
    }
    for (music) |n| {
        const v = try a.create(script.ir.Expr);
        v.* = .{ .line = n.value.line, .kind = .{ .lit = .{ .string = try Str.of(a, n.value) } } };
        const campaign: ?[]const u8 = if (std.mem.eql(u8, n.name, "menu")) "menu_music" else if (std.mem.eql(u8, n.name, "credits")) "credits_music" else null;
        if (campaign) |cf| {
            for (named.items) |*x| if (std.mem.eql(u8, x.name, cf)) {
                x.value = v;
            };
            continue;
        }
        // A list (`battle = ["battle", "battle2"]`) as the row's words ("battle battle2").
        for (exe_music.items) |*x| {
            if (std.mem.eql(u8, x.name, n.name)) {
                x.value = v;
                break;
            }
        } else try exe_music.append(a, .{ .name = n.name, .value = v });
    }
    if (music.len > 0) try out.append(a, .{ .id = 0, .text = "ExeMusic", .args = &.{}, .named = exe_music.items });
    // `anims = Anims(fight_look = …)`, `holds = Holds(one_hand = …)`: core/ui.zig's rows.
    for ([_][2][]const u8{ .{ "anims", @import("../core.zig").ui.Anims.call }, .{ "holds", @import("../core.zig").ui.Holds.call } }) |rec| if (fieldOf(e, rec[0])) |v| if (v.kind == .call)
        try out.append(a, .{ .id = 0, .text = rec[1], .args = &.{}, .named = v.kind.call.named });
    // The videos' places: `Video(name = "intro.avi", y = 60, double = true)` in intro/startup.
    for ([_][]const u8{ "intro", "startup" }) |lf| {
        const l = fieldOf(e, lf) orelse continue;
        if (l.kind != .list) continue;
        for (l.kind.list) |x| if (x.kind == .call and std.mem.eql(u8, x.kind.call.text, "Video")) {
            var vn: std.ArrayList(script.ir.Named) = .empty;
            const zero = try a.create(script.ir.Expr);
            zero.* = .{ .line = x.line, .kind = .{ .lit = .{ .int = 0 } } };
            const no = try a.create(script.ir.Expr);
            no.* = .{ .line = x.line, .kind = .{ .lit = .{ .bool = false } } };
            try vn.appendSlice(a, &.{ .{ .name = "x", .value = zero }, .{ .name = "y", .value = zero }, .{ .name = "double", .value = no } });
            for (x.kind.call.named) |n| {
                for (vn.items) |*y| {
                    if (std.mem.eql(u8, y.name, n.name)) {
                        y.value = n.value;
                        break;
                    }
                } else try vn.append(a, n);
            }
            try out.append(a, .{ .id = 0, .text = "ExeVideo", .args = &.{}, .named = vn.items });
        };
    }
    const pt = try a.create(script.ir.Expr);
    pt.* = .{ .line = e.line, .kind = .{ .lit = .{ .int = if (fieldOf(e, "start_point")) |v| (if (v.kind == .lit and v.kind.lit == .int) v.kind.lit.int else 0) else 0 } } };
    try named.append(a, .{ .name = "point", .value = pt });
    for ([_]struct { []const u8, []const u8 }{ .{ "party", "" }, .{ "panel_first", panel.items } }) |f| {
        const v = try a.create(script.ir.Expr);
        v.* = .{ .line = e.line, .kind = .{ .lit = .{ .string = f[1] } } };
        try named.append(a, .{ .name = f[0], .value = v });
    }
    try out.append(a, .{ .id = 0, .text = rules.Campaign.call, .args = &.{}, .named = named.items });
}

/// Blocks that are one row each, `name` the block's: `action Open { label = "open"; }` an
/// Action, `speaker HQ { portrait = "Head Quarters"; }` a Speaker (core/ui.zig).
const named_rows = [_][2][]const u8{ .{ "action", "Action" }, .{ "speaker", "Speaker" } };

fn actionRow(a: Allocator, e: script.ir.Entity, out: *std.ArrayList(script.ir.Call)) !void {
    const call = for (named_rows) |k| {
        if (std.mem.eql(u8, e.kind, k[0])) break k[1];
    } else return;
    const n = try a.create(script.ir.Expr);
    n.* = .{ .line = e.line, .kind = .{ .lit = .{ .string = e.name } } };
    const named = try std.mem.concat(a, script.ir.Named, &.{ &.{.{ .name = "name", .value = n }}, e.fields });
    try out.append(a, .{ .id = 0, .text = call, .args = &.{}, .named = named });
}

/// Record `c` of engine settings (`Blood(count = 15)`, `PopupColors(hp_loss = [247, 83, 16])`;
/// rules/adjust_owners.zig) as its settings' Setting rows (`Setting(name = "blood_particle_count", int = 15)`).
fn ownedSettings(a: Allocator, c: script.ir.Call, out: *std.ArrayList(script.ir.Call)) !void {
    return ownedSettingsFor(a, c, out, "");
}

/// `ownedSettings` of weapon `weapon` ("" the project's): `Setting(…, weapon = ~w"<path>")`.
fn ownedSettingsFor(a: Allocator, c: script.ir.Call, out: *std.ArrayList(script.ir.Call), weapon: []const u8) !void {
    const wk: ?*script.ir.Expr = if (weapon.len > 0) blk: {
        const x = try a.create(script.ir.Expr);
        x.* = .{ .line = 0, .sigil = .weapon, .kind = .{ .lit = .{ .string = weapon } } };
        break :blk x;
    } else null;
    for (c.named) |n| {
        const f = rules.adjust_owners.of(c.text, n.name) orelse {
            std.log.warn("rules: {s} has no field {s}", .{ c.text, n.name });
            continue;
        };
        const d = rules.adjust.defaultOf(f.name) orelse continue;
        const nv = try a.create(script.ir.Expr);
        nv.* = .{ .line = n.value.line, .kind = .{ .lit = .{ .string = f.name } } };
        const kind: []const u8 = switch (d) {
            .int => "int",
            .float => "float",
            .rgba => "rgba",
        };
        const named: []const script.ir.Named = if (wk) |x| &.{ .{ .name = "name", .value = nv }, .{ .name = "weapon", .value = x }, .{ .name = kind, .value = n.value } } else &.{ .{ .name = "name", .value = nv }, .{ .name = kind, .value = n.value } };
        try out.append(a, .{ .id = 0, .text = "Setting", .args = &.{}, .named = try a.dupe(script.ir.Named, named) });
    }
}

fn fieldOf(e: script.ir.Entity, name: []const u8) ?*const script.ir.Expr {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

/// A `settings` block's fields as rows (an OpenGorky project's tuning values in one
/// place): `exp_levels = [0, 220, …]` ExpLevel by index, a record its table's row of no
/// key (`hero_attack = HeroAttack(anim = …)`: every weapon's without its own), a name of
/// rules.Const a Value, any other a Setting of its literal's kind (an int, a float, `[r, g, b]`).
fn settingsRows(a: Allocator, e: script.ir.Entity, out: *std.ArrayList(script.ir.Call)) !void {
    // The game block holds the game's rules: `exp_levels`, `hero_attack`, the formulas'
    // numbers (rules.Const); its other fields are its own.
    // No `settings` block (an engine setting is a field of what it tunes: ownedSettings).
    const game = std.mem.eql(u8, e.kind, "game");
    if (!game) return;
    for (e.fields) |f| {
        if (game and !std.mem.eql(u8, f.name, "exp_levels") and !std.mem.eql(u8, f.name, "hero_attack") and std.meta.stringToEnum(rules.Const, f.name) == null) continue;
        const nv = try a.create(script.ir.Expr);
        nv.* = .{ .line = f.value.line, .kind = .{ .lit = .{ .string = f.name } } };
        if (std.mem.eql(u8, f.name, "exp_levels")) {
            const l = if (f.value.kind == .list) f.value.kind.list else {
                std.log.warn("settings {s}: exp_levels: expected [exp, …]", .{e.name});
                continue;
            };
            for (l, 0..) |x, i| {
                const lv = try a.create(script.ir.Expr);
                lv.* = .{ .line = x.line, .kind = .{ .lit = .{ .int = @intCast(i) } } };
                try out.append(a, .{ .id = 0, .text = "ExpLevel", .args = &.{}, .named = try a.dupe(script.ir.Named, &.{ .{ .name = "level", .value = lv }, .{ .name = "exp", .value = x } }) });
            }
            continue;
        }
        if (f.value.kind == .call) {
            var c = f.value.kind.call;
            // Of no key: a HeroAttack's weapon 0 (every weapon with none of its own).
            if (std.mem.eql(u8, c.text, "HeroAttack") and for (c.named) |x| {
                if (std.mem.eql(u8, x.name, "weapon")) break false;
            } else true) {
                const z = try a.create(script.ir.Expr);
                z.* = .{ .line = f.value.line, .kind = .{ .lit = .{ .int = 0 } } };
                c.named = try std.mem.concat(a, script.ir.Named, &.{ &.{.{ .name = "weapon", .value = z }}, c.named });
            }
            try out.append(a, c);
            continue;
        }
        if (std.meta.stringToEnum(rules.Const, f.name) != null) {
            try out.append(a, .{ .id = 0, .text = "Value", .args = &.{}, .named = try a.dupe(script.ir.Named, &.{ .{ .name = "name", .value = nv }, .{ .name = "value", .value = f.value } }) });
            continue;
        }
        const kind: []const u8 = switch (litKind(f.value)) {
            .int => "int",
            .float => "float",
            .list => "rgba",
            .other => {
                std.log.warn("settings {s}: {s}: expected a number or [r, g, b]", .{ e.name, f.name });
                continue;
            },
        };
        try out.append(a, .{ .id = 0, .text = "Setting", .args = &.{}, .named = try a.dupe(script.ir.Named, &.{ .{ .name = "name", .value = nv }, .{ .name = kind, .value = f.value } }) });
    }
}

fn litKind(v: *const script.ir.Expr) enum { int, float, list, other } {
    return switch (v.kind) {
        .lit => |l| switch (l) {
            .int => .int,
            .float => .float,
            else => .other,
        },
        .unary => |u| if (u.op == .neg) litKind(u.operand) else .other,
        .list => .list,
        else => .other,
    };
}

fn pathOf(a: Allocator, ns: []const u8, name: []const u8) ![]const u8 {
    return if (ns.len == 0) name else std.fmt.allocPrint(a, "{s}::{s}", .{ ns, name });
}

/// The project's `ai_profile` blocks by path (`ai::garcia`): a block names one in its
/// `ai_profile` (a fighter's: the AiProfile row by it; the game's: the row of every
/// fighter with none), its fields over its bases' (`ai_profile garcia : monster`). How it
/// scores a hit tile is its own fields too (no AiScoring in OG Script): `weapons` (all,
/// by_health, first, free_arms), `follow_lock` (its AITargetLock target first, default
/// true), `score` (a component whose ScoreTile scores the tiles, `ai_scoring::Avenge`),
/// `wakeful`, `near` (`@grandma`) — each block the core's AiScoring row of its path.
const Profiles = struct {
    blocks: std.StringHashMapUnmanaged(struct { ns: []const u8, e: *const script.ir.Entity }) = .empty,

    /// A profile's fields that are its tile scoring's (the AiScoring row), not the AiProfile's.
    const scoring_fields = [_][]const u8{ "weapons", "follow_lock", "score", "wakeful", "near" };

    fn scoringField(n: []const u8) bool {
        for (scoring_fields) |x| if (std.mem.eql(u8, x, n)) return true;
        return false;
    }

    fn rowOf(self: *const Profiles, a: Allocator, ns: []const u8, e: script.ir.Entity, out: *std.ArrayList(script.ir.Call)) !void {
        // A profile: the AiScoring row of its path, of its own and its bases' scoring fields.
        if (std.mem.eql(u8, e.kind, "ai_profile")) {
            const path = try pathOf(a, ns, e.name);
            var fs: std.ArrayList(script.ir.Named) = .empty;
            _ = try self.fields(a, path, "", 0, &fs);
            try out.append(a, .{ .id = 0, .text = "AiScoring", .args = &.{}, .named = try scoringRow(a, path, fs.items, e.line) });
            return;
        }
        const fighter = std.mem.eql(u8, e.kind, "fighter") or std.mem.eql(u8, e.kind, "hero");
        if (!fighter and !std.mem.eql(u8, e.kind, "game")) return;
        const v = for (e.fields) |f| {
            if (std.mem.eql(u8, f.name, "ai_profile")) break f.value;
        } else return;
        const name = switch (v.kind) {
            .word => |w| w,
            .lit => |l| if (l == .string) l.string else "",
            else => "",
        };
        var all: std.ArrayList(script.ir.Named) = .empty;
        if (!try self.fields(a, name, "", 0, &all)) {
            std.log.warn("{s} {s}: ai_profile {s}: no such ai_profile block", .{ e.kind, e.name, name });
            return;
        }
        // Its fields but the scoring's; its scoring the profile's own row (by its path).
        var named: std.ArrayList(script.ir.Named) = .empty;
        for (all.items) |f| if (!scoringField(f.name)) try named.append(a, f);
        const sv = try a.create(script.ir.Expr);
        sv.* = .{ .line = v.line, .kind = .{ .lit = .{ .string = name } } };
        try named.append(a, .{ .name = "scoring", .value = sv });
        const pv = try a.create(script.ir.Expr);
        pv.* = .{ .line = v.line, .kind = .{ .lit = .{ .string = name } } };
        try named.append(a, .{ .name = "profile", .value = pv });
        if (fighter) {
            const key = try a.create(script.ir.Expr);
            key.* = .{ .line = v.line, .sigil = .character, .kind = .{ .lit = .{ .string = try pathOf(a, ns, e.name) } } };
            try named.insert(a, 0, .{ .name = "fighter", .value = key });
        }
        try out.append(a, .{ .id = 0, .text = "AiProfile", .args = &.{}, .named = named.items });
    }

    /// The core's AiScoring row `eval` of a profile's fields `fs`: `weapons` its keep;
    /// `score` its script (occupant none); `follow_lock = false` the occupant no_lock, else
    /// generic (Classic's `a` is generic for a monster: hero priority is the heroes' autoplay);
    /// `near = @grandma` the object's name.
    fn scoringRow(a: Allocator, eval: []const u8, fs: []const script.ir.Named, line: u32) ![]const script.ir.Named {
        var out: std.ArrayList(script.ir.Named) = .empty;
        const str = struct {
            fn f(al: Allocator, s: []const u8, l: u32) !*const script.ir.Expr {
                const x = try al.create(script.ir.Expr);
                x.* = .{ .line = l, .kind = .{ .lit = .{ .string = s } } };
                return x;
            }
        }.f;
        try out.append(a, .{ .name = "eval", .value = try str(a, eval, line) });
        var follow = true;
        var score: ?[]const u8 = null;
        for (fs) |f| {
            if (std.mem.eql(u8, f.name, "weapons")) {
                try out.append(a, .{ .name = "keep", .value = f.value });
            } else if (std.mem.eql(u8, f.name, "follow_lock")) {
                if (f.value.kind == .lit and f.value.kind.lit == .bool) follow = f.value.kind.lit.bool;
            } else if (std.mem.eql(u8, f.name, "score")) {
                score = if (f.value.kind == .lit and f.value.kind.lit == .string) f.value.kind.lit.string else if (f.value.kind == .word) f.value.kind.word else null;
            } else if (std.mem.eql(u8, f.name, "wakeful")) {
                // The row's flag is a number (the exe's table).
                const on = f.value.kind == .lit and ((f.value.kind.lit == .bool and f.value.kind.lit.bool) or (f.value.kind.lit == .int and f.value.kind.lit.int != 0));
                const x = try a.create(script.ir.Expr);
                x.* = .{ .line = line, .kind = .{ .lit = .{ .int = @intFromBool(on) } } };
                try out.append(a, .{ .name = "wakeful", .value = x });
            } else if (std.mem.eql(u8, f.name, "near")) {
                const n = switch (f.value.kind) {
                    .ref => |r| r,
                    .lit => |l| if (l == .string) l.string else "",
                    else => "",
                };
                try out.append(a, .{ .name = "near", .value = try str(a, n, line) });
            }
        }
        try out.append(a, .{ .name = "occupant", .value = try str(a, if (score != null) "none" else if (follow) "generic" else "no_lock", line) });
        if (score) |s| try out.append(a, .{ .name = "script", .value = try str(a, s, line) });
        return out.items;
    }

    /// Profile `path`'s fields (a name as its string) into `out`, its bases' first; `ns` the
    /// namespace a bare base name is in. False: no such block.
    fn fields(self: *const Profiles, a: Allocator, path: []const u8, ns: []const u8, depth: u32, out: *std.ArrayList(script.ir.Named)) !bool {
        const p = self.blocks.get(path) orelse (if (ns.len > 0) self.blocks.get(try pathOf(a, ns, path)) else null) orelse return false;
        if (depth > 16) return false;
        if (p.e.base.len > 0 and !try self.fields(a, p.e.base, p.ns, depth + 1, out))
            std.log.warn("ai_profile {s}: base {s}: no such ai_profile block", .{ p.e.name, p.e.base });
        for (p.e.fields) |f| {
            var n = f;
            if (f.value.kind == .word) {
                const x = try a.create(script.ir.Expr);
                x.* = .{ .line = f.value.line, .kind = .{ .lit = .{ .string = f.value.kind.word } } };
                n.value = x;
            }
            const at = for (out.items) |*o| {
                if (std.mem.eql(u8, o.name, n.name)) break o;
            } else null;
            if (at) |o| o.* = n else try out.append(a, n);
        }
        return true;
    }
};

/// The class rows (block_rows `key_field`: keyed by the class, not the block) of blocks
/// `cs` inside a level or battle (a battle's own weapon of class `invisible_bite`), theirs too.
fn nestedClassRows(a: Allocator, cs: []const script.ir.Entity, out: *std.ArrayList(script.ir.Call)) Allocator.Error!void {
    for (cs) |c| {
        try blockRows(a, "", c, out, .child);
        try nestedClassRows(a, c.children, out);
    }
}

/// The rows top-level block `e` of module `ns` writes in its fields (block_rows), into `out`;
/// `classes_only`: those keyed by a field (`key_field`) alone.
fn blockRows(a: Allocator, ns: []const u8, e: script.ir.Entity, out: *std.ArrayList(script.ir.Call), where: enum { top, child }) Allocator.Error!void {
    for (block_rows) |br| {
        if (where == .child and br.key_field.len == 0 and !br.child) continue;
        const kind_ok = for (br.kinds) |k| {
            if (std.mem.eql(u8, k, e.kind)) break true;
        } else false;
        if (!kind_ok) continue;
        const f = for (e.fields) |x| {
            if (std.mem.eql(u8, x.name, br.field)) break x;
        } else continue;
        const key = try a.create(script.ir.Expr);
        if (br.key_field.len > 0) {
            // That field's value: a name (`class = blaster`) as its string, a number as is.
            const kf = for (e.fields) |x| {
                if (std.mem.eql(u8, x.name, br.key_field)) break x.value;
            } else null;
            const kv: ?script.ir.Expr = if (kf) |v| switch (v.kind) {
                .word => |w| .{ .line = v.line, .kind = .{ .lit = .{ .string = w } } },
                .lit => |l| if (l == .string or l == .int) v.* else null,
                else => null,
            } else null;
            key.* = kv orelse {
                std.log.warn("{s} {s}: {s} needs its own {s}", .{ e.kind, e.name, br.field, br.key_field });
                continue;
            };
        } else if (where == .child) {
            // A level's or battle's own object: by its name (`fighter = "04mf_invisible1"`).
            key.* = .{ .line = f.value.line, .kind = .{ .lit = .{ .string = e.name } } };
        } else {
            const path = if ((br.sigil == .none and !br.path) or ns.len == 0) e.name else try std.fmt.allocPrint(a, "{s}::{s}", .{ ns, e.name });
            key.* = .{ .line = f.value.line, .sigil = br.sigil, .kind = .{ .lit = .{ .string = path } } };
        }
        const kn: script.ir.Named = .{ .name = br.key, .value = key };
        const keyed: []const script.ir.Named = if (br.key.len > 0) &.{kn} else &.{};
        if (br.flag) {
            if (f.value.kind == .lit and f.value.kind.lit == .bool and f.value.kind.lit.bool) try out.append(a, .{ .id = 0, .text = br.call, .args = &.{}, .named = try a.dupe(script.ir.Named, &.{kn}) });
            continue;
        }
        if (br.arg.len > 0) {
            try out.append(a, .{ .id = 0, .text = br.call, .args = &.{}, .named = try a.dupe(script.ir.Named, &.{ kn, .{ .name = br.arg, .value = f.value } }) });
            continue;
        }
        const one = [_]*const script.ir.Expr{f.value};
        const items: []const *const script.ir.Expr = if (f.value.kind == .list) f.value.kind.list else &one;
        for (items) |x| {
            if (x.kind != .call or !std.ascii.eqlIgnoreCase(x.kind.call.text, br.call)) {
                std.log.warn("{s} {s}: {s}: expected {s}(…)", .{ e.kind, e.name, br.field, br.call });
                continue;
            }
            try out.append(a, .{ .id = 0, .text = br.call, .args = &.{}, .named = try std.mem.concat(a, script.ir.Named, &.{ keyed, x.kind.call.named }) });
        }
    }
}

/// Rows the files name without the exe's number: an Action without
/// `classic_id` takes the built-in action's of its name, else a free one; a weapon class
/// (WeaponClass, Pattern: one name, one number) its row's, else (Classic) the exe's class
/// of its name (rules/weapon_classes.zig), else a free one: an OpenGorky project's classes
/// are its rows' names, numbered here.
fn numberRows(lists: *Lists(rules.Set), og: bool) void {
    const acts = lists.actions.items;
    // An OpenGorky project's actions are its rows' names, numbered here.
    const exe_acts: []const rules.Action = if (og) &.{} else rules.builtin.actions;
    var top: i32 = 0;
    for (acts) |r| top = @max(top, r.classic_id);
    for (exe_acts) |r| top = @max(top, r.classic_id);
    for (acts) |*r| if (r.classic_id == 0) {
        r.classic_id = for (exe_acts) |b| {
            if (std.ascii.eqlIgnoreCase(b.name, r.name)) break b.classic_id;
        } else blk: {
            top += 1;
            break :blk top;
        };
    };
    const wc = lists.weapon_classes.items;
    const ps = lists.patterns.items;
    var wtop: i32 = 0;
    for (wc) |r| wtop = @max(wtop, r.classic_id);
    for (ps) |r| wtop = @max(wtop, r.classic_id);
    const exe: []const @TypeOf(rules.weapon_class_names[0]) = if (og) &.{} else &rules.weapon_class_names;
    for (exe) |x| wtop = @max(wtop, x[0]);
    for (wc) |*r| if (r.classic_id == 0) {
        r.classic_id = classNumber(r.name, wc, ps, exe, &wtop);
    };
    for (ps) |*r| if (r.classic_id == 0) {
        r.classic_id = classNumber(r.name, wc, ps, exe, &wtop);
    };
}

/// The number of weapon class `name`: a row's of that name, `exe`'s, else `top` + 1.
fn classNumber(name: []const u8, wc: []const rules.WeaponClass, ps: []const rules.Pattern, exe: anytype, top: *i32) i32 {
    for (wc) |r| if (r.classic_id != 0 and std.ascii.eqlIgnoreCase(r.name, name)) return r.classic_id;
    for (ps) |r| if (r.classic_id != 0 and std.ascii.eqlIgnoreCase(r.name, name)) return r.classic_id;
    for (exe) |x| if (std.ascii.eqlIgnoreCase(x[1], name)) return x[0];
    top.* += 1;
    return top.*;
}

/// An OpenGorky project's text rows (loaders/ogs.zig `texts`): the interface and classic_id
/// texts, the items' and the areas' examine texts.
pub const text_rows = [_][]const u8{ "UiText", "Examine", "AreaExamine" };

fn isTextRow(name: []const u8) bool {
    for (text_rows) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn isRulesCall(name: []const u8) bool {
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| if (std.ascii.eqlIgnoreCase(name, @typeInfo(@FieldType(rules.Set, f)).pointer.child.call)) return true;
    return false;
}

/// A list per table of `S` (rules.Set, modules.Tables).
fn Lists(comptime S: type) type {
    const names = @typeInfo(S).@"struct".field_names;
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (names, 0..) |f, i| {
        const L = std.ArrayList(@typeInfo(@FieldType(S, f)).pointer.child);
        types[i] = L;
        attrs[i] = .{ .default_value_ptr = &@as(L, .empty) };
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

fn addRow(comptime S: type, a: Allocator, lists: *Lists(S), c: script.ir.Call, why: *codec.Why) codec.Error!void {
    inline for (@typeInfo(S).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(S, f)).pointer.child;
        if (std.ascii.eqlIgnoreCase(c.text, Row.call)) {
            const list = &@field(lists, f);
            // A row with an existing key overrides only the fields it writes (read over that row).
            for (list.items) |*r| {
                const over = codec.readRow(Row, a, c, r.*, why) catch |err| if (err == error.BadRow) continue else return err;
                if (codec.sameKey(Row, r.*, over)) {
                    r.* = over;
                    return;
                }
            }
            return list.append(a, try codec.readRow(Row, a, c, null, why));
        }
    }
    why.* = .unknown_table;
    return error.BadRow;
}

test "rules: every dumped file reads back as the built-ins" {
    defer rules.reset();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try apply(try dumpTextsAs(arena, .keep));
    try std.testing.expect(rules.active != &rules.builtin);
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(rules.Set, f)).pointer.child;
        const want = @field(rules.builtin, f);
        const got = @field(rules.active.*, f);
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |x, y| {
            var xn = x;
            xn.note = "";
            var yn = y;
            yn.note = "";
            if (!codec.same(Row, xn, yn)) {
                std.debug.print("{s}: {any}\n  vs {any}\n", .{ f, x, y });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "rules: an OpenGorky dump writes plain numbers and the Setting rows, and plays the same" {
    defer rules.reset();
    defer rules.adjust.clear();
    const Num = rules.rows.Num;
    // Two names the built-in strikes follow: one a value, one negative (kept named).
    var named: [2][]const u8 = undefined;
    var n: usize = 0;
    for (rules.builtin.monster_attacks) |r| if (r.hit_delay.a) |a| if (n < 2 and (n == 0 or !std.mem.eql(u8, a.name, named[0]))) {
        named[n] = a.name;
        n += 1;
    };
    try rules.adjust.put(named[0], .{ .int = 77 });
    try rules.adjust.put(named[1], .{ .int = -3 });
    try rules.adjust.put("sound_volume_falloff", .{ .float = 0.004 });
    try rules.adjust.put("fighter_stunned_color", .{ .rgba = .{ 200, 60, 20 } });
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const texts = try dumpTexts(arena_state.allocator());
    for (texts) |t| if (std.mem.eql(u8, t.name, entry_dir ++ "attacks.ss")) {
        try std.testing.expect(std.mem.indexOf(u8, t.data, named[0]) == null);
        try std.testing.expect(std.mem.indexOf(u8, t.data, named[1]) != null);
    } else if (std.mem.eql(u8, t.name, entry_dir ++ "adjust.ss")) {
        try std.testing.expect(std.mem.indexOf(u8, t.data, "Setting(name = \"sound_volume_falloff\", float = 0.004);") != null);
        try std.testing.expect(std.mem.indexOf(u8, t.data, "Setting(name = \"fighter_stunned_color\", rgba = list(200, 60, 20));") != null);
    };
    // The project reads them back: its values the Setting rows', every number the same.
    rules.adjust.clear();
    rules.og = true;
    try apply(texts);
    try std.testing.expectEqual(77, rules.adjust.getInt(named[0], 0));
    try std.testing.expectEqual([3]u8{ 200, 60, 20 }, rules.adjust.getRgb("fighter_stunned_color", .{ 0, 0, 0 }));
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(rules.Set, f)).pointer.child;
        if (Row == rules.Setting) continue;
        for (@field(rules.builtin, f), @field(rules.active.*, f)) |x, y| inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |fl, T| {
            if (T == Num) try std.testing.expect(@field(x, fl).ticks() == @field(y, fl).ticks() and @field(x, fl).int() == @field(y, fl).int());
            if (T == ?Num) if (@field(x, fl)) |v| try std.testing.expect(v.ticks() == @field(y, fl).?.ticks() and v.int() == @field(y, fl).?.int());
        };
    }
}

test "rules: the modules' records dump and read back as the built-ins; a row writes over one" {
    defer rules.reset();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try apply(try dumpTextsAs(arena_state.allocator(), .keep));
    const t = modules.tables();
    try std.testing.expect(t.weapon_fx.ptr != modules.builtin_tables.weapon_fx.ptr);
    inline for (@typeInfo(modules.Tables).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(modules.Tables, f)).pointer.child;
        const want = @field(modules.builtin_tables, f);
        const got = @field(t, f);
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |x, y| if (!codec.same(Row, x, y)) {
            std.debug.print("{s}: {any}\n  vs {any}\n", .{ f, x, y });
            return error.TestUnexpectedResult;
        };
    }
    try apply(&.{.{ .name = "fighters.ss", .data =
        \\Abilities(class = 13, stand = -1);
        \\Abilities(class = 4242, double_turn = 1, pairs = list(list(1, 2)));
        \\Abilities(fighter = "ft_new", class = 13, double_turn = 1);
        \\Character(fighter = "ft_new", as_hero = 1, as_enemy = 1);
        \\AiScoring(eval = "a", wakeful = 1);
        \\PanelPlace(button = "portrait4", hint = "hint_turn");
        \\WeaponFx(id = 49, flash = list(shake(adjust("attack_sq_life", 30)), explosion(Val(d = 2, adj = "x"))));
        \\ExeMusic(battle_enter = "x");
    }});
    const any: rules.Who = .{ .id = 1 };
    try std.testing.expectEqual(@as(?f32, -1), modules.abilities(any, 13).stand);
    try std.testing.expect(modules.abilities(any, 13).stand_after_move and modules.abilities(any, 13).guard != null);
    try std.testing.expect(modules.abilities(any, 4242).double_turn and modules.abilities(any, 4242).pairs[0][1] == 2);
    // A character's own row (by its class) over its classType's; its roles row.
    const new: rules.Who = .{ .id = 1, .class = "ft_new" };
    try std.testing.expect(modules.abilities(new, 13).double_turn and modules.abilities(new, 13).stand == null and !modules.abilities(any, 13).double_turn);
    try std.testing.expect(rules.character(new).?.as_hero and rules.character(new).?.as_enemy and rules.character(any) == null);
    try std.testing.expect(modules.aiScoring("a").wakeful and modules.aiScoring("a").occupant == .a);
    try std.testing.expectEqualStrings("hint_turn", modules.ui().panel.places[10].hint);
    try std.testing.expectEqualStrings("x", modules.ui().music.battle_enter);
    try std.testing.expectEqualStrings("upgradeparameters", modules.ui().music.level_up);
    try std.testing.expectEqual(.explosion, std.meta.activeTag(modules.weaponFx(49, 0).?.flash[1]));
    // An older file's presets are read as their parts, and dump as data.
    try apply(&.{.{ .name = "fx.ss", .data = "WeaponFx(id = 1037, pre = list(code(\"blaster\")));\nWeaponFx(id = 1040, launch = Launch(pr = Projectile(pos = list(0, 0, 0), start = list(0, 0, 0), target = list(0, 0, 0), mesh = \"pocisk\"), code = \"orbital\"));" }});
    try std.testing.expectEqual(.ribbon, std.meta.activeTag(modules.weaponFx(1037, 0).?.pre[0]));
    try std.testing.expectEqual(.none, modules.weaponFx(1040, 0).?.launch.?.code);
    var arena2: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena2.deinit();
    const texts = try dumpTextsAs(arena2.allocator(), .keep);
    for (texts) |tx| if (std.mem.eql(u8, tx.name, entry_dir ++ "fx.ss")) {
        try std.testing.expect(std.mem.indexOf(u8, tx.data, "code(") == null);
        try std.testing.expect(std.mem.indexOf(u8, tx.data, "WeaponFx(id = 1037, pre = list(\n    ribbon(") != null);
        try std.testing.expect(std.mem.indexOf(u8, tx.data, "Set(f = \"trail_period\"") != null);
    };
    // New rules in force (another project, Classic): the built-ins again.
    rules.reset();
    try std.testing.expect(modules.abilities(new, 4242) == &@import("../core.zig").behaviour.plain);
    try std.testing.expectEqualStrings("screenoff4", modules.ui().music.battle_enter);
}

test "rules: a mod's effect (new classic_id, chain, spread, look by age) reads and dumps back" {
    defer rules.reset();
    try apply(&.{.{ .name = "fx.ss", .data =
        \\WeaponFx(id = 5001, hit = list(
        \\  emitter(at = self(list(0, 0, 400)), aim = chain(lift = 300, n = 3, delay = 10), spread = 0.2, gravity = 1.5, drag = 0.05,
        \\    look = Look(sprite = "smoke2", size = Track(v = 20, rate = 4, max = 300), rgb = list(Track(v = 1), Track(v = 0.5, rate = 0.02), Track(v = 0.2)), alpha = Track(v = 1, rate = -0.05, min = 0), add = 0)),
        \\  ribbon(from = toward(r = 120, up = 450), to = chain(lift = 300))));
        \\Material(name = "melt", program = "dissolve", blend = "add", rgb = list(Track(v = 1), Track(v = 0.5), Track(v = 0.25)), k = Track(rate = 0.1, max = 1));
    }});
    // A bitmap with that material: its colour by the tracks, the dissolve's k by its age.
    const Sink = struct {
        got: *@import("../effects.zig").batch.Billboard,
        pub fn put(k: @This(), b: @import("../effects.zig").batch.Billboard) !void {
            k.got.* = b;
        }
    };
    var got: @import("../effects.zig").batch.Billboard = undefined;
    var bm: @import("../effects.zig").bitmap.Bitmap = .{ .effect = "x", .pos = @splat(0), .size = 1, .step = 1, .acc = 3, .material = "melt" };
    try @import("../effects.zig").batch.bitmaps(&.{bm}, 1, Sink{ .got = &got });
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0.25 }, got.rgb);
    try std.testing.expect(got.blend == .add and got.program == .dissolve);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), got.k, 1e-6);
    bm.material = "";
    try @import("../effects.zig").batch.bitmaps(&.{bm}, 1, Sink{ .got = &got });
    try std.testing.expect(got.blend == null and got.program == .none);
    const d = modules.weaponFx(5001, 0).?;
    const m = d.hit[0].emitter;
    try std.testing.expectEqual(@as(u32, 10), m.aim.chain.delay);
    try std.testing.expectEqual(@as(f32, 0.2), m.spread);
    try std.testing.expectEqualStrings("smoke2", m.look.?.sprite);
    try std.testing.expectEqual(@as(f32, 0.02), m.look.?.rgb[1].rate);
    try std.testing.expect(!m.look.?.add);
    try std.testing.expectEqual(@as(f32, 300), d.hit[1].ribbon.to.chain.lift);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const texts = try dumpTextsAs(arena_state.allocator(), .keep);
    try apply(texts);
    const again = modules.weaponFx(5001, 0).?;
    try std.testing.expect(codec.same(@import("../core.zig").effect.Weapon, d.*, again.*));
}

test "rules: a row replaces its key, a new key adds, bad rows are skipped" {
    std.testing.log_level = .err; // the bad rows below warn on purpose
    defer rules.reset();
    try apply(&.{.{ .name = "t.ss", .data =
        \\// Garcia: no resistances, heavy armour.
        \\Resist(fighter = 101, armor = -3);
        \\Resist(fighter = 2001, resist = "fire gas");
        \\Resist(fighter = 2002, resist = "nope");
        \\Nope(x = 1);
        \\MonsterAttack(fighter = 106, anim = "short_attack", hit_delay = adjust("rc28_attack_short_delay", 25) + 5, after_delay = 30);
    }});
    try std.testing.expectEqual(-3, rules.resist(.{ .id = 101 }).?.armor);
    try std.testing.expect(rules.resist(.{ .id = 2001 }).?.resist.bits[0] == 1 and rules.resist(.{ .id = 2001 }).?.resist.bits[6] == 1);
    try std.testing.expect(rules.resist(.{ .id = 2002 }) == null);
    try std.testing.expectEqual(rules.builtin.resist.len + 1, rules.active.resist.len);
    try std.testing.expectEqual(30, rules.monsterAttack(.{ .id = 106 }, .{ .id = 92 }).?.hit_delay.ticks());
    // Untouched tables stay the built-ins.
    try std.testing.expectEqual(rules.resist(.{ .id = 120 }).?.resist.bits, rules.builtin.resist[13].resist.bits);
}

test "rules: a row overrides only the fields it writes" {
    defer rules.reset();
    // An actions.ss dumped before the action flags existed.
    try apply(&.{.{ .name = "actions.ss", .data =
        \\Action(name = "Explore", kind = "explore");
        \\Action(name = "Close", walk_click = 0);
        \\Resist(fighter = "ft_hornet_2", armor = -3);
        \\Resist(fighter = 128, resist = "fire");
    }});
    try std.testing.expect(rules.actionFlag(7, .auto_open));
    try std.testing.expectEqual(7, rules.actionText(7));
    try std.testing.expect(!rules.actionFlag(2, .walk_click));
    // A classic_id row never merges into a class row (nor the other way).
    try std.testing.expectEqual(-3, rules.resist(.{ .id = 2000, .class = "ft_hornet_2" }).?.armor);
    try std.testing.expectEqual(-2, rules.resist(.{ .id = 128 }).?.armor);
}

test "rules: a row written with a field cleared over its built-in one clears it" {
    defer rules.reset();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // The Cripple's resistances emptied and its armour 0; Explore (7) not opening the box.
    var cripple = rules.resist(.{ .id = 125 }).?.*;
    cripple.resist = .{};
    cripple.armor = 0;
    cripple.note = "";
    try codec.write(rules.Resist, &aw.writer, cripple);
    var explore = for (rules.builtin.actions) |r| {
        if (r.classic_id == 7) break r;
    } else unreachable;
    try std.testing.expect(explore.auto_open);
    explore.auto_open = false;
    explore.note = "";
    try codec.write(rules.Action, &aw.writer, explore);
    try std.testing.expectEqualStrings(
        \\Resist(fighter = 125, resist = "", armor = 0);
        \\Action(name = "Explore", classic_id = 7, kind = "explore", auto_open = 0);
        \\
    , aw.written());
    try apply(&.{.{ .name = "t.ss", .data = aw.written() }});
    const got = rules.resist(.{ .id = 125 }).?;
    try std.testing.expect(codec.same(rules.rows.Flags, .{}, got.resist) and got.armor == 0);
    try std.testing.expect(!rules.actionFlag(7, .auto_open));
}

test "rules: class keys beat classic_id keys, and write back as strings" {
    defer rules.reset();
    try apply(&.{.{ .name = "t.ss", .data =
        \\Resist(fighter = "ft_hornet_2", resist = "fire", armor = -3);
        \\MonsterAttack(fighter = "ft_hornet_2", anim = "long_attack", hit_delay = 7);
        \\HeroAttack(weapon = "cw_riffle_2", anim = "attack_axe", wait = 3);
        \\FxAs(weapon = "cw_riffle_2", as = 98);
    }});
    const copy: rules.Who = .{ .id = 2000, .class = "FT_Hornet_2" };
    try std.testing.expectEqual(-3, rules.resist(copy).?.armor);
    // The hornet (128) keeps its own; a copy under the game's classic_id takes the class row.
    try std.testing.expectEqual(-2, rules.resist(.{ .id = 128, .class = "ft_hornet" }).?.armor);
    try std.testing.expectEqual(-3, rules.resist(.{ .id = 128, .class = "ft_hornet_2" }).?.armor);
    // No class (Classic): never a class row.
    try std.testing.expect(rules.resist(.{ .id = 2000 }) == null);
    try std.testing.expect(rules.hasMonsterAttack(copy) and !rules.hasMonsterAttack(.{ .id = 2000 }));
    try std.testing.expectEqual(7, rules.monsterAttack(copy, .{ .id = 1 }).?.hit_delay.ticks());
    try std.testing.expectEqualStrings("attack_axe", rules.heroAttack(.{ .id = 2001, .class = "cw_riffle_2" }, .{ .id = 20 }).anim);
    try std.testing.expectEqual(98, rules.fxAs(.{ .id = 2001, .class = "cw_riffle_2" }));
    try std.testing.expectEqual(2001, rules.fxAs(.{ .id = 2001 }));
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try codec.write(rules.Resist, &aw.writer, rules.resist(copy).?.*);
    try std.testing.expectEqualStrings("Resist(fighter = \"ft_hornet_2\", resist = \"fire\", armor = -3);\n", aw.written());
}

test "rules: a copy's rows are the original's under its class" {
    defer rules.reset();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const Sink = struct {
        out: [rules.files.len]Io.Writer.Allocating,
        fn row(self: *@This(), comptime Row: type, r: Row) !void {
            const k = comptime for (rules.files, 0..) |n, i| {
                if (std.mem.eql(u8, n, Row.file)) break i;
            } else unreachable;
            try codec.write(Row, &self.out[k].writer, r);
        }
    };
    var sink: Sink = undefined;
    for (&sink.out) |*o| o.* = .init(arena_state.allocator());
    try cloneRows(.{ .id = 128, .class = "ft_hornet" }, .{ .id = 2000, .class = "ft_hornet_2" }, false, &sink);
    var out: [rules.files.len][]const u8 = undefined;
    for (&out, &sink.out) |*t, *o| t.* = o.written();
    var texts: std.ArrayList(Text) = .empty;
    for (out, rules.files) |t, n| try texts.append(arena_state.allocator(), .{ .name = n, .data = t });
    try std.testing.expect(std.mem.indexOf(u8, out[1], "Resist(fighter = \"ft_hornet_2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[2], "KillIcon(fighter = \"ft_hornet_2\", icon = \"hornet\")") != null);
    try apply(texts.items);
    const copy: rules.Who = .{ .id = 2000, .class = "ft_hornet_2" };
    try std.testing.expectEqual(rules.resist(.{ .id = 128 }).?.armor, rules.resist(copy).?.armor);
    try std.testing.expectEqual(rules.monsterAttack(.{ .id = 128 }, .{ .id = 1 }).?.hit_delay.ticks(), rules.monsterAttack(copy, .{ .id = 1 }).?.hit_delay.ticks());
    try std.testing.expectEqual(.class, rowFor(arena_state.allocator(), codec.oneRow(arena_state.allocator(), "Resist(fighter = \"ft_hornet_2\");").?, copy).?);
}

test "rules: a fighter's AI row writes over its class's: the rest stays" {
    defer rules.reset();
    try apply(&.{.{ .name = "ai.ss", .data = "AiProfile(fighter = \"ft_hornet_2\", attack_weight = 7, decoys = 0);" }});
    const p = rules.aiProfile(.{ .id = 2000, .class = "ft_hornet_2" }, 0);
    try std.testing.expect(p.attack_weight.? == 7 and !p.decoys.? and p.damage_bonus.? == 5 and std.mem.eql(u8, p.scoring.?, "generic"));
    try std.testing.expect(rules.aiProfile(.{ .id = 128, .class = "ft_hornet" }, 0).attack_weight == null);
}

test "rules: a give row lists its weapon class for its fighter" {
    defer rules.reset();
    try apply(&.{.{ .name = "attacks.ss", .data = "MonsterAttack(fighter = \"ft_hornet_2\", weapon = \"wp_spit\", give = 1, anim = \"long_attack\", hit_delay = 20, attack_zone = \"rifle\");" }});
    var buf: [4][]const u8 = undefined;
    const g = rules.givenWeapons(.{ .id = 2000, .class = "ft_hornet_2" }, &buf);
    try std.testing.expect(g.len == 1 and std.mem.eql(u8, g[0], "wp_spit"));
    try std.testing.expectEqual(0, rules.givenWeapons(.{ .id = 128, .class = "ft_hornet" }, &buf).len);
    try std.testing.expectEqualStrings("rifle", rules.monsterAttack(.{ .id = 2000, .class = "ft_hornet_2" }, .{ .id = 1, .class = "wp_spit" }).?.attack_zone);
}

test "rules: a field typed into a row" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: codec.Why = .not_value;
    const base: rules.MonsterAttack = .{ .fighter = 0, .fighter_class = "ft_hornet_2", .weapon = 0, .weapon_class = "wp_hornet", .anim = "long_attack", .hit_delay = .n(45), .lift_delay = 40 };
    const r = try withField(a, rules.MonsterAttack, base, "anim", "short_attack", &why);
    try std.testing.expectEqualStrings("short_attack", r.anim);
    try std.testing.expectEqual(40, r.lift_delay);
    try std.testing.expectEqualStrings("ft_hornet_2", r.fighter_class);
    const z = try withField(a, rules.MonsterAttack, r, "attack_zone", "flame_thrower", &why);
    try std.testing.expectEqualStrings("flame_thrower", z.attack_zone);
    try std.testing.expectError(error.BadRow, withField(a, rules.MonsterAttack, r, "nope", "4", &why));
    try std.testing.expectEqual(codec.Why.unknown_field, why);
    const k = try withField(a, rules.Resist, .{ .fighter = 101 }, "fighter", "ft_x", &why);
    try std.testing.expect(k.fighter == 0 and std.mem.eql(u8, k.fighter_class, "ft_x"));
    try std.testing.expectEqual(7, (try withField(a, rules.Resist, k, "fighter", "7", &why)).fighter);
    // A core module's record (no comment field).
    try std.testing.expect((try withField(a, @import("../core.zig").ui.Music, modules.builtin_tables.music[0], "battle_enter", "x", &why)).battle_enter[0] == 'x');
    const p = try withField(a, rules.AiProfile, .{ .fighter_class = "ft_x" }, "scoring", "a", &why);
    try std.testing.expectEqualStrings("a", p.scoring.?);
    try std.testing.expect(p.attack_weight == null);
}

test "rules: the campaign is the exe's start; a file's row writes over it; code is not rows" {
    defer rules.reset();
    try std.testing.expectEqualStrings("01_port", rules.campaign().level);
    try std.testing.expectEqualStrings("introkon.avi", rules.campaign().intro);
    try apply(&.{
        .{ .name = "rules\\campaign.ss", .data = "Campaign(level = \"03_museum\", party = \"sullivan_2.hro medusa.hro\");" },
        .{ .name = "rules\\hooks.ss", .data = "component Hooks for game { fn OnDamage(a, t, w, amount) { return amount * 2; } }" },
    });
    try std.testing.expectEqual(1, rules.active.campaign.len);
    try std.testing.expectEqualStrings("03_museum", rules.campaign().level);
    try std.testing.expectEqualStrings("Sullivan", rules.campaign().leader);
    try std.testing.expectEqual(1, rules.scripts.len);
    try std.testing.expect(std.mem.indexOf(u8, rules.scripts[0].data, "OnDamage") != null);
}

test "rules: a project's WeaponClass kind, battle Values and outcome rule take effect" {
    defer rules.reset();
    const br = @import("../battle.zig").rules;
    // The built-ins are the exe's.
    try std.testing.expectEqual(.satellite, modules.weaponKind(8));
    try std.testing.expectEqual(.plain, modules.weaponKind(2));
    try std.testing.expectEqual(@as(f32, 1.2), br.perMille(.crit_pm));
    try std.testing.expectEqual(@as(f32, 0.2), br.perMille(.kill_exp_pm));
    try std.testing.expectEqual(30, br.skillPercent(3, true));
    try std.testing.expectEqual(4, br.sideBonus(std.math.pi, 0));
    const lost: modules.Count = .{ .heroes = 2, .dead_heroes = 1, .enemies = 1, .lenient = false };
    try std.testing.expectEqual(.lost, modules.battleOutcome(lost));
    try apply(&.{
        .{ .name = "rules\\weapon_classes.ss", .data = "WeaponClass(name = \"rifle\", kind = \"decoy\"); WeaponClass(name = \"orbital\", kind = \"satellite\"); Pattern(name = \"orbital\");" },
        .{ .name = "rules\\party.ss", .data = "Value(name = \"skill_step\", value = 20); Value(name = \"back_bonus\", value = 9); Value(name = \"crit_pm\", value = 1500); Value(name = \"lose_on_hero_death\", value = 0);" },
    });
    try std.testing.expectEqual(.decoy, modules.weaponKind(2));
    try std.testing.expect(rules.weaponClass(2).rolls_to_hit); // the row's other fields stay built-in
    // A new name: a free number (above the exe's), its Pattern row the same one.
    const orbital = rules.weaponClassId("orbital").?;
    try std.testing.expect(orbital > 1020 and rules.pattern(orbital) != null);
    try std.testing.expectEqual(.satellite, modules.weaponKind(orbital));
    try std.testing.expectEqual(60, br.skillPercent(3, true));
    try std.testing.expectEqual(100, br.skillPercent(3, false));
    try std.testing.expectEqual(9, br.sideBonus(std.math.pi, 0));
    try std.testing.expectEqual(@as(f32, 1.5), br.perMille(.crit_pm));
    try std.testing.expectEqual(.none, modules.battleOutcome(lost));
    try std.testing.expectEqual(.lost, modules.battleOutcome(.{ .heroes = 0, .dead_heroes = 2, .enemies = 1, .lenient = false }));
}

test "rules: an OpenGorky block's rows fields are rows keyed by it, the files' over them" {
    defer rules.reset();
    rules.og = true;
    try applyOg(&.{
        .{ .name = "characters/g.ogs", .data = "module characters { fighter g { report_icon = \"gi\"; ai = AiProfile(scoring = \"a\", lock = 7); strikes = [MonsterAttack(weapon = ~w\"weapons::w\", anim = \"long_attack\", hit_delay = 3)]; } }" },
        .{ .name = "rules/ui.ogs", .data = "KillIcon(fighter = ~c\"characters::g\", icon = \"over\");" },
    });
    const w: rules.Who = .{ .id = 1, .class = "characters::g" };
    // The file's row over the block's.
    var icon: []const u8 = "";
    for (rules.active.kill_icons) |r| if (std.mem.eql(u8, r.fighter_class, "characters::g")) {
        icon = r.icon;
    };
    try std.testing.expectEqualStrings("over", icon);
    try std.testing.expectEqual(@as(?i32, 7), rules.aiProfileRows(w, 0).own.?.lock);
    try std.testing.expectEqualStrings("long_attack", rules.monsterAttack(w, .{ .id = 2, .class = "weapons::w" }).?.anim);
}

test "rules: an ai_profile block is its fighters' AiProfile row, its fields over its base's" {
    defer rules.reset();
    rules.og = true;
    try applyOg(&.{
        .{ .name = "ai/x.ogs", .data = "module ai { ai_profile generic { lock = 100; monitor = 2; } ai_profile g2 : generic { monitor = 1; weapons = by_health; follow_lock = false; } ai_profile g3 : g2 { score = ai_scoring::Avenge; near = @grandma; wakeful = true; } }" },
        .{ .name = "game.ogs", .data = "game g { ai_profile = ai::generic; }" },
        .{ .name = "characters/g.ogs", .data = "module characters { fighter g { ai_profile = ai::g2; ai = AiProfile(lock = 7); } fighter h { ai_profile = ai::g3; } }" },
    });
    const own = rules.aiProfileRows(.{ .id = 1, .class = "characters::g" }, 0);
    try std.testing.expectEqual(@as(?i32, 7), own.own.?.lock);
    try std.testing.expectEqual(@as(?i32, 1), own.own.?.monitor);
    try std.testing.expectEqual(@as(?i32, 2), own.base.?.monitor);
    // Each profile is its own tile scoring (its path), its bases' fields under its own.
    try std.testing.expectEqualStrings("ai::g2", own.own.?.scoring.?);
    const g2 = modules.aiScoring("ai::g2");
    try std.testing.expect(g2.keep == .by_health and g2.occupant == .no_lock and g2.script.len == 0);
    const g3 = modules.aiScoring("ai::g3");
    try std.testing.expect(g3.keep == .by_health and g3.occupant == .none and g3.wakeful);
    try std.testing.expectEqualStrings("ai_scoring::Avenge", g3.script);
    try std.testing.expectEqualStrings("grandma", g3.near);
    try std.testing.expect(modules.aiScoring("ai::generic").occupant == .generic);
}

test "rules: the game's rules and the engine's settings where they live" {
    defer rules.reset();
    rules.og = true;
    try applyOg(&.{
        .{ .name = "game.ogs", .data = "game g { exp_levels = [0, 100, 250]; party_max = 4; explosion = Explosion(speed = 1.5); motion = Motion(stunned_level = 8); }" },
        .{ .name = "ui.ogs", .data = "PopupColors(exp_gain = [1, 2, 3]);" },
    });
    try std.testing.expectEqual(@as(usize, 3), rules.active.exp_levels.len);
    try std.testing.expectEqual(@as(i32, 250), rules.active.exp_levels[2].exp);
    try std.testing.expectEqual(@as(i32, 4), rules.value(.party_max));
    var n: usize = 0;
    for (rules.active.adjust) |r| {
        if (std.mem.eql(u8, r.name, "explosion_speed")) n += @intFromBool(r.float.? == 1.5);
        if (std.mem.eql(u8, r.name, "fighter_stunned_level")) n += @intFromBool(r.int.? == 8);
        if (std.mem.eql(u8, r.name, "cfcExpGain")) n += @intFromBool(r.rgba.?[2] == 3);
    }
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "rules: a weapon's own effect values over the game's" {
    defer rules.reset();
    rules.og = true;
    try applyOg(&.{
        .{ .name = "game.ogs", .data = "game g { flame = Flame(scale = 2.0); }" },
        .{ .name = "weapons/f.ogs", .data = "module weapons { weapon f { flame = Flame(scale = 5.0, color = [1, 2, 3]); } }" },
    });
    const f: rules.Who = .{ .id = 0, .class = "weapons::f" };
    const other: rules.Who = .{ .id = 0, .class = "weapons::g" };
    try std.testing.expectEqual(@as(f32, 5), rules.weaponFloat("attack_flame_scale", f));
    try std.testing.expectEqual(@as(u8, 3), rules.weaponRgb("attack_flame_col", f)[2]);
    try std.testing.expectEqual(@as(f32, 2), rules.weaponFloat("attack_flame_scale", other));
    try std.testing.expectEqual(@as(f32, 2), rules.weaponFloat("attack_flame_scale", null));
}

test "rules: a class's effects and a monster's resistances are lists of names" {
    defer rules.reset();
    rules.og = true;
    try applyOg(&.{.{ .name = "rules/x.ogs", .data = "WeaponClass(name = \"zap\", effects = [sleep, burn]); Resist(fighter = ~c\"characters::g\", resist = [attract, gas], armor = -2);" }});
    const wc = rules.weaponClass(rules.weaponClassId("zap").?);
    try std.testing.expectEqualSlices(rules.Effect, &.{ .sleep, .burn }, wc.effects);
    var n: usize = 0;
    for (rules.active.resist) |r| if (std.mem.eql(u8, r.fighter_class, "characters::g")) {
        try std.testing.expectEqual(@as(u1, 1), r.resist.bits[2]);
        try std.testing.expectEqual(@as(u1, 1), r.resist.bits[6]);
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "rules: a weapon's class_rules is its class's WeaponClass row" {
    defer rules.reset();
    rules.og = true;
    try applyOg(&.{
        .{ .name = "weapons/b.ogs", .data = "module weapons { weapon b { class = zap; class_rules = WeaponClass(recharge = 3, kind = \"energy\"); } weapon c { class = zap; class_rules = WeaponClass(recharge = 3, kind = \"energy\"); } }" },
    });
    const wc = rules.weaponClass(rules.weaponClassId("zap").?);
    try std.testing.expectEqual(@as(i32, 3), wc.recharge);
    try std.testing.expectEqual(rules.rows.WeaponKind.energy, wc.kind);
}

test "rules: an OpenGorky project's Actions are numbered by their names, their menu text a key" {
    defer rules.reset();
    rules.og = true;
    try applyOg(&.{.{ .name = "rules/actions.ogs", .data = "Action(name = \"Take\", label = \"take\", kind = \"take\"); Action(name = \"Pray\"); Action(name = \"Open\", classic_id = 1);" }});
    // Numbers of the rows' own (no exe table): a written one kept, the others after it.
    try std.testing.expectEqual(1, rules.actionNamed("Open").?.classic_id);
    const take = rules.actionNamed("Take").?.classic_id;
    const pray = rules.actionNamed("Pray").?.classic_id;
    try std.testing.expect(take > 1 and pray > 1 and take != pray);
    // The menu row: the label's text (ui key take = 3), a row without one its name.
    try std.testing.expectEqualStrings("take", rules.actionLabel(take));
    try std.testing.expectEqual(0, rules.actionText(pray));
}
