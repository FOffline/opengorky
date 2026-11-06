//! A rules file's rows checked for the code view (codeview.check): fields the call lacks
//! (the nearest name offered), fields written twice, values that do not read (the
//! engine's own reading, rules_text.rowProblem), a new row's missing fields; and values
//! naming nothing the editor knows: a fighter or weapon classType nothing declares (the
//! exe's, the game's class scripts', the rules' rows), a classic_id no entity has, a
//! string.tab number without a text; an older file's `adjust("name", d)` (the rules
//! hold plain numbers now): the number to write instead.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const ir = og.script.ir;
const rules_text = og.loaders.rules_text;
const rulesapi = @import("rulesapi.zig");
const tx = @import("text.zig");
const App = @import("app.zig").App;

/// A problem: its line, the word (or string) to underline, the message.
pub const Issue = struct { line: u32, name: []const u8, quoted: bool = false, msg: []const u8 };

/// The rows of a rules file (its top-level calls, og.loaders.codec.parseRows).
const Rows = []const *const ir.Expr;

/// Problems of the rows that need no game data.
pub fn rows(a: Allocator, list: Rows, out: *std.ArrayList(Issue)) void {
    for (list) |e| row(a, e, out);
}

fn stringLit(e: *const ir.Expr) ?[]const u8 {
    return if (e.kind == .lit and e.kind.lit == .string) e.kind.lit.string else null;
}

fn row(a: Allocator, e: *const ir.Expr, out: *std.ArrayList(Issue)) void {
    const c = e.kind.call;
    // An OpenGorky project's texts (texts/*.ogs): read as texts, not rules (rules_text.text_rows).
    for (rules_text.text_rows) |n| if (std.mem.eql(u8, n, c.text)) return;
    const rc = rulesapi.find(c.text) orelse {
        var best: ?[]const u8 = null;
        for (rules_text.calls) |n| if (distance(n, c.text) <= 2) {
            best = n;
        };
        const msg = if (best) |b| tx.alloc(a, tx.code_r_no_table_near, .{ c.text, b }) else tx.alloc(a, tx.code_r_no_table, .{c.text});
        return out.append(a, .{ .line = e.line, .name = c.text, .msg = msg }) catch {};
    };
    if (std.ascii.eqlIgnoreCase(rc.name, "adjust")) return;
    var bad = false;
    for (c.named, 0..) |arg, k| {
        const name = arg.name;
        if (rulesapi.field(rc, name) == null and !companion(rc, name)) {
            bad = true;
            const msg = if (nearest(rc, name)) |n| tx.alloc(a, tx.code_r_no_field, .{ rc.name, name, n }) else tx.alloc(a, tx.code_r_no_field_list, .{ rc.name, name, fieldList(a, rc) });
            out.append(a, .{ .line = arg.value.line, .name = name, .msg = msg }) catch {};
            continue;
        }
        for (c.named[0..k]) |prev| if (std.ascii.eqlIgnoreCase(prev.name, name)) {
            out.append(a, .{ .line = arg.value.line, .name = name, .msg = tx.alloc(a, tx.code_r_twice, .{ rc.name, name }) }) catch {};
            break;
        };
    }
    if (bad) return;
    for (c.named) |arg| adjustTerms(a, arg.value, out);
    // A scoring is a name of the data (an AiScoring row's `eval`): one the rules in force have.
    if (std.ascii.eqlIgnoreCase(rc.name, "AiProfile")) for (c.named) |arg| if (std.mem.eql(u8, arg.name, "scoring")) if (stringLit(arg.value)) |v| {
        const known = for (og.core.modules.tables().scorings) |r| {
            if (std.ascii.eqlIgnoreCase(r.eval, v)) break true;
        } else false;
        if (!known) if (rulesapi.field(rc, "scoring")) |f| out.append(a, .{ .line = arg.value.line, .name = arg.name, .msg = tx.alloc(a, tx.code_r_word, .{ arg.name, v, wordList(a, f) }) }) catch {};
    };
    const p = rules_text.rowProblem(a, c) orelse return;
    if (p.positional) return out.append(a, .{ .line = c.args[0].line, .name = c.text, .msg = tx.alloc(a, tx.code_r_value, .{ c.text, why(p.why), "name = value" }) }) catch {};
    if (p.arg) |k| {
        const arg = c.named[k];
        const name = arg.name;
        const f = rulesapi.field(rc, name);
        const msg = if (f != null and f.?.words.len > 0 and stringLit(arg.value) != null)
            tx.alloc(a, tx.code_r_word, .{ name, stringLit(arg.value).?, wordList(a, f.?) })
        else
            tx.alloc(a, tx.code_r_value, .{ name, why(p.why), rulesapi.shape(a, rc.name, name).ty });
        return out.append(a, .{ .line = arg.value.line, .name = name, .msg = msg }) catch {};
    }
    // The fields without a default it leaves out (a new row: no built-in one has its keys).
    var miss: std.ArrayList(u8) = .empty;
    for (rc.fields) |f| {
        const sh = rulesapi.shape(a, rc.name, f.name);
        if (sh.optional or sh.default.len > 0) continue;
        if (written(c, f.name)) continue;
        miss.print(a, "{s}{s}", .{ if (miss.items.len > 0) ", " else "", f.name }) catch {};
    }
    out.append(a, .{ .line = e.line, .name = c.text, .msg = if (miss.items.len > 0) tx.alloc(a, tx.code_r_missing, .{ c.text, miss.items }) else tx.alloc(a, tx.code_r_value, .{ c.text, why(p.why), "" }) }) catch {};
}

