//! The project's traits and components as the editor shows them: the
//! script traits and components of its rules code (`rules.scripts`, the hooks), the
//! engine's traits (script/traits.zig) and native components (core/natives.zig); a
//! component's traits with their supertraits, its method rows (its own, the default bodies
//! it takes, the required ones it lacks), who implements a trait, where a stub goes. Read
//! from the parsed texts, not linked: a component lacking a required method does not link,
//! and its page is where it gets one. No SDL (its tests run).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const ir = og.script.ir;
const traits = og.script.traits;
const parser = og.script.ogs.parser;

/// A trait or a component of the project's code: its path (`abilities::Shielded`), its
/// module block's `use`s (its names are found from there) and the file (`rules\x.ss`).
pub fn Item(comptime T: type) type {
    return struct { path: []const u8, it: *const T, uses: []const []const u8, file: []const u8 };
}
const STrait = Item(ir.Trait);
pub const SComp = Item(ir.Component);

/// A trait as a component names it: the project's or the engine's.
pub const Ref = union(enum) {
    script: *const STrait,
    engine: *const traits.Trait,

    pub fn name(r: Ref) []const u8 {
        return switch (r) {
            .script => |s| s.path,
            .engine => |e| e.name,
        };
    }

    fn eql(r: Ref, o: Ref) bool {
        return switch (r) {
            .script => |s| o == .script and o.script == s,
            .engine => |e| o == .engine and o.engine == e,
        };
    }
};

const SEnum = Item(ir.Enum);
const SStruct = Item(ir.Struct);

