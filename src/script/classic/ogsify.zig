//! Classic code → OG Script. A class's own functions, as the
//! importer made them (`import.zig`: plain nodes where proven, `exe` quirks and run-time
//! names elsewhere), become the methods of one OGS component `for` its host kind; the
//! Classic text is never changed. The converter knows what the importer does not: the
//! class's declared variables and their types, the functions the class answers, the
//! builtins' results (`bool(…)`: a yes/no answer, `bool` in OGS). With them a quirk
//! becomes plain OGS where the value is provably the same, else it stays a `classic::` form:
//! - a variable the class declares is a field (`ponton`; `host.x` where a bare word would
//!   be a keyword or a local); `this` is `host.name`; another name stays `classic::name`;
//!   an assignment to a name the class does not declare is dropped (the exe skips it), its
//!   value kept for its effects;
//! - a call: the class's own function → its method; an inherited one without parameters,
//!   locals or `return` → its statements in place (`StartDialog()`: `DialogInit(host.name,
//!   host.name);`), else `host.f(…)`; a builtin → its OGS name (`rename.zig`),
//!   `s_stricmp(a, b) == 0` → `EqualsIgnoreCase(a, b)`, a name of the kind a parameter
//!   takes with its sigil (`level::Load(~l"01_port")`); none → its arguments for their
//!   effects, then 0;
//! - truth: an int or a yes/no answer as it is, a string is false, another value in an
//!   `if` through `var int t = x;` (the exe's: a float truncates); `==`, arithmetic and
//!   comparisons over numbers → plain operators where the order of the operands' effects
//!   cannot matter (the exe goes right first, OGS left first); a yes/no answer `== 1` /
//!   `== 0` → the answer / `!answer`; `&&`, `||` → `and`, `or`: as they are over operands
//!   without effects, else (in an `if`) both sides into locals first, right first;
//! - OGS gives `bool` where Classic gave int 1/0: such a value where Classic's int is
//!   needed (arithmetic, a comparison, an untyped argument, a string, `return`) becomes
//!   `classic::truthy(b)` (int 1/0);
//! - the exe's events get their method names (`traits.classic`: `init` → `OnCreate`) and
//!   the event's extra parameters; a function that may end without `return` and whose
//!   value is read gets `return 0;` (Classic's 0; nil from an event is "no answer").

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const object = @import("../object.zig");
const field_name = @import("import.zig").fieldName;
const traits = @import("../traits.zig");
const rename = @import("rename.zig");
const ogs_parser = @import("../ogs/parser.zig");
const ogs_print = @import("../ogs/print.zig");
const ogs_link = @import("../ogs/link.zig");
const Value = @import("../value.zig").Value;
const Runtime = @import("../runtime.zig").Runtime;

/// A variable the class declares (its inherited ones too).
pub const Field = struct { name: []const u8, type: ir.Type };

/// A function the class answers by name; `own`: of its text (a method of the component),
/// else inherited (another class's component has it).
pub const Method = struct { f: *const ir.Fn, own: bool };

pub const Class = struct {
    /// The component's name and its host kind (`for level`).
    name: []const u8,
    kind: []const u8,
    fields: []const Field,
    /// Own first, then inherited (`classOf`).
    methods: []const Method,
    /// An actor's script: `Disable()` acts (`rename.toOgs`).
    actor: bool,
    /// The declared spelling of a name a sigil gives a kind (`port-out bt` for the
    /// exe's `"port-out BT"`: OGS names are exact, the exe's are not); `.item`: the
    /// archetype path of a Classic class file (Item_New's `"cw_axe.s"`); null: as written.
    spelling: ?Spelling = null,
    /// A split class (`trait`, convert.zig): a method it does not own is a trait's (or a
    /// trait's required one), called bare, so the most derived version runs as in Classic;
    /// never inlined, never `host.f()`.
    virtual: bool = false,
    /// A trait's bodies: a trait has no fields, its variables are the host's, `host.x`.
    host_fields: bool = false,
};

/// The method a Classic function called by name becomes (`"init"` → `"OnCreate"`, a scene's
/// GO_RUNFUN, GO_RunFun's string): an event's, where it is the only Classic function of that
/// event (`postinit` and `additionalIdleAnims` keep their names: OnActorReady calls both).
pub fn renamedEvent(name: []const u8) ?[]const u8 {
    for (traits.classic) |c| if (c.method.len > 0 and std.ascii.eqlIgnoreCase(c.name, name)) {
        var n: usize = 0;
        for (traits.classic) |d| if (std.mem.eql(u8, d.method, c.method)) {
            n += 1;
        };
        return if (n == 1) c.method else null;
    };
    return null;
}

const Spelling = struct {
    ctx: *const anyopaque,
    of: *const fn (ctx: *const anyopaque, sigil: ir.Sigil, name: []const u8) ?[]const u8,
};

/// The forms of `classic::` a translation may keep (`ir.ExeOp`, then the names and the
/// failed include).
pub const Form = enum { add, sub, mul, div, eq, ne, lt, le, gt, ge, @"and", @"or", neg, not, truthy, name, maybe, fail };

pub const Stats = struct {
    functions: usize = 0,
    /// Renamed to the host's event methods; of them, with parameters appended; events
    /// made of several functions (`Conv.mergedEvent`).
    events: usize = 0,
    padded: usize = 0,
    merged: usize = 0,
    /// `return 0;` added.
    returns: usize = 0,
    /// Names: object variables as fields, `this` as `host.name`.
    fields: usize = 0,
    this: usize = 0,
    /// Assignments to an undeclared name (the exe skips them).
    dropped: usize = 0,
    /// Calls of no function and no builtin (Classic's 0), inherited calls inlined, on `host`.
    unknown_calls: usize = 0,
    inlined: usize = 0,
    host_calls: usize = 0,
    /// Quirks made plain OGS, by form (`truthy` also counts bare conditions).
    clean: std.EnumArray(Form, usize) = .initFill(0),
    /// `bool` answers put back to int 1/0 (as `classic::truthy`).
    bool_ints: usize = 0,
};

pub const Error = Allocator.Error;

