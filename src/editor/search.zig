//! Search in lists: case-insensitive substring match on UTF-8 text, Latin and
//! Cyrillic letters folded (game names are in either); typing into the short fields
//! (a search, a number, a name: `append`, `dropLast`, `Field`).

const std = @import("std");

fn fold(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0x410...0x42f => cp + 0x20,
        0x401 => 0x451,
        else => cp,
    };
}

fn decode(s: []const u8, out: []u21) []u21 {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return out[0..0]).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n == out.len) break;
        out[n] = fold(cp);
        n += 1;
    }
    return out[0..n];
}

/// `query` (trimmed) occurs in any of `fields`; an empty query matches everything.
pub fn matches(query: []const u8, fields: []const []const u8) bool {
    const q_raw = std.mem.trim(u8, query, " ");
    if (q_raw.len == 0) return true;
    var qb: [64]u21 = undefined;
    const q = decode(q_raw, &qb);
    for (fields) |f| {
        var fb: [1024]u21 = undefined; // reference articles run past 256 letters
        if (std.mem.indexOf(u21, decode(f, &fb), q) != null) return true;
    }
    return false;
}

/// `s` without its last UTF-8 character.
fn dropLast(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0) {
        n -= 1;
        if (s[n] & 0xc0 != 0x80) break;
    }
    return s[0..n];
}

test "search: id and translated name, any case" {
    try std.testing.expect(matches("STILL", &.{ "Кинжал", "stilleto" }));
    try std.testing.expect(matches("кинж", &.{ "Кинжал", "stilleto" }));
    try std.testing.expect(matches("ЖИРАФ", &.{ "garcia", "Жираф" }));
    try std.testing.expect(!matches("axe", &.{ "Кинжал", "stilleto" }));
    try std.testing.expect(matches(" ", &.{"x"}));
    try std.testing.expectEqualStrings("Ки", dropLast("Кин"));
}

/// `s` typed into a short field's `buf[0..len.*]` (a number, a name, a search): each
/// byte `filter` takes (as it maps it; null: dropped; given the length so far) while
/// there is room (textedit.zig is the full text field: cursor, Cyrillic).
pub fn append(buf: []u8, len: *usize, s: []const u8, filter: *const fn (u8, usize) ?u8) void {
    for (s) |ch| {
        if (len.* == buf.len) return;
        buf[len.*] = filter(ch, len.*) orelse continue;
        len.* += 1;
    }
}

/// `append` filters: any byte; a number (`,` as `.`, `-` first only); a level name
/// (lowercase); an area name; a scene name (`-` too).
pub const keep = struct {
    pub fn any(ch: u8, _: usize) ?u8 {
        return ch;
    }
    pub fn number(ch: u8, at: usize) ?u8 {
        return if (ch == ',') '.' else if (std.ascii.isDigit(ch) or ch == '.' or (ch == '-' and at == 0)) ch else null;
    }
    pub fn levelName(ch: u8, _: usize) ?u8 {
        return if (std.ascii.isAlphanumeric(ch) or ch == '_') std.ascii.toLower(ch) else null;
    }
    pub fn areaName(ch: u8, _: usize) ?u8 {
        return if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else null;
    }
    pub fn sceneName(ch: u8, _: usize) ?u8 {
        return if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else null;
    }
};

test append {
    var buf: [4]u8 = undefined;
    var n: usize = 0;
    append(&buf, &n, "-1,5-9", keep.number);
    try std.testing.expectEqualStrings("-1.5", buf[0..n]);
    n = 0;
    append(&buf, &n, "1,25", keep.number);
    try std.testing.expectEqualStrings("1.25", buf[0..n]);
    append(&buf, &n, "7", keep.number);
    try std.testing.expectEqualStrings("1.25", buf[0..n]);
}