pub const Project = struct {
    traits: []const STrait = &.{},
    comps: []const SComp = &.{},
    /// Its enums and the engine's (the prelude's `foundation::Side`, `foundation::ItemPlace`:
    /// foundation/types.ogs).
    enums: []const SEnum = &.{},
    /// Its structs and the engine's (`Place`, `Slot`; the editor edits their values field by field).
    structs: []const SStruct = &.{},

    /// Enum `n` as code in module `module` (with `uses`) names it (as `resolve`).
    pub fn enumNamed(p: *const Project, a: Allocator, module: []const u8, uses: []const []const u8, n: []const u8) ?*const ir.Enum {
        return named(ir.Enum, p.enums, a, module, uses, n);
    }

    /// Struct `n` as code in module `module` (with `uses`) names it (as `enumNamed`).
    pub fn structNamed(p: *const Project, a: Allocator, module: []const u8, uses: []const []const u8, n: []const u8) ?*const ir.Struct {
        return named(ir.Struct, p.structs, a, module, uses, n);
    }

    fn named(comptime T: type, list: []const Item(T), a: Allocator, module: []const u8, uses: []const []const u8, n: []const u8) ?*const T {
        var tries: std.ArrayList([]const u8) = .empty;
        if (std.mem.indexOf(u8, n, "::") == null) {
            if (module.len > 0) tries.append(a, join(a, module, n)) catch {};
            for (uses) |u| tries.append(a, join(a, u, n)) catch {};
        }
        tries.append(a, n) catch {};
        // Data names the engine's bare (`place = hand`, `Place(…)`).
        if (std.mem.indexOf(u8, n, "::") == null) tries.append(a, join(a, foundation, n)) catch {};
        for (tries.items) |t| for (list) |e| if (std.mem.eql(u8, e.path, t)) return e.it;
        return null;
    }

    /// Component `c`'s fields as attached: its script traits' params it does not declare
    /// (the most general first), then its own (link.zig `Table.fields`).
    pub fn fields(p: *const Project, a: Allocator, c: *const SComp) []const ir.Field {
        var out: std.ArrayList(ir.Field) = .empty;
        const cl = p.closure(a, c);
        var i = cl.len;
        while (i > 0) {
            i -= 1;
            if (cl[i] == .script) for (cl[i].script.it.params) |tp| {
                const own = for (c.it.fields) |f| {
                    if (std.ascii.eqlIgnoreCase(f.name, tp.name)) break f;
                } else tp;
                if (!hasField(out.items, tp.name)) out.append(a, own) catch {};
            };
        }
        for (c.it.fields) |f| if (!hasField(out.items, f.name)) out.append(a, f) catch {};
        return out.items;
    }

    pub fn trait(p: *const Project, path: []const u8) ?*const STrait {
        for (p.traits) |*t| if (std.mem.eql(u8, t.path, path)) return t;
        return null;
    }

    pub fn comp(p: *const Project, path: []const u8) ?*const SComp {
        for (p.comps) |*c| if (std.mem.eql(u8, c.path, path)) return c;
        return null;
    }

    /// Trait `n` as code in module `module` (with `uses`) names it: `foundation::X` the
    /// engine's; the module's, a used namespace's (foundation's), the root's; then the
    /// engine's bare (the editor shows code that does not link yet too).
    pub fn resolve(p: *const Project, a: Allocator, module: []const u8, uses: []const []const u8, n: []const u8) ?Ref {
        if (engineName(n)) |e| return if (traits.find(e)) |t| .{ .engine = t } else null;
        if (std.mem.indexOf(u8, n, "::") == null) {
            if (module.len > 0) if (p.trait(join(a, module, n))) |t| return .{ .script = t };
            for (uses) |u| {
                if (std.mem.eql(u8, u, foundation)) if (traits.find(n)) |t| return .{ .engine = t };
                if (p.trait(join(a, u, n))) |t| return .{ .script = t };
            }
        }
        if (p.trait(n)) |t| return .{ .script = t };
        if (traits.find(n)) |t| return .{ .engine = t };
        return null;
    }

    /// The traits of component `c` with their supertraits, each once, the ones it names
    /// first (`:` traits, then the `for` hosts), each before its supertraits.
    pub fn closure(p: *const Project, a: Allocator, c: *const SComp) []const Ref {
        var out: std.ArrayList(Ref) = .empty;
        for (c.it.traits) |n| if (p.resolve(a, c.it.module, c.uses, n)) |r| p.add(a, &out, r);
        for (c.it.hosts) |h| if (traits.find(h) orelse traits.ofHost(h)) |t| p.add(a, &out, .{ .engine = t });
        return out.items;
    }

    /// Trait `r` with its supertraits (as `closure`).
    pub fn supers(p: *const Project, a: Allocator, r: Ref) []const Ref {
        var out: std.ArrayList(Ref) = .empty;
        p.add(a, &out, r);
        return out.items;
    }

    fn add(p: *const Project, a: Allocator, out: *std.ArrayList(Ref), r: Ref) void {
        for (out.items) |x| if (x.eql(r)) return;
        out.append(a, r) catch return;
        switch (r) {
            .engine => |t| for (t.supers) |s| p.add(a, out, .{ .engine = traits.find(s).? }),
            .script => |t| for (t.it.supers) |s| if (p.resolve(a, t.it.module, t.uses, s)) |x| p.add(a, out, x),
        }
    }

    /// Component `c`'s methods: its own (with the engine method of that name among its
    /// traits, an event), then each method of its script traits it does not define: the
    /// default body of the first trait giving one (the most specific: a trait comes
    /// before its supertraits), else required.
    pub fn rows(p: *const Project, a: Allocator, c: *const SComp) []const Row {
        const cl = p.closure(a, c);
        var out: std.ArrayList(Row) = .empty;
        for (c.it.methods) |f| out.append(a, .{ .name = f.name, .params = paramNames(a, f), .kind = .own, .line = f.line, .event = engineMethod(cl, f.name), .from = declarer(cl, f.name) }) catch {};
        for (cl) |r| if (r == .script) for (r.script.it.methods) |m| {
            if (for (out.items) |x| {
                if (std.mem.eql(u8, x.name, m.f.name)) break true;
            } else false) continue;
            const body = bodyOf(cl, m.f.name);
            out.append(a, .{ .name = m.f.name, .params = paramNames(a, m.f), .kind = if (body != null) .default else .required, .from = body orelse r, .line = m.f.line, .event = engineMethod(cl, m.f.name) }) catch {};
        };
        return out.items;
    }

    /// The project's components that implement trait `r`: it is among their traits (with
    /// the supertraits), in file order.
    pub fn implementers(p: *const Project, a: Allocator, r: Ref) []const *const SComp {
        var out: std.ArrayList(*const SComp) = .empty;
        for (p.comps) |*c| for (p.closure(a, c)) |x| if (x.eql(r)) {
            out.append(a, c) catch {};
            break;
        };
        return out.items;
    }
};

