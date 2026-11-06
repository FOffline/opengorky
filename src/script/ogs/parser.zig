//! OGS parser: text → IR, one `ir.Module` per `module` block (the
//! text's top level is the root namespace). Recursive descent. Locals bind to slots as
//! they are declared (one slot per name in a function; blocks don't scope, as in
//! Classic); any other name in a component's method is a `field` (the component's, else
//! the host's); calls are left to `link.zig`. Case-sensitive. The Classic importer's
//! nodes have `classic::` forms (`classic::name("x")`, `classic::add(a, b)`…) so the
//! printer can write imported Classic code and this parser reads it back to the same IR.
//! Data (blocks' fields, records, commands) has no code: a name there is
//! a path to a block or an enum word (`ir.Expr.Kind.word`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const ir = @import("../ir.zig");
const ast = @import("../ast.zig");
const object = @import("../names.zig");
const Token = lexer.Token;
const Tag = lexer.Tag;

pub const Error = lexer.Error || Allocator.Error || error{ParseError};
pub const Diagnostic = @import("../parser.zig").Diagnostic;

/// The blocks of one text: the root namespace first, then each `module` block in order;
/// the text's file (messages).
pub const Unit = struct { modules: []const ir.Module, file: []const u8 = "" };

/// Words that never name a local, a field, a function or a component.
const keywords = [_][]const u8{ "module", "use", "component", "fn", "param", "var", "if", "else", "while", "for", "in", "return", "break", "continue", "and", "or", "not", "nil", "true", "false", "host", "self", "attach", "trait", "is", "super", "native" };

