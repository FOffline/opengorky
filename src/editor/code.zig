//! Script text editing for the code editor: a UTF-8 buffer with cursor, selection,
//! line moves, auto-indent and its own undo; line highlighting; the word before the
//! cursor and completion candidates. The game's bytes (Windows-1251 in the Russian
//! edition) convert to UTF-8 and back without loss. The buffer lives in codebuf.zig,
//! the call and argument scanners in callscan.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const codebuf = @import("codebuf.zig");
const callscan = @import("callscan.zig");

pub const Buffer = codebuf.Buffer;
pub const CallPos = callscan.CallPos;
pub const NamedArg = callscan.NamedArg;
pub const Scan = callscan.Scan;
pub const Token = callscan.Token;
pub const argValue = callscan.argValue;
pub const argsEnd = callscan.argsEnd;
pub const callAt = callscan.callAt;
pub const namedArg = callscan.namedArg;
pub const nameStart = callscan.nameStart;
pub const scanTo = callscan.scanTo;
const skipOver = callscan.skipOver;
pub const tokenAt = callscan.tokenAt;
pub const valueOf = callscan.valueOf;

/// Game bytes → UTF-8: Cyrillic letters of Windows-1251 (Russian edition) to their
/// letters, every other high byte to U+0080…U+00FF, so `toGame` gives the bytes back.
pub fn fromGame(gpa: Allocator, bytes: []const u8, cyrillic: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |b| {
        const cp: u21 = if (b < 0x80) b else if (cyrillic and b >= 0xc0) @as(u21, b) - 0xc0 + 0x410 else if (cyrillic and b == 0xa8) 0x401 else if (cyrillic and b == 0xb8) 0x451 else b;
        var buf: [4]u8 = undefined;
        try out.appendSlice(gpa, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable]);
    }
    return out.toOwnedSlice(gpa);
}

/// UTF-8 → game bytes; typographic quotes, dashes and the ellipsis as ASCII (no game
/// font draws them), other characters the edition can't hold become '?'.
pub fn toGame(gpa: Allocator, text: []const u8, cyrillic: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = (std.unicode.Utf8View.init(text) catch return error.BadText).iterator();
    while (it.nextCodepoint()) |cp| try out.append(gpa, switch (cp) {
        // Latin-1 letters would be Cyrillic ones in cp1251 (é → й); fromGame never makes them there.
        0xa8, 0xb8, 0xc0...0xff => if (cyrillic) '?' else @intCast(cp),
        0...0xa7, 0xa9...0xb7, 0xb9...0xbf => @intCast(cp),
        0x2018, 0x2019, 0x201a, 0x2032 => '\'',
        0x201c, 0x201d, 0x201e, 0x2033 => '"',
        0x2010...0x2015, 0x2212 => '-',
        0x2026 => blk: {
            try out.appendSlice(gpa, "..");
            break :blk '.';
        },
        0x410...0x44f => if (cyrillic) @intCast(cp - 0x410 + 0xc0) else '?',
        0x401 => if (cyrillic) 0xa8 else '?',
        0x451 => if (cyrillic) 0xb8 else '?',
        else => '?',
    });
    return out.toOwnedSlice(gpa);
}

/// A file's bytes → UTF-8: an OpenGorky (OGS) file's are UTF-8 already (`utf8`; one that
/// is not reads as game bytes and is written back as UTF-8), the game's scripts' the
/// edition's (fromGame).
pub fn fromFile(gpa: Allocator, bytes: []const u8, utf8: bool, cyrillic: bool) ![]u8 {
    if (utf8 and std.unicode.utf8ValidateSlice(bytes)) return gpa.dupe(u8, bytes);
    return fromGame(gpa, bytes, cyrillic);
}

/// UTF-8 → a file's bytes: an OGS file's as they are, a game script's toGame.
pub fn toFile(gpa: Allocator, text: []const u8, utf8: bool, cyrillic: bool) ![]u8 {
    if (!utf8) return toGame(gpa, text, cyrillic);
    if (!std.unicode.utf8ValidateSlice(text)) return error.BadText;
    return gpa.dupe(u8, text);
}

pub const isIdent = @import("model.zig").isIdent;

/// A function's declaration: its name, `(` and `)` (`close` is the text's end when it is
/// not closed yet), each parameter as declared with its comment (`// …` after it on its
/// line), and the `//` lines right above it joined (its doc).
const Header = struct { name: []const u8, open: usize, close: usize, params: []const HeaderParam, doc: []const u8 };
pub const HeaderParam = struct { decl: []const u8, doc: []const u8 = "" };

