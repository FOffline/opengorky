//! Script interpreter: classes (`#inherit`), objects with variables, calls to
//! script functions and engine builtins. A function is compiled to IR (`ir.zig`,
//! `classic/import.zig`) on its first call; the runtime walks the IR.
//!
//! Variable and function names are case-insensitive (.wpn files write `Owner`
//! while the class declares `owner`).
//!
//! OGS: texts load into one program (`loadOgs`, `ogs/link.zig`); a
//! component attached to a host object (`attach`) is an object of its own (its fields
//! are its variables, `owner` its host) whose class has the component's methods. A
//! run-time error in OGS code (`error.ScriptFault`, `fault` says where) ends the call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const exe = @import("exe.zig");
const import = @import("classic/import.zig");
const lift = @import("classic/lift.zig");
const rename = @import("classic/rename.zig");
const names_classic = @import("classic/names.zig");
const ogs_parser = @import("ogs/parser.zig");
const ogs_link = @import("ogs/link.zig");
const traits = @import("traits.zig");
const parser = @import("parser.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// Script source provider by file name (`activebitmapanimation.s`,
/// `drzwi_barak_aba.aba`). Returned memory must live as long as the runtime.
const SourceProvider = struct {
    ctx: *anyopaque,
    fetch: *const fn (ctx: *anyopaque, name: []const u8) anyerror!?[]const u8,
};

const BuiltinFn = *const fn (ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value;

/// What the importer may assume about a builtin (`builtins.zig` table).
pub const Sig = struct {
    /// `int(string, ?int)`: result and parameter types as `editor/api.zig` writes them
    /// (`?` optional). `any` result: whatever a script function returns. A handler error
    /// gives int 0, so only an `int` result is a static type. `bool` result: a yes/no
    /// answer; the handler gives int 1/0, which a Classic caller keeps and an OGS caller
    /// gets as `bool` (`Runtime.builtinResult`). A `level`, `scene`, `sound` parameter is a
    /// string naming one (`ir.Sigil.ofType`: `ogs/link.zig` checks a sigil passed there).
    text: []const u8 = "",
    /// No effects and no failure: the importer may skip it (`&&`) or reorder it.
    pure: bool = false,
    /// Declarative: a call with literal arguments in a creation event is model data
    /// (`classic/lift.zig`).
    data: bool = false,
    /// OGS's name (docs/og-script.md §16): a package's (`fighter::SetHp`) or the root's
    /// (`print`); empty: the name it is registered under.
    ogs: []const u8 = "",
    /// Classic only: OGS has no such builtin (`GetName`: `host.name`; `Disable`: `object::Disable(host)`).
    classic: bool = false,
    /// Its first argument `"this"` names the caller (`args.objectArg`); OGS writes `host`.
    this: bool = false,

    fn returnsInt(self: Sig) bool {
        return std.mem.startsWith(u8, self.text, "int(") or self.returnsBool();
    }

    fn returnsBool(self: Sig) bool {
        return std.mem.startsWith(u8, self.text, "bool(");
    }

    /// Parameter `i` is declared `any`: the handler takes an OGS value there as it is.
    fn takesAny(self: Sig, i: usize) bool {
        return std.mem.eql(u8, ogs_link.sigType(self.text, i), "any");
    }

    /// Argument `i` goes to the handler as it is: an `any` parameter, or one the
    /// signature does not declare (no signature, extra arguments).
    fn takesAsIs(self: Sig, i: usize) bool {
        const t = ogs_link.sigType(self.text, i);
        return t.len == 0 or std.mem.eql(u8, t, "any");
    }
};

const Builtin = struct {
    /// As registered (an OGS call names it in this case).
    name: []const u8 = "",
    ctx: *anyopaque,
    func: BuiltinFn,
    sig: Sig = .{},
};

const object = @import("object.zig");
const Class = object.Class;
const Var = object.Var;
const Object = object.Object;
const Func = object.Func;

const Error = error{ ScriptNotFound, IncludeCycle, StackOverflow, ScriptFault, LinkError } || parser.Error || Allocator.Error;

pub const Runtime = struct {
    gpa: Allocator,
    /// Classes, parse trees, IR, sources, names: everything until the runtime is destroyed.
    arena_state: std.heap.ArenaAllocator,
    /// Strings created at run time.
    strings_state: std.heap.ArenaAllocator,
    source: SourceProvider,
    classes: std.StringHashMapUnmanaged(*Class) = .empty,
    units: std.StringHashMapUnmanaged(ast.Unit) = .empty,
    objects: std.ArrayList(*Object) = .empty,
    /// Lower-case object name → first object with that name (objects are only added,
    /// names never change), so `findObject` doesn't scan.
    by_name: std.StringHashMapUnmanaged(*Object) = .empty,
    builtins: std.AutoHashMapUnmanaged(u32, Builtin) = .empty,
    /// OGS name (`Sig.ogs`) → builtin id; of two with one name (`path::Delay`), the first.
    ogs_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// Names of all script functions loaded (a call to one is not a builtin call).
    fn_names: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Bumped when a script function takes a builtin's name: compiled IR assumed the builtin.
    ir_gen: u32 = 0,
    /// Builtins called but not implemented (name → call count).
    missing_builtins: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Assignments to undeclared variables and reads of unknown names.
    unknown_names: std.StringArrayHashMapUnmanaged(u32) = .empty,
    depth: u32 = 0,
    /// Number of the current top-level script call (grows on every entry from depth
    /// 0), to tell "the same call" from the next one.
    top_call: u64 = 0,
    /// Last load error: a parse or link error, a missing include of a Classic function.
    diag: parser.Diagnostic = .{},
    /// OGS: every loaded text's functions and components (`loadOgs`).
    ogs: ogs_link.Program = .{},
    /// The data blocks' schema `linkOgs` checks them against (the host's: `core/schema.zig
    /// blockField`); null: not checked.
    schema: ?*const fn (kind: []const u8, name: []const u8) ogs_link.Lookup = null,
    /// The native components code names (`host.get(Guard)`; the host's: core/natives.zig).
    natives_known: []const object.Native = &.{},
    /// A component's instance class (its methods).
    comp_classes: std.AutoHashMapUnmanaged(*const ir.Component, *Class) = .empty,
    /// The last `error.ScriptFault`: where and why.
    fault: parser.Diagnostic = .{},
    /// The builtin running was called from OGS code (not Classic): one that reports only
    /// OGS calls reads it (FighterSetHp's battle log line keeps Classic's logs as they were).
    ogs_call: bool = false,
    /// A host's computed fields (`target.side`, `alive`, `tile` of a fighter in battle):
    /// asked for `o.name` when the object has no such variable (null: nil).
    host_fields: ?HostFields = null,
    /// A word given to an int variable (`action = "Close";` in OpenGorky code): its number
    /// by the variable's name (an action's: rules Action; null: no such word, kept a string).
    field_words: ?*const fn (field: []const u8, word: []const u8) ?i32 = null,
    /// The engine methods of its traits (`native fn` of `Hero`, `Enemy`),
    /// called on `o` that is the trait (null: they answer nil).
    natives: ?Natives = null,
    /// The engine's code of native components' methods (Object.Class.native; null: they
    /// answer nil): `tag` the component's, `method` the built-in method's name.
    native_components: ?*const fn (rt: *Runtime, inst: *Object, tag: u8, method: []const u8, args: []Value) anyerror!?Value = null,
    /// A native component's instance class (its bits).
    native_classes: std.AutoHashMapUnmanaged(*const object.Native, *Class) = .empty,
    /// Creation events lifted to model data (`classic/lift.zig`), by class (layers depend
    /// on its file) and function, valid while the function's IR is (`Func.gen`).
    lifted: std.AutoHashMapUnmanaged(LiftKey, Lifted) = .empty,
    /// Creation events run as their lifted model (`callScript`); false: as code (gorky-tool
    /// `lift` compares the two).
    lift: bool = true,
    /// OGS events (og-script.md §14.1): who hears what, in subscription order
    /// (`subscribe`, `emit`); a save keeps them (world/saved.zig `subs`).
    subs: std.ArrayList(Sub) = .empty,
    /// Stand-ins of objects of other locations (`farRef`), by `location::name` lower-case.
    far_objects: std.StringHashMapUnmanaged(*Object) = .empty,
    far_class: ?*Class = null,
    /// The object whose OGS code called the running builtin (a component instance in a
    /// method): `Subscribe` subscribes it.
    caller: ?*Object = null,
    /// `emit`s running one inside another.
    emit_depth: u32 = 0,

    const LiftKey = struct { cls: *const Class, func: *const Func };
    const Lifted = struct { gen: u32, l: ?lift.Lifted };

    const Natives = struct { ctx: *anyopaque, call: *const fn (ctx: *anyopaque, rt: *Runtime, o: *Object, name: []const u8, args: []const Value) anyerror!Value };
    const HostFields = struct { ctx: *anyopaque, get: *const fn (ctx: *anyopaque, rt: *Runtime, o: *Object, name: []const u8) ?Value };

    /// shortcut: the exe has no call depth limit (recursion overflows the stack); we
    /// return StackOverflow. Game scripts don't recurse.
    const max_depth = 64;
    /// An `Emit` inside a handler is allowed this deep; deeper faults (a handler that
    /// emits its own event would otherwise run until max_depth).
    pub const max_emit_depth = 8;

    /// Component instance `inst`'s method (interned id `handler`) hears `event`.
    pub const Sub = struct { event: []const u8, inst: *Object, handler: u32 };

    pub fn init(gpa: Allocator, source: SourceProvider) Runtime {
        return .{ .gpa = gpa, .arena_state = .init(gpa), .strings_state = .init(gpa), .source = source };
    }

    pub fn deinit(self: *Runtime) void {
        self.strings_state.deinit();
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn arena(self: *Runtime) Allocator {
        return self.arena_state.allocator();
    }

    pub fn strings(self: *Runtime) Allocator {
        return self.strings_state.allocator();
    }

    fn lower(self: *Runtime, s: []const u8) Allocator.Error![]const u8 {
        return std.ascii.allocLowerString(self.arena(), s);
    }

    pub fn registerBuiltin(self: *Runtime, name: []const u8, ctx: *anyopaque, func: BuiltinFn) Allocator.Error!void {
        try self.registerBuiltinSig(name, ctx, func, .{});
    }

    pub fn registerBuiltinSig(self: *Runtime, name: []const u8, ctx: *anyopaque, func: BuiltinFn, sig: Sig) Allocator.Error!void {
        const id = try object.intern(name);
        try self.builtins.put(self.arena(), id, .{ .name = name, .ctx = ctx, .func = func, .sig = sig });
        if (sig.classic) return;
        const gop = try self.ogs_names.getOrPut(self.arena(), if (sig.ogs.len > 0) sig.ogs else name);
        if (!gop.found_existing) gop.value_ptr.* = id;
    }

    /// The builtins by both languages' names (`classic/rename.zig`).
    pub fn names(self: *Runtime) rename.Names {
        return .{ .ctx = self, .classic = namesClassic, .ogs = namesOgs };
    }

    fn namesClassic(ctx: *anyopaque, id: u32) ?rename.Info {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        // A script function of that name wins over the builtin (any class may define it).
        if (self.fn_names.contains(id)) return null;
        return namesBuiltin(ctx, id);
    }

    /// The builtins by id, whether or not a script function has the name too: the
    /// converter (`classic/ogsify.zig`) knows which functions each class has.
    pub fn builtinNames(self: *Runtime) rename.Names {
        return .{ .ctx = self, .classic = namesBuiltin, .ogs = namesOgs };
    }

    fn namesBuiltin(ctx: *anyopaque, id: u32) ?rename.Info {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        const b = self.builtins.get(id) orelse return null;
        return .{ .exe = b.name, .ogs = if (b.sig.classic) "" else if (b.sig.ogs.len > 0) b.sig.ogs else b.name, .this = b.sig.this, .sig = b.sig.text, .pure = b.sig.pure };
    }

    fn namesOgs(ctx: *anyopaque, path: []const u8) ?rename.Info {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        const id = self.ogs_names.get(path) orelse return null;
        return namesClassic(ctx, id);
    }

    // ---------------------------------------------------------------- loading

    const Loaded = import.Loaded;

    /// Parse tree of a file (cached by lower-case name); a parse error fills `diag`.
    fn parseUnit(self: *Runtime, file: []const u8, diag: *parser.Diagnostic) Error!Loaded {
        const key = try self.lower(file);
        if (self.units.get(key)) |u| return .{ .unit = u, .key = key };
        const src = (self.source.fetch(self.source.ctx, file) catch return error.ScriptNotFound) orelse return error.ScriptNotFound;
        const unit = try parser.parse(self.arena(), src, diag);
        try self.units.put(self.arena(), key, unit);
        return .{ .unit = unit, .key = key };
    }

    fn loadUnit(self: *Runtime, file: []const u8) Error!Loaded {
        return self.parseUnit(file, &self.diag) catch |err| {
            if (err != error.ScriptNotFound and err != error.OutOfMemory) self.diag.file = try self.lower(file);
            return err;
        };
    }

    /// Class from a script file. `#inherit X` → `x.s`.
    pub fn loadClass(self: *Runtime, file: []const u8) Error!*Class {
        const key = try self.lower(file);
        if (self.classes.get(key)) |c| return c;
        const cls = try self.arena().create(Class);
        cls.* = .{ .name = key, .parent = null, .loading = true };
        // Register first so cyclic inheritance doesn't recurse.
        try self.classes.put(self.arena(), key, cls);
        // Text not found: don't leave an empty class behind (a retry would return it).
        errdefer _ = self.classes.remove(key);
        const loaded = try self.loadUnit(file);
        try self.addItems(cls, loaded.unit, loaded.key, 0);
        cls.loading = false;
        return cls;
    }

    fn addItems(self: *Runtime, cls: *Class, unit: ast.Unit, file: []const u8, depth: u32) Error!void {
        if (depth > 16) return error.IncludeCycle;
        if (names_classic.Host.ofFile(file)) |h| cls.host = names_classic.Host.deeper(cls.host, h);
        for (unit.items) |*it| switch (it.*) {
            .inherit => |name| {
                const pfile = if (std.fs.path.extension(name).len > 0) name else try std.fmt.allocPrint(self.arena(), "{s}.s", .{name});
                const p = try self.loadClass(pfile);
                if (!p.loading) cls.parent = p;
                if (p.host) |h| cls.host = names_classic.Host.deeper(cls.host, h);
                // #inherit is an insertion at this point too: ancestors' variables and functions
                // come before the class's later definitions (the parent has collected its own
                // #inherit already). Each of several #inherit lines inserts its own.
                try cls.vars.appendSlice(self.arena(), p.vars.items);
                var fit = p.functions.iterator();
                while (fit.next()) |e| {
                    const gop = try cls.functions.getOrPut(self.arena(), e.key_ptr.*);
                    if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.*;
                }
            },
            // Top-level `#include` is a text insertion into the same class.
            .include => |name| {
                const inc = try self.loadUnit(name);
                try self.addItems(cls, inc.unit, inc.key, depth + 1);
            },
            .var_decl => |d| try cls.vars.append(self.arena(), d),
            // The first definition wins (text insertion in the exe): Headnail gets post_init
            // from Headnail.s, not the empty one from .ftr.
            .function => |*f| {
                const id = try object.intern(f.name);
                const name_gop = try self.fn_names.getOrPut(self.arena(), id);
                if (!name_gop.found_existing and self.builtins.contains(id)) self.ir_gen +%= 1;
                const gop = try cls.functions.getOrPut(self.arena(), id);
                if (!gop.found_existing) {
                    const func = try self.arena().create(Func);
                    func.* = .{ .ast = f, .file = file, .class = cls };
                    gop.value_ptr.* = func;
                }
            },
            // Top-level statements only occur in `.ss` snippets included inside functions.
            .stmt => {},
        };
    }

    /// Creates an object with the class variables (inherited ones included) at their defaults.
    pub fn createObject(self: *Runtime, name: []const u8, cls: *Class) Allocator.Error!*Object {
        const obj = try self.createDetached(name, cls);
        try self.objects.append(self.arena(), obj);
        const gop = try self.by_name.getOrPut(self.arena(), try self.lower(name));
        if (!gop.found_existing) gop.value_ptr.* = obj;
        return obj;
    }

    /// An object the runtime calls but never lists (no findObject, no walks over
    /// `objects`): the OpenGorky hooks.
    pub fn createDetached(self: *Runtime, name: []const u8, cls: *Class) Allocator.Error!*Object {
        const obj = try self.arena().create(Object);
        obj.* = .{ .name = try self.arena().dupe(u8, name), .class = cls };
        try self.declareVars(obj, cls);
        return obj;
    }

    /// Change an object's class (ACTOR_MORPH): new class variables are added, old
    /// values stay.
    pub fn morph(self: *Runtime, obj: *Object, cls: *Class) Allocator.Error!void {
        obj.class = cls;
        try self.declareVars(obj, cls);
    }

    fn declareVars(self: *Runtime, obj: *Object, cls: *Class) Allocator.Error!void {
        var buf: [128]u8 = undefined;
        for (cls.vars.items) |d| {
            const n = cls.varName(d);
            const lname = if (n.len <= buf.len) std.ascii.lowerString(&buf, n) else try self.lower(n);
            try obj.declare(self.arena(), lname, .{ .type = d.type, .value = .initial(d.type) });
        }
    }

    pub fn findObject(self: *Runtime, name: []const u8) ?*Object {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) {
            for (self.objects.items) |o| if (std.ascii.eqlIgnoreCase(o.name, name)) return o;
            return null;
        }
        return self.by_name.get(std.ascii.lowerString(&buf, name));
    }

    /// Values from `.var` (0x431ee0): declared int and float only.
    pub fn applyVar(self: *Runtime, obj: *Object, name: []const u8, text: []const u8) void {
        _ = self;
        const v = obj.getVarDyn(names_classic.engine(obj.class.host, name)) orelse return;
        v.value = Value.parse(text, v.type) orelse return;
    }

    /// IR of a class function, compiled on first use. Not kept while an include is
    /// missing: a later call retries it, as the exe's loader would see a source added since.
    pub fn compiled(self: *Runtime, func: *Func) Allocator.Error!*const ir.Fn {
        if (func.ast == null) return func.ir.?;
        if (func.ir) |f| if (func.gen == self.ir_gen) return f;
        const r = try import.function(self.arena(), self.gpa, self.importEnv(), func);
        if (r.complete) {
            func.ir = r.ir;
            func.gen = self.ir_gen;
        }
        return r.ir;
    }

    /// The importer's view of this runtime: its sources (parse trees cached) and builtins.
    pub fn importEnv(self: *Runtime) import.Env {
        return .{ .ctx = self, .unit = envUnit, .callee = envCallee };
    }

    fn envUnit(ctx: *anyopaque, file: []const u8, diag: *parser.Diagnostic) anyerror!Loaded {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        return self.parseUnit(file, diag);
    }

    fn envCallee(ctx: *anyopaque, id: u32) import.Callee {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        // A script function of that name wins over the builtin (any class may define it).
        if (self.fn_names.contains(id)) return .{};
        const b = self.builtins.get(id) orelse return .{};
        return .{ .int = b.sig.returnsInt(), .pure = b.sig.pure, .data = b.sig.data };
    }

    // ---------------------------------------------------------------- calls

    /// Calls a script function by name if it exists; null if there is none.
    pub fn callIfExists(self: *Runtime, obj: *Object, name: []const u8, args: []const Value) Error!?Value {
        const id = object.findAnyCase(name) orelse return null;
        const f = obj.class.findFunctionId(id) orelse {
            const c = byName(obj, id, name) orelse return null;
            return try self.callScript(c.inst, c.func, args);
        };
        if (!answers(f, name)) return null;
        return try self.callScript(obj, f, args);
    }

    /// `componentWith` for the exe's call by name of a function that is no hook or fighter
    /// event (those the engine dispatches to the components itself, after the host's own).
    fn byName(host: *const Object, id: u32, name: []const u8) ?ComponentMethod {
        if (traits.hook(name) != null or traits.event(name) != null) return null;
        return componentWith(host, id, null);
    }

    const ComponentMethod = struct { inst: *Object, func: *Func };

    /// The first OGS component of `host` (not `skip`) with a method `id` (any case, as the exe calls a
    /// script's function by name): a converted object's Classic-named methods (`Take`,
    /// `Open`, `GO_RunFun`'s, `host.f()`) Null: none.
    fn componentWith(host: *const Object, id: u32, skip: ?*const Object) ?ComponentMethod {
        for (host.components.items) |c| {
            if (c.class.component == null or c == skip) continue;
            if (c.class.findFunctionId(id)) |f| return .{ .inst = c, .func = f };
        }
        return null;
    }

    /// Same for a comptime-known name (`update` of every object every tick): the id is
    /// looked up once per call site.
    pub fn callIfExistsC(self: *Runtime, obj: *Object, comptime name: []const u8, args: []const Value) Error!?Value {
        // The struct must capture `name`, or every call site would share one cache.
        const S = struct {
            const key = blk: {
                var buf: [name.len]u8 = undefined;
                for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                const final = buf;
                break :blk &final;
            };
            var id: ?u32 = null;
        };
        const id = S.id orelse blk: {
            const found = object.findName(S.key) orelse return null;
            S.id = found;
            break :blk found;
        };
        return self.callIfExistsId(obj, id, name, args);
    }

    /// Same for name `name` of interned id `id` (a built-in method's: traits.Method.name_id).
    pub fn callIfExistsId(self: *Runtime, obj: *Object, id: u32, name: []const u8, args: []const Value) Error!?Value {
        const f = obj.class.findFunctionId(id) orelse {
            const c = byName(obj, id, name) orelse return null;
            return try self.callScript(c.inst, c.func, args);
        };
        if (!answers(f, name)) return null;
        return try self.callScript(obj, f, args);
    }

    /// Function `f` (found by its name in any case) is called `name`: a Classic name ignores
    /// case, an OGS one is exact.
    fn answers(f: *const Func, name: []const u8) bool {
        return f.ast != null or std.mem.eql(u8, f.ir.?.name, name);
    }

    fn callScript(self: *Runtime, obj: *Object, func: *Func, args: []const Value) Error!Value {
        if (self.depth >= max_depth) return error.StackOverflow;
        if (self.depth == 0) self.top_call += 1;
        if (self.lift and func.ast != null and lift.isEvent(func.ast.?.name)) if (try self.liftedOf(obj.class, func)) |l| return self.runLifted(obj, l, args);
        return self.run(obj, try self.compiled(func), args, &.{});
    }

    /// Pass 3 of a creation event of `cls`; null: nothing lifted, or its IR is not kept
    /// (an include missing), so it runs as code.
    fn liftedOf(self: *Runtime, cls: *const Class, func: *Func) Error!?lift.Lifted {
        const f = try self.compiled(func);
        if (func.ir != f) return null;
        const gop = try self.lifted.getOrPut(self.arena(), .{ .cls = cls, .func = func });
        if (gop.found_existing and gop.value_ptr.gen == func.gen) return gop.value_ptr.l;
        const l = try lift.lift(self.arena(), self.importEnv(), f, cls);
        gop.value_ptr.* = .{ .gen = func.gen, .l = if (l.items.len > 0) l else null };
        return gop.value_ptr.l;
    }

    /// The lifted model of an event, then its rest: each item as its statement ran (a
    /// field converted to the variable's type, skipped if the object lacks it; a builtin
    /// called with the values), in the body's order.
    fn runLifted(self: *Runtime, obj: *Object, l: lift.Lifted, args: []const Value) Error!Value {
        {
            self.depth += 1;
            defer self.depth -= 1;
            var frame: Frame = .{ .obj = obj, .slots = &.{}, .f = l.rest };
            for (l.items) |it| switch (it) {
                .field => |x| {
                    const v = obj.getVarId(x.id) orelse {
                        try self.count(&self.unknown_names, x.name);
                        continue;
                    };
                    v.value = try x.value.convert(v.type, self.strings());
                },
                .call => |c| _ = try self.callNamed(&frame, c.id, c.name, c.args),
            };
        }
        return self.run(obj, l.rest, args, &.{});
    }

    /// An argument by parameter name (OGS).
    pub const NamedValue = struct { name: []const u8, value: Value };

    /// `f` on `obj`: positional `args`, then `named`; a parameter left out gets its
    /// default (evaluated in the callee), else its type's initial value.
    fn run(self: *Runtime, obj: *Object, f: *const ir.Fn, args: []const Value, named: []const NamedValue) Error!Value {
        if (self.depth >= max_depth) return error.StackOverflow;
        self.depth += 1;
        defer self.depth -= 1;
        // The first slots live on the stack without allocation; more go to the heap.
        var inline_buf: [16]Slot = undefined;
        const slots = if (f.slots <= inline_buf.len) inline_buf[0..f.slots] else try self.gpa.alloc(Slot, f.slots);
        defer if (f.slots > inline_buf.len) self.gpa.free(slots);
        for (slots) |*s| s.* = .{ .declared = false, .v = .{ .type = .any, .value = .nil } };
        var frame: Frame = .{ .obj = obj, .slots = slots, .f = f, .ret = if (f.ogs) .nil else .zero };
        for (f.params, 0..) |p, i| {
            var given: ?Value = if (i < args.len) args[i] else null;
            for (named) |n| if (std.mem.eql(u8, n.name, p.name)) {
                given = n.value;
            };
            if (given == null) if (p.default) |d| {
                given = try self.eval(&frame, d);
            };
            const v = if (given) |g| try g.convert(p.type, self.strings()) else Value.initial(p.type);
            // A parameter of a trait (a script trait, a host kind, a role, a mark) is checked.
            if (p.resolved) |r| if (v != .nil and !self.isTrait(v, r.*)) return self.failAt(&frame, "{s}: {s} is not {s}", .{ f.name, p.name, r.name() });
            slots[p.slot] = .{ .declared = true, .v = .{ .type = p.type, .value = v } };
        }
        _ = try self.exec(&frame, f.body);
        return frame.ret;
    }

    fn call(self: *Runtime, frame: *Frame, c: ir.Call) Error!Value {
        // Arguments go into 0x108 bytes of stack at 0x4e3b80, 8 bytes each plus a zero
        // terminator: up to 32. shortcut: beyond 32 the exe corrupts its stack; we return 0
        // unevaluated (OGS: a fault).
        var args_buf: [32]Value = undefined;
        if (c.args.len > args_buf.len) return if (frame.ogs()) self.failAt(frame, "{s}: more than {d} arguments", .{ c.text, args_buf.len }) else .zero;
        for (c.args, 0..) |a, i| args_buf[i] = try self.eval(frame, a);
        const args = args_buf[0..c.args.len];

        if (c.target) |t| return self.callOgs(frame, t.*, args, c);
        return self.callNamed(frame, c.id, c.text, args);
    }

    /// A Classic call with its arguments evaluated.
    fn callNamed(self: *Runtime, frame: *Frame, id: u32, text: []const u8, args: []const Value) Error!Value {
        // shortcut: names longer than 128 give 0 (the exe has no limit; game names are under 40).
        if (text.len > 128) return .zero;
        if (frame.obj.class.findFunctionId(id)) |f| return self.callScript(frame.obj, f, args);
        if (self.builtins.get(id)) |b| {
            const was = self.ogs_call;
            self.ogs_call = false;
            defer self.ogs_call = was;
            return builtinResult(frame, b, b.func(b.ctx, self, frame.obj, args) catch |err| blk: {
                std.log.warn("builtin {s}: {t}", .{ text, err });
                break :blk .zero;
            });
        }
        try self.count(&self.missing_builtins, text);
        return .zero;
    }

    fn count(self: *Runtime, map: *std.StringArrayHashMapUnmanaged(u32), name: []const u8) Allocator.Error!void {
        const gop = try map.getOrPut(self.arena(), name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    // ---------------------------------------------------------------- execution

    const Slot = struct { declared: bool, v: Var };

    const Frame = struct {
        obj: *Object,
        slots: []Slot,
        ret: Value = .zero,
        f: ?*const ir.Fn = null,
        /// Line of the expression being evaluated (for `fault`).
        line: u32 = 0,

        /// OGS semantics (`ir.Fn.ogs`); no function: a component's defaults or a data
        /// block, both OGS.
        fn ogs(self: *const Frame) bool {
            return if (self.f) |f| f.ogs else true;
        }

        /// The dialect's truth value: OGS `bool`, Classic int 0/1.
        fn truth(self: *const Frame, b: bool) Value {
            return if (self.ogs()) .{ .bool = b } else .{ .int = @intFromBool(b) };
        }

        /// A slot whose declaration has run.
        fn declared(self: *Frame, slot: ?u16) ?*Var {
            const s = &self.slots[slot orelse return null];
            return if (s.declared) &s.v else null;
        }
    };

    const Flow = enum { normal, returned, broke, continued };

    fn exec(self: *Runtime, frame: *Frame, body: []const ir.Stmt) Error!Flow {
        for (body) |*st| switch (st.kind) {
            .expr => |e| _ = try self.eval(frame, e),
            .local => |l| frame.slots[l.slot] = .{ .declared = true, .v = .{ .type = l.type, .value = .initial(l.type) } },
            .assign => |a| _ = try self.assign(frame, a, try self.eval(frame, a.value)),
            .@"if" => |i| {
                const branch = if ((try self.eval(frame, i.cond)).truth()) i.then else i.@"else";
                const flow = try self.exec(frame, branch);
                if (flow != .normal) return flow;
            },
            .@"return" => |e| {
                frame.ret = try self.eval(frame, e);
                return .returned;
            },
            .@"while" => |w| while ((try self.eval(frame, w.cond)).truth()) switch (try self.exec(frame, w.body)) {
                .returned => return .returned,
                .broke => break,
                .normal, .continued => {},
            },
            .for_in => |x| if (try self.forIn(frame, x) == .returned) return .returned,
            .@"break" => return .broke,
            .@"continue" => return .continued,
            .fail => |f| {
                if (f.err != error.ScriptNotFound and f.err != error.IncludeCycle) self.diag = .{ .file = f.file, .line = f.line, .message = f.message };
                return @errorCast(f.err);
            },
        };
        return .normal;
    }

    fn assign(self: *Runtime, frame: *Frame, a: ir.Assign, v: Value) Error!Value {
        const field_name: []const u8 = switch (a.target) {
            .local => "",
            .name => |n| n.text,
            .field => |x| x.text,
            .member => |m| m.text,
        };
        const target = switch (a.target) {
            .local => |s| &frame.slots[s].v,
            .name => |n| frame.declared(n.slot) orelse frame.obj.getVarId(n.id) orelse {
                // Undeclared variable (0x44ae80): "Cannot find variable", the assignment is skipped.
                try self.count(&self.unknown_names, n.text);
                return v;
            },
            .field => |x| self.fieldVar(frame.obj, x.id) orelse return self.failAt(frame, "no field or host variable {s}", .{x.text}),
            .member => |m| blk: {
                const o = try self.refOf(frame, try self.eval(frame, m.obj));
                if (isNameField(m.text)) return self.failAt(frame, "{s}.{s} is read-only", .{ o.name, m.text });
                break :blk o.getVarId(m.id) orelse return self.failAt(frame, "{s} has no variable {s}", .{ o.name, m.text });
            },
        };
        const stored = switch (a.op) {
            .set => v,
            .add => try self.binary(frame, .add, target.value, v),
            .sub => try self.binary(frame, .sub, target.value, v),
        };
        if (stored == .string and target.type == .int and field_name.len > 0) if (self.field_words) |fw| if (fw(field_name, stored.string)) |n| {
            target.value = .{ .int = n };
            return target.value;
        };
        target.value = try stored.convert(target.type, self.strings());
        return target.value;
    }

    /// `obj.name`: the computed field of every ref (object variables ignore case).
    fn isNameField(text: []const u8) bool {
        return std.ascii.eqlIgnoreCase(text, "name");
    }

    /// A component instance's field, else its host's variable.
    fn fieldVar(self: *Runtime, obj: *Object, id: u32) ?*Var {
        _ = self;
        if (obj.getVarId(id)) |v| return v;
        return (obj.owner orelse return null).getVarId(id);
    }

    fn failAt(self: *Runtime, frame: *const Frame, comptime fmt: []const u8, args: anytype) Error {
        self.fault = .{ .file = if (frame.f) |f| f.file else "", .line = frame.line, .message = try std.fmt.allocPrint(self.strings(), fmt, args) };
        return error.ScriptFault;
    }

    fn refOf(self: *Runtime, frame: *const Frame, v: Value) Error!*Object {
        return switch (v) {
            .ref => |h| Object.of(h),
            else => self.failAt(frame, "{f} is no object", .{v}),
        };
    }

    /// OGS operators: numbers as `ir.binary`, two strings joined by `+`; another mix faults.
    /// A comparison gives the frame's truth value.
    fn binary(self: *Runtime, frame: *const Frame, op: ir.BinaryOp, lhs: Value, rhs: Value) Error!Value {
        if (op == .eq or op == .ne or (ir.numeric(lhs) and ir.numeric(rhs))) {
            const v = ir.binary(op, lhs, rhs);
            return switch (op) {
                .add, .sub, .mul, .div, .mod => v,
                .eq, .ne, .lt, .le, .gt, .ge => frame.truth(v.truth()),
            };
        }
        if (op == .add and lhs == .string and rhs == .string) return .{ .string = try std.mem.concat(self.strings(), u8, &.{ lhs.string, rhs.string }) };
        return self.failAt(frame, "{f} {t} {f}", .{ lhs, op, rhs });
    }

    fn forIn(self: *Runtime, frame: *Frame, x: ir.ForIn) Error!Flow {
        const from = try self.eval(frame, x.iter);
        const slot = &frame.slots[x.slot];
        if (x.to) |t| {
            const end = try self.eval(frame, t);
            if (from != .int or end != .int) return self.failAt(frame, "a range is of ints: {f}..{f}", .{ from, end });
            var i = from.int;
            while (i < end.int) : (i += 1) {
                slot.* = .{ .declared = true, .v = .{ .type = .any, .value = .{ .int = i } } };
                switch (try self.exec(frame, x.body)) {
                    .returned => return .returned,
                    .broke => break,
                    .normal, .continued => {},
                }
            }
            return .normal;
        }
        const items = switch (from) {
            .list => |l| l,
            .map => |m| m.keys,
            else => return self.failAt(frame, "for over {f}", .{from}),
        };
        for (items) |v| {
            slot.* = .{ .declared = true, .v = .{ .type = .any, .value = v } };
            switch (try self.exec(frame, x.body)) {
                .returned => return .returned,
                .broke => break,
                .normal, .continued => {},
            }
        }
        return .normal;
    }

    /// An OGS call (`ogs/link.zig` resolved it): a script function on the caller's object,
    /// a builtin called for the host (a component's own name is no game object).
    fn callOgs(self: *Runtime, frame: *Frame, t: ir.Callee, args: []const Value, c: ir.Call) Error!Value {
        switch (t) {
            .unresolved => return self.failAt(frame, "{s}: not linked", .{c.text}),
            .make => |st| return self.make(frame, st, c),
            .enum_from => |en| {
                if (args.len != 1 or args[0] != .string) return .nil;
                const v = en.value(args[0].string) orelse return .nil;
                return .{ .string = v.name };
            },
            .func => |f| return self.runNamed(frame, frame.obj, f, args, c.named, c.text),
            // The component's table has every method of its traits (`attach`).
            .virtual => {
                const func = frame.obj.class.findFunctionId(c.id) orelse return self.failAt(frame, "{s} has no method {s}", .{ frame.obj.name, c.text });
                return self.runNamed(frame, frame.obj, try self.compiled(func), args, c.named, c.text);
            },
            .trait_default => |d| {
                const body = d.body orelse return .nil;
                const r = d.trait orelse return self.runNamed(frame, frame.obj, body, args, c.named, c.text);
                // The instance itself (not a host with one attached) implements it.
                if (args[0] != .ref or !self.implements(Object.of(args[0].ref), r)) return self.failAt(frame, "{s}: self is not {s}", .{ c.text, r.name() });
                return self.runNamed(frame, Object.of(args[0].ref), body, args[1..], c.named, c.text);
            },
            .builtin => |bc| {
                const b = self.builtins.get(bc.id) orelse return self.failAt(frame, "{s}: no builtin", .{c.text});
                // Named arguments at their positions (link checked there is no gap).
                var all: [32]Value = undefined;
                @memcpy(all[0..args.len], args);
                var n = args.len;
                for (c.named, bc.slots) |x, k| {
                    all[k] = try self.eval(frame, x.value);
                    n = @max(n, k + 1);
                }
                // Handlers take Classic values: OGS `true`/`false` become int 1/0, an object
                // its name (a component instance: its host's), as a Classic script names it.
                for (all[0..n], 0..) |*v, i| switch (v.*) {
                    .bool => if (!b.sig.takesAsIs(i)) {
                        v.* = .{ .int = @intFromBool(v.truth()) };
                    },
                    .ref => |h| if (!b.sig.takesAny(i)) {
                        const o = Object.of(h);
                        v.* = .{ .string = (o.owner orelse o).name };
                    },
                    else => {},
                };
                const was = self.ogs_call;
                self.ogs_call = true;
                defer self.ogs_call = was;
                const prev = self.caller;
                self.caller = frame.obj;
                defer self.caller = prev;
                const r = b.func(b.ctx, self, frame.obj.owner orelse frame.obj, all[0..n]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return self.failAt(frame, "{s}: {t}", .{ c.text, err }),
                };
                return builtinResult(frame, b, r);
            },
        }
    }

    /// A value of struct `st` (`Wave(turn = 3)`): a map of its fields by name, in its
    /// order, each the value given else its default, of its type. `@name` given to an
    /// `object` or `string` field is the name (the object may not be made yet:
    /// `Place(who = @Medusa)` before she joins).
    fn make(self: *Runtime, frame: *Frame, st: *const ir.Struct, c: ir.Call) Error!Value {
        const keys = try self.strings().alloc(Value, st.fields.len);
        const values = try self.strings().alloc(Value, st.fields.len);
        for (st.fields, keys, values) |f, *k, *v| {
            k.* = .{ .string = f.name };
            const given = for (c.named) |n| {
                if (std.mem.eql(u8, n.name, f.name)) break n.value;
            } else f.default;
            const e = given orelse {
                v.* = .initial(f.type);
                continue;
            };
            const x = if (e.kind == .ref and (f.type == .object or f.type == .string)) Value{ .string = e.kind.ref } else try self.eval(frame, e);
            v.* = try x.convert(f.type, self.strings());
        }
        const out = try self.strings().create(Value.Map);
        out.* = .{ .keys = keys, .values = values };
        return .{ .map = out };
    }

    /// `f` on `obj` called as `text` with `args` and the `named` ones evaluated here.
    fn runNamed(self: *Runtime, frame: *Frame, obj: *Object, f: *const ir.Fn, args: []const Value, named: []const ir.Named, text: []const u8) Error!Value {
        var named_buf: [16]NamedValue = undefined;
        if (named.len > named_buf.len) return self.failAt(frame, "{s}: too many named arguments", .{text});
        for (named, 0..) |n, i| named_buf[i] = .{ .name = n.name, .value = try self.eval(frame, n.value) };
        return self.run(obj, f, args, named_buf[0..named.len]);
    }

    /// The component of instance `o` implements trait `r` (its link table says so), or is
    /// the native component `r` names.
    fn implements(self: *Runtime, o: *const Object, r: ir.TraitRef) bool {
        if (r == .native) return if (o.class.native) |n| std.mem.eql(u8, n.name, r.native) else false;
        const comp = o.class.component orelse return false;
        const t = self.ogs.tables.get(comp) orelse return false;
        for (t.traits) |x| if (x.eql(r)) return true;
        return false;
    }

    /// `v is T`: a role the object (an instance: its host) has now; its
    /// host kind (`Object.kind`: `Fighter`, `Item`, their supertraits); a mark or method bit
    /// of its active components (`Object.implements`); else a component instance
    /// implementing `T`, or an object with an active one attached.
    pub fn isTrait(self: *Runtime, v: Value, r: ir.TraitRef) bool {
        if (r == .unresolved) return true;
        if (v != .ref) return false;
        const o = Object.of(v.ref);
        if (r == .engine) if (traits.find(r.engine)) |t| switch (t.kind) {
            .role => return (o.owner orelse o).roles.contains(traits.Role.of(t.name).?),
            .mark => if (o.implements.isSet(traits.bitOf(t.name).?)) return true,
            .host => if (o.kind) |k| if (traits.isA(k, t.name)) return true,
        };
        if (self.implements(o, r)) return true;
        for (o.components.items) |c| if (c.activeOn(o) and self.implements(c, r)) return true;
        return false;
    }

    /// `o.f(…)` where `f` is an engine method (`native fn`) of a trait `o`
    /// is (`host.as(Hero).party_slot()`): the host answers (`natives`; none: nil).
    fn native(self: *Runtime, frame: *Frame, o: *Object, m: *const ir.Method) Error!Value {
        const t = traits.nativeOwner(m.text) orelse return self.failAt(frame, "{s} has no function {s}", .{ o.name, m.text });
        if (!self.isTrait(o.ref(), .{ .engine = t.name })) return self.failAt(frame, "{s}: {s} is not {s}", .{ m.text, o.name, t.name });
        const n = t.own(m.text).?.arity();
        if (m.args.len != n or m.named.len > 0) return self.failAt(frame, "{s} takes {d} arguments", .{ m.text, n });
        const h = self.natives orelse return .nil;
        const args = try self.evalAll(frame, m.args);
        return h.call(h.ctx, self, o.owner orelse o, m.text, args) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => self.failAt(frame, "{s}: {t}", .{ m.text, err }),
        };
    }

    /// `x is T`, `x.as(T)`, `x.get(T)`, `x.all(T)`.
    fn traitOp(self: *Runtime, frame: *Frame, t: ir.TraitOp) Error!Value {
        const v = try self.eval(frame, t.obj);
        const r = t.resolved.*;
        switch (t.op) {
            .is => return frame.truth(self.isTrait(v, r)),
            .as => return if (self.isTrait(v, r)) v else .nil,
            .get, .all => {
                const o = try self.refOf(frame, v);
                var out: std.ArrayList(Value) = .empty;
                for (o.components.items) |c| if (c.activeOn(o) and self.implements(c, r)) {
                    if (t.op == .get) return c.ref();
                    try out.append(self.strings(), c.ref());
                };
                return if (t.op == .get) .nil else .{ .list = out.items };
            },
        }
    }

    /// A `bool(...)` builtin's int 1/0 as the caller's dialect has it (`Frame.truth`).
    fn builtinResult(frame: *const Frame, b: Builtin, v: Value) Value {
        return if (b.sig.returnsBool() and v == .int) frame.truth(v.int != 0) else v;
    }

    fn evalAll(self: *Runtime, frame: *Frame, list: []const *const ir.Expr) Error![]Value {
        const out = try self.strings().alloc(Value, list.len);
        for (list, out) |e, *o| o.* = try self.eval(frame, e);
        return out;
    }

    fn eval(self: *Runtime, frame: *Frame, e: *const ir.Expr) Error!Value {
        frame.line = e.line;
        return switch (e.kind) {
            .lit => |v| v,
            .local => |s| frame.slots[s].v.value,
            .name => |n| blk: {
                if (frame.declared(n.slot)) |v| break :blk v.value;
                if (frame.obj.getVarId(n.id)) |v| break :blk v.value;
                if (n.this) break :blk .{ .string = frame.obj.name };
                // A scenario object's name refers to it (0x44b130).
                if (self.findObject(n.text)) |o| break :blk .{ .string = o.name };
                try self.count(&self.unknown_names, n.text);
                break :blk .zero;
            },
            .call => |c| try self.call(frame, c),
            .exe => |x| blk: {
                // Right to left, as the exe (0x4e3620).
                var args: [2]Value = undefined;
                var i = x.args.len;
                while (i > 0) {
                    i -= 1;
                    args[i] = try self.eval(frame, x.args[i]);
                }
                break :blk exe.call(x.op, args[0..x.args.len]);
            },
            .unary => |u| blk: {
                const v = try self.eval(frame, u.operand);
                break :blk switch (u.op) {
                    .neg => if (ir.numeric(v)) ir.neg(v) else return self.failAt(frame, "-{f}", .{v}),
                    .not => frame.truth(!v.truth()),
                };
            },
            .binary => |b| blk: {
                const lhs = try self.eval(frame, b.lhs);
                const rhs = try self.eval(frame, b.rhs);
                frame.line = e.line;
                break :blk try self.binary(frame, b.op, lhs, rhs);
            },
            .logic => |l| blk: {
                const lhs = (try self.eval(frame, l.lhs)).truth();
                const r = switch (l.op) {
                    .@"and" => lhs and (try self.eval(frame, l.rhs)).truth(),
                    .@"or" => lhs or (try self.eval(frame, l.rhs)).truth(),
                };
                break :blk frame.truth(r);
            },
            .assign => |a| try self.assign(frame, a.*, try self.eval(frame, a.value)),
            .field => |x| if (self.fieldVar(frame.obj, x.id)) |v| v.value else self.failAt(frame, "no field or host variable {s}", .{x.text}),
            .host => if (frame.obj.owner) |h| h.ref() else .nil,
            .self => frame.obj.ref(),
            .member => |m| blk: {
                const x = try self.eval(frame, m.obj);
                // A struct's field (`w.turn`).
                if (x == .map) {
                    for (x.map.keys, x.map.values) |k, v| if (k == .string and std.mem.eql(u8, k.string, m.text)) break :blk v;
                    return self.failAt(frame, "no field {s}", .{m.text});
                }
                const o = try self.refOf(frame, x);
                if (o.handle.far.len > 0) break :blk .nil;
                // `name`: the object's name, read-only (no variable shadows it).
                if (isNameField(m.text)) break :blk .{ .string = o.name };
                // No host schema here: a variable the object lacks is a computed
                // field, else nil.
                if (o.getVarId(m.id)) |v| break :blk v.value;
                const h = self.host_fields orelse break :blk .nil;
                break :blk h.get(h.ctx, self, o, m.text) orelse .nil;
            },
            .index => |x| blk: {
                const obj = try self.eval(frame, x.obj);
                const k = try self.eval(frame, x.key);
                switch (obj) {
                    .list => |l| {
                        if (k != .int or k.int < 0 or k.int >= l.len) return self.failAt(frame, "index {f} of a list of {d}", .{ k, l.len });
                        break :blk l[@intCast(k.int)];
                    },
                    .map => |m| {
                        for (m.keys, m.values) |mk, v| if (ir.binary(.eq, mk, k).truth()) break :blk v;
                        break :blk .nil;
                    },
                    else => return self.failAt(frame, "{f}[{f}]", .{ obj, k }),
                }
            },
            .list => |l| .{ .list = try self.evalAll(frame, l) },
            .map => |m| blk: {
                const out = try self.strings().create(Value.Map);
                out.* = .{ .keys = try self.evalAll(frame, m.keys), .values = try self.evalAll(frame, m.values) };
                break :blk .{ .map = out };
            },
            .ref => |n| if (self.findObject(n)) |o| o.ref() else .nil,
            .method => |m| blk: {
                var o = try self.refOf(frame, try self.eval(frame, m.obj));
                if (o.handle.far.len > 0) break :blk .nil;
                // `x.as(T).f()` of a component trait: `f` of `x.get(T)`.
                if (m.obj.kind == .trait_op and m.obj.kind.trait_op.op == .as) if (m.obj.kind.trait_op.resolved.* == .script and !self.implements(o, m.obj.kind.trait_op.resolved.*)) {
                    o = for (o.components.items) |c| {
                        if (c.activeOn(o) and self.implements(c, m.obj.kind.trait_op.resolved.*)) break c;
                    } else o;
                };
                const func = o.class.findFunctionId(m.id) orelse {
                    // A method of one of its other components (`host.PlaySoundAtFrame(…)`
                    // of a converted class); not `x.as(T).f()`, which names the trait's.
                    const other = if (m.obj.kind == .trait_op) null else componentWith(o, m.id, frame.obj);
                    const c = other orelse break :blk try self.native(frame, o, m);
                    break :blk try self.runNamed(frame, c.inst, try self.compiled(c.func), try self.evalAll(frame, m.args), m.named, m.text);
                };
                if (!answers(func, m.text)) return self.failAt(frame, "{s} has no function {s}", .{ o.name, m.text });
                break :blk try self.runNamed(frame, o, try self.compiled(func), try self.evalAll(frame, m.args), m.named, m.text);
            },
            // An enum's value (link checked it): its name (`Side::enemy` → "enemy"); a
            // block's path in data (`target = characters::grandma`): the path.
            .word => |w| .{ .string = self.wordValue(w) },
            .trait_op => |t| try self.traitOp(frame, t),
        };
    }

    // ---------------------------------------------------------------- OGS

    /// Adds OGS text `text` (`file`: for positions) to the program and links it (one text:
    /// `addOgs` and `linkOgs`).
    pub fn loadOgs(self: *Runtime, file: []const u8, text: []const u8) Error!void {
        try self.addOgs(file, text);
        try self.linkOgs();
    }

    /// Adds OGS text `text` to the program, not linked yet. A parse error, or a name
    /// defined twice, fills `diag`; nothing of such a text is added.
    pub fn addOgs(self: *Runtime, file: []const u8, text: []const u8) Error!void {
        const u = ogs_parser.parse(self.arena(), text, file, &self.diag) catch |err| {
            self.diag.file = file;
            return err;
        };
        return self.addOgsUnit(u);
    }

    /// Adds parsed OGS text `u` to the program, not linked yet (a name defined twice
    /// fills `diag`; nothing of it is added).
    pub fn addOgsUnit(self: *Runtime, u: ogs_parser.Unit) Error!void {
        var d: ogs_link.Diagnostic = .{};
        errdefer self.linkDiag(d);
        try self.ogs.add(self.arena(), u, &d);
    }

    /// Links the texts added since the last link against the whole program. A text that
    /// fails is dropped (its error in `diag`, error.LinkError): call again to
    /// link the others without it.
    pub fn linkOgs(self: *Runtime) Error!void {
        var d: ogs_link.Diagnostic = .{};
        errdefer self.linkDiag(d);
        try self.ogs.link(self.arena(), .{ .ctx = self, .builtin = envBuiltin, .schema = self.schema, .natives = self.natives_known }, &d);
    }

    fn linkDiag(self: *Runtime, d: ogs_link.Diagnostic) void {
        self.diag = .{ .file = d.file, .line = d.line, .message = d.message };
    }

    /// Builtin `name` by its OGS name; by its Classic one: where OGS has it (`moved`).
    fn envBuiltin(ctx: *anyopaque, name: []const u8) ?ogs_link.Builtin {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (self.ogs_names.get(name)) |id| return .{ .id = id, .sig = self.builtins.get(id).?.sig.text };
        const id = object.findAnyCase(name) orelse return null;
        const b = self.builtins.get(id) orelse return null;
        if (!std.mem.eql(u8, b.name, name)) return null;
        return .{ .id = id, .sig = b.sig.text, .moved = if (b.sig.classic) "" else b.sig.ogs };
    }

    /// An instance of `comp` attached to `host` (last in `host.components`): its fields at
    /// their defaults, then the `params` given (each a `param` of it).
    pub fn attach(self: *Runtime, host: *Object, comp: *const ir.Component, params: []const NamedValue) Error!*Object {
        const table = self.ogs.tables.get(comp);
        const gop = try self.comp_classes.getOrPut(self.arena(), comp);
        if (!gop.found_existing) {
            const cls = try self.arena().create(Class);
            cls.* = .{ .name = comp.name, .parent = null, .component = comp };
            // Its own methods and the default bodies of its traits.
            for (comp.methods) |m| try self.addMethod(cls, m);
            if (table) |t| {
                for (t.methods) |r| if (r.from != null) try self.addMethod(cls, r.f);
                for (t.traits) |r| if (r == .engine) if (traits.find(r.engine)) |et| if (et.kind == .mark) cls.marks.set(traits.bitOf(et.name).?);
            }
            gop.value_ptr.* = cls;
        }
        const obj = try self.arena().create(Object);
        obj.* = .{ .name = comp.name, .class = gop.value_ptr.*, .owner = host, .for_roles = if (table) |t| t.roles else .empty };
        var frame: Frame = .{ .obj = obj, .slots = &.{} };
        const fields = self.ogs.fieldsOf(comp);
        for (params) |p| for (fields) |f| {
            if (f.kind == .param and std.mem.eql(u8, f.name, p.name)) break;
        } else return self.failAt(&frame, "{s} has no param {s}", .{ comp.name, p.name });
        for (fields) |f| try obj.declare(self.arena(), object.nameOf(f.id), .{ .type = f.type, .value = .initial(f.type) });
        // In order: a param given, else the default (it sees the fields before it).
        for (fields) |f| {
            frame.line = f.line;
            const given = if (f.kind == .param) for (params) |p| {
                if (std.mem.eql(u8, f.name, p.name)) break p.value;
            } else null else null;
            var v = given orelse if (f.default) |d| try self.eval(&frame, d) else continue;
            // A trait's param: an object that is it, else nil.
            if (f.resolved) |r| if (v != .nil and !self.isTrait(v, r.*)) {
                std.log.warn("{s}.{s}: {s} is not {s} (nil)", .{ comp.name, f.name, if (v == .ref) Object.of(v.ref).name else "the value", r.name() });
                v = .nil;
            };
            obj.getVarId(f.id).?.value = try v.convert(f.type, self.strings());
        }
        try host.components.append(self.arena(), obj);
        host.refreshImplements();
        return obj;
    }

    /// An instance of native component `n` attached to `host` (last in `host.components`),
    /// its parameters `state` (the engine's record, `Object.host`).
    pub fn attachNative(self: *Runtime, host: *Object, n: *const object.Native, state: ?*anyopaque) Allocator.Error!*Object {
        const gop = try self.native_classes.getOrPut(self.arena(), n);
        if (!gop.found_existing) {
            const cls = try self.arena().create(Class);
            cls.* = .{ .name = n.name, .parent = null, .marks = n.bits, .native = n };
            gop.value_ptr.* = cls;
        }
        const obj = try self.arena().create(Object);
        obj.* = .{ .name = n.name, .class = gop.value_ptr.*, .owner = host, .host = state };
        try host.components.append(self.arena(), obj);
        host.refreshImplements();
        return obj;
    }

    /// Built-in method `method` of native component instance `inst` (its class implements
    /// it); an engine error is a fault (dispatch logs it).
    pub fn callNative(self: *Runtime, inst: *Object, method: []const u8, args: []Value) Error!?Value {
        const f = self.native_components orelse return null;
        return f(self, inst, inst.class.native.?.tag, method, args) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                self.fault = .{ .file = inst.name, .line = 0, .message = @errorName(err) };
                return error.ScriptFault;
            },
        };
    }

    // ---------------------------------------------------------------- events

    /// Component instance `inst` hears `event` with its method `handler` (after the
    /// earlier subscribers); false: it already does. A name `inst` has no method of is
    /// error.NoSuchMethod.
    pub fn subscribe(self: *Runtime, inst: *Object, event: []const u8, handler: []const u8) error{ OutOfMemory, NotInComponent, NoSuchMethod }!bool {
        if (inst.owner == null) return error.NotInComponent;
        const id = object.findAnyCase(handler) orelse return error.NoSuchMethod;
        const f = inst.class.findFunctionId(id) orelse return error.NoSuchMethod;
        if (!answers(f, handler)) return error.NoSuchMethod;
        for (self.subs.items) |s| if (s.inst == inst and s.handler == id and std.mem.eql(u8, s.event, event)) return false;
        try self.subs.append(self.arena(), .{ .event = try self.arena().dupe(u8, event), .inst = inst, .handler = id });
        return true;
    }

    /// A reference to object `name` of location `level` (not this world): its stand-in, one
    /// per object, so `==` holds between two of them; it has no variables and no methods
    /// (a field or a method of it is nil), the builtins get its name (no such object
    /// here). world/snapshot.zig attach makes it live again in its own location.
    pub fn farRef(self: *Runtime, level: []const u8, name: []const u8) Allocator.Error!Value {
        const key = try std.ascii.allocLowerString(self.arena(), try std.fmt.allocPrint(self.arena(), "{s}::{s}", .{ level, name }));
        const gop = try self.far_objects.getOrPut(self.arena(), key);
        if (!gop.found_existing) {
            const cls = self.far_class orelse blk: {
                const c = try self.arena().create(Class);
                c.* = .{ .name = "far", .parent = null };
                self.far_class = c;
                break :blk c;
            };
            const o = try self.arena().create(Object);
            o.* = .{ .name = try self.arena().dupe(u8, name), .class = cls, .enabled = false };
            o.handle.far = try self.arena().dupe(u8, level);
            gop.value_ptr.* = o;
        }
        return gop.value_ptr.*.ref();
    }

    /// `inst`'s subscriptions to `event` taken back (only the one with method `handler`
    /// when it is given); how many.
    pub fn unsubscribe(self: *Runtime, inst: *Object, event: []const u8, handler: ?[]const u8) usize {
        const id = if (handler) |h| object.findAnyCase(h) orelse return 0 else null;
        var k: usize = 0;
        for (self.subs.items) |s| {
            if (s.inst == inst and std.mem.eql(u8, s.event, event) and (id == null or s.handler == id.?)) continue;
            self.subs.items[k] = s;
            k += 1;
        }
        defer self.subs.shrinkRetainingCapacity(k);
        return self.subs.items.len - k;
    }

    /// `event`'s subscribers called with `args` in subscription order (those subscribed
    /// as it starts and not taken back before their turn; a handler that faults is logged
    /// and the rest still hear it); how many were called. A subscription whose instance
    /// is no longer attached to its host (`Object.components`: detached, swapped, a
    /// battle's scripted ones attached anew) is dropped; one whose host is disabled
    /// (removed from the world) is skipped.
    pub fn emit(self: *Runtime, event: []const u8, args: []const Value) (Error || error{EmitTooDeep})!usize {
        if (self.emit_depth >= max_emit_depth) return error.EmitTooDeep;
        self.emit_depth += 1;
        defer self.emit_depth -= 1;
        var k: usize = 0;
        for (self.subs.items) |s| if (std.mem.indexOfScalar(*Object, s.inst.owner.?.components.items, s.inst) != null) {
            self.subs.items[k] = s;
            k += 1;
        };
        self.subs.shrinkRetainingCapacity(k);
        var todo: std.ArrayList(Sub) = .empty;
        defer todo.deinit(self.gpa);
        for (self.subs.items) |s| if (std.mem.eql(u8, s.event, event)) try todo.append(self.gpa, s);
        var n: usize = 0;
        for (todo.items) |s| {
            const still = for (self.subs.items) |x| {
                if (std.meta.eql(x, s)) break true;
            } else false;
            if (!still or !s.inst.owner.?.enabled) continue;
            const f = s.inst.class.findFunctionId(s.handler) orelse continue;
            n += 1;
            _ = self.callScript(s.inst, f, args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ScriptFault => std.log.warn("{f} ({s}.{s})", .{ self.fault, s.inst.name, f.ir.?.name }),
                else => std.log.warn("{s}.{s}: {t}", .{ s.inst.name, f.ir.?.name, err }),
            };
        }
        return n;
    }

    fn addMethod(self: *Runtime, cls: *Class, m: *const ir.Fn) Allocator.Error!void {
        const func = try self.arena().create(Func);
        func.* = .{ .ast = null, .file = m.file, .ir = m };
        try cls.functions.put(self.arena(), try object.intern(m.name), func);
    }

    /// Data block `e` (of module `m`) applied to `host`: its fields set (converted to a
    /// variable's type; one the host lacks is added untyped), then its `attach`es with
    /// their params. A word is its enum value by the schema (`place = hand` → 11), else
    /// the path it names as a string (`explodeWeapon = weapons::x`). shortcut: other values
    /// are evaluated as code, so a call in it (`AiProfile(…)`) or a list of words faults; the
    /// model reads those. A structured field of the schema (`tile`, `camera`: a
    /// `check`) is left alone: the OG reader reads it (world/start.zig).
    pub fn applyEntity(self: *Runtime, host: *Object, m: *const ir.Module, e: ir.Entity) Error!void {
        var frame: Frame = .{ .obj = host, .slots = &.{} };
        for (e.vars) |v| {
            frame.line = v.line;
            try host.declare(self.arena(), object.nameOf(v.id), .{ .type = v.type, .value = .initial(v.type) });
            const d = v.default orelse continue;
            const slot = host.getVarId(v.id).?;
            slot.value = try (try self.eval(&frame, d)).convert(slot.type, self.strings());
        }
        for (e.fields) |f| {
            // Of its schema type where it has one (an OpenGorky-only field declared here).
            var ty: ir.Type = .any;
            if (self.schema) |s| switch (s(e.kind, f.name)) {
                .field => |fd| {
                    if (fd.check != null) continue;
                    ty = fd.type;
                },
                else => {},
            };
            const v: Value = switch (f.value.kind) {
                .word => |w| self.dataWord(e.kind, f.name, w),
                else => try self.eval(&frame, f.value),
            };
            var buf: [128]u8 = undefined;
            if (f.name.len > buf.len) return self.failAt(&frame, "name too long: {s}", .{f.name});
            try host.declare(self.arena(), std.ascii.lowerString(&buf, f.name), .{ .type = ty, .value = .initial(ty) });
            const slot = host.getVarDyn(f.name).?;
            slot.value = try v.convert(slot.type, self.strings());
        }
        // Its own code first (`fn`s in the block; a Classic class's code before the others).
        if (e.own) |c| {
            frame.line = c.line;
            _ = try self.attach(host, self.ogs.ownComponent(c) orelse return self.failAt(&frame, "{s}: its code did not link", .{e.name}), &.{});
        }
        for (e.attach) |x| {
            frame.line = x.line;
            const comp = try self.ogs.component(self.arena(), m, x.component) orelse return self.failAt(&frame, "no component {s}", .{x.component});
            const params = try self.arena().alloc(NamedValue, x.params.len);
            for (x.params, params) |p, *o| o.* = .{ .name = p.name, .value = try self.eval(&frame, p.value) };
            _ = try self.attach(host, comp, params);
        }
    }

    /// Word `w` of field `name` of a `kind` block: its enum value's number (`place = hand`:
    /// 11), else the word as `wordValue`.
    fn dataWord(self: *Runtime, kind: []const u8, name: []const u8, w: []const u8) Value {
        var buf: [128]u8 = undefined;
        if (self.schema) |s| switch (s(kind, name)) {
            // A schema field's type is the engine's (`foundation::ItemPlace`).
            .field => |fd| if (self.ogs.types.get(std.fmt.bufPrint(&buf, ogs_link.foundation ++ "::{s}", .{fd.type_name}) catch "")) |t| if (t == .@"enum") {
                if (t.@"enum".value(w[if (std.mem.lastIndexOf(u8, w, "::")) |k| k + 2 else 0..])) |v| if (v.number) |n| return .{ .int = n };
            },
            else => {},
        };
        return .{ .string = self.wordValue(w) };
    }

    /// `Side::enemy`: "enemy" (an enum of any namespace written so: link found which);
    /// any other word as written.
    fn wordValue(self: *Runtime, w: []const u8) []const u8 {
        const k = std.mem.lastIndexOf(u8, w, "::") orelse return w;
        var it = self.ogs.types.iterator();
        while (it.next()) |x| if (x.value_ptr.* == .@"enum") {
            const p = x.key_ptr.*;
            if (std.mem.eql(u8, p, w[0..k]) or (std.mem.endsWith(u8, p, w[0..k]) and std.mem.endsWith(u8, p[0 .. p.len - k], "::"))) return w[k + 2 ..];
        };
        return w;
    }
};
