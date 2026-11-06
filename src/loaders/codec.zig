//! Rules rows as script calls: `Name(field = value, …);`, one per row, in OGS (the
//! engine's language, script/ogs/parser.zig reads them to IR calls; strings with OGS
//! escapes: `"weapons\\bottle"`). Generic over a row struct: ints,
//! bools (0/1; OpenGorky's `true`/`false`), floats, strings, enums (by name), `[]const i32` (a "1 2 3" string),
//! optionals (left out = null), the rows' own value types (`Num`, resistance words,
//! pattern rays and hit sets: their text forms are below) and, for the core modules'
//! records (effects, fighter classes, AI scorings, the interface: core/modules.zig
//! `Tables`), nested values: other lists and arrays `list(a, b, …)`, structs
//! `Type(field = value, …)` (fields at their defaults left out, the core's object pointers
//! never written), tagged unions `tag(field = value, …)` or `tag(value)` (an effect point:
//! `target(130)`, `self(list(0, 0, 360))`), a plain `effect.Val` as its number and a panel
//! button as its name (`"portrait3"` a slot).
//! A field `note` is the row's comment (written above it, not read back).
//! Numbers that follow adjust (`Num`'s `adjust("name", d)`, a Val's `adj`, a colour's,
//! the menu's `Adj`) are written as their values in force in an OpenGorky project
//! (`Mode`: its rules hold plain numbers); reading still takes them.
//! A key field `k` with a companion `k_class` (OpenGorky: a row by entity class) is
//! written and read as a string when that is set: `fighter = "ft_wasp"`; an archetype's
//! path as its reference, `fighter = ~c"characters::garcia"` (`~w` a weapon's, `~i` an item's).
//! So too a value naming an entity by classic_id (MonsterAttack `strike`, `effects_from`…):
//! its archetype, `strike = ~c"characters::medusa"`; the core takes its number (entity.refId).
//! Composition: the core keeps the rows (rules/rows.zig), this is their text.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const script = @import("../script.zig");
const ir = script.ir;
const rules = @import("../rules.zig");
const rows = rules.rows;
const core = @import("../core.zig");
const Val = core.effect.Val;
const Button = core.ui.Button;

pub const Error = error{ BadRow, OutOfMemory };

/// How numbers that follow adjust are written: `auto` as their values in an OpenGorky
/// project (rules.og), else named; `resolve` as values (conversion's dump); `keep` named.
pub const Mode = enum { auto, keep, resolve };

fn resolving(mode: Mode) bool {
    return switch (mode) {
        .auto => rules.og,
        .keep => false,
        .resolve => true,
    };
}

/// `v` with its adjust names made the values in force when `resolving` (else as it is).
/// Bit-exact: a Num's negative value stays named (`Num.ticks` clamps each one at 0).
fn inlined(comptime T: type, v: T, mode: Mode) T {
    if (!resolving(mode)) return v;
    const adj = rules.adjust;
    if (T == rows.Num) {
        var out: rows.Num = .{ .c = v.c };
        inline for (.{ v.a, v.b }) |x| if (x) |a| {
            const g = adj.getInt(a.name, a.d);
            if (g >= 0) {
                out.c += if (a.neg) -g else g;
            } else if (out.a == null) out.a = a else {
                out.b = a;
            }
        };
        return out;
    }
    if (T == Val) {
        if (v.adj.len == 0) return v;
        var o = v;
        o.d = if (v.int) @floatFromInt(adj.getInt(v.adj, @intFromFloat(v.d))) else adj.getFloat(v.adj, v.d);
        o.adj = "";
        o.int = false;
        return o;
    }
    if (T == core.ui.Adj) return .{ .d = adj.getInt(v.name, v.d) };
    // effect.Rgb: a colour that may follow adjust.
    if (comptime @hasField(T, "adj") and @hasField(T, "d") and @FieldType(T, "d") == [3]u8) {
        var o = v;
        o.d = adj.getRgb(v.adj, v.d);
        o.adj = "";
        return o;
    }
    return v;
}

/// Why a value does not read (the editor shows it in its interface language).
pub const Why = enum {
    name_value,
    unknown_field,
    missing,
    not_value,
    one_value,
    out_of_range,
    portrait_slot,
    unknown_name,
    list_len,
    tag,
    tag_value,
    unknown_kind,
    list_number,
    number,
    list,
    string,
    resistance,
    typed,
    adjust_call,
    two_adjust,
    number_or_adjust,
    pattern,
    unknown_table,

    /// In English (the port's log).
    pub fn text(w: Why) []const u8 {
        return switch (w) {
            .name_value => "arguments are name = value",
            .unknown_field => "unknown field",
            .missing => "a field without a default is missing",
            .not_value => "not a value",
            .one_value => "one value",
            .out_of_range => "number out of range",
            .portrait_slot => "portrait slot out of range",
            .unknown_name => "unknown name",
            .list_len => "wrong number of list items",
            .tag => "expected tag(...)",
            .tag_value => "expected tag(value)",
            .unknown_kind => "unknown kind",
            .list_number => "bad number in the list",
            .number => "expected a number",
            .list => "expected list(...)",
            .string => "expected a string",
            .resistance => "unknown resistance word",
            .typed => "expected Type(field = value, ...)",
            .adjust_call => "expected adjust(\"name\", default)",
            .two_adjust => "at most two adjust() values",
            .number_or_adjust => "expected a number or adjust(\"name\", default)",
            .pattern => "bad pattern list",
            .unknown_table => "unknown table",
        };
    }
};

