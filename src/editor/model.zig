//! The editor's entity fields: an object's variables as the model holds
//! them — by layer (schema default, archetype: the class snippet its init includes,
//! instance: its own file, `.var`: its starting values) — read from the lifted creation
//! events (`script/classic/lift.zig` over the Store's texts), written at one point.
//!
//! An entity is a script file of the Store (`.ftr`, `.wpn`, `.lev`, a class `ci_x.s`, an
//! archetype snippet `ft_x.ss`). `set` changes a value the model lifted through the Classic
//! exporter (only the literal's bytes, `classic/export.zig`); a field the file does not set
//! yet is a new line (the lift cannot add fields yet "not done"). Each `set`
//! is one undo step.
//!
//! Single values of a text are still read by `get`/`getStr` (formats/assigns.zig, the
//! composition's reader): shortcut: pages read a field's text, until they lay out views.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const script = og.script;
const ast = script.ast;
const ir = script.ir;
const lift = script.classic.lift;
const Value = script.value.Value;
const Runtime = script.runtime.Runtime;
const schema = og.core.schema;
const classic_names = script.classic.names;
const assigns = og.formats.assigns;
const App = @import("app.zig").App;
const common_archive = @import("store.zig").common_archive;

pub const isIdent = assigns.isIdent;

/// Field `name` (the engine's name) assigned in a text: an OG block's, or a Classic file's
/// by the exe's spelling (`classic/names.zig`: an item's `icon` is its `spriteFile`).
pub fn find(text: []const u8, name: []const u8) ?assigns.Span {
    return assigns.find(text, name) orelse assigns.find(text, classic_names.anyOld(name) orelse return null);
}

pub fn getStr(text: []const u8, name: []const u8) ?[]const u8 {
    const s = find(text, name) orelse return null;
    if (text[s.start] != '"') return null;
    return text[s.start + 1 .. s.end - 1];
}

pub fn get(text: []const u8, name: []const u8) ?f32 {
    if (find(text, name)) |s| return std.fmt.parseFloat(f32, text[s.start..s.end]) catch null;
    return enumWord(name, wordOf(text, name) orelse return null);
}

/// The word the last `name = word;` of a text gives (an OG block's enum value).
fn wordOf(text: []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, name)) |p| : (i = p + name.len) {
        if (p > 0 and isIdent(text[p - 1])) continue;
        var k = p + name.len;
        if (k < text.len and isIdent(text[k])) continue;
        while (k < text.len and text[k] == ' ') k += 1;
        if (k + 1 >= text.len or text[k] != '=' or text[k + 1] == '=') continue;
        k += 1;
        while (k < text.len and text[k] == ' ') k += 1;
        const a = k;
        while (k < text.len and isIdent(text[k])) k += 1;
        if (k > a and k < text.len and text[k] == ';' and !std.ascii.isDigit(text[a])) found = text[a..k];
    }
    return found;
}

/// An OG block's enum word of field `name` (`battle_class = grandma`) as its number; a
/// weapon class's name (`class = pistol`) its rules' number; `action = walk` −1.
fn enumWord(name: []const u8, word: []const u8) ?f32 {
    if (std.mem.eql(u8, name, "class") or std.mem.eql(u8, name, "attack_zone")) return @floatFromInt(og.rules.weaponClassId(word) orelse return null);
    if (std.mem.eql(u8, name, "battle_class")) return @floatFromInt(og.rules.fighterClassId(word) orelse return null);
    if (std.mem.startsWith(u8, name, "action")) return @floatFromInt(schema.noAction(word) orelse (og.rules.actionNamed(word) orelse return null).classic_id);
    for (&schema.hosts) |*h| if (schema.field(h, name)) |fd| if (fd.type_name.len > 0) {
        const v = model_og.enumNumber(fd.type_name, word) orelse return null;
        return @floatFromInt(v.int);
    };
    return null;
}

/// A text's class: a fighter's `battle_class` or a weapon's `class` (the exe's `classType`).
pub fn classOf(text: []const u8) ?f32 {
    return get(text, "battle_class") orelse get(text, "class");
}

/// `assigns.inherited` by the engine's name (`find`).
pub fn inherited(lib: anytype, text: []const u8, name: []const u8, depth: u8) ?f32 {
    // An OG block's enum word (`get`) has no include to follow.
    return assigns.inherited(lib, text, name, depth) orelse get(text, name) orelse assigns.inherited(lib, text, classic_names.anyOld(name) orelse return null, depth);
}

/// `assigns.definer` by the engine's name (`find`).
pub fn definer(lib: anytype, text: []const u8, name: []const u8, depth: u8) ?[]const u8 {
    return assigns.definer(lib, text, name, depth) orelse assigns.definer(lib, text, classic_names.anyOld(name) orelse return null, depth);
}
pub const joins = assigns.joins;
pub const directives = assigns.directives;

/// Where a field's value comes from (lift's layers; `schema`: no text sets it).
pub const Layer = enum { schema, archetype, instance, vars };

