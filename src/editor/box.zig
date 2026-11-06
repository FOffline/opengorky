//! Box contents in a box script (`.itm` including ci_box.s, or a battle `.obs_i`):
//! slots `itm_N = "name1,name2";` (+ `cnt_itm`) in init(), and the objects they name
//! created by `Weapon_New("name","cw_x.s")` / `Item_New("name","ca_x.s"[,count])` in
//! post_init_box() (post_init() for battle boxes); a hero's starting inventory: the
//! calls with its name as the owner. Both are read from the lifted model (model.zig:
//! the slots' values, the calls). The engine finds a box's contents by the slot names,
//! so `write` rebuilds both places from one list (shortcut: by text, the lift cannot
//! add or drop a call; the rebuilt lines are the old path's bytes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const placement = @import("placement.zig");
const model = @import("model.zig");
const lineAfter = @import("code.zig").lineAfter;
const App = @import("app.zig").App;

/// The builtins making an object of a class.
const makers = [_][]const u8{ "Weapon_New", "Item_New" };

pub const Item = struct {
    /// Class file, `cw_crowbar.s`.
    class: []const u8,
    /// Object names, one per unit (all listed in one slot).
    names: std.ArrayList([]const u8) = .empty,
    /// Item_New's count (ammo); null — the class default.
    count: ?i32 = null,

    pub fn weapon(self: Item) bool {
        return std.ascii.startsWithIgnoreCase(self.class, "cw_");
    }
};

/// The script creating the contents: post_init_box() of an exploration box, else post_init().
fn creator(text: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, text, "function post_init_box") != null) "post_init_box" else "post_init";
}

pub fn isBox(text: []const u8) bool {
    return std.ascii.findIgnoreCase(text, "ci_box.s") != null or model.find(text, "itm_1") != null;
}

/// Contents of box script `file` by slot; names its creator does not make are dropped
/// (they make nothing).
pub fn parse(app: *App, a: Allocator, file: usize) ![]Item {
    const ev = creator(app.store.text(file));
    const made = model.calls(app, a, file, &makers);
    var items: std.ArrayList(Item) = .empty;
    var n: usize = 1;
    while (n <= 13) : (n += 1) {
        var key: [8]u8 = undefined;
        const slot = model.ownStr(app, file, std.fmt.bufPrint(&key, "itm_{d}", .{n}) catch unreachable) orelse continue;
        var item: ?Item = null;
        var names = std.mem.tokenizeScalar(u8, slot, ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            const call = for (made) |cl| {
                if (std.ascii.eqlIgnoreCase(cl.event, ev) and std.ascii.eqlIgnoreCase(str(cl, 0) orelse continue, name)) break cl;
            } else continue;
            if (item == null) item = .{ .class = str(call, 1) orelse continue, .count = int(call, 2) };
            // A name twice in a slot makes one object (seen in 01pr_box2).
            for (item.?.names.items) |x| {
                if (std.ascii.eqlIgnoreCase(x, name)) break;
            } else try item.?.names.append(a, name);
        }
        if (item) |i| try items.append(a, i);
    }
    return items.items;
}

/// String argument `k` of a call.
fn str(c: model.Call, k: usize) ?[]const u8 {
    return if (k < c.args.len and c.args[k] == .string) c.args[k].string else null;
}

fn int(c: model.Call, k: usize) ?i32 {
    return if (k < c.args.len and c.args[k] == .int) c.args[k].int else null;
}

const Span = placement.Span;

/// From the `{` after `function <name>` to its matching `}`.
pub fn funcBody(text: []const u8, name: []const u8) ?Span {
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "function {s}(", .{name}) catch return null;
    const p = std.mem.indexOf(u8, text, head) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, p, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return .{ .start = open + 1, .end = i };
        },
        '"' => i = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse return null,
        else => {},
    };
    return null;
}

fn isSlotLine(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "cnt_itm")) return true;
    if (!std.mem.startsWith(u8, t, "itm_")) return false;
    var k: usize = 4;
    while (k < t.len and std.ascii.isDigit(t[k])) k += 1;
    while (k < t.len and (t[k] == ' ' or t[k] == '\t')) k += 1;
    return k > 4 and k < t.len and t[k] == '=';
}