fn fail(w: Why, reason: *Why) Error {
    reason.* = w;
    return error.BadRow;
}

/// `row` as one call; fields equal to their defaults are left out, unless the built-in
/// row of its key has another value there (a file's row is read over that one,
/// rules_text.addRow: one left out would keep the built-in's).
pub fn write(comptime Row: type, w: *std.Io.Writer, row: Row) std.Io.Writer.Error!void {
    return writeAs(Row, w, row, .auto);
}

/// `write` with the numbers that follow adjust written as `mode` says.
pub fn writeAs(comptime Row: type, w: *std.Io.Writer, row: Row, mode: Mode) std.Io.Writer.Error!void {
    const info = @typeInfo(Row).@"struct";
    const base = builtinOf(Row, row);
    if (@hasField(Row, "note") and row.note.len > 0) {
        var it = std.mem.splitScalar(u8, row.note, '\n');
        while (it.next()) |l| try w.print("// {s}\n", .{l});
    }
    try w.print("{s}(", .{Row.call});
    var first = true;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, attrs| {
        if (comptime std.mem.eql(u8, name, "note") or isCompanion(Row, name)) continue;
        // A row keyed by name (Action, WeaponClass, Pattern): only a built-in one's number is
        // written in an OpenGorky project (rules_text.numberRows gives the others one).
        const own_number = comptime std.mem.eql(u8, name, "classic_id") and @hasField(Row, "name");
        const v = @field(row, name);
        const listed = comptime @hasField(Row, name ++ "_class") and @FieldType(Row, name ++ "_class") == []const []const u8;
        const class: []const u8 = if (comptime @hasField(Row, name ++ "_class") and !listed) @field(row, name ++ "_class") else "";
        // A list of numbers naming archetypes in places (`list(~w"weapons::riffle", 98)`).
        const refs: []const []const u8 = if (comptime listed) @field(row, name ++ "_class") else &.{};
        const d = attrs.defaultValue(T);
        const inherit = if (d) |x| base == null or same(T, @field(base.?, name), x) else false;
        // shortcut: a null optional has no text (left out, it keeps the built-in's value);
        // upgrade with a `null` word if clearing one over a built-in row is needed.
        const none = if (comptime @typeInfo(T) == .optional) v == null else false;
        const skip = refs.len == 0 and ((own_number and rules.og and base == null) or (class.len == 0 and (none or (inherit and same(T, v, d.?)))));
        if (refs.len > 0) {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("{s} = list(", .{name});
            if (comptime T == []const i32) for (v, 0..) |n, k| {
                if (k > 0) try w.writeAll(", ");
                const c = if (k < refs.len) refs[k] else "";
                if (c.len > 0) {
                    try w.writeAll(comptime sigilOf(name));
                    try script.ogs.lexer.writeString(w, c);
                } else try w.print("{d}", .{n});
            };
            if (comptime T == []const [2]i32) for (v, 0..) |pr, k| {
                if (k > 0) try w.writeAll(", ");
                try w.writeAll("list(");
                for (pr, 0..) |n, j| {
                    if (j > 0) try w.writeAll(", ");
                    const c = if (2 * k + j < refs.len) refs[2 * k + j] else "";
                    if (c.len > 0) {
                        try w.writeAll(comptime sigilOf(name));
                        try script.ogs.lexer.writeString(w, c);
                    } else try w.print("{d}", .{n});
                }
                try w.writeAll(")");
            };
            try w.writeAll(")");
        } else if (!skip) {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("{s} = ", .{name});
            // An archetype's path as its reference (`~c"characters::garcia"`, the converter's).
            if (class.len > 0 and std.mem.indexOf(u8, class, "::") != null) try w.writeAll(comptime sigilOf(name));
            if (class.len > 0) try script.ogs.lexer.writeString(w, class) else try writeValueAs(T, w, v, mode);
        }
    }
    try w.writeAll(");\n");
}

/// The sigil of a reference field `name` (its `_class` an archetype's path): a weapon's
/// (`weapon`, MonsterAttack's `effects_from`…), an item's, else a character's.
fn sigilOf(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "item")) return "~i";
    // WeaponFx's `id`: the weapon whose effects these are.
    inline for (.{ "weapon", "effects_from", "flash_from", "launch_from", "hit_from", "id", "weapons", "pairs" }) |n| if (std.mem.eql(u8, name, n)) return "~w";
    if (std.mem.eql(u8, name, "random")) return "~i";
    return "~c";
}

/// The sigil a row of call `call` takes for field `field` naming an archetype (`weapon` →
/// `.weapon`, `item` → `.item`, `fighter`… → `.character`), when the row's type has its
/// `<field>_class`; null: a number only.
pub fn classField(call: []const u8, field: []const u8) ?script.ir.Sigil {
    @setEvalBranchQuota(4000);
    inline for (.{ rules.Set, core.modules.Tables }) |S| inline for (@typeInfo(S).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(S, f)).pointer.child;
        if (comptime @hasDecl(Row, "call")) if (std.ascii.eqlIgnoreCase(call, Row.call)) {
            inline for (@typeInfo(Row).@"struct".field_names) |name| if (comptime @hasField(Row, name ++ "_class")) {
                if (std.mem.eql(u8, name, field)) {
                    const sg = comptime sigilOf(name);
                    return if (comptime std.mem.eql(u8, sg, "~i")) .item else if (comptime std.mem.eql(u8, sg, "~w")) .weapon else .character;
                }
            };
            return null;
        };
    };
    return null;
}