/// A field of an entity as the inspector shows it.
pub const View = struct {
    name: []const u8,
    /// In force; null: no layer sets it and the schema does not know it.
    value: ?Value = null,
    layer: Layer = .schema,
    /// Set in the entity's own file (an override when `below` is set too).
    own: bool = false,
    /// The value without the own one (what a reset gives): an archetype's, a `.var`'s.
    below: ?Value = null,
    below_layer: Layer = .schema,
    /// An own value's bytes in the file (its literal).
    span: ir.Span = .{},
    /// The schema's type (null: the class's own variable or unknown).
    type: ?ir.Type = null,
    only_og: bool = false,
    /// An OpenGorky block's value as written (a list, a record, a word too; model_og.zig).
    og_expr: ?*const ir.Expr = null,

    /// The value as a field shows it ("—": none).
    pub fn text(v: View, a: Allocator) []const u8 {
        return show(a, v.value);
    }
};

pub fn show(a: Allocator, v: ?Value) []const u8 {
    return switch (v orelse return "—") {
        .int => |i| std.fmt.allocPrint(a, "{d}", .{i}) catch "?",
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}) catch "?",
        .string => |s| s,
        else => "?",
    };
}

/// A number field's value (f32, as the pages compare them).
pub fn num(v: ?Value) ?f32 {
    return switch (v orelse return null) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

// ---------------------------------------------------------------- the model of a file

const Event = struct { f: *const ir.Fn, l: lift.Lifted };

/// The lifted model of one Store file and what it was built from.
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    file: usize,
    /// Lower-case name of the file as its scripts name it (origins compare to it).
    key: []const u8,
    rt: Runtime,
    events: []const Event = &.{},
    vars: []const lift.Field = &.{},
    host: ?*const schema.Host = null,
    /// Its class (every function's IR is compiled from it on demand: `sites`).
    cls: ?*script.object.Class = null,
    /// An archetype snippet, lifted through a stand-in class: its own values are the
    /// archetype's.
    snippet: bool = false,
    /// Store files read and their texts' hashes (the model is stale when one changed).
    read: std.ArrayList([2]u64) = .empty,

    fn fresh(m: *const Model, app: *App) bool {
        for (m.read.items) |r| {
            const i: usize = @intCast(r[0]);
            if (i >= app.store.files.items.len or std.hash.Wyhash.hash(0, app.store.text(i)) != r[1]) return false;
        }
        return true;
    }
};

/// Fetches scripts for the model's runtime: the entity's archive, then common/other.dat
/// (`classes\`, `scriptlets\`, `gamestart\`), as the world resolves them.
const Src = struct {
    app: *App,
    m: *Model,
    archive: []const u8,
    /// The snippet's stand-in class (an archetype entity has no class of its own).
    stand_in: ?[]const u8 = null,

    fn fetch(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
        const self: *Src = @ptrCast(@alignCast(ctx));
        if (std.ascii.eqlIgnoreCase(name, stand_in_name)) return self.stand_in;
        const st = &self.app.store;
        const i = st.file(self.archive, name) catch blk: {
            var buf: [256]u8 = undefined;
            for ([_][]const u8{ "classes", "scriptlets", "gamestart" }) |dir| {
                const p = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ dir, name }) catch continue;
                break :blk st.file(common_archive, p) catch continue;
            }
            return null;
        };
        return try self.note(i);
    }

    /// File `i`'s text, copied into the model, its hash kept.
    fn note(self: *Src, i: usize) ![]const u8 {
        const t = self.app.store.text(i);
        try self.m.read.append(self.m.arena.allocator(), .{ i, std.hash.Wyhash.hash(0, t) });
        return try self.m.arena.allocator().dupe(u8, t);
    }
};

const stand_in_name = "~model~.s";

fn noBuiltin(_: *anyopaque, _: *Runtime, _: *script.object.Object, _: []const Value) anyerror!Value {
    return .zero;
}

