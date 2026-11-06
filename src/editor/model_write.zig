//! The writing side of the editor's entity fields (model.zig reads them, re-exports
//! these): a lifted value rewritten by the Classic exporter (only its literal), a call's
//! arguments, a new line where the file does not set a field yet, a `.var` start value,
//! a declaration. Each write is one undo step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const classic_names = og.script.classic.names;
const script = og.script;
const lift = script.classic.lift;
const Value = script.value.Value;
const placement = @import("placement.zig");
const level = @import("level.zig");
const App = @import("app.zig").App;
const common_archive = @import("store.zig").common_archive;
const model = @import("model.zig");
const Model = model.Model;
const Call = model.Call;
const modelOf = model.modelOf;
const show = model.show;
const find = model.find;
const get = model.get;
const getStr = model.getStr;

/// Sets `names` of entity `file` to `v` (as typed: a number, or a string in quotes) in
/// the file itself, one undo step: a value the model lifted from the file is rewritten by
/// the exporter (only its literal); a missing one is a new line after the line holding
/// `after` (null or not found: at the end).
pub fn set(app: *App, file: usize, names: []const []const u8, v: []const u8, after: ?[]const u8) !void {
    const pairs = try app.store.gpa.alloc([2][]const u8, names.len);
    defer app.store.gpa.free(pairs);
    for (names, pairs) |n, *p| p.* = .{ n, v };
    return setEach(app, file, pairs, after);
}

/// `set` of several fields, each its own value (name, value as typed), one undo step.
pub fn setEach(app: *App, file: usize, pairs: []const [2][]const u8, after: ?[]const u8) !void {
    if (model.model_og.isOg(app, file)) return model.model_og.setEach(app, file, pairs);
    const st = &app.store;
    const old = st.text(file);
    var rest: std.ArrayList([2][]const u8) = .empty;
    defer rest.deinit(st.gpa);
    var t: []u8 = blk: {
        if (modelOf(app, file)) |m| if (exported(app, m, old, pairs, &rest)) |x| break :blk x else |err| {
            std.log.warn("model: {s} through the exporter: {t}; written as text", .{ st.files.items[file].entry, err });
        };
        rest.clearRetainingCapacity();
        try rest.appendSlice(st.gpa, pairs);
        break :blk try st.gpa.dupe(u8, old);
    };
    errdefer st.gpa.free(t);
    for (rest.items) |p| {
        // A Classic file: a new line by the exe's spelling (classic/names.zig).
        const next = try textSet(st.gpa, t, classic_names.anyOld(p[0]) orelse p[0], p[1], after);
        st.gpa.free(t);
        t = next;
    }
    try st.replace(file, t);
}

/// Argument `index` of call `call` (one `calls` gave) set to `value`.
pub const ArgSet = struct { call: Call, index: usize, value: Value };