/// The declaration whose `function` keyword (OG Script's `fn`) is at `at`; null if none
/// is there.
pub fn header(a: Allocator, t: []const u8, at: usize) ?Header {
    const kw: usize = if (std.mem.startsWith(u8, t[at..], "function")) "function".len else if (std.mem.startsWith(u8, t[at..], "fn ")) "fn".len else return null;
    var j = at + kw;
    while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
    const s0 = j;
    while (j < t.len and isIdent(t[j])) j += 1;
    if (j == s0 or j == at + kw) return null;
    const name = t[s0..j];
    while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
    if (j >= t.len or t[j] != '(') return null;
    const open = j;
    var params: std.ArrayList(HeaderParam) = .empty;
    var start = open + 1;
    var k = open + 1;
    const close = while (k < t.len) : (k += 1) switch (t[k]) {
        ',', ')' => {
            const d = std.mem.trim(u8, t[start..k], " \t\r\n");
            if (d.len > 0) params.append(a, .{ .decl = d }) catch {};
            start = k + 1;
            if (t[k] == ')') break k;
        },
        '/' => if (k + 1 < t.len and t[k + 1] == '/') {
            const e = lineEnd(t, k);
            noteParam(a, &params, t[start..k], std.mem.trim(u8, t[k + 2 .. e], " \t/"));
            start = e;
            k = e;
        },
        '{', ';' => break k,
        else => {},
    } else t.len;
    // Still being typed: the last one so far.
    if (close == t.len or t[close] != ')') noteParam(a, &params, t[start..close], "");
    // A comment after `)` on its line is the last parameter's.
    if (close < t.len and t[close] == ')') {
        const e = lineEnd(t, close);
        if (std.mem.indexOf(u8, t[close..e], "//")) |c| if (std.mem.trim(u8, t[close + 1 .. close + c], " \t").len == 0) noteParam(a, &params, "", std.mem.trim(u8, t[close + c + 2 .. e], " \t/"));
    }
    // The comment lines right above.
    var doc: std.ArrayList(u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var ls = lineStart(t, at);
    while (ls > 0) {
        const prev = lineStart(t, ls - 1);
        const l = std.mem.trim(u8, t[prev .. ls - 1], " \t\r");
        if (!std.mem.startsWith(u8, l, "//")) break;
        lines.append(a, std.mem.trim(u8, l, " \t/-=*")) catch {};
        ls = prev;
    }
    var n = lines.items.len;
    while (n > 0) {
        n -= 1;
        if (lines.items[n].len == 0) continue;
        if (doc.items.len > 0) doc.append(a, ' ') catch {};
        doc.appendSlice(a, lines.items[n]) catch {};
    }
    return .{ .name = name, .open = open, .close = close, .params = params.items, .doc = doc.items };
}

test header {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = "x;\n// Opens the door.\n//   ---\n// Twice.\nfunction Door(string hero, // who\n  int fast) // 1: run\n{\n};\nfunction F()\n{};\n";
    const h = header(a, t, std.mem.indexOf(u8, t, "function Door").?).?;
    try std.testing.expectEqualStrings("Door", h.name);
    try std.testing.expectEqualStrings("Opens the door. Twice.", h.doc);
    try std.testing.expectEqual(2, h.params.len);
    try std.testing.expectEqualStrings("string hero", h.params[0].decl);
    try std.testing.expectEqualStrings("who", h.params[0].doc);
    try std.testing.expectEqualStrings("int fast", h.params[1].decl);
    try std.testing.expectEqualStrings("1: run", h.params[1].doc);
    try std.testing.expectEqual(')', t[h.close]);
    const f = header(a, t, std.mem.indexOf(u8, t, "function F").?).?;
    try std.testing.expectEqual(0, f.params.len);
    try std.testing.expectEqualStrings("", f.doc);
    try std.testing.expect(header(a, t, 0) == null);
    // Not closed yet (being typed).
    const u = header(a, "function G(int a, str", 0).?;
    try std.testing.expectEqual(2, u.params.len);
    // OG Script: `fn`, a parameter's type and default as written.
    const o = header(a, "// Hit.\nfn OnHit(attacker, amount: int = 2) {}", 8).?;
    try std.testing.expectEqualStrings("OnHit", o.name);
    try std.testing.expectEqualStrings("Hit.", o.doc);
    try std.testing.expectEqualStrings("amount: int = 2", o.params[1].decl);
}

/// Comment `note` of the parameter written before it on its line: `seg` (still being
/// written: it ends there), else the last one.
fn noteParam(a: Allocator, params: *std.ArrayList(HeaderParam), seg: []const u8, note: []const u8) void {
    const d = std.mem.trim(u8, seg, " \t\r\n");
    if (d.len > 0) {
        params.append(a, .{ .decl = d, .doc = note }) catch {};
    } else if (params.items.len > 0 and params.items[params.items.len - 1].doc.len == 0) params.items[params.items.len - 1].doc = note;
}

/// The argument being typed at offset `i`: in its string (`quoted`), or a bare word
/// right after `(` or `,` (a value goes in with its quotes); where its text starts.
const ArgSlot = struct { call: CallPos, start: usize, quoted: bool };

pub fn argSlot(t: []const u8, i: usize) ?ArgSlot {
    if (stringArgAt(t, i)) |sa| return .{ .call = sa.call, .start = sa.start, .quoted = true };
    const cp = callAt(t, i) orelse return null;
    var a = i;
    while (a > 0 and isIdent(t[a - 1])) a -= 1;
    var k = a;
    while (k > 0 and t[k - 1] == ' ') k -= 1;
    if (k == 0 or (t[k - 1] != '(' and t[k - 1] != ',')) return null;
    return .{ .call = cp, .start = a, .quoted = false };
}

test argSlot {
    const t = "PlaceActor(\"Sul\", cap";
    try std.testing.expect(argSlot(t, 15).?.quoted);
    const s = argSlot(t, t.len).?;
    try std.testing.expect(!s.quoted and s.call.arg == 1 and s.start == 18);
    try std.testing.expect(argSlot("x = 1 + ab", 10) == null);
    try std.testing.expectEqualStrings("Sullivan", argValue("Actor_SetAnimation(\"Sullivan\", \"idle\");", 18, 0).?);
}

/// A string argument the cursor is in: its call and where the string's text starts
/// (after the opening `"`), the call need not be closed yet.
const StringArg = struct { call: CallPos, start: usize };

pub fn stringArgAt(t: []const u8, i: usize) ?StringArg {
    const s = scanTo(t, i);
    if (s.in != .string) return null;
    return .{ .call = s.call(t, s.n) orelse return null, .start = s.quote + 1 };
}

/// `text` re-indented by its braces (`indent` a level) with trailing spaces gone;
/// line endings, blank lines and the lines of `/* */` comments kept. Braces in
/// strings and comments don't count; a line starting with `}` steps back first.
pub fn format(gpa: Allocator, text: []const u8, indent: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var depth: usize = 0;
    var in_block = false;
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        const nl_end = if (e < text.len) e + 1 else e;
        const raw = text[i..e];
        const cr = raw.len > 0 and raw[raw.len - 1] == '\r';
        const line = raw[0 .. raw.len - @intFromBool(cr)];
        const body = std.mem.trim(u8, line, " \t");
        if (in_block) {
            try out.appendSlice(gpa, std.mem.trimEnd(u8, line, " \t"));
        } else if (body.len > 0) {
            const lead = body[0] == '}';
            for (0..(if (lead) depth -| 1 else depth)) |_| try out.appendSlice(gpa, indent);
            try out.appendSlice(gpa, body);
        }
        // Braces of the line (outside strings and comments) set the next lines' depth.
        var k: usize = 0;
        var str = false;
        while (k < line.len) : (k += 1) {
            const ch = line[k];
            if (in_block) {
                if (ch == '*' and k + 1 < line.len and line[k + 1] == '/') {
                    in_block = false;
                    k += 1;
                }
            } else if (str) {
                if (ch == '"') str = false;
            } else switch (ch) {
                '"' => str = true,
                '/' => if (k + 1 < line.len and line[k + 1] == '/') break else if (k + 1 < line.len and line[k + 1] == '*') {
                    in_block = true;
                    k += 1;
                },
                '{' => depth += 1,
                '}' => depth -|= 1,
                else => {},
            }
        }
        if (cr) try out.append(gpa, '\r');
        if (nl_end > e) try out.append(gpa, '\n');
        i = nl_end;
    }
    return out.toOwnedSlice(gpa);
}