/// Each `adjust("name", d)` in `e`: its value in force, the number to write.
fn adjustTerms(a: Allocator, e: *const ir.Expr, out: *std.ArrayList(Issue)) void {
    switch (e.kind) {
        .unary => |x| adjustTerms(a, x.operand, out),
        .binary => |x| {
            adjustTerms(a, x.lhs, out);
            adjustTerms(a, x.rhs, out);
        },
        .call => |x| if (std.ascii.eqlIgnoreCase(x.text, "adjust") and x.args.len == 2 and stringLit(x.args[0]) != null and x.args[1].kind == .lit and x.args[1].kind.lit == .int) {
            const v = og.rules.adjust.getInt(stringLit(x.args[0]).?, x.args[1].kind.lit.int);
            out.append(a, .{ .line = e.line, .name = x.text, .msg = tx.alloc(a, tx.code_r_adjust, .{ stringLit(x.args[0]).?, v }) }) catch {};
        } else {
            for (x.args) |y| adjustTerms(a, y, out);
            for (x.named) |y| adjustTerms(a, y.value, out);
        },
        else => {},
    }
}

fn written(c: ir.Call, name: []const u8) bool {
    for (c.named) |arg| if (std.ascii.eqlIgnoreCase(arg.name, name)) return true;
    return false;
}

/// `fighter_class`: a key's class written by its own name (the codec reads it).
fn companion(rc: *const rulesapi.Call, name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_class") and rulesapi.field(rc, name[0 .. name.len - "_class".len]) != null;
}

/// The field of `rc` nearest to `name` (two edits at most, or one starting the other).
fn nearest(rc: *const rulesapi.Call, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var bd: usize = 3;
    for (rc.fields) |f| {
        const d = distance(f.name, name);
        if (d < bd) {
            bd = d;
            best = f.name;
        }
    }
    if (best == null) for (rc.fields) |f| if (name.len >= 3 and std.ascii.startsWithIgnoreCase(f.name, name)) return f.name;
    return best;
}

/// Edits from `x` to `y` (case aside); names are short.
fn distance(x: []const u8, y: []const u8) usize {
    if (x.len > 40 or y.len > 40) return 99;
    var prev: [41]usize = undefined;
    var cur: [41]usize = undefined;
    for (0..y.len + 1) |j| prev[j] = j;
    for (x, 0..) |cx, i| {
        cur[0] = i + 1;
        for (y, 0..) |cy, j| cur[j + 1] = @min(@min(prev[j + 1], cur[j]) + 1, prev[j] + @intFromBool(std.ascii.toLower(cx) != std.ascii.toLower(cy)));
        @memcpy(prev[0 .. y.len + 1], cur[0 .. y.len + 1]);
    }
    return prev[y.len];
}