/// The creation events whose data the model holds, and the functions the lift reads like
/// them: `class_init` (an item class's fields: `ci_bandage.s`), `post_init_box` (an
/// exploration box's contents, ci_box.s's post_init calls it), `additionalIdleAnims` (a
/// hero's idles in more stances).
fn lifted(name: []const u8) bool {
    if (lift.isEvent(name)) return true;
    for ([_][]const u8{ "class_init", "post_init_box", "additionalIdleAnims" }) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

/// The model shows data the runtime's lift leaves as code: values and calls after a call
/// (an item's after its `class_init();`), calls with an argument that is no literal (`spd`).
const lift_opts: lift.Opts = .{ .calls_pass = true, .opaque_args = true };

/// The last models built (pages draw a file's fields every frame). shortcut: a model is
/// stale only when a file it read changed, not when a new file would shadow one (a `.var`
/// made, a class copied into a level); rebuilt then on the next change of its own.
var cache: [8]?*Model = @splat(null);
var cache_next: usize = 0;

/// File `file`'s model; null: its scripts do not parse (the pages read the text).
pub fn modelOf(app: *App, file: usize) ?*Model {
    for (cache) |c| if (c) |m| if (m.file == file and m.fresh(app)) return m;
    const m = build(app, file) catch |err| {
        std.log.debug("model of {s}: {t}", .{ app.store.files.items[file].entry, err });
        return null;
    };
    if (cache[cache_next]) |old| drop(old);
    cache[cache_next] = m;
    cache_next = (cache_next + 1) % cache.len;
    return m;
}

fn drop(m: *Model) void {
    var arena = m.arena;
    arena.deinit();
}

fn build(app: *App, file: usize) !*Model {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const m = arena.allocator().create(Model) catch |err| {
        arena.deinit();
        return err;
    };
    m.* = .{ .arena = arena, .file = file, .key = "", .rt = undefined };
    errdefer drop(m);
    const a = m.arena.allocator();
    const sf = app.store.files.items[file];
    const base = baseName(sf.entry);
    m.key = try std.ascii.allocLowerString(a, base);
    const src = try a.create(Src);
    src.* = .{ .app = app, .m = m, .archive = sf.archive };
    m.rt = .init(a, .{ .ctx = src, .fetch = Src.fetch });
    inline for (og.builtins.table) |e| try m.rt.registerBuiltinSig(e[0], src, noBuiltin, e[2]);
    // Its own text read first (its hash kept even when no class reads it).
    var diag: script.parser.Diagnostic = .{};
    const unit = try script.parser.parse(a, try src.note(file), &diag);
    const class_file = for (unit.items) |it| {
        if (it == .function) break base;
    } else blk: {
        // A snippet: lifted where a stand-in init includes it, every schema field declared.
        src.stand_in = try std.fmt.allocPrint(a, "function init()\r\n{{\r\n#include {s}\r\n}};\r\n", .{base});
        break :blk stand_in_name;
    };
    const cls = try m.rt.loadClass(class_file);
    // A snippet's code names fields as its includer's host does (classic/names.zig).
    if (src.stand_in != null) cls.host = snippetHost(app, base);
    if (src.stand_in != null) for (&schema.hosts) |*h| for (h.fields) |x| {
        const id = try script.object.intern(x.name);
        for (cls.vars.items) |d| {
            if (d.id == id) break;
        } else try cls.vars.append(a, .{ .type = x.type, .name = x.name, .line = 0, .id = id });
    };
    const fkey = try std.ascii.allocLowerString(a, class_file);
    m.cls = cls;
    var events: std.ArrayList(Event) = .empty;
    var it = cls.functions.valueIterator();
    while (it.next()) |func| {
        const name = if (func.*.ast) |x| x.name else continue;
        if (!lifted(name) or !std.mem.eql(u8, func.*.file, fkey)) continue;
        const f = try m.rt.compiled(func.*);
        // class_init first: the item's class sets its fields before an instance's init.
        const e: Event = .{ .f = f, .l = try lift.liftWith(a, m.rt.importEnv(), f, cls, lift_opts) };
        if (std.ascii.eqlIgnoreCase(name, "class_init")) try events.insert(a, 0, e) else try events.append(a, e);
    }
    m.events = events.items;
    // Its `.var` (common/other.dat variables\<name>.var), applied before init.
    var vb: [256]u8 = undefined;
    const vname = try std.fmt.bufPrint(&vb, "variables\\{s}.var", .{std.fs.path.stem(base)});
    if (app.store.file(common_archive, vname)) |vi| {
        const vt = try src.note(vi);
        const parsed = try og.formats.vars.parse(a, vt);
        m.vars = try lift.varFields(a, cls, try std.ascii.allocLowerString(a, vname), vt, parsed.entries);
    } else |_| {}
    const names = try a.alloc([]const u8, cls.vars.items.len);
    for (cls.vars.items, names) |d, *n| n.* = d.name;
    m.snippet = src.stand_in != null;
    m.host = if (m.snippet) null else schema.hostOf(names);
    return m;
}

/// Snippet hosts found (lower-case base name → its includers' host; null: none has one),
/// as of Store revision `rev`. shortcut: a host found is kept for the session (an include
/// edited away still names it); a miss is looked for again after an edit.
var snippet_hosts: struct { map: std.StringHashMapUnmanaged(?classic_names.Host) = .empty, rev: u64 = std.math.maxInt(u64) } = .{};

/// The host of the files that include snippet `base` (`ft_x.ss` a level's fighter's,
/// `act_x.ss` its `ft_x.ss`'s, `wp_x.ss` a `.wpn`'s): the deepest
/// base class any of them includes or inherits (`classes\fighter.s`), else that of the
/// snippets including it, 4 deep (uses.zig: the levels' and the common scripts).
fn snippetHost(app: *App, base: []const u8) ?classic_names.Host {
    var kb: [128]u8 = undefined;
    if (base.len > kb.len) return null;
    const key = std.ascii.lowerString(&kb, base);
    if (snippet_hosts.map.get(key)) |h| if (h != null or snippet_hosts.rev == app.store.rev) return h;
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    const h = includerHost(tmp.allocator(), @import("uses.zig").get(app), base, 4);
    const k = app.gpa.dupe(u8, key) catch return h;
    const gop = snippet_hosts.map.getOrPut(app.gpa, k) catch return h;
    if (gop.found_existing) app.gpa.free(k);
    gop.value_ptr.* = h;
    snippet_hosts.rev = app.store.rev;
    return h;
}

fn includerHost(a: Allocator, ix: anytype, base: []const u8, depth: u8) ?classic_names.Host {
    if (depth == 0) return null;
    var host: ?classic_names.Host = null;
    for (ix.levels) |lv| host = includedIn(a, ix, lv.files, base, depth, host);
    return includedIn(a, ix, ix.scripts, base, depth, host);
}

fn includedIn(a: Allocator, ix: anytype, files: []const @import("refs.zig").File, base: []const u8, depth: u8, found: ?classic_names.Host) ?classic_names.Host {
    var host = found;
    for (files) |f| {
        const ds = directives(a, f.text);
        const named = for (ds) |d| {
            if (std.ascii.eqlIgnoreCase(baseName(d), base)) break true;
        } else false;
        if (!named) continue;
        var own: ?classic_names.Host = null;
        for (ds) |d| if (classic_names.Host.ofFile(d)) |x| {
            own = classic_names.Host.deeper(own, x);
        };
        // A snippet including it (`ft_x.ss` its `act_x.ss`): its own includers'.
        if (own == null) own = includerHost(a, ix, baseName(f.name), depth - 1);
        if (own) |x| host = classic_names.Host.deeper(host, x);
    }
    return host;
}

pub fn deinitSnippets(gpa: Allocator) void {
    var it = snippet_hosts.map.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    snippet_hosts.map.deinit(gpa);
    snippet_hosts = .{};
}

// ---------------------------------------------------------------- reading

/// Field `name` of entity `file`: the last value the model sets (after `.var`, in event
/// order), its layer, and the one under it.
pub fn field(app: *App, file: usize, name: []const u8) View {
    var v: View = .{ .name = name };
    if (app.store.files.items.len <= file) return v;
    if (model_og.isOg(app, file)) return model_og.field(app, file, name);
    const m = modelOf(app, file) orelse {
        // Unparsed (code being typed): the text's own value.
        const t = app.store.text(file);
        if (get(t, name)) |x| v = .{ .name = name, .value = .{ .float = x }, .layer = .instance, .own = true } else if (getStr(t, name)) |x| v = .{ .name = name, .value = .{ .string = x }, .layer = .instance, .own = true };
        return v;
    };
    if (m.host) |h| {
        if (schema.field(h, name)) |s| {
            v.type = s.type;
            v.only_og = s.only_og;
            v.value = s.default();
        }
    } else for (&schema.hosts) |*h| if (schema.field(h, name)) |s| {
        // A snippet's host is whoever includes it: the field's type, no default.
        v.type = s.type;
        v.only_og = s.only_og;
        break;
    };
    v.below = v.value;
    for (m.vars) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) {
        v.value = x.value;
        v.layer = .vars;
        v.below = x.value;
        v.below_layer = .vars;
    };
    for (m.events) |e| for (e.l.items) |it| {
        if (it != .field or !std.ascii.eqlIgnoreCase(it.field.name, name)) continue;
        const x = it.field;
        const own = std.mem.eql(u8, x.origin.file, m.key);
        v.value = x.value;
        v.layer = layerOf(x.origin.layer, own, m);
        v.own = own;
        v.span = if (own) x.origin.span else .{};
        if (!own) {
            v.below = x.value;
            v.below_layer = v.layer;
        }
    };
    return v;
}

