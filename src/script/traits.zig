//! The engine's built-in traits, as foundation/traits.ogs declares them:
//! every event and decision point the engine calls on a host's components is a method of
//! one of them. Host-kind traits (`Fighter`, `Level`…, `component X for fighter`
//! implements `Fighter`), roles the engine grants (`Hero`, `Enemy`) and marks (methodless
//! traits whose component turns engine code on). The declarations (names, parameters,
//! rules, docs en/ru, default bodies) are the OGS file's; this file reads them once
//! (`all`) for the dispatcher (script/dispatch.zig: a method's `Combine`), the linker and
//! the editor, and keeps what is the engine's own: how results combine, the roles it
//! grants, the original's script functions and the method each becomes (`classic`).
//! `live`: the engine calls the method already. Not live yet: Fighter.OnResist.

const std = @import("std");
const parser = @import("ogs/parser.zig");
const ir = @import("ir.zig");

pub const Doc = ir.Doc;

/// The language's declarations, as the engine reads them (build.zig addFoundation).
const traits_text = @embedFile("foundation_traits");
/// The engine's types: the words and records of the data the OG reader reads
/// (core/schema.zig names them as fields' types: `place = hand`, `placement = [Place(…)]`,
/// `camera = Camera(…)`), the sides of a battle. An enum's number is what an int field of
/// the engine stores (`ItemPlace`, `ItemKind`: inventory/item.zig `Place`, `ItemType`;
/// `WeaponKind`: battle/immunity.zig `DamageType`; tests/script.zig checks they agree).
pub const types = @embedFile("foundation_types");
/// `engine.ogs`: the built-in traits and the types (read-only; the editor shows it, go to
/// definition lands in it; the linker puts it first).
pub const prelude = traits_text ++ "\n" ++ types;

/// How the results of the handlers at one point combine (all components of a host in
/// attach order, then the next host: dispatch.chainHosts). A nil result (no `return`,
/// `return;`) is no answer: nothing changes. A handler that faults is logged and skipped.
/// Any other value is an answer: `return 0;` in a chain zeroes, 0 in a veto forbids.
const Combine = enum {
    /// Every handler runs; the result is not used.
    all,
    /// Each result (as an int) replaces the method's last argument for the next handler;
    /// the last one is the answer. Nobody answers: the engine's value.
    chain,
    /// The first false result answers no, and nothing after it runs.
    veto,
    /// The first non-nil result is the answer, and nothing after it runs.
    first,
    /// The first true result means done: nothing after it runs and the engine's own action
    /// is skipped.
    handled,
    /// The int results add up.
    sum,

    /// Its name as the editor and the reference show it (`chain`).
    pub fn label(c: Combine) Doc {
        return switch (c) {
            .all => .{ .en = "all", .ru = "все" },
            .chain => .{ .en = "chain", .ru = "цепочка" },
            .veto => .{ .en = "veto", .ru = "запрет" },
            .first => .{ .en = "first answer", .ru = "первый ответ" },
            .handled => .{ .en = "handled", .ru = "сделано" },
            .sum => .{ .en = "sum", .ru = "сумма" },
        };
    }

    /// What it does with the handlers' results (docs/og-script.md §13.2).
    fn about(c: Combine) Doc {
        return switch (c) {
            .all => .{ .en = "every component's handler runs in attach order; the result is not used.", .ru = "обработчики всех компонентов выполняются по порядку подключения, результат не используется." },
            .chain => .{ .en = "each result, as an int, becomes the last argument (amount, chance…) for the next component; the last one's is the answer. A change is a battle log line (`OnHit X <- Y: 12 -> 0`).", .ru = "результат каждого обработчика приводится к `int` и становится последним аргументом (`amount`, `chance`…) для следующего компонента. Результат последнего — итог. Изменение пишется в лог боя (`OnHit X <- Y: 12 -> 0`, `Armor X: 0 -> 3`)." },
            .veto => .{ .en = "the first false answer is no, and nobody after it is asked. Nobody said no: yes. Nobody answered: the engine's behaviour.", .ru = "первый ложный ответ — «нет», дальше не спрашивают. Если никто не ответил «нет», ответ «да». Если не ответил никто, действует поведение движка." },
            .first => .{ .en = "the first answer (not nil) is the answer, and nobody after it is asked.", .ru = "первый ответ (не `nil`) — ответ, дальше не спрашивают." },
            .handled => .{ .en = "the first true answer means done: nothing after it runs and the engine's own action is skipped.", .ru = "первый истинный ответ — «сделано», дальше не вызывают, и встроенное действие движка пропускается." },
            .sum => .{ .en = "the int answers add up.", .ru = "целые ответы складываются." },
        };
    }
};