fn fieldList(a: Allocator, rc: *const rulesapi.Call) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (rc.fields, 0..) |f, k| out.print(a, "{s}{s}", .{ if (k > 0) ", " else "", f.name }) catch {};
    return out.items;
}

fn wordList(a: Allocator, f: *const rulesapi.Field) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (f.words, 0..) |w, k| out.print(a, "{s}\"{s}\"", .{ if (k > 0) ", " else "", w.name }) catch {};
    return out.items;
}

/// The codec's reason (codec.Why) in the interface language.
pub fn why(w: og.loaders.codec.Why) []const u8 {
    return tx.get(switch (w) {
        .name_value => .{ .en = "arguments are name = value", .ru = "аргументы пишутся как имя = значение" },
        .unknown_field => .{ .en = "unknown field", .ru = "неизвестное поле" },
        .missing => .{ .en = "a field without a default is missing", .ru = "не записано поле без умолчания" },
        .not_value => .{ .en = "not a value", .ru = "не значение" },
        .one_value => .{ .en = "one value", .ru = "одно значение" },
        .out_of_range => .{ .en = "number out of range", .ru = "число вне допустимого диапазона" },
        .portrait_slot => .{ .en = "portrait slot out of range", .ru = "слот портрета вне диапазона" },
        .unknown_name => .{ .en = "unknown name", .ru = "неизвестное имя" },
        .list_len => .{ .en = "wrong number of list items", .ru = "не то число элементов списка" },
        .tag => .{ .en = "expected tag(...)", .ru = "ожидается вид(…)" },
        .tag_value => .{ .en = "expected tag(value)", .ru = "ожидается вид(значение)" },
        .unknown_kind => .{ .en = "unknown kind", .ru = "неизвестный вид" },
        .list_number => .{ .en = "bad number in the list", .ru = "в списке не число" },
        .number => .{ .en = "expected a number", .ru = "ожидается число" },
        .list => .{ .en = "expected list(...)", .ru = "ожидается list(…)" },
        .string => .{ .en = "expected a string", .ru = "ожидается строка" },
        .resistance => .{ .en = "unknown resistance word", .ru = "неизвестное слово сопротивления" },
        .typed => .{ .en = "expected Type(field = value, ...)", .ru = "ожидается Тип(поле = значение, …)" },
        .adjust_call => .{ .en = "expected adjust(\"name\", default)", .ru = "ожидается adjust(\"имя\", умолчание)" },
        .two_adjust => .{ .en = "at most two adjust() values", .ru = "не больше двух значений adjust()" },
        .number_or_adjust => .{ .en = "expected a number or adjust(\"name\", default)", .ru = "ожидается число или adjust(\"имя\", умолчание)" },
        .pattern => .{ .en = "bad pattern list", .ru = "неверный список шаблонов" },
        .unknown_table => .{ .en = "unknown table", .ru = "неизвестная таблица" },
    });
}

/// Class keys and their classic_ids (lower case: `ft_sphinx` → 102).
pub const ClassIds = std.StringHashMapUnmanaged(i32);

/// Rows of one table naming the same entities, one by classic_id and one by class (`ids`):
/// the class row is the one in force, the classic_id row is noted; rows with the same keys:
/// the first is noted.
pub fn overridden(a: Allocator, list: Rows, ids: *const ClassIds, out: *std.ArrayList(Issue)) void {
    inline for (@typeInfo(og.rules.Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(og.rules.Set, f)).pointer.child;
        var got: std.ArrayList(struct { row: Row, line: u32 }) = .empty;
        for (list) |e| if (std.ascii.eqlIgnoreCase(e.kind.call.text, Row.call)) {
            const r = og.loaders.codec.read(Row, a, e.kind.call, null) catch continue;
            got.append(a, .{ .row = r, .line = e.line }) catch {};
        };
        for (got.items, 0..) |x, i| for (got.items[i + 1 ..]) |y| {
            // The same keys again (an editor before rules_rows appended such rows).
            if (og.loaders.codec.sameKey(Row, x.row, y.row)) {
                out.append(a, .{ .line = x.line, .name = Row.call, .msg = tx.alloc(a, tx.code_r_again, .{ Row.call, y.line }) }) catch {};
                continue;
            }
            if (byClassOver(Row, x.row, y.row, ids)) |x_wins| {
                const lost = if (x_wins) y.line else x.line;
                out.append(a, .{ .line = lost, .name = Row.call, .msg = tx.alloc(a, tx.code_r_overridden, .{ Row.call, if (x_wins) x.line else y.line }) }) catch {};
            }
        };
    }
}