/// A method of a component's page.
pub const Row = struct {
    name: []const u8,
    params: []const []const u8,
    kind: enum { own, default, required },
    /// Default: the trait whose body it takes; required: the trait requiring it; own: the
    /// trait declaring it (null: a helper of its own).
    from: ?Ref = null,
    /// An engine method among its traits of that name (an event: its rule and when).
    event: ?*const traits.Method = null,
    /// Its line (own: the component's text; default, required: the trait's).
    line: u32 = 0,
};

fn join(a: Allocator, m: []const u8, n: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}::{s}", .{ m, n }) catch n;
}

fn paramNames(a: Allocator, f: *const ir.Fn) []const []const u8 {
    const out = a.alloc([]const u8, f.params.len) catch return &.{};
    for (f.params, out) |pr, *o| o.* = pr.name;
    return out;
}

fn engineMethod(cl: []const Ref, n: []const u8) ?*const traits.Method {
    for (cl) |r| if (r == .engine) if (r.engine.own(n)) |m| return m;
    return null;
}

/// The first script trait among `cl` giving method `n` a default body.
fn bodyOf(cl: []const Ref, n: []const u8) ?Ref {
    for (cl) |q| if (q == .script) for (q.script.it.methods) |o| if (o.body and std.mem.eql(u8, o.f.name, n)) return q;
    return null;
}

/// The trait among `cl` that declares method `n` (the first).
fn declarer(cl: []const Ref, n: []const u8) ?Ref {
    for (cl) |r| switch (r) {
        .engine => |t| if (t.own(n) != null) return r,
        .script => |t| for (t.it.methods) |m| if (std.mem.eql(u8, m.f.name, n)) return r,
    };
    return null;
}

/// The engine's namespace (script/ogs/link.zig): its traits, structs and enums.
pub const foundation = og.script.ogs.link.foundation;

/// `foundation::Fighter`: `Fighter`; null: not foundation's path.
pub fn engineName(n: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, n, foundation ++ "::")) n[foundation.len + 2 ..] else null;
}

/// The traits and components of texts `texts` (a text that does not parse has none).
pub fn fromTexts(a: Allocator, texts: []const og.rules.Script) Project {
    var ts: std.ArrayList(STrait) = .empty;
    var cs: std.ArrayList(SComp) = .empty;
    var es: std.ArrayList(SEnum) = .empty;
    var ss: std.ArrayList(SStruct) = .empty;
    const engine: og.rules.Script = .{ .name = "engine.ogs", .data = traits.types };
    for ([_][]const og.rules.Script{ &.{engine}, texts }, 0..) |list, k| for (list) |t| {
        var diag: parser.Diagnostic = .{};
        const u = parser.parse(a, t.data, t.name, &diag) catch continue;
        for (u.modules) |um| {
            // The prelude's types are foundation's.
            var m = um;
            if (k == 0) m.path = foundation;
            for (m.traits) |x| ts.append(a, .{ .path = pathOf(a, m.path, x.name), .it = x, .uses = m.uses, .file = t.name }) catch {};
            for (m.components) |x| cs.append(a, .{ .path = pathOf(a, m.path, x.name), .it = x, .uses = m.uses, .file = t.name }) catch {};
            for (m.enums) |x| es.append(a, .{ .path = pathOf(a, m.path, x.name), .it = x, .uses = m.uses, .file = t.name }) catch {};
            for (m.structs) |x| ss.append(a, .{ .path = pathOf(a, m.path, x.name), .it = x, .uses = m.uses, .file = t.name }) catch {};
        }
    };
    return .{ .traits = ts.items, .comps = cs.items, .enums = es.items, .structs = ss.items };
}