test classField {
    try std.testing.expectEqual(script.ir.Sigil.character, classField("Resist", "fighter").?);
    try std.testing.expectEqual(script.ir.Sigil.weapon, classField("MonsterAttack", "weapon").?);
    try std.testing.expect(classField("ExpLevel", "level") == null);
}

/// The built-in row (rules or modules' records) of `row`'s key.
fn builtinOf(comptime Row: type, row: Row) ?Row {
    inline for (.{ rules.Set, core.modules.Tables }, .{ rules.builtin, core.modules.builtin_tables }) |S, b| inline for (@typeInfo(S).@"struct".field_names) |f| {
        if (comptime @typeInfo(@FieldType(S, f)).pointer.child == Row) {
            for (@field(b, f)) |x| if (sameKey(Row, x, row)) return x;
            return null;
        }
    };
    return null;
}

pub fn writeValue(comptime T: type, w: *std.Io.Writer, v: T) std.Io.Writer.Error!void {
    return writeValueAs(T, w, v, .auto);
}

/// `writeValue` with the numbers that follow adjust written as `mode` says.
pub fn writeValueAs(comptime T: type, w: *std.Io.Writer, v: T, mode: Mode) std.Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .bool => if (resolving(mode)) try w.writeAll(if (v) "true" else "false") else try w.writeByte(if (v) '1' else '0'),
        .int => try w.print("{d}", .{v}),
        .float => try w.print("{d}", .{v}),
        // OpenGorky's text (`resolving`): a name as a word (`effect = burn`), numbers as a list
        // (`damage = [15, 10, 5]`); Classic's a string ("burn", "15 10 5").
        .@"enum" => if (T == Button) {
            if (v.slot()) |k| try w.print("\"portrait{d}\"", .{k}) else try w.print("\"{t}\"", .{v});
        } else if (resolving(mode) and isWord(@tagName(v))) try w.print("{t}", .{v}) else try w.print("\"{t}\"", .{v}),
        .optional => |o| if (v) |x| try writeValueAs(o.child, w, x, mode),
        .pointer => |p| if (p.child == u8) try script.ogs.lexer.writeString(w, v) else if (comptime @typeInfo(p.child) == .int) {
            const og_list = resolving(mode);
            try w.writeByte(if (og_list) '[' else '"');
            for (v, 0..) |x, i| try w.print("{s}{d}", .{ if (i == 0) "" else if (og_list) ", " else " ", x });
            try w.writeByte(if (og_list) ']' else '"');
        } else try writeList(p.child, w, v, mode),
        .array => |r| try writeList(r.child, w, &v, mode),
        // A number that followed adjust, resolved: the number (`start_y = 220`).
        .@"struct" => if (T == core.ui.Adj and resolving(mode)) try w.print("{d}", .{inlined(T, v, mode).d}) else try writeStruct(T, w, v, mode),
        .@"union" => |u| switch (v) {
            inline else => |x, tag| {
                const F = @FieldType(T, @tagName(tag));
                _ = u;
                try w.print("{s}(", .{@tagName(tag)});
                if (comptime isGeneric(F) and F != Val) try writeFields(F, w, x, mode) else try writeValueAs(F, w, x, mode);
                try w.writeByte(')');
            },
        },
        else => @compileError("rules field type " ++ @typeName(T)),
    }
}

/// `list(a, b, …)`: structs and unions one per line.
fn writeList(comptime T: type, w: *Io.Writer, v: []const T, mode: Mode) Io.Writer.Error!void {
    const long = comptime (isGeneric(T) and T != Val) or @typeInfo(T) == .@"union";
    try w.writeAll("list(");
    for (v, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        if (long) try w.writeAll("\n    ") else if (i > 0) try w.writeByte(' ');
        try writeValueAs(T, w, x, mode);
    }
    try w.writeByte(')');
}

/// A struct written field by field (not one of the rows' value types).
fn isGeneric(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and T != rows.Num and T != rows.Flags and T != rows.Rays and T != rows.Effects;
}

/// A field the text leaves out: the core's object pointers (state, never in a record).
fn isState(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| @typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size == .one,
        .pointer => |p| p.size == .one,
        else => false,
    };
}

/// `field = value, …` of struct `v`, fields at their defaults left out.
fn writeFields(comptime T: type, w: *Io.Writer, v0: T, mode: Mode) Io.Writer.Error!void {
    const v = inlined(T, v0, mode);
    const info = @typeInfo(T).@"struct";
    var first = true;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        if (comptime isState(F)) continue;
        const x = @field(v, name);
        if (!(if (attrs.defaultValue(F)) |d| same(F, x, d) else false)) {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("{s} = ", .{name});
            try writeValueAs(F, w, x, mode);
        }
    }
}

fn shortName(comptime T: type) []const u8 {
    const n = @typeName(T);
    return n[if (comptime std.mem.lastIndexOfScalar(u8, n, '.')) |k| k + 1 else 0..];
}

