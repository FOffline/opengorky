//! Scanning script text around a place (code.zig): the call it is in and which
//! argument, a call's arguments and their ends (strings and comments skipped), a named
//! argument's value, the token under it.

const std = @import("std");
const code = @import("code.zig");

const isIdent = code.isIdent;
const lineEnd = code.lineEnd;
const lineStart = code.lineStart;

/// A call around a text offset: its name, the offset of its `(` and which argument
/// (from 0) the offset is in.
pub const CallPos = struct { name: []const u8, open: usize, arg: usize };

/// Where a string or comment starting at offset `k` ends (the offset after it), as the
/// script lexer reads them: `"…"` on its line (unclosed: to the line's end), `// …` to
/// the line's end, `/* … */` (unclosed: to the text's end); null when none starts there.
/// The one rule the scanners here and the highlighter skip them by.
pub fn skipOver(t: []const u8, k: usize) ?usize {
    if (t[k] == '"') {
        const e = std.mem.indexOfAnyPos(u8, t, k + 1, "\"\n") orelse return lineEnd(t, k + 1);
        return if (t[e] == '"') e + 1 else lineEnd(t, k + 1);
    }
    if (t[k] != '/' or k + 1 >= t.len) return null;
    if (t[k + 1] == '/') return lineEnd(t, k);
    if (t[k + 1] == '*') return if (std.mem.indexOfPos(u8, t, k + 2, "*/")) |e| e + 2 else t.len;
    return null;
}

/// The calls open at an offset, read from the text's start with strings and comments
/// skipped (a statement's `;`, `{`, `}` closes them all); `to` goes on forward.
/// shortcut: reads from the text's start (scripts are a few 100 KB at most); upgrade to
/// a cached statement start if one gets much bigger.
pub const Scan = struct {
    open: [16]usize = undefined,
    commas: [16]usize = undefined,
    /// Calls open (deeper than `open` holds: counted only).
    n: usize = 0,
    /// The offset last scanned to is in a string (its `"` at `quote`) or a comment.
    in: enum { code, string, comment } = .code,
    quote: usize = 0,
    pos: usize = 0,

    pub fn to(s: *Scan, t: []const u8, i: usize) void {
        const end = @min(i, t.len);
        s.in = .code;
        var k = s.pos;
        while (k < end) : (k += 1) switch (t[k]) {
            '"', '/' => if (skipOver(t, k)) |e| {
                // At its end still in it: an unclosed string, a line comment.
                const closed = if (t[k] == '"') e - 1 > k and t[e - 1] == '"' else t[k + 1] == '*' and e >= k + 4 and t[e - 2] == '*' and t[e - 1] == '/';
                if (i < e or (i == e and !closed)) {
                    s.in = if (t[k] == '"') .string else .comment;
                    s.quote = k;
                    s.pos = k;
                    return;
                }
                k = e - 1;
            },
            '(' => {
                if (s.n < s.open.len) {
                    s.open[s.n] = k;
                    s.commas[s.n] = 0;
                }
                s.n += 1;
            },
            ')' => s.n -|= 1,
            ',' => if (s.n > 0 and s.n <= s.open.len) {
                s.commas[s.n - 1] += 1;
            },
            ';', '{', '}' => s.n = 0,
            else => {},
        };
        s.pos = end;
    }

    /// The call open at depth `d` (1 the outermost, `n` the innermost); null when that
    /// `(` is no call's.
    pub fn call(s: *const Scan, t: []const u8, d: usize) ?CallPos {
        if (d == 0 or d > @min(s.n, s.open.len)) return null;
        const k = s.open[d - 1];
        var a = k;
        while (a > 0 and t[a - 1] == ' ') a -= 1;
        const e = a;
        a = nameStart(t, e);
        const name = t[a..e];
        if (name.len == 0 or std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "while")) return null;
        return .{ .name = name, .open = k, .arg = s.commas[d - 1] };
    }
};

/// Where the name ending at offset `e` starts: identifier characters and `::` between
/// them (OG Script's `fighter::SetHp`).
pub fn nameStart(t: []const u8, e: usize) usize {
    var a = e;
    while (a > 0) {
        if (isIdent(t[a - 1])) {
            a -= 1;
        } else if (a >= 3 and t[a - 1] == ':' and t[a - 2] == ':' and isIdent(t[a - 3])) {
            a -= 2;
        } else break;
    }
    return a;
}

/// The scan of `t` up to offset `i`.
pub fn scanTo(t: []const u8, i: usize) Scan {
    var s: Scan = .{};
    s.to(t, i);
    return s;
}

/// The innermost call whose arguments hold offset `i` (within the statement; none in a
/// comment).
pub fn callAt(t: []const u8, i: usize) ?CallPos {
    const s = scanTo(t, i);
    return if (s.in == .comment) null else s.call(t, s.n);
}

