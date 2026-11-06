//! Save files. Our own text format (no original saves to copy), one block per object.
//! Every visited location is stored: all script objects with vars, flags and actor
//! state. Loading recreates the location (init/restore), then applies the saved state;
//! objects created during play (Weapon_New, Item_New) are recreated from their class
//! file, deleted ones are deleted.
//!
//! ```
//! OGSAVE 1
//! current 01_port
//! hero Sullivan
//! name <save name>
//! imm <monster id> <mask>
//! world 01_port
//! obj <name> <class> <kind> <flags> <floor> <state> <points>
//! var <name> i:<int> | f:<float> | s:<escaped string> | b:<0 or 1> | v:<literal>
//! comp <component>
//! var …
//! skill <id> <level> <count>
//! anim <reverse> <animation>
//! walk <allow> <floor> <area>
//! sub <host#component> <method> <escaped event>
//! end
//! ```
//!
//! `v:` holds an OpenGorky value a line of its own cannot: a list, a record (a struct is a
//! map of its fields), a reference, nil — as an OG Script literal on one line: `nil`,
//! `true`, `42`, `2.5` (a float always has `.`, `e`, `inf` or `nan`), `"text"` (`\\`, `\"`,
//! `\n`, `\r`), `@"name"` (an object; a component instance `@"host#Component"`), `[a, b]`,
//! `{k: v, …}`: `var wave v:[{"turn": 3, "who": @"01_port::grandma"}]` (a reference's
//! name: world/snapshot.zig detach). `comp`: the `var` lines after it, up to the next
//! `comp` or `obj`, are those of the object's component instance of that name. `sub`: an
//! `events::Subscribe` of the location, in subscription order. A file with `v:`, `comp` or
//! `sub` lines is `OGSAVE 2` (an older engine refuses it instead of misreading it), else
//! `OGSAVE 1` as before; both are read.
//!
//! A parser: it reads and writes the core's records (world/saved.zig `Save`) by their
//! shape, as std.json does, and imports no core; composition (compose/save.zig) gives
//! it the record type and the monster ids of the `imm` masks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("script.zig").value.Value;

/// `self` (a `Save` of world/saved.zig) as save text; `fighters`: the monster ids its
/// `imm` masks are indexed by.
pub fn write(self: anytype, fighters: []const i32, out: *std.Io.Writer) !void {
    var v2 = false;
    for (self.worlds.items) |ws| {
        v2 = v2 or ws.subs.len > 0;
        for (ws.objects) |o| {
            v2 = v2 or o.comps.len > 0;
            for (o.vars) |v| v2 = v2 or literal(v.value);
        }
    }
    try out.print("OGSAVE {d}\ncurrent {s}\nhero {s}\nname {s}\n", .{ @as(u8, if (v2) 2 else 1), self.current, self.hero, self.name });
    // Discovered monster resistances (the exe saves table 0x6d2070).
    for (fighters, self.imm) |id, k| if (k != 0) try out.print("imm {d} {d}\n", .{ id, k });
    for (self.worlds.items) |ws| {
        try out.print("world {s}\n", .{ws.level});
        for (ws.objects) |o| {
            const flags: u8 = @as(u8, @intFromBool(o.enabled)) | @as(u8, @intFromBool(o.deleted)) << 1 | @as(u8, @intFromBool(o.placed)) << 2 | @as(u8, @intFromBool(o.hero)) << 3 | @as(u8, @intFromBool(o.idle_off)) << 4;
            try out.print("obj {s} {s} {t} {d} {d} {d} {d}\n", .{ o.name, o.class_file, o.kind, flags, o.map, o.state, o.stat_points });
            try writeVars(out, o.vars);
            for (o.comps) |c| {
                try out.print("comp {s}\n", .{c.name});
                try writeVars(out, c.vars);
            }
            for (o.skills) |sk| try out.print("skill {d} {d} {d}\n", .{ sk.id, sk.level, sk.count });
            if (o.anim.len > 0) try out.print("anim {d} {s}\n", .{ @intFromBool(o.anim_reverse), o.anim });
            if (o.idle_anim.len > 0) try out.print("idle {s}\n", .{o.idle_anim});
        }
        for (ws.walk) |wa| try out.print("walk {d} {d} {s}\n", .{ @intFromBool(wa.allow), wa.floor, wa.name });
        for (ws.subs) |sb| {
            try out.print("sub {s} {s} ", .{ sb.inst, sb.handler });
            try escape(out, sb.event);
            try out.writeByte('\n');
        }
        try out.writeAll("end\n");
    }
}