/// Field values equal (strings and lists by content).
pub fn same(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| if (a) |x| (if (b) |y| same(o.child, x, y) else false) else b == null,
        .pointer => |p| if (comptime p.size == .one) a == b else if (comptime @typeInfo(p.child) == .int) std.mem.eql(p.child, a, b) else {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!same(p.child, x, y)) return false;
            return true;
        },
        .@"struct" => |s| {
            inline for (s.field_names, s.field_types) |n, F| if (!same(F, @field(a, n), @field(b, n))) return false;
            return true;
        },
        .array => |r| {
            for (a, b) |x, y| if (!same(r.child, x, y)) return false;
            return true;
        },
        .@"union" => switch (a) {
            inline else => |x, tag| if (std.meta.activeTag(b) != tag) false else same(@FieldType(T, @tagName(tag)), x, @field(b, @tagName(tag))),
        },
        else => a == b,
    };
}

/// Rows with the same key fields (`Row.keys`, with their classes).
pub fn sameKey(comptime Row: type, a: Row, b: Row) bool {
    inline for (Row.keys) |k| {
        if (!same(@FieldType(Row, k), @field(a, k), @field(b, k))) return false;
        if (@hasField(Row, k ++ "_class") and !std.ascii.eqlIgnoreCase(@field(a, k ++ "_class"), @field(b, k ++ "_class"))) return false;
    }
    return true;
}

/// `name` is a key field or a key's class (never taken from a `read` base).
fn isKey(comptime Row: type, comptime name: []const u8) bool {
    inline for (Row.keys) |k| if (std.mem.eql(u8, name, k) or std.mem.eql(u8, name, k ++ "_class")) return true;
    return false;
}

/// `name` is the class of key field `name[0 .. len - 6]`.
fn isCompanion(comptime Row: type, comptime name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_class") and @hasField(Row, name[0 .. name.len - "_class".len]);
}

/// A row from call `c` (its name already matched `Row.call`); strings point into the
/// source, lists into `arena`. Fields the call leaves out are `base`'s (the row it
/// overrides; never its keys), else their defaults.
pub fn read(comptime Row: type, arena: Allocator, c: ir.Call, base: ?Row) Error!Row {
    var why: Why = .not_value;
    return readRow(Row, arena, c, base, &why);
}

/// `read`, error.BadRow's reason in `reason`.
pub fn readRow(comptime Row: type, arena: Allocator, c: ir.Call, base: ?Row, reason: *Why) Error!Row {
    const info = @typeInfo(Row).@"struct";
    var row: Row = base orelse undefined;
    var set: [info.field_names.len]bool = @splat(false);
    if (c.args.len > 0) return fail(.name_value, reason);
    for (c.named) |a| {
        inline for (info.field_names, info.field_types, 0..) |name, T, i| {
            if (comptime std.mem.eql(u8, name, "note")) continue;
            if (std.ascii.eqlIgnoreCase(a.name, name)) {
                const listed = comptime @hasField(Row, name ++ "_class") and @FieldType(Row, name ++ "_class") == []const []const u8;
                // Pairs naming archetypes in places (`pairs = list(list(~w"…", 1078))`): the
                // numbers, the paths flat ("" a number's place).
                if (comptime listed and T == []const [2]i32) if (listItems(a.value)) |l| {
                    const ps = try arena.alloc([2]i32, l.len);
                    const cs = try arena.alloc([]const u8, 2 * l.len);
                    var any = false;
                    for (l, ps, 0..) |x, *pr, k| {
                        const two = listItems(x) orelse return fail(.list, reason);
                        if (two.len != 2) return fail(.list, reason);
                        for (two, 0..) |y, j| if (stringLit(y)) |s| {
                            pr[j] = 0;
                            cs[2 * k + j] = s;
                            any = true;
                        } else {
                            pr[j] = std.math.cast(i32, try readInt(y, reason)) orelse return fail(.out_of_range, reason);
                            cs[2 * k + j] = "";
                        };
                    }
                    @field(row, name) = ps;
                    @field(row, name ++ "_class") = if (any) cs else &.{};
                    set[comptime std.meta.fieldIndex(Row, name ++ "_class").?] = true;
                    set[i] = true;
                    break;
                };
                // A list naming archetypes in places: the numbers ("" a number's place).
                if (comptime listed and T == []const i32) if (a.value.kind == .list) {
                    const l = a.value.kind.list;
                    const ns = try arena.alloc(i32, l.len);
                    const cs = try arena.alloc([]const u8, l.len);
                    var any = false;
                    for (l, ns, cs) |x, *n, *cl| if (stringLit(x)) |s| {
                        n.* = 0;
                        cl.* = s;
                        any = true;
                    } else {
                        n.* = std.math.cast(i32, try readInt(x, reason)) orelse return fail(.out_of_range, reason);
                        cl.* = "";
                    };
                    @field(row, name) = ns;
                    @field(row, name ++ "_class") = if (any) cs else &.{};
                    set[comptime std.meta.fieldIndex(Row, name ++ "_class").?] = true;
                    set[i] = true;
                    break;
                };
                if (comptime @hasField(Row, name ++ "_class") and !listed) if (stringLit(a.value)) |s| {
                    @field(row, name ++ "_class") = s;
                    set[comptime std.meta.fieldIndex(Row, name ++ "_class").?] = true;
                    @field(row, name) = 0;
                    set[i] = true;
                    break;
                };
                if (comptime listed) @field(row, name ++ "_class") = &.{} else if (comptime @hasField(Row, name ++ "_class")) @field(row, name ++ "_class") = "";
                @field(row, name) = try readValue(T, arena, a.value, reason);
                set[i] = true;
                break;
            }
        } else return fail(.unknown_field, reason);
    }
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, T, attrs, i| {
        if (!set[i] and (base == null or comptime isKey(Row, name))) @field(row, name) = attrs.defaultValue(T) orelse return fail(.missing, reason);
    }
    return row;
}