/// An open code editor (codeview.zig).
pub const View = struct {
    buf: Buffer,
    /// Store index of the file and its name.
    file: usize,
    title: []u8,
    /// First line shown; the text's line count (measured with `wide`); the vertical bar's
    /// thumb held (where on it it was taken).
    scroll: usize = 0,
    lines: usize = 1,
    vbar: ?f32 = null,
    /// Points the text is scrolled to the left (long lines); its widest line (measured at
    /// buffer version `wide_ver`); the horizontal bar's thumb held (where on it it was
    /// taken); the cursor brought into view sideways at the next draw.
    hscroll: f32 = 0,
    wide: f32 = 0,
    wide_ver: ?u32 = null,
    hbar: ?f32 = null,
    follow_x: bool = false,
    /// The right-click menu open (where), as Go to's pick list when `picks`.
    menu: ?[2]f32 = null,
    picks: bool = false,
    /// Where the pointer rests over the text and since when (ms): its hover tip.
    rest: [2]f32 = .{ 0, 0 },
    rest_since: u64 = 0,
    /// Completion list open and its selected line.
    popup: bool = false,
    popup_sel: usize = 0,
    /// The list holds tasks (Ctrl+Space on an empty spot), not words.
    tasks: bool = false,
    /// The functions' help column shown (F1).
    help: bool = false,
    /// Where the text was drawn last (pointer → cursor): x, y, w, h.
    rect: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dragging: bool = false,
    /// Syntax check of the text at `checked` (buffer version): the error's line (1-based,
    /// 0 — none) and message; `force` — Apply pressed once despite it.
    checked: ?u32 = null,
    err_line: u32 = 0,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,
    force: bool = false,
    /// Calls (scene commands in a `.scr`) that nothing registers: line and name, the
    /// first `unknown.len` (warnings, they do not hold Apply back).
    /// A hooks file's functions the engine never calls this way (`hook`: no such hook,
    /// `hook_args`: not its parameters) go in here too; `note`: a message of its own
    /// (`msg`: a rules row's problem, a value naming nothing, a callback's parameters),
    /// under its name (in quotes when `quoted`).
    unknown: [16]struct { line: u32, name: [48]u8, len: u8, kind: enum { call, hook, hook_args, port_only, args, missing, note } = .call, quoted: bool = false, msg: [240]u8 = undefined, msg_len: u8 = 0 } = undefined,
    unknown_n: usize = 0,
    /// The interface language the messages were made in (a change checks again).
    checked_lang: @import("text.zig").Lang = .en,
    /// Hash of the Store's text the buffer was last read from or applied to; `stale`:
    /// the Store's changed since while the buffer has edits of its own (codeview.refresh).
    store_hash: u64 = 0,
    stale: bool = false,
    /// The Store's key then (codecheck.storeKey).
    checked_store: [3]usize = .{ 0, 0, 0 },
    /// A Classic script shown as OG Script (its functions printed from the IR); Apply
    /// writes it back through the Classic exporter (model.setCode). False: its own text.
    ogs_view: bool = false,
    /// The find field (Cmd+F) shown and its text; its matches are marked.
    find_open: bool = false,
    find_buf: [64]u8 = undefined,
    find_len: usize = 0,

    pub fn err(self: *const View) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn findText(self: *const View) []const u8 {
        return self.find_buf[0..self.find_len];
    }

    pub fn setFind(self: *View, q: []const u8) void {
        self.find_len = @min(q.len, self.find_buf.len);
        @memcpy(self.find_buf[0..self.find_len], q[0..self.find_len]);
    }

    /// The buffer read again from `bytes` (its file's game text) when they differ from
    /// what it was last read from or applied to, the cursor and scroll kept. With edits
    /// of its own it stays, marked `stale` (Apply asks before writing over).
    pub fn follow(self: *View, bytes: []const u8, utf8_file: bool, cyrillic: bool) !void {
        const h = std.hash.Wyhash.hash(0, bytes);
        if (h == self.store_hash) return;
        if (self.buf.changed) {
            self.stale = true;
            return;
        }
        const utf8 = try fromFile(self.buf.gpa, bytes, utf8_file, cyrillic);
        defer self.buf.gpa.free(utf8);
        try self.reread(utf8, h);
    }

    /// The buffer as `utf8` (from the Store's text hashed `h`), the cursor kept.
    pub fn reread(self: *View, utf8: []const u8, h: u64) !void {
        const gpa = self.buf.gpa;
        var nb = try Buffer.init(gpa, utf8);
        nb.cursor = @min(self.buf.cursor, utf8.len);
        while (nb.cursor > 0 and nb.cursor < utf8.len and utf8[nb.cursor] & 0xc0 == 0x80) nb.cursor -= 1;
        nb.version = self.buf.version +% 1;
        self.buf.deinit();
        self.buf = nb;
        self.store_hash = h;
        self.stale = false;
    }

    pub fn destroy(self: *View, gpa: Allocator) void {
        self.buf.deinit();
        gpa.free(self.title);
        gpa.destroy(self);
    }
};

