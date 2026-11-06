//! Lexer of the Gorky 17 script language (`.lev .act .ba .aba .s .ss .itm .are .obs .wpn .ftr .hro …`).

const std = @import("std");

pub const Tag = enum {
    identifier,
    int_literal,
    float_literal,
    string_literal,
    /// `#include name` / `#inherit Name`: the argument is the rest of the line (see `Token.arg`).
    directive_include,
    directive_inherit,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    semicolon,
    comma,
    equal,
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
    amp_amp,
    pipe_pipe,
    eof,
};

pub const Token = struct {
    tag: Tag,
    /// Token text in the source (strings include the quotes).
    text: []const u8,
    line: u32,

    /// Directive argument, trimmed.
    pub fn arg(self: Token) []const u8 {
        const space = std.mem.indexOfAny(u8, self.text, " \t") orelse return "";
        return std.mem.trim(u8, self.text[space..], " \t\r");
    }

    /// String literal contents without quotes (the language has no escapes).
    pub fn stringValue(self: Token) []const u8 {
        return self.text[1 .. self.text.len - 1];
    }
};

pub const Error = error{ UnexpectedChar, UnterminatedString, UnterminatedComment, UnknownDirective };

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    /// Line of the last error.
    err_line: u32 = 0,

    /// The text ends at the first NUL, as the exe's C string does: mods pad scripts with
    /// zeros after the last line.
    pub fn init(src: []const u8) Lexer {
        return .{ .src = src[0 .. std.mem.indexOfScalar(u8, src, 0) orelse src.len] };
    }

    pub fn next(self: *Lexer) Error!Token {
        try skipTrivia(self);
        const start = self.pos;
        const line = self.line;
        if (start >= self.src.len) return .{ .tag = .eof, .text = "", .line = line };
        const ch = self.src[start];
        self.pos += 1;
        const tag: Tag = switch (ch) {
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            ';' => .semicolon,
            ',' => .comma,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '=' => if (self.eat('=')) .equal_equal else .equal,
            '!' => if (self.eat('=')) .bang_equal else .bang,
            '<' => if (self.eat('=')) .less_equal else .less,
            '>' => if (self.eat('=')) .greater_equal else .greater,
            '&' => if (self.eat('&')) .amp_amp else return self.fail(),
            '|' => if (self.eat('|')) .pipe_pipe else return self.fail(),
            '"' => blk: {
                while (self.pos < self.src.len and self.src[self.pos] != '"') : (self.pos += 1) {
                    if (self.src[self.pos] == '\n') {
                        self.err_line = line;
                        return error.UnterminatedString;
                    }
                }
                if (self.pos >= self.src.len) {
                    self.err_line = line;
                    return error.UnterminatedString;
                }
                self.pos += 1;
                break :blk .string_literal;
            },
            '#' => blk: {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                const text = self.src[start..self.pos];
                if (std.mem.startsWith(u8, text, "#include")) break :blk .directive_include;
                if (std.mem.startsWith(u8, text, "#inherit")) break :blk .directive_inherit;
                self.err_line = line;
                return error.UnknownDirective;
            },
            '0'...'9', '.' => blk: {
                var is_float = ch == '.';
                while (self.pos < self.src.len) : (self.pos += 1) {
                    const d = self.src[self.pos];
                    // Every dot joins: mods hex-edit a number keeping its length (`106` → `5..`).
                    if (d == '.') {
                        is_float = true;
                    } else if (!std.ascii.isDigit(d)) break;
                }
                break :blk if (is_float) .float_literal else .int_literal;
            },
            'a'...'z', 'A'...'Z', '_' => blk: {
                while (self.pos < self.src.len) : (self.pos += 1) {
                    const d = self.src[self.pos];
                    if (std.ascii.isAlphanumeric(d) or d == '_') continue;
                    // A field access `target.hp` (only in classes\inventoryitem.s) is lexed as one
                    // compound name.
                    if (d == '.' and self.pos + 1 < self.src.len and std.ascii.isAlphabetic(self.src[self.pos + 1])) continue;
                    break;
                }
                break :blk .identifier;
            },
            else => return self.fail(),
        };
        return .{ .tag = tag, .text = self.src[start..self.pos], .line = line };
    }

    fn fail(self: *Lexer) Error {
        self.err_line = self.line;
        return error.UnexpectedChar;
    }

    fn eat(self: *Lexer, ch: u8) bool {
        if (self.pos < self.src.len and self.src[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }
};

/// Whitespace and `//`, `/* */` comments of lexer `lx` (this one or OGS's: fields `src`,
/// `pos`, `line`, `err_line`) skipped, lines counted; an unclosed `/*` is an error at its line.
pub fn skipTrivia(lx: anytype) error{UnterminatedComment}!void {
    while (lx.pos < lx.src.len) {
        const ch = lx.src[lx.pos];
        if (ch == '\n') {
            lx.line += 1;
            lx.pos += 1;
        } else if (std.ascii.isWhitespace(ch) or ch == 0x1a) {
            // 0x1A: DOS EOF at the end of some files.
            lx.pos += 1;
        } else if (std.mem.startsWith(u8, lx.src[lx.pos..], "//")) {
            while (lx.pos < lx.src.len and lx.src[lx.pos] != '\n') lx.pos += 1;
        } else if (std.mem.startsWith(u8, lx.src[lx.pos..], "/*")) {
            const start_line = lx.line;
            lx.pos += 2;
            while (!std.mem.startsWith(u8, lx.src[lx.pos..], "*/")) : (lx.pos += 1) {
                if (lx.pos >= lx.src.len) {
                    lx.err_line = start_line;
                    return error.UnterminatedComment;
                }
                if (lx.src[lx.pos] == '\n') lx.line += 1;
            }
            lx.pos += 2;
        } else break;
    }
}

test "lex statements, comments and directives" {
    var lx: Lexer = .init("#inherit Level\r\n// c\r\nint a; /* x\r\n y */ a=-1.5;\r\nif(a>=2&&b!=\"s\") return(0);");
    const expected = [_]Tag{
        .directive_inherit, .identifier, .identifier, .semicolon,      .identifier, .equal,         .minus,
        .float_literal,     .semicolon,  .identifier, .l_paren,        .identifier, .greater_equal, .int_literal,
        .amp_amp,           .identifier, .bang_equal, .string_literal, .r_paren,    .identifier,    .l_paren,
        .int_literal,       .r_paren,    .semicolon,  .eof,
    };
    var first: Token = undefined;
    for (expected, 0..) |tag, i| {
        const t = try lx.next();
        if (i == 0) first = t;
        try std.testing.expectEqual(tag, t.tag);
    }
    try std.testing.expectEqualStrings("Level", first.arg());
}

test "padding dots stay in the number" {
    var lex = Lexer.init("5..;");
    const t = try lex.next();
    try std.testing.expectEqual(Tag.float_literal, t.tag);
    try std.testing.expectEqualStrings("5..", t.text);
    try std.testing.expectEqual(Tag.semicolon, (try lex.next()).tag);
}

test "NUL ends the text" {
    var lex = Lexer.init("x;\r\n\x00\x00@");
    try std.testing.expectEqual(Tag.identifier, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.semicolon, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.eof, (try lex.next()).tag);
}

test "dotted names" {
    var lx: Lexer = .init("target.hp = target.hp + 20;");
    const t = try lx.next();
    try std.testing.expectEqual(Tag.identifier, t.tag);
    try std.testing.expectEqualStrings("target.hp", t.text);
}

test "line numbers" {
    var lx: Lexer = .init("a\n/*\n\n*/b\n\"x\"");
    try std.testing.expectEqual(1, (try lx.next()).line);
    try std.testing.expectEqual(4, (try lx.next()).line);
    const s = try lx.next();
    try std.testing.expectEqual(5, s.line);
    try std.testing.expectEqualStrings("x", s.stringValue());
}