fn writeVars(out: *std.Io.Writer, vars: anytype) !void {
    for (vars) |v| {
        try out.print("var {s} ", .{v.name});
        switch (v.value) {
            .int => |i| try out.print("i:{d}\n", .{i}),
            .float => |f| try out.print("f:{d}\n", .{f}),
            .string => |s| {
                try out.writeAll("s:");
                try escape(out, s);
                try out.writeByte('\n');
            },
            .bool => |b| try out.print("b:{d}\n", .{@intFromBool(b)}),
            .nil, .list, .map, .ref => {
                try out.writeAll("v:");
                try writeValue(out, v.value);
                try out.writeByte('\n');
            },
        }
    }
}

/// Save text as records of type `Save` (world/saved.zig); `fighters` as `write`'s.
/// error.BadSave: not a save, or cut short.
pub fn parse(comptime Save: type, gpa: Allocator, text: []const u8, fighters: []const i32) !Save {
    var s: Save = .init(gpa);
    errdefer s.deinit();
    const a = s.arena.allocator();
    var lines = std.mem.splitScalar(u8, text, '\n');
    const head = lines.next() orelse return error.BadSave;
    const version = std.mem.trimEnd(u8, head, "\r");
    if (!std.mem.eql(u8, version, "OGSAVE 1") and !std.mem.eql(u8, version, "OGSAVE 2")) return error.BadSave;
    var objs: std.ArrayList(Save.Obj) = .empty;
    var vars: std.ArrayList(Save.Var) = .empty;
    var skills: std.ArrayList(Save.Skill) = .empty;
    var walk: std.ArrayList(Save.Walk) = .empty;
    var comps: std.ArrayList(Save.Comp) = .empty;
    var subs: std.ArrayList(Save.Sub) = .empty;
    var level: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const key = line[0..sp];
        const rest = if (sp < line.len) line[sp + 1 ..] else "";
        if (std.mem.eql(u8, key, "current")) {
            s.current = try a.dupe(u8, rest);
        } else if (std.mem.eql(u8, key, "imm")) {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const id = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            const mask = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            for (fighters, &s.imm) |f, *k| if (f == id) {
                k.* = mask;
            };
        } else if (std.mem.eql(u8, key, "hero")) {
            s.hero = try a.dupe(u8, rest);
        } else if (std.mem.eql(u8, key, "name")) {
            s.name = try a.dupe(u8, rest);
        } else if (std.mem.eql(u8, key, "world")) {
            if (level != null) return error.BadSave; // previous section lacks "end"
            level = try a.dupe(u8, rest);
            objs = .empty;
            walk = .empty;
            subs = .empty;
        } else if (std.mem.eql(u8, key, "walk")) {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const allow = (std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0) != 0;
            const floor = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
            try walk.append(a, .{ .name = try a.dupe(u8, it.rest()), .allow = allow, .floor = floor });
        } else if (std.mem.eql(u8, key, "sub")) {
            var it = std.mem.splitScalar(u8, rest, ' ');
            const inst = it.next() orelse return error.BadSave;
            const handler = it.next() orelse return error.BadSave;
            try subs.append(a, .{ .inst = try a.dupe(u8, inst), .handler = try a.dupe(u8, handler), .event = try unescape(a, it.rest()) });
        } else if (std.mem.eql(u8, key, "comp")) {
            if (objs.items.len == 0) return error.BadSave;
            try flushVars(Save, a, &objs, &comps, &vars);
            try comps.append(a, .{ .name = try a.dupe(u8, rest), .vars = &.{} });
        } else if (std.mem.eql(u8, key, "obj")) {
            try finishObj(Save, a, &objs, &vars, &skills, &comps);
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const name = it.next() orelse return error.BadSave;
            const cls = it.next() orelse return error.BadSave;
            const kind = std.meta.stringToEnum(@FieldType(Save.Obj, "kind"), it.next() orelse "") orelse .other;
            const flags = try std.fmt.parseInt(u8, it.next() orelse "0", 10);
            const map = try std.fmt.parseInt(u8, it.next() orelse "0", 10);
            const state = try std.fmt.parseInt(u8, it.next() orelse "0", 10);
            // State indexes the actor's idle tables (apply → pickIdle).
            if (state >= Save.max_states) return error.BadSave;
            try objs.append(a, .{
                .name = try a.dupe(u8, name),
                .class_file = try a.dupe(u8, cls),
                .kind = kind,
                .enabled = flags & 1 != 0,
                .deleted = flags & 2 != 0,
                .placed = flags & 4 != 0,
                .hero = flags & 8 != 0,
                .idle_off = flags & 16 != 0,
                .map = @intCast(map & 1),
                .state = state,
                .stat_points = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
                .vars = &.{},
                .skills = &.{},
            });
        } else if (std.mem.eql(u8, key, "var")) {
            const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const name = rest[0..sp2];
            const v = rest[sp2 + 1 ..];
            if (v.len < 2) continue;
            const value: Value = switch (v[0]) {
                'i' => .{ .int = try std.fmt.parseInt(i32, v[2..], 10) },
                'f' => .{ .float = try std.fmt.parseFloat(f32, v[2..]) },
                'b' => .{ .bool = !std.mem.eql(u8, v[2..], "0") },
                'v' => blk: {
                    var at: usize = 2;
                    const x = try readValue(a, v, &at);
                    if (at != v.len) return error.BadSave;
                    break :blk x;
                },
                else => .{ .string = try unescape(a, v[2..]) },
            };
            try vars.append(a, .{ .name = try a.dupe(u8, name), .value = value });
        } else if (std.mem.eql(u8, key, "anim")) {
            if (objs.items.len == 0) continue;
            const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const last = &objs.items[objs.items.len - 1];
            last.anim_reverse = !std.mem.eql(u8, rest[0..sp2], "0");
            last.anim = try a.dupe(u8, rest[sp2 + 1 ..]);
        } else if (std.mem.eql(u8, key, "idle")) {
            if (objs.items.len > 0) objs.items[objs.items.len - 1].idle_anim = try a.dupe(u8, rest);
        } else if (std.mem.eql(u8, key, "skill")) {
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            try skills.append(a, .{
                .id = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
                .level = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
                .count = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
            });
        } else if (std.mem.eql(u8, key, "end")) {
            try finishObj(Save, a, &objs, &vars, &skills, &comps);
            try s.worlds.append(a, .{ .level = level orelse return error.BadSave, .objects = objs.items, .walk = walk.items, .subs = subs.items });
            level = null;
        }
    }
    // Truncated file: an unclosed section or no section for the current location.
    if (level != null or s.find(s.current) == null) return error.BadSave;
    return s;
}

