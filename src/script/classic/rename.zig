//! Builtin names between Classic and OGS (docs/og-script.md §16): imported Classic IR as
//! OGS calls it (`toOgs`: `FighterSetHp` → `fighter::SetHp`, `"this"` → `host`) and OGS IR
//! of such code back as the exe calls it (`toClassic`). One table drives both: the
//! builtins' `Runtime.Sig.ogs` (`src/builtins.zig`), through `Names`. Merges: `Disable()`
//! is `object::Disable(host)` on an actor's script (on any other host the exe does
//! nothing, the call is dropped), `ActorQueueDelay` is `path::Delay` as `ActorDelay` is;
//! `GetName()` is `host.name`; `DialogInit("name", "x.dlg")` is `scene::Dialog(~d"x")` (the
//! name nothing reads goes), `DialogInit(…, GetName())` a level's own `scene::Dialog(host.dialog)`.
//! Back, a call keeps the spelling (and a dialog the pair) its function had (`DISABLEOBJECT`,
//! `ActorQueueDelay`), so code read back unchanged is the same IR.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const object = @import("../object.zig");
const Value = @import("../value.zig").Value;

const log = std.log.scoped(.rename);

/// A builtin as both languages call it. `ogs` empty: OGS has none (`GetName`, `Disable`).
/// `this`: its first argument `"this"` names the caller (`args.objectArg`), `host` in OGS.
/// `sig`, `pure`: its `Runtime.Sig` (the converter types calls by them, `ogsify.zig`).
pub const Info = struct { exe: []const u8, ogs: []const u8, this: bool = false, sig: []const u8 = "", pure: bool = false };

/// The builtins (`Runtime.names`).
pub const Names = struct {
    ctx: *anyopaque,
    /// The builtin a Classic call names (by its interned id).
    classic: *const fn (ctx: *anyopaque, id: u32) ?Info,
    /// The builtin an OGS path names (`fighter::SetHp`, `print`).
    ogs: *const fn (ctx: *anyopaque, path: []const u8) ?Info,
};

/// Classic `f` (of an actor's script: `actor`) with OGS's builtin names.
pub fn toOgs(a: Allocator, f: *const ir.Fn, names: Names, actor: bool) Allocator.Error!*const ir.Fn {
    var r: Rename = .{ .a = a, .names = names, .actor = actor, .dir = .ogs };
    return r.function(f);
}

/// OGS `f` (Classic code shown as OGS, `toOgs`) with the exe's names; `old`: the function
/// as imported, whose spellings the calls keep.
pub fn toClassic(a: Allocator, f: *const ir.Fn, names: Names, actor: bool, old: ?*const ir.Fn) Allocator.Error!*const ir.Fn {
    var r: Rename = .{ .a = a, .names = names, .actor = actor, .dir = .ogs };
    if (old) |o| _ = try r.function(o);
    r.dir = .classic;
    return r.function(f);
}

/// `scene::Dialog`'s argument as a key: a dialog's name, a level's own `host.dialog`, else none.
fn dialogKey(a: Allocator, d: *const ir.Expr) Allocator.Error![]const u8 {
    if (isOwnDialog(d)) return "~own";
    if (d.kind == .lit and d.kind.lit == .string) return std.ascii.allocLowerString(a, d.kind.lit.string);
    return "~other";
}

/// `host.dialog`: a level's own dialog.
fn isOwnDialog(d: *const ir.Expr) bool {
    return d.kind == .member and d.kind.member.obj.kind == .host and std.mem.eql(u8, d.kind.member.text, "dialog");
}