/// A lifted value's layer as the entity sees it: its own file is the instance (a
/// snippet's values are the archetype's).
fn layerOf(l: lift.Layer, own: bool, m: *const Model) Layer {
    if (own) return if (m.snippet) .archetype else .instance;
    return switch (l) {
        .base => .schema,
        .archetype => .archetype,
        .instance => .instance,
        .vars => .vars,
    };
}

/// The Store file whose text `text` is (a slice `app.store.text` gave); null: another text.
pub fn fileOf(app: *App, text: []const u8) ?usize {
    for (app.store.files.items, 0..) |_, i| if (app.store.text(i).ptr == text.ptr) return i;
    return null;
}

/// The schema host of entity `file` (null: a snippet, or its scripts do not parse).
pub fn hostOf(app: *App, file: usize) ?*const schema.Host {
    return (modelOf(app, file) orelse return null).host;
}

/// A variable entity `file` declares itself (outside its functions): `int readyF01;   //
/// battle 1` of a `.lev`.
pub const Decl = struct { name: []const u8, type: ir.Type, comment: []const u8, at: usize };

pub fn declared(app: *App, a: Allocator, file: usize) []const Decl {
    const text = app.store.text(file);
    var diag: script.parser.Diagnostic = .{};
    const unit = script.parser.parse(a, text, &diag) catch return &.{};
    var out: std.ArrayList(Decl) = .empty;
    for (unit.items) |it| if (it == .var_decl) {
        const d = it.var_decl;
        // The comment after it on its line.
        const eol = std.mem.indexOfScalarPos(u8, text, d.end, '\n') orelse text.len;
        const tail = text[@min(d.end, eol)..eol];
        const cm = if (std.mem.indexOf(u8, tail, "//")) |k| std.mem.trim(u8, tail[k + 2 ..], " \t\r") else "";
        out.append(a, .{ .name = d.name, .type = d.type, .comment = cm, .at = d.start }) catch {};
    };
    return out.items;
}

/// Field `name`'s value that entity `file` sets itself (null: it does not, or not as a
/// literal the model lifts): what a page shows of the file's own text.
fn ownValue(app: *App, file: usize, name: []const u8) ?Value {
    const v = field(app, file, name);
    return if (v.own) v.value else null;
}

/// `ownValue` of a number.
pub fn ownNum(app: *App, file: usize, name: []const u8) ?f32 {
    return num(ownValue(app, file, name));
}

/// `ownValue` of a string: its bytes in the file's text (as long-lived as the text, not
/// the model's copy, which a later model may drop).
pub fn ownStr(app: *App, file: usize, name: []const u8) ?[]const u8 {
    const v = field(app, file, name);
    const s = if (v.own and v.value != null and v.value.? == .string) v.value.?.string else return null;
    const t = app.store.text(file);
    if (v.span.end <= t.len and v.span.end >= v.span.start + 2) {
        const in = t[v.span.start + 1 .. v.span.end - 1];
        if (std.mem.eql(u8, in, s)) return in;
    }
    return s;
}