fn finishObj(comptime Save: type, a: Allocator, objs: *std.ArrayList(Save.Obj), vars: *std.ArrayList(Save.Var), skills: *std.ArrayList(Save.Skill), comps: *std.ArrayList(Save.Comp)) !void {
    if (objs.items.len == 0) {
        vars.* = .empty;
        skills.* = .empty;
        return;
    }
    try flushVars(Save, a, objs, comps, vars);
    const last = &objs.items[objs.items.len - 1];
    if (last.skills.len == 0 and skills.items.len > 0) last.skills = try a.dupe(Save.Skill, skills.items);
    if (comps.items.len > 0) last.comps = try a.dupe(Save.Comp, comps.items);
    skills.clearRetainingCapacity();
    comps.clearRetainingCapacity();
}

/// The `var` lines read so far: the last object's, or its last `comp`'s.
fn flushVars(comptime Save: type, a: Allocator, objs: *std.ArrayList(Save.Obj), comps: *std.ArrayList(Save.Comp), vars: *std.ArrayList(Save.Var)) !void {
    const to = if (comps.items.len > 0) &comps.items[comps.items.len - 1].vars else &objs.items[objs.items.len - 1].vars;
    if (to.len == 0 and vars.items.len > 0) to.* = try a.dupe(Save.Var, vars.items);
    vars.clearRetainingCapacity();
}

/// A value only a `v:` line holds.
fn literal(v: Value) bool {
    return switch (v) {
        .nil, .list, .map, .ref => true,
        else => false,
    };
}