/// Named argument `a` of a `Row` call alone, as `read` takes it (its field, its value):
/// why it does not read (`reason`), for the editor's check.
pub fn readArg(comptime Row: type, arena: Allocator, a: ir.Named, reason: *Why) Error!void {
    inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |name, T| {
        if (comptime std.mem.eql(u8, name, "note")) continue;
        if (std.ascii.eqlIgnoreCase(a.name, name)) {
            if (comptime @hasField(Row, name ++ "_class")) {
                if (stringLit(a.value) != null) return;
                // A list naming archetypes in places (`[~w"…", 98]`, pairs `[[~w"…", 1078]]`).
                if (comptime @FieldType(Row, name ++ "_class") == []const []const u8) if (listItems(a.value)) |l| {
                    for (l) |x| if (comptime T == []const [2]i32) {
                        const two = listItems(x) orelse return fail(.list, reason);
                        if (two.len != 2) return fail(.list, reason);
                        for (two) |y| if (stringLit(y) == null) {
                            _ = try readInt(y, reason);
                        };
                    } else if (stringLit(x) == null) {
                        _ = try readInt(x, reason);
                    };
                    return;
                };
            }
            _ = try readValue(T, arena, a.value, reason);
            return;
        }
    }
    return fail(.unknown_field, reason);
}

/// The calls of a rules text (OGS; null: it does not parse, `diag` says where).
pub fn parseRows(arena: Allocator, text: []const u8, diag: *script.ogs.parser.Diagnostic) ?[]const *const ir.Expr {
    return script.ogs.parser.rows(arena, text, "rules", diag) catch null;
}

/// The one call of rules text `text`, else null.
pub fn oneRow(arena: Allocator, text: []const u8) ?ir.Call {
    var diag: script.ogs.parser.Diagnostic = .{};
    const r = parseRows(arena, text, &diag) orelse return null;
    return if (r.len == 1) r[0].kind.call else null;
}

/// A value from its text (as `writeValue` writes it): a field typed in the editor;
/// error.BadRow's reason in `reason`.
pub fn readText(comptime T: type, arena: Allocator, text: []const u8, reason: *Why) Error!T {
    const src = try std.fmt.allocPrint(arena, "V({s});", .{text});
    var diag: script.ogs.parser.Diagnostic = .{};
    const r = parseRows(arena, src, &diag) orelse return fail(.not_value, reason);
    if (r.len != 1 or r[0].kind.call.args.len != 1 or r[0].kind.call.named.len != 0) return fail(.one_value, reason);
    return readValue(T, arena, r[0].kind.call.args[0], reason);
}

/// A bare name (`sleep`): a data word, or a name as a rules file's row parses it.
fn bareWord(e: *const ir.Expr) ?[]const u8 {
    return switch (e.kind) {
        .word => |w| w,
        .name => |n| n.text,
        else => null,
    };
}

fn stringLit(e: *const ir.Expr) ?[]const u8 {
    return if (e.kind == .lit and e.kind.lit == .string) e.kind.lit.string else null;
}

fn readValue(comptime T: type, arena: Allocator, e: *const ir.Expr, reason: *Why) Error!T {
    switch (@typeInfo(T)) {
        .bool => return if (e.kind == .lit and e.kind.lit == .bool) e.kind.lit.bool else try readInt(e, reason) != 0,
        .int => return std.math.cast(T, try readInt(e, reason)) orelse fail(.out_of_range, reason),
        .float => return @floatCast(try readFloat(e, reason)),
        .@"enum" => {
            // A name as a string (`"sleep"`) or a word (`sleep`: OpenGorky's lists).
            const s = bareWord(e) orelse try readString(e, reason);
            if (T == Button) if (std.ascii.startsWithIgnoreCase(s, "portrait")) if (std.fmt.parseInt(u8, s["portrait".len..], 10)) |k| {
                return if (k < 64) Button.portrait(k) else fail(.portrait_slot, reason);
            } else |_| {};
            return std.meta.stringToEnum(T, s) orelse fail(.unknown_name, reason);
        },
        .optional => |o| return try readValue(o.child, arena, e, reason),
        .array => |r| {
            const items = try listArgs(e, reason);
            if (items.len != r.len) return fail(.list_len, reason);
            var out: T = undefined;
            for (&out, items) |*o, x| o.* = try readValue(r.child, arena, x, reason);
            return out;
        },
        .@"union" => |u| {
            const c = switch (e.kind) {
                .call => |c| c,
                else => return fail(.tag, reason),
            };
            inline for (u.field_names) |name| if (std.ascii.eqlIgnoreCase(c.text, name)) {
                const F = @FieldType(T, name);
                // A struct's fields, or one value (a number for a Val).
                if (comptime isGeneric(F)) if (c.args.len != 1 or c.named.len > 0) return @unionInit(T, name, try readFields(F, arena, c, reason));
                if (c.args.len != 1 or c.named.len > 0) return fail(.tag_value, reason);
                return @unionInit(T, name, try readValue(F, arena, c.args[0], reason));
            };
            return fail(.unknown_kind, reason);
        },
        .pointer => |p| {
            if (comptime p.child != u8 and @typeInfo(p.child) != .int) {
                const items = try listArgs(e, reason);
                const out = try arena.alloc(p.child, items.len);
                for (out, items) |*o, x| o.* = try readValue(p.child, arena, x, reason);
                return out;
            }
            if (p.child != u8) if (listItems(e)) |items| {
                const out = try arena.alloc(p.child, items.len);
                for (out, items) |*o, x| o.* = std.math.cast(p.child, try readInt(x, reason)) orelse return fail(.out_of_range, reason);
                return out;
            };
            const s = try readString(e, reason);
            if (p.child == u8) return s;
            var list: std.ArrayList(p.child) = .empty;
            var it = std.mem.tokenizeAny(u8, s, " ,");
            while (it.next()) |t| try list.append(arena, std.fmt.parseInt(p.child, t, 10) catch return fail(.list_number, reason));
            return list.items;
        },
        .@"struct" => {
            if (T == core.ui.Adj) if (e.kind == .lit and e.kind.lit == .int) return .{ .d = e.kind.lit.int };
            return readStruct(T, arena, e, reason);
        },
        else => @compileError("rules field type " ++ @typeName(T)),
    }
}