/// `x` and `y` key the same entities, one of them by a class the other names by its
/// classic_id: whether `x` is the class one; null otherwise.
fn byClassOver(comptime Row: type, x: Row, y: Row, ids: *const ClassIds) ?bool {
    if (Row.keys.len == 0) return null;
    var x_class = false;
    var y_class = false;
    inline for (Row.keys) |k| {
        if (comptime !@hasField(Row, k ++ "_class")) {
            if (!og.loaders.codec.same(@FieldType(Row, k), @field(x, k), @field(y, k))) return null;
        } else {
            const xc: []const u8 = @field(x, k ++ "_class");
            const yc: []const u8 = @field(y, k ++ "_class");
            const xi = if (xc.len > 0) classId(ids, xc) orelse return null else @field(x, k);
            const yi = if (yc.len > 0) classId(ids, yc) orelse return null else @field(y, k);
            if (xi != yi) return null;
            x_class = x_class or (xc.len > 0 and yc.len == 0);
            y_class = y_class or (yc.len > 0 and xc.len == 0);
        }
    }
    return if (x_class == y_class) null else x_class;
}

fn classId(ids: *const ClassIds, class: []const u8) ?i32 {
    var buf: [96]u8 = undefined;
    if (class.len > buf.len) return null;
    return ids.get(std.ascii.lowerString(&buf, class));
}

// ---------------------------------------------------------------- values naming things

/// Values a game declares, with a name for each (the message lists the nearest).
pub const Known = std.AutoArrayHashMapUnmanaged(i32, []const u8);

/// What the rows name that nothing declares (needs the game: the catalog, the Store,
/// the rules in force; `ids`: the classic_ids the game's scripts declare).
pub fn values(app: *App, a: Allocator, list: Rows, ids: *const Known, out: *std.ArrayList(Issue)) void {
    @import("entry_rules.zig").sync(app);
    var fighters: ?Known = null;
    var weapons: ?Known = null;
    var texts: ?[]const @import("texts.zig").Row = null;
    for (list) |e| {
        const c = e.kind.call;
        const rc = rulesapi.find(c.text) orelse continue;
        for (c.named) |arg_n| {
            const f = rulesapi.field(rc, arg_n.name) orelse continue;
            const val = arg_n.value;
            const arg = val;
            switch (f.ref) {
                .none => {},
                .fighter_class, .weapon_class => {
                    // The calls declaring classes are not checked against themselves.
                    if (std.ascii.eqlIgnoreCase(c.text, "Abilities") or std.ascii.eqlIgnoreCase(c.text, "WeaponClass") or std.ascii.eqlIgnoreCase(c.text, "Pattern")) continue;
                    // A weapon class by name: a row in force or of this file names it.
                    if (f.ref == .weapon_class) if (stringLit(val)) |s| {
                        if (s.len == 0 or og.rules.weaponClassId(s) != null or namedHere(list, s)) continue;
                        out.append(a, .{ .line = arg.line, .name = s, .quoted = true, .msg = tx.alloc(a, tx.code_r_key, .{ f.name, s }) }) catch {};
                        continue;
                    };
                    const n = int(val) orelse continue;
                    const fighter = f.ref == .fighter_class;
                    const set = if (fighter) &(fighters orelse blk: {
                        fighters = fighterClasses(app, a, list);
                        break :blk fighters.?;
                    }) else &(weapons orelse blk: {
                        weapons = weaponClasses(app, a, list);
                        break :blk weapons.?;
                    });
                    if (set.contains(n)) continue;
                    out.append(a, .{ .line = arg.line, .name = f.name, .msg = if (fighter) tx.alloc(a, tx.code_r_class, .{ f.name, n, near(a, set, n) }) else tx.alloc(a, tx.code_r_wclass, .{ f.name, n, near(a, set, n) }) }) catch {};
                },
                .name_id => {
                    // A stage's number: an effect record's too (stray, below).
                    if (int(val) != null and og.compose.og_build.isStage(f.name)) continue;
                    const s: []const u8 = stringLit(val) orelse "";
                    if (int(val)) |n| {
                        if (n > 0 and !ids.contains(n)) out.append(a, .{ .line = arg.line, .name = f.name, .msg = tx.alloc(a, tx.code_r_id, .{ f.name, n, near(a, ids, n) }) }) catch {};
                    } else {
                        var it = std.mem.tokenizeAny(u8, s, " ,");
                        while (it.next()) |tok| {
                            if (std.fmt.parseInt(i32, tok, 10)) |n| {
                                if (n > 0 and !ids.contains(n)) out.append(a, .{ .line = arg.line, .name = f.name, .msg = tx.alloc(a, tx.code_r_id, .{ f.name, n, near(a, ids, n) }) }) catch {};
                            } else |_| if (!hasClass(app, tok)) out.append(a, .{ .line = arg.line, .name = tok, .quoted = true, .msg = tx.alloc(a, tx.code_r_key, .{ f.name, tok }) }) catch {};
                        }
                    }
                },
                .text => {
                    const n = int(val) orelse continue;
                    const rs = texts orelse blk: {
                        texts = @import("texts.zig").rows(app, a, .strings);
                        break :blk texts.?;
                    };
                    // shortcut: no string.tab loaded (a game without it): nothing to check against.
                    if (rs.len == 0 or n <= 0) continue;
                    for (rs) |r| {
                        if (r.id == n) break;
                    } else out.append(a, .{ .line = arg.line, .name = f.name, .msg = tx.alloc(a, tx.code_r_text, .{ f.name, n, rs[0].id, rs[rs.len - 1].id }) }) catch {};
                },
            }
        }
    }
}

