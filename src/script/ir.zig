//! Script IR: the resolved tree the runtime executes. Locals are slots,
//! names keep their source positions, and the exe's quirks are `exe` nodes
//! (`exe.zig`), so the plain nodes here have the semantics both languages share.
//! The Classic front end is `classic/import.zig`, the OGS one `ogs/parser.zig` (its nodes
//! and the module items are below the Classic ones; `ogs/link.zig` resolves them).
//!
//! Plain nodes: arithmetic and `< > >=` as `value.binary`; `==` by value (an int and a
//! float compare as floats, strings by content, a string and a number differ), `!=` its
//! negation, `<=` the mirror of `>=`; truth is "not 0, not 0.0, not empty"; `and`/`or`
//! short-circuit; operands left to right. Results of comparisons and logic are int 0/1
//! in Classic and `bool` in OGS (`Fn.ogs`: the runtime reads the dialect off the function).

const std = @import("std");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// Declared types (variables, parameters, schema fields): the values' (`value.Type`).
pub const Type = value_mod.Type;

/// Byte range of a node's text in its file (`Stmt.file`, `Fn.file`) for the Classic
/// exporter (`classic/export.zig`); empty for a node not read from a file.
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub fn none(self: Span) bool {
        return self.end == 0;
    }
};

pub const Fn = struct {
    name: []const u8,
    /// Lower-case file of the definition and its line.
    file: []const u8,
    line: u32,
    params: []const Param,
    /// Local slots: parameters and declarations, one per name (a redeclaration reuses it).
    slots: u16,
    body: []const Stmt,
    /// From `function` through the closing `};` (OGS: `fn` through its `}`).
    span: Span = .{},
    /// OGS: where its body's `{` is (the editor edits inside it: editor/trigger.zig).
    open: u32 = 0,
    /// Name of each slot as first declared (printing).
    names: []const []const u8 = &.{},
    /// OGS: the component of a method (null: a free function or Classic).
    component: ?*const Component = null,
    /// Read by the OGS parser: comparisons and logic give `bool`, no `return` gives nil
    /// (Classic: int 0/1 and 0, as the exe). `ogs/print.same` skips it: printed Classic
    /// code read back is the same IR.
    ogs: bool = false,
};

pub const Param = struct {
    slot: u16,
    type: Type,
    name: []const u8 = "",
    /// OGS: evaluated in the callee when the call leaves the parameter out.
    default: ?*const Expr = null,
    /// OGS: the type as written when it is no `Type` (`x: Shielded`, `x: fighter`).
    type_name: []const u8 = "",
    /// OGS: the trait `type_name` names (`ogs/link.zig` fills it): a value must be `is` it.
    resolved: ?*TraitRef = null,
};

pub const Stmt = struct {
    /// Lower-case file the statement comes from (an included one keeps its own) and line.
    file: []const u8,
    line: u32,
    kind: Kind,
    /// The statement's text in `file`, its `;` included.
    span: Span = .{},
    /// A statement an `#include` brought: that directive in the file holding the statement
    /// list (the enclosing `if`'s file, else `Fn.file`); the outermost one if nested.
    via: Span = .{},

    pub const Kind = union(enum) {
        expr: *const Expr,
        /// Declaration: the slot gets the type and its initial value.
        local: Local,
        assign: Assign,
        @"if": If,
        @"return": *const Expr,
        // OGS:
        @"while": While,
        /// `for x in list` (items), `for i in a..b` (a to b - 1).
        for_in: ForIn,
        @"break",
        @"continue",
        /// An include that failed to load: raises `err` when reached (with the parse
        /// diagnostic for a parse error), where the exe's text insertion would have failed.
        fail: *const Fail,
    };
};

const Local = struct { slot: u16, type: Type };

const If = struct { cond: *const Expr, then: []const Stmt, @"else": []const Stmt };
const While = struct { cond: *const Expr, body: []const Stmt };
pub const ForIn = struct { slot: u16, iter: *const Expr, to: ?*const Expr = null, body: []const Stmt };

pub const Assign = struct {
    target: Target,
    value: *const Expr,
    /// OGS `+=`, `-=`: the target read once.
    op: AssignOp = .set,
};

pub const AssignOp = enum { set, add, sub };