fn hasField(list: []const ir.Field, name: []const u8) bool {
    for (list) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return true;
    return false;
}

fn pathOf(a: Allocator, m: []const u8, n: []const u8) []const u8 {
    return if (m.len == 0) n else join(a, m, n);
}

/// The project's code as the rules in force hold it (its rules code),
/// parsed again only when they change (the tree and the pages ask every frame). `a`: the
/// caller's frame (unused while kept).
pub fn load(a: Allocator) Project {
    _ = a;
    const key: [2]usize = .{ @intFromPtr(og.rules.scripts.ptr), og.rules.scripts.len };
    if (cache.key) |k| if (std.mem.eql(usize, &k, &key)) return cache.project;
    _ = cache.arena.reset(.retain_capacity);
    const ca = cache.arena.allocator();
    var texts: std.ArrayList(og.rules.Script) = .empty;
    texts.appendSlice(ca, og.rules.scripts) catch {};
    cache.project = fromTexts(ca, texts.items);
    cache.key = key;
    return cache.project;
}

const cache = struct {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var key: ?[2]usize = null;
    var project: Project = .{};
};

/// The native components (core/natives.zig) that implement engine trait `t`: a mark they
/// are, or a method of `t` (or of its supertraits) they answer.
pub fn nativesOf(a: Allocator, t: *const traits.Trait) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (og.core.natives.components()) |*n| if (nativeIs(n, t)) out.append(a, n.name) catch {};
    return out.items;
}

/// Whether native component `n` implements engine trait `t` (the natives are fighters':
/// a host trait a fighter is counts when it answers one of its methods).
fn nativeIs(n: *const og.script.object.Native, t: *const traits.Trait) bool {
    if (t.kind == .mark) return if (traits.bitOf(t.name)) |b| n.bits.isSet(b) else false;
    if (t.kind == .role) return false;
    for (t.methods) |m| if (traits.bitOf(m.name)) |b| if (n.bits.isSet(b)) return true;
    return false;
}

/// The engine methods and marks native component `n` implements, by name.
pub fn nativeImplements(a: Allocator, n: *const og.script.object.Native) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (traits.names(), 0..) |name, b| if (n.bits.isSet(b)) out.append(a, name) catch {};
    return out.items;
}

/// The native component named `name`.
pub fn native(name: []const u8) ?*const og.script.object.Native {
    for (og.core.natives.components()) |*n| if (std.mem.eql(u8, n.name, name)) return n;
    return null;
}

// ---------------------------------------------------------------- completion by type

/// The component or trait whose body `at` of OGS text `text` is in: the last
/// `component`/`trait` header line before it (an unfinished text has no tree to ask).
fn enclosing(text: []const u8, at: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text[0..@min(at, text.len)], '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, l, "component ") or std.mem.startsWith(u8, l, "trait ")) best = l[0 .. std.mem.indexOfScalar(u8, l, '{') orelse l.len];
    }
    return best;
}

/// The host kind (`fighter`) a component or trait header `h` gives `host`: its first
/// `for` (a role: fighter), else its traits' (supertraits') first host kind.
fn hostKind(p: *const Project, a: Allocator, h: []const u8) []const u8 {
    const is_trait = std.mem.startsWith(u8, h, "trait ");
    var rest = std.mem.trim(u8, h[if (is_trait) 6 else 10..], " \t\r");
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    if (!is_trait) if (std.mem.indexOf(u8, rest, " for ")) |f| {
        const list = rest[f + 5 .. if (colon) |c| (if (c > f) c else rest.len) else rest.len];
        var hs = std.mem.tokenizeAny(u8, list, ", \t");
        if (hs.next()) |w| return if (traits.Role.of(w) != null) "fighter" else w;
    };
    const after = if (colon) |c| rest[c + 1 ..] else return "";
    var ts = std.mem.tokenizeAny(u8, after, ", \t\r");
    while (ts.next()) |n| {
        const r = p.resolve(a, "", &.{}, n) orelse for (p.traits) |*t| {
            if (std.mem.endsWith(u8, t.path, n) and (t.path.len == n.len or std.mem.endsWith(u8, t.path[0 .. t.path.len - n.len], "::"))) break Ref{ .script = t };
        } else continue;
        for (p.supers(a, r)) |x| if (x == .engine) if (x.engine.host) |k| return k;
    }
    rest = "";
    return "";
}