/// A stage field's number that names nothing (og_build.strayFx: a weapon block's
/// `effects_from`…, a MonsterAttack row's): no block has it (`ids`, the text's own) and
/// it is no effect record's id (built-in, in force).
pub fn stray(a: Allocator, u: og.script.ogs.parser.Unit, ids: *const Known, out: *std.ArrayList(Issue)) void {
    const b = og.compose.og_build;
    var known = b.effectIds(a, og.core.modules.tables().weapon_fx) catch return;
    for (ids.keys()) |k| known.put(a, k, {}) catch {};
    b.knownIds(a, &known, u) catch {};
    for (b.strayFx(a, u, &known) catch return) |x| out.append(a, .{ .line = x.line, .name = x.field, .msg = tx.alloc(a, tx.code_r_effect, .{ x.field, x.id }) }) catch {};
}

// ---------------------------------------------------------------- fighters' weapons

/// An OpenGorky text's monsters (`fighter` blocks; not the party's heroes: they share its
/// backpack) with a weapon that needs ammo (`ammo = ~i"items::x"`, its own or its
/// archetype's) and no item of that ammo of their own (nested, or the level's block
/// `owner`ed by it): the exe's fighter does not strike with it (combat/weapons.zig
/// hasAmmo). One issue at the weapon.
/// shortcut: a weapon or ammo an instance inherits from its fighter archetype is checked in
/// the archetype's text, an item given by code (item::New) not seen; upgrade with the
/// reader's object list.
pub fn unarmed(app: *App, a: Allocator, u: og.script.ogs.parser.Unit, out: *std.ArrayList(Issue)) void {
    for (u.modules) |m| for (m.entities) |*e| {
        if (std.mem.eql(u8, e.kind, "fighter") or std.mem.eql(u8, e.kind, "hero")) fighterAmmo(app, a, e, &.{}, out);
        // A level's: its fighters and the blocks they own.
        if (std.mem.eql(u8, e.kind, "level") or std.mem.eql(u8, e.kind, "battle")) for (e.children) |*c| if (std.mem.eql(u8, c.kind, "fighter") or std.mem.eql(u8, c.kind, "hero")) fighterAmmo(app, a, c, e.children, out);
    };
}