pub const Func = struct { name: []const u8, at: usize, component: bool = false };

/// `function name(` headers of the text, in order; OG Script's `fn name(`,
/// `component Name` and `trait Name` too (two words in a row: no Classic text has them).
pub fn functions(a: Allocator, t: []const u8) []const Func {
    var out: std.ArrayList(Func) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        if (!isIdent(t[i])) {
            i += 1;
            continue;
        }
        const at = i;
        while (i < t.len and isIdent(t[i])) i += 1;
        const w = t[at..i];
        const comp = std.mem.eql(u8, w, "component") or std.mem.eql(u8, w, "trait");
        if (!comp and !std.mem.eql(u8, w, "function") and !std.mem.eql(u8, w, "fn")) continue;
        // Not one commented out (`// function OnDamage(…)` of the hooks template).
        if (std.mem.indexOf(u8, t[lineStart(t, at)..at], "//") != null) continue;
        var j = i;
        while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
        const s0 = j;
        while (j < t.len and isIdent(t[j])) j += 1;
        if (j == s0 or (!comp and (j >= t.len or t[j] != '('))) continue;
        out.append(a, .{ .name = t[s0..j], .at = at, .component = comp }) catch {};
    }
    return out.items;
}

pub fn currentFn(fns: []const Func, cursor: usize) ?usize {
    var cur: ?usize = null;
    for (fns, 0..) |f, k| if (f.at <= cursor) {
        cur = k;
    };
    return cur;
}

pub fn lineStart(t: []const u8, i: usize) usize {
    var a = @min(i, t.len);
    while (a > 0 and t[a - 1] != '\n') a -= 1;
    return a;
}

/// Offset of the line's end (before CR LF).
pub fn lineEnd(t: []const u8, i: usize) usize {
    var e = @min(i, t.len);
    while (e < t.len and t[e] != '\n' and t[e] != '\r') e += 1;
    return e;
}

/// Offset just past the line holding `i` (after its LF; the text's end on the last line).
pub fn lineAfter(t: []const u8, i: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, t, i, '\n')) |e| e + 1 else t.len;
}

/// Offset of line `n` (1-based; past the last line: the text's end).
pub fn lineOffset(t: []const u8, n: usize) usize {
    var at: usize = 0;
    var l: usize = 1;
    while (l < n) : (l += 1) at = (std.mem.indexOfScalarPos(u8, t, at, '\n') orelse return t.len) + 1;
    return at;
}

test lineOffset {
    try std.testing.expectEqual(@as(usize, 0), lineOffset("a\nb", 1));
    try std.testing.expectEqual(@as(usize, 3), lineOffset("a\r\nb", 2));
    try std.testing.expectEqual(@as(usize, 3), lineOffset("a\nb", 3));
    try std.testing.expectEqual(@as(usize, 2), lineAfter("a\nb", 0));
    try std.testing.expectEqual(@as(usize, 3), lineAfter("a\nb", 2));
}

pub fn nextLine(t: []const u8, e: usize) usize {
    var n = e;
    if (n < t.len and t[n] == '\r') n += 1;
    if (n < t.len and t[n] == '\n') n += 1;
    return n;
}

pub fn prevChar(t: []const u8, i: usize) usize {
    var p = i -| 1;
    while (p > 0 and t[p] & 0xc0 == 0x80) p -= 1;
    return p;
}