/// `ownNum` of the Store text `text` (a slice `app.store.text` gave; another text, a made
/// up one, is read as text).
pub fn textNum(app: *App, text: []const u8, name: []const u8) ?f32 {
    return if (fileOf(app, text)) |f| ownNum(app, f, name) else get(text, name);
}

/// `ownStr` of the Store text `text` (`textNum`).
pub fn textStr(app: *App, text: []const u8, name: []const u8) ?[]const u8 {
    return if (fileOf(app, text)) |f| ownStr(app, f, name) else getStr(text, name);
}

/// A declarative builtin call (`Runtime.Sig.data`: RegisterAnimation, Item_New, …) that
/// entity `file` makes itself in an event the model lifts.
pub const Call = struct {
    /// The event holding it (`init`, `post_init_box`).
    event: []const u8,
    name: []const u8,
    args: []const Value,
    /// Its bytes in the file (the call, without `;`) and each argument's.
    span: ir.Span,
    arg_spans: []const ir.Span,
};

/// Entity `file`'s own calls to one of `names`, in the text's order, copied into `a`.
pub fn calls(app: *App, a: Allocator, file: usize, names: []const []const u8) []const Call {
    const m = modelOf(app, file) orelse return &.{};
    var out: std.ArrayList(Call) = .empty;
    for (m.events) |e| for (e.l.items) |it| {
        if (it != .call or !std.mem.eql(u8, it.call.origin.file, m.key)) continue;
        const x = it.call;
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(n, x.name)) break;
        } else continue;
        const c = e.f.body[x.origin.at].kind.expr.kind.call;
        const spans = a.alloc(ir.Span, c.args.len) catch continue;
        for (c.args, spans) |arg, *sp| sp.* = arg.span;
        const args = a.alloc(Value, x.args.len) catch continue;
        for (x.args, args) |v, *d| d.* = if (v == .string) .{ .string = a.dupe(u8, v.string) catch continue } else v;
        out.append(a, .{ .event = a.dupe(u8, e.f.name) catch continue, .name = a.dupe(u8, x.name) catch continue, .args = args, .span = x.origin.span, .arg_spans = spans }) catch {};
    };
    std.mem.sort(Call, out.items, {}, struct {
        fn lt(_: void, p: Call, q: Call) bool {
            return p.span.start < q.span.start;
        }
    }.lt);
    return out.items;
}

/// A call statement in a function entity `file` defines (any function, any depth; the
/// IR, so comments and included statements are not in it).
pub const Site = struct {
    /// The function holding it, as written.
    func: []const u8,
    /// Directly in the function's body.
    top: bool,
    call: *const ir.Call,
    /// The statement's bytes, its `;` included (a call that is an `if`'s condition: the call).
    stmt: ir.Span,
    /// Conditions over its innermost braced block: the `if` owning that block and the
    /// braceless `if`s it is the body of (`if(a) if(b) { … }`: a and b).
    conds: []const *const ir.Expr,
};

/// Entity `file`'s scripts parse: it has a model.
pub fn parses(app: *App, file: usize) bool {
    return modelOf(app, file) != null;
}

/// Entity `file`'s calls to one of `names` in its own functions, in the text's order; they
/// point into the model (read them before the next model call).
pub fn sites(app: *App, a: Allocator, file: usize, names: []const []const u8) []const Site {
    const m = modelOf(app, file) orelse return &.{};
    var fns: std.ArrayList(*const ir.Fn) = .empty;
    var it = m.cls.?.functions.valueIterator();
    while (it.next()) |func| if (func.*.ast != null and std.mem.eql(u8, func.*.file, m.cls.?.name))
        fns.append(a, m.rt.compiled(func.*) catch continue) catch {};
    return sitesOf(a, app.store.text(file), m.cls.?.name, fns.items, names) catch &.{};
}

/// Function `name` of entity `file`: from `function` through its `};` (null: none).
pub fn funcSpan(app: *App, file: usize, name: []const u8) ?ir.Span {
    const m = modelOf(app, file) orelse return null;
    var it = m.cls.?.functions.valueIterator();
    while (it.next()) |func| if (func.*.ast) |x| if (std.ascii.eqlIgnoreCase(x.name, name) and std.mem.eql(u8, func.*.file, m.cls.?.name))
        return (m.rt.compiled(func.*) catch return null).span;
    return null;
}

/// `sites` of functions `fns` of file `key` (lower-case), whose text is `text`.
pub fn sitesOf(a: Allocator, text: []const u8, key: []const u8, fns: []const *const ir.Fn, names: []const []const u8) ![]const Site {
    var out: std.ArrayList(Site) = .empty;
    const w: Walk = .{ .a = a, .text = text, .key = key, .names = names, .out = &out };
    for (fns) |f| try w.list(f.name, f.body, true, &.{}, &.{});
    std.mem.sort(Site, out.items, {}, struct {
        fn lt(_: void, p: Site, q: Site) bool {
            return p.stmt.start < q.stmt.start;
        }
    }.lt);
    return out.items;
}