fn fighterAmmo(app: *App, a: Allocator, f: *const ir.Entity, level: []const ir.Entity, out: *std.ArrayList(Issue)) void {
    // A hero (the party's archetype, `characters::sullivan`).
    for (app.catalog.entries.items) |x| if (x.kind == .hero and std.ascii.eqlIgnoreCase(x.id, f.name)) return;
    for ([_][]const ir.Entity{ f.children, level }) |list| for (list) |*w| {
        if (!std.mem.eql(u8, w.kind, "weapon") or (list.ptr == level.ptr and !ownedBy(w, f.name))) continue;
        const ammo = ammoOf(app, a, w, 0) orelse continue;
        if (!hasItem(f, level, ammo)) out.append(a, .{ .line = w.line, .name = w.name, .msg = tx.alloc(a, tx.code_r_unarmed, .{ f.name, w.name, ammo }) }) catch {};
    };
}

/// Fighter `f` has an item of archetype `path`: nested, or in `level` owned by it.
fn hasItem(f: *const ir.Entity, level: []const ir.Entity, path: []const u8) bool {
    for (f.children) |*it| if (std.mem.eql(u8, it.kind, "item") and std.ascii.eqlIgnoreCase(it.base, path)) return true;
    for (level) |*it| if (std.mem.eql(u8, it.kind, "item") and ownedBy(it, f.name) and std.ascii.eqlIgnoreCase(it.base, path)) return true;
    return false;
}

/// Block `e`'s `owner` is `name` (any case).
fn ownedBy(e: *const ir.Entity, name: []const u8) bool {
    for (e.fields) |x| if (std.mem.eql(u8, x.name, "owner")) return if (og.core.schema.text(x.value)) |s| std.ascii.eqlIgnoreCase(s, name) else false;
    return false;
}

/// The ammo archetype weapon block `w` needs (its `ammo`, else its archetype's); null: none
/// (`thrown`, or no `ammo`).
fn ammoOf(app: *App, a: Allocator, w: *const ir.Entity, depth: u32) ?[]const u8 {
    for (w.fields) |x| {
        if (std.mem.eql(u8, x.name, "thrown")) return null;
        if (std.mem.eql(u8, x.name, "ammo")) return if (x.value.sigil == .item) og.core.schema.text(x.value) else null;
    }
    if (w.base.len == 0 or depth > 8) return null;
    const mo = @import("model_og.zig");
    const b = mo.blockOf(app, a, mo.archetypeFile(app, w.base) orelse return null) orelse return null;
    return ammoOf(app, a, b.e, depth + 1);
}

fn int(e: *const ir.Expr) ?i32 {
    return switch (e.kind) {
        .lit => |v| if (v == .int) v.int else null,
        .unary => |u| if (u.op == .neg) (if (int(u.operand)) |x| -x else null) else null,
        else => null,
    };
}

/// A class key (`"ft_wasp"`): an entity's class script or id.
fn hasClass(app: *App, key: []const u8) bool {
    if (app.store.root != null and battleFighter(app, key)) return true;
    // Any block by its path (a hero's too: the OG reader's number, entry_rules.sync).
    if (std.mem.indexOf(u8, key, "::") != null and og.core.entity.idOf(key) != null) return true;
    // An archetype reference (`~c"characters::jetelmer"`): by its block's name.
    const s = if (std.mem.lastIndexOf(u8, key, "::")) |k| key[k + 2 ..] else key;
    for (app.catalog.entries.items) |e| {
        const b = baseName(e.entry);
        const stem = b[0 .. std.mem.lastIndexOfScalar(u8, b, '.') orelse b.len];
        // An OpenGorky project's inner block (`battles/x/objects.ogs#01pr_hornet02`): by its name.
        const inner = if (std.mem.lastIndexOfScalar(u8, e.entry, '#')) |k| e.entry[k + 1 ..] else "";
        if (std.ascii.eqlIgnoreCase(stem, s) or std.ascii.eqlIgnoreCase(e.id, s) or std.ascii.eqlIgnoreCase(inner, s)) return true;
    }
    return false;
}