/// The words OGS code may write after the `.` at `dot` of `text`, by the receiver's
/// static type: `host` — its host kind's fields (core/schema.zig), the battle's computed
/// ones of a fighter, `name` and the queries; `x.as(T).`/`x.get(T).` — T's methods (a role's
/// engine methods); `self` — the enclosing component's fields and methods. Empty: unknown.
pub fn members(p: *const Project, a: Allocator, text: []const u8, dot: usize) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var e = dot;
    if (e > 0 and text[e - 1] == ')') {
        // `….as(T)` / `….get(T)`: T between the parentheses.
        const open = std.mem.lastIndexOfScalar(u8, text[0 .. e - 1], '(') orelse return &.{};
        const t = std.mem.trim(u8, text[open + 1 .. e - 1], " ");
        var w = open;
        while (w > 0 and isWord(text[w - 1])) w -= 1;
        const op = text[w..open];
        if (!std.mem.eql(u8, op, "as") and !std.mem.eql(u8, op, "get")) return &.{};
        const r = p.resolve(a, "", &.{}, t) orelse return &.{};
        for (p.supers(a, r)) |x| switch (x) {
            .engine => |et| for (et.methods) |m| if (m.native) out.append(a, m.name) catch {},
            .script => |st| for (st.it.methods) |m| out.append(a, m.f.name) catch {},
        };
        return out.items;
    }
    while (e > 0 and isWord(text[e - 1])) e -= 1;
    const recv = text[e..dot];
    const h = enclosing(text, dot) orelse return &.{};
    if (std.mem.eql(u8, recv, "host")) {
        const kind = hostKind(p, a, h);
        out.appendSlice(a, &.{ "name", "as", "get", "all" }) catch {};
        if (std.mem.eql(u8, kind, "fighter")) out.appendSlice(a, &.{ "side", "alive", "tile", "asleep", "second_turn", "avenging" }) catch {};
        if (og.core.schema.blockHost(kind)) |sh| for (og.core.schema.fields(a, sh, true) catch &.{}) |f| out.append(a, f.name) catch {};
        return out.items;
    }
    if (std.mem.eql(u8, recv, "self") and std.mem.startsWith(u8, h, "component ")) {
        var ws = std.mem.tokenizeAny(u8, h[10..], " \t:");
        const name = ws.next() orelse return &.{};
        for (p.comps) |*c| if (std.mem.eql(u8, c.it.name, name)) {
            out.append(a, "name") catch {};
            for (c.it.fields) |f| out.append(a, f.name) catch {};
            for (p.rows(a, c)) |r| out.append(a, r.name) catch {};
            break;
        };
    }
    return out.items;
}

/// The engine method `name` that a method declared at `at` of OGS text `text` implements:
/// of the enclosing component's (or trait's) role or host kind trait, supertraits too
/// (the hover's row of the table: its parameters, when, its rule). Null: none, or no
/// host (the fighter's events then, as a component without `for` was before traits).
pub fn engineMethodAt(p: *const Project, a: Allocator, text: []const u8, at: usize, name: []const u8) ?*const traits.Method {
    const h = enclosing(text, at) orelse return traits.event(name);
    var ws = std.mem.tokenizeAny(u8, h, ", \t:");
    while (ws.next()) |w| if (traits.Role.of(w) != null) if (traits.lookup(traits.find(w).?, name)) |m| return m;
    const kind = hostKind(p, a, h);
    if (kind.len == 0) return traits.event(name);
    return traits.lookup(traits.ofHost(kind) orelse return null, name);
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == ':';
}