pub fn nextChar(t: []const u8, i: usize) usize {
    var n = @min(i + 1, t.len);
    while (n < t.len and t[n] & 0xc0 == 0x80) n += 1;
    return n;
}

pub fn colOf(t: []const u8, i: usize) usize {
    var n: usize = 0;
    for (t[lineStart(t, i)..i]) |ch| n += @intFromBool(ch & 0xc0 != 0x80);
    return n;
}

/// Offset of column `col` (characters) on the line starting at `ls`, or its end.
pub fn posAtCol(t: []const u8, ls: usize, col: usize) usize {
    const e = lineEnd(t, ls);
    var i = ls;
    var n: usize = 0;
    while (i < e and n < col) : (n += 1) i = nextChar(t, i);
    return i;
}

/// What a character is for word moves: spaces, a word (letters, digits, `_`, any
/// non-ASCII), signs, a line end.
pub fn class(ch: u8) u2 {
    if (ch == ' ' or ch == '\t') return 0;
    if (ch == '\n' or ch == '\r') return 3;
    if (isIdent(ch) or ch >= 0x80) return 1;
    return 2;
}

/// Alt+Left: past the spaces, then the word (or the signs) before `i`; at a line's start,
/// to the line before's end.
pub fn wordLeftPos(t: []const u8, i: usize) usize {
    var p = i;
    while (p > 0 and class(t[p - 1]) == 0) p -= 1;
    if (p == 0) return 0;
    const k = class(t[p - 1]);
    if (k == 3) return if (p == i) lineEnd(t, lineStart(t, p - 1)) else p;
    while (p > 0 and class(t[p - 1]) == k) p -= 1;
    return p;
}

pub fn wordRightPos(t: []const u8, i: usize) usize {
    var p = i;
    while (p < t.len and class(t[p]) == 0) p += 1;
    if (p == t.len) return p;
    const k = class(t[p]);
    if (k == 3) return if (p == i) nextLine(t, p) else p;
    while (p < t.len and class(t[p]) == k) p += 1;
    return p;
}

pub fn closerOf(ch: u8) ?u8 {
    return switch (ch) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        else => null,
    };
}

/// Offset `i` is inside a string or a comment.
pub fn inString(t: []const u8, i: usize) bool {
    return scanTo(t, i).in != .code;
}

/// Highlight kinds.
/// `path`: an OG Script path (`looks::medusa_2`); `field`: the name a value is given to
/// (`hp = 120`, a named argument).
pub const Kind = enum { plain, keyword, call, string, number, comment, directive, path, field };

pub const Span = struct { kind: Kind, start: usize, end: usize };

const keywords = [_][]const u8{ "function", "if", "else", "while", "for", "return", "int", "float", "string", "break", "continue" };

/// OG Script's words (script/ogs/parser.zig): declarations, statements, values, types.
pub const ogs_keywords = [_][]const u8{ "module", "use", "component", "trait", "fn", "param", "var", "attach", "import", "injects", "struct", "enum", "if", "else", "while", "for", "in", "return", "break", "continue", "and", "or", "not", "nil", "true", "false", "self", "host", "super", "is", "native", "classic", "int", "float", "string", "bool", "object" };

/// Highlight spans of `line` (no newline); `ogs`: an OG Script line (its words, strings
/// with `\"` escapes, no `#` directives).
pub fn highlight(a: Allocator, line: []const u8, ogs: bool) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    var i: usize = 0;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!ogs and std.mem.startsWith(u8, trimmed, "#")) {
        try out.append(a, .{ .kind = .directive, .start = 0, .end = line.len });
        return out.items;
    }
    while (i < line.len) {
        const ch = line[i];
        const s = i;
        var kind: Kind = .plain;
        // Line by line: a `/* */` on one line stays plain (one across lines can't be told).
        if (ogs and ch == '~' and i + 2 < line.len and std.ascii.isAlphabetic(line[i + 1]) and line[i + 2] == '"') {
            // A sigil (`~l"01_port"`): its letter as a word of the language, then the string.
            i += 2;
            kind = .keyword;
        } else if (ogs and ch == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') i += if (line[i] == '\\' and i + 1 < line.len) 2 else 1;
            i = @min(line.len, i + 1);
            kind = .string;
        } else if ((ch == '/' and i + 1 < line.len and line[i + 1] == '/') or ch == '"') {
            i = skipOver(line, i).?;
            kind = if (ch == '"') .string else .comment;
        } else if (std.ascii.isDigit(ch) or (ch == '-' and i + 1 < line.len and std.ascii.isDigit(line[i + 1]) and (i == 0 or !isIdent(line[i - 1])))) {
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '.')) i += 1;
            kind = .number;
        } else if (isIdent(ch)) {
            while (i < line.len and isIdent(line[i])) i += 1;
            // OG Script: a path `a::b::c` one word.
            var path = false;
            if (ogs) while (i + 2 < line.len and line[i] == ':' and line[i + 1] == ':' and isIdent(line[i + 2])) {
                path = true;
                i += 2;
                while (i < line.len and isIdent(line[i])) i += 1;
            };
            const w = line[s..i];
            var k = i;
            while (k < line.len and line[k] == ' ') k += 1;
            const called = k < line.len and line[k] == '(';
            kind = for (if (ogs) &ogs_keywords else &keywords) |kw| {
                if (std.mem.eql(u8, w, kw)) break .keyword;
            } else if (called or (!ogs and s == line.len - trimmed.len and isCommand(w))) .call else if (path) .path else if (ogs and blockKind(line, s, k)) .keyword else if (ogs and k < line.len and line[k] == '=' and !(k + 1 < line.len and line[k + 1] == '=')) .field else .plain;
        } else {
            i = nextChar(line, i);
        }
        if (out.items.len > 0 and out.items[out.items.len - 1].kind == kind and out.items[out.items.len - 1].end == s) {
            out.items[out.items.len - 1].end = i;
        } else try out.append(a, .{ .kind = kind, .start = s, .end = i });
    }
    return out.items;
}