const Walk = struct {
    a: Allocator,
    text: []const u8,
    key: []const u8,
    names: []const []const u8,
    out: *std.ArrayList(Site),

    /// `guard`: the conditions over the innermost braced block; `chain`: of the braceless
    /// `if`s since it.
    fn list(w: Walk, func: []const u8, body: []const ir.Stmt, top: bool, guard: []const *const ir.Expr, chain: []const *const ir.Expr) Allocator.Error!void {
        for (body) |*s| {
            if (!std.mem.eql(u8, s.file, w.key)) continue;
            switch (s.kind) {
                .expr => |e| try w.site(func, top, e, s.span, guard),
                .@"if" => |x| {
                    // `if(PlaceActor("BT",-30,-30))`: the call alone (no statement of its own).
                    var c = x.cond;
                    while (c.kind == .exe and c.kind.exe.args.len == 1) c = c.kind.exe.args[0];
                    try w.site(func, top, c, c.span, guard);
                    const both = try std.mem.concat(w.a, *const ir.Expr, &.{ chain, &.{x.cond} });
                    if (x.then.len > 0) {
                        if (w.braced(x.cond.span.end, x.then[0].span.start))
                            try w.list(func, x.then, false, both, &.{})
                        else
                            try w.list(func, x.then, false, guard, both);
                    }
                    if (x.@"else".len > 0) {
                        const from = if (x.then.len > 0) x.then[x.then.len - 1].span.end else x.cond.span.end;
                        try w.list(func, x.@"else", false, if (w.braced(from, x.@"else"[0].span.start)) &.{} else guard, &.{});
                    }
                },
                .@"while" => |x| try w.list(func, x.body, false, &.{}, &.{}),
                .for_in => |x| try w.list(func, x.body, false, &.{}, &.{}),
                else => {},
            }
        }
    }

    fn site(w: Walk, func: []const u8, top: bool, e: *const ir.Expr, span: ir.Span, guard: []const *const ir.Expr) Allocator.Error!void {
        if (e.kind != .call) return;
        for (w.names) |n| if (std.ascii.eqlIgnoreCase(n, e.kind.call.text))
            return w.out.append(w.a, .{ .func = func, .top = top, .call = &e.kind.call, .stmt = span, .conds = guard });
    }

    /// A `{` opens a block between `from` and `to` (after any `}` there).
    fn braced(w: Walk, from: u32, to: u32) bool {
        if (from > to or to > w.text.len) return false;
        const t = w.text[from..to];
        const open = std.mem.lastIndexOfScalar(u8, t, '{') orelse return false;
        return if (std.mem.lastIndexOfScalar(u8, t, '}')) |close| open > close else true;
    }
};

/// Names of the numeric fields entity `file` sets itself, first-seen order.
pub fn ownNumbers(app: *App, a: Allocator, file: usize) []const []const u8 {
    const m = modelOf(app, file) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (m.events) |e| for (e.l.items) |it| {
        if (it != .field or !std.mem.eql(u8, it.field.origin.file, m.key) or it.field.value == .string) continue;
        for (out.items) |o| {
            if (std.ascii.eqlIgnoreCase(o, it.field.name)) break;
        } else out.append(a, a.dupe(u8, it.field.name) catch continue) catch {};
    };
    return out.items;
}

// ---------------------------------------------------------------- code (OG Script view)

/// Entity `file`'s own functions (its class's, defined in it), compiled, in the text's
/// order; null: no model (it does not parse) or an archetype snippet (no functions).
fn ownFns(m: *Model, a: Allocator) ?[]const *const ir.Fn {
    if (m.snippet) return null;
    var fns: std.ArrayList(*const ir.Fn) = .empty;
    var it = m.cls.?.functions.valueIterator();
    while (it.next()) |func| if (func.*.ast != null and std.mem.eql(u8, func.*.file, m.cls.?.name))
        fns.append(a, m.rt.compiled(func.*) catch return null) catch return null;
    std.mem.sort(*const ir.Fn, fns.items, {}, struct {
        fn lt(_: void, p: *const ir.Fn, q: *const ir.Fn) bool {
            return p.span.start < q.span.start;
        }
    }.lt);
    return fns.items;
}

/// Classic entity `file` as OG Script: the lines
/// before its first function as comments (the header: `#inherit`, declarations — the IR
/// has none), then each function printed from its IR (`#include`d statements inline) with
/// OGS's builtin names (`classic/rename.zig`); game bytes, in `a`. Null: no model, or no
/// function to show.
pub fn ogsText(app: *App, a: Allocator, file: usize) ?[]const u8 {
    const m = modelOf(app, file) orelse return null;
    const fns = ownFns(m, a) orelse return null;
    return ogsOf(a, app.store.text(file), fns, m.rt.names(), isActor(m.key)) catch null;
}

/// File `key` is an actor's script (`Disable()` acts on it: `state/object.zig kindOf`).
fn isActor(key: []const u8) bool {
    return og.state.object.kindOf(std.fs.path.extension(key)) == .actor;
}

fn ogsOf(a: Allocator, text: []const u8, classic: []const *const ir.Fn, names: script.classic.rename.Names, actor: bool) ![]const u8 {
    const fns = try a.alloc(*const ir.Fn, classic.len);
    for (classic, fns) |f, *o| o.* = try script.classic.rename.toOgs(a, f, names, actor);
    if (fns.len == 0) return error.NoFunctions;
    var w: std.Io.Writer.Allocating = .init(a);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text[0..@min(fns[0].span.start, text.len)], " \t\r\n"), '\n');
    while (lines.next()) |l| if (std.mem.trim(u8, l, " \t\r").len > 0) try w.writer.print("// {s}\n", .{std.mem.trimEnd(u8, l, "\r")});
    for (fns) |f| {
        if (w.written().len > 0) try w.writer.writeByte('\n');
        try script.ogs.print.function(&w.writer, f, 0);
    }
    return w.written();
}