/// A number literal, possibly negated.
fn readFloat(e: *const ir.Expr, reason: *Why) Error!f32 {
    return switch (e.kind) {
        .lit => |v| switch (v) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => fail(.number, reason),
        },
        .unary => |u| if (u.op == .neg) -(try readFloat(u.operand, reason)) else fail(.number, reason),
        else => fail(.number, reason),
    };
}

/// A name OG Script reads as a word (`burn`; not a keyword, not `portrait3`'s digit start).
fn isWord(n: []const u8) bool {
    if (n.len == 0 or std.ascii.isDigit(n[0]) or script.ogs.parser.isKeyword(n)) return false;
    for (n) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

/// The items of `[…]` or `list(…)`, if `e` is one.
fn listItems(e: *const ir.Expr) ?[]const *const ir.Expr {
    return switch (e.kind) {
        .list => |l| l,
        .call => |c| if (std.ascii.eqlIgnoreCase(c.text, "list") and c.named.len == 0) c.args else null,
        else => null,
    };
}

/// The items of `[…]` or `list(…)`.
fn listArgs(e: *const ir.Expr, reason: *Why) Error![]const *const ir.Expr {
    return listItems(e) orelse fail(.list, reason);
}

/// Struct `T` from a call's `field = value` arguments: the rest its defaults.
fn readFields(comptime T: type, arena: Allocator, c: ir.Call, reason: *Why) Error!T {
    const info = @typeInfo(T).@"struct";
    var out: T = undefined;
    var set: [info.field_names.len]bool = @splat(false);
    if (c.args.len > 0) return fail(.name_value, reason);
    for (c.named) |a| {
        inline for (info.field_names, info.field_types, 0..) |name, F, i| {
            if (comptime !isState(F)) if (std.ascii.eqlIgnoreCase(a.name, name)) {
                @field(out, name) = try readValue(F, arena, a.value, reason);
                set[i] = true;
                break;
            };
        } else return fail(.unknown_field, reason);
    }
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
        if (!set[i]) @field(out, name) = attrs.defaultValue(F) orelse return fail(.missing, reason);
    }
    return out;
}

/// An integer literal, possibly negated.
fn readInt(e: *const ir.Expr, reason: *Why) Error!i32 {
    return switch (e.kind) {
        .lit => |v| if (v == .int) v.int else fail(.number, reason),
        .unary => |u| if (u.op == .neg) -%(try readInt(u.operand, reason)) else fail(.number, reason),
        else => fail(.number, reason),
    };
}

fn readString(e: *const ir.Expr, reason: *Why) Error![]const u8 {
    return stringLit(e) orelse fail(.string, reason);
}

// ---------------------------------------------------------------- the rows' value types