test "traitinfo: the words after host., self. and as(T). by type" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = fromTexts(a, &.{.{ .name = "rules\\abilities.ss", .data = sample }});
    const has = struct {
        fn f(l: []const []const u8, w: []const u8) bool {
            for (l) |x| if (std.mem.eql(u8, x, w)) return true;
            return false;
        }
    }.f;
    const t1 = sample ++ "component Q for Hero { fn OnSpawn() { host.";
    try std.testing.expect(has(members(&p, a, t1, t1.len - 1), "max_hp") and has(members(&p, a, t1, t1.len - 1), "alive"));
    const t2 = sample ++ "component Q for item { fn f() { host.as(foundation::Hero).";
    try std.testing.expect(has(members(&p, a, t2, t2.len - 1), "party_slot"));
    const t3 = "module abilities {\n    component M : Shielded {\n    param int charge;\n    fn f() { self.";
    const p3 = fromTexts(a, &.{.{ .name = "x", .data = sample ++ "component M2 : abilities::Shielded { param int charge; }\n" }});
    // A trait's host kind through its supertraits (Shielded: Fighter).
    try std.testing.expect(has(members(&p3, a, t3[0 .. t3.len - 6] ++ "host.", t3.len - 6 + 4), "hp"));
    const t4 = "component M2 : abilities::Shielded {\n fn g() { self.";
    try std.testing.expect(has(members(&p3, a, t4, t4.len - 1), "absorb") and has(members(&p3, a, t4, t4.len - 1), "charge"));
    // The hover: a level's OnEnter, a hero's OnLevelUp, a Shielded component's OnHit.
    const lv = "component L for level {\n    fn OnEnter() { }";
    try std.testing.expectEqual(0, engineMethodAt(&p, a, lv, lv.len, "OnEnter").?.arity());
    const hero = "component H for Hero {\n    fn OnLevelUp(level) { }";
    try std.testing.expectEqual(1, engineMethodAt(&p, a, hero, hero.len, "OnLevelUp").?.arity());
    try std.testing.expectEqual(3, engineMethodAt(&p3, a, t4, t4.len, "OnHit").?.arity());
    try std.testing.expect(engineMethodAt(&p, a, lv, lv.len, "OnHit") == null);
}

// ---------------------------------------------------------------- stubs