test callAt {
    // `)` and `,` in strings and comments are no call's.
    const t = "// 1), a\nMonsterAttack(fighter = 1, note = \"a), b\", /* x) */ hit_delay = 2";
    const cp = callAt(t, t.len).?;
    try std.testing.expectEqualStrings("MonsterAttack", cp.name);
    try std.testing.expectEqualStrings("fighter::SetHp", callAt("x = fighter::SetHp(host, ", 25).?.name);
    try std.testing.expectEqual(2, cp.arg);
    // The comment line above is no part of it.
    try std.testing.expect(callAt(t, 4) == null);
    try std.testing.expect(callAt("// F(a, \nx", 10) == null);
    try std.testing.expect(callAt("F(a); // G(b,", 13) == null);
    try std.testing.expectEqual(1, callAt("F(\"a);\", ", 9).?.arg);
}

/// Offset of the `)` closing the call opened at `open`.
pub fn argsEnd(t: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var k = open + 1;
    while (k < t.len) : (k += 1) switch (t[k]) {
        '"', '/' => if (skipOver(t, k)) |e| {
            k = e - 1;
        },
        '(' => depth += 1,
        ')' => {
            if (depth == 0) return k;
            depth -= 1;
        },
        ';', '{', '}' => return null,
        else => {},
    };
    return null;
}

/// Start and end (spaces trimmed) of argument `n` of the call opened at `open`.
pub fn argSpan(t: []const u8, open: usize, n: usize) ?[2]usize {
    const close = argsEnd(t, open) orelse return null;
    var depth: usize = 0;
    var start = open + 1;
    var idx: usize = 0;
    var k = open + 1;
    while (k <= close) : (k += 1) {
        const ch = t[k];
        if (skipOver(t, k)) |e| {
            k = e - 1;
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')' and k < close) depth -= 1;
        if ((ch == ',' and depth == 0) or k == close) {
            if (idx == n) {
                var a = start;
                var e = k;
                while (a < e and t[a] == ' ') a += 1;
                while (e > a and t[e - 1] == ' ') e -= 1;
                if (a == e and k == close and n == 0) return null;
                return .{ a, e };
            }
            idx += 1;
            start = k + 1;
        }
    }
    return null;
}

/// The `name = value` argument of the call opened at `open` that offset `i` is in: the
/// name, the value as written (up to the argument's end: nested calls and strings whole)
/// and where the value starts; null when that argument is no `name = value`.
pub const NamedArg = struct { name: []const u8, value: []const u8, value_start: usize };

pub fn namedArg(t: []const u8, open: usize, i: usize) ?NamedArg {
    var depth: usize = 0;
    var start = open + 1;
    var k = open + 1;
    // The argument's start: after the last top-level `,` before `i`.
    while (k < @min(i, t.len)) : (k += 1) switch (t[k]) {
        '"', '/' => if (skipOver(t, k)) |e| {
            if (e > i) break;
            k = e - 1;
        },
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        ',' => if (depth == 0) {
            start = k + 1;
        },
        else => {},
    };
    var a = start;
    // Past spaces and comments (a `// …` line above it, a `/* */` before it).
    while (a < t.len) {
        if (std.ascii.isWhitespace(t[a])) {
            a += 1;
        } else if (t[a] == '/' and skipOver(t, a) != null) {
            a = skipOver(t, a).?;
        } else break;
    }
    var e = a;
    while (e < t.len and isIdent(t[e])) e += 1;
    if (e == a) return null;
    var q = e;
    while (q < t.len and (t[q] == ' ' or t[q] == '\t')) q += 1;
    if (q >= t.len or t[q] != '=' or (q + 1 < t.len and t[q + 1] == '=')) return null;
    const vs = q + 1;
    const ve = valueEnd(t, vs, true);
    return .{ .name = t[a..e], .value = std.mem.trim(u8, t[vs..ve], " \t\r\n"), .value_start = vs };
}

/// Where a value starting at `from` ends: at `;`, or (`in_call`) at a top-level `,` or
/// the `)` closing its call; nested calls and strings are whole.
fn valueEnd(t: []const u8, from: usize, in_call: bool) usize {
    var depth: usize = 0;
    var k = from;
    while (k < t.len) : (k += 1) switch (t[k]) {
        '"', '/' => if (skipOver(t, k)) |e| {
            k = e - 1;
        },
        '(', '[' => depth += 1,
        ']' => depth -|= 1,
        ')' => if (depth == 0) {
            if (in_call) return k;
        } else {
            depth -= 1;
        },
        ',' => if (depth == 0 and in_call) return k,
        ';', '{', '}' => return k,
        else => {},
    };
    return t.len;
}