pub const Method = struct {
    name: []const u8,
    /// Parameters as a handler declares them (`side, turn`).
    params: []const u8 = "",
    combine: Combine = .all,
    /// When (and where) the engine calls it.
    when: Doc,
    /// What the engine does when nobody answers; null: nothing.
    default: ?Doc = null,
    /// The engine runs it (a role's `native fn`): a component can't define it.
    native: bool = false,
    /// The engine calls it already (the template and the editor's checks list these).
    live: bool = false,
    /// Each parameter's meaning (the editor's tips; the game hooks so far).
    param_docs: []const Doc = &.{},
    /// Its bit in `Mask` (`names`); null: a native.
    bit: ?usize = null,
    /// Its name's id (script/names.zig: the variables' and functions' table).
    name_id: u32 = 0,

    pub fn arity(m: Method) usize {
        return std.mem.count(u8, m.params, ",") + @intFromBool(m.params.len > 0);
    }

    /// The argument a `chain` result replaces for the next handler: always the last.
    pub fn valueArg(m: Method) usize {
        return m.arity() - 1;
    }
};

pub const Kind = enum {
    /// The trait of a host kind: always there.
    host,
    /// Granted and taken by the engine as it runs (`for Hero`: active only meanwhile).
    role,
    /// No methods: a component implementing it turns engine behaviour on.
    mark,
};

pub const Trait = struct {
    name: []const u8,
    kind: Kind = .host,
    supers: []const []const u8 = &.{},
    /// The host kind written after `for` (a host trait's; `active_anim`).
    host: ?[]const u8 = null,
    doc: Doc,
    methods: []const Method = &.{},

    /// Its own method `name` (not its supertraits').
    pub fn own(t: *const Trait, name: []const u8) ?*const Method {
        for (t.methods) |*m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }
};

/// The roles a fighter may have.
pub const Role = enum {
    hero,
    enemy,

    /// Its trait's name (`OnRoleGained("Hero")`).
    pub fn name(r: Role) []const u8 {
        return switch (r) {
            .hero => "Hero",
            .enemy => "Enemy",
        };
    }

    /// The role of trait `trait_name`, if it is one.
    pub fn of(trait_name: []const u8) ?Role {
        inline for (.{ Role.hero, Role.enemy }) |r| if (std.mem.eql(u8, r.name(), trait_name)) return r;
        return null;
    }
};
pub const Roles = std.EnumSet(Role);

// ---------------------------------------------------------------- the table

const Table = struct {
    traits: []const Trait,
    /// Every method a component may define (not the natives) and the marks, each once.
    names: []const []const u8,
    events: []const Method,
    hooks: []const Method,
};

/// Read once, on first use; only the script thread asks (as object.zig's names).
var table: ?Table = null;
var table_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn get() *const Table {
    if (table == null) table = read(table_arena.allocator()) catch |err| std.debug.panic("foundation/traits.ogs: {s}", .{@errorName(err)});
    return &table.?;
}