/// An OpenGorky project's battle fighter block named `s` (`fighter "04mf_invisible1" {`,
/// `fighter x: characters::y {`): the Abilities rows the editor keys by its object's name.
/// shortcut: a text search of `battles/*/*.ogs`, not a parse; upgrade if a name hides in a comment.
fn battleFighter(app: *App, s: []const u8) bool {
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    const a = tmp.allocator();
    const og_src = @import("store.zig").og_src;
    const heads = [_][]const u8{
        std.fmt.allocPrint(a, "fighter \"{s}\"", .{s}) catch return false,
        std.fmt.allocPrint(a, "fighter {s} ", .{s}) catch return false,
        std.fmt.allocPrint(a, "fighter {s}:", .{s}) catch return false,
    };
    for (app.store.listing(a, og_src, null, false)) |p| {
        if (!std.mem.startsWith(u8, p, "battles/")) continue;
        const f = app.store.file(og_src, p) catch continue;
        const t = app.store.text(f);
        for (heads) |h| if (std.mem.indexOf(u8, t, h) != null) return true;
    }
    return false;
}

/// The classTypes of the game's scripts of `kinds` (the Store's text: unsaved edits and
/// new entities too), named by the entity.
fn scriptClasses(app: *App, set: *Known, a: Allocator, kinds: []const og.loaders.classic.entities.Kind) void {
    const entries = @import("entries.zig");
    for (app.catalog.entries.items) |e| {
        if (std.mem.indexOfScalar(og.loaders.classic.entities.Kind, kinds, e.kind) == null) continue;
        const fi = entries.fileOf(app, e) orelse continue;
        const ct = @import("model.zig").classOf(app.store.text(fi)) orelse continue;
        const gop = set.getOrPut(a, @intFromFloat(ct)) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = if (e.title.len > 0) e.title else e.id;
    }
}

/// Every fighter classType declared: 0 (ordinary), the exe's, the Abilities rows (in
/// force, of this file) and the built-in AiProfile ones, the game's fighter scripts'.
fn fighterClasses(app: *App, a: Allocator, here: Rows) Known {
    var set: Known = .empty;
    set.put(a, 0, tx.get(tx.code_class_other)) catch {};
    inline for (@typeInfo(og.battle.fighter.Class).@"enum".field_names, @typeInfo(og.battle.fighter.Class).@"enum".field_values) |n, x| set.put(a, x, n) catch {};
    for (og.core.modules.tables().classes) |r| _ = set.getOrPutValue(a, r.class, "Abilities") catch {};
    for (og.rules.builtin.ai_profiles) |r| _ = set.getOrPutValue(a, r.class, "AiProfile") catch {};
    declared(a, &set, here, "Abilities");
    scriptClasses(app, &set, a, &.{ .enemy, .hero });
    return set;
}

/// Every weapon classType declared: the exe's, the WeaponClass and Pattern rows (in
/// force, of this file), the game's weapon and attack scripts'.
fn weaponClasses(app: *App, a: Allocator, here: Rows) Known {
    var set: Known = .empty;
    inline for (@typeInfo(og.battle.weapon_class.WeaponClass).@"enum".field_names, @typeInfo(og.battle.weapon_class.WeaponClass).@"enum".field_values) |n, x| set.put(a, x, n) catch {};
    for (og.rules.active.weapon_classes) |r| _ = set.getOrPutValue(a, r.classic_id, "WeaponClass") catch {};
    for (og.rules.active.patterns) |r| _ = set.getOrPutValue(a, r.classic_id, "Pattern") catch {};
    declared(a, &set, here, "WeaponClass");
    declared(a, &set, here, "Pattern");
    scriptClasses(app, &set, a, &.{ .weapon, .attack });
    return set;
}

/// `classic_id = n` of this file's `call` rows.
fn declared(a: Allocator, set: *Known, here: Rows, call: []const u8) void {
    for (here) |e| if (std.ascii.eqlIgnoreCase(e.kind.call.text, call)) for (e.kind.call.named) |arg| {
        if (std.ascii.eqlIgnoreCase(arg.name, "classic_id")) if (int(arg.value)) |n| {
            _ = set.getOrPutValue(a, n, call) catch {};
        };
    };
}