/// OG Script: the word at `s` (its line's first, `k` the next non-space after it) opens a
/// block: a name or a string follows, the line ends with `{` (`fighter medusa {`,
/// `weapon la: weapons::medusalong {`, `level "01_port" {`).
fn blockKind(line: []const u8, s: usize, k: usize) bool {
    if (std.mem.trimStart(u8, line[0..s], " \t").len != 0 or k >= line.len) return false;
    if (!isIdent(line[k]) and line[k] != '"') return false;
    return std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \t\r"), "{");
}

/// A scene command without arguments (`FADE_OUT`): an all-caps word.
fn isCommand(w: []const u8) bool {
    if (w.len < 2) return false;
    for (w) |ch| if (!std.ascii.isUpper(ch) and ch != '_' and !std.ascii.isDigit(ch)) return false;
    return true;
}

test "a sigil is highlighted before its string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sp = try highlight(arena.allocator(), "LEVEL_Load(~l\"01_port\")", true);
    try std.testing.expectEqual(Kind.keyword, sp[2].kind);
    try std.testing.expectEqualStrings("~l", "LEVEL_Load(~l\"01_port\")"[sp[2].start..sp[2].end]);
    try std.testing.expectEqual(Kind.string, sp[3].kind);
}

test "OG Script: a block's kind, a path, a field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "    weapon la: weapons::medusalong {";
    const sp = try highlight(a, line, true);
    var kinds: [8]Kind = undefined;
    var n: usize = 0;
    for (sp) |x| if (x.kind != .plain) {
        kinds[n] = x.kind;
        n += 1;
    };
    try std.testing.expectEqualSlices(Kind, &.{ .keyword, .path }, kinds[0..n]);
    const f = try highlight(a, "    look = looks::medusa_2;", true);
    try std.testing.expectEqual(Kind.field, f[1].kind);
    try std.testing.expectEqualStrings("look", "    look = looks::medusa_2;"[f[1].start..f[1].end]);
    // A call by its path stays a call; `==` names no field.
    try std.testing.expectEqual(Kind.call, (try highlight(a, "fx::Rocket(a)", true))[0].kind);
    for (try highlight(a, "if (x == 1)", true)) |x| if (x.start <= 4 and 4 < x.end) try std.testing.expectEqual(Kind.plain, x.kind);
}

test "scene command without arguments is a call" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const spans = try highlight(arena.allocator(), "  FADE_OUT", false);
    try std.testing.expectEqual(Kind.call, spans[spans.len - 1].kind);
}

/// Candidates for `prefix` (case-insensitive): starting with it first, then containing it.
pub fn matches(a: Allocator, prefix: []const u8, words: []const []const u8, max: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (prefix.len == 0) return out.items;
    for ([_]bool{ true, false }) |starts| for (words) |w| {
        if (out.items.len == max) return out.items;
        if (w.len <= prefix.len and std.ascii.eqlIgnoreCase(w, prefix)) continue;
        const hit = if (starts) std.ascii.startsWithIgnoreCase(w, prefix) else !std.ascii.startsWithIgnoreCase(w, prefix) and std.ascii.findIgnoreCase(w, prefix) != null;
        if (!hit) continue;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, w)) break;
        } else try out.append(a, w);
    };
    return out.items;
}

/// Identifiers of `text` (for completion with the file's own names).
pub fn identifiers(a: Allocator, text: []const u8) ![]const []const u8 {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (isIdent(text[i]) and !std.ascii.isDigit(text[i])) {
            const s = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            if (i - s >= 3) try set.put(a, text[s..i], {});
        } else i += 1;
    }
    return set.keys();
}

test "code: encoding round trip" {
    const gpa = std.testing.allocator;
    const bytes = "x = \"\xcf\xf0\xe8\xe2\xe5\xf2\xa8\x96\xff\";\r\n";
    const u = try fromGame(gpa, bytes, true);
    defer gpa.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "Привет") != null);
    const back = try toGame(gpa, u, true);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, bytes, back);
}

test "code: typing, CRLF, indent, moves, undo" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "function init()\r\n{\r\n  x = 1;\r\n};\r\n");
    defer b.deinit();
    b.cursor = 18; // after "{"
    try b.newline();
    try std.testing.expectEqualStrings("function init()\r\n{\r\n  \r\n  x = 1;\r\n};\r\n", b.str());
    try b.insert("H");
    try b.insert("P");
    try std.testing.expectEqualStrings("  HP", b.str()[20..24]);
    try b.complete("HERO_EnableEnumerate");
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "  HERO_EnableEnumerate\r\n") != null);
    try b.undoLast();
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "  HP\r\n") != null);
    b.vertical(1, false);
    try std.testing.expectEqual(@as(u8, 'x'), b.str()[b.cursor - 2]);
    b.end(false);
    try b.backspace();
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "x = 1\r\n") != null);
    b.cursor = lineStart(b.str(), b.cursor);
    try b.backspace(); // joins the line with the previous one, CRLF as one
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "  HP  x = 1") != null);
}