pub const Target = union(enum) {
    /// A slot declared on every path to here.
    local: u16,
    /// Resolved at run time (see `Name`); an undeclared target skips the assignment.
    name: Name,
    /// OGS: see `Expr.Kind.field`, `member`.
    field: Ident,
    member: Member,
};

/// A Classic name the importer cannot bind statically: the slot
/// if its declaration ran, else the object variable, else `this` (own object name), else
/// the name of a scene object, else 0. Object variables are not typed statically before
/// the host schema: their values can differ from the declared type
/// (`world/snapshot.zig` restores copied values as they are).
pub const Name = struct {
    id: u32,
    text: []const u8,
    /// A slot declared on some paths only.
    slot: ?u16 = null,
    this: bool = false,
};

pub const Fail = struct {
    /// `error.ScriptNotFound`, `error.IncludeCycle` or a parse error.
    err: anyerror,
    file: []const u8,
    /// Where the parse failed and why.
    line: u32 = 0,
    message: []const u8 = "",
};

pub const Expr = struct {
    line: u32,
    kind: Kind,
    /// In the file of its statement; a node the importer adds (`classic::truthy` around a
    /// condition) has its operand's.
    span: Span = .{},
    /// OGS: a string literal written with a sigil (`~l"01_port"`); its value is the plain
    /// string, the sigil is checked when the program links (`ogs/link.zig`).
    sigil: Sigil = .none,

    pub const Kind = union(enum) {
        lit: Value,
        local: u16,
        name: Name,
        call: Call,
        exe: Exe,
        unary: Unary,
        binary: Binary,
        logic: Logic,
        /// A Classic assignment used as a value (the stored value).
        assign: *const Assign,
        // OGS:
        /// A name that is no local in a component's method: the component's field, else
        /// the host's variable (no host schema here).
        field: Ident,
        /// The component's host; `self`: the component instance.
        host,
        self,
        member: Member,
        index: Index,
        list: []const *const Expr,
        map: MapLit,
        /// `@name`: the world's object of that name, else nil.
        ref: []const u8,
        /// `obj.f(…)`: the object's script function `f`.
        method: *const Method,
        /// Data only (a block's field, a record's, a command's argument): a path naming a
        /// block (`characters::grandma`) or a word of the field's enum (`hand`).
        word: []const u8,
        /// `x is T`, `x.as(T)`, `x.get(T)`, `x.all(T)`.
        trait_op: TraitOp,
    };
};

/// What a sigil's string names (`~l"01_port"`: a level). The program's blocks of
/// `blocks()` kinds declare such names; the host knows the rest (`link.Env.exists`).
/// What a block's `import` names (its `same_as` word): `characters::medusa<fighter>` the
/// block of that kind at that path, `characters::c_nato` the one block there (`kind` "").
pub const Import = struct {
    path: []const u8,
    kind: []const u8 = "",

    pub fn of(word: []const u8) Import {
        if (word.len > 2 and word[word.len - 1] == '>') if (std.mem.lastIndexOfScalar(u8, word, '<')) |k|
            return .{ .path = word[0..k], .kind = word[k + 1 .. word.len - 1] };
        return .{ .path = word };
    }
};

pub const Sigil = enum {
    none,
    level,
    scene,
    dialog,
    sound,
    asset,
    text,
    character,
    item,
    weapon,
    /// A look (`look grandma`): a fighter's model and animations (`look = looks::grandma`).
    look,

    /// The sigils' letters, in the enum's order (`-`: none).
    const letters = "-ledsatciwk";

    pub fn of(letter_: u8) ?Sigil {
        const i = std.mem.indexOfScalar(u8, letters[1..], letter_) orelse return null;
        return @fromBackingInt(@intCast(i + 1));
    }

    pub fn letter(self: Sigil) u8 {
        return letters[@backingInt(self)];
    }

    /// A builtin's parameter type naming a kind (`int(level)`, `editor/api.zig`).
    pub fn ofType(type_word: []const u8) ?Sigil {
        const k = std.meta.stringToEnum(Sigil, type_word) orelse return null;
        return if (k == .none) null else k;
    }

    /// Block kinds that declare a name of this kind.
    pub fn blocks(self: Sigil) []const []const u8 {
        return switch (self) {
            .level => &.{ "level", "battle" },
            .scene => &.{"scene"},
            .dialog => &.{"dialog"},
            // A location's hero (`hero bt`) is a character too.
            .character => &.{ "fighter", "hero" },
            .item => &.{"item"},
            .weapon => &.{"weapon"},
            .look => &.{"look"},
            .none, .sound, .asset, .text => &.{},
        };
    }
};

