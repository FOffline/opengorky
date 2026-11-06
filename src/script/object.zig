//! Script objects and classes: object variables (case-insensitive names) and
//! class functions with inheritance (`#inherit`). The interpreter is `runtime.zig`.

const std = @import("std");
const names = @import("names.zig");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const Value = @import("value.zig").Value;
const traits = @import("traits.zig");
const names_classic = @import("classic/names.zig");

/// A class function: its parse tree and the IR the runtime compiles from it on the
/// first call (`classic/import.zig`). Classes that inherit it share it. An OGS method
/// has no parse tree: its IR is the parser's.
pub const Func = struct {
    ast: ?*const ast.Function,
    /// Lower-case file of the definition.
    file: []const u8,
    ir: ?*const ir.Fn = null,
    /// `Runtime.ir_gen` the IR was compiled at (a new script function that takes a
    /// builtin's name makes older IR stale).
    gen: u32 = 0,
    /// The Classic class that defined it: its host renames the names of its code
    /// (`classic/names.zig`); null: none (a tool's, an OGS method).
    class: ?*const Class = null,
};

pub const Class = struct {
    /// Class file name, lower case.
    name: []const u8,
    /// Last `#inherit` (for `isA`); never set to a class that is still loading
    /// (mutual inheritance), so the chain has no cycles.
    parent: ?*Class,
    /// Class is still being built (`Runtime.loadClass`).
    loading: bool = false,
    /// Entity class (rules.classOf), found on first use.
    ident: ?[]const u8 = null,
    /// OGS: the component whose instances have this class (`Runtime.attach`).
    component: ?*const ir.Component = null,
    /// OGS: the marks its component implements (`: Monitor`, through its traits too); a
    /// native component's: its marks and methods.
    marks: traits.Mask = .empty,
    /// A native component's: the engine runs its methods (Runtime.attachNative).
    native: ?*const Native = null,
    /// Own variables and inserted `#inherit` ones, in text order, as the files spell them
    /// (`varName`: as the engine does).
    vars: std.ArrayList(ast.VarDecl) = .empty,
    /// Classic: the most derived base class whose file it includes or inherits
    /// (`classes\\weapon.s`): the engine's names of its fields (`classic/names.zig`).
    host: ?names_classic.Host = null,
    /// Key is the interned function name (`intern`); the first definition wins
    /// (`#inherit`/`#include` insertions come before later ones).
    functions: std.AutoHashMapUnmanaged(u32, *Func) = .empty,

    /// Variable `d` of the class as the engine names it (`charSize` → `footprint_tiles`).
    pub fn varName(self: *const Class, d: ast.VarDecl) []const u8 {
        return names_classic.engine(self.host, d.name);
    }

    /// Its interned id (`intern`).
    pub fn varId(self: *const Class, d: ast.VarDecl) std.mem.Allocator.Error!u32 {
        const n = self.varName(d);
        if (n.ptr == d.name.ptr) if (d.id) |id| return id;
        return intern(n);
    }

    pub fn findFunction(self: *const Class, lower_name: []const u8) ?*const ast.Function {
        const f = self.findFunctionId(findName(lower_name) orelse return null) orelse return null;
        return f.ast;
    }

    /// Lookup by interned name id, up the ancestor chain.
    pub fn findFunctionId(self: *const Class, id: u32) ?*Func {
        var c: ?*const Class = self;
        while (c) |cls| : (c = cls.parent) {
            if (cls.functions.get(id)) |f| return f;
        }
        return null;
    }

    /// Whether the class inherits (directly or via ancestors) from `lower_name`.
    pub fn isA(self: *const Class, lower_name: []const u8) bool {
        var c: ?*const Class = self;
        while (c) |cls| : (c = cls.parent) {
            if (std.mem.eql(u8, std.fs.path.stem(cls.name), lower_name)) return true;
        }
        return false;
    }
};

/// A native component (core/natives.zig): an ability whose methods the engine
/// runs in Zig (`Runtime.native_components`), in the host's component list with the OGS
/// ones. `tag` tells the engine which one; `bits` the methods and marks it implements.
pub const Native = struct { name: []const u8, tag: u8, bits: traits.Mask };

pub const Var = struct {
    type: ir.Type,
    value: Value,
};

pub const intern = names.intern;
pub const findName = names.findName;
pub const findAnyCase = names.findAnyCase;
pub const nameOf = names.nameOf;
const internName = names.internName;

