//! Scenes and dialogs as core records: a scene's commands and points (`.scr`/`.pts`),
//! a dialog's lines (`.dlg`, cut as the edition cuts it, each with its voice file).
//! The core reads no files: a world asks its `Source` (composition, loaders/world.zig,
//! parses them) and keeps what it got for the location's life (state/scene.zig caches).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("../script.zig").value;

pub const Arg = union(enum) {
    string: []const u8,
    number: f32,

    pub fn str(self: Arg) []const u8 {
        return switch (self) {
            .string => |s| s,
            .number => "",
        };
    }

    /// Like the exe's `atof`: `WALKAREA("ciuch_blokada",0,1")` in `05l_ciuchcia.scr` gives 1.
    pub fn num(self: Arg) f32 {
        return switch (self) {
            .number => |n| n,
            .string => |s| value.atof(s),
        };
    }

    /// Integer via `_ftol`: NaN and 1e30 from a file do not crash the cast.
    pub fn int(self: Arg) i32 {
        return value.floatToInt(self.num());
    }
};

/// What a scene command's argument is (`Cmd.args`, a letter each): how an OpenGorky scene
/// writes it and what it is as the exe's. A value of another type than its kind's (a
/// string where the exe reads a number) stays as written both ways.
pub const Kind = enum(u8) {
    /// `@Sullivan`: the exe's actor name; `@hero::selected` its #HERO_SELECTED (the
    /// selected hero), `@hero::last_action` its #LAST_ACTION_HERO.
    actor = 'a',
    /// `@gate1`: a level object's name.
    object = 'o',
    /// `"suliv_p1"`: a point of the scene's `points`.
    point = 'p',
    /// A name the exe looks up itself (an animation, a function, a track, an area, music).
    name = 'n',
    int = 'i',
    number = 'f',
    /// `true`/`false`: the exe's 1/0.
    bool = 'b',
    /// `true`/`false`: the exe's 0/1 (DISABLEOBJECT: 0 enables).
    not = 'B',
    /// `true`: the exe's argument there (any value: WEAPON's two hands); `false`: none.
    given = 'P',
    /// Seconds: the exe's ticks (`ticks_per_second`).
    ticks = 'T',
    /// Seconds: the exe's 1/100 s.
    centis = 'C',
    /// A zoom factor (1.0–2.0): the exe's percent.
    percent = 'Z',
    /// `~l"01_port"`.
    level = 'l',
    /// `~e"port-meet_bt"`.
    scene = 'e',
    /// `~s"wheel"`.
    sound = 's',
    /// `~w"weapons::rocket_launcher"` (OpenGorky's only).
    weapon = 'w',
    /// `~d"port-arriving"`: the exe's `port-arriving.dlg`.
    dialog = 'd',
    /// None in OpenGorky: an exe argument nothing reads (DIALOG_INIT's section, hero, mode).
    dropped = '_',
    /// A line of the open dialog, from 0.
    line = 'L',
    /// An actor state, 0 to `max_state`.
    state = 'S',

    pub fn of(letter: u8) Kind {
        return @fromBackingInt(@intCast(letter));
    }

    /// Its exe value per OpenGorky unit (seconds, a factor); null: the same.
    pub fn scale(self: Kind) ?f64 {
        return switch (self) {
            .ticks => ticks_per_second,
            .centis, .percent => 100,
            else => null,
        };
    }

    /// The sigil its string takes (`~l`…); 0: none.
    pub fn sigil(self: Kind) u8 {
        return switch (self) {
            .level, .scene, .sound, .weapon, .dialog => @backingInt(self),
            else => 0,
        };
    }
};

/// The scene runner's ticks a second (DELAY, EARTHQUAKE).
pub const ticks_per_second = 30;
/// ACTORSETSTATE's highest state (actor.zig `max_states` − 1).
pub const max_state = 9;
/// The exe's placeholders of `@hero::selected`, `@hero::last_action`.
const placeholders = [_][2][]const u8{ .{ "#HERO_SELECTED", "hero::selected" }, .{ "#LAST_ACTION_HERO", "hero::last_action" } };