/// Sets arguments of entity `file`'s own calls, one undo step labelled `label`: by the
/// exporter (only the literals' bytes change); a call the model no longer lifts as it was
/// (the text changed under it, an argument from a constant) gets the literal written at
/// the argument's bytes, as typed text, with a warning in the log.
pub fn setArgs(app: *App, file: usize, sets: []const ArgSet, label: ?[]const u8) !void {
    const st = &app.store;
    const old = st.text(file);
    const t = blk: {
        if (modelOf(app, file)) |m| if (argsExported(app, m, sets)) |x| break :blk x else |err| {
            std.log.warn("model: {s} call arguments through the exporter: {t}; written as text", .{ st.files.items[file].entry, err });
        };
        var scratch: std.heap.ArenaAllocator = .init(st.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const edits = try a.alloc(placement.Edit, sets.len);
        for (sets, edits) |x, *e| {
            if (x.index >= x.call.arg_spans.len) return error.NoArgument;
            const sp = x.call.arg_spans[x.index];
            e.* = .{ .span = .{ .start = sp.start, .end = sp.end }, .text = try literalText(a, x.value) };
        }
        break :blk try placement.apply(st.gpa, old, edits);
    };
    try st.replaceLabeled(file, t, label);
}

fn argsExported(app: *App, m: *Model, sets: []const ArgSet) ![]u8 {
    var scratch: std.heap.ArenaAllocator = .init(app.store.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const items = try itemsOf(a, m);
    const touched = try a.alloc(bool, m.events.len);
    @memset(touched, false);
    for (sets) |x| {
        const k, const it = found: for (items, 0..) |list, k| {
            for (list) |*it| if (it.* == .call and std.mem.eql(u8, it.call.origin.file, m.key) and it.call.origin.span.start == x.call.span.start) break :found .{ k, it };
        } else return error.NoCall;
        if (x.index >= it.call.args.len) return error.NoArgument;
        const args = try a.dupe(Value, it.call.args);
        args[x.index] = x.value;
        it.call.args = args;
        touched[k] = true;
    }
    return exportItems(app.store.gpa, a, m, items, touched);
}

/// A value as a Classic literal (a float with its dot, as the Classic printer writes it).
pub fn literalText(a: Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| std.fmt.allocPrint(a, "\"{s}\"", .{s}),
        .int => show(a, v),
        .float => |f| std.fmt.allocPrint(a, "{d}{s}", .{ f, if (@abs(f) == @trunc(@abs(f)) and std.math.isFinite(f)) ".0" else "" }),
        else => error.NotLiteral,
    };
}

/// A copy of the model's items per event (to change before `exportItems`).
fn itemsOf(a: Allocator, m: *const Model) ![][]lift.Item {
    const items = try a.alloc([]lift.Item, m.events.len);
    for (m.events, items) |e, *x| x.* = try a.dupe(lift.Item, e.l.items);
    return items;
}

/// The entity's text with the events' items as `items` (`touched`: the changed events)
/// put back into their statements and written by the exporter.
fn exportItems(gpa: Allocator, a: Allocator, m: *Model, items: []const []lift.Item, touched: []const bool) ![]u8 {
    const Export = script.classic.@"export".Export;
    var changes: std.ArrayList(script.classic.@"export".Change) = .empty;
    for (m.events, items, touched) |e, list, tch| if (tch)
        try changes.append(a, .{ .old = e.f, .new = try lift.unlift(a, e.f, .{ .items = list, .rest = e.l.rest }) });
    var ex: Export = .init(a, m.rt.importEnv());
    try ex.apply(changes.items);
    if (ex.files.count() != 1) return error.OtherFiles;
    const new = ex.files.get(m.key) orelse return error.OtherFiles;
    return gpa.dupe(u8, new);
}

/// `old` with the lifted literals of `pairs`' names set to their values (the exporter's
/// text); the pairs it did not write go to `rest` (none lifted where the text's last
/// assignment is).
fn exported(app: *App, m: *Model, old: []const u8, pairs: []const [2][]const u8, rest: *std.ArrayList([2][]const u8)) ![]u8 {
    const gpa = app.store.gpa;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const items = try itemsOf(a, m);
    var touched = try a.alloc(bool, m.events.len);
    @memset(touched, false);
    for (pairs) |p| {
        const n = p[0];
        const val = parseTyped(p[1]);
        // The literal the text's last assignment holds (where a page reads the value).
        const at = find(old, n);
        if (at != null and val != null) if (lifted: for (items, 0..) |list, k| {
            for (list) |*it| if (it.* == .field and std.mem.eql(u8, it.field.origin.file, m.key) and
                it.field.origin.span.start == at.?.start and it.field.origin.span.end == at.?.end)
            {
                it.field.value = val.?;
                break :lifted k;
            };
        } else null) |k| {
            touched[k] = true;
            continue;
        };
        try rest.append(gpa, p);
    }
    if (std.mem.indexOfScalar(bool, touched, true) == null) return gpa.dupe(u8, old);
    return exportItems(gpa, a, m, items, touched);
}

/// A typed value as a literal of the model: "text" a string, with a dot a float, else an
/// int; null: none of those (written as typed).
fn parseTyped(v: []const u8) ?Value {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
        const s = v[1 .. v.len - 1];
        return if (std.mem.indexOfAny(u8, s, "\"\r\n") == null) .{ .string = s } else null;
    }
    if (std.mem.indexOfScalar(u8, v, '.') != null) {
        const f = std.fmt.parseFloat(f32, v) catch return null;
        return if (std.math.isFinite(f)) .{ .float = f } else null;
    }
    return .{ .int = std.fmt.parseInt(i32, v, 10) catch return null };
}