/// `text` with contents `items`: slot lines (at the first old one, else first in
/// init()) and creator calls (first in its body) rebuilt; every other line kept.
pub fn write(gpa: Allocator, text: []const u8, items: []const Item) ![]u8 {
    const nl = placement.newline(text);
    const body = funcBody(text, creator(text)) orelse return error.NoCreator;
    const init_body = funcBody(text, "init") orelse return error.NoInit;
    const calls_at = lineAfter(text, body.start - 1);
    const has_slots = blk: {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| if (isSlotLine(std.mem.trim(u8, l, " \t\r"))) break :blk true;
        break :blk false;
    };
    const slots_at = if (has_slots) null else lineAfter(text, init_body.start - 1);

    var slots: std.ArrayList(u8) = .empty;
    defer slots.deinit(gpa);
    var calls: std.ArrayList(u8) = .empty;
    defer calls.deinit(gpa);
    var used: usize = 0;
    for (items) |item| {
        if (item.names.items.len == 0) continue;
        used += 1;
        try slots.print(gpa, "  itm_{d} = \"", .{used});
        for (item.names.items, 0..) |name, k| {
            if (k > 0) try slots.append(gpa, ',');
            try slots.appendSlice(gpa, name);
            const f = if (item.weapon()) "Weapon_New" else "Item_New";
            if (item.count) |c| {
                try calls.print(gpa, "  {s}(\"{s}\",\"{s}\",{d});{s}", .{ f, name, item.class, c, nl });
            } else try calls.print(gpa, "  {s}(\"{s}\",\"{s}\");{s}", .{ f, name, item.class, nl });
        }
        try slots.print(gpa, "\";{s}", .{nl});
    }
    try slots.print(gpa, "  cnt_itm={d};{s}", .{ used, nl });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var slots_done = false;
    var i: usize = 0;
    while (i < text.len) {
        const e = lineAfter(text, i);
        const t = std.mem.trim(u8, text[i..e], " \t\r\n");
        const in_body = i >= body.start and i < body.end;
        if (slots_at == i and !slots_done) {
            try out.appendSlice(gpa, slots.items);
            slots_done = true;
        }
        if (i == calls_at) try out.appendSlice(gpa, calls.items);
        if (isSlotLine(t)) {
            if (!slots_done) try out.appendSlice(gpa, slots.items);
            slots_done = true;
        } else if (!(in_body and (std.mem.startsWith(u8, t, "Weapon_New(") or std.mem.startsWith(u8, t, "Item_New(")))) {
            try out.appendSlice(gpa, text[i..e]);
        }
        i = e;
    }
    var result = try out.toOwnedSlice(gpa);
    // Slots past those the script declares, after its last `string itm_N;`.
    for (1..used + 1) |n| {
        var d: [24]u8 = undefined;
        const decl = std.fmt.bufPrint(&d, "string itm_{d};", .{n}) catch unreachable;
        if (std.mem.indexOf(u8, result, decl) != null) continue;
        const last = std.mem.lastIndexOf(u8, result, "string itm_") orelse {
            if (try model.declare(gpa, result, decl)) |next| {
                gpa.free(result);
                result = next;
            }
            continue;
        };
        const at = lineAfter(result, last);
        const next = try std.mem.concat(gpa, u8, &.{ result[0..at], decl, nl, result[at..] });
        gpa.free(result);
        result = next;
    }
    return result;
}

/// A starting inventory: the `Item_New`/`Weapon_New(name, class, "<owner>"[, count])`
/// calls of hero script `file`, by class in their order.
pub fn parseOwned(app: *App, a: Allocator, file: usize, owner: []const u8) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    for (ownedCalls(app, a, file, owner)) |call| {
        const class = str(call, 1).?;
        const it = for (items.items) |*x| {
            if (std.ascii.eqlIgnoreCase(x.class, class)) break x;
        } else blk: {
            try items.append(a, .{ .class = class, .count = int(call, 3) });
            break :blk &items.items[items.items.len - 1];
        };
        try it.names.append(a, str(call, 0).?);
    }
    return items.items;
}

/// The calls of `file` making an object for `owner`.
fn ownedCalls(app: *App, a: Allocator, file: usize, owner: []const u8) []const model.Call {
    var out: std.ArrayList(model.Call) = .empty;
    for (model.calls(app, a, file, &makers)) |c| {
        if (str(c, 0) == null or str(c, 1) == null or !std.ascii.eqlIgnoreCase(str(c, 2) orelse continue, owner)) continue;
        out.append(a, c) catch {};
    }
    return out.items;
}

/// The owner of hero script `file`'s first call making an object, a slice of its text
/// (as long-lived as the old text was; null: none).
pub fn ownerOf(app: *App, a: Allocator, file: usize) ?[]const u8 {
    for (model.calls(app, a, file, &makers)) |c| if (str(c, 2) != null) {
        const sp = c.arg_spans[2];
        return app.store.text(file)[sp.start + 1 .. sp.end - 1];
    };
    return null;
}

/// The item whose names include `name`.
fn holder(items: []const Item, name: []const u8) ?Item {
    for (items) |it| for (it.names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) return it;
    return null;
}