test namedArg {
    const t = "AiProfile(class = 1, scoring = \"a,b\", rgb = list(1, 2), walks = 1);";
    const at = std.mem.indexOf(u8, t, "scoring").? + 2;
    const n = namedArg(t, 9, at).?;
    try std.testing.expectEqualStrings("scoring", n.name);
    try std.testing.expectEqualStrings("\"a,b\"", n.value);
    try std.testing.expectEqualStrings("list(1, 2)", namedArg(t, 9, std.mem.indexOf(u8, t, "rgb").?).?.value);
    try std.testing.expectEqualStrings("1", namedArg(t, 9, t.len - 3).?.value);
    try std.testing.expect(namedArg("F(1, 2)", 1, 5) == null);
    // A list's `,` is no argument's end (`resist = [fire, gas]`).
    const l = "Resist(resist = [fire, ga], armor = 1);";
    const li = namedArg(l, 6, std.mem.indexOf(u8, l, "ga]").?).?;
    try std.testing.expectEqualStrings("resist", li.name);
    try std.testing.expectEqualStrings("[fire, ga]", li.value);
    // Comments before it and `)` / `,` in them are no part of it.
    const u = "F(a = 1, // b), c\n  /* d, */ wait = 2);";
    try std.testing.expectEqualStrings("wait", namedArg(u, 1, u.len - 4).?.name);
    try std.testing.expectEqualStrings("2", namedArg(u, 1, u.len - 4).?.value);
    try std.testing.expectEqual(@as(usize, 18), valueEnd("x = foo(a, b) + 1; y", 3, false) + 1);
}

/// `w = value`: its value — the one at `cursor`, else the first. In a call's arguments
/// (`f(w = 1, x = 2)`) up to the argument's end, else up to `;` (`w = f(a, b);` whole).
pub fn valueOf(t: []const u8, w: []const u8, cursor: usize) ?[]const u8 {
    var first: ?[]const u8 = null;
    var pos: usize = 0;
    var s: Scan = .{};
    while (std.mem.indexOfPos(u8, t, pos, w)) |i| {
        pos = i + w.len;
        if (i > 0 and isIdent(t[i - 1])) continue;
        if (pos < t.len and isIdent(t[pos])) continue;
        var j = pos;
        while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
        if (j >= t.len or t[j] != '=' or (j + 1 < t.len and t[j + 1] == '=')) continue;
        // One in a string or a comment is none.
        s.to(t, i);
        if (s.in != .code) continue;
        const val = std.mem.trim(u8, t[j + 1 .. valueEnd(t, j + 1, s.call(t, s.n) != null)], " \t\r\n");
        if (cursor >= i and cursor <= pos) return val;
        if (first == null) first = val;
    }
    return first;
}

test valueOf {
    const t = "// x = 1)\nx = foo(a, b);\nAiProfile(class = 0, scoring = \"generic\", walks = 1);\nAiProfile(class = 1, scoring = \"garcia\");";
    try std.testing.expectEqualStrings("foo(a, b)", valueOf(t, "x", 0).?);
    try std.testing.expectEqualStrings("\"a); b\"", valueOf("F(n = \"a); b\", m = 2);", "n", 0).?);
    try std.testing.expectEqualStrings("\"generic\"", valueOf(t, "scoring", 0).?);
    try std.testing.expectEqualStrings("\"garcia\"", valueOf(t, "scoring", std.mem.lastIndexOf(u8, t, "scoring").? + 1).?);
}

/// A token of the text: a string's text (between its quotes) or a word.
pub const Token = struct { start: usize, end: usize, string: bool };

/// The token at offset `i`: the string it is in (its quotes count), else the word
/// (letters, digits, `_`) around it; null on neither. A `//` comment ends the strings.
pub fn tokenAt(t: []const u8, i: usize) ?Token {
    if (i > t.len) return null;
    const ls = lineStart(t, i);
    const le = lineEnd(t, i);
    var k = ls;
    while (k < le) : (k += 1) {
        const e = skipOver(t, k) orelse continue;
        if (t[k] == '/') {
            if (t[k + 1] == '/') break;
            k = e - 1;
            continue;
        }
        const close = if (e - 1 > k and t[e - 1] == '"') e - 1 else e;
        if (i >= k and i <= close) return .{ .start = k + 1, .end = close, .string = true };
        k = e - 1;
    }
    var a = i;
    var b = i;
    while (a > ls and isIdent(t[a - 1])) a -= 1;
    while (b < le and isIdent(t[b])) b += 1;
    if (a == b) return null;
    return .{ .start = a, .end = b, .string = false };
}

test tokenAt {
    const t = "  PlaceActor(\"Sullivan\", x1); // \"no\"\nb";
    try std.testing.expectEqualStrings("Sullivan", t[tokenAt(t, 16).?.start..tokenAt(t, 16).?.end]);
    try std.testing.expect(tokenAt(t, 13).?.string);
    try std.testing.expectEqualStrings("PlaceActor", t[tokenAt(t, 4).?.start..tokenAt(t, 4).?.end]);
    try std.testing.expectEqualStrings("x1", t[tokenAt(t, 26).?.start..tokenAt(t, 26).?.end]);
    try std.testing.expect(!tokenAt(t, 36).?.string);
    try std.testing.expect(tokenAt(t, 0) == null);
}

/// Argument `n` of the call opened at `open` as written, a string's quotes off; null when
/// the call is not closed or has no such argument.
pub fn argValue(t: []const u8, open: usize, n: usize) ?[]const u8 {
    const s = argSpan(t, open, n) orelse return null;
    const v = t[s[0]..s[1]];
    return if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v[1 .. v.len - 1] else v;
}