/// Removes the own values of `names` from entity `file` (back to the layer under them),
/// one undo step. shortcut: the line of the text's last assignment is cut, until the lift
/// can drop a field (the exporter keeps a comment sharing its line).
pub fn unset(app: *App, file: usize, names: []const []const u8) !void {
    if (model.model_og.isOg(app, file)) return model.model_og.unset(app, file, names);
    const st = &app.store;
    var t = try st.gpa.dupe(u8, st.text(file));
    errdefer st.gpa.free(t);
    for (names) |n| if (try textUnset(st.gpa, t, n)) |next| {
        st.gpa.free(t);
        t = next;
    };
    try st.replace(file, t);
}

/// Level `name`'s variable `key` starts at `v`: its line in `variables\<name>.var`
/// (the `.var` layer; the file made if missing), one undo step.
pub fn setStart(app: *App, name: []const u8, key: []const u8, v: []const u8) !void {
    var buf: [256]u8 = undefined;
    const entry = try std.fmt.bufPrint(&buf, "variables\\{s}.var", .{name});
    if (app.store.file(common_archive, entry)) |f| {
        const t = try level.setVarLine(app.gpa, app.store.text(f), key, v);
        return app.store.replaceLabeled(f, t, key);
    } else |_| {}
    const t = try std.fmt.allocPrint(app.gpa, "{s}={s}\r\n", .{ key, v });
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try app.frame.allocator().dupe(u8, entry), .text = t }});
}

/// The text of a `.var` value of level `name` (null: none).
pub fn start(app: *App, name: []const u8, key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "variables\\{s}.var", .{name}) catch return null) catch return null;
    var it = std.mem.splitScalar(u8, app.store.text(f), '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \r");
        if (l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == '=') return l[key.len + 1 ..];
    }
    return null;
}

/// `text` with declaration `decl` ("string effect;") after its leading directives
/// (`#include Weapon.s`, `#inherit …`, past comments), unless it already declares
/// that variable; null — nothing to add. shortcut: a declaration by text, until the
/// model has class headers.
pub fn declare(gpa: Allocator, text: []const u8, decl: []const u8) !?[]u8 {
    var words = std.mem.tokenizeAny(u8, decl, " \t;");
    const ty = words.next() orelse return null;
    const name = words.next() orelse return null;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n;,");
    var prev: []const u8 = "";
    while (it.next()) |w| {
        if (std.mem.eql(u8, prev, ty) and std.ascii.eqlIgnoreCase(w, name)) return null;
        prev = w;
    }
    const nl = placement.newline(text);
    var at: usize = if (std.mem.indexOfScalar(u8, text, '\n')) |e| e + 1 else text.len;
    var pos: usize = 0;
    while (pos < text.len) {
        const e = if (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |x| x + 1 else text.len;
        const t = std.mem.trim(u8, text[pos..e], " \t\r\n");
        if (t.len > 0 and t[0] == '#') {
            at = e;
        } else if (!(t.len == 0 or std.mem.startsWith(u8, t, "//"))) break;
        pos = e;
    }
    const line = try std.fmt.allocPrint(gpa, "{s}{s}", .{ decl, nl });
    defer gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = at, .end = at }, .text = line }};
    return try placement.apply(gpa, text, &edits);
}

/// `text` with `name` set to `v`: the last assignment changed, or a new line after
/// the line holding `after` (null or missing — at the end). shortcut: by text, for a text
/// not in the Store yet (a new file, a copy). A Classic text: a new line by the exe's
/// spelling (classic/names.zig).
pub fn setIn(gpa: Allocator, text: []const u8, name: []const u8, v: []const u8, after: ?[]const u8) ![]u8 {
    return textSet(gpa, text, classic_names.anyOld(name) orelse name, v, after);
}