fn writeStruct(comptime T: type, w: *Io.Writer, v0: T, mode: Mode) Io.Writer.Error!void {
    const v = inlined(T, v0, mode);
    switch (T) {
        // `adjust("name", default) + c`.
        rows.Num => {
            var any = false;
            inline for (.{ v.a, v.b }) |x| if (x) |a| {
                if (any) try w.writeAll(if (a.neg) " - " else " + ") else if (a.neg) try w.writeByte('-');
                try w.print("adjust(\"{s}\", {d})", .{ a.name, a.d });
                any = true;
            };
            if (!any) return w.print("{d}", .{v.c});
            if (v.c != 0) try w.print(" {s} {d}", .{ if (v.c < 0) "-" else "+", @abs(v.c) });
        },
        // Classic "fire gas"; OpenGorky `[fire, gas]`.
        rows.Flags => {
            try w.writeByte(if (rules.og) '[' else '"');
            var first = true;
            for (v.bits, rows.Flags.words) |b, word| if (b != 0) {
                if (!first) try w.writeAll(if (rules.og) ", " else " ");
                first = false;
                try w.writeAll(word);
            };
            try w.writeByte(if (rules.og) ']' else '"');
        },
        // "dx,dy,kind,effect,pct …" (kind s/c/x/y).
        rows.Rays => {
            try w.writeByte('"');
            for (v.items, 0..) |r, i| try w.print("{s}{d},{d},{c},{d},{d}", .{ if (i > 0) " " else "", r.dx, r.dy, rows.Ray.letters[@backingInt(r.kind)], r.effect, r.pct });
            try w.writeByte('"');
        },
        // "dx,dy … | dx,dy … | …" (empty sets at the end left out).
        rows.Effects => {
            var last: usize = 0;
            for (v.sets, 0..) |set, i| if (set.len > 0) {
                last = i + 1;
            };
            try w.writeByte('"');
            for (v.sets[0..last], 0..) |set, i| {
                if (i > 0) try w.writeAll(" |");
                for (set, 0..) |d, j| try w.print("{s}{d},{d}", .{ if (i > 0 or j > 0) " " else "", d[0], d[1] });
            }
            try w.writeByte('"');
        },
        // A scripted ability: `Name(param = value, …)`.
        core.behaviour.Script => {
            try w.print("{s}(", .{v.component});
            for (v.params, 0..) |p, i| {
                try w.print("{s}{s} = ", .{ if (i > 0) ", " else "", p.name });
                switch (p.value) {
                    .int => |x| try w.print("{d}", .{x}),
                    .float => |x| try w.print("{d}", .{x}),
                    .bool => |x| try w.writeAll(if (x) "true" else "false"),
                    .string => |x| try script.ogs.lexer.writeString(w, x),
                }
            }
            try w.writeByte(')');
        },
        else => {
            if (T == Val and v.plain()) return w.print("{d}", .{v.d});
            try w.print("{s}(", .{shortName(T)});
            try writeFields(T, w, v, mode);
            try w.writeByte(')');
        },
    }
}

fn readStruct(comptime T: type, arena: Allocator, e: *const ir.Expr, reason: *Why) Error!T {
    switch (T) {
        rows.Num => {
            var out: rows.Num = .{};
            try addTerm(&out, e, false, reason);
            return out;
        },
        rows.Flags => {
            // OpenGorky: `[attract, gas]` (words or strings); Classic: "attract gas".
            if (listItems(e)) |items| {
                var f: rows.Flags = .{};
                for (items) |x| {
                    const word = bareWord(x) orelse stringLit(x) orelse return fail(.resistance, reason);
                    f.bits[rows.resistIndex(word) orelse return fail(.resistance, reason)] = 1;
                }
                return f;
            }
            return rows.Flags.parse(try readString(e, reason)) orelse fail(.resistance, reason);
        },
        rows.Rays => {
            var list: std.ArrayList(rows.Ray) = .empty;
            var it = std.mem.tokenizeAny(u8, try readString(e, reason), " \t\r\n");
            while (it.next()) |t| {
                var f = std.mem.splitScalar(u8, t, ',');
                const dx = num(i8, f.next()) orelse return bad(reason);
                const dy = num(i8, f.next()) orelse return bad(reason);
                const k = f.next() orelse return bad(reason);
                const kind = if (k.len == 1) std.mem.indexOfScalar(u8, rows.Ray.letters, k[0]) orelse return bad(reason) else return bad(reason);
                const effect = num(u8, f.next()) orelse return bad(reason);
                const pct = num(u8, f.next()) orelse return bad(reason);
                try list.append(arena, .{ .dx = dx, .dy = dy, .kind = @fromBackingInt(@intCast(kind)), .effect = effect, .pct = pct });
            }
            return .{ .items = list.items };
        },
        rows.Effects => {
            var out: rows.Effects = .{};
            var sets = std.mem.splitScalar(u8, try readString(e, reason), '|');
            var i: usize = 0;
            while (sets.next()) |set| : (i += 1) {
                if (i == out.sets.len) return bad(reason);
                var list: std.ArrayList([2]i8) = .empty;
                var it = std.mem.tokenizeAny(u8, set, " \t\r\n");
                while (it.next()) |t| {
                    var f = std.mem.splitScalar(u8, t, ',');
                    try list.append(arena, .{ num(i8, f.next()) orelse return bad(reason), num(i8, f.next()) orelse return bad(reason) });
                }
                out.sets[i] = list.items;
            }
            return out;
        },
        core.behaviour.Script => {
            const c = if (e.kind == .call) e.kind.call else return fail(.typed, reason);
            if (c.args.len > 0) return fail(.name_value, reason);
            const ps = try arena.alloc(core.behaviour.Script.Param, c.named.len);
            for (c.named, ps) |n, *p| p.* = .{ .name = n.name, .value = switch (n.value.kind) {
                .lit => |v| switch (v) {
                    .int => |x| .{ .int = x },
                    .float => |x| .{ .float = x },
                    .bool => |x| .{ .bool = x },
                    .string => |x| .{ .string = x },
                    else => return fail(.not_value, reason),
                },
                .unary => if (n.value.kind.unary.op != .neg) return fail(.not_value, reason) else if (readInt(n.value, reason)) |x| .{ .int = x } else |_| .{ .float = try readFloat(n.value, reason) },
                else => return fail(.not_value, reason),
            } };
            return .{ .component = c.text, .params = ps };
        },
        else => {
            if (T == Val and e.kind != .call) return .{ .d = try readFloat(e, reason) };
            return switch (e.kind) {
                .call => |c| readFields(T, arena, c, reason),
                else => fail(.typed, reason),
            };
        },
    }
}