/// Runtime class `cls` of file `file` as the converter sees it: a component `name` for
/// `kind`; own functions (the file's and those of the snippets it `#include`s at the top,
/// a text insertion) by file and place, then the inherited ones: another class's
/// (`#inherit X`, `#include X.s`), that class's component has them (`components/base.ogs`).
pub fn classOf(a: Allocator, rt: *Runtime, cls: *const object.Class, file: []const u8, name: []const u8, kind: []const u8, actor: bool) Error!Class {
    var own: std.ArrayList(Method) = .empty;
    var inherited: std.ArrayList(Method) = .empty;
    var it = cls.functions.valueIterator();
    while (it.next()) |func| {
        const f = try rt.compiled(func.*);
        const mine = std.ascii.eqlIgnoreCase(func.*.file, file) or std.ascii.endsWithIgnoreCase(func.*.file, ".ss");
        try (if (mine) &own else &inherited).append(a, .{ .f = f, .own = true });
    }
    for (inherited.items) |*m| m.own = false;
    // By file, then by place in it.
    std.mem.sort(Method, own.items, {}, struct {
        fn lt(_: void, x: Method, y: Method) bool {
            const fx = !std.mem.eql(u8, x.f.file, y.f.file) and std.mem.lessThan(u8, x.f.file, y.f.file);
            return fx or (std.mem.eql(u8, x.f.file, y.f.file) and x.f.span.start < y.f.span.start);
        }
    }.lt);
    try own.appendSlice(a, inherited.items);
    const fields = try a.alloc(Field, cls.vars.items.len);
    for (cls.vars.items, fields) |d, *fd| fd.* = .{ .name = cls.varName(d), .type = d.type };
    return .{ .name = name, .kind = kind, .fields = fields, .methods = own.items, .actor = actor };
}

/// `cls` as a component (in `a`): its own functions converted, with OGS's builtin names.
pub fn component(a: Allocator, cls: *const Class, builtins: rename.Names, stats: *Stats) Error!*const ir.Component {
    var c: Conv = .{ .a = a, .cls = cls, .builtins = builtins, .stats = stats };
    try c.planNames();
    var methods: std.ArrayList(*const ir.Fn) = .empty;
    const names: rename.Names = .{ .ctx = &c, .classic = Conv.builtinOf, .ogs = Conv.noOgs };
    for (cls.methods, 0..) |m, i| {
        if (!m.own) continue;
        const f = try c.function(m.f, c.new_names[i]);
        try methods.append(a, try rename.toOgs(a, f, names, cls.actor));
        stats.functions += 1;
    }
    for (c.merged.items) |ev| try methods.append(a, try c.mergedEvent(ev));
    const comp = try a.create(ir.Component);
    comp.* = .{ .name = cls.name, .module = "", .hosts = try a.dupe([]const u8, &.{cls.kind}), .fields = &.{}, .methods = methods.items, .line = 0 };
    try dropEmptyEvents(a, comp);
    return comp;
}

/// The OGS name of each of `cls.methods` (`init` → `OnCreate`; a merged one keeps its own).
pub fn methodNames(a: Allocator, cls: *const Class, builtins: rename.Names, stats: *Stats) Error![]const []const u8 {
    var c: Conv = .{ .a = a, .cls = cls, .builtins = builtins, .stats = stats };
    try c.planNames();
    return c.new_names;
}

/// `cls` (a class file's own functions, `virtual`, `host_fields`) as trait `name` of
/// module `module` over `supers`: each own function a default body; `extra` appended
/// (the required ones its bodies call, convert.zig).
pub fn traitOf(a: Allocator, cls: *const Class, module: []const u8, supers: []const []const u8, extra: []const ir.TraitFn, builtins: rename.Names, stats: *Stats) Error!*const ir.Trait {
    var c: Conv = .{ .a = a, .cls = cls, .builtins = builtins, .stats = stats };
    try c.planNames();
    var methods: std.ArrayList(ir.TraitFn) = .empty;
    const names: rename.Names = .{ .ctx = &c, .classic = Conv.builtinOf, .ogs = Conv.noOgs };
    for (cls.methods, 0..) |m, i| {
        if (!m.own) continue;
        const f = try c.function(m.f, c.new_names[i]);
        try methods.append(a, .{ .f = try rename.toOgs(a, f, names, cls.actor), .body = true });
        stats.functions += 1;
    }
    try methods.appendSlice(a, extra);
    const t = try a.create(ir.Trait);
    // Its supertraits are the engine's host traits, named bare from its module's `use foundation;`.
    t.* = .{ .name = cls.name, .module = module, .supers = supers, .uses = &.{"foundation"}, .methods = methods.items, .file = "", .line = 0 };
    return t;
}

/// Events the engine only calls if they exist, never reading their value
/// (world/start.zig, game/life.zig `callIfExists`): an empty one does what none does.
const quiet_events = [_][]const u8{ "OnCreate", "OnClassInit", "OnCamera", "OnRestore", "OnStart", "OnActorReady", "OnUpdate" };

/// `comp` without its empty quiet events (`fn OnCreate() { }`), unless its own code
/// calls one (`host.OnClassInit()`).
fn dropEmptyEvents(a: Allocator, comp: *ir.Component) Error!void {
    var printed: ?[]const u8 = null;
    var keep: std.ArrayList(*const ir.Fn) = .empty;
    for (comp.methods) |f| {
        const quiet = for (quiet_events) |n| {
            if (std.mem.eql(u8, f.name, n)) break true;
        } else false;
        if (!quiet or f.body.len > 0) {
            try keep.append(a, f);
            continue;
        }
        // shortcut: the call found in the printed text, not by walking the IR; the
        // name followed by `(` only ever stands in a call or its own `fn`.
        const t = printed orelse (text(a, "m", &.{comp}) catch return error.OutOfMemory);
        printed = t;
        const call = try std.fmt.allocPrint(a, "{s}(", .{f.name});
        const decl = try std.fmt.allocPrint(a, "fn {s}(", .{f.name});
        if (std.mem.count(u8, t, call) > std.mem.count(u8, t, decl)) try keep.append(a, f);
    }
    comp.methods = keep.items;
}