test "code: brackets, words, redo" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "");
    defer b.deinit();
    for ("Say(") |ch| try b.typeText(&.{ch});
    try std.testing.expectEqualStrings("Say()", b.str());
    try b.typeText("\"");
    try b.typeText("a");
    try b.typeText("\""); // steps over the closing quote
    try b.typeText(")"); // and over the bracket
    try std.testing.expectEqualStrings("Say(\"a\")", b.str());
    try std.testing.expectEqual(@as(usize, 8), b.cursor);
    b.cursor = 4;
    try b.typeText("(");
    try b.backspace(); // the pair goes together
    try std.testing.expectEqualStrings("Say(\"a\")", b.str());
    b.selectWord(1);
    try std.testing.expectEqualStrings("Say", b.str()[b.selection().?[0]..b.selection().?[1]]);
    try b.typeText("["); // wraps the selection
    try std.testing.expectEqualStrings("[Say](\"a\")", b.str());
    try b.undoLast();
    try std.testing.expectEqualStrings("Say(\"a\")", b.str());
    try b.redoLast();
    try std.testing.expectEqualStrings("[Say](\"a\")", b.str());
    b.cursor = b.str().len;
    b.wordLeft(false);
    try std.testing.expectEqual(@as(usize, 8), b.cursor); // before `")`
    try b.deleteBack(false);
    try std.testing.expectEqualStrings("[Say](\"\")", b.str());
}

test "code: line operations" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "a();\r\n  b();\r\nc();");
    defer b.deinit();
    b.cursor = 8; // in b();
    try b.lines(.comment);
    try std.testing.expectEqualStrings("a();\r\n  // b();\r\nc();", b.str());
    try std.testing.expectEqual(@as(usize, 11), b.cursor);
    try b.lines(.comment);
    try std.testing.expectEqualStrings("a();\r\n  b();\r\nc();", b.str());
    try b.moveLines(false);
    try std.testing.expectEqualStrings("  b();\r\na();\r\nc();", b.str());
    try std.testing.expectEqual(@as(usize, 2), b.cursor);
    try b.moveLines(true);
    try b.moveLines(true); // to the end: the last line keeps no line end
    try std.testing.expectEqualStrings("a();\r\nc();\r\n  b();", b.str());
    try b.duplicateLines();
    try std.testing.expectEqualStrings("a();\r\nc();\r\n  b();\r\n  b();", b.str());
    try b.deleteLines();
    try b.deleteLines();
    try std.testing.expectEqualStrings("a();\r\nc();", b.str());
    b.selectAll();
    try b.lines(.indent);
    try std.testing.expectEqualStrings("  a();\r\n  c();", b.str());
    try b.lines(.outdent);
    try std.testing.expectEqualStrings("a();\r\nc();", b.str());
    b.selectLine(0, false);
    try std.testing.expectEqualStrings("a();\r\n", b.str()[b.selection().?[0]..b.selection().?[1]]);
}

test "code: call snippets and argument moves" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "  Plac\r\n");
    defer b.deinit();
    b.cursor = 6;
    try b.insertCall("PlaceActor", "\"Sullivan\", 1, 4");
    try std.testing.expectEqualStrings("  PlaceActor(\"Sullivan\", 1, 4);\r\n", b.str());
    try std.testing.expectEqualStrings("\"Sullivan\"", b.str()[b.selection().?[0]..b.selection().?[1]]);
    const cp = callAt(b.str(), b.cursor).?;
    try std.testing.expectEqualStrings("PlaceActor", cp.name);
    try std.testing.expect(b.nextArg());
    try std.testing.expectEqualStrings("1", b.str()[b.selection().?[0]..b.selection().?[1]]);
    try std.testing.expectEqual(1, callAt(b.str(), b.cursor).?.arg);
    try std.testing.expect(b.nextArg());
    try std.testing.expect(b.nextArg());
    try std.testing.expectEqual(b.str().len - 2, b.cursor); // past `);`
    try std.testing.expect(!b.nextArg());
    try std.testing.expect(callAt("if(AIFreeTile(3, 9", 18).?.arg == 1);
    try std.testing.expect(callAt("if(x", 4) == null);
}

test "code: highlight and completion" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sp = try highlight(a, "  if (x) StartScriptlet(\"a\", 12); // go", false);
    try std.testing.expectEqual(Kind.keyword, sp[1].kind);
    // OG Script: its words, an escaped quote inside a string, no directive.
    const o = try highlight(a, "fn OnHit(a) { FighterPopup(host, \"\\\"x\\\" // y\"); } // z", true);
    try std.testing.expectEqual(Kind.keyword, o[0].kind);
    for (o) |x| if (x.kind == .string) try std.testing.expectEqualStrings("\"\\\"x\\\" // y\"", "fn OnHit(a) { FighterPopup(host, \"\\\"x\\\" // y\"); } // z"[x.start..x.end]);
    try std.testing.expectEqual(Kind.comment, o[o.len - 1].kind);
    try std.testing.expect((try highlight(a, "#include x", true))[0].kind != .directive);
    var kinds: [32]Kind = undefined;
    for (sp, 0..) |s, i| kinds[i] = s.kind;
    try std.testing.expect(std.mem.indexOfScalar(Kind, kinds[0..sp.len], .call) != null);
    try std.testing.expectEqual(Kind.comment, sp[sp.len - 1].kind);
    const m = try matches(a, "start", &.{ "PlaceActor", "StartScriptlet", "SetAddonScriptlet", "MyStart" }, 8);
    try std.testing.expectEqualStrings("StartScriptlet", m[0]);
    try std.testing.expectEqualStrings("MyStart", m[1]);
}