/// A scene command: the exe's name, OG Script's (`namespace::Name`
/// as its builtins), its arguments. The OG reader runs a scene's `actor::WalkTo(…)` as
/// WALKTO; an exe name still reads as itself.
pub const Cmd = struct {
    exe: []const u8,
    ogs: []const u8,
    /// The exe's arguments' kinds in order (`Kind` letters); past them, as written.
    args: []const u8 = "",
    /// Half of a pair (PANORAMA_ON/OFF: `camera::Panorama(true)`/`(false)`): the OG call's
    /// last argument, a bool, picks it.
    flag: ?bool = null,
};

fn c(exe: []const u8, ogs: []const u8, args: []const u8) Cmd {
    return .{ .exe = exe, .ogs = ogs, .args = args };
}

fn pair(exe: []const u8, ogs: []const u8, args: []const u8, flag: bool) Cmd {
    return .{ .exe = exe, .ogs = ogs, .args = args, .flag = flag };
}

/// The commands in the exe table's order (scene/scenario.zig `exe_order`: a Classic name
/// runs as the first it starts with).
pub const commands = [_]Cmd{
    c("PLACEHEROES", "hero::PlaceAll", "ni"),                   c("WALKTO", "actor::WalkTo", "ap"),
    c("PLACE", "actor::Place", "api"),                          c("NO_SKIP", "scene::NoSkip", ""),
    c("ACTOR_MORPH", "actor::Morph", "annn"),                   c("EARTHQUAKE", "camera::Shake", "T"),
    c("MP3_PLAY", "music::Play", "n"),                          c("MP3_FADE", "music::Fade", ""),
    pair("GUI_DISABLE", "gui::Input", "", false),               c("GUI_CREDITS", "gui::Credits", ""),
    c("GUI_MENU", "gui::Menu", ""),                             pair("GUI_ENABLE", "gui::Input", "", true),
    pair("GUI_CUTSCENE", "gui::Cutscene", "", true),            c("GUI_ENDDEMO", "gui::EndDemo", ""),
    c("GUI_GAMEOVER", "gui::GameOver", ""),                     pair("GUI_NORMAL", "gui::Cutscene", "", false),
    c("ACTORSETSTATE", "actor::SetState", "aS"),                c("PLAYAVI", "video::Play", "niib"),
    c("WAITFORACTOR", "actor::Wait", "a"),                      c("FX_WEAPON", "fx::Weapon", "ai"),
    c("VOLTAGE", "fx::Voltage", "a"),                           c("ROCKET", "fx::Rocket", "afffw"),
    c("ATTACK", "actor::Attack", "a"),                          c("USEANIMATION", "actor::UseAnimation", "an"),
    c("FAST_ANIMATION", "actor::FastAnimation", "an"),          c("ANIMATION", "actor::Animation", "anib"),
    c("SYSTEMANIMATION", "actor::SystemAnimation", "an"),       c("GO_RUNFUN", "object::Call", "on"),
    c("SIGNATURE_ON", "scene::Signature", "i"),                 c("SIGNATURE_OFF", "scene::SignatureOff", ""),
    c("IMPULSEOBJECT", "object::Impulse", "oi"),                c("ABA_MOVE", "anim::Move", "offf"),
    c("ABA_POS", "anim::Position", "oii"),                      c("ABA_STATE", "anim::State", "oi"),
    c("WAITFORANIMATION", "anim::Wait", "o"),                   c("DELAY", "scene::Wait", "T"),
    c("LOADLEVEL", "level::Load", "l"),                         c("PREVLEVEL", "level::Back", ""),
    c("DIALOG_INIT", "dialog::Open", "_d__"),                   c("DIALOG_DISPLAY", "dialog::Say", "L"),
    c("DIALOG_SHOW", "dialog::Show", "L"),                      pair("PANORAMA_OFF", "camera::Panorama", "", false),
    pair("PANORAMA_ON", "camera::Panorama", "", true),          pair("AUTOCAMERA_ON", "camera::Auto", "", true),
    pair("AUTOCAMERA_OFF", "camera::Auto", "", false),          c("DISABLEOBJECT", "object::Enable", "oB"),
    c("DELETEOBJECT", "object::Delete", "o"),                   pair("IDLE_OFF", "actor::Idle", "a", false),
    c("ASSIGN_ITEM", "item::Give", "ao"),                       pair("IDLE_ON", "actor::Idle", "a", true),
    c("IDLE_ANIMATION", "actor::IdleAnimation", "an"),          c("WALK_ANIMATION", "actor::WalkAnimation", "anf"),
    c("FADE_IN", "screen::FadeIn", ""),                         c("FADE_BLACK", "screen::Black", ""),
    c("FADE_OUT", "screen::FadeOut", ""),                       c("WALK_ON_SCENERY_TRACK", "actor::WalkOnTrack", "anff"),
    c("ACTOR_GOINDOWN", "actor::GoDown", "aff"),                c("ZOOM", "camera::Zoom", "ZC"),
    c("DOLLY", "camera::Move", "pCZ"),                          c("WEAPON", "actor::Weapon", "anP"),
    c("SOUND", "sound::Play", "s"),                             pair("ALLOW_WALK_IN_AREA", "area::Walkable", "ni", true),
    pair("FORBID_WALK_IN_AREA", "area::Walkable", "ni", false), c("ADDONSCRIPTLET", "scene::Add", "e"),
    c("SETHERO", "hero::SetInParty", "ab"),                     c("STOP_HEROES", "hero::StopAll", ""),
    c("WALKAREA", "area::WalkableAt", "nib"),
};