/// Classic call by name: the object's own script function, else the builtin, else 0
/// (counted in `missing_builtins`). Over 32 arguments it is 0 without evaluating them.
/// OGS: `target` (filled by `ogs/link.zig`) says what it calls; `named` after `args`.
pub const Call = struct {
    id: u32,
    text: []const u8,
    args: []const *const Expr,
    named: []const Named = &.{},
    target: ?*Callee = null,
    /// OGS `super.f(…)`.
    super: bool = false,
};

/// What an OGS call resolved to (`ogs/link.zig`): a method of the caller's component
/// or a free function (by namespace), else a builtin.
pub const Callee = union(enum) {
    unresolved,
    func: *const Fn,
    builtin: BuiltinCall,
    /// In a trait's default body, a method of the trait or a supertrait: called by name
    /// on `self`, so the component's own version wins.
    virtual,
    /// `super.f(…)`, `T::f(self, …)`: a trait's default body, static.
    trait_default: TraitDefault,
    /// `Wave(turn = 3)`: a value of a struct (named fields only).
    make: *const Struct,
    /// `Side::from("enemy")`: the enum's value of that name, else nil.
    enum_from: *const Enum,
};

/// `body` null: an engine method's default (nil). `trait` set (`T::f(self, …)`): the
/// first argument is the instance, checked to be `is` it when run.
const TraitDefault = struct { body: ?*const Fn, trait: ?TraitRef = null };

pub const TraitOpKind = enum { is, as, get, all };
pub const TraitOp = struct { op: TraitOpKind, obj: *const Expr, name: []const u8, resolved: *TraitRef };

/// A trait as linking found it: the program's or the engine's (by name); `native`: a
/// native component's name (`host.get(Guard)`: that component, core/natives.zig).
pub const TraitRef = union(enum) {
    unresolved,
    script: *const Trait,
    engine: []const u8,
    native: []const u8,

    pub fn eql(a: TraitRef, b: TraitRef) bool {
        return switch (a) {
            .unresolved => false,
            .script => |t| b == .script and b.script == t,
            .engine => |n| b == .engine and std.mem.eql(u8, b.engine, n),
            .native => |n| b == .native and std.mem.eql(u8, b.native, n),
        };
    }

    pub fn name(r: TraitRef) []const u8 {
        return switch (r) {
            .unresolved => "",
            .script => |t| t.name,
            .engine, .native => |n| n,
        };
    }
};

/// A builtin by its interned id; `slots[i]`: the position of named argument `i` (by the
/// parameter names of its signature, `Runtime.Sig`).
const BuiltinCall = struct { id: u32, slots: []const u8 = &.{} };

/// `span`: a data block's field statement (`hp = 40;`, through its `;`; the OG writer
/// edits it in place, compose/og/write.zig); empty elsewhere.
pub const Named = struct { name: []const u8, value: *const Expr, span: Span = .{} };
const Ident = struct { id: u32, text: []const u8 };
const Member = struct { obj: *const Expr, id: u32, text: []const u8 };
const Index = struct { obj: *const Expr, key: *const Expr };
const MapLit = struct { keys: []const *const Expr, values: []const *const Expr };
pub const Method = struct { obj: *const Expr, id: u32, text: []const u8, args: []const *const Expr, named: []const Named = &.{} };

/// An exe quirk (`exe.zig`): operands evaluated right to left, as the exe does.
const Exe = struct { op: ExeOp, args: []const *const Expr };

pub const ExeOp = enum {
    // The exe's binary operators (`value.binary`): `ne` adds, `le` is `ge`, `and`/`or`
    // evaluate both sides.
    add,
    sub,
    mul,
    div,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",
    /// Unary minus: a float negates, anything else is `-toInt` (a string is parsed).
    neg,
    /// `!` with the exe's truth.
    not,
    /// The exe's truth as int 0/1: a fraction truncates (`0.5` is false), a string is false.
    truthy,

    pub fn binary(op: ast.BinaryOp) ExeOp {
        return std.meta.stringToEnum(ExeOp, @tagName(op)).?;
    }
};

const UnaryOp = enum { neg, not };
const Unary = struct { op: UnaryOp, operand: *const Expr };