/// Where a method goes in the component (or trait) declared at line `line` of `text`:
/// before its closing brace (strings and comments skipped); null: no body found.
pub fn bodyEnd(text: []const u8, line: u32) ?usize {
    var i: usize = 0;
    var ln: u32 = 1;
    while (ln < line and i < text.len) : (i += 1) ln += @intFromBool(text[i] == '\n');
    var depth: usize = 0;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '"' => {
            i += 1;
            while (i < text.len and text[i] != '"' and text[i] != '\n') : (i += 1) i += @intFromBool(text[i] == '\\');
        },
        '/' => if (i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
        } else if (i + 1 < text.len and text[i + 1] == '*') {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 1 else text.len;
        },
        '{' => depth += 1,
        '}' => {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

/// `methods` (each a whole `fn …` line) inserted into `text` at `at` (a closing brace,
/// `bodyEnd`): each on a line of its own, indented one level inside it, the brace after
/// them; a body on one line (`{ fn a() { } }`) gets them before its brace. The new text
/// and where the first method starts.
pub fn insertMethods(a: Allocator, text: []const u8, at: usize, methods: []const []const u8) !struct { text: []u8, at: usize } {
    const ls = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |k| k + 1 else 0;
    const own_line = std.mem.trim(u8, text[ls..at], " \t").len == 0;
    var out: std.ArrayList(u8) = .empty;
    if (own_line) {
        // `    }`: before the brace's line, one level deeper than it.
        const indent = text[ls..at];
        try out.appendSlice(a, text[0..ls]);
        const first = out.items.len + indent.len + 4;
        for (methods) |m| try out.print(a, "{s}    {s}\n", .{ indent, m });
        try out.appendSlice(a, text[ls..]);
        return .{ .text = try out.toOwnedSlice(a), .at = first };
    }
    try out.appendSlice(a, text[0..at]);
    if (at > 0 and text[at - 1] != ' ') try out.append(a, ' ');
    const first = out.items.len;
    for (methods) |m| try out.print(a, "{s} ", .{m});
    try out.appendSlice(a, text[at..]);
    return .{ .text = try out.toOwnedSlice(a), .at = first };
}

/// The stub of method `name(params)`: an override calling its default (`super`), else empty.
pub fn stub(a: Allocator, name: []const u8, params: []const []const u8, call_super: bool) []const u8 {
    const ps = std.mem.join(a, ", ", params) catch "";
    return if (call_super)
        std.fmt.allocPrint(a, "fn {s}({s}) {{ return super.{s}({s}); }}", .{ name, ps, name, ps }) catch ""
    else
        std.fmt.allocPrint(a, "fn {s}({s}) {{ }}", .{ name, ps }) catch "";
}

/// The required methods of trait `trait` (and its supertraits) component `c` lacks, as
/// stubs ("Implement Shielded").
pub fn missing(p: *const Project, a: Allocator, c: *const SComp, trait: Ref) []const []const u8 {
    const ts = p.supers(a, trait);
    var out: std.ArrayList([]const u8) = .empty;
    for (p.rows(a, c)) |r| if (r.kind == .required) for (ts) |t| if (r.from.?.eql(t)) {
        out.append(a, stub(a, r.name, r.params, false)) catch {};
        break;
    };
    return out.items;
}

/// `X: no f() (required by T)`: the component and the trait.
pub fn requiredError(msg: []const u8) ?struct { comp: []const u8, trait: []const u8 } {
    const c = std.mem.indexOf(u8, msg, ": no ") orelse return null;
    const r = std.mem.indexOf(u8, msg, "() (required by ") orelse return null;
    if (!std.mem.endsWith(u8, msg, ")") or r < c) return null;
    return .{ .comp = msg[0..c], .trait = msg[r + "() (required by ".len .. msg.len - 1] };
}

const sample =
    \\module abilities {
    \\    trait Shielded: foundation::Fighter {
    \\        fn capacity();
    \\        fn spend(amount);
    \\        fn absorb(amount) { return amount; }
    \\    }
    \\    trait Reflective: Shielded {
    \\        fn reflect_pct();
    \\        fn absorb(amount) { return 0; }
    \\    }
    \\    component Mirror : Reflective {
    \\        fn capacity() { return "}"; } // }
    \\    }
    \\}
    \\component Plain for fighter { fn OnHit(attacker, weapon, amount) { } }
    \\
;

test "traitinfo: closure, rows, implementers, stubs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = fromTexts(a, &.{.{ .name = "rules\\abilities.ss", .data = sample }});
    const m = p.comp("abilities::Mirror").?;
    const cl = p.closure(a, m);
    // Reflective, Shielded, Fighter, Actor, Object.
    try std.testing.expectEqual(5, cl.len);
    try std.testing.expectEqualStrings("abilities::Reflective", cl[0].name());
    try std.testing.expectEqualStrings("Object", cl[4].name());
    const rs = p.rows(a, m);
    try std.testing.expectEqual(4, rs.len);
    try std.testing.expect(rs[0].kind == .own and std.mem.eql(u8, rs[0].from.?.name(), "abilities::Shielded"));
    // reflect_pct, absorb (Reflective's body wins), spend.
    try std.testing.expect(rs[1].kind == .required and std.mem.eql(u8, rs[1].name, "reflect_pct"));
    try std.testing.expect(rs[2].kind == .default and std.mem.eql(u8, rs[2].from.?.name(), "abilities::Reflective"));
    try std.testing.expect(rs[3].kind == .required and std.mem.eql(u8, rs[3].params[0], "amount"));
    const plain = p.comp("Plain").?;
    try std.testing.expectEqualStrings("chain", @tagName(p.rows(a, plain)[0].event.?.combine));
    try std.testing.expectEqual(2, p.implementers(a, .{ .engine = traits.find("Fighter").? }).len);
    try std.testing.expectEqual(1, p.implementers(a, .{ .script = p.trait("abilities::Shielded").? }).len);
    // Reflective needs its own and Shielded's; Shielded only its own.
    try std.testing.expectEqual(2, missing(&p, a, m, .{ .script = p.trait("abilities::Reflective").? }).len);
    try std.testing.expectEqual(1, missing(&p, a, m, .{ .script = p.trait("abilities::Shielded").? }).len);
    // The brace after the string and the comment: the component's own.
    const at = bodyEnd(sample, m.it.line).?;
    try std.testing.expectEqualStrings("    }\n}", sample[at - 4 .. at + 3]);
    const r = try insertMethods(a, sample, at, &.{"fn spend(amount) { }"});
    try std.testing.expect(std.mem.indexOf(u8, r.text, "// }\n        fn spend(amount) { }\n    }\n}") != null);
    try std.testing.expectEqualStrings("fn spend", r.text[r.at .. r.at + 8]);
    const pl = bodyEnd(sample, plain.it.line).?;
    const r2 = try insertMethods(a, sample, pl, &.{"fn OnSpawn() { }"});
    try std.testing.expect(std.mem.endsWith(u8, r2.text, "{ } fn OnSpawn() { } }\n"));
    try std.testing.expectEqualStrings("fn absorb(amount) { return super.absorb(amount); }", stub(a, "absorb", &.{"amount"}, true));
    const e = requiredError("Mirror: no capacity() (required by Shielded)").?;
    try std.testing.expectEqualStrings("Shielded", e.trait);
    try std.testing.expectEqualStrings("Mirror", e.comp);
    try std.testing.expect(nativesOf(a, traits.find("Monitor").?).len == 1);
    // The engine's types are foundation's; data names them bare; a project's own beside them.
    const q = fromTexts(a, &.{.{ .name = "x", .data = "enum Side { left }\nmodule m { use foundation; }\n" }});
    try std.testing.expectEqualStrings("left", q.enumNamed(a, "", &.{}, "Side").?.values[0].name);
    try std.testing.expectEqualStrings("hero", q.enumNamed(a, "", &.{}, "foundation::Side").?.values[0].name);
    try std.testing.expect(q.enumNamed(a, "", &.{}, "ItemPlace") != null and q.structNamed(a, "", &.{}, "Place") != null);
    try std.testing.expect(q.resolve(a, "m", &.{"foundation"}, "Hero").? == .engine);
    try std.testing.expect(q.resolve(a, "", &.{}, "foundation::Fighter").? == .engine);
    try std.testing.expect(nativesOf(a, traits.find("Fighter").?).len > 5);
}

test "traitinfo: every prelude label has its translation (text.zig prelude)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tx = @import("text.zig");
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(arena.allocator(), traits.types, "engine.ogs", &diag);
    var n: usize = 0;
    var types: usize = 0;
    for (u.modules) |m| {
        // Every type its name, every value and field its label (Slot, Camera too).
        for (m.enums) |e| try std.testing.expect(tx.preludeType(e.name) != null);
        for (m.structs) |s| try std.testing.expect(tx.preludeType(s.name) != null);
        types += m.enums.len + m.structs.len;
        for (m.enums) |e| for (e.values) |v| {
            try std.testing.expect(v.label.len > 0);
            try std.testing.expectEqualStrings(v.label, tx.preludeLabel(e.name, v.name).?);
            n += 1;
        };
        for (m.structs) |s| for (s.fields) |f| {
            try std.testing.expect(f.doc.len > 0);
            try std.testing.expectEqualStrings(f.doc, tx.preludeLabel(s.name, f.name).?);
            n += 1;
        };
    }
    try std.testing.expectEqual(tx.prelude.len, n);
    try std.testing.expectEqual(tx.prelude_types.len, types);
}