fn read(a: std.mem.Allocator) !Table {
    var diag: parser.Diagnostic = .{};
    const u = parser.parse(a, traits_text, "engine.ogs", &diag) catch |err| {
        std.debug.print("foundation/traits.ogs:{d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    var ts: std.ArrayList(Trait) = .empty;
    for (u.modules) |m| for (m.traits) |t| {
        const e = t.engine orelse return error.NotBuiltIn;
        var ms: std.ArrayList(Method) = .empty;
        for (t.methods) |tm| {
            const ef = tm.engine.?;
            var ps: std.ArrayList(u8) = .empty;
            for (tm.f.params, 0..) |p, k| try ps.print(a, "{s}{s}", .{ if (k > 0) ", " else "", p.name });
            try ms.append(a, .{ .name = tm.f.name, .params = ps.items, .combine = std.meta.stringToEnum(Combine, ef.combine) orelse return error.BadCombine, .when = ef.when, .default = ef.default, .native = tm.native, .live = ef.live, .param_docs = ef.param_docs });
        }
        try ts.append(a, .{ .name = t.name, .kind = switch (e.kind) {
            .host => .host,
            .role => .role,
            .mark => .mark,
        }, .supers = t.supers, .host = if (e.host.len > 0) e.host else null, .doc = e.doc, .methods = ms.items });
    };
    var names_: std.ArrayList([]const u8) = .empty;
    for (ts.items) |t| {
        if (t.kind == .mark) try names_.append(a, t.name);
        for (t.methods) |m| {
            if (m.native) continue;
            for (names_.items) |n| {
                if (std.mem.eql(u8, n, m.name)) break;
            } else try names_.append(a, m.name);
        }
    }
    if (names_.items.len > max_names) return error.TooManyNames;
    for (ts.items) |tr| for (@constCast(tr.methods)) |*m| {
        m.name_id = try @import("names.zig").intern(m.name);
        if (!m.native) for (names_.items, 0..) |n, i| if (std.mem.eql(u8, n, m.name)) {
            m.bit = i;
        };
    };
    return .{ .traits = ts.items, .names = names_.items, .events = try liveOf(a, ts.items, "Fighter"), .hooks = try liveOf(a, ts.items, "Game") };
}

fn liveOf(a: std.mem.Allocator, ts: []const Trait, trait: []const u8) ![]const Method {
    var out: std.ArrayList(Method) = .empty;
    for (ts) |t| if (std.mem.eql(u8, t.name, trait)) for (t.methods) |m| if (m.live) try out.append(a, m);
    return out.items;
}

/// The built-in traits, in the file's order.
pub fn all() []const Trait {
    return get().traits;
}

/// Trait `name` (exact case: OGS names are).
pub fn find(name: []const u8) ?*const Trait {
    for (all()) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// The trait of host kind `kind` (`fighter`, `active_anim`), as written after `for`.
pub fn ofHost(kind: []const u8) ?*const Trait {
    for (all()) |*t| if (t.host) |h| if (std.mem.eql(u8, h, kind)) return t;
    return null;
}

/// The trait with engine method (`native fn`) `name`, if any (`host.as(Hero).inventory()`).
pub fn nativeOwner(name: []const u8) ?*const Trait {
    for (all()) |*t| for (t.methods) |m| if (m.native and std.mem.eql(u8, m.name, name)) return t;
    return null;
}

/// Method `name` of `t` or of its supertraits (its own first, then each supertrait's in
/// order, depth first).
pub fn lookup(t: *const Trait, name: []const u8) ?*const Method {
    if (t.own(name)) |m| return m;
    for (t.supers) |s| if (lookup(find(s).?, name)) |m| return m;
    return null;
}

/// Whether `sup` is `t` or one of its supertraits.
pub fn isA(t: *const Trait, sup: []const u8) bool {
    if (std.mem.eql(u8, t.name, sup)) return true;
    for (t.supers) |s| if (isA(find(s).?, sup)) return true;
    return false;
}

/// Method `path` ("Fighter.OnHit": a trait's own) the engine calls, found once per call
/// point. The tests check every path the engine names (tests/script.zig).
pub fn method(comptime path: []const u8) *const Method {
    // The struct must capture `path`, or every call point would share one cache.
    const S = struct {
        const key = path;
        var m: ?*const Method = null;
    };
    if (S.m) |m| return m;
    S.m = methodOf(path) orelse std.debug.panic("foundation/traits.ogs has no method {s}", .{path});
    return S.m.?;
}

/// Method `path` ("Fighter.OnHit"), if the foundation has it.
pub fn methodOf(path: []const u8) ?*const Method {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;
    return (find(path[0..dot]) orelse return null).own(path[dot + 1 ..]);
}

/// A fighter's events the battle calls (combat/events.zig), in the template's order.
pub fn events() []const Method {
    return get().events;
}

/// The game hooks the engine calls (state/hooks.zig), in the template's order.
pub fn hooks() []const Method {
    return get().hooks;
}

/// The fighter event `name`.
pub fn event(name: []const u8) ?*const Method {
    for (events()) |*e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// The game hook `name`, case aside (a level's own Classic function may define it).
pub fn hook(name: []const u8) ?*const Method {
    for (hooks()) |*h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h;
    return null;
}

// ---------------------------------------------------------------- the host's mask

/// The names a component can implement: every method a component may define (not the
/// natives) and the marks, each once (`OnTurnStart` of Fighter, Battle and Game: one bit,
/// a host is of one kind). `Object.implements` has a bit per name.
pub fn names() []const []const u8 {
    return get().names;
}

/// How many names a mask holds (the foundation has fewer: `read` checks).
const max_names = 256;
pub const Mask = std.StaticBitSet(max_names);

/// The bit of `name` (a method or a mark) the engine names, found once.
pub fn bit(comptime name: []const u8) usize {
    const S = struct {
        const key = name;
        var b: ?usize = null;
    };
    if (S.b) |b| return b;
    S.b = bitOf(name) orelse std.debug.panic("foundation/traits.ogs has no method or mark {s}", .{name});
    return S.b.?;
}

pub fn bitOf(name: []const u8) ?usize {
    for (names(), 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

// ---------------------------------------------------------------- Classic

pub const Param = struct {
    /// `string hero`, as the script declares it.
    decl: []const u8,
    doc: Doc,
};

/// A function of the original's scripts the exe calls by name, and the method the
/// converter makes it. The Classic reader keeps
/// calling these by name at their points.
pub const Classic = struct {
    name: []const u8,
    params: []const Param = &.{},
    /// Who calls it and when.
    doc: Doc,
    /// The method it becomes (on the trait of the file's host).
    method: []const u8 = "",
};

const hero: Param = .{ .decl = "string hero", .doc = .{ .en = "the name of the hero who does it (his object's)", .ru = "имя героя, который это делает (его объекта)" } };

pub const classic = [_]Classic{
    .{ .name = "init", .method = "OnCreate", .doc = .{ .en = "Every object of a location as it is made: after its .var values, the level's own after the others' (world/start.zig); also an item or weapon made later (after class_init), a battle device, a spawned object.", .ru = "Каждый объект локации при её создании: после значений .var, у самого уровня — после остальных (world/start.zig); а также предмет или оружие, созданные позже (после class_init), боевое устройство, появившийся объект." } },
    .{ .name = "class_init", .method = "OnClassInit", .doc = .{ .en = "An item or weapon being made (Item_New, Weapon_New, box contents; inventory/create.zig): before its init(). Item scripts call it from their init() too.", .ru = "Создаваемый предмет или оружие (Item_New, Weapon_New, содержимое ящика; inventory/create.zig): до его init(). Скрипты предметов вызывают его и сами из init()." } },
    .{ .name = "initCamera", .method = "OnCamera", .doc = .{ .en = "The level, as the location is made: before its init(); the camera is made from its values after it.", .ru = "Уровень при создании локации: до его init(); камера строится по его значениям после него." } },
    .{ .name = "restore", .method = "OnRestore", .doc = .{ .en = "The level, then its bitmap animations: after every init() of a new location, and each time the party comes back to it (world/levels.zig).", .ru = "Уровень, затем его битмап-анимации: после всех init() новой локации и каждый раз, когда отряд в неё возвращается (world/levels.zig)." } },
    .{ .name = "post_init", .method = "OnStart", .doc = .{ .en = "Once for every new object (level, actors, areas, items) after the restore() calls; not for party heroes brought along (world/start.zig).", .ru = "Один раз для каждого нового объекта (уровень, актёры, области, предметы) после вызовов restore(); не для пришедших с отрядом героев (world/start.zig)." } },
    .{ .name = "additionalIdleAnims", .method = "OnActorReady", .doc = .{ .en = "An actor, right after its init(): registers its idles for the battle states 7 and 8 (copies of 0 and 1 before it).", .ru = "Актёр сразу после init(): регистрирует idle для боевых стоек 7 и 8 (до него это копии 0 и 1)." } },
    .{ .name = "postinit", .method = "OnActorReady", .doc = .{ .en = "An actor, after its init() and additionalIdleAnims() (heroes: ReferenceAnimation, NotInPlaceAnimation).", .ru = "Актёр после init() и additionalIdleAnims() (у героев: ReferenceAnimation, NotInPlaceAnimation)." } },
    .{ .name = "update", .method = "OnUpdate", .doc = .{ .en = "Every tick, for the level, its bitmap animations and its actors (game/life.zig).", .ru = "Каждый тик — у уровня, его битмап-анимаций и актёров (game/life.zig)." } },
    .{ .name = "allowRender", .method = "CanRender", .doc = .{ .en = "A bitmap animation, after restore() and every tick: its value says whether it is drawn (0: hidden; no function: drawn).", .ru = "Битмап-анимация после restore() и каждый тик: значение решает, рисуется ли она (0 — скрыта; без функции — рисуется)." } },
    .{ .name = "after_select_gui", .method = "OnShown", .doc = .{ .en = "The level at the end of every load (new or returned to): battles put the pre-battle dialogue, a video or EndTurnGlobal here.", .ru = "Уровень в конце каждой загрузки (новой или при возвращении): бои ставят сюда предбоевой диалог, видео или EndTurnGlobal." } },
    .{ .name = "LevelSwitch", .method = "OnExit", .doc = .{ .en = "An exit area (isLevelSwitch) when a hero who walked to it takes it: usually LEVEL_Load.", .ru = "Область выхода (isLevelSwitch), когда подошедший к ней герой её выбирает: обычно LEVEL_Load." } },
    .{ .name = "UseItem", .method = "OnUseItem", .params = &.{
        .{ .decl = "string item", .doc = .{ .en = "the used item's object name", .ru = "имя объекта использованного предмета" } },
        hero,
    }, .doc = .{ .en = "An area, item or actor a hero uses an inventory item on (after walking there; with use_item_N set, only those items). Not for medicine on a hero.", .ru = "Область, предмет или актёр, на которых герой применяет предмет из инвентаря (подойдя туда; с заданными use_item_N — только эти предметы). Не для лекарства на героя." } },
    .{ .name = "CheckCode", .method = "OnCode", .params = &.{
        .{ .decl = "int code", .doc = .{ .en = "the 8 digits entered on the keypad, as a number", .ru = "8 введённых на клавиатуре цифр числом" } },
    }, .doc = .{ .en = "A safe area (GUI_SafeBox) when its code has been entered.", .ru = "Область сейфа (GUI_SafeBox), когда набран её код." } },
    .{ .name = "UniversalTake", .params = &.{hero}, .doc = .{ .en = "An item taken (Take, action 3) whose script has no Take() of its own.", .ru = "Подбираемый предмет (Take, action 3), в скрипте которого нет своего Take()." } },
    .{ .name = "post_init_box", .method = "OnFirstOpen", .doc = .{ .en = "A box explored for the first time while its itm_1 item does not exist yet: it makes the contents (Item_New, Weapon_New).", .ru = "Ящик, осматриваемый впервые, пока его предмета itm_1 ещё нет: создаёт содержимое (Item_New, Weapon_New)." } },
    .{ .name = "NodeResponse", .method = "OnNode", .params = &.{
        .{ .decl = "int no", .doc = .{ .en = "the path point passed (from 0, in the .ap order)", .ru = "пройденная точка пути (с 0, в порядке .ap)" } },
        .{ .decl = "int dir", .doc = .{ .en = "1: the path walked forward, 0: backwards", .ru = "1 — путь проходится вперёд, 0 — назад" } },
    }, .doc = .{ .en = "A path script (<path>.pth) when an actor walking the path passes one of its points (game/life.zig); the Actor… path functions act on that actor.", .ru = "Скрипт пути (<путь>.pth), когда идущий по пути актёр проходит его точку (game/life.zig); функции пути Actor… действуют на этого актёра." } },
    .{ .name = "AfterBattle", .method = "OnAfterBattle", .params = &.{
        .{ .decl = "string level", .doc = .{ .en = "the name of the battle level won", .ru = "имя выигранного боевого уровня" } },
    }, .doc = .{ .en = "The level the party returns to after winning a battle (game.zig).", .ru = "Уровень, в который отряд возвращается после победы в бою (game.zig)." } },
    .{ .name = "CombatEnemiesAppear", .method = "OnEnemiesAppear", .doc = .{ .en = "A battle level once, when the battle begins (after the pre-battle dialogue), before the first player turn.", .ru = "Боевой уровень один раз, когда начинается бой (после предбоевого диалога), до первого хода игрока." } },
};

// ---------------------------------------------------------------- texts made from the table

/// A new ability component `name` (OGS): a sample param and every fighter event as a
/// commented-out method (nothing happens until one is uncommented); ASCII (the code view
/// shows a rules file as the game's 8-bit text).
pub fn template(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.print(a, "\n// A scripted ability (OpenGorky): attached to a character in its Extra abilities block.\ncomponent {s} for fighter {{\n", .{name});
    try s.appendSlice(a,
        \\    // A param is the ability's setting: the character's Extra abilities block
        \\    // shows it as a field (int, float, bool, string, fighter: an object's name).
        \\    param int amount = 1 "Amount";
        \\    // A var is its state for the battle.
        \\    // var int count = 0;
        \\    // `host` is the fighter; host.hp, host.max_hp, host.side ("hero", "enemy"),
        \\    // host.alive, host.tile. Builtins: fighter::Damage(who, amount, kind),
        \\    // fighter::AddState(who, state, turns), fighter::SetTarget(who, target),
        \\    // fighter::GetLastAttacker(who), fighter::Side(who), fighter::IsAlive(who),
        \\    // fighter::Popup(who, text), battle::GetVar(name), battle::SetVar(name, value),
        \\    // battle::AddVar(name, delta). Remove the // of one to use it.
        \\
    );
    for (events()) |e| {
        try s.print(a, "\n    // {s}: {s}.\n    // fn {s}({s}) {{\n", .{ e.name, e.when.en, e.name, e.params });
        if (e.combine == .chain) try s.print(a, "    //     return {s};\n", .{e.params[if (std.mem.lastIndexOf(u8, e.params, ", ")) |k| k + 2 else 0..]}) else if (e.combine == .veto) try s.appendSlice(a, "    //     return true;\n");
        try s.appendSlice(a, "    // }\n");
    }
    try s.appendSlice(a, "}\n");
    return s.toOwnedSlice(a);
}

/// The game hooks' template (the editor's OG layout makes a hooks file of it): an empty
/// game component, every hook described as a commented-out method (nothing changes).
pub fn hooksTemplate(a: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(a,
        \\// OpenGorky hooks, in OGS (the engine's language). Each component
        \\// `for game` here is attached to the game, in order, and the engine calls its method
        \\// of a hook's name (only in an OpenGorky project): remove the // of one to use it.
        \\// Objects come as refs (target.hp; object::GetClass(weapon): its class, "cw_riffle");
        \\// a value returned changes the engine's, nil (no return) changes nothing. Builtins
        \\// are the game scripts' ones, by package (fighter::SetHp). The level's components (Battle, Level) hear the
        \\// same points first. OnDamage, OnResist: the result before comes as `amount`;
        \\// OnItemUse: a true ends it (nothing more runs); the others: all run.
        \\// level::GetName() is the current level's name ("05_laboratory").
        \\component Hooks for game {
        \\
    );
    for (hooks()) |h| {
        try s.print(a, "\n    // {s}: {s}.\n    // fn {s}({s}) {{\n", .{ h.name, h.when.en, h.name, h.params });
        if (std.mem.eql(u8, h.name, "OnDamage")) try s.appendSlice(a, "    //     return amount;\n") else if (std.mem.indexOf(u8, h.when.en, "return") != null) try s.appendSlice(a, "    //     return 0;\n");
        try s.appendSlice(a, "    // }\n");
    }
    try s.appendSlice(a, "}\n");
    return s.toOwnedSlice(a);
}

// ---------------------------------------------------------------- the reference's catalog

/// The marker a generated block of docs/og-script.md starts with (`gorky-tool
/// traits-doc`): `<!-- traits-doc: catalog -->`, up to `doc_end`.
const doc_begin = "<!-- traits-doc: ";
const doc_end = "<!-- /traits-doc -->";

/// Generated block `name` of the reference (Russian, as the reference is): `traits` the
/// built-in traits, `roles` the roles' engine methods, `rules` the combine rules and who
/// has each, `catalog` every trait's methods (a mark has none). error.NoSuchBlock: another name.
fn writeBlock(w: *std.Io.Writer, name: []const u8) !void {
    const eql = std.mem.eql;
    if (eql(u8, name, "traits")) {
        try w.writeAll("| Trait | Kind | Supertraits | What it is |\n|---|---|---|---|\n");
        for (all()) |t| {
            try w.print("| `{s}` | {s} | ", .{ t.name, switch (t.kind) {
                .host => "host kind",
                .role => "role",
                .mark => "mark",
            } });
            try writeList(w, t.supers);
            try w.print(" | {s} |\n", .{t.doc.en});
        }
    } else if (eql(u8, name, "roles")) {
        try w.writeAll("| Method | What it gives |\n|---|---|\n");
        for (all()) |t| for (t.methods) |m| if (m.native) try w.print("| `{s}.{s}({s})` | {s} |\n", .{ t.name, m.name, m.params, m.when.en });
    } else if (eql(u8, name, "rules")) {
        for (std.enums.values(Combine)) |c| {
            try w.print("- **`{s}`** (", .{@tagName(c)});
            var seen: []const []const u8 = &.{};
            var buf: [64][]const u8 = undefined;
            for (all()) |t| for (t.methods) |m| if (!m.native and m.combine == c) {
                for (seen) |s| {
                    if (eql(u8, s, m.name)) break;
                } else {
                    try w.print("{s}`{s}`", .{ if (seen.len > 0) ", " else "", m.name });
                    buf[seen.len] = m.name;
                    seen = buf[0 .. seen.len + 1];
                }
            };
            try w.print("): {s}\n", .{c.about().en});
        }
    } else if (eql(u8, name, "catalog")) {
        for (all()) |t| {
            if (t.kind == .mark) continue;
            try w.print("**`{s}`**", .{t.name});
            if (t.host) |h| try w.print(" (`for {s}`)", .{h});
            if (t.supers.len > 0) {
                try w.writeAll(": ");
                try writeList(w, t.supers);
            }
            try w.print(" — {s}", .{t.doc.en});
            var n: usize = 0;
            for (t.methods) |m| n += @intFromBool(!m.native);
            if (n == 0) {
                try w.writeAll(" No methods of its own.\n\n");
                continue;
            }
            try w.writeAll("\n\n| Method | When | Rule | No answer | Classic |\n|---|---|---|---|---|\n");
            for (t.methods) |m| if (!m.native) {
                try w.print("| `{s}({s})` | {s}{s} | {s} | {s} | ", .{ m.name, m.params, m.when.en, if (m.live) "" else " (**not called yet**)", m.combine.label().en, if (m.default) |d| d.en else "—" });
                var k: usize = 0;
                for (classic) |c| if (eql(u8, c.method, m.name)) {
                    try w.print("{s}`{s}`", .{ if (k > 0) ", " else "", c.name });
                    k += 1;
                };
                try w.writeAll(if (k == 0) "— |\n" else " |\n");
            };
            try w.writeAll("\n");
        }
    } else return error.NoSuchBlock;
}

fn writeList(w: *std.Io.Writer, names_: []const []const u8) !void {
    if (names_.len == 0) return w.writeAll("—");
    for (names_, 0..) |s, k| try w.print("{s}`{s}`", .{ if (k > 0) ", " else "", s });
}

/// `md` (docs/og-script.md) with every generated block made again from the table.
pub fn fillDoc(a: std.mem.Allocator, md: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, md, at, doc_begin)) |b| {
        const nl = std.mem.indexOfScalarPos(u8, md, b, '\n') orelse return error.BadMarker;
        const head = md[b..nl];
        if (!std.mem.endsWith(u8, head, " -->")) return error.BadMarker;
        const e = std.mem.indexOfPos(u8, md, nl, doc_end) orelse return error.NoEndMarker;
        try out.writer.writeAll(md[at .. nl + 1]);
        try writeBlock(&out.writer, head[doc_begin.len .. head.len - 4]);
        at = e;
    }
    try out.writer.writeAll(md[at..]);
    return out.toOwnedSlice();
}

test "traits: the reference's blocks are made again between their markers" {
    const a = std.testing.allocator;
    const md = try fillDoc(a, "a\n<!-- traits-doc: roles -->\nold\n<!-- /traits-doc -->\nb\n");
    defer a.free(md);
    try std.testing.expect(std.mem.startsWith(u8, md, "a\n<!-- traits-doc: roles -->\n| Method | What it gives |\n"));
    try std.testing.expect(std.mem.indexOf(u8, md, "| `Hero.equipped(place)` |") != null);
    try std.testing.expect(std.mem.endsWith(u8, md, "|\n<!-- /traits-doc -->\nb\n"));
    try std.testing.expect(std.mem.indexOf(u8, md, "old") == null);
    // Made again, it is the same.
    const again = try fillDoc(a, md);
    defer a.free(again);
    try std.testing.expectEqualStrings(md, again);
    try std.testing.expectError(error.NoSuchBlock, fillDoc(a, "<!-- traits-doc: nope -->\n<!-- /traits-doc -->\n"));
    try std.testing.expectError(error.NoEndMarker, fillDoc(a, "<!-- traits-doc: roles -->\n"));
}

test "traits: the table holds together" {
    const t = std.testing;
    for (all(), 0..) |tr, i| {
        try t.expect(tr.doc.en.len > 0 and tr.doc.ru.len > 0);
        for (all()[0..i]) |o| try t.expect(!std.mem.eql(u8, o.name, tr.name));
        for (tr.supers) |s| try t.expect(find(s) != null);
        try t.expect((tr.host != null) == (tr.kind == .host));
        if (tr.kind == .mark) try t.expectEqual(0, tr.methods.len);
        for (tr.methods, 0..) |m, k| {
            for (tr.methods[0..k]) |o| try t.expect(!std.mem.eql(u8, o.name, m.name));
            try t.expect(m.when.en.len > 0 and m.when.ru.len > 0);
            if (m.default) |d| try t.expect(d.en.len > 0 and d.ru.len > 0);
            if (m.combine == .chain) try t.expect(m.arity() > 0);
            if (m.param_docs.len > 0) try t.expectEqual(m.arity(), m.param_docs.len);
            try t.expect(!m.native or tr.kind == .role);
        }
    }
    for (classic) |c| {
        try t.expect(c.doc.en.len > 0 and c.doc.ru.len > 0);
        for (c.params) |p| try t.expect(p.decl.len > 0 and p.doc.en.len > 0 and p.doc.ru.len > 0);
        if (c.method.len > 0) try t.expect(bitOf(c.method) != null);
    }
    try t.expectEqual(26, events().len);
    try t.expectEqual(7, hooks().len);
    try t.expectEqual(3, event("OnHit").?.arity());
    try t.expectEqual(2, event("OnHit").?.valueArg());
    try t.expectEqual(0, event("OnSpawn").?.arity());
    try t.expect(event("onhit") == null);
    try t.expectEqual(4, hook("ondamage").?.arity());
    try t.expectEqual(1, hook("OnBattleEnd").?.arity());
    try t.expect(hook("OnDamge") == null);
    try t.expectEqual(find("Fighter").?, ofHost("fighter").?);
    try t.expectEqual(find("ActiveAnim").?, ofHost("active_anim").?);
    // Fighter.OnStart is Actor's; Hero is a Fighter, an Object; Path is not.
    try t.expectEqualStrings("OnStart", lookup(find("Fighter").?, "OnStart").?.name);
    try t.expect(lookup(find("Hero").?, "OnCreate") != null and isA(find("Hero").?, "Object"));
    try t.expect(!isA(find("Path").?, "Object") and lookup(find("Path").?, "OnCreate") == null);
    try t.expectEqual(Combine.handled, method("Game.OnItemUse").combine);
    // One bit a name; the marks have theirs, natives none.
    try t.expect(bitOf("Monitor") != null and bitOf("inventory") == null);
    try t.expectEqual(bit("OnTurnStart"), bitOf("OnTurnStart").?);
    // The Battle and Game hooks of one name combine alike (state/hooks.zig calls both).
    for (hooks()) |h| if (methodOf(try std.fmt.allocPrint(table_arena.allocator(), "Battle.{s}", .{h.name}))) |b| try t.expectEqual(h.combine, b.combine);
}

test "traits: the prelude is the foundation's text, read whole" {
    try std.testing.expect(std.mem.indexOf(u8, prelude, "\ntrait Battle : Level for battle\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prelude, "\nmark trait Monitor : Fighter\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prelude, "\nenum ItemPlace {") != null);
    for (all()) |t| for (t.methods) |m| try std.testing.expect(std.mem.indexOf(u8, prelude, m.name) != null);
    // Each trait's header as the editor's trait page finds it (editor/traitpage.zig headerAt).
    var buf: [96]u8 = undefined;
    for (all()) |t| {
        const kind = switch (t.kind) {
            .host => "",
            .role => "role ",
            .mark => "mark ",
        };
        try std.testing.expect(std.mem.indexOf(u8, prelude, try std.fmt.bufPrint(&buf, "\n{s}trait {s} ", .{ kind, t.name })) != null or
            std.mem.indexOf(u8, prelude, try std.fmt.bufPrint(&buf, "\n{s}trait {s}\n", .{ kind, t.name })) != null);
    }
    // The templates are ASCII (a rules file is the game's 8-bit text in the code view).
    const tm = try template(std.testing.allocator, "X");
    defer std.testing.allocator.free(tm);
    const ht = try hooksTemplate(std.testing.allocator);
    defer std.testing.allocator.free(ht);
    for (tm) |c| try std.testing.expect(c < 0x80);
    for (ht) |c| try std.testing.expect(c < 0x80);
}

test "traits: a built-in declaration is the engine file's only" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: parser.Diagnostic = .{};
    try std.testing.expectError(error.ParseError, parser.parse(arena.allocator(), "mark trait X { }", "a.ogs", &d));
    try std.testing.expectError(error.ParseError, parser.parse(arena.allocator(), "trait X for fighter { }", "a.ogs", &d));
    const u = try parser.parse(arena.allocator(), "trait X : Y for fighter \"what\" {\n live chain fn F(a \"x\") \"when\" default \"none\" { return a; }\n}", "engine.ogs", &d);
    const t = u.modules[0].traits[0];
    try std.testing.expectEqualStrings("fighter", t.engine.?.host);
    // One text, English, for both interface languages.
    try std.testing.expectEqualStrings("what", t.engine.?.doc.ru);
    const f = t.methods[0].engine.?;
    try std.testing.expect(f.live and std.mem.eql(u8, f.combine, "chain"));
    try std.testing.expectEqualStrings("none", f.default.?.en);
    try std.testing.expectEqualStrings("x", f.param_docs[0].en);
    // `ru` is no OG Script any more: a parse error.
    try std.testing.expectError(error.ParseError, parser.parse(arena.allocator(), "trait Z \"what\" ru \"что\" { }", "engine.ogs", &d));
    try std.testing.expect(t.methods[0].body);
}