/// OGS text of module `path` holding `comps`.
pub fn text(a: Allocator, path: []const u8, comps: []const *const ir.Component) (Error || ogs_print.Error)![]const u8 {
    const m: ir.Module = .{ .path = path, .uses = &.{}, .fns = &.{}, .components = comps, .entities = &.{}, .rows = &.{} };
    var w: std.Io.Writer.Allocating = .init(a);
    try ogs_print.unit(&w.writer, .{ .modules = &.{m} });
    return w.written();
}

/// A word OGS reads as a component, a field or a method name.
pub fn ident(a: Allocator, name: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (name.len == 0 or std.ascii.isDigit(name[0])) try out.append(a, '_');
    for (name) |ch| try out.append(a, if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_');
    if (ogs_parser.isKeyword(out.items)) try out.append(a, '_');
    return out.items;
}

/// Static type of a converted value. `bool`: OGS's answer where Classic had int 1/0;
/// `any`: a Classic value of unknown tag (never a bool, nil or object).
const Ty = enum { int, float, string, bool, any };

fn tyOf(t: ir.Type) Ty {
    return switch (t) {
        .int => .int,
        .float => .float,
        .string, .object => .string,
        .bool, .any => .any,
    };
}

fn numeric(t: Ty) bool {
    return t == .int or t == .float;
}

/// A converted expression: its value is the Classic one (a `bool` stands for int 1/0).
/// `pure`: no effects; `stable`: no effect changes it (a literal, a local).
const T = struct { e: *const ir.Expr, ty: Ty, pure: bool, stable: bool = false };

const Conv = struct {
    a: Allocator,
    cls: *const Class,
    builtins: rename.Names,
    stats: *Stats,
    /// Each method's name in OGS (`cls.methods` order).
    new_names: []const []const u8 = &.{},
    /// Events several functions become (`mergedEvent`).
    merged: std.ArrayList([]const u8) = .empty,
    /// Of the function being converted: its slots' types and names (`host.x` for a field
    /// a bare word would read as a local), temporaries appended.
    slot_ty: std.ArrayList(Ty) = .empty,
    locals: std.ArrayList([]const u8) = .empty,
    /// Inherited functions being inlined (a recursive one stops at `max_inline`).
    inlining: u8 = 0,

    const max_inline = 4;

    /// The exe's events as the host's methods: one function each, of an arity the event
    /// can take (its extra parameters appended); the rest keep their names.
    fn planNames(self: *Conv) Error!void {
        const out = try self.a.alloc([]const u8, self.cls.methods.len);
        for (self.cls.methods, out) |m, *n| n.* = m.f.name;
        self.new_names = out;
        const host = traits.ofHost(self.cls.kind) orelse return;
        for (self.cls.methods, out) |m, *name| {
            const ev = self.eventOf(host, m) orelse continue;
            // Several become one event (`additionalIdleAnims`, `postinit`): a method calling
            // them in the exe's order (`traits.classic`'s), each keeping its name.
            var n: usize = 0;
            for (self.cls.methods) |o| if (if (self.eventOf(host, o)) |e| std.mem.eql(u8, e, ev) else false) {
                n += 1;
            };
            if (n == 1) {
                name.* = ev;
                continue;
            }
            const dup = for (self.merged.items) |x| {
                if (std.mem.eql(u8, x, ev)) break true;
            } else false;
            if (dup) continue;
            try self.merged.append(self.a, ev);
            self.stats.merged += 1;
        }
    }

    /// The event own method `m` becomes on `host`: one the host has, of no fewer parameters,
    /// that no function of the class is called already.
    fn eventOf(self: *const Conv, host: *const traits.Trait, m: Method) ?[]const u8 {
        // A split class names a trait's events as the trait does.
        if (!m.own and !self.cls.virtual) return null;
        const ev = event(m.f.name) orelse return null;
        const em = traits.lookup(host, ev) orelse return null;
        if (em.arity() < m.f.params.len) return null;
        for (self.cls.methods) |o| if (std.ascii.eqlIgnoreCase(o.f.name, ev)) return null;
        return ev;
    }

    /// Event `ev` calling the class's functions that are it (`merged`), in the exe's
    /// order, with the event's parameters they take.
    fn mergedEvent(self: *Conv, ev: []const u8) Error!*const ir.Fn {
        const host = traits.ofHost(self.cls.kind).?;
        const em = traits.lookup(host, ev).?;
        var names: std.ArrayList([]const u8) = .empty;
        var params: std.ArrayList(ir.Param) = .empty;
        var it = std.mem.splitSequence(u8, em.params, ", ");
        while (it.next()) |pn| if (pn.len > 0) {
            try params.append(self.a, .{ .slot = @intCast(names.items.len), .type = .any, .name = pn });
            try names.append(self.a, pn);
        };
        var body: std.ArrayList(ir.Stmt) = .empty;
        var file: []const u8 = "";
        for (traits.classic) |c| if (std.mem.eql(u8, c.method, ev)) for (self.cls.methods) |m| {
            if (!m.own or !std.ascii.eqlIgnoreCase(m.f.name, c.name)) continue;
            file = m.f.file;
            const args = try self.a.alloc(*const ir.Expr, m.f.params.len);
            for (args, 0..) |*x, k| {
                const e = try self.a.create(ir.Expr);
                e.* = .{ .line = m.f.line, .kind = .{ .local = @intCast(k) } };
                x.* = e;
            }
            const ce = try self.a.create(ir.Expr);
            ce.* = .{ .line = m.f.line, .kind = .{ .call = .{ .id = try object.intern(m.f.name), .text = m.f.name, .args = args } } };
            try body.append(self.a, .{ .file = m.f.file, .line = m.f.line, .kind = .{ .expr = ce } });
        };
        const f = try self.a.create(ir.Fn);
        f.* = .{ .name = ev, .file = file, .line = 0, .params = params.items, .slots = @intCast(names.items.len), .body = body.items, .names = names.items, .ogs = true };
        return f;
    }

    fn event(name: []const u8) ?[]const u8 {
        for (traits.classic) |c| if (c.method.len > 0 and std.ascii.eqlIgnoreCase(c.name, name)) return c.method;
        return null;
    }

    /// Builtin `id` for `rename.toOgs`: none where the class answers the name itself.
    fn builtinOf(ctx: *anyopaque, id: u32) ?rename.Info {
        const self: *Conv = @ptrCast(@alignCast(ctx));
        if (self.methodOf(id) != null) return null;
        return self.builtins.classic(self.builtins.ctx, id);
    }

    fn noOgs(_: *anyopaque, _: []const u8) ?rename.Info {
        return null;
    }

    fn methodOf(self: *const Conv, id: u32) ?usize {
        const name = object.nameOf(id);
        for (self.cls.methods, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.f.name, name)) return i;
        return null;
    }

    fn fieldOf(self: *const Conv, name: []const u8) ?Field {
        for (self.cls.fields) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x;
        return null;
    }

    fn node(self: *Conv, at: *const ir.Expr, kind: ir.Expr.Kind) Error!*const ir.Expr {
        const n = try self.a.create(ir.Expr);
        n.* = .{ .line = at.line, .span = at.span, .kind = kind };
        return n;
    }

    fn lit(self: *Conv, at: *const ir.Expr, v: Value) Error!T {
        return .{ .e = try self.node(at, .{ .lit = v }), .ty = if (v == .bool) .bool else .int, .pure = true, .stable = true };
    }

    // ---------------------------------------------------------------- functions

    fn function(self: *Conv, f: *const ir.Fn, name: []const u8) Error!*const ir.Fn {
        const ty = try self.a.alloc(Ty, f.slots);
        @memset(ty, .any);
        const seen = try self.a.alloc(bool, f.slots);
        @memset(seen, false);
        for (f.params) |p| {
            ty[p.slot] = tyOf(p.type);
            seen[p.slot] = true;
        }
        markLocals(f.body, ty, seen);
        self.slot_ty = .fromOwnedSlice(ty);
        // OGS words for the locals (a Classic local may be called `in`).
        self.locals = .empty;
        for (0..f.slots) |i| try self.locals.append(self.a, try ident(self.a, if (i < f.names.len) f.names[i] else "_"));
        var params: std.ArrayList(ir.Param) = .empty;
        try params.appendSlice(self.a, f.params);
        const renamed = !std.mem.eql(u8, name, f.name);
        // The event's parameters the Classic function lacks (`OnNode(no, dir, walker)`).
        if (renamed) if (traits.lookup(traits.ofHost(self.cls.kind).?, name)) |em| if (em.arity() > params.items.len) {
            var it = std.mem.splitSequence(u8, em.params, ", ");
            var k: usize = 0;
            while (it.next()) |pn| : (k += 1) {
                if (k < f.params.len) continue;
                const slot = try self.newSlot(pn, .any);
                // nil when the class's own code calls it with the Classic arguments.
                const nil = try self.a.create(ir.Expr);
                nil.* = .{ .line = f.line, .kind = .{ .lit = .nil } };
                try params.append(self.a, .{ .slot = slot, .type = .any, .name = self.locals.items[slot], .default = nil });
            }
            self.stats.padded += 1;
        };
        if (renamed) self.stats.events += 1;
        var body: std.ArrayList(ir.Stmt) = .empty;
        try self.stmts(&body, f.body);
        // Classic's 0 where the value is read: not an event whose result nobody uses.
        const unused = renamed and traits.lookup(traits.ofHost(self.cls.kind).?, name).?.combine == .all;
        if (!unused and !returns(body.items)) {
            const zero = try self.a.create(ir.Expr);
            zero.* = .{ .line = f.line, .kind = .{ .lit = .zero } };
            try body.append(self.a, .{ .file = f.file, .line = f.line, .kind = .{ .@"return" = zero } });
            self.stats.returns += 1;
        }
        const out = try self.a.create(ir.Fn);
        out.* = .{ .name = name, .file = f.file, .line = f.line, .params = params.items, .slots = @intCast(self.locals.items.len), .body = body.items, .span = f.span, .names = self.locals.items, .ogs = true };
        return out;
    }

    /// A new slot named `base` (`base_`, `base__`… where a local or a field has the name).
    fn newSlot(self: *Conv, base: []const u8, ty: Ty) Error!u16 {
        var n = base;
        while (self.fieldOf(n) != null or for (self.locals.items) |x| {
            if (std.ascii.eqlIgnoreCase(x, n)) break true;
        } else false) n = try std.mem.concat(self.a, u8, &.{ n, "_" });
        try self.locals.append(self.a, n);
        try self.slot_ty.append(self.a, ty);
        return @intCast(self.locals.items.len - 1);
    }

    /// `t` evaluated here into a new local (`int`: as an int, the exe's truth of it).
    fn temp(self: *Conv, h: Hoist, t: T, int: bool) Error!T {
        const ty: Ty = if (int) .int else t.ty;
        const slot = try self.newSlot("t", ty);
        try self.push(h.out, h.at, .{ .local = .{ .slot = slot, .type = if (int) .int else .any } });
        try self.push(h.out, h.at, .{ .assign = .{ .target = .{ .local = slot }, .value = t.e } });
        return .{ .e = try self.node(t.e, .{ .local = slot }), .ty = ty, .pure = true, .stable = true };
    }

    /// Slot types: a slot declared with one type keeps it (the runtime converts every
    /// value stored there); two types: unknown.
    fn markLocals(body: []const ir.Stmt, ty: []Ty, seen: []bool) void {
        for (body) |s| switch (s.kind) {
            .local => |l| {
                const t = tyOf(l.type);
                ty[l.slot] = if (!seen[l.slot] or ty[l.slot] == t) t else .any;
                seen[l.slot] = true;
            },
            .@"if" => |x| {
                markLocals(x.then, ty, seen);
                markLocals(x.@"else", ty, seen);
            },
            else => {},
        };
    }

    /// Every path through `body` ends in a `return`.
    fn returns(body: []const ir.Stmt) bool {
        if (body.len == 0) return false;
        return switch (body[body.len - 1].kind) {
            .@"return" => true,
            .@"if" => |x| returns(x.then) and returns(x.@"else"),
            else => false,
        };
    }

    // ---------------------------------------------------------------- statements

    fn stmts(self: *Conv, out: *std.ArrayList(ir.Stmt), list: []const ir.Stmt) Error!void {
        for (list) |*s| try self.stmt(out, s);
    }

    fn push(self: *Conv, out: *std.ArrayList(ir.Stmt), s: *const ir.Stmt, kind: ir.Stmt.Kind) Error!void {
        var n = s.*;
        n.kind = kind;
        try out.append(self.a, n);
    }

    fn stmt(self: *Conv, out: *std.ArrayList(ir.Stmt), s: *const ir.Stmt) Error!void {
        switch (s.kind) {
            .expr => |e| {
                // A call of nothing: its arguments' effects only.
                if (e.kind == .call and self.callee(e.kind.call.id) == .none) {
                    self.stats.unknown_calls += 1;
                    for (e.kind.call.args) |x| {
                        const t = try self.value(x);
                        if (!t.pure) try self.push(out, s, .{ .expr = t.e });
                    }
                    return;
                }
                // An inherited function without parameters, locals or `return`: its statements.
                if (e.kind == .call) if (self.inlinable(e)) |g| {
                    self.stats.inlined += 1;
                    self.inlining += 1;
                    defer self.inlining -= 1;
                    return self.stmts(out, g.body);
                };
                try self.push(out, s, .{ .expr = (try self.value(e)).e });
            },
            .local => try self.push(out, s, s.kind),
            .assign => |x| {
                const v = try self.value(x.value);
                const t: ir.Target, const ty: Ty = switch (x.target) {
                    .local => |slot| .{ x.target, self.slot_ty.items[slot] },
                    .name => |n| if (n.slot != null) .{ x.target, .any } else if (self.fieldOf(field_name(n))) |fd| blk: {
                        self.stats.fields += 1;
                        break :blk .{ try self.fieldTarget(x.value, fd), tyOf(fd.type) };
                    } else {
                        // The exe skips it ("Cannot find variable"): the value for its effects.
                        self.stats.dropped += 1;
                        if (!v.pure) try self.push(out, s, .{ .expr = v.e });
                        return;
                    },
                    .field, .member => unreachable,
                };
                // The stored value converts to the target's type: a bool to an int as Classic's 1/0.
                const val = if (ty == .int or ty == .float) v.e else try self.classicValue(v);
                try self.push(out, s, .{ .assign = .{ .target = t, .value = val } });
            },
            .@"if" => |x| {
                // The condition runs first: what it needs evaluated goes before the `if`.
                const c = try self.cond(x.cond, .{ .out = out, .at = s });
                var then: std.ArrayList(ir.Stmt) = .empty;
                try self.stmts(&then, x.then);
                var els: std.ArrayList(ir.Stmt) = .empty;
                try self.stmts(&els, x.@"else");
                try self.push(out, s, .{ .@"if" = .{ .cond = c, .then = then.items, .@"else" = els.items } });
            },
            .@"return" => |e| try self.push(out, s, .{ .@"return" = try self.classicValue(try self.value(e)) }),
            .fail => try self.push(out, s, s.kind),
            .@"while", .for_in, .@"break", .@"continue" => unreachable,
        }
    }

    fn fieldTarget(self: *Conv, at: *const ir.Expr, fd: Field) Error!ir.Target {
        const e = try self.fieldExpr(at, fd);
        return switch (e.kind) {
            .field => |x| .{ .field = x },
            .member => |m| .{ .member = m },
            else => unreachable,
        };
    }

    /// Field `fd` as written in its declaration: a bare word, or `host.x` where the word
    /// would be a keyword or one of the function's locals.
    fn fieldExpr(self: *Conv, at: *const ir.Expr, fd: Field) Error!*const ir.Expr {
        const id = try object.intern(fd.name);
        const bare = !self.cls.host_fields and !ogs_parser.isKeyword(fd.name) and for (self.locals.items) |l| {
            if (std.ascii.eqlIgnoreCase(l, fd.name)) break false;
        } else true;
        if (bare) return self.node(at, .{ .field = .{ .id = id, .text = fd.name } });
        return self.node(at, .{ .member = .{ .obj = try self.node(at, .host), .id = id, .text = fd.name } });
    }

    // ---------------------------------------------------------------- expressions

    /// A condition: its OGS truth is the exe's of the original. `h`: it is a statement's
    /// first evaluation (an `if`'s), so its parts may run before it into locals.
    fn cond(self: *Conv, e: *const ir.Expr, h: ?Hoist) Error!*const ir.Expr {
        if (e.kind == .exe and e.kind.exe.op == .truthy) {
            const x = try self.value(e.kind.exe.args[0]);
            if (try self.truthOf(x)) |t| {
                self.count(.truthy);
                return t;
            }
            // `var int t = x;`: the exe's truth (a float truncates, a string is 0).
            if (h) |at| {
                self.count(.truthy);
                return (try self.temp(at, x, true)).e;
            }
            return self.exe(e, .truthy, &.{x.e});
        }
        // `&&`, `||` with effects: both sides, right first, into locals, then `and`, `or`.
        if (h) |at| if (e.kind == .exe and (e.kind.exe.op == .@"and" or e.kind.exe.op == .@"or") and !self.pureIr(e)) return self.hoistLogic(at, e);
        // The importer left an int there: an int or a yes/no answer now.
        const t = try self.value(e);
        if (t.ty == .int or t.ty == .bool) return t.e;
        if (h) |at| return (try self.temp(at, t, true)).e;
        return self.exe(e, .truthy, &.{t.e});
    }

    const Hoist = struct { out: *std.ArrayList(ir.Stmt), at: *const ir.Stmt };

    /// Exe `&&`/`||` node `e` as `and`/`or` over locals evaluated before, right first.
    fn hoistLogic(self: *Conv, h: Hoist, e: *const ir.Expr) Error!*const ir.Expr {
        const x = e.kind.exe;
        self.count(formOf(x.op));
        const r = try self.hoistSide(h, x.args[1]);
        const l = try self.hoistSide(h, x.args[0]);
        return self.node(e, .{ .logic = .{ .op = if (x.op == .@"and") .@"and" else .@"or", .lhs = l, .rhs = r } });
    }

    /// An operand of `hoistLogic`: its truth, from a local unless a literal or a local.
    fn hoistSide(self: *Conv, h: Hoist, e: *const ir.Expr) Error!*const ir.Expr {
        if (e.kind == .exe and (e.kind.exe.op == .@"and" or e.kind.exe.op == .@"or")) return self.hoistLogic(h, e);
        const t = try self.value(e);
        if (t.stable) if (try self.truthOf(t)) |x| return x;
        return (try self.temp(h, t, !(t.ty == .int or t.ty == .bool))).e;
    }

    /// `e` has no effects (the importer's sense: reads, pure builtins).
    fn pureIr(self: *const Conv, e: *const ir.Expr) bool {
        return switch (e.kind) {
            .lit, .local, .name => true,
            .call => |c| blk: {
                const ok = switch (self.callee(c.id)) {
                    .none => true,
                    .method => false,
                    .builtin => |b| b.pure,
                };
                if (!ok) break :blk false;
                for (c.args) |x| if (!self.pureIr(x)) break :blk false;
                break :blk true;
            },
            .exe => |x| for (x.args) |y| {
                if (!self.pureIr(y)) break false;
            } else true,
            .unary => |u| self.pureIr(u.operand),
            .binary => |b| self.pureIr(b.lhs) and self.pureIr(b.rhs),
            .logic => |b| self.pureIr(b.lhs) and self.pureIr(b.rhs),
            else => false,
        };
    }

    fn count(self: *Conv, f: Form) void {
        self.stats.clean.set(f, self.stats.clean.get(f) + 1);
    }

    /// An expression whose OGS truth is the exe's truth of `x`; null: none known.
    fn truthOf(self: *Conv, x: T) Error!?*const ir.Expr {
        return switch (x.ty) {
            .int, .bool => x.e,
            // A string is false in the exe.
            .string => if (x.pure) (try self.lit(x.e, .{ .bool = false })).e else null,
            .float, .any => null,
        };
    }

    /// `x` as Classic's value: a yes/no answer as int 1/0.
    fn classicValue(self: *Conv, x: T) Error!*const ir.Expr {
        if (x.ty != .bool) return x.e;
        self.stats.bool_ints += 1;
        return self.exe(x.e, .truthy, &.{x.e});
    }

    fn exe(self: *Conv, at: *const ir.Expr, op: ir.ExeOp, args: []const *const ir.Expr) Error!*const ir.Expr {
        return self.node(at, .{ .exe = .{ .op = op, .args = try self.a.dupe(*const ir.Expr, args) } });
    }

    fn value(self: *Conv, e: *const ir.Expr) Error!T {
        switch (e.kind) {
            .lit => |v| return .{ .e = e, .ty = switch (v) {
                .int => .int,
                .float => .float,
                .string => .string,
                else => .any,
            }, .pure = true, .stable = true },
            .local => |s| return .{ .e = try self.node(e, .{ .local = s }), .ty = self.slot_ty.items[s], .pure = true, .stable = true },
            .name => |n| {
                if (n.slot == null) {
                    if (self.fieldOf(field_name(n))) |fd| {
                        self.stats.fields += 1;
                        return .{ .e = try self.fieldExpr(e, fd), .ty = tyOf(fd.type), .pure = true };
                    }
                    if (n.this) {
                        self.stats.this += 1;
                        return .{ .e = try self.node(e, .{ .member = .{ .obj = try self.node(e, .host), .id = try object.intern("name"), .text = "name" } }), .ty = .string, .pure = true };
                    }
                }
                return .{ .e = e, .ty = .any, .pure = true };
            },
            .call => |c| return self.call(e, c),
            .exe => |x| return self.quirk(e, x.op, x.args),
            .unary => |u| {
                const o = try self.value(u.operand);
                return switch (u.op) {
                    // The importer made it plain over a number only; a yes/no answer as 1/0.
                    .neg => .{ .e = try self.node(e, .{ .unary = .{ .op = .neg, .operand = try self.classicValue(o) } }), .ty = if (o.ty == .bool) .int else o.ty, .pure = o.pure },
                    .not => .{ .e = try self.node(e, .{ .unary = .{ .op = .not, .operand = o.e } }), .ty = .bool, .pure = o.pure },
                };
            },
            .binary => |b| {
                if (b.op == .eq or b.op == .ne) if (try self.stricmp(e, b.op == .ne, b.lhs, b.rhs)) |t| return t;
                const l = try self.value(b.lhs);
                const r = try self.value(b.rhs);
                if (b.op == .eq or b.op == .ne) if (try self.answerCompare(e, b.op == .ne, l, r)) |t| return t;
                const ty: Ty = switch (b.op) {
                    .eq, .ne, .lt, .le, .gt, .ge => .bool,
                    else => if (l.ty == .float or r.ty == .float) .float else .int,
                };
                return .{ .e = try self.node(e, .{ .binary = .{ .op = b.op, .lhs = try self.classicValue(l), .rhs = try self.classicValue(r) } }), .ty = ty, .pure = l.pure and r.pure };
            },
            // The importer made it plain over pure operands only.
            .logic => |x| return .{ .e = try self.node(e, .{ .logic = .{ .op = x.op, .lhs = try self.cond(x.lhs, null), .rhs = try self.cond(x.rhs, null) } }), .ty = .bool, .pure = false },
            // A Classic assignment used as a value: none in the games, no OGS text.
            .assign => return .{ .e = e, .ty = .any, .pure = false },
            .field, .host, .self, .member, .index, .list, .map, .ref, .method, .word, .trait_op => unreachable,
        }
    }

    /// A yes/no answer `== 1` (the answer), `== 0` (its negation), `!= …` the other way;
    /// null: not that.
    fn answerCompare(self: *Conv, at: *const ir.Expr, ne: bool, l: T, r: T) Error!?T {
        const b, const k = if (l.ty == .bool and isIntLit(r.e)) .{ l, r.e.kind.lit.int } else if (r.ty == .bool and isIntLit(l.e)) .{ r, l.e.kind.lit.int } else return null;
        if (k != 0 and k != 1) return if (b.pure) try self.lit(at, .{ .bool = ne }) else null;
        if ((k == 1) != ne) return b;
        return .{ .e = try self.node(at, .{ .unary = .{ .op = .not, .operand = b.e } }), .ty = .bool, .pure = b.pure };
    }

    /// `s_stricmp(a, b) == 0` (Classic's case-insensitive compare: 0 when equal) →
    /// `EqualsIgnoreCase(a, b)`, `!= 0` its negation; null: not that.
    fn stricmp(self: *Conv, at: *const ir.Expr, ne: bool, l: *const ir.Expr, r: *const ir.Expr) Error!?T {
        const c, const z = if (l.kind == .call) .{ l, r } else .{ r, l };
        if (c.kind != .call or !isIntLit(z) or z.kind.lit.int != 0) return null;
        const b = switch (self.callee(c.kind.call.id)) {
            .builtin => |b| b,
            else => return null,
        };
        if (!std.ascii.eqlIgnoreCase(b.exe, "s_stricmp") or c.kind.call.args.len != 2) return null;
        const args = try self.a.alloc(*const ir.Expr, 2);
        var pure = true;
        for (c.kind.call.args, args) |x, *o| {
            const t = try self.value(x);
            pure = pure and t.pure;
            o.* = t.e;
        }
        const eq = try self.node(at, .{ .call = .{ .id = try object.intern("EqualsIgnoreCase"), .text = "EqualsIgnoreCase", .args = args } });
        const t: T = .{ .e = eq, .ty = .bool, .pure = pure };
        if (!ne) return t;
        return .{ .e = try self.node(at, .{ .unary = .{ .op = .not, .operand = eq } }), .ty = .bool, .pure = pure };
    }

    fn isIntLit(e: *const ir.Expr) bool {
        return e.kind == .lit and e.kind.lit == .int;
    }

    /// The exe's operator `op` over `args` (right first): plain OGS where the value is
    /// the same, else `classic::op` over the converted operands.
    fn quirk(self: *Conv, at: *const ir.Expr, op: ir.ExeOp, args: []const *const ir.Expr) Error!T {
        var xs: [2]T = undefined;
        for (args, 0..) |x, i| xs[i] = try self.value(x);
        const pure = xs[0].pure and (args.len == 1 or xs[1].pure);
        if (try self.plainQuirk(at, op, xs[0..args.len])) |t| {
            self.count(formOf(op));
            return t;
        }
        var conv: [2]*const ir.Expr = undefined;
        for (xs[0..args.len], 0..) |x, i| conv[i] = x.e;
        const ty: Ty = switch (op) {
            .add, .sub, .mul, .div, .ne => if (numeric(xs[0].ty) and numeric(xs[1].ty)) (if (xs[0].ty == .float or xs[1].ty == .float) .float else .int) else .any,
            .neg => if (numeric(xs[0].ty)) xs[0].ty else .any,
            else => .int,
        };
        return .{ .e = try self.exe(at, op, conv[0..args.len]), .ty = ty, .pure = pure };
    }

    fn formOf(op: ir.ExeOp) Form {
        return std.meta.stringToEnum(Form, @tagName(op)).?;
    }

    fn plainQuirk(self: *Conv, at: *const ir.Expr, op: ir.ExeOp, xs: []const T) Error!?T {
        if (xs.len == 1) {
            const x = xs[0];
            return switch (op) {
                .neg => if (numeric(x.ty)) .{ .e = try self.node(at, .{ .unary = .{ .op = .neg, .operand = x.e } }), .ty = x.ty, .pure = x.pure } else null,
                .not => if (x.ty == .int or x.ty == .bool)
                    .{ .e = try self.node(at, .{ .unary = .{ .op = .not, .operand = x.e } }), .ty = .bool, .pure = x.pure }
                else if (x.ty == .string and x.pure) try self.lit(at, .{ .bool = true }) else null,
                // As a value (a condition is `cond`'s): `x != 0`, an answer as it is.
                .truthy => switch (x.ty) {
                    .int => .{ .e = try self.node(at, .{ .binary = .{ .op = .ne, .lhs = x.e, .rhs = (try self.lit(at, .zero)).e } }), .ty = .bool, .pure = x.pure },
                    .bool => x,
                    .string => if (x.pure) try self.lit(at, .{ .bool = false }) else null,
                    .float, .any => null,
                },
                else => unreachable,
            };
        }
        const l = xs[0];
        const r = xs[1];
        // The exe evaluates the right operand first, a plain node the left one.
        const order_free = (l.pure and r.pure) or l.stable or r.stable;
        const both_num = numeric(l.ty) and numeric(r.ty);
        switch (op) {
            .add, .sub, .mul, .div, .ne, .lt, .gt, .ge, .le => {
                if (!both_num or !order_free) return null;
                // `!=` adds and `<=` is `>=` in the exe.
                const p: ir.BinaryOp = switch (op) {
                    .ne => .add,
                    .le => .ge,
                    inline .add, .sub, .mul, .div, .lt, .gt, .ge => |o| @field(ir.BinaryOp, @tagName(o)),
                    else => unreachable,
                };
                const ty: Ty = switch (p) {
                    .lt, .gt, .ge => .bool,
                    else => if (l.ty == .float or r.ty == .float) .float else .int,
                };
                return .{ .e = try self.node(at, .{ .binary = .{ .op = p, .lhs = l.e, .rhs = r.e } }), .ty = ty, .pure = l.pure and r.pure };
            },
            .eq => {
                if (l.ty == .int and r.ty == .int and order_free) return .{ .e = try self.node(at, .{ .binary = .{ .op = .eq, .lhs = l.e, .rhs = r.e } }), .ty = .bool, .pure = l.pure and r.pure };
                if (try self.answerCompare(at, false, l, r)) |t| return t;
                // Two strings are always equal in the exe.
                if (l.ty == .string and r.ty == .string and l.pure and r.pure) return try self.lit(at, .{ .bool = true });
                return null;
            },
            .@"and", .@"or" => {
                if (!l.pure or !r.pure) return null;
                const lt = try self.truthOf(l) orelse return null;
                const rt = try self.truthOf(r) orelse return null;
                return .{ .e = try self.node(at, .{ .logic = .{ .op = if (op == .@"and") .@"and" else .@"or", .lhs = lt, .rhs = rt } }), .ty = .bool, .pure = true };
            },
            .neg, .not, .truthy => unreachable,
        }
    }

    const Callee = union(enum) { none, method: usize, builtin: rename.Info };

    fn callee(self: *const Conv, id: u32) Callee {
        if (self.methodOf(id)) |i| return .{ .method = i };
        if (self.builtins.classic(self.builtins.ctx, id)) |b| return .{ .builtin = b };
        return .none;
    }

    fn call(self: *Conv, e: *const ir.Expr, c: ir.Call) Error!T {
        const args = try self.a.alloc(*const ir.Expr, c.args.len);
        var pure = true;
        switch (self.callee(c.id)) {
            .none => {
                // A value: 0 once its arguments ran (statements drop the call, `stmt`).
                self.stats.unknown_calls += 1;
                for (c.args) |x| pure = pure and (try self.value(x)).pure;
                if (pure) return self.lit(e, .zero);
                // shortcut: no game script uses such a call's value with effects in its arguments.
                return .{ .e = e, .ty = .any, .pure = false };
            },
            .method => |i| {
                const m = self.cls.methods[i];
                for (c.args, args, 0..) |x, *o, k| {
                    const t = try self.value(x);
                    // A parameter converts the value to its type; Classic's 1/0 for a string.
                    const pt: Ty = if (k < m.f.params.len) tyOf(m.f.params[k].type) else .any;
                    o.* = if (pt == .int or pt == .float) t.e else try self.classicValue(t);
                }
                if (!m.own and !self.cls.virtual) {
                    self.stats.host_calls += 1;
                    const meth = try self.a.create(ir.Method);
                    meth.* = .{ .obj = try self.node(e, .host), .id = c.id, .text = m.f.name, .args = args };
                    return .{ .e = try self.node(e, .{ .method = meth }), .ty = .any, .pure = false };
                }
                const n = self.new_names[i];
                return .{ .e = try self.node(e, .{ .call = .{ .id = try object.intern(n), .text = n, .args = args } }), .ty = .any, .pure = false };
            },
            .builtin => |b| {
                for (c.args, args, 0..) |x, *o, k| {
                    const t = try self.value(x);
                    pure = pure and t.pure;
                    // A declared parameter takes `true` as 1; an undeclared one as it is.
                    const pt = ogs_link.sigType(b.sig, k);
                    o.* = if (pt.len > 0 and !std.mem.eql(u8, pt, "any")) t.e else try self.classicValue(t);
                    // A name of a kind the parameter takes: with its sigil (`~l"01_port"`).
                    if (ir.Sigil.ofType(pt)) |sg| if (t.e.kind == .lit and t.e.kind.lit == .string) {
                        const n = try self.a.create(ir.Expr);
                        n.* = t.e.*;
                        n.sigil = sg;
                        if (self.cls.spelling) |sp| if (sp.of(sp.ctx, sg, t.e.kind.lit.string)) |named| {
                            n.kind = .{ .lit = .{ .string = named } };
                        };
                        o.* = n;
                    };
                }
                // Item_New/Weapon_New(name, "cw_axe.s"): the archetype made of that class
                // (`"weapons::axe"`, the converter's: `spelling` of `.item`), else as written.
                if (std.ascii.eqlIgnoreCase(c.text, "Item_New") or std.ascii.eqlIgnoreCase(c.text, "Weapon_New")) if (args.len > 1) if (self.cls.spelling) |sp| {
                    const x = args[1];
                    if (x.kind == .lit and x.kind.lit == .string and x.sigil == .none) if (sp.of(sp.ctx, .item, x.kind.lit.string)) |path| {
                        const n = try self.a.create(ir.Expr);
                        n.* = x.*;
                        n.kind = .{ .lit = .{ .string = path } };
                        args[1] = n;
                    };
                };
                // GO_RunFun(obj, "init"), Actor_GORunFun(…, "init"): the function by its new
                // name, the event's.
                if (std.ascii.eqlIgnoreCase(c.text, "GO_RunFun") or std.ascii.eqlIgnoreCase(c.text, "Actor_GORunFun")) if (args.len > 0) {
                    const last = args[args.len - 1];
                    if (last.kind == .lit and last.kind.lit == .string) if (renamedEvent(last.kind.lit.string)) |ev| {
                        const n = try self.a.create(ir.Expr);
                        n.* = last.*;
                        n.kind = .{ .lit = .{ .string = ev } };
                        args[args.len - 1] = n;
                    };
                };
                const ty: Ty = if (std.mem.startsWith(u8, b.sig, "bool(")) .bool else if (std.mem.startsWith(u8, b.sig, "int(")) .int else .any;
                return .{ .e = try self.node(e, .{ .call = .{ .id = c.id, .text = c.text, .args = args } }), .ty = ty, .pure = pure and b.pure };
            },
        }
    }

    /// The inherited function call statement `e` runs, if it can stand in its place: no
    /// arguments, parameters, locals, `return` or failed include.
    fn inlinable(self: *const Conv, e: *const ir.Expr) ?*const ir.Fn {
        const i = self.methodOf(e.kind.call.id) orelse return null;
        const g = self.cls.methods[i].f;
        if (self.cls.virtual or self.cls.methods[i].own or self.inlining >= max_inline or g.params.len > 0 or e.kind.call.args.len > 0 or g.slots > 0 or !plainBody(g.body)) return null;
        return g;
    }

    fn plainBody(body: []const ir.Stmt) bool {
        for (body) |st| switch (st.kind) {
            .@"return", .fail => return false,
            .@"if" => |x| if (!plainBody(x.then) or !plainBody(x.@"else")) return false,
            else => {},
        };
        return true;
    }
};

test "renamedEvent: a Classic event called by name gets its method's name, a merged pair keeps its own" {
    try std.testing.expectEqualStrings("OnCreate", renamedEvent("INIT").?);
    try std.testing.expectEqualStrings("OnRestore", renamedEvent("restore").?);
    try std.testing.expect(renamedEvent("postinit") == null);
    try std.testing.expect(renamedEvent("UniversalTake") == null);
    try std.testing.expect(renamedEvent("CheckRules") == null);
}