test stringArgAt {
    const t = "  PlaceActor(\"Sul";
    const sa = stringArgAt(t, t.len).?;
    try std.testing.expectEqualStrings("PlaceActor", sa.call.name);
    try std.testing.expectEqual(0, sa.call.arg);
    try std.testing.expectEqualStrings("Sul", t[sa.start..]);
    const u = "PlaceActor(\"Sullivan\", \"capt";
    try std.testing.expectEqual(1, stringArgAt(u, u.len).?.call.arg);
    try std.testing.expect(stringArgAt("PlaceActor(\"Sullivan\", ", 23) == null);
}

test format {
    const gpa = std.testing.allocator;
    const src = "function init()\r\n{\r\n if(a){\r\n\tb = \"{\"; // }\r\n   }   \r\n\r\n/* {\r\n   kept */\r\n};\r\n";
    const out = try format(gpa, src, "  ");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("function init()\r\n{\r\n  if(a){\r\n    b = \"{\"; // }\r\n  }\r\n\r\n  /* {\r\n   kept */\r\n};\r\n", out);
}

test "code: an OGS file's UTF-8 as it is, a game script's cp1251 both ways" {
    const gpa = std.testing.allocator;
    const u = try fromFile(gpa, "// \u{41f}\u{440}\u{438}\u{432}\u{435}\u{442} \u{2014}", true, true);
    defer gpa.free(u);
    try std.testing.expectEqualStrings("// \u{41f}\u{440}\u{438}\u{432}\u{435}\u{442} \u{2014}", u);
    const back = try toFile(gpa, u, true, true);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(u, back);
    const g = try fromFile(gpa, "\xcf\xf0", false, true);
    defer gpa.free(g);
    try std.testing.expectEqualStrings("\u{41f}\u{440}", g);
    const gb = try toFile(gpa, g, false, true);
    defer gpa.free(gb);
    try std.testing.expectEqualStrings("\xcf\xf0", gb);
    // Not UTF-8 in an OGS file: the game bytes' letters, then written as UTF-8.
    const bad = try fromFile(gpa, "\xcf", true, true);
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("\u{41f}", bad);
}

test "toGame: typographic quotes, dashes and the ellipsis as ASCII; game bytes back" {
    const gpa = std.testing.allocator;
    const g = try toGame(gpa, "\u{201c}Hi\u{201d} \u{2014} it\u{2019}s\u{2026} \u{432}", true);
    defer gpa.free(g);
    try std.testing.expectEqualStrings("\"Hi\" - it's... \xe2", g);
    const u = try fromGame(gpa, "\x93\xe2", true);
    defer gpa.free(u);
    const back = try toGame(gpa, u, true);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("\x93\xe2", back);
    const l = try toGame(gpa, "\u{e9}", true);
    defer gpa.free(l);
    try std.testing.expectEqualStrings("?", l);
}

/// Whole-word matches of `w` in `t` (case aside).
const WordUses = struct {
    t: []const u8,
    w: []const u8,
    pos: usize = 0,

    pub fn next(self: *WordUses) ?usize {
        while (std.ascii.findIgnoreCasePos(self.t, self.pos, self.w)) |i| {
            self.pos = i + self.w.len;
            if (i > 0 and isIdent(self.t[i - 1])) continue;
            if (self.pos < self.t.len and isIdent(self.t[self.pos])) continue;
            return i;
        }
        return null;
    }
};

pub fn wordUses(t: []const u8, w: []const u8) WordUses {
    return .{ .t = t, .w = w };
}

test wordUses {
    var it = wordUses("Sullivan; xSullivan sullivan_1 \"SULLIVAN\"", "sullivan");
    try std.testing.expectEqual(@as(?usize, 0), it.next());
    try std.testing.expectEqual(@as(?usize, 32), it.next());
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "View.follow: a view without edits reads the Store's new text; one with edits keeps them, stale" {
    const gpa = std.testing.allocator;
    var v: View = .{ .buf = try Buffer.init(gpa, "a();\r\n"), .file = 0, .title = &.{}, .store_hash = std.hash.Wyhash.hash(0, "a();\r\n") };
    defer v.buf.deinit();
    v.buf.cursor = 3;
    try v.follow("a();\r\n", false, false);
    try std.testing.expectEqualStrings("a();\r\n", v.buf.str());
    // Changed elsewhere (a page wrote a row): read again, the cursor kept.
    try v.follow("a();\r\nb();\r\n", false, false);
    try std.testing.expectEqualStrings("a();\r\nb();\r\n", v.buf.str());
    try std.testing.expectEqual(@as(usize, 3), v.buf.cursor);
    try std.testing.expect(!v.stale);
    // Typed in, then changed elsewhere: the typing stays, marked stale.
    v.buf.changed = true;
    try v.follow("c();\r\n", false, false);
    try std.testing.expectEqualStrings("a();\r\nb();\r\n", v.buf.str());
    try std.testing.expect(v.stale);
}