/// Why `setCode` refused: the line of the OG Script text and the message.
pub const CodeDiag = struct { line: u32 = 0, message: []const u8 = "", comments: usize = 0 };

/// Entity `file`'s Classic text with its functions as OG Script text `src` (game bytes)
/// has them: a function changed, added (at the end) or gone, each
/// through the Classic exporter — only the changed nodes' bytes, checked to import back
/// (`error.NotClassic`: no text of the original's language does; `diag` says where).
/// `error.Parse`: `src` is no OG Script; `error.OtherFile`: the change is in an included
/// file; `error.DropsComments`: the export re-prints a block and loses comments (`diag.comments`).
/// The new text in `gpa`; the Store is not written.
pub fn setCode(app: *App, gpa: Allocator, file: usize, src: []const u8, keep_comments: bool, diag: *CodeDiag) ![]u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const m = modelOf(app, file) orelse return error.NoModel;
    const fns = ownFns(m, a) orelse return error.NoModel;
    const new = try codeOf(a, &m.rt, m.key, app.store.text(file), fns, src, keep_comments, diag);
    return gpa.dupe(u8, new);
}

fn codeOf(a: Allocator, rt: *Runtime, key: []const u8, text: []const u8, fns: []const *const ir.Fn, src: []const u8, keep_comments: bool, diag: *CodeDiag) ![]const u8 {
    const ex_mod = script.classic.@"export";
    var pd: script.ogs.parser.Diagnostic = .{};
    const u = script.ogs.parser.parseHosted(a, src, key, &pd) catch |err| {
        if (err == error.OutOfMemory) return err;
        diag.* = .{ .line = pd.line, .message = pd.message };
        return error.Parse;
    };
    var news: std.ArrayList(*const ir.Fn) = .empty;
    for (u.modules) |mod| {
        if (mod.path.len > 0 or mod.components.len + mod.entities.len + mod.rows.len + mod.uses.len > 0) {
            diag.* = .{ .line = if (mod.components.len > 0) mod.components[0].line else 1, .message = "modules, components, data blocks and rows have no Classic text" };
            return error.NotClassic;
        }
        // Back to the exe's names, as each function spelled them.
        for (mod.fns) |f| {
            const old = for (fns) |o| {
                if (std.ascii.eqlIgnoreCase(f.name, o.name)) break o;
            } else null;
            try news.append(a, try script.classic.rename.toClassic(a, f, rt.names(), isActor(key), old));
        }
    }
    var changes: std.ArrayList(ex_mod.Change) = .empty;
    for (fns) |o| {
        const n = for (news.items) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, o.name)) break f;
        } else null;
        try changes.append(a, .{ .old = o, .new = n });
    }
    for (news.items) |n| for (fns) |o| {
        if (std.ascii.eqlIgnoreCase(n.name, o.name)) break;
    } else try changes.append(a, .{ .old = null, .new = n });
    var ex: ex_mod.Export = .init(a, rt.importEnv());
    ex.apply(changes.items) catch |err| {
        if (err == error.NotClassic) diag.* = .{ .line = ex.diag.line, .message = ex.diag.message };
        return err;
    };
    var it = ex.files.iterator();
    while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, key)) {
        diag.* = .{ .message = e.key_ptr.* };
        return error.OtherFile;
    };
    const out = ex.files.get(key) orelse return text;
    // shortcut: comments inside a re-printed node are lost (export.zig "no trivia");
    // counted, the caller asks once before writing (a removed function's go with it).
    const lost = comments(text) -| comments(out);
    if (lost > 0 and !keep_comments) {
        diag.* = .{ .comments = lost };
        return error.DropsComments;
    }
    return out;
}

/// `//` and `/* */` comments of a Classic text (strings skipped).
fn comments(t: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len) : (i += 1) switch (t[i]) {
        '"' => i = std.mem.indexOfAnyPos(u8, t, i + 1, "\"\n") orelse t.len,
        '/' => if (i + 1 < t.len and (t[i + 1] == '/' or t[i + 1] == '*')) {
            n += 1;
            i = if (t[i + 1] == '/') std.mem.indexOfScalarPos(u8, t, i, '\n') orelse t.len else (std.mem.indexOfPos(u8, t, i + 2, "*/") orelse t.len) + 1;
        },
        else => {},
    };
    return n;
}