/// `mod`: OGS `%` (the exe has none).
pub const BinaryOp = enum { add, sub, mul, div, eq, ne, lt, le, gt, ge, mod };
const Binary = struct { op: BinaryOp, lhs: *const Expr, rhs: *const Expr };

pub const LogicOp = enum { @"and", @"or" };
const Logic = struct { op: LogicOp, lhs: *const Expr, rhs: *const Expr };

// ---------------------------------------------------------------- semantics of plain nodes

pub fn binary(op: BinaryOp, a: Value, b: Value) Value {
    return switch (op) {
        .eq => .{ .int = @intFromBool(equal(a, b)) },
        .ne => .{ .int = @intFromBool(!equal(a, b)) },
        .le => value_mod.binary(.ge, b, a),
        // As C (and `/`): truncated; an int by 0 gives 0.
        .mod => if (a == .float or b == .float) .{ .float = @rem(a.toFloat(), b.toFloat()) } else if (b.toInt() == 0 or b.toInt() == -1) .zero else .{ .int = @rem(a.toInt(), b.toInt()) },
        inline .add, .sub, .mul, .div, .lt, .gt, .ge => |o| value_mod.binary(@field(ast.BinaryOp, @tagName(o)), a, b),
    };
}

fn equal(a: Value, b: Value) bool {
    if (numeric(a) and numeric(b)) return if (a == .int and b == .int) a.int == b.int else a.toFloat() == b.toFloat();
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |s| std.mem.eql(u8, s, b.string),
        .nil => true,
        .bool => |x| x == b.bool,
        .ref => |o| o == b.ref,
        .list => |l| l.ptr == b.list.ptr and l.len == b.list.len,
        .map => |m| m == b.map,
        .int, .float => unreachable,
    };
}

pub fn numeric(v: Value) bool {
    return v == .int or v == .float;
}

/// Numeric minus; anything else gives 0 (the OGS runtime faults on it first).
pub fn neg(v: Value) Value {
    return switch (v) {
        .int => |i| .{ .int = -%i },
        .float => |f| .{ .float = -f },
        else => .zero,
    };
}

// ---------------------------------------------------------------- OGS module items

/// One `module a::b { … }` block of an OGS text; the text's top level is the root
/// namespace (path ""). Items are named by namespace, never by file:
/// every text loads, `use` names namespaces.
pub const Module = struct {
    path: []const u8,
    /// Namespaces `use`d in this block, in order.
    uses: []const []const u8,
    fns: []const *const Fn,
    components: []const *const Component,
    traits: []const *const Trait = &.{},
    structs: []const *const Struct = &.{},
    enums: []const *const Enum = &.{},
    entities: []const Entity,
    /// Top-level calls: rules rows (`Resist(fighter = 125);`), data, never run.
    rows: []const *const Expr,
};

/// `component Name for fighter, item { param …; var …; fn …; }`.
pub const Component = struct {
    name: []const u8,
    /// Namespace path ("" the root).
    module: []const u8,
    /// Host kinds after `for` (`fighter`, `game`) or a role (`Hero`); empty: any host.
    hosts: []const []const u8,
    /// Traits after `:` as written (`Shielded`, `abilities::Armored`); `ogs/link.zig`
    /// builds the component's method table from them (`link.Table`).
    traits: []const []const u8 = &.{},
    /// `param`s and `var`s in declaration order.
    fields: []const Field,
    methods: []const *const Fn,
    line: u32,
    /// `component` through its `}`, and where its `{` is (the editor edits inside it).
    span: Span = .{},
    open: u32 = 0,
    /// A data block's own code (`fighter c_nato { fn OnCreate() { … } }`): the component
    /// the parser makes of its `fn`s, named as the block, attached to it first (no `attach`).
    own: bool = false,
};

/// `trait Name: Super1, Super2 { fn required(a); fn defaulted(a) { … } }`:
/// methods only; a default body is linked once, in the trait (its calls of the trait's
/// methods are `Callee.virtual`).
pub const Trait = struct {
    name: []const u8,
    module: []const u8,
    supers: []const []const u8,
    /// Namespaces its module block `use`s (its supertraits are named from there).
    uses: []const []const u8 = &.{},
    methods: []const TraitFn,
    /// `param T name = default "Label";`: every implementer has it (`link.Table.fields`).
    params: []const Field = &.{},
    file: []const u8,
    line: u32,
    /// engine.ogs (foundation/traits.ogs) only: what the engine says of it.
    engine: ?*const EngineTrait = null,
};