fn writeValue(out: *std.Io.Writer, v: Value) !void {
    switch (v) {
        .nil => try out.writeAll("nil"),
        .bool => |b| try out.writeAll(if (b) "true" else "false"),
        .int => |i| try out.print("{d}", .{i}),
        .float => |f| {
            var buf: [64]u8 = undefined;
            const t = try std.fmt.bufPrint(&buf, "{d}", .{f});
            try out.writeAll(t);
            // `3` would read back as an int.
            if (std.mem.indexOfAny(u8, t, ".ein") == null) try out.writeAll(".0");
        },
        .string => |s| try quoted(out, s),
        .ref => |h| {
            try out.writeByte('@');
            try quoted(out, h.name);
        },
        .list => |l| {
            try out.writeByte('[');
            for (l, 0..) |x, i| {
                if (i > 0) try out.writeAll(", ");
                try writeValue(out, x);
            }
            try out.writeByte(']');
        },
        .map => |m| {
            try out.writeByte('{');
            for (m.keys, m.values, 0..) |k, x, i| {
                if (i > 0) try out.writeAll(", ");
                try writeValue(out, k);
                try out.writeAll(": ");
                try writeValue(out, x);
            }
            try out.writeByte('}');
        },
    }
}

fn quoted(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try out.writeAll("\\\""),
        else => try escape(out, &.{ch}),
    };
    try out.writeByte('"');
}

/// The `writeValue` literal at `t[at.*..]`, `at` past it. A reference is a handle with the
/// name only (snapshot.attach finds the object on load). error.BadSave: not a literal.
fn readValue(a: Allocator, t: []const u8, at: *usize) !Value {
    while (at.* < t.len and t[at.*] == ' ') at.* += 1;
    if (at.* >= t.len) return error.BadSave;
    switch (t[at.*]) {
        '"' => return .{ .string = try readString(a, t, at) },
        '@' => {
            at.* += 1;
            if (at.* >= t.len or t[at.*] != '"') return error.BadSave;
            const h = try a.create(Value.Handle);
            h.* = .{ .name = try readString(a, t, at) };
            return .{ .ref = h };
        },
        '[', '{' => {
            const map = t[at.*] == '{';
            const close: u8 = if (map) '}' else ']';
            at.* += 1;
            var keys: std.ArrayList(Value) = .empty;
            var values: std.ArrayList(Value) = .empty;
            while (true) {
                while (at.* < t.len and t[at.*] == ' ') at.* += 1;
                if (at.* >= t.len) return error.BadSave;
                if (t[at.*] == close) break;
                if (values.items.len > 0) {
                    if (t[at.*] != ',') return error.BadSave;
                    at.* += 1;
                }
                if (map) {
                    try keys.append(a, try readValue(a, t, at));
                    while (at.* < t.len and t[at.*] == ' ') at.* += 1;
                    if (at.* >= t.len or t[at.*] != ':') return error.BadSave;
                    at.* += 1;
                }
                try values.append(a, try readValue(a, t, at));
            }
            at.* += 1;
            if (!map) return .{ .list = values.items };
            const m = try a.create(Value.Map);
            m.* = .{ .keys = keys.items, .values = values.items };
            return .{ .map = m };
        },
        else => {
            const start = at.*;
            while (at.* < t.len and std.mem.indexOfScalar(u8, " ,:]}", t[at.*]) == null) at.* += 1;
            const word = t[start..at.*];
            if (std.mem.eql(u8, word, "nil")) return .nil;
            if (std.mem.eql(u8, word, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, word, "false")) return .{ .bool = false };
            if (std.fmt.parseInt(i32, word, 10)) |i| return .{ .int = i } else |_| {}
            return .{ .float = std.fmt.parseFloat(f32, word) catch return error.BadSave };
        },
    }
}

/// `quoted`'s string at `t[at.*]` (its `"`), `at` past the closing one.
fn readString(a: Allocator, t: []const u8, at: *usize) ![]const u8 {
    at.* += 1;
    var out: std.ArrayList(u8) = .empty;
    while (at.* < t.len) : (at.* += 1) switch (t[at.*]) {
        '"' => {
            at.* += 1;
            return out.items;
        },
        '\\' => {
            at.* += 1;
            if (at.* >= t.len) break;
            try out.append(a, switch (t[at.*]) {
                'n' => '\n',
                'r' => '\r',
                else => t[at.*],
            });
        },
        else => |ch| try out.append(a, ch),
    };
    return error.BadSave;
}

fn escape(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(ch),
    };
}

fn unescape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(a, switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                else => s[i],
            });
        } else try out.append(a, s[i]);
    }
    return out.items;
}