/// What is typed into a field (`filter` takes each byte: search.keep) over what it
/// showed when the typing began: `give` is the typed text, null when left as it was.
/// It begins all selected: the first character typed replaces it, Backspace clears it.
pub fn Field(comptime n: usize) type {
    return struct {
        const Self = @This();
        buf: [n]u8 = undefined,
        len: usize = 0,
        orig: [n]u8 = undefined,
        orig_len: usize = 0,
        filter: *const fn (u8, usize) ?u8 = keep.any,
        /// All of it selected (as it began; drawn so).
        all: bool = false,
        /// Where typing goes (a byte offset at a letter's start).
        caret: usize = 0,

        /// Typing from `value` shown (cut to the room).
        pub fn begin(value: []const u8, filter: *const fn (u8, usize) ?u8) Self {
            var f: Self = .{ .filter = filter };
            f.len = @min(value.len, n);
            @memcpy(f.buf[0..f.len], value[0..f.len]);
            f.orig = f.buf;
            f.orig_len = f.len;
            f.all = f.len > 0;
            f.caret = f.len;
            return f;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        /// `s` typed: each byte the filter takes, while there is room.
        pub fn add(self: *Self, s: []const u8) void {
            if (self.all) {
                // Replaces the selection, unless the filter takes none of it.
                var len: usize = 0;
                append(&self.buf, &len, s, self.filter);
                if (len == 0) return;
                self.len = len;
                self.caret = len;
                self.all = false;
                return;
            }
            // At the caret: what follows it kept after (as much as there is room for).
            var tail: [n]u8 = undefined;
            const tl = self.len - self.caret;
            @memcpy(tail[0..tl], self.buf[self.caret..self.len]);
            self.len = self.caret;
            append(&self.buf, &self.len, s, self.filter);
            self.caret = self.len;
            const room = @min(tl, n - self.len);
            @memcpy(self.buf[self.len..][0..room], tail[0..room]);
            self.len += room;
        }

        /// Backspace: the character before the caret (all its UTF-8 bytes); all of it if selected.
        pub fn backspace(self: *Self) void {
            if (self.all) return self.clear();
            self.cut(dropLast(self.buf[0..self.caret]).len, self.caret);
        }

        /// Delete: the character after the caret; all of it if selected.
        pub fn delete(self: *Self) void {
            if (self.all) return self.clear();
            self.cut(self.caret, self.next());
        }

        /// The caret one letter left or right, or to an end (a selection: dropped, the caret
        /// at its side).
        pub fn move(self: *Self, to: enum { left, right, home, end }) void {
            const was = self.all;
            self.all = false;
            self.caret = switch (to) {
                .home => 0,
                .end => self.len,
                .left => if (was) 0 else dropLast(self.buf[0..self.caret]).len,
                .right => if (was) self.len else self.next(),
            };
        }

        pub fn selectAll(self: *Self) void {
            self.all = self.len > 0;
            self.caret = self.len;
        }

        fn clear(self: *Self) void {
            self.len = 0;
            self.caret = 0;
            self.all = false;
        }

        /// The end of the letter after the caret.
        fn next(self: *const Self) usize {
            if (self.caret >= self.len) return self.len;
            var k = self.caret + 1;
            while (k < self.len and self.buf[k] & 0xc0 == 0x80) k += 1;
            return k;
        }

        /// Bytes `from..to` taken out, the caret at `from`.
        fn cut(self: *Self, from: usize, to: usize) void {
            std.mem.copyForwards(u8, self.buf[from..], self.buf[to..self.len]);
            self.len -= to - from;
            self.caret = from;
        }

        /// Cut to `room` bytes (never inside a UTF-8 letter).
        pub fn fit(self: *Self, room: usize) void {
            if (self.len <= room) return;
            self.len = room;
            while (self.len > 0 and self.buf[self.len] & 0xc0 == 0x80) self.len -= 1;
            self.caret = @min(self.caret, self.len);
        }

        /// The typed text, or null when it is what the field showed.
        pub fn give(self: *const Self) ?[]const u8 {
            return if (std.mem.eql(u8, self.text(), self.orig[0..self.orig_len])) null else self.text();
        }
    };
}

test "Field: the caret moves, types and deletes inside (Cyrillic too)" {
    var f: Field(16) = .begin("600.0", keep.any);
    f.move(.left); // the selection dropped, the caret at its start
    f.move(.right);
    f.add("5");
    try std.testing.expectEqualStrings("6500.0", f.text());
    f.move(.end);
    f.backspace();
    f.move(.home);
    f.delete();
    try std.testing.expectEqualStrings("500.", f.text());
    var r: Field(16) = .begin("дом", keep.any);
    r.move(.end);
    r.move(.left);
    r.backspace();
    try std.testing.expectEqualStrings("дм", r.text());
    r.selectAll();
    r.add("x");
    try std.testing.expectEqualStrings("x", r.text());
}

test Field {
    // Begun selected: typing replaces (150, 7 → 7), a rejected key keeps it, Backspace clears.
    var r: Field(8) = .begin("150", keep.number);
    r.add("x");
    try std.testing.expect(r.all and r.give() == null);
    r.add("7");
    try std.testing.expectEqualStrings("7", r.give().?);
    r.add("5");
    try std.testing.expectEqualStrings("75", r.give().?);
    r = .begin("150", keep.number);
    r.backspace();
    try std.testing.expectEqualStrings("", r.give().?);
    var f: Field(8) = .begin("1.5", keep.number);
    try std.testing.expect(f.give() == null);
    f.backspace();
    f.add("1.5");
    f.add("x,");
    try std.testing.expectEqualStrings("1.5.", f.give().?);
    f.backspace();
    try std.testing.expect(f.give() == null);
    f.backspace();
    f.add("-2");
    try std.testing.expectEqualStrings("1.2", f.give().?);
    var t: Field(8) = .begin("ж", keep.any);
    t.all = false;
    t.add("ab\u{0436}");
    t.backspace();
    try std.testing.expectEqualStrings("жab", t.give().?);
    // Cut to 4 bytes: "abж" (the next letter whole).
    t = .begin("", keep.any);
    t.add("ab\u{0436}\u{0436}");
    t.fit(4);
    try std.testing.expectEqualStrings("ab\u{0436}", t.text());
}