/// The exe command a Classic line's name runs as: the first of `commands` (the exe
/// table's order) it starts with (`FADE_INDIALOG_DISPLAY` → FADE_IN), else the name.
pub fn exeMatch(name: []const u8) []const u8 {
    for (commands) |p| if (std.ascii.startsWithIgnoreCase(name, p.exe)) return p.exe;
    return name;
}

/// Exe command `exe`'s row.
pub fn ofExe(exe: []const u8) ?*const Cmd {
    for (&commands) |*p| if (std.ascii.eqlIgnoreCase(p.exe, exe)) return p;
    return null;
}

/// OG Script command `name`'s row; a pair's by `flag` (null: its first).
pub fn ofOgs(name: []const u8, flag: ?bool) ?*const Cmd {
    for (&commands) |*p| if (std.mem.eql(u8, p.ogs, name) and (flag == null or p.flag == flag)) return p;
    return null;
}

/// The exe's name of scene command `name` (`actor::WalkTo` → WALKTO; a pair's first); an
/// exe name or an unknown one as it is.
pub fn exeOf(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "::") == null) return name;
    return if (ofOgs(name, null)) |p| p.exe else name;
}

/// The exe's placeholder of `@name` (`hero::selected` → #HERO_SELECTED), else `name`.
pub fn exeActor(name: []const u8) []const u8 {
    for (placeholders) |p| if (std.mem.eql(u8, p[1], name)) return p[0];
    return name;
}

/// The `@` name of exe actor `name` (#HERO_SELECTED → `hero::selected`), else `name`.
pub fn ogsActor(name: []const u8) []const u8 {
    for (placeholders) |p| if (std.ascii.eqlIgnoreCase(p[0], name)) return p[1];
    return name;
}