/// Hero script `file`'s starting inventory of `owner` changed to `items` in place, one
/// undo step: a count the call has is its literal (through the exporter when nothing else
/// changes); lines of names gone are removed, a count the call lacks becomes a last
/// argument, new names go after the last line of their class (else after the owner's
/// last call, else first in post_init()); every other line stays as it is.
pub fn writeOwned(app: *App, file: usize, items: []const Item, owner: []const u8) !void {
    const gpa = app.gpa;
    const text = app.store.text(file);
    const nl = placement.newline(text);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const old = ownedCalls(app, a, file, owner);
    var edits: std.ArrayList(placement.Edit) = .empty;
    var counts: std.ArrayList(model.ArgSet) = .empty;
    var last_owned: ?usize = null;
    for (old) |call| {
        var i = call.span.start;
        while (i > 0 and text[i - 1] != '\n') i -= 1;
        const e = lineAfter(text, call.span.start);
        last_owned = e;
        const now = holder(items, str(call, 0).?) orelse {
            try edits.append(a, .{ .span = .{ .start = i, .end = e }, .text = "" });
            continue;
        };
        const cnt = now.count orelse continue;
        if (int(call, 3)) |c| {
            if (c != cnt) try counts.append(a, .{ .call = call, .index = 3, .value = .{ .int = cnt } });
        } else {
            // A new last argument, before the call's `)`.
            const close = call.span.end - 1;
            try edits.append(a, .{ .span = .{ .start = close, .end = close }, .text = try std.fmt.allocPrint(a, ", {d}", .{cnt}) });
        }
    }
    // New names, after their class's last line (else the owner's last call).
    for (items) |it| for (it.names.items) |name| {
        if (for (old) |call| {
            if (std.ascii.eqlIgnoreCase(str(call, 0).?, name)) break true;
        } else false) continue;
        var at: ?usize = null;
        for (old) |call| if (std.ascii.eqlIgnoreCase(str(call, 1).?, it.class)) {
            at = lineAfter(text, call.span.start);
        };
        const pos = at orelse last_owned orelse blk: {
            const body = funcBody(text, "post_init") orelse return error.NoPostInit;
            break :blk lineAfter(text, body.start - 1);
        };
        const f = if (it.weapon()) "Weapon_New" else "Item_New";
        const line = if (it.count) |cnt|
            try std.fmt.allocPrint(a, "\t{s}(\"{s}\", \"{s}\", \"{s}\", {d});{s}", .{ f, name, it.class, owner, cnt, nl })
        else
            try std.fmt.allocPrint(a, "\t{s}(\"{s}\", \"{s}\", \"{s}\");{s}", .{ f, name, it.class, owner, nl });
        try edits.append(a, .{ .span = .{ .start = pos, .end = pos }, .text = line });
    };
    if (edits.items.len == 0) {
        if (counts.items.len > 0) try model.setArgs(app, file, counts.items, null);
        return;
    }
    // With lines added or cut the counts go as text too (one step).
    for (counts.items) |x| {
        const sp = x.call.arg_spans[x.index];
        try edits.append(a, .{ .span = .{ .start = sp.start, .end = sp.end }, .text = try std.fmt.allocPrint(a, "{d}", .{x.value.int}) });
    }
    // Inserts at one point keep their order (apply sorts by start, stable for equal ones).
    const out = try placement.apply(gpa, text, edits.items);
    app.store.replace(file, out) catch |err| {
        gpa.free(out);
        return err;
    };
}

const sample =
    "#include ci_box.s\r\n" ++
    "string itm_1;\r\nstring itm_2;\r\n" ++
    "function init()\r\n{\r\n" ++
    "  itm_1 = \"b_crowbar1\";\r\n" ++
    "  itm_2 = \"b_food1,b_food2\";\r\n" ++
    "  cnt_itm=2;\r\n" ++
    "};\r\n" ++
    "function post_init_box()\r\n{\r\n" ++
    "  Weapon_New(\"b_crowbar1\",\"cw_crowbar.s\");\r\n" ++
    "  //Item_New(\"old\",\"ci_food.s\");\r\n" ++
    "  Item_New(\"b_food1\",\"ci_food.s\");\r\n" ++
    "  Item_New(\"b_food2\",\"ci_food.s\");\r\n" ++
    "};\r\n";

test "box: write back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The sample's contents (parse reads them from the model), one food less, pistol ammo
    // with a count in a third slot.
    var crowbar: Item = .{ .class = "cw_crowbar.s" };
    try crowbar.names.append(a, "b_crowbar1");
    var food: Item = .{ .class = "ci_food.s" };
    try food.names.append(a, "b_food1");
    var ammo: Item = .{ .class = "ca_pistolammo.s", .count = 24 };
    try ammo.names.append(a, "b_ammo1");
    const out = try write(std.testing.allocator, sample, &.{ crowbar, food, ammo });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "string itm_2;\r\nstring itm_3;\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  itm_2 = \"b_food1\";\r\n  itm_3 = \"b_ammo1\";\r\n  cnt_itm=3;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item_New(\"b_food2\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  Item_New(\"b_ammo1\",\"ca_pistolammo.s\",24);\r\n  //Item_New(\"old\"") != null);
}