pub fn isKeyword(w: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

/// Parses text `src` of `file` (positions only: nothing is named by it). Nodes and
/// strings are in `a` or point into `src`; on error `diag` has the line and why.
pub fn parse(a: Allocator, src: []const u8, file: []const u8, diag: *Diagnostic) Error!Unit {
    return parseAs(a, src, file, diag, false);
}

/// An object's own functions (a Classic script shown as OGS, `classic/rename.zig`):
/// `host` is the object outside a component too.
pub fn parseHosted(a: Allocator, src: []const u8, file: []const u8, diag: *Diagnostic) Error!Unit {
    return parseAs(a, src, file, diag, true);
}

fn parseAs(a: Allocator, src: []const u8, file: []const u8, diag: *Diagnostic, hosted: bool) Error!Unit {
    var p: Parser = .{ .a = a, .lx = .{ .src = src }, .diag = diag, .file = file, .hosted = hosted };
    try p.advance();
    try p.items("", .eof);
    return .{ .modules = p.modules.items, .file = file };
}

/// The top-level calls of a rules text (`rules\*.ss`: rows), from every block.
pub fn rows(a: Allocator, src: []const u8, file: []const u8, diag: *Diagnostic) Error![]const *const ir.Expr {
    const u = try parse(a, src, file, diag);
    if (u.modules.len == 1) return u.modules[0].rows;
    var out: std.ArrayList(*const ir.Expr) = .empty;
    for (u.modules) |m| try out.appendSlice(a, m.rows);
    return out.items;
}

const FnState = struct { names: std.ArrayList([]const u8) = .empty };

const Parser = struct {
    a: Allocator,
    lx: lexer.Lexer,
    diag: *Diagnostic,
    file: []const u8,
    tok: Token = .{ .tag = .eof, .text = "", .line = 0, .start = 0 },
    peeked: ?Token = null,
    /// Where the token before `tok` ends (a function's span ends at its `}`).
    prev_end: u32 = 0,
    modules: std.ArrayList(ir.Module) = .empty,
    /// The function being parsed (its locals), the component (its methods' free names are fields).
    fs: ?*FnState = null,
    in_component: bool = false,
    /// The namespace of the module being parsed (a block's own code's component is there).
    module_path: []const u8 = "",
    /// The blocks' own components made in the module being parsed (`items` adds them).
    own: std.ArrayList(*const ir.Component) = .empty,
    /// `parseHosted`.
    hosted: bool = false,
    /// Parsing data: a word or a path is an `ir.Expr.Kind.word`.
    in_data: bool = false,
    /// Parsing a trait's methods; the last one had no body (`fn f(a);`).
    in_trait: bool = false,
    declared_only: bool = false,
    /// The built-in method being read (engine.ogs): `function` fills its docs.
    engine_fn: ?*ir.EngineFn = null,

    fn advance(self: *Parser) Error!void {
        self.prev_end = self.tok.start + @as(u32, @intCast(self.tok.text.len));
        if (self.peeked) |t| {
            self.tok = t;
            self.peeked = null;
            return;
        }
        self.tok = try self.lex();
    }

    fn lex(self: *Parser) Error!Token {
        return self.lx.next() catch |err| {
            self.diag.* = .{ .line = self.lx.err_line, .message = @errorName(err) };
            return err;
        };
    }

    fn peek(self: *Parser) Error!Token {
        if (self.peeked == null) self.peeked = try self.lex();
        return self.peeked.?;
    }

    fn fail(self: *Parser, message: []const u8) Error {
        self.diag.* = .{ .line = self.tok.line, .message = message };
        return error.ParseError;
    }

    fn failf(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        return self.fail(try std.fmt.allocPrint(self.a, fmt, args));
    }

    fn expect(self: *Parser, tag: Tag, message: []const u8) Error!Token {
        if (self.tok.tag != tag) return self.fail(message);
        const t = self.tok;
        try self.advance();
        return t;
    }

    fn eat(self: *Parser, tag: Tag) Error!bool {
        if (self.tok.tag != tag) return false;
        try self.advance();
        return true;
    }

    fn isWord(self: *const Parser, w: []const u8) bool {
        return self.tok.tag == .word and std.mem.eql(u8, self.tok.text, w);
    }

    fn eatWord(self: *Parser, w: []const u8) Error!bool {
        if (!self.isWord(w)) return false;
        try self.advance();
        return true;
    }

    /// A word that is no keyword.
    fn name(self: *Parser, what: []const u8) Error![]const u8 {
        if (self.tok.tag != .word or isKeyword(self.tok.text)) return self.failf("expected {s}", .{what});
        const t = self.tok.text;
        try self.advance();
        return t;
    }

    /// `a::b::c`.
    fn path(self: *Parser, what: []const u8) Error![]const u8 {
        var text = try self.name(what);
        while (try self.eat(.colon_colon)) text = try std.fmt.allocPrint(self.a, "{s}::{s}", .{ text, try self.name(what) });
        return text;
    }

    fn node(self: *Parser, line: u32, kind: ir.Expr.Kind) Allocator.Error!*const ir.Expr {
        const e = try self.a.create(ir.Expr);
        e.* = .{ .line = line, .kind = kind };
        return e;
    }

    fn push(self: *Parser, out: *std.ArrayList(ir.Stmt), line: u32, kind: ir.Stmt.Kind) Allocator.Error!void {
        try out.append(self.a, .{ .file = self.file, .line = line, .kind = kind });
    }

    // ---------------------------------------------------------------- module items

    fn items(self: *Parser, module_path: []const u8, end: Tag) Error!void {
        const outer_path = self.module_path;
        self.module_path = module_path;
        defer self.module_path = outer_path;
        const own_from = self.own.items.len;
        const index = self.modules.items.len;
        try self.modules.append(self.a, undefined);
        var uses: std.ArrayList([]const u8) = .empty;
        var fns: std.ArrayList(*const ir.Fn) = .empty;
        var comps: std.ArrayList(*const ir.Component) = .empty;
        var traits: std.ArrayList(*ir.Trait) = .empty;
        var structs: std.ArrayList(*const ir.Struct) = .empty;
        var enums: std.ArrayList(*const ir.Enum) = .empty;
        var ents: std.ArrayList(ir.Entity) = .empty;
        var row_list: std.ArrayList(*const ir.Expr) = .empty;
        while (self.tok.tag != end) {
            if (self.tok.tag == .eof) return self.fail("expected }");
            if (try self.eat(.semicolon)) continue;
            if (try self.eatWord("module")) {
                const sub = try self.path("module name");
                const full = if (module_path.len == 0) sub else try std.fmt.allocPrint(self.a, "{s}::{s}", .{ module_path, sub });
                _ = try self.expect(.l_brace, "expected { after the module name");
                try self.items(full, .r_brace);
                _ = try self.expect(.r_brace, "expected }");
            } else if (try self.eatWord("use")) {
                try uses.append(self.a, try self.path("namespace"));
                _ = try self.expect(.semicolon, "expected ; after use");
            } else if (self.isWord("component")) {
                try comps.append(self.a, try self.component(module_path));
            } else if (self.isWord("trait") or ((self.isWord("role") or self.isWord("mark")) and self.engineFile() and (try self.peek()).tag == .word and std.mem.eql(u8, (try self.peek()).text, "trait"))) {
                try traits.append(self.a, try self.trait(module_path));
            } else if (self.isWord("struct") and (try self.peek()).tag == .word) {
                try structs.append(self.a, try self.structDecl(module_path));
            } else if (self.isWord("host") and (try self.peek()).tag == .word) {
                try structs.append(self.a, try self.hostDecl(module_path));
            } else if (self.isWord("enum") and (try self.peek()).tag == .word) {
                try enums.append(self.a, try self.enumDecl(module_path));
            } else if (self.isWord("native")) {
                return self.fail(native_msg);
            } else if (self.isWord("fn")) {
                try fns.append(self.a, try self.function(null));
            } else if (try self.atBlock()) {
                try ents.append(self.a, try self.entity());
            } else {
                // A rules row: a call (data, never run: its words are names, `[sleep, burn]`).
                const was = self.in_data;
                self.in_data = true;
                const e = self.expr() catch |err| {
                    self.in_data = was;
                    return err;
                };
                self.in_data = was;
                if (e.kind != .call) return self.fail("expected a declaration or a call");
                try row_list.append(self.a, e);
                _ = try self.expect(.semicolon, "expected ;");
            }
        }
        for (traits.items) |t| t.uses = uses.items;
        // The blocks' own code (theirs only: a nested module's went to it).
        try comps.appendSlice(self.a, self.own.items[own_from..]);
        self.own.shrinkRetainingCapacity(own_from);
        self.modules.items[index] = .{ .path = module_path, .uses = uses.items, .fns = fns.items, .components = comps.items, .traits = traits.items, .structs = structs.items, .enums = enums.items, .entities = ents.items, .rows = row_list.items };
    }

    fn typeOf(type_name: []const u8) ir.Type {
        for ([_]ir.Type{ .int, .float, .string, .object, .bool }) |t| if (std.mem.eql(u8, @tagName(t), type_name)) return t;
        return .any;
    }

    fn component(self: *Parser, module_path: []const u8) Error!*const ir.Component {
        const line = self.tok.line;
        const start = self.tok.start;
        try self.advance();
        const cname = try self.name("component name");
        var hosts: std.ArrayList([]const u8) = .empty;
        if (try self.eatWord("for")) while (true) {
            try hosts.append(self.a, try self.name("host kind"));
            if (!try self.eat(.comma)) break;
        };
        const traits = try self.traitList();
        const open = (try self.expect(.l_brace, "expected { after the component's name")).start;
        const comp = try self.a.create(ir.Component);
        var fields: std.ArrayList(ir.Field) = .empty;
        var methods: std.ArrayList(*const ir.Fn) = .empty;
        self.in_component = true;
        defer self.in_component = false;
        while (self.tok.tag != .r_brace) {
            if (try self.eat(.semicolon)) continue;
            if (self.isWord("param") or self.isWord("var")) {
                const f = try self.field();
                // An instance's fields are an `Object`'s variables, case-insensitive.
                for (fields.items) |g| if (std.ascii.eqlIgnoreCase(g.name, f.name)) return self.failf("field {s} declared twice (names apart only by case clash)", .{f.name});
                try fields.append(self.a, f);
            } else if (self.isWord("fn")) {
                const m = try self.function(comp);
                for (methods.items) |g| if (std.mem.eql(u8, g.name, m.name)) return self.failf("method {s} defined twice", .{m.name});
                try methods.append(self.a, m);
            } else return self.fail(if (self.isWord("native")) native_msg else "expected param, var, fn or }");
        }
        const end = self.tok.start + 1;
        try self.advance();
        comp.* = .{ .name = cname, .module = module_path, .hosts = hosts.items, .traits = traits, .fields = fields.items, .methods = methods.items, .line = line, .span = .{ .start = start, .end = end }, .open = open };
        return comp;
    }

    /// `: T1, a::T2` after a trait's or a component's name.
    fn traitList(self: *Parser) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (try self.eat(.colon)) while (true) {
            try out.append(self.a, try self.path("trait"));
            if (!try self.eat(.comma)) break;
        };
        return out.items;
    }

    const native_msg = "native is the engine's (engine.ogs)";

    fn dupe(self: *Parser, comptime T: type, v: T) Error!*const T {
        const x = try self.a.create(T);
        x.* = v;
        return x;
    }

    fn engineFile(self: *const Parser) bool {
        return std.mem.eql(u8, self.file, "engine.ogs");
    }

    /// `"text"` (engine.ogs: a built-in trait's, method's, parameter's): English only, the
    /// one text for every interface language.
    fn engineDoc(self: *Parser, what: []const u8) Error!ir.Doc {
        if (self.tok.tag != .string) return self.failf("expected the {s}'s text", .{what});
        const t = try lexer.stringValue(self.a, self.tok.text);
        try self.advance();
        return .{ .en = t, .ru = t };
    }

    /// `trait Name [: Super, …] { [native] fn f(a); fn g(a) { … } }`; in
    /// engine.ogs a built-in one: `[role|mark] trait Name [: Super] [for kind] "what"
    /// { [native] [live] [combine] fn f(a "meaning") "when" [default "…"] { … } }`
    /// (foundation/traits.ogs).
    fn trait(self: *Parser, module_path: []const u8) Error!*ir.Trait {
        const line = self.tok.line;
        const engine = self.engineFile();
        var et: ir.EngineTrait = .{ .kind = .host, .doc = .{} };
        if (engine and !self.isWord("trait")) {
            et.kind = if (self.isWord("role")) .role else .mark;
            try self.advance();
        }
        try self.advance();
        const tname = try self.name("trait name");
        const supers = try self.traitList();
        if (engine) {
            if (try self.eatWord("for")) et.host = try self.name("host kind");
            if (self.tok.tag == .string) et.doc = try self.engineDoc("trait");
        }
        _ = try self.expect(.l_brace, "expected { after the trait's name");
        var methods: std.ArrayList(ir.TraitFn) = .empty;
        var params: std.ArrayList(ir.Field) = .empty;
        // A default body sees `host` and `self`; a bare name is linked as an error.
        self.in_component = true;
        self.in_trait = true;
        defer self.in_component = false;
        defer self.in_trait = false;
        while (!try self.eat(.r_brace)) {
            if (try self.eat(.semicolon)) continue;
            const native = self.isWord("native");
            if (native) {
                if (!engine) return self.fail(native_msg);
                try self.advance();
            }
            var ef: ir.EngineFn = .{ .when = .{} };
            if (engine) {
                ef.live = try self.eatWord("live");
                for ([_][]const u8{ "chain", "veto", "first", "handled", "sum", "all" }) |c| if (try self.eatWord(c)) {
                    ef.combine = c;
                    break;
                };
            }
            if (self.isWord("param")) {
                const f = try self.field();
                for (params.items) |g| if (std.ascii.eqlIgnoreCase(g.name, f.name)) return self.failf("param {s} declared twice", .{f.name});
                try params.append(self.a, f);
                continue;
            }
            if (!self.isWord("fn")) return self.fail("a trait has no state (var): only param and fn");
            self.engine_fn = if (engine) &ef else null;
            defer self.engine_fn = null;
            const f = try self.function(null);
            for (methods.items) |g| if (std.mem.eql(u8, g.f.name, f.name)) return self.failf("method {s} defined twice", .{f.name});
            try methods.append(self.a, .{ .f = f, .body = !self.declared_only, .native = native, .engine = if (engine) try self.dupe(ir.EngineFn, ef) else null });
        }
        const t = try self.a.create(ir.Trait);
        t.* = .{ .name = tname, .module = module_path, .supers = supers, .methods = methods.items, .params = params.items, .file = self.file, .line = line, .engine = if (engine) try self.dupe(ir.EngineTrait, et) else null };
        return t;
    }

    /// `struct Name { Type name [= default] ["Label"]; … }`: fields only.
    fn structDecl(self: *Parser, module_path: []const u8) Error!*const ir.Struct {
        const line = self.tok.line;
        try self.advance();
        const sname = try self.name("struct name");
        _ = try self.expect(.l_brace, "expected { after the struct's name");
        var fields: std.ArrayList(ir.Field) = .empty;
        while (!try self.eat(.r_brace)) {
            if (try self.eat(.semicolon)) continue;
            if (self.isWord("fn")) return self.fail("a struct is data: no fn");
            const f = try self.fieldRest(.param, true);
            for (fields.items) |g| if (std.mem.eql(u8, g.name, f.name)) return self.failf("field {s} declared twice", .{f.name});
            try fields.append(self.a, f);
        }
        const s = try self.a.create(ir.Struct);
        s.* = .{ .name = sname, .module = module_path, .fields = fields.items, .file = self.file, .line = line };
        return s;
    }

    /// `host fighter : actor { int hp = 0 "…"; }`: a data block kind's fields as the engine
    /// declares them (foundation/hosts.ogs, core/field_docs.zig writeHosts).
    fn hostDecl(self: *Parser, module_path: []const u8) Error!*const ir.Struct {
        const line = self.tok.line;
        try self.advance();
        const hname = try self.name("host name");
        const parent = if (try self.eat(.colon)) try self.name("parent host") else "";
        _ = try self.expect(.l_brace, "expected { after the host's name");
        var fields: std.ArrayList(ir.Field) = .empty;
        while (!try self.eat(.r_brace)) {
            if (try self.eat(.semicolon)) continue;
            const f = try self.fieldRest(.param, true);
            for (fields.items) |g| if (std.mem.eql(u8, g.name, f.name)) return self.failf("field {s} declared twice", .{f.name});
            try fields.append(self.a, f);
        }
        const s = try self.a.create(ir.Struct);
        s.* = .{ .name = hname, .module = module_path, .host = true, .parent = parent, .fields = fields.items, .file = self.file, .line = line };
        return s;
    }

    /// `enum Name { a, b "Label", c = 11 "Label", }` (a trailing comma is fine).
    fn enumDecl(self: *Parser, module_path: []const u8) Error!*const ir.Enum {
        const line = self.tok.line;
        try self.advance();
        const ename = try self.name("enum name");
        _ = try self.expect(.l_brace, "expected { after the enum's name");
        var values: std.ArrayList(ir.EnumValue) = .empty;
        while (self.tok.tag != .r_brace) {
            var v: ir.EnumValue = .{ .name = try self.name("enum value") };
            for (values.items) |x| if (std.mem.eql(u8, x.name, v.name)) return self.failf("value {s} declared twice", .{v.name});
            if (try self.eat(.equal)) {
                const neg = try self.eat(.minus);
                const t = try self.expect(.int, "expected a number");
                const n = std.fmt.parseInt(i32, t.text, 10) catch return self.fail("integer too large");
                v.number = if (neg) -n else n;
            }
            if (self.tok.tag == .string) {
                v.label = try lexer.stringValue(self.a, self.tok.text);
                try self.advance();
            }
            try values.append(self.a, v);
            if (!try self.eat(.comma)) break;
        }
        _ = try self.expect(.r_brace, "expected , or } in the enum");
        const e = try self.a.create(ir.Enum);
        e.* = .{ .name = ename, .module = module_path, .values = values.items, .file = self.file, .line = line };
        return e;
    }

    /// The rest of a type whose first word or path is `head`: `list<T>` (`T` any type).
    fn typeRest(self: *Parser, head: []const u8) Error![]const u8 {
        if (self.tok.tag != .less) return head;
        if (!std.mem.eql(u8, head, "list")) return self.failf("{s} takes no type argument (list<T> does)", .{head});
        try self.advance();
        const inner = try self.typeRest(try self.path("type"));
        _ = try self.expect(.greater, "expected > after list<T>'s type");
        return std.fmt.allocPrint(self.a, "list<{s}>", .{inner});
    }

    /// A trait's type word (`Shielded`, `fighter`) needs linking; a `Type` does not.
    fn typeRef(self: *Parser, type_name: []const u8) Allocator.Error!?*ir.TraitRef {
        if (type_name.len == 0 or typeOf(type_name) != .any or std.mem.eql(u8, type_name, "any") or std.mem.startsWith(u8, type_name, "list<")) return null;
        const r = try self.a.create(ir.TraitRef);
        r.* = .unresolved;
        return r;
    }

    /// `param [type] name [= default] ["doc"];`, `var [type] name [= default];`.
    fn field(self: *Parser) Error!ir.Field {
        const is_param = self.isWord("param");
        try self.advance();
        return self.fieldRest(if (is_param) .param else .@"var", false);
    }

    /// A field after its keyword (a struct's has none: `typed`, its type is required).
    fn fieldRest(self: *Parser, kind: @FieldType(ir.Field, "kind"), typed: bool) Error!ir.Field {
        const line = self.tok.line;
        const is_param = kind == .param;
        var type_name: []const u8 = "";
        var fname = try self.path("field name");
        if (self.tok.tag == .less) {
            type_name = try self.typeRest(fname);
            fname = try self.name("field name");
        } else if (self.tok.tag == .word) {
            type_name = fname;
            fname = try self.name("field name");
        } else if (typed) return self.fail("expected the field's type and name") else if (std.mem.indexOf(u8, fname, "::") != null) return self.fail("expected field name");
        const default = if (try self.eat(.equal)) try self.expr() else null;
        var doc: []const u8 = "";
        if (is_param and self.tok.tag == .string) {
            doc = try lexer.stringValue(self.a, self.tok.text);
            try self.advance();
        }
        _ = try self.expect(.semicolon, "expected ; after the field");
        return .{ .kind = kind, .name = fname, .id = try object.intern(fname), .type_name = type_name, .type = typeOf(type_name), .default = default, .doc = doc, .line = line, .resolved = try self.typeRef(type_name) };
    }

    /// A data block starts here: `kind name` or `kind "name"`.
    fn atBlock(self: *Parser) Error!bool {
        if (self.tok.tag != .word or isKeyword(self.tok.text)) return false;
        const nx = try self.peek();
        return nx.tag == .word or nx.tag == .string;
    }

    /// `kind name[: archetype] { field = value; attach Comp(p = v); kind name { … } }`;
    /// a scene's or dialog's commands (`WALKTO(@Sullivan, "p1");`) too.
    fn entity(self: *Parser) Error!ir.Entity {
        const line = self.tok.line;
        const start = self.tok.start;
        const kind = try self.name("kind");
        const ename = if (self.tok.tag == .string) blk: {
            const v = try lexer.stringValue(self.a, self.tok.text);
            try self.advance();
            break :blk v;
        } else try self.name("name");
        const base = if (try self.eat(.colon)) try self.path("archetype") else "";
        _ = try self.expect(.l_brace, "expected {");
        // `injects T1, T2;`: the traits its own code implements (its own component's).
        var traits: std.ArrayList([]const u8) = .empty;
        var fields: std.ArrayList(ir.Named) = .empty;
        var vars: std.ArrayList(ir.Field) = .empty;
        var attach: std.ArrayList(ir.Attach) = .empty;
        var children: std.ArrayList(ir.Entity) = .empty;
        var cmds: std.ArrayList(*const ir.Expr) = .empty;
        // Its own code: `fn`s, its component (made when the first comes).
        var own: ?*ir.Component = null;
        var own_fns: std.ArrayList(*const ir.Fn) = .empty;
        // A command's statement (`Line(…);`): its span is the row's (the editor edits a row in place).
        var cmd: ?*ir.Expr = null;
        const outer = self.in_data;
        self.in_data = true;
        defer self.in_data = outer;
        while (self.tok.tag != .r_brace) {
            if (try self.eat(.semicolon)) continue;
            const l = self.tok.line;
            const at = self.tok.start;
            if (self.isWord("var")) {
                try vars.append(self.a, try self.field());
                continue;
            }
            if (try self.eatWord("injects")) {
                while (true) {
                    try traits.append(self.a, try self.path("trait"));
                    if (!try self.eat(.comma)) break;
                }
            } else if (self.isWord("import") and (try self.peek()).tag == .string) {
                // `import "03_museum/card";`: a level's own object (no path of a module).
                try self.advance();
                for (fields.items) |f| if (std.mem.eql(u8, f.name, "same_as")) return self.fail("a block imports one block (import … once)");
                const v = try self.a.create(ir.Expr);
                v.* = .{ .line = l, .kind = .{ .lit = .{ .string = try lexer.stringValue(self.a, self.tok.text) } } };
                try self.advance();
                try fields.append(self.a, .{ .name = "same_as", .value = v });
            } else if (self.isWord("import") and (try self.peek()).tag == .word) {
                // `import characters::c_nato;`: the block it is the same object as (field
                // `same_as`, the IR's name: its number, texts, rules rows and the values it has not).
                try self.advance();
                for (fields.items) |f| if (std.mem.eql(u8, f.name, "same_as")) return self.fail("a block imports one block (import … once)");
                const p = try self.path("block");
                // `characters::medusa<fighter>`: which block of the path (several kinds have it).
                const w = if (try self.eat(.less)) blk: {
                    const k = try self.name("block kind");
                    _ = try self.expect(.greater, "expected > after the block kind");
                    break :blk try std.fmt.allocPrint(self.a, "{s}<{s}>", .{ p, k });
                } else p;
                const v = try self.a.create(ir.Expr);
                v.* = .{ .line = l, .kind = .{ .word = w } };
                try fields.append(self.a, .{ .name = "same_as", .value = v });
            } else if (try self.eatWord("attach")) {
                const comp = try self.path("component");
                if (self.tok.tag != .l_paren) return self.fail("expected ( after the component");
                const args = try self.callArgs();
                if (args.args.len > 0) return self.fail("attach takes named parameters (p = value)");
                try attach.append(self.a, .{ .component = comp, .params = args.named, .line = l });
            } else if (self.isWord("fn")) {
                const c = own orelse blk: {
                    const x = try self.a.create(ir.Component);
                    own = x;
                    break :blk x;
                };
                // Code, not data: its words are names, `x = 1;` assigns.
                const was = .{ self.in_component, self.in_data };
                self.in_component = true;
                self.in_data = false;
                defer {
                    self.in_component = was[0];
                    self.in_data = was[1];
                }
                const m = try self.function(c);
                for (own_fns.items) |g| if (std.mem.eql(u8, g.name, m.name)) return self.failf("method {s} defined twice", .{m.name});
                try own_fns.append(self.a, m);
                continue;
            } else if (try self.atBlock()) {
                try children.append(self.a, try self.entity());
                continue;
            } else if (self.tok.tag == .word and (try self.peek()).tag == .equal) {
                const f = self.tok.text;
                if (std.mem.eql(u8, f, "same_as")) return self.fail("write import: import characters::c_nato; import \"03_museum/card\";");
                try self.advance();
                try self.advance();
                try fields.append(self.a, .{ .name = f, .value = try self.expr() });
            } else if (self.tok.tag == .word and ((try self.peek()).tag == .l_paren or (try self.peek()).tag == .colon_colon)) {
                if (!std.mem.eql(u8, kind, "scene") and !std.mem.eql(u8, kind, "dialog")) return self.fail("commands are in scene and dialog blocks only");
                const e = try self.a.create(ir.Expr);
                e.* = (try self.expr()).*;
                if (e.kind != .call) return self.fail("expected a command");
                try cmds.append(self.a, e);
                cmd = e;
            } else return self.fail("expected a field, attach, a block or }");
            const semi = try self.expect(.semicolon, "expected ;");
            // The statement's bytes (the OG writer edits a field or an attach in place).
            const st: ir.Span = .{ .start = at, .end = semi.start + 1 };
            if (attach.items.len > 0 and attach.items[attach.items.len - 1].span.end == 0) attach.items[attach.items.len - 1].span = st;
            if (fields.items.len > 0 and fields.items[fields.items.len - 1].span.end == 0) fields.items[fields.items.len - 1].span = st;
            if (cmd) |c| c.span = st;
            cmd = null;
        }
        const end = self.tok.start + 1;
        try self.advance();
        // Its traits without code of its own: its own component all the same (their defaults).
        if (own == null and traits.items.len > 0) own = try self.a.create(ir.Component);
        if (own) |c| {
            // For its kind's host (a hero's code is a fighter's).
            const host = try self.a.dupe([]const u8, &.{if (std.mem.eql(u8, kind, "hero")) "fighter" else kind});
            c.* = .{ .name = ename, .module = self.module_path, .hosts = host, .traits = traits.items, .fields = &.{}, .methods = own_fns.items, .line = line, .span = .{ .start = start, .end = end }, .own = true };
            try self.own.append(self.a, c);
        }
        return .{ .kind = kind, .name = ename, .base = base, .fields = fields.items, .vars = vars.items, .attach = attach.items, .children = children.items, .rows = cmds.items, .own = own, .line = line, .span = .{ .start = start, .end = end } };
    }

    fn function(self: *Parser, comp: ?*const ir.Component) Error!*const ir.Fn {
        const line = self.tok.line;
        const start = self.tok.start;
        try self.advance();
        const fname = try self.name("function name");
        _ = try self.expect(.l_paren, "expected ( after the function name");
        var fs: FnState = .{};
        const outer = self.fs;
        self.fs = &fs;
        defer self.fs = outer;
        var params: std.ArrayList(ir.Param) = .empty;
        // A built-in method (engine.ogs): its parameters' meanings, when it is called.
        const ef = self.engine_fn;
        self.engine_fn = null;
        var param_docs: std.ArrayList(ir.Doc) = .empty;
        if (self.tok.tag != .r_paren) while (true) {
            const pname = try self.name("parameter name");
            for (fs.names.items) |n| if (std.mem.eql(u8, n, pname)) return self.failf("parameter {s} twice", .{pname});
            const type_word = if (try self.eat(.colon)) try self.typeRest(try self.path("parameter type")) else "";
            const t = typeOf(type_word);
            const default = if (try self.eat(.equal)) try self.expr() else null;
            const r = try self.typeRef(type_word);
            try params.append(self.a, .{ .slot = try self.declare(pname), .type = t, .name = pname, .default = default, .type_name = if (r != null) type_word else "", .resolved = r });
            if (ef != null and self.tok.tag == .string) try param_docs.append(self.a, try self.engineDoc("parameter"));
            if (!try self.eat(.comma)) break;
        };
        _ = try self.expect(.r_paren, "expected )");
        if (ef) |e| {
            if (param_docs.items.len > 0 and param_docs.items.len != params.items.len) return self.fail("every parameter has its meaning, or none");
            e.param_docs = param_docs.items;
            if (self.tok.tag == .string) e.when = try self.engineDoc("method");
            if (try self.eatWord("default")) e.default = try self.engineDoc("default");
        }
        // In a trait, `fn f(a);`: a required method, no body.
        self.declared_only = self.in_trait and self.tok.tag == .semicolon;
        const open = self.tok.start;
        const stmts = if (self.declared_only) blk: {
            try self.advance();
            break :blk &.{};
        } else try self.blockStmts();
        const f = try self.a.create(ir.Fn);
        f.* = .{ .name = fname, .file = self.file, .line = line, .params = params.items, .slots = @intCast(fs.names.items.len), .body = stmts, .span = .{ .start = start, .end = self.prev_end }, .open = open, .names = fs.names.items, .component = comp, .ogs = true };
        return f;
    }

    // ---------------------------------------------------------------- statements

    fn declare(self: *Parser, n: []const u8) Error!u16 {
        const fs = self.fs.?;
        if (self.local(n)) |s| return s;
        if (fs.names.items.len == std.math.maxInt(u16)) return self.fail("too many locals");
        try fs.names.append(self.a, n);
        return @intCast(fs.names.items.len - 1);
    }

    fn local(self: *const Parser, n: []const u8) ?u16 {
        const fs = self.fs orelse return null;
        for (fs.names.items, 0..) |x, i| if (std.mem.eql(u8, x, n)) return @intCast(i);
        return null;
    }

    fn blockStmts(self: *Parser) Error![]const ir.Stmt {
        _ = try self.expect(.l_brace, "expected {");
        var out: std.ArrayList(ir.Stmt) = .empty;
        while (!try self.eat(.r_brace)) {
            if (self.tok.tag == .eof) return self.fail("expected }");
            try self.stmt(&out);
        }
        return out.items;
    }

    /// The body of `if`, `while`, `for`: a block or one statement.
    fn body(self: *Parser) Error![]const ir.Stmt {
        if (self.tok.tag == .l_brace) return self.blockStmts();
        var out: std.ArrayList(ir.Stmt) = .empty;
        try self.stmt(&out);
        return out.items;
    }

    fn stmt(self: *Parser, out: *std.ArrayList(ir.Stmt)) Error!void {
        const line = self.tok.line;
        if (try self.eat(.semicolon)) return;
        if (self.tok.tag == .l_brace) return out.appendSlice(self.a, try self.blockStmts());
        if (try self.eatWord("var")) {
            var type_name: []const u8 = "";
            var n = try self.name("variable name");
            if (self.tok.tag == .word) {
                type_name = n;
                n = try self.name("variable name");
            }
            const t = typeOf(type_name);
            const slot = try self.declare(n);
            try self.push(out, line, .{ .local = .{ .slot = slot, .type = t } });
            if (try self.eat(.equal)) try self.push(out, line, .{ .assign = .{ .target = .{ .local = slot }, .value = try self.expr() } });
            _ = try self.expect(.semicolon, "expected ; after the variable");
            return;
        }
        if (try self.eatWord("if")) {
            _ = try self.expect(.l_paren, "expected ( after if");
            const c = try self.expr();
            _ = try self.expect(.r_paren, "expected )");
            const then = try self.body();
            const els: []const ir.Stmt = if (try self.eatWord("else")) try self.body() else &.{};
            return self.push(out, line, .{ .@"if" = .{ .cond = c, .then = then, .@"else" = els } });
        }
        if (try self.eatWord("while")) {
            _ = try self.expect(.l_paren, "expected ( after while");
            const c = try self.expr();
            _ = try self.expect(.r_paren, "expected )");
            return self.push(out, line, .{ .@"while" = .{ .cond = c, .body = try self.body() } });
        }
        if (try self.eatWord("for")) {
            const paren = try self.eat(.l_paren);
            const n = try self.name("loop variable");
            if (!try self.eatWord("in")) return self.fail("expected in");
            const iter = try self.expr();
            const to = if (try self.eat(.dot_dot)) try self.expr() else null;
            if (paren) _ = try self.expect(.r_paren, "expected )");
            const slot = try self.declare(n);
            return self.push(out, line, .{ .for_in = .{ .slot = slot, .iter = iter, .to = to, .body = try self.body() } });
        }
        if (try self.eatWord("break")) {
            _ = try self.expect(.semicolon, "expected ;");
            return self.push(out, line, .@"break");
        }
        if (try self.eatWord("continue")) {
            _ = try self.expect(.semicolon, "expected ;");
            return self.push(out, line, .@"continue");
        }
        if (try self.eatWord("return")) {
            const v = if (self.tok.tag == .semicolon) try self.node(line, .{ .lit = .nil }) else try self.expr();
            _ = try self.expect(.semicolon, "expected ; after return");
            return self.push(out, line, .{ .@"return" = v });
        }
        if (self.isWord("classic") and try self.classicFail(out)) return;
        const e = try self.expr();
        const op: ?ir.AssignOp = switch (self.tok.tag) {
            .equal => .set,
            .plus_equal => .add,
            .minus_equal => .sub,
            else => null,
        };
        if (op) |o| {
            try self.advance();
            const target: ir.Target = switch (e.kind) {
                .local => |s| .{ .local = s },
                .field => |f| .{ .field = f },
                .member => |m| .{ .member = m },
                .name => |n| .{ .name = n },
                .index => return self.fail("lists and maps are read-only (v1)"),
                else => return self.fail("cannot assign to this"),
            };
            try self.push(out, line, .{ .assign = .{ .target = target, .value = try self.expr(), .op = o } });
        } else try self.push(out, line, .{ .expr = e });
        _ = try self.expect(.semicolon, "expected ;");
    }

    /// `classic::fail("Error", "file", line, "message");`: a Classic include that failed.
    fn classicFail(self: *Parser, out: *std.ArrayList(ir.Stmt)) Error!bool {
        const saved = .{ self.lx, self.tok, self.peeked };
        try self.advance();
        if (self.tok.tag != .colon_colon or (try self.peek()).tag != .word or !std.mem.eql(u8, (try self.peek()).text, "fail")) {
            self.lx, self.tok, self.peeked = saved;
            return false;
        }
        const line = self.tok.line;
        try self.advance();
        try self.advance();
        const args = try self.callArgs();
        const x = args.args;
        if (x.len != 4 or !isLit(x[0], .string) or !isLit(x[1], .string) or !isLit(x[2], .int) or !isLit(x[3], .string) or x[2].kind.lit.int < 0)
            return self.fail("classic::fail(error, file, line, message)");
        const f = try self.a.create(ir.Fail);
        f.* = .{ .err = errorNamed(x[0].kind.lit.string) orelse return self.fail("unknown error"), .file = x[1].kind.lit.string, .line = @intCast(x[2].kind.lit.int), .message = x[3].kind.lit.string };
        _ = try self.expect(.semicolon, "expected ;");
        try out.append(self.a, .{ .file = self.file, .line = line, .kind = .{ .fail = f } });
        return true;
    }

    fn isLit(e: *const ir.Expr, tag: std.meta.Tag(@import("../value.zig").Value)) bool {
        return e.kind == .lit and e.kind.lit == tag;
    }

    fn errorNamed(n: []const u8) ?anyerror {
        const E = error{ ScriptNotFound, IncludeCycle } || @import("../parser.zig").Error;
        inline for (@typeInfo(E).error_set.error_names.?) |e| if (std.mem.eql(u8, e, n)) return @field(anyerror, e);
        return null;
    }

    // ---------------------------------------------------------------- expressions

    pub fn expr(self: *Parser) Error!*const ir.Expr {
        return self.logic(.@"or");
    }

    fn logic(self: *Parser, op: ir.LogicOp) Error!*const ir.Expr {
        var lhs = if (op == .@"or") try self.logic(.@"and") else try self.binary(0);
        while (if (op == .@"or") self.tok.tag == .pipe_pipe or self.isWord("or") else self.tok.tag == .amp_amp or self.isWord("and")) {
            const line = self.tok.line;
            try self.advance();
            const rhs = if (op == .@"or") try self.logic(.@"and") else try self.binary(0);
            lhs = try self.node(line, .{ .logic = .{ .op = op, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    /// Levels: `== !=`, `< <= > >=`, `+ -`, `* / %`; left-associative.
    const levels = [_][]const struct { Tag, ir.BinaryOp }{
        &.{ .{ .equal_equal, .eq }, .{ .bang_equal, .ne } },
        &.{ .{ .less, .lt }, .{ .less_equal, .le }, .{ .greater, .gt }, .{ .greater_equal, .ge } },
        &.{ .{ .plus, .add }, .{ .minus, .sub } },
        &.{ .{ .star, .mul }, .{ .slash, .div }, .{ .percent, .mod } },
    };

    fn binary(self: *Parser, level: usize) Error!*const ir.Expr {
        if (level == levels.len) return self.unary();
        var lhs = try self.binary(level + 1);
        outer: while (true) {
            for (levels[level]) |pair| if (self.tok.tag == pair[0]) {
                const line = self.tok.line;
                try self.advance();
                const rhs = try self.binary(level + 1);
                lhs = try self.node(line, .{ .binary = .{ .op = pair[1], .lhs = lhs, .rhs = rhs } });
                continue :outer;
            };
            // `x is T`: as tight as a comparison.
            if (level == 1 and self.isWord("is")) {
                const line = self.tok.line;
                try self.advance();
                lhs = try self.traitOp(line, .is, lhs, try self.path("trait"));
                continue :outer;
            }
            return lhs;
        }
    }

    fn unary(self: *Parser) Error!*const ir.Expr {
        const line = self.tok.line;
        if (try self.eat(.minus)) return self.node(line, .{ .unary = .{ .op = .neg, .operand = try self.unary() } });
        if (try self.eat(.bang) or try self.eatWord("not")) return self.node(line, .{ .unary = .{ .op = .not, .operand = try self.unary() } });
        return self.postfix(try self.primary());
    }

    fn postfix(self: *Parser, start: *const ir.Expr) Error!*const ir.Expr {
        var e = start;
        while (true) {
            const line = self.tok.line;
            if (try self.eat(.dot)) {
                const n = if (self.tok.tag == .word) self.tok.text else return self.fail("expected a field after .");
                try self.advance();
                const id = try object.intern(n);
                if (std.meta.stringToEnum(ir.TraitOpKind, n)) |op| if (op != .is and self.tok.tag == .l_paren) if (try self.traitArg()) |t| {
                    e = try self.traitOp(line, op, e, t);
                    continue;
                };
                if (self.tok.tag == .l_paren) {
                    const args = try self.callArgs();
                    const m = try self.a.create(ir.Method);
                    m.* = .{ .obj = e, .id = id, .text = n, .args = args.args, .named = args.named };
                    e = try self.node(line, .{ .method = m });
                } else e = try self.node(line, .{ .member = .{ .obj = e, .id = id, .text = n } });
            } else if (try self.eat(.l_bracket)) {
                const k = try self.expr();
                _ = try self.expect(.r_bracket, "expected ]");
                e = try self.node(line, .{ .index = .{ .obj = e, .key = k } });
            } else return e;
        }
    }

    fn traitOp(self: *Parser, line: u32, op: ir.TraitOpKind, obj: *const ir.Expr, n: []const u8) Error!*const ir.Expr {
        const r = try self.a.create(ir.TraitRef);
        r.* = .unresolved;
        return self.node(line, .{ .trait_op = .{ .op = op, .obj = obj, .name = n, .resolved = r } });
    }

    /// `(T)` of `x.as(T)`, `x.get(T)`, `x.all(T)`: a capitalised name or path
    /// (`foundation::Hero`) that is no local; else (null) the call is an object's
    /// function's (`x.get(key)`).
    fn traitArg(self: *Parser) Error!?[]const u8 {
        const saved = .{ self.lx, self.tok, self.peeked };
        try self.advance();
        if (self.tok.tag == .word and !isKeyword(self.tok.text) and self.local(self.tok.text) == null) {
            const t = try self.path("trait");
            const last = t[if (std.mem.lastIndexOf(u8, t, "::")) |k| k + 2 else 0..];
            if (std.ascii.isUpper(last[0]) and try self.eat(.r_paren)) return t;
        }
        self.lx, self.tok, self.peeked = saved;
        return null;
    }

    const Args = struct { args: []const *const ir.Expr, named: []const ir.Named };

    /// `(a, b, name = v, name: v)`: positional arguments first.
    fn callArgs(self: *Parser) Error!Args {
        _ = try self.expect(.l_paren, "expected (");
        var args: std.ArrayList(*const ir.Expr) = .empty;
        var named: std.ArrayList(ir.Named) = .empty;
        while (self.tok.tag != .r_paren) {
            const nx = try self.peek();
            if (self.tok.tag == .word and (nx.tag == .equal or nx.tag == .colon)) {
                // The same name twice is the linker's (and a rules row check's) to report.
                const n = self.tok.text;
                try self.advance();
                try self.advance();
                try named.append(self.a, .{ .name = n, .value = try self.expr() });
            } else {
                if (named.items.len > 0) return self.fail("a positional argument after a named one");
                try args.append(self.a, try self.expr());
            }
            if (!try self.eat(.comma)) break;
        }
        _ = try self.expect(.r_paren, "expected )");
        return .{ .args = args.items, .named = named.items };
    }

    fn call(self: *Parser, line: u32, text: []const u8, super: bool) Error!*const ir.Expr {
        const args = try self.callArgs();
        const target = try self.a.create(ir.Callee);
        target.* = .unresolved;
        return self.node(line, .{ .call = .{ .id = try object.intern(text), .text = text, .args = args.args, .named = args.named, .target = target, .super = super } });
    }

    fn primary(self: *Parser) Error!*const ir.Expr {
        const t = self.tok;
        const line = t.line;
        switch (t.tag) {
            .int => {
                try self.advance();
                return self.node(line, .{ .lit = .{ .int = std.fmt.parseInt(i32, t.text, 10) catch return self.fail("integer too large") } });
            },
            .float => {
                try self.advance();
                return self.node(line, .{ .lit = .{ .float = std.fmt.parseFloat(f32, t.text) catch return self.fail("bad number") } });
            },
            .string => {
                try self.advance();
                return self.node(line, .{ .lit = .{ .string = try lexer.stringValue(self.a, t.text) } });
            },
            .l_paren => {
                try self.advance();
                const e = try self.expr();
                _ = try self.expect(.r_paren, "expected )");
                return e;
            },
            .l_bracket => {
                try self.advance();
                var list: std.ArrayList(*const ir.Expr) = .empty;
                while (self.tok.tag != .r_bracket) {
                    try list.append(self.a, try self.expr());
                    if (!try self.eat(.comma)) break;
                }
                _ = try self.expect(.r_bracket, "expected ]");
                return self.node(line, .{ .list = list.items });
            },
            .l_brace => {
                try self.advance();
                var keys: std.ArrayList(*const ir.Expr) = .empty;
                var values: std.ArrayList(*const ir.Expr) = .empty;
                while (self.tok.tag != .r_brace) {
                    try keys.append(self.a, try self.expr());
                    _ = try self.expect(.colon, "expected : in the map");
                    try values.append(self.a, try self.expr());
                    if (!try self.eat(.comma)) break;
                }
                _ = try self.expect(.r_brace, "expected }");
                return self.node(line, .{ .map = .{ .keys = keys.items, .values = values.items } });
            },
            .at => {
                try self.advance();
                // `@"01pr_garcia1"`: a name that is no identifier; `@hero::selected`: a path
                // (a scene's selected hero, core/scene.zig `placeholders`).
                var n = switch (self.tok.tag) {
                    .word => self.tok.text,
                    .string => try lexer.stringValue(self.a, self.tok.text),
                    else => return self.fail("expected a name after @"),
                };
                const word = self.tok.tag == .word;
                try self.advance();
                if (word) while (try self.eat(.colon_colon)) {
                    n = try std.fmt.allocPrint(self.a, "{s}::{s}", .{ n, try self.name("a name") });
                };
                return self.node(line, .{ .ref = n });
            },
            .tilde => {
                try self.advance();
                const k = if (self.tok.tag == .word and self.tok.text.len == 1) ir.Sigil.of(self.tok.text[0]) else null;
                const sigil = k orelse return self.failf("unknown sigil ~{s}", .{if (self.tok.tag == .word) self.tok.text else ""});
                try self.advance();
                if (self.tok.tag != .string) return self.fail("expected a string after the sigil");
                const e = try self.a.create(ir.Expr);
                e.* = .{ .line = line, .kind = .{ .lit = .{ .string = try lexer.stringValue(self.a, self.tok.text) } }, .sigil = sigil };
                try self.advance();
                return e;
            },
            .word => {},
            else => return self.fail("expected a value"),
        }
        const w = t.text;
        const nx = try self.peek();
        // Rows name a union's tag `self(…)`, `attach(…)`: any word before `(` is a call.
        if (nx.tag == .l_paren) {
            try self.advance();
            return self.call(line, w, false);
        }
        if (nx.tag == .colon_colon and std.mem.eql(u8, w, "classic")) {
            try self.advance();
            return self.classic(line);
        }
        if (nx.tag == .colon_colon) {
            const p = try self.path("function");
            if (self.tok.tag == .l_paren) return self.call(line, p, false);
            // Data: a block's path or an enum's value; code: an enum's value (`Side::enemy`).
            return self.node(line, .{ .word = p });
        }
        try self.advance();
        if (std.mem.eql(u8, w, "nil")) return self.node(line, .{ .lit = .nil });
        if (std.mem.eql(u8, w, "true")) return self.node(line, .{ .lit = .{ .bool = true } });
        if (std.mem.eql(u8, w, "false")) return self.node(line, .{ .lit = .{ .bool = false } });
        if (self.in_data and !isKeyword(w)) return self.node(line, .{ .word = w });
        // `super.f(…)`: the default body `f` overrides (`ogs/link.zig`).
        if (std.mem.eql(u8, w, "super")) {
            _ = try self.expect(.dot, "expected . after super");
            const n = try self.name("method");
            if (self.tok.tag != .l_paren) return self.fail("expected ( after super's method");
            return self.call(line, n, true);
        }
        if (std.mem.eql(u8, w, "host") or std.mem.eql(u8, w, "self")) {
            if (!self.in_component and !(self.hosted and w[0] == 'h')) return self.failf("{s} outside a component", .{w});
            return self.node(line, if (w[0] == 'h') .host else .self);
        }
        if (isKeyword(w)) return self.failf("unexpected {s}", .{w});
        if (self.local(w)) |s| return self.node(line, .{ .local = s });
        if (self.in_component) return self.node(line, .{ .field = .{ .id = try object.intern(w), .text = w } });
        return self.failf("unknown name {s}", .{w});
    }

    /// `classic::<quirk>(…)`, `classic::name("x")`, `classic::maybe("x")` (the Classic
    /// importer's nodes): a closed set, the module `classic` has nothing else.
    fn classic(self: *Parser, line: u32) Error!*const ir.Expr {
        try self.advance();
        const op = if (self.tok.tag == .word) self.tok.text else return self.fail("expected classic::<name>");
        try self.advance();
        if (self.tok.tag != .l_paren) return self.failf("classic::{s} is no value", .{op});
        const args = try self.callArgs();
        if (args.named.len > 0) return self.fail("classic::* takes no named arguments");
        if (std.mem.eql(u8, op, "name") or std.mem.eql(u8, op, "maybe")) {
            if (args.args.len != 1 or !isLit(args.args[0], .string)) return self.fail("classic::name(\"x\")");
            const text = args.args[0].kind.lit.string;
            var n: ir.Name = .{ .id = try object.intern(text), .text = text, .this = std.ascii.eqlIgnoreCase(text, "this") };
            // A Classic local declared on some paths: its slot by its name in any case.
            if (op[0] == 'm') n.slot = for ((self.fs orelse return self.fail("classic::maybe outside a function")).names.items, 0..) |x, i| {
                if (std.ascii.eqlIgnoreCase(x, text)) break @intCast(i);
            } else return self.failf("classic::maybe: no local {s}", .{text});
            return self.node(line, .{ .name = n });
        }
        const x = std.meta.stringToEnum(ir.ExeOp, op) orelse return self.failf("unknown classic::{s}", .{op});
        const arity: usize = switch (x) {
            .neg, .not, .truthy => 1,
            else => 2,
        };
        if (args.args.len != arity) return self.failf("classic::{s} takes {d} arguments", .{ op, arity });
        return self.node(line, .{ .exe = .{ .op = x, .args = args.args } });
    }
};