test "scene commands: each exe name once, each OG name (a pair's by its flag) once, both ways" {
    for (commands, 0..) |p, i| {
        try std.testing.expectEqual(&commands[i], ofExe(p.exe).?);
        try std.testing.expectEqual(&commands[i], ofOgs(p.ogs, p.flag).?);
        for (p.args) |l| try std.testing.expect(std.mem.indexOfScalar(u8, "aopnifbBPTCZlewsd_LS", l) != null);
        for (commands[i + 1 ..]) |q| {
            try std.testing.expect(!std.mem.eql(u8, p.exe, q.exe));
            if (std.mem.eql(u8, p.ogs, q.ogs)) {
                // A pair: the same arguments, the other flag.
                try std.testing.expect(p.flag != null and q.flag != null and p.flag != q.flag);
                try std.testing.expectEqualStrings(p.args, q.args);
            }
        }
    }
    try std.testing.expectEqualStrings("WALKTO", exeOf("WALKTO"));
    try std.testing.expectEqualStrings("PANORAMA_ON", ofOgs("camera::Panorama", true).?.exe);
    try std.testing.expectEqualStrings("#HERO_SELECTED", exeActor(ogsActor("#hero_selected")));
}

/// One scene command: `NAME(arg, …)` (the exe's name and arguments).
pub const Command = struct {
    name: []const u8,
    args: []Arg,
    line: u32,

    pub fn arg(self: Command, i: usize) Arg {
        return if (i < self.args.len) self.args[i] else .{ .string = "" };
    }
};

/// A named point of a scene (`.pts`: background pixels).
pub const Point = struct {
    name: []const u8,
    x: f32,
    y: f32,
    angle: f32,
};

pub const Scene = struct {
    commands: []const Command,
    points: []const Point,
    /// OpenGorky: `enabled = false` in its block: never started, as a
    /// Classic scene whose start calls are commented out.
    off: bool = false,
};

pub const Line = struct {
    speaker: []const u8,
    /// The line's rows joined with spaces.
    text: []const u8,
    /// `#CAM x,y`: the camera scroll while it shows in a level's own dialogue (0x459196).
    cam: ?[2]i32 = null,
    /// Its voice file in `voice.dat` (null: no name, too long).
    voice: ?[]const u8,
};

pub const Dialog = struct {
    lines: []const Line,
};

/// Where a world's scenes and dialogs come from: composition reads and parses the
/// game's files into records (in `a`, the location's arena). Null functions: none.
/// shortcut: asked at a scene's or dialog's first use in the location (scripts name them
/// at run time: StartScriptlet, DialogInit), not all at level entry; each once, kept.
pub const Source = struct {
    ctx: ?*anyopaque = null,
    /// Scene `name` (`scriptlets\<name>.scr`, its `.pts`); error.NotFound: none.
    scene: ?*const fn (ctx: ?*anyopaque, a: Allocator, name: []const u8) anyerror!Scene = null,
    /// Dialog `file` (with or without `.dlg`) as edition `language` cuts it.
    dialog: ?*const fn (ctx: ?*anyopaque, a: Allocator, file: []const u8, language: u8) anyerror!Dialog = null,

    pub fn loadScene(self: Source, a: Allocator, name: []const u8) !Scene {
        return (self.scene orelse return error.NotFound)(self.ctx, a, name);
    }

    pub fn loadDialog(self: Source, a: Allocator, file: []const u8, language: u8) !Dialog {
        return (self.dialog orelse return error.NotFound)(self.ctx, a, file, language);
    }
};

test "int argument wraps like _ftol" {
    try std.testing.expectEqual(@as(i32, 705032704), (Arg{ .number = 5e9 }).int());
    try std.testing.expectEqual(@as(i32, 0), (Arg{ .number = std.math.nan(f32) }).int());
}

test "number argument with trailing junk" {
    try std.testing.expectEqual(@as(f32, 1), (Arg{ .string = "1\"" }).num());
    try std.testing.expectEqual(@as(f32, 2.5), (Arg{ .string = " 2.5x" }).num());
    try std.testing.expectEqual(@as(f32, 0), (Arg{ .string = "abc" }).num());
}
