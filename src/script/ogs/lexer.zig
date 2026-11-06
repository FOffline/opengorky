//! Lexer of OGS: C-like tokens, `//` and `/* */` comments, strings with
//! `\" \\ \n \t` escapes, `::` paths, `..` ranges, `~` of a sigil (`~l"01_port"`).
//! Keywords are words the parser checks.

const std = @import("std");

pub const Tag = enum {
    word,
    int,
    float,
    string,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    semicolon,
    dot,
    dot_dot,
    colon,
    colon_colon,
    at,
    tilde,
    equal,
    plus_equal,
    minus_equal,
    equal_equal,
    bang,
    bang_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    plus,
    minus,
    star,
    slash,
    percent,
    amp_amp,
    pipe_pipe,
    eof,
};

pub const Token = struct {
    tag: Tag,
    /// The token's text (a string with its quotes and escapes).
    text: []const u8,
    line: u32,
    /// Byte offset in the source.
    start: u32,
};

pub const Error = error{ UnexpectedChar, UnterminatedString, UnterminatedComment };

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    /// Line of the last error.
    err_line: u32 = 0,

    pub fn next(self: *Lexer) Error!Token {
        try @import("../lexer.zig").skipTrivia(self);
        const start = self.pos;
        const line = self.line;
        if (start >= self.src.len) return .{ .tag = .eof, .text = "", .line = line, .start = @intCast(start) };
        const ch = self.src[start];
        self.pos += 1;
        const tag: Tag = switch (ch) {
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ',' => .comma,
            ';' => .semicolon,
            '@' => .at,
            '~' => .tilde,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '.' => if (self.eat('.')) .dot_dot else .dot,
            ':' => if (self.eat(':')) .colon_colon else .colon,
            '+' => if (self.eat('=')) .plus_equal else .plus,
            '-' => if (self.eat('=')) .minus_equal else .minus,
            '=' => if (self.eat('=')) .equal_equal else .equal,
            '!' => if (self.eat('=')) .bang_equal else .bang,
            '<' => if (self.eat('=')) .less_equal else .less,
            '>' => if (self.eat('=')) .greater_equal else .greater,
            '&' => if (self.eat('&')) .amp_amp else return self.fail(),
            '|' => if (self.eat('|')) .pipe_pipe else return self.fail(),
            '"' => blk: {
                while (self.pos < self.src.len and self.src[self.pos] != '"') : (self.pos += 1) {
                    if (self.src[self.pos] == '\n') break;
                    if (self.src[self.pos] == '\\') self.pos += 1;
                }
                if (self.pos >= self.src.len or self.src[self.pos] != '"') {
                    self.err_line = line;
                    return error.UnterminatedString;
                }
                self.pos += 1;
                break :blk .string;
            },
            '0'...'9' => blk: {
                self.digits();
                var float = false;
                // `1..5` is a range, `x.0` never starts here.
                if (self.at(0) == '.' and std.ascii.isDigit(self.at(1))) {
                    self.pos += 1;
                    self.digits();
                    float = true;
                }
                if ((self.at(0) == 'e' or self.at(0) == 'E') and (std.ascii.isDigit(self.at(1)) or ((self.at(1) == '-' or self.at(1) == '+') and std.ascii.isDigit(self.at(2))))) {
                    self.pos += 2;
                    self.digits();
                    float = true;
                }
                break :blk if (float) .float else .int;
            },
            'a'...'z', 'A'...'Z', '_' => blk: {
                while (std.ascii.isAlphanumeric(self.at(0)) or self.at(0) == '_') self.pos += 1;
                break :blk .word;
            },
            else => return self.fail(),
        };
        return .{ .tag = tag, .text = self.src[start..self.pos], .line = line, .start = @intCast(start) };
    }

    fn at(self: *const Lexer, k: usize) u8 {
        return if (self.pos + k < self.src.len) self.src[self.pos + k] else 0;
    }

    fn digits(self: *Lexer) void {
        while (std.ascii.isDigit(self.at(0))) self.pos += 1;
    }

    fn fail(self: *Lexer) Error {
        self.err_line = self.line;
        return error.UnexpectedChar;
    }

    fn eat(self: *Lexer, ch: u8) bool {
        if (self.at(0) != ch) return false;
        self.pos += 1;
        return true;
    }
};

/// A string token's value, escapes decoded (`\"`, `\\`, `\n`, `\t`; another `\c` stays
/// as written); in `a` when it has any.
pub fn stringValue(a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    const body = text[1 .. text.len - 1];
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return body;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\' or i + 1 == body.len) {
            try out.append(a, body[i]);
            continue;
        }
        i += 1;
        switch (body[i]) {
            '"', '\\' => try out.append(a, body[i]),
            'n' => try out.append(a, '\n'),
            't' => try out.append(a, '\t'),
            else => try out.appendSlice(a, body[i - 1 .. i + 1]),
        }
    }
    return out.items;
}

/// `s` as an OGS string literal (what `stringValue` reads back).
pub fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "OGS tokens: paths, ranges, compound assignment, escapes" {
    var lx: Lexer = .{ .src = "a::b.c(x: 1..5, 2.5e1) += -= @g /* c\n */ \"q\\\"\\\\\\n\" % 3." };
    const want = [_]Tag{ .word, .colon_colon, .word, .dot, .word, .l_paren, .word, .colon, .int, .dot_dot, .int, .comma, .float, .r_paren, .plus_equal, .minus_equal, .at, .word, .string, .percent, .int, .dot, .eof };
    var s: Token = undefined;
    for (want) |t| {
        const tok = try lx.next();
        if (tok.tag == .string) s = tok;
        try std.testing.expectEqual(t, tok.tag);
    }
    try std.testing.expectEqual(2, s.line);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("q\"\\\n", try stringValue(arena.allocator(), s.text));
    try std.testing.expectEqualStrings("weapons\\x", try stringValue(arena.allocator(), "\"weapons\\x\""));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeString(&aw.writer, "a\"b\\n\n");
    try std.testing.expectEqualStrings("a\"b\\n\n", try stringValue(arena.allocator(), aw.written()));
}