/// A WeaponClass or Pattern row of this file is named `name`.
fn namedHere(here: Rows, name: []const u8) bool {
    for (here) |e| if (std.ascii.eqlIgnoreCase(e.kind.call.text, "WeaponClass") or std.ascii.eqlIgnoreCase(e.kind.call.text, "Pattern")) for (e.kind.call.named) |arg| {
        if (std.ascii.eqlIgnoreCase(arg.name, "name")) if (stringLit(arg.value)) |s| if (std.ascii.eqlIgnoreCase(s, name)) return true;
    };
    return false;
}

/// The (up to six) declared values nearest `n`: `5 monitor, 6 smokerider…`.
fn near(a: Allocator, set: *const Known, n: i32) []const u8 {
    const keys = a.dupe(i32, set.keys()) catch return "";
    const Ctx = struct {
        n: i32,
        fn lt(ctx: @This(), x: i32, y: i32) bool {
            const dx = @abs(x - ctx.n);
            const dy = @abs(y - ctx.n);
            return dx < dy or (dx == dy and x < y);
        }
    };
    std.mem.sort(i32, keys, Ctx{ .n = n }, Ctx.lt);
    const shown = keys[0..@min(6, keys.len)];
    std.mem.sort(i32, shown, {}, std.sort.asc(i32));
    var out: std.ArrayList(u8) = .empty;
    for (shown, 0..) |k, i| out.print(a, "{s}{d} {s}", .{ if (i > 0) ", " else "", k, set.get(k).? }) catch {};
    return out.items;
}

test "rulescheck: fields the call lacks, twice, values that do not read, missing fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\AiProfile(clas = 1);
        \\AiProfile(class = 1, class = 2);
        \\AiProfile(class = 1, scoring = "foo");
        \\AiProfile(class = "x");
        \\AiProfile(class = 1, scoring = "garcia", fighter_class = "ft_wasp");
        \\MonsterAttack(fighter = 999, weapon = 0);
        \\Resist(fighter = 1, zzzzzz = 2);
        \\adjust("name", 3);
        \\MonsterAttack(fighter = 106, anim = "a", hit_delay = adjust("nope", 25) + 5);
        \\AiProfil(class = 1);
    ;
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const unit = og.loaders.codec.parseRows(a, src, &diag).?;
    var out: std.ArrayList(Issue) = .empty;
    rows(a, unit, &out);
    const want = [_]struct { line: u32, name: []const u8, has: []const u8 }{
        .{ .line = 1, .name = "clas", .has = "did you mean 'class'" },
        .{ .line = 2, .name = "class", .has = "twice" },
        .{ .line = 3, .name = "scoring", .has = "\"garcia\"" },
        .{ .line = 4, .name = "class", .has = "expected a number" },
        .{ .line = 6, .name = "MonsterAttack", .has = "anim" },
        .{ .line = 7, .name = "zzzzzz", .has = "fields: fighter, resist, armor" },
        .{ .line = 9, .name = "adjust", .has = "25" },
        .{ .line = 10, .name = "AiProfil", .has = "'AiProfile'" },
    };
    try std.testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, got| {
        try std.testing.expectEqual(w.line, got.line);
        try std.testing.expectEqualStrings(w.name, got.name);
        if (std.mem.indexOf(u8, got.msg, w.has) == null) {
            std.debug.print("rulescheck: {s}\n", .{got.msg});
            return error.TestUnexpectedResult;
        }
    }
}

test "rulescheck: a classic_id row and a class row for the same fighter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\Resist(fighter = 102, armor = -1);
        \\Resist(fighter = 105, armor = -2);
        \\Resist(fighter = "ft_sphinx", resist = "fire", armor = -1);
        \\Resist(fighter = "ft_other", armor = -1);
        \\KillIcon(fighter = 102, icon = "sphinks");
        \\Resist(fighter = "FT_OTHER", armor = -2);
    ;
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const unit = og.loaders.codec.parseRows(a, src, &diag).?;
    var ids: ClassIds = .empty;
    try ids.put(a, "ft_sphinx", 102);
    var out: std.ArrayList(Issue) = .empty;
    overridden(a, unit, &ids, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u32, 1), out.items[0].line);
    try std.testing.expect(std.mem.indexOf(u8, out.items[0].msg, "line 3") != null);
    try std.testing.expectEqual(@as(u32, 4), out.items[1].line);
    try std.testing.expect(std.mem.indexOf(u8, out.items[1].msg, "line 6") != null);
}