const Rename = struct {
    a: Allocator,
    names: Names,
    actor: bool,
    dir: enum { ogs, classic },
    /// OGS name (`~disable`, `~getname`: the Classic-only ones) → the spelling a Classic call had.
    spelled: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// A renamed field's id → its spelling in the Classic code.
    names_spelled: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// `scene::Dialog`'s dialog (`dialogKey`) → the DialogInit arguments it came from.
    dialogs: std.StringHashMapUnmanaged([2]*const ir.Expr) = .empty,

    fn function(self: *Rename, f: *const ir.Fn) Allocator.Error!*const ir.Fn {
        const n = try self.a.create(ir.Fn);
        n.* = try self.copy(ir.Fn, f.*);
        return n;
    }

    /// `x` with every expression through `rename` (a deep copy of what holds code).
    fn copy(self: *Rename, comptime T: type, x: T) Allocator.Error!T {
        if (T == *const ir.Expr) return self.expr(x);
        if (T == []const ir.Stmt) return self.stmts(x);
        if (T == Value) return x;
        if (T == ir.Name) return self.name(x);
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                var out = x;
                inline for (s.field_names) |n| @field(out, n) = try self.copy(@FieldType(T, n), @field(x, n));
                return out;
            },
            .@"union" => switch (x) {
                inline else => |v, tag| return @unionInit(T, @tagName(tag), try self.copy(@TypeOf(v), v)),
            },
            .pointer => |p| {
                if (p.size == .one) {
                    // Link results, back pointers, failures: not code of this function.
                    if (p.child != ir.Assign and p.child != ir.Method) return x;
                    const n = try self.a.create(p.child);
                    n.* = try self.copy(p.child, x.*);
                    return n;
                }
                if (p.child == u8 or p.child == []const u8) return x;
                const out = try self.a.alloc(p.child, x.len);
                for (x, out) |v, *o| o.* = try self.copy(p.child, v);
                return out;
            },
            .optional => |o| return if (x) |v| try self.copy(o.child, v) else null,
            else => return x,
        }
    }

    /// A field the Classic reader renamed (`names.zig`): OGS writes the engine's name, the
    /// exe's file its own spelling back.
    fn name(self: *Rename, n: ir.Name) Allocator.Error!ir.Name {
        var out = n;
        switch (self.dir) {
            .ogs => {
                out.text = @import("import.zig").fieldName(n);
                if (out.text.ptr != n.text.ptr) {
                    const gop = try self.names_spelled.getOrPut(self.a, n.id);
                    if (!gop.found_existing) gop.value_ptr.* = n.text;
                }
            },
            .classic => if (self.names_spelled.get(n.id)) |t| {
                out.text = t;
            },
        }
        return out;
    }

    fn stmts(self: *Rename, list: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
        var out: std.ArrayList(ir.Stmt) = .empty;
        for (list) |s| {
            if (self.dir == .ogs and !self.actor and s.kind == .expr and self.isDisable(s.kind.expr)) {
                log.info("{s}:{d}: Disable() dropped: the exe does nothing on a host that is no actor", .{ s.file, s.line });
                continue;
            }
            try out.append(self.a, try self.copy(ir.Stmt, s));
        }
        return out.items;
    }

    fn expr(self: *Rename, x: *const ir.Expr) Allocator.Error!*const ir.Expr {
        const y = (try self.rename(x)) orelse x;
        const n = try self.a.create(ir.Expr);
        n.* = .{ .line = y.line, .span = y.span, .sigil = y.sigil, .kind = try self.copy(ir.Expr.Kind, y.kind) };
        return n;
    }

    fn isDisable(self: *Rename, x: *const ir.Expr) bool {
        if (x.kind != .call or x.kind.call.target != null) return false;
        const info = self.names.classic(self.names.ctx, x.kind.call.id) orelse return false;
        return std.ascii.eqlIgnoreCase(info.exe, "Disable");
    }

    /// `x` as the other language writes it (its operands renamed after), null: as it is.
    fn rename(self: *Rename, x: *const ir.Expr) Allocator.Error!?*const ir.Expr {
        return switch (self.dir) {
            .ogs => if (x.kind == .call and x.kind.call.target == null) self.ogsCall(x) else null,
            .classic => switch (x.kind) {
                .call => self.classicCall(x),
                .member => |m| if (m.obj.kind == .host and std.mem.eql(u8, m.text, "name")) try self.call(x, self.spelling("~getname", "GetName"), &.{}) else null,
                // The host as an argument: its name, as builtins take it.
                .host => try self.call(x, self.spelling("~getname", "GetName"), &.{}),
                else => null,
            },
        };
    }

    fn ogsCall(self: *Rename, x: *const ir.Expr) Allocator.Error!?*const ir.Expr {
        const c = x.kind.call;
        const info = self.names.classic(self.names.ctx, c.id) orelse return null;
        // The Classic-only builtins with an OGS form.
        if (std.ascii.eqlIgnoreCase(info.exe, "DialogInit") and c.args.len == 2 and c.named.len == 0) {
            try self.spell("~dialoginit", c.text);
            const d = try self.dialogOf(c.args[1]);
            const gop = try self.dialogs.getOrPut(self.a, try dialogKey(self.a, d));
            if (!gop.found_existing) gop.value_ptr.* = .{ c.args[0], c.args[1] };
            return try self.call(x, "scene::Dialog", try self.a.dupe(*const ir.Expr, &.{d}));
        }
        if (std.ascii.eqlIgnoreCase(info.exe, "Disable")) {
            try self.spell("~disable", c.text);
            if (!self.actor) return try self.node(x, .{ .lit = .{ .int = 0 } });
            return try self.call(x, "object::Disable", &.{try self.node(x, .host)});
        }
        if (std.ascii.eqlIgnoreCase(info.exe, "GetName")) {
            try self.spell("~getname", c.text);
            return try self.node(x, .{ .member = .{ .obj = try self.node(x, .host), .id = try object.intern("name"), .text = "name" } });
        }
        if (info.ogs.len == 0) return null;
        try self.spell(info.ogs, c.text);
        var args = c.args;
        if (info.this and args.len > 0 and args[0].kind == .lit and args[0].kind.lit == .string and std.ascii.eqlIgnoreCase(args[0].kind.lit.string, "this")) {
            const v = try self.a.dupe(*const ir.Expr, args);
            v[0] = try self.node(args[0], .host);
            args = v;
        }
        return try self.callNamed(x, info.ogs, args, c.named);
    }

    fn classicCall(self: *Rename, x: *const ir.Expr) Allocator.Error!?*const ir.Expr {
        const c = x.kind.call;
        if (std.mem.eql(u8, c.text, "scene::Dialog") and c.args.len == 1 and c.named.len == 0) {
            const d = c.args[0];
            if (self.dialogs.get(try dialogKey(self.a, d))) |was| return try self.call(x, self.spelling("~dialoginit", "DialogInit"), try self.a.dupe(*const ir.Expr, &was));
            // Written in OGS: the dialog both as its name and its `.dlg`, a level's own its name.
            const file = if (isOwnDialog(d)) try self.call(x, self.spelling("~getname", "GetName"), &.{}) else if (d.kind == .lit and d.kind.lit == .string)
                try self.node(x, .{ .lit = .{ .string = try std.fmt.allocPrint(self.a, "{s}.dlg", .{d.kind.lit.string}) } })
            else
                d;
            const label = if (d.kind == .lit and d.kind.lit == .string) try self.node(x, .{ .lit = .{ .string = d.kind.lit.string } }) else file;
            return try self.call(x, self.spelling("~dialoginit", "DialogInit"), try self.a.dupe(*const ir.Expr, &.{ label, file }));
        }
        if (self.actor and std.mem.eql(u8, c.text, "object::Disable") and c.args.len == 1 and c.args[0].kind == .host and c.named.len == 0)
            return try self.call(x, self.spelling("~disable", "Disable"), &.{});
        const info = self.names.ogs(self.names.ctx, c.text) orelse return null;
        var args = c.args;
        if (info.this and args.len > 0 and args[0].kind == .host) {
            const v = try self.a.dupe(*const ir.Expr, args);
            v[0] = try self.node(args[0], .{ .lit = .{ .string = "this" } });
            args = v;
        }
        return try self.callNamed(x, self.spelling(info.ogs, info.exe), args, c.named);
    }

    /// DialogInit's file `f` as OGS names the dialog: `"x.dlg"` its block `~d"x"`; the
    /// caller's own name (`GetName()`) a level's `host.dialog`; else as it is.
    fn dialogOf(self: *Rename, f: *const ir.Expr) Allocator.Error!*const ir.Expr {
        if (f.kind == .lit and f.kind.lit == .string) {
            const s = f.kind.lit.string;
            const stem = if (std.ascii.endsWithIgnoreCase(s, ".dlg")) s[0 .. s.len - 4] else s;
            const n = try self.a.create(ir.Expr);
            n.* = .{ .line = f.line, .span = f.span, .sigil = .dialog, .kind = .{ .lit = .{ .string = stem } } };
            return n;
        }
        if (f.kind == .call and f.kind.call.target == null and f.kind.call.args.len == 0) if (self.names.classic(self.names.ctx, f.kind.call.id)) |i| if (std.ascii.eqlIgnoreCase(i.exe, "GetName")) {
            try self.spell("~getname", f.kind.call.text);
            return try self.node(f, .{ .member = .{ .obj = try self.node(f, .host), .id = try object.intern("dialog"), .text = "dialog" } });
        };
        return f;
    }

    fn spell(self: *Rename, k: []const u8, text: []const u8) Allocator.Error!void {
        const gop = try self.spelled.getOrPut(self.a, k);
        if (!gop.found_existing) gop.value_ptr.* = text;
    }

    fn spelling(self: *const Rename, k: []const u8, default: []const u8) []const u8 {
        return self.spelled.get(k) orelse default;
    }

    fn node(self: *Rename, at: *const ir.Expr, kind: ir.Expr.Kind) Allocator.Error!*const ir.Expr {
        const n = try self.a.create(ir.Expr);
        n.* = .{ .line = at.line, .span = at.span, .kind = kind };
        return n;
    }

    fn call(self: *Rename, at: *const ir.Expr, text: []const u8, args: []const *const ir.Expr) Allocator.Error!*const ir.Expr {
        return self.callNamed(at, text, args, &.{});
    }

    fn callNamed(self: *Rename, at: *const ir.Expr, text: []const u8, args: []const *const ir.Expr, named: []const ir.Named) Allocator.Error!*const ir.Expr {
        return self.node(at, .{ .call = .{ .id = try object.intern(text), .text = text, .args = args, .named = named } });
    }
};