/// One term of a `Num`: a number, `adjust("name", default)`, their sums and negations.
fn addTerm(out: *rows.Num, e: *const ir.Expr, neg: bool, reason: *Why) Error!void {
    switch (e.kind) {
        .lit => |v| if (v == .int) {
            out.c += if (neg) -v.int else v.int;
        } else return fail(.number_or_adjust, reason),
        .unary => |u| if (u.op == .neg) try addTerm(out, u.operand, !neg, reason) else return fail(.number_or_adjust, reason),
        .binary => |b| switch (b.op) {
            .add, .sub => {
                try addTerm(out, b.lhs, neg, reason);
                try addTerm(out, b.rhs, if (b.op == .sub) !neg else neg, reason);
            },
            else => return fail(.number_or_adjust, reason),
        },
        .call => |c| {
            if (!std.ascii.eqlIgnoreCase(c.text, "adjust") or c.args.len != 2 or c.named.len > 0) return fail(.adjust_call, reason);
            const v: rows.Adj = .{ .name = try readString(c.args[0], reason), .d = try readInt(c.args[1], reason), .neg = neg };
            if (out.a == null) out.a = v else if (out.b == null) out.b = v else return fail(.two_adjust, reason);
        },
        else => return fail(.number_or_adjust, reason),
    }
}

fn num(comptime T: type, s: ?[]const u8) ?T {
    return std.fmt.parseInt(T, s orelse return null, 10) catch null;
}

fn bad(reason: *Why) Error {
    return fail(.pattern, reason);
}

test "pairs naming archetypes in places: read, written back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = core.behaviour.Abilities;
    const r = try read(Row, a, oneRow(a, "Abilities(class = 17, pairs = [[~w\"weapons::schizo1\", 1078]]);").?, null);
    try std.testing.expectEqual(1078, r.pairs[0][1]);
    try std.testing.expectEqualStrings("weapons::schizo1", r.pairs_class[0]);
    try std.testing.expectEqualStrings("", r.pairs_class[1]);
    var w: std.Io.Writer.Allocating = .init(a);
    try write(Row, &w.writer, r);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "pairs = list(list(~w\"weapons::schizo1\", 1078))") != null);
    // Numbers alone: as before.
    const n = try read(Row, a, oneRow(a, "Abilities(class = 17, pairs = list(list(1077, 1078)));").?, null);
    try std.testing.expectEqual(0, n.pairs_class.len);
}

test "resolving: adjust values written as numbers" {
    defer rules.adjust.clear();
    try rules.adjust.put("x", .{ .float = 2.5 });
    try rules.adjust.put("y", .{ .int = 4 });
    try rules.adjust.put("neg", .{ .int = -2 });
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeValueAs(Val, &aw.writer, .a("x", 1), .resolve);
    try writeValueAs(Val, &aw.writer, .{ .d = 1, .adj = "y", .int = true, .div = 2 }, .resolve);
    try writeValueAs(core.ui.Adj, &aw.writer, .{ .name = "y", .d = 3 }, .resolve);
    try writeValueAs(rows.Num, &aw.writer, .{ .c = 1, .a = .{ .name = "neg", .d = 0 }, .b = .{ .name = "y", .d = 0, .neg = true } }, .resolve);
    try std.testing.expectEqualStrings("2.5Val(d = 4, div = 2)4adjust(\"neg\", 0) - 3", aw.written());
}

test readText {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const P = core.effect.Part;
    var why: Why = .not_value;
    var aw: Io.Writer.Allocating = .init(a);
    // Every part template writes and reads back the same.
    for (core.effect.templates) |t| {
        aw.clearRetainingCapacity();
        try writeValue(P, &aw.writer, t);
        try std.testing.expect(same(P, t, try readText(P, a, aw.written(), &why)));
    }
    try std.testing.expectEqual(@as(f32, 2.5), try readText(f32, a, "2.5", &why));
    try std.testing.expectError(error.BadRow, readText(f32, a, "1, 2", &why));
    try std.testing.expectEqual(Why.one_value, why);
}

test "scripted abilities: Name(param = value, …) by name, read and written back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const A = core.behaviour.Abilities;
    const text = "Abilities(fighter = 7, scripts = list(\n    abilities::Rage(below_pct = -30, factor = 2.5, on = true, who = \"granny\"),\n    Reflect()));\n";
    const r = try read(A, a, oneRow(a, text).?, null);
    try std.testing.expectEqualStrings("abilities::Rage", r.scripts[0].component);
    try std.testing.expectEqual(core.behaviour.Script.Lit{ .int = -30 }, r.scripts[0].param("below_pct").?);
    try std.testing.expectEqual(core.behaviour.Script.Lit{ .float = 2.5 }, r.scripts[0].param("factor").?);
    try std.testing.expectEqual(core.behaviour.Script.Lit{ .bool = true }, r.scripts[0].param("on").?);
    try std.testing.expectEqualStrings("granny", r.scripts[0].param("who").?.string);
    try std.testing.expectEqual(0, r.scripts[1].params.len);
    var aw: Io.Writer.Allocating = .init(a);
    try write(A, &aw.writer, r);
    try std.testing.expectEqualStrings(text, aw.written());
    // A value that is no literal.
    try std.testing.expectError(error.BadRow, read(A, a, oneRow(a, "Abilities(class = 0, scripts = list(Rage(x = list(1))));").?, null));
}