/// A text in English and Russian (the engine's own tables; OG Script's `"…"` is English, both halves).
pub const Doc = struct { en: []const u8 = "", ru: []const u8 = "" };

/// A built-in trait's description (foundation/traits.ogs): its kind (`role trait Hero`,
/// `mark trait Monitor`, else a host kind's: `trait Level … for level`), what it is.
pub const EngineTrait = struct {
    kind: enum { host, role, mark },
    /// The host kind written after `for` (a host kind's trait).
    host: []const u8 = "",
    doc: Doc,
};

/// A built-in method's description (`live chain fn OnHit(…) "when" default …`):
/// whether the engine calls it, how the handlers' results combine (`all`…), when it is
/// called, what the engine does with no answer, each parameter's meaning.
pub const EngineFn = struct {
    live: bool = false,
    combine: []const u8 = "all",
    when: Doc,
    default: ?Doc = null,
    param_docs: []const Doc = &.{},
};

/// `struct Name { int turn "Turn"; Side side = Side::enemy; }`: data, no methods. A value
/// is a map of its fields by name in this order (`Callee.make`; `w.turn` reads one).
pub const Struct = struct {
    name: []const u8,
    module: []const u8,
    /// `host fighter : actor { … }` (foundation/hosts.ogs, core/field_docs.zig): the fields of a
    /// data block kind's base, its parent's after `:`; no type of the program.
    host: bool = false,
    parent: []const u8 = "",
    /// Each a `param` (its type, default, label).
    fields: []const Field,
    file: []const u8,
    line: u32,

    pub fn field(s: *const Struct, n: []const u8) ?*const Field {
        for (s.fields) |*f| if (std.mem.eql(u8, f.name, n)) return f;
        return null;
    }
};

/// `enum Name { a "Label", b = 11, }`: its values. At run time a value is the string of
/// its name (`str(Side::enemy)` is "enemy", as the engine passes sides); `number` is what
/// an int field of the engine stores for it (`place = hand` → 11).
pub const Enum = struct {
    name: []const u8,
    module: []const u8,
    values: []const EnumValue,
    file: []const u8,
    line: u32,

    pub fn value(e: *const Enum, n: []const u8) ?*const EnumValue {
        for (e.values) |*v| if (std.mem.eql(u8, v.name, n)) return v;
        return null;
    }
};

pub const EnumValue = struct { name: []const u8, label: []const u8 = "", number: ?i32 = null };

/// `f`: the declaration (name, parameters) and, with `body`, the default body.
/// `native`: the engine's (only in its prelude, `engine.ogs`).
pub const TraitFn = struct { f: *const Fn, body: bool, native: bool = false, engine: ?*const EngineFn = null };

pub const Field = struct {
    kind: enum { param, @"var" },
    name: []const u8,
    /// Interned (lower-case): an instance's fields are its `Object`'s variables.
    id: u32,
    /// As written (`int`, `fighter`; "" untyped) and what a value converts to (`any`: none).
    type_name: []const u8,
    type: Type,
    default: ?*const Expr,
    /// The inspector's label (`"Percent to return"`).
    doc: []const u8,
    line: u32,
    /// The trait `type_name` names (`param Shielded ward`; `ogs/link.zig` fills it).
    resolved: ?*TraitRef = null,
};

/// A data block: `fighter grandma: characters::base { hp = 200; attach
/// Rage(below_pct = 30); weapon gun: weapons::pistol { place = hand; } }` — fields,
/// attachments, nested blocks and (scene, dialog) commands, no statements. The name is a
/// word or a string (`level "01_port"`). `ogs/link.zig` checks it against
/// `core/schema.zig`; the model reads it.
pub const Entity = struct {
    kind: []const u8,
    name: []const u8,
    /// The archetype (`characters::grandma`); "" none.
    base: []const u8 = "",
    fields: []const Named,
    attach: []const Attach,
    /// Variables of its own (`var int ponton = 1;`): the host's, beyond its schema's
    /// fields, declared with their type before its fields apply (a Classic class's
    /// variables).
    vars: []const Field = &.{},
    /// Blocks inside it, in order (a battle's fighters, a fighter's weapon).
    children: []const Entity = &.{},
    /// Its own code: `fn`s written in it, as the component `own` (Component.own).
    own: ?*const Component = null,
    /// A scene's or dialog's commands (`WALKTO(@Sullivan, "p1");`, `Line(…)`): data.
    rows: []const *const Expr = &.{},
    line: u32,
    /// From the kind through the closing `}` in its text (the OG writer rewrites only
    /// this range when the block is edited, compose/og/write.zig); empty: not read.
    span: Span = .{},
};