fn textSet(gpa: Allocator, text: []const u8, name: []const u8, v: []const u8, after: ?[]const u8) ![]u8 {
    if (find(text, name)) |s| {
        var edits = [_]placement.Edit{.{ .span = s, .text = v }};
        return placement.apply(gpa, text, &edits);
    }
    const nl = placement.newline(text);
    const at: usize = blk: {
        const a = after orelse break :blk text.len;
        const p = std.ascii.findIgnoreCase(text, a) orelse break :blk text.len;
        break :blk if (std.mem.indexOfScalarPos(u8, text, p, '\n')) |e| e + 1 else text.len;
    };
    const lead = if (at == text.len and text.len > 0 and text[text.len - 1] != '\n') nl else "";
    const line = try std.fmt.allocPrint(gpa, "{s}    {s} = {s};{s}", .{ lead, name, v, nl });
    defer gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = at, .end = at }, .text = line }};
    return placement.apply(gpa, text, &edits);
}

/// `text` without the line of the last assignment to `name`; null — none.
fn textUnset(gpa: Allocator, text: []const u8, name: []const u8) !?[]u8 {
    const s = find(text, name) orelse return null;
    var a = s.start;
    while (a > 0 and text[a - 1] != '\n') a -= 1;
    var b = s.end;
    while (b < text.len and text[b] != '\n') b += 1;
    if (b < text.len) b += 1;
    var edits = [_]placement.Edit{.{ .span = .{ .start = a, .end = b }, .text = "" }};
    return try placement.apply(gpa, text, &edits);
}

const ftr =
    "#include Fighter.s\r\n" ++
    "function init()\r\n" ++
    "{\r\n" ++
    "#include ft_garcia.ss\r\n" ++
    "};\r\n" ++
    "function post_init()\r\n" ++
    "{\r\n" ++
    "  //hp = 5;\r\n" ++
    "};\r\n";

test "declarations, typed values" {
    const gpa = std.testing.allocator;
    const t = "#include Weapon.s\nfunction class_init()\n{\n  spriteFile=\"axe\";\n  max_damage = 20;\n  type = 7;\n};\n";
    try std.testing.expectEqualStrings("axe", getStr(t, "spriteFile").?);
    const a = try textSet(gpa, t, "spriteFile", "\"knife\"", null);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("knife", getStr(a, "spriteFile").?);
    const b = (try declare(gpa, a, "string effect;")).?;
    defer gpa.free(b);
    try std.testing.expect(std.mem.startsWith(u8, b, "#include Weapon.s\nstring effect;\nfunction"));
    try std.testing.expectEqual(null, try declare(gpa, b, "string effect;"));
    // A copy's mark comes first: declarations still go after the include.
    const c = (try declare(gpa, "// copy\n#include Weapon.s\n\nfunction f() {};", "string title;")).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings("// copy\n#include Weapon.s\nstring title;\n\nfunction f() {};", c);
    try std.testing.expectEqual(Value{ .int = -5 }, parseTyped("-5").?);
    try std.testing.expectEqual(Value{ .float = 1.5 }, parseTyped("1.5").?);
    try std.testing.expectEqualStrings("x", parseTyped("\"x\"").?.string);
    try std.testing.expectEqual(null, parseTyped("1e"));
}

test "set and unset an override after the include" {
    const gpa = std.testing.allocator;
    const a = try textSet(gpa, ftr, "hp", "80", "#include ft_");
    defer gpa.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "#include ft_garcia.ss\r\n    hp = 80;\r\n};") != null);
    const b = try textSet(gpa, a, "hp", "95", "#include ft_");
    defer gpa.free(b);
    try std.testing.expectEqual(95, get(b, "hp").?);
    const c = (try textUnset(gpa, b, "hp")).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings(ftr, c);
    const d = try textSet(gpa, "x = 1;", "y", "2", null);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("x = 1;\n    y = 2;\n", d);
}