pub const Object = struct {
    name: []const u8,
    class: *Class,
    /// Key is the interned id of the lower-case variable name (`nameOf`).
    vars: std.AutoArrayHashMapUnmanaged(u32, Var) = .empty,
    enabled: bool = true,
    /// Engine data attached to the object.
    host: ?*anyopaque = null,
    /// What an OGS `ref` value points at (`ref`, `of`); its name is `name`.
    handle: Value.Handle = .{},
    /// OGS: a component instance's host (`host` in its code); null for others.
    owner: ?*Object = null,
    /// OGS: the component instances attached to this host, in attach order.
    components: std.ArrayList(*Object) = .empty,
    /// OGS: the built-in methods and marks (traits.names()) at least one active component of
    /// this host implements; an engine point checks its bit before it makes the arguments
    /// (`refreshImplements` after an attach or a role change).
    implements: traits.Mask = .empty,
    /// OGS: its host-kind trait (`Fighter`, `Item`…: `x is Fighter`, `param fighter`), set by
    /// the engine as it makes a world object; null: no kind (a component instance, a test's).
    kind: ?*const traits.Trait = null,
    /// OGS: the roles the host has now (the engine grants them: dispatch.setRole).
    roles: traits.Roles = .empty,
    /// OGS: a component instance active only while its host has one of these roles
    /// (`for Hero`); empty: always active.
    for_roles: traits.Roles = .empty,
    /// OGS: a component instance's lifetime: with the host (`object`: native ones, attached
    /// as the object is made) or one battle (`battle`: a row's scripted abilities,
    /// combat/events.zig spawn attaches them anew).
    scope: enum { object, battle } = .object,

    /// Whether component instance `c` of `host` takes part (gets events, counts for
    /// `implements`).
    pub fn activeOn(c: *const Object, host: *const Object) bool {
        return c.for_roles.count() == 0 or c.for_roles.intersectWith(host.roles).count() > 0;
    }

    /// Whether an active component implements built-in method or mark `name`.
    pub fn implementsC(self: *const Object, comptime name: []const u8) bool {
        return self.implements.isSet(traits.bit(name));
    }

    /// `implements` again from the active components' methods and marks.
    pub fn refreshImplements(self: *Object) void {
        self.implements = .empty;
        for (self.components.items) |c| if (c.activeOn(self)) {
            self.implements.setUnion(c.class.marks);
            var it = c.class.functions.valueIterator();
            while (it.next()) |f| if (f.*.ir) |m| if (traits.bitOf(m.name)) |b| self.implements.set(b);
        };
    }

    /// The OGS value referring to this object.
    pub fn ref(self: *Object) Value {
        self.handle.name = self.name;
        return .{ .ref = &self.handle };
    }

    /// The object an OGS `ref` value refers to.
    pub fn of(h: *const Value.Handle) *Object {
        return @constCast(@as(*const Object, @alignCast(@fieldParentPtr("handle", h))));
    }

    /// Variable by a comptime-known name (almost every engine access): the id is looked
    /// up once per call site and cached.
    pub fn getVar(self: *Object, comptime name: []const u8) ?*Var {
        // The struct must capture `name`, or every call site would share one cache.
        const S = struct {
            const key = lowerConst(name);
            var id: ?u32 = null;
            /// Slot of the last hit: objects of one class share the variable order, so the
            /// next object usually has the name at the same slot.
            var slot: usize = 0;
        };
        const id = S.id orelse blk: {
            // Not cached until some object declares the name.
            const found = findName(S.key) orelse return null;
            S.id = found;
            break :blk found;
        };
        const keys = self.vars.keys();
        if (S.slot < keys.len and keys[S.slot] == id) return &self.vars.values()[S.slot];
        const i = self.vars.getIndex(id) orelse return null;
        S.slot = i;
        return &self.vars.values()[i];
    }

    /// Variable by an interned id (script identifiers resolved at parse time).
    pub fn getVarId(self: *Object, id: u32) ?*Var {
        return self.vars.getPtr(id);
    }

    /// Variable by a runtime name.
    pub fn getVarDyn(self: *Object, name: []const u8) ?*Var {
        return self.vars.getPtr(findAnyCase(name) orelse return null);
    }

    /// Declare a variable by its lower-case name unless the object has it.
    pub fn declare(self: *Object, gpa: std.mem.Allocator, lower: []const u8, v: Var) std.mem.Allocator.Error!void {
        const gop = try self.vars.getOrPut(gpa, try internName(lower));
        if (!gop.found_existing) gop.value_ptr.* = v;
    }

    pub fn getInt(self: *Object, comptime name: []const u8) i32 {
        const v = self.getVar(name) orelse return 0;
        return v.value.toInt();
    }

    pub fn getIntDyn(self: *Object, name: []const u8) i32 {
        const v = self.getVarDyn(name) orelse return 0;
        return v.value.toInt();
    }

    pub fn getString(self: *Object, comptime name: []const u8) []const u8 {
        const v = self.getVar(name) orelse return "";
        return switch (v.value) {
            .string => |s| s,
            else => "",
        };
    }

    pub fn getStringDyn(self: *Object, name: []const u8) []const u8 {
        const v = self.getVarDyn(name) orelse return "";
        return switch (v.value) {
            .string => |s| s,
            else => "",
        };
    }

    /// Write converting to the variable's type. Strings must live in the runtime arena.
    pub fn setInt(self: *Object, comptime name: []const u8, v: i32) void {
        const p = self.getVar(name) orelse return;
        p.value = switch (p.type) {
            .int => .{ .int = v },
            .float => .{ .float = @floatFromInt(v) },
            else => p.value,
        };
    }

    pub fn hasFunction(self: *Object, name: []const u8) bool {
        return self.class.findFunctionId(findAnyCase(name) orelse return false) != null;
    }
};

fn lowerConst(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const final = buf;
        return &final;
    }
}

test "interned variable names: case-insensitive, unknown name misses" {
    const gpa = std.testing.allocator;
    var o: Object = .{ .name = "o", .class = undefined };
    defer o.vars.deinit(gpa);
    try o.declare(gpa, "speed", .{ .type = .int, .value = .{ .int = 7 } });
    try o.declare(gpa, "speed", .{ .type = .int, .value = .{ .int = 9 } });
    try std.testing.expectEqual(7, o.getInt("Speed"));
    try std.testing.expectEqual(7, o.getIntDyn("SPEED"));
    try std.testing.expectEqualStrings("speed", nameOf(o.vars.keys()[0]));
    try std.testing.expect(o.getVarDyn("never_declared_name_xyz") == null);
}