test "a Classic class as OG Script and back: untouched, one literal, a new function, refusals" {
    const T = struct {
        const src = "#inherit Level\r\nint state;\r\n// the door\r\nfunction init()\r\n{\r\n  state = 1; // first\r\n  if (state) { PlaySound(\"a\"); };\r\n};\r\n";
        fn fetch(_: *anyopaque, name: []const u8) anyerror!?[]const u8 {
            return if (std.ascii.eqlIgnoreCase(name, "x.s")) src else if (std.ascii.eqlIgnoreCase(name, "level.s")) "int a;\r\n" else null;
        }
    };
    var dummy: u8 = 0;
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &dummy, .fetch = T.fetch });
    defer rt.deinit();
    inline for (og.builtins.table) |e| try rt.registerBuiltinSig(e[0], &dummy, noBuiltin, e[2]);
    const a = rt.arena();
    const cls = try rt.loadClass("x.s");
    const fns = [_]*const ir.Fn{try rt.compiled(cls.functions.get(script.object.findName("init").?).?)};
    const view = try ogsOf(a, T.src, &fns, rt.names(), false);
    try std.testing.expect(std.mem.indexOf(u8, view, "sound::Play(\"a\");") != null);
    try std.testing.expect(std.mem.startsWith(u8, view, "// #inherit Level\n// int state;\n// // the door\n\nfn init() {"));
    var d: CodeDiag = .{};
    // Untouched: the same bytes.
    try std.testing.expectEqualStrings(T.src, try codeOf(a, &rt, "x.s", T.src, &fns, view, false, &d));
    // One literal: only its bytes (the comment after it stays).
    const one = try std.mem.replaceOwned(u8, a, view, "= 1;", "= 7;");
    try std.testing.expectEqualStrings("  state = 7; // first", std.mem.trim(u8, (try codeOf(a, &rt, "x.s", T.src, &fns, one, false, &d))[60..82], "\r\n"));
    // A new function: at the end, in the original's language.
    const more = try std.mem.concat(a, u8, &.{ view, "fn Use() { sound::Play(\"b\"); }\n" });
    try std.testing.expect(std.mem.endsWith(u8, try codeOf(a, &rt, "x.s", T.src, &fns, more, false, &d), "};\r\n\r\nfunction Use()\r\n{\r\n    PlaySound(\"b\");\r\n};\r\n"));
    // OG Script only: refused, nothing written.
    try std.testing.expectError(error.NotClassic, codeOf(a, &rt, "x.s", T.src, &fns, try std.mem.concat(a, u8, &.{ view, "component C {}\n" }), false, &d));
    try std.testing.expectError(error.NotClassic, codeOf(a, &rt, "x.s", T.src, &fns, try std.mem.replaceOwned(u8, a, view, "sound::Play(\"a\")", "sound::Play(@a)"), false, &d));
    try std.testing.expectError(error.Parse, codeOf(a, &rt, "x.s", T.src, &fns, "fn init( {", false, &d));
    try std.testing.expect(d.line == 1);
}

test "an actor's Classic script as OG Script and back: merged builtins, \"this\", spellings kept" {
    const T = struct {
        const src = "function init()\r\n{\r\n  DISABLEOBJECT(\"bt\");\r\n  Disable();\r\n  ActorQueueDelay(5);\r\n  Item_DisableWalkCircle(\"this\");\r\n  print(GetName());\r\n};\r\n";
        fn fetch(_: *anyopaque, name: []const u8) anyerror!?[]const u8 {
            return if (std.ascii.eqlIgnoreCase(name, "x.act")) src else null;
        }
    };
    var dummy: u8 = 0;
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &dummy, .fetch = T.fetch });
    defer rt.deinit();
    inline for (og.builtins.table) |e| try rt.registerBuiltinSig(e[0], &dummy, noBuiltin, e[2]);
    const a = rt.arena();
    const cls = try rt.loadClass("x.act");
    const fns = [_]*const ir.Fn{try rt.compiled(cls.functions.get(script.object.findName("init").?).?)};
    const view = try ogsOf(a, T.src, &fns, rt.names(), true);
    try std.testing.expectEqualStrings(
        \\fn init() {
        \\    object::Disable("bt");
        \\    object::Disable(host);
        \\    path::Delay(5);
        \\    item::DisableWalkCircle(host);
        \\    print(host.name);
        \\}
        \\
    , view);
    var d: CodeDiag = .{};
    // Untouched: the same bytes; a changed literal keeps its call's spelling.
    try std.testing.expectEqualStrings(T.src, try codeOf(a, &rt, "x.act", T.src, &fns, view, false, &d));
    const six = try codeOf(a, &rt, "x.act", T.src, &fns, try std.mem.replaceOwned(u8, a, view, "Delay(5)", "Delay(6)"), false, &d);
    try std.testing.expect(std.mem.indexOf(u8, six, "ActorQueueDelay(6);") != null);
    // A new function: the exe's names, "this" for `host`.
    const more = try std.mem.concat(a, u8, &.{ view, "fn Use() { object::Disable(host); object::Disable(\"door\"); path::Delay(1); return item::GetNameID(host); }\n" });
    try std.testing.expect(std.mem.endsWith(u8, try codeOf(a, &rt, "x.act", T.src, &fns, more, false, &d), "function Use()\r\n{\r\n    Disable();\r\n    DisableObject(\"door\");\r\n    ActorDelay(1);\r\n    return(Item_GetNameID(\"this\"));\r\n};\r\n"));
}

// ---------------------------------------------------------------- writing (model_write.zig)

const model_write = @import("model_write.zig");
/// The OG backend (an OpenGorky project's blocks): `field`, `set`, `unset`, `setEach` go there
/// for its files.
pub const model_og = @import("model_og.zig");
pub const set = model_write.set;
pub const setEach = model_write.setEach;
pub const ArgSet = model_write.ArgSet;
pub const setArgs = model_write.setArgs;
pub const literalText = model_write.literalText;
pub const unset = model_write.unset;
pub const setStart = model_write.setStart;
pub const start = model_write.start;
pub const declare = model_write.declare;
pub const setIn = model_write.setIn;