/// `span`: the statement `attach C(…);` through its `;` (as `Named.span`).
pub const Attach = struct { component: []const u8, params: []const Named, line: u32, span: Span = .{} };

test "plain nodes: equality by value, truth, <= mirrors >=" {
    try std.testing.expectEqual(Value{ .int = 0 }, binary(.eq, .{ .float = 1.5 }, .{ .int = 1 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.eq, .{ .float = 2 }, .{ .int = 2 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.eq, .{ .string = "a" }, .{ .string = "a" }));
    try std.testing.expectEqual(Value{ .int = 0 }, binary(.eq, .{ .string = "a" }, .{ .string = "b" }));
    try std.testing.expectEqual(Value{ .int = 0 }, binary(.eq, .{ .string = "0" }, .{ .int = 0 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.ne, .{ .int = 2 }, .{ .int = 3 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.le, .{ .int = 3 }, .{ .int = 5 }));
    try std.testing.expectEqual(Value{ .int = 0 }, binary(.le, .{ .int = 6 }, .{ .int = 5 }));
    try std.testing.expect((Value{ .float = 0.5 }).truth());
    try std.testing.expect((Value{ .string = "x" }).truth());
    try std.testing.expect(!(Value{ .string = "" }).truth());
    try std.testing.expectEqual(Value{ .int = std.math.minInt(i32) }, neg(.{ .int = std.math.minInt(i32) }));
}

/// Two trees (parse trees or IR) are the same apart from positions and the fields named
/// `skip` (the printers: Classic skips sigils; OGS also files, link results and back
/// pointers). Values compare by tag and content (objects by identity).
pub fn sameSkipping(comptime T: type, a: T, b: T, comptime skip: []const []const u8) bool {
    if (T == Value) {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .float => |x| @as(u32, @bitCast(x)) == @as(u32, @bitCast(b.float)),
            .list => |l| l.ptr == b.list.ptr and l.len == b.list.len,
            .nil => true,
            inline else => |x, tag| x == @field(b, @tagName(tag)),
        };
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.field_names) |n| {
                if (comptime position(T, n) or for (skip) |k| {
                    if (std.mem.eql(u8, n, k)) break true;
                } else false) continue;
                if (!sameSkipping(@FieldType(T, n), @field(a, n), @field(b, n), skip)) return false;
            }
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |x, tag| return sameSkipping(@TypeOf(x), x, @field(b, @tagName(tag)), skip),
            }
        },
        .pointer => |p| {
            if (p.size == .one) return sameSkipping(p.child, a.*, b.*, skip);
            if (a.len != b.len) return false;
            if (p.child == u8) return std.mem.eql(u8, a, b);
            for (a, b) |x, y| if (!sameSkipping(p.child, x, y, skip)) return false;
            return true;
        },
        .optional => |o| {
            if ((a == null) != (b == null)) return false;
            return a == null or sameSkipping(o.child, a.?, b.?, skip);
        },
        // Literals are f32 (`ast.Expr.Kind.float`).
        .float => return @as(u32, @bitCast(@as(f32, a))) == @as(u32, @bitCast(@as(f32, b))),
        .void => return true,
        else => return a == b,
    }
}

fn position(comptime T: type, comptime field: []const u8) bool {
    // `target`: OGS's link result (the parser sets it unresolved; Classic import never
    // sets it): Classic code read as OG Script compares as the same calls. `ogs`: the
    // dialect of the text it was read from; written back, it runs as Classic.
    const skip = [_][]const u8{ "line", "id", "start", "end", "src", "span", "open", "via", "target", "ogs" };
    inline for (skip) |n| if (comptime std.mem.eql(u8, n, field)) return true;
    // A statement's or function's file is where it was read; `Fail.file` is the include.
    return (T == Stmt or T == Fn) and comptime std.mem.eql(u8, field, "file");
}
