//! Texts of a new location or battle made from another (App.newLevel): its name, its
//! clean script (a location's party at area `capt_start`; a battle's heroes where the
//! template placed them, no enemies), a location's entry area.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");

/// A folder name the exe takes as `dat\%s\…` and in LEVEL_Load: lower-case letters,
/// digits and `_`. LEVEL_Load takes any `__` for a battle (0x41f1b9) but plays the
/// battle music only for `__` at 2…3 of a name over 5 long (0x41f0da…0x41f0eb): a
/// battle is `NN__…` (`01__port_heavy`), a location has no `__`.
pub fn validName(name: []const u8, battle: bool) bool {
    if (name.len < 3 or name.len > 24) return false;
    if (battle != (name.len > 5 and std.mem.eql(u8, name[2..4], "__"))) return false;
    if (!battle and std.mem.indexOf(u8, name, "__") != null) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

/// Function `name` of script `text` (header to its closing `};` line), if there.
fn function(text: []const u8, name: []const u8) ?[]const u8 {
    var hb: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "function {s}()", .{name}) catch return null;
    const at = std.mem.indexOf(u8, text, head) orelse return null;
    const end = std.mem.indexOfPos(u8, text, at, "\n};") orelse return null;
    return text[at .. end + 3];
}

/// The new level's script: the template's camera, its shadows on or not, the party
/// placed at `capt_start`; init/post_init/update empty for triggers to fill.
pub fn levText(gpa: Allocator, template: []const u8, back_to: []const u8) ![]u8 {
    const cam = function(template, "initCamera") orelse "";
    const shadows = if (function(template, "init")) |f| std.mem.indexOf(u8, f, "shadowActive=1") != null else false;
    const t = try std.fmt.allocPrint(gpa,
        \\#inherit Level
        \\
        \\{s}
        \\
        \\function init()
        \\{{
        \\{s}}};
        \\
        \\function post_init()
        \\{{
        \\}};
        \\
        \\function restore()
        \\{{
        \\  PlaceHeroes("capt_start");
        \\}};
        \\
        \\// A way out: a trigger area (level edit mode) whose block does LEVEL_Load("{s}");
        \\// the way in: one in {s} with LEVEL_Load("<this level>").
        \\function update()
        \\{{
        \\}};
        \\
    , .{ cam, if (shadows) "  shadowActive=1;\n" else "", back_to, back_to });
    defer gpa.free(t);
    // The game's scripts are CRLF (the template's camera may be already).
    const lf_only = try std.mem.replaceOwned(u8, gpa, t, "\r\n", "\n");
    defer gpa.free(lf_only);
    return std.mem.replaceOwned(u8, gpa, lf_only, "\n", "\r\n");
}

/// A new battle's script: the template's camera, its heroes' PlaceActor lines in
/// restore() (not the ones naming `enemies`, its fighters), no enemies (the editor
/// adds them), the staging GUI the game's battles start with.
pub fn battleLevText(gpa: Allocator, template: []const u8, enemies: []const []const u8) ![]u8 {
    const cam = function(template, "initCamera") orelse "";
    var heroes: std.ArrayList(u8) = .empty;
    defer heroes.deinit(gpa);
    if (function(template, "restore")) |body| {
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            const head = "PlaceActor(\"";
            if (!std.mem.startsWith(u8, l, head)) continue;
            const end = std.mem.indexOfScalarPos(u8, l, head.len, '"') orelse continue;
            const who = l[head.len..end];
            for (enemies) |e| {
                if (std.ascii.eqlIgnoreCase(e, who)) break;
            } else try heroes.print(gpa, "    {s}\n", .{l});
        }
    }
    const t = try std.fmt.allocPrint(gpa,
        \\#inherit CombatLevel
        \\
        \\{s}
        \\
        \\function init()
        \\{{
        \\}};
        \\
        \\// A battle's lines before the fight: StartDialog() here plays <this battle>.dlg.
        \\function after_select_gui()
        \\{{
        \\  GUI_SelectMode("GUI_Staging");
        \\}};
        \\
        \\// Started by a location's trigger with LEVEL_Load("<this battle>"); the game
        \\// returns there after it and calls that level's AfterBattle(level).
        \\function restore()
        \\{{
        \\{s}}};
        \\
        \\function update()
        \\{{
        \\}};
        \\
        \\function CombatEnemiesAppear()
        \\{{
        \\}};
        \\
    , .{ cam, heroes.items });
    defer gpa.free(t);
    const lf_only = try std.mem.replaceOwned(u8, gpa, t, "\r\n", "\n");
    defer gpa.free(lf_only);
    return std.mem.replaceOwned(u8, gpa, lf_only, "\n", "\r\n");
}

/// `.ar` with the entry area `capt_start`: a small triangle around `at`.
pub fn arText(gpa: Allocator, at: [2]f32) ![]u8 {
    const x: i32 = @intFromFloat(@round(at[0]));
    const y: i32 = @intFromFloat(@round(at[1]));
    return std.fmt.allocPrint(gpa, "areaCnt=1\r\nareaName: capt_start\r\npointCnt=3\r\n{d},{d},0.000000\r\n{d},{d},0.000000\r\n{d},{d},0.000000\r\ncontrolPoint: {d},{d},0.000000\r\n", .{ x - 12, y - 8, x + 12, y - 8, x, y + 10, x, y });
}

/// `.ar` text with every corner and control point's x, y (background pixels) times
/// `k`, rounded; z and the other lines as they are.
pub fn scaleAr(gpa: Allocator, text: []const u8, k: [2]f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const head = if (std.mem.startsWith(u8, l, "controlPoint:")) "controlPoint: " else "";
        var it = std.mem.splitScalar(u8, std.mem.trimStart(u8, l[@min(l.len, if (head.len > 0) "controlPoint:".len else 0)..], " "), ',');
        const xs = it.next() orelse "";
        const ys = it.next() orelse "";
        const rest = it.rest();
        const x = std.fmt.parseFloat(f32, xs) catch null;
        const y = std.fmt.parseFloat(f32, ys) catch null;
        if (x == null or y == null or rest.len == 0) {
            try out.appendSlice(gpa, l);
            continue;
        }
        try out.print(gpa, "{s}{d},{d},{s}", .{ head, @as(i32, @intFromFloat(@round(x.? * k[0]))), @as(i32, @intFromFloat(@round(y.? * k[1]))), rest });
    }
    return out.toOwnedSlice(gpa);
}

/// `.ap` text with its nodes' x, y (background pixels) times `k` and each link's walk
/// cells (sx, sy, dx, dy: the cells of its end nodes) taken to the cell over the same
/// spot; angles and the rest as they are. Also returns the links before and after (the
/// walk marks follow them).
pub fn scaleAp(gpa: Allocator, text: []const u8, k: [2]f32) !struct { text: []u8, links: [][2][4]f32 } {
    const lf = og.formats.level_files;
    const paths = try lf.parsePaths(gpa, text);
    defer lf.freePaths(gpa, paths);
    const links = try gpa.alloc([2][4]f32, paths.len);
    errdefer gpa.free(links);
    for (paths, links) |*p, *l| {
        for (p.points) |*pt| pt.* = .{ @round(pt[0] * k[0]), @round(pt[1] * k[1]), pt[2], pt[3] };
        l[0] = p.link;
        for (&p.link, 0..) |*v, i| v.* = @floor((v.* + 0.5) * k[i % 2]);
        l[1] = p.link;
    }
    return .{ .text = try lf.encodePaths(gpa, paths), .links = links };
}

/// A scene's `.pts` text (`name,x,y,angle` lines, background pixels) with x, y times `k`,
/// rounded; the other lines as they are.
pub fn scalePts(gpa: Allocator, text: []const u8, k: [2]f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const body = std.mem.trimEnd(u8, l, "\r");
        var f = std.mem.splitScalar(u8, body, ',');
        const n = f.next() orelse "";
        const x = std.fmt.parseFloat(f32, std.mem.trim(u8, f.next() orelse "", " ")) catch null;
        const y = std.fmt.parseFloat(f32, std.mem.trim(u8, f.next() orelse "", " ")) catch null;
        if (x == null or y == null) {
            try out.appendSlice(gpa, l);
            continue;
        }
        try out.print(gpa, "{s},{d},{d}{s}{s}{s}", .{ n, @as(i32, @intFromFloat(@round(x.? * k[0]))), @as(i32, @intFromFloat(@round(y.? * k[1]))), if (std.mem.count(u8, body, ",") > 2) "," else "", f.rest(), l[body.len..] });
    }
    return out.toOwnedSlice(gpa);
}

test scaleAp {
    const gpa = std.testing.allocator;
    const r = try scaleAp(gpa, "pathCnt=1\r\npathName: szuflada\r\n    link: sx 100, sy 58, dx 72, dy 39\r\n    pointCnt=2\r\n        804,468,0.000000,28\r\n        580,316,-1.040000,-136\r\n\r\n", .{ 2, 0.5 });
    defer gpa.free(r.text);
    defer gpa.free(r.links);
    try std.testing.expectEqualStrings("pathCnt=1\r\npathName: szuflada\r\n    link: sx 201, sy 29, dx 145, dy 19\r\n    pointCnt=2\r\n        1608,234,0.000000,28\r\n        1160,158,-1.040000,-136\r\n\r\n", r.text);
    // The link cells are the end nodes' cells.
    try std.testing.expectEqual(@as(f32, @floor(1608.0 / 8.0)), r.links[0][1][0]);
    const t = try scalePts(gpa, "p1,100,50,0\r\nbad line\r\np2,10,10\r\n", .{ 2, 2 });
    defer gpa.free(t);
    try std.testing.expectEqualStrings("p1,200,100,0\r\nbad line\r\np2,20,20\r\n", t);
}

/// A background `.cfg` copied for level `name`: its `bkg` and `krz` lines (the picture
/// and overlay it names) naming `name`'s; the rest as it is.
pub fn cfgFor(gpa: Allocator, text: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const key = for ([_][]const u8{ "bkg ", "krz " }) |k| {
            if (std.mem.startsWith(u8, l, k)) break k;
        } else {
            try out.appendSlice(gpa, l);
            continue;
        };
        try out.print(gpa, "{s}{s}{s}", .{ key, name, if (std.mem.endsWith(u8, l, "\r")) "\r" else "" });
    }
    return out.toOwnedSlice(gpa);
}

test cfgFor {
    const t = try cfgFor(std.testing.allocator, "bkg 01_port\r\nkrz 01_port\r\n\r\nmod models\\owicz.msh\r\ngscale 253.000000\r\n", "09_new");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("bkg 09_new\r\nkrz 09_new\r\n\r\nmod models\\owicz.msh\r\ngscale 253.000000\r\n", t);
}

// ---------------------------------------------------------------- a blank level

/// The pixel format record every level's sprite.dat holds as `1.bin` (the same 160 bytes
/// in all the game's levels: RGB565 masks and the palette the exe's loader expects).
const pixel_format = [_]u8{
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00,
    0x05, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x06, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0xe0, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x05, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x80, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x40, 0x05, 0x00, 0x00, 0x55, 0x05, 0x00, 0x00,
    0x00, 0xa8, 0x00, 0x00, 0x15, 0xa8, 0x00, 0x00, 0xa0, 0xaa, 0x00, 0x00, 0x55, 0xad, 0x00, 0x00,
    0xaa, 0x52, 0x00, 0x00, 0xbf, 0x52, 0x00, 0x00, 0xea, 0x57, 0x00, 0x00, 0xff, 0x57, 0x00, 0x00,
    0xaa, 0xfa, 0x00, 0x00, 0xbf, 0xfa, 0x00, 0x00, 0xea, 0xff, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
    0x9a, 0xd6, 0x00, 0x00, 0xd3, 0x9c, 0x00, 0x00, 0x30, 0x84, 0x00, 0x00, 0xcb, 0x5a, 0x00, 0x00,
};

/// A battle's camera over a 1280×960 picture and the grid it projects (the game's
/// common battle view, 01__port_park's numbers), the party at the grid's foot.
const battle_tpl =
    \\function initCamera()
    \\{
    \\    perspective=1;
    \\    frontPlane=0.8;
    \\    backPlane=-27.9118;
    \\    viewX=-2.750;
    \\    viewY=7.984;
    \\    viewZ=25.369;
    \\    aimX=3.773;
    \\    aimY=-5.167;
    \\    aimZ=-0.794;
    \\    angle=16.732;
    \\    zLevel=-0.851845;
    \\    cameraScale = 0;
    \\};
    \\
    \\function restore()
    \\{
    \\    PlaceActor("Sullivan",7,16);
    \\    PlaceActor("Trantigne",9,16);
    \\    PlaceActor("Ovitz",10,14);
    \\};
    \\
;

/// A location's camera over a 640×480 picture (01_port_store's numbers).
const location_tpl =
    \\function initCamera()
    \\{
    \\    perspective=1;
    \\    frontPlane=0.8;
    \\    backPlane=-9.7195;
    \\    viewX=-0.393;
    \\    viewY=1.134;
    \\    viewZ=5.696;
    \\    aimX=1.125;
    \\    aimY=0.353;
    \\    aimZ=0.823;
    \\    angle=61.339;
    \\    zLevel=-0.6;
    \\    actorScale=0.286405;
    \\    speedScale=1.404963;
    \\};
    \\
;

/// A blank level's picture size by default: what its template camera is made for.
pub fn blankSize(battle: bool) [2]u32 {
    return if (battle) .{ 1280, 960 } else .{ 640, 480 };
}

/// Picture sizes a blank level may take: the exe's screen at least (640×480), cells of 8
/// pixels (the walk grid's); at most the game's own largest picture (2600×1916) in a
/// Classic project (no larger one is known to load in the exe), the port's `.bkg` limit
/// in an OpenGorky one.
pub fn checkBlankSize(size: [2]u32, og_project: bool) !void {
    if (size[0] < 640 or size[1] < 480) return error.PictureTooSmall;
    if (size[0] % 8 != 0 or size[1] % 8 != 0) return error.PictureNotCellsOf8;
    const max: [2]u32 = if (og_project) @splat(og.formats.background.max_side) else .{ 2600, 1916 };
    if (size[0] > max[0] or size[1] > max[1]) return error.PictureTooLarge;
}

/// Template camera `tpl` (made for a `from` picture) for a `to` picture: the view angle
/// spans the picture's width (camera.Persp.initBank), so it widens with the aspect and
/// the template's vertical view (its grid, its floor) stays the same.
fn cameraFor(a: Allocator, tpl: []const u8, from: [2]u32, to: [2]u32) ![]const u8 {
    const ang = cameraVar(tpl, "fov") orelse return tpl;
    const k = (@as(f32, @floatFromInt(to[0])) / @as(f32, @floatFromInt(to[1]))) / (@as(f32, @floatFromInt(from[0])) / @as(f32, @floatFromInt(from[1])));
    if (k == 1) return tpl;
    return setCameraVar(a, tpl, "fov", 2 * std.math.atan(@tan(ang * std.math.pi / 360) * k) * 180 / std.math.pi);
}

/// The background `.cfg` of a perspective level (0x41cf07: eye, target, scene depth) from
/// its camera, as the game's battles write it: the target a fifth of a unit along the view,
/// `tl` the planes' span. Its `.zbf` values then map as without one, the far plane at v = 0.
fn perspCfg(a: Allocator, lev: []const u8) ![]const u8 {
    const eye: [3]f32 = .{ cameraVar(lev, "eye_x") orelse 0, cameraVar(lev, "eye_y") orelse 0, cameraVar(lev, "eye_z") orelse 0 };
    const aim: [3]f32 = .{ cameraVar(lev, "target_x") orelse 0, cameraVar(lev, "target_y") orelse 0, cameraVar(lev, "target_z") orelse 0 };
    const d: [3]f32 = .{ aim[0] - eye[0], aim[1] - eye[1], aim[2] - eye[2] };
    const len = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    const t = 0.2 / @max(len, 1e-6);
    const tl = (cameraVar(lev, "near_plane") orelse 0) - (cameraVar(lev, "far_plane") orelse 0);
    return std.fmt.allocPrint(a, "vx {d:.3}\r\nvy {d:.3}\r\nvz {d:.3}\r\ntx {d:.6}\r\nty {d:.6}\r\ntz {d:.6}\r\ntl {d:.4}\r\n", .{ eye[0], eye[1], eye[2], eye[0] + d[0] * t, eye[1] + d[1] * t, eye[2] + d[2] * t, tl });
}

/// The files of a new blank level `name` (a battle by its name, `validName`) with a
/// `size` picture (checkBlankSize): a grey `.jpg` (as the game's battles and small
/// locations), its camera the template's widened to the picture's aspect (cameraFor), a
/// depth that keeps every model in front with its `.cfg` (perspCfg), one ambient light, a
/// free grid (a battle's 20×32 cells, a location's walk and second floor all walkable),
/// the entry area `capt_start` in the near middle and a clean script; `sprites` and
/// `other` as levelops.writeLevel takes them (exe-readable formats only). The picture,
/// depth, grid and camera are then the level edit mode's. No `.krz`: the exe reads one
/// only as an orthographic level's floor height offsets (0x430d00, through the ortho
/// projection 0x496860; 01_port's alone), and a blank level is perspective.
pub fn blank(a: Allocator, name: []const u8, battle: bool, size: [2]u32) !struct { sprites: []og.formats.archive.File, other: []og.formats.archive.File } {
    const fmt = og.formats;
    var pic = try og.image.Image.init(a, size[0], size[1]);
    for (0..size[0] * size[1]) |i| pic.pixels[i * 4 ..][0..4].* = .{ 96, 96, 96, 255 };
    const depth = try a.alloc(u16, size[0] * size[1]);
    @memset(depth, 0);
    const lights: fmt.level_files.Lights = .{ .omni = &.{}, .ambient = @splat(0.6), .directional_color = @splat(0.82), .shadow_light = .{ 2130, 554.5, 4285.5 }, .shadow_intensity = 0.6 };
    const sprites = try a.dupe(fmt.archive.File, &.{
        .{ .name = "1.bin", .data = &pixel_format },
        .{ .name = try std.fmt.allocPrint(a, "background\\{s}.jpg", .{name}), .data = try fmt.jpeg.encode(a, pic, 92) },
        .{ .name = try std.fmt.allocPrint(a, "background\\{s}.zbf", .{name}), .data = try fmt.zbuffer.encode(a, .{ .width = size[0], .height = size[1], .depth = depth }) },
    });
    var other: std.ArrayList(fmt.archive.File) = .empty;
    const f = struct {
        fn n(al: Allocator, nm: []const u8, ext: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}.{s}", .{ nm, ext });
        }
    }.n;
    try other.append(a, .{ .name = try f(a, name, "lts"), .data = try fmt.level_files.encodeLights(a, lights) });
    try other.append(a, .{ .name = try f(a, name, "ar"), .data = try arText(a, .{ @floatFromInt(size[0] / 2), @floatFromInt(size[1] * 3 / 4) }) });
    if (battle) {
        const w = 20;
        const h = 32;
        const blocked = try a.alloc(bool, w * h);
        @memset(blocked, false);
        const cm: fmt.level_files.CombatMap = .{ .center = .{ 20.55658, 165.96289, -147 }, .rotation = 0.18, .cell_size = @splat(57), .width = w, .height = h, .blocked = blocked, .heights = &.{} };
        try other.append(a, .{ .name = try f(a, name, "cm"), .data = try fmt.level_files.encodeCombatMap(a, cm) });
        try other.append(a, .{ .name = try f(a, name, "lev"), .data = try battleLevText(a, try cameraFor(a, battle_tpl, blankSize(true), size), &.{}) });
    } else {
        const cs = og.core.map.WalkMap.cell_size;
        const cells = try a.alloc(fmt.level_files.WalkMap.Cell, (size[0] / cs) * (size[1] / cs));
        @memset(cells, .{ .kind = 1, .height = 0 });
        const wm = try fmt.level_files.encodeWalkMap(a, .{ .width = size[0] / cs, .height = size[1] / cs, .cells = cells });
        try other.append(a, .{ .name = try f(a, name, "wm"), .data = wm });
        try other.append(a, .{ .name = try f(a, name, "wm2"), .data = wm });
        try other.append(a, .{ .name = try f(a, name, "ap"), .data = "pathCnt=0\r\n" });
        try other.append(a, .{ .name = try f(a, name, "lev"), .data = try levText(a, try cameraFor(a, location_tpl, blankSize(false), size), "01_port") });
    }
    const lev = other.items[other.items.len - 1].data;
    const with_cfg = try a.alloc(fmt.archive.File, sprites.len + 1);
    @memcpy(with_cfg[0..sprites.len], sprites);
    with_cfg[sprites.len] = .{ .name = try std.fmt.allocPrint(a, "background\\{s}.cfg", .{name}), .data = try perspCfg(a, lev) };
    return .{ .sprites = with_cfg, .other = other.items };
}

test blank {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fmt = og.formats;
    for ([_]bool{ true, false }, [_][]const u8{ "09__blank", "09_blank" }) |battle, name| {
        const l = try blank(a, name, battle, blankSize(battle));
        // Every file reads back with the game's parsers.
        for (l.sprites) |x| {
            if (std.mem.endsWith(u8, x.name, ".jpg")) {
                const img = try fmt.jpeg.decode(a, x.data);
                try std.testing.expectEqual(@as(u32, if (battle) 1280 else 640), img.width);
            }
            if (std.mem.endsWith(u8, x.name, ".zbf")) _ = try fmt.zbuffer.decode(a, x.data);
            // The exe's perspective `.cfg`: the port reads it back, the planes' span its depth.
            if (std.mem.endsWith(u8, x.name, ".cfg")) try std.testing.expectApproxEqAbs(@as(f32, if (battle) 28.7118 else 10.5195), fmt.level.parsePerspCfg(x.data).?.tl, 1e-3);
        }
        for (l.other) |x| {
            if (std.mem.endsWith(u8, x.name, ".cm")) try std.testing.expectEqual(@as(u32, 32), (try fmt.level_files.parseCombatMap(a, x.data)).height);
            if (std.mem.endsWith(u8, x.name, ".wm")) try std.testing.expectEqual(@as(u32, 80), (try fmt.level_files.parseWalkMap(a, x.data)).width);
            if (std.mem.endsWith(u8, x.name, ".lts")) _ = try fmt.level_files.parseLights(a, x.data);
            if (std.mem.endsWith(u8, x.name, ".ar")) try std.testing.expectEqual(@as(usize, 1), (try fmt.level_files.parseAreas(a, x.data)).len);
            if (std.mem.endsWith(u8, x.name, ".lev")) try std.testing.expect(cameraVar(x.data, "far_plane") != null);
        }
    }
}

test cameraFor {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The same aspect: the template as it is; twice as wide: tan(angle/2) doubles.
    try std.testing.expectEqualStrings(battle_tpl, try cameraFor(a, battle_tpl, .{ 1280, 960 }, .{ 640, 480 }));
    const wide = try cameraFor(a, battle_tpl, .{ 1280, 960 }, .{ 2560, 960 });
    try std.testing.expectApproxEqAbs(2 * @tan(16.732 * std.math.pi / 360.0), @tan(cameraVar(wide, "fov").? * std.math.pi / 360.0), 1e-4);
    try std.testing.expectError(error.PictureNotCellsOf8, checkBlankSize(.{ 1284, 960 }, false));
    try std.testing.expectError(error.PictureTooLarge, checkBlankSize(.{ 4096, 960 }, false));
    try checkBlankSize(.{ 4096, 960 }, true);
}

test scaleAr {
    const gpa = std.testing.allocator;
    const t = try scaleAr(gpa, "areaCnt=1\r\nareaName: capt_start\r\npointCnt=2\r\n388,292,0.000000\r\n412,310,3.059999\r\ncontrolPoint: 400,300,0.000000\r\n", .{ 2, 0.5 });
    defer gpa.free(t);
    try std.testing.expectEqualStrings("areaCnt=1\r\nareaName: capt_start\r\npointCnt=2\r\n776,146,0.000000\r\n824,155,3.059999\r\ncontrolPoint: 800,150,0.000000\r\n", t);
}

test validName {
    try std.testing.expect(validName("01_port_bar", false));
    try std.testing.expect(!validName("01__port_bar", false));
    try std.testing.expect(validName("01__port_bar", true));
    try std.testing.expect(!validName("01_port_bar", true));
    try std.testing.expect(!validName("port__bar", true));
    try std.testing.expect(!validName("01__x", true));
    try std.testing.expect(!validName("01_port__bar", false));
    try std.testing.expect(!validName("Port", false));
    try std.testing.expect(!validName("a b", false));
}

test battleLevText {
    const gpa = std.testing.allocator;
    const tpl = "#inherit CombatLevel\r\n\r\nfunction initCamera()\r\n{\r\n    perspective=1;\r\n    cameraScale = 0;\r\n};\r\n\r\nfunction restore()\r\n{\r\n    //PlaceActor(\"Sullivan\",\"capt_start\",0);\r\n    PlaceActor(\"Trantigne\",4,1,2);\r\n    PlaceActor(\"Sullivan\",6,4,4);\r\n    PlaceActor(\"01b_sfinks\",1,5);\r\n    AIEnemyAppear(\"01b_sfinks\", -2, 5, 1, 5);\r\n};\r\n";
    const t = try battleLevText(gpa, tpl, &.{"01B_sfinks"});
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "    cameraScale = 0;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "{\r\n    PlaceActor(\"Trantigne\",4,1,2);\r\n    PlaceActor(\"Sullivan\",6,4,4);\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "sfinks") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "\n\n") == null);
}

test levText {
    const gpa = std.testing.allocator;
    const tpl = "#inherit Level\r\n\r\nfunction initCamera()\r\n{\r\n\tperspective=1;\r\n};\r\n\r\nfunction init()\r\n{\r\n\tshadowActive=1;\r\n  x = 1;\r\n};\r\n";
    const t = try levText(gpa, tpl, "01_port");
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "function initCamera()\r\n{\r\n\tperspective=1;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "  shadowActive=1;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "x = 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "PlaceHeroes(\"capt_start\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "\n\n") == null);
}

/// The value of `key = <number>;` in the level script's initCamera(), if set there.
pub fn cameraVar(lev: []const u8, key: []const u8) ?f32 {
    const cam = function(lev, "initCamera") orelse return null;
    const at = assignment(cam, levelName(key)) orelse return null;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, cam[at[0]..at[1]], " \t")) catch null;
}

/// The value of `key=<number>` in a `.var` text (`variables\\<object>.var`), if there.
pub fn varValue(var_text: []const u8, name: []const u8) ?f32 {
    const key = levelName(name);
    var lines = std.mem.splitScalar(u8, var_text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == '=') return std.fmt.parseFloat(f32, std.mem.trim(u8, l[key.len + 1 ..], " \t")) catch null;
    }
    return null;
}

/// Level field `name` (the engine's: `eye_x`) as a Classic `.lev`/`.var` spells it (`viewX`).
fn levelName(name: []const u8) []const u8 {
    return og.script.classic.names.anyOld(name) orelse name;
}

/// Where the value of `key = …;` is in `text` (a whole-word key, not in a comment).
fn assignment(text: []const u8, key: []const u8) ?[2]usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var off: usize = 0;
    while (lines.next()) |l| : (off += l.len + 1) {
        const t = std.mem.trimStart(u8, l, " \t");
        if (!std.mem.startsWith(u8, t, key)) continue;
        const rest = std.mem.trimStart(u8, t[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const v0 = off + (l.len - rest.len) + 1;
        const semi = std.mem.indexOfScalarPos(u8, text, v0, ';') orelse continue;
        if (semi > off + l.len) continue;
        return .{ v0, semi };
    }
    return null;
}

/// `lev` with `key = value;` in initCamera(): the value replaced, or a line added
/// before its closing `};` (the camera vars the exe reads right after it, 0x4218e9).
pub fn setCameraVar(gpa: Allocator, lev: []const u8, name: []const u8, value: f32) ![]u8 {
    const cam = function(lev, "initCamera") orelse return error.NoCamera;
    const base = @intFromPtr(cam.ptr) - @intFromPtr(lev.ptr);
    var vb: [32]u8 = undefined;
    // 6 decimals, as the game's own (`actorScale=0.108346`).
    const v = try std.fmt.bufPrint(&vb, "{d:.6}", .{value});
    const key = levelName(name);
    if (assignment(cam, key)) |at| return std.mem.concat(gpa, u8, &.{ lev[0 .. base + at[0]], " ", v, lev[base + at[1] ..] });
    const close = base + cam.len - 2; // the `};` line
    const nl = if (std.mem.indexOf(u8, lev, "\r\n") != null) "\r\n" else "\n";
    const line = try std.fmt.allocPrint(gpa, "\t{s} = {s};{s}", .{ key, v, nl });
    defer gpa.free(line);
    return std.mem.concat(gpa, u8, &.{ lev[0..close], line, lev[close..] });
}

test setCameraVar {
    const gpa = std.testing.allocator;
    const lev = "function initCamera()\r\n{\r\n\tzLevel=-0.6;\r\n};\r\n\r\nfunction init()\r\n{\r\n};\r\n";
    const a = try setCameraVar(gpa, lev, "actor_scale", 0.2);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("function initCamera()\r\n{\r\n\tzLevel=-0.6;\r\n\tactorScale = 0.200000;\r\n};\r\n\r\nfunction init()\r\n{\r\n};\r\n", a);
    try std.testing.expectEqual(@as(f32, 0.2), cameraVar(a, "actor_scale").?);
    const b = try setCameraVar(gpa, a, "actor_scale", 0.25);
    defer gpa.free(b);
    try std.testing.expectEqual(@as(f32, 0.25), cameraVar(b, "actor_scale").?);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expect(cameraVar(lev, "actor_scale") == null);
    try std.testing.expectEqual(@as(f32, 0.644575), varValue("actorScaleX=1\r\nactorScale=0.108346\r\nspeedScale=0.644575\r\n", "speed_scale").?);
    try std.testing.expect(varValue("actorScaleX=1\r\n", "actor_scale") == null);
}

// ---------------------------------------------------------------- OpenGorky

/// Level `level`'s module under `top` (`locations`, `battles`) as the converter names it:
/// `locations::_01_port` (`_` before a digit, other signs as `_`), in `gpa`.
fn ogModule(gpa: Allocator, top: []const u8, level: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{s}::", .{top});
    if (level.len == 0 or std.ascii.isDigit(level[0])) try out.append(gpa, '_');
    for (level) |ch| try out.append(gpa, if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_');
    return out.toOwnedSlice(gpa);
}

/// A level's text (`level.ogs`, `objects.ogs`, `logic.ogs` of `<top>/<from>/`) for its copy
/// `to`: its block's name (`level "from"`, `battle from`) and every `"from"` as `to`, its
/// module and the paths into it (`locations::_from::comp`) as the copy's.
pub fn ogCopyText(gpa: Allocator, text: []const u8, top: []const u8, from: []const u8, to: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const old_mod = try ogModule(a, top, from);
    const new_mod = try ogModule(a, top, to);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const word_start = i == 0 or !isIdent(text[i - 1]);
        if (word_start and std.mem.startsWith(u8, text[i..], old_mod) and (i + old_mod.len == text.len or !isIdent(text[i + old_mod.len]))) {
            try out.appendSlice(a, new_mod);
            i += old_mod.len;
        } else if (text[i] == '"' and std.ascii.startsWithIgnoreCase(text[i + 1 ..], from) and i + 1 + from.len < text.len and text[i + 1 + from.len] == '"') {
            try out.print(a, "\"{s}\"", .{to});
            i += from.len + 2;
        } else if (word_start and bareHead(text[i..], from) != null) {
            const kind = bareHead(text[i..], from).?;
            try out.print(a, "{s} \"{s}\"", .{ kind, to });
            i += kind.len + 1 + from.len;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
    return gpa.dupe(u8, out.items);
}

/// The kinds of a level's objects that a copy renames (a level's `hero` is the party's,
/// one for every level: kept).
const og_object_kinds = [_][]const u8{ "actor", "active_anim", "anim", "area", "fighter", "item", "obstacle", "weapon" };

/// Fields naming an asset, not an object (`sprite = "09_sejf"` beside object `09_sejf`).
const og_asset_fields = [_][]const u8{ "sprite", "depth_sprite", "mesh", "icon", "areaName", "portrait" };

/// The objects copied level `texts` make: its blocks' objects (`area "x" {`, `fighter x:
/// characters::y {`, at the block's indent) and the ones its code makes by name
/// (`item::New("x", …)`, `item::NewWeapon`, `sound::NewAmbient`). In `a`.
pub fn ogObjectNames(a: Allocator, texts: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (texts) |text| {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| if (objectHead(l)) |h| try addName(a, &out, h.name);
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "::New")) |k| : (at = k + 1) {
            var e = k + "::New".len;
            while (e < text.len and isIdent(text[e])) e += 1;
            if (!std.mem.startsWith(u8, text[e..], "(\"")) continue;
            const q = std.mem.indexOfScalarPos(u8, text, e + 2, '"') orelse continue;
            try addName(a, &out, text[e + 2 .. q]);
        }
    }
    return out.items;
}

fn addName(a: Allocator, out: *std.ArrayList([]const u8), n: []const u8) !void {
    if (n.len == 0) return;
    for (out.items) |x| if (std.ascii.eqlIgnoreCase(x, n)) return;
    try out.append(a, n);
}

/// Line `l` as an object's head of a level block (four spaces, an object kind, its name
/// bare or quoted): the name and where it is in `l` (quotes included).
fn objectHead(l: []const u8) ?struct { name: []const u8, start: usize, end: usize } {
    if (!std.mem.startsWith(u8, l, "    ") or l.len < 5 or l[4] == ' ') return null;
    const sp = std.mem.indexOfScalarPos(u8, l, 4, ' ') orelse return null;
    for (og_object_kinds) |k| {
        if (!std.mem.eql(u8, l[4..sp], k)) continue;
        const s = sp + 1;
        if (s < l.len and l[s] == '"') {
            const q = std.mem.indexOfScalarPos(u8, l, s + 1, '"') orelse return null;
            return .{ .name = l[s + 1 .. q], .start = s, .end = q + 1 };
        }
        var e = s;
        while (e < l.len and isIdent(l[e])) e += 1;
        if (e == s or e >= l.len or (l[e] != ' ' and l[e] != ':')) return null;
        return .{ .name = l[s..e], .start = s, .end = e };
    }
    return null;
}

/// Parameters of the engine's functions (editor/api.zig's names) that never name an
/// object: `actor::Place(x, "area")`, `actor::WalkOnTrack(x, "track")` (an area, a path
/// or a link point may share an object's name: `ponton` of 01_port is all three).
const og_not_object_params = [_][]const u8{ "area", "track", "point", "mesh", "anim", "idle", "file", "wav", "sounds", "class", "kind", "mode", "text", "state", "function", "event", "value", "logical", "ai" };

/// The string at `l[q]` (its `"`) may name an object: not an argument of a known engine
/// function whose parameter there is no object (og_not_object_params). The call is found
/// on the line (strings skipped), as the writer puts a call's arguments on one.
fn objectArg(l: []const u8, q: usize) bool {
    var names: [16][]const u8 = undefined;
    var args: [16]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < q) : (i += 1) switch (l[i]) {
        '"' => i = std.mem.indexOfScalarPos(u8, l, i + 1, '"') orelse return true,
        '(' => {
            var s = i;
            while (s > 0 and (isIdent(l[s - 1]) or l[s - 1] == ':')) s -= 1;
            if (n < names.len) {
                names[n] = l[s..i];
                args[n] = 0;
            }
            n += 1;
        },
        ')' => n -|= 1,
        ',' => if (n > 0 and n <= args.len) {
            args[n - 1] += 1;
        },
        else => {},
    };
    if (n == 0 or n > names.len) return true;
    const api = @import("api.zig");
    const f = api.find(names[n - 1]) orelse return true;
    var pb: [12]api.Param = undefined;
    const ps = api.params(f, &pb);
    if (args[n - 1] >= ps.len) return true;
    const decl = ps[args[n - 1]].decl;
    const pn = decl[(std.mem.lastIndexOfScalar(u8, decl, ' ') orelse return true) + 1 ..];
    for (og_not_object_params) |x| if (std.mem.eql(u8, x, pn)) return false;
    return true;
}

/// Object `old` of level `from` as its copy `to` names it: `<to>_` before it, a `<from>_`
/// it starts with dropped (a copy of a copy does not grow).
fn ogObjectName(a: Allocator, old: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const rest = if (old.len > from.len + 1 and std.ascii.startsWithIgnoreCase(old, from) and old[from.len] == '_') old[from.len + 1 ..] else old;
    return std.fmt.allocPrint(a, "{s}_{s}", .{ to, rest });
}

/// Text `text` of a level copied from `from` as `to` with each of `names` (ogObjectNames)
/// as the copy names it (ogObjectName): object heads (quoted), `@x` / `@"x"`, and the
/// strings naming them (`"x"`, each of a list `"x,y"`), not the sigil references (`~s"x"`)
/// nor the asset fields (`sprite = "x"`). Matched case-insensitively. In `gpa`.
pub fn ogRenameObjects(gpa: Allocator, text: []const u8, names: []const []const u8, from: []const u8, to: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const New = struct {
        fn of(al: Allocator, ns: []const []const u8, n: []const u8, f: []const u8, t: []const u8) !?[]const u8 {
            for (ns) |x| if (std.ascii.eqlIgnoreCase(x, n)) return try ogObjectName(al, x, f, t);
            return null;
        }
    };
    var out: std.ArrayList(u8) = .empty;
    var ls: usize = 0;
    while (ls < text.len) {
        const le = if (std.mem.indexOfScalarPos(u8, text, ls, '\n')) |k| k + 1 else text.len;
        var l = text[ls..le];
        ls = le;
        if (objectHead(l)) |h| if (try New.of(a, names, h.name, from, to)) |n| {
            try out.print(a, "{s}\"{s}\"", .{ l[0..h.start], n });
            l = l[h.end..];
        };
        const lead = std.mem.trimStart(u8, l, " \t");
        const asset = for (og_asset_fields) |f| {
            const v = if (std.mem.startsWith(u8, lead, "var ")) if (std.mem.indexOfScalarPos(u8, lead, 4, ' ')) |k| lead[k + 1 ..] else lead else lead;
            if (std.mem.startsWith(u8, v, f) and std.mem.startsWith(u8, v[f.len..], " = ")) break true;
        } else false;
        var i: usize = 0;
        while (i < l.len) {
            const ch = l[i];
            if (ch == '@' and i + 1 < l.len and isIdent(l[i + 1])) {
                var e = i + 1;
                while (e < l.len and isIdent(l[e])) e += 1;
                if (try New.of(a, names, l[i + 1 .. e], from, to)) |n| try out.print(a, "@\"{s}\"", .{n}) else try out.appendSlice(a, l[i..e]);
                i = e;
            } else if (ch == '"') {
                var e = i + 1;
                while (e < l.len and l[e] != '"') : (e += 1) if (l[e] == '\\') {
                    e += 1;
                };
                if (e >= l.len) {
                    try out.appendSlice(a, l[i..]);
                    break;
                }
                const sigil = i >= 2 and l[i - 2] == '~';
                try out.append(a, '"');
                if (sigil or asset or !objectArg(l, i)) try out.appendSlice(a, l[i + 1 .. e]) else {
                    var parts = std.mem.splitScalar(u8, l[i + 1 .. e], ',');
                    var first = true;
                    while (parts.next()) |p| : (first = false) {
                        if (!first) try out.append(a, ',');
                        try out.appendSlice(a, (try New.of(a, names, p, from, to)) orelse p);
                    }
                }
                try out.append(a, '"');
                i = e + 1;
            } else {
                try out.append(a, ch);
                i += 1;
            }
        }
    }
    return gpa.dupe(u8, out.items);
}

/// `v` as an OG Script float (`0.0`, never `0`: an int where the schema wants a float).
fn float(a: Allocator, v: f32) ![]const u8 {
    return if (v == @trunc(v)) std.fmt.allocPrint(a, "{d}.0", .{v}) else std.fmt.allocPrint(a, "{d}", .{v});
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// `level <name> ` / `battle <name> ` (a block's head with its name as a word) at `t`'s
/// start: its kind; null: none.
fn bareHead(t: []const u8, name: []const u8) ?[]const u8 {
    for ([_][]const u8{ "level", "battle" }) |kind| {
        if (!std.mem.startsWith(u8, t, kind) or t.len <= kind.len + 1 + name.len or t[kind.len] != ' ') continue;
        const rest = t[kind.len + 1 ..];
        if (std.mem.startsWith(u8, rest, name) and !isIdent(rest[name.len])) return kind;
    }
    return null;
}

/// A new OpenGorky level's block text from Classic level script `lev` (a blank's, newlevel.blank):
/// `level "<name>"` (`battle` for a battle) with the camera of its initCamera() as
/// `camera = Camera(…)`, a location's character size and walk speed and its party's entry
/// point `capt_start`, a battle's heroes placed by restore()'s `PlaceActor("x", col, row)`.
pub fn ogLevelBlock(gpa: Allocator, name: []const u8, battle: bool, lev: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var cam: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "perspective", "near_plane", "far_plane", "eye_x", "eye_y", "eye_z", "target_x", "target_y", "target_z", "fov", "floor_z", "camera_scale" }) |k| {
        const v = cameraVar(lev, k) orelse continue;
        if (cam.items.len > 0) try cam.appendSlice(a, ", ");
        if (std.mem.eql(u8, k, "perspective")) try cam.print(a, "perspective = {s}", .{if (v != 0) "true" else "false"}) else try cam.print(a, "{s} = {s}", .{ k, try float(a, v) });
    }
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s} \"{s}\" {{\n", .{ if (battle) "battle" else "level", name });
    if (cam.items.len > 0) try out.print(a, "    camera = Camera({s});\n", .{cam.items});
    if (battle) {
        var places: std.ArrayList(u8) = .empty;
        if (function(lev, "restore")) |body| {
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |raw| {
                const l = std.mem.trim(u8, raw, " \t\r");
                const head = "PlaceActor(\"";
                if (!std.mem.startsWith(u8, l, head)) continue;
                const q = std.mem.indexOfScalarPos(u8, l, head.len, '"') orelse continue;
                var nums = std.mem.tokenizeAny(u8, l[q + 1 ..], ",); ");
                const x = std.fmt.parseInt(i32, nums.next() orelse continue, 10) catch continue;
                const y = std.fmt.parseInt(i32, nums.next() orelse continue, 10) catch continue;
                try places.print(a, "{s}Place(who = @{s}, tile = [{d}, {d}])", .{ if (places.items.len > 0) ", " else "", l[head.len..q], x, y });
            }
        }
        if (places.items.len > 0) try out.print(a, "    placement = [{s}];\n", .{places.items});
    } else {
        try out.appendSlice(a, "    entry = \"capt_start\";\n");
        for ([_][]const u8{ "actor_scale", "speed_scale" }) |k| if (cameraVar(lev, k)) |v| try out.print(a, "    {s} = {s};\n", .{ k, try float(a, v) });
    }
    try out.appendSlice(a, "}\n");
    return gpa.dupe(u8, out.items);
}

test ogCopyText {
    const gpa = std.testing.allocator;
    const t = try ogCopyText(gpa,
        \\level "01_port_chief" {
        \\    area x { attach locations::_01_port_chief::_x(); }
        \\}
        \\module locations::_01_port_chief { component _x for area { fn OnExit() { level::Load(~l"01_port"); } } }
        \\module locations::_01_port_chief_old { }
        \\level other { }
        \\
    , "locations", "01_port_chief", "zz_copy");
    defer gpa.free(t);
    try std.testing.expectEqualStrings(
        \\level "zz_copy" {
        \\    area x { attach locations::zz_copy::_x(); }
        \\}
        \\module locations::zz_copy { component _x for area { fn OnExit() { level::Load(~l"01_port"); } } }
        \\module locations::_01_port_chief_old { }
        \\level other { }
        \\
    , t);
    const b = try ogCopyText(gpa, "battle b1 {\n}\nbattle b1x { }\n", "battles", "b1", "b2");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("battle \"b2\" {\n}\nbattle b1x { }\n", b);
}

test ogRenameObjects {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const objects =
        \\battle "b1" {
        \\    area sejf_are {
        \\        var string itm_2 = "01pch_g1,01pch_g2";
        \\        areaName = "sejf";
        \\        attach battles::b2::sejf_are();
        \\    }
        \\    active_anim "09_sejf" {
        \\        sprite = "09_sejf";
        \\    }
        \\    fighter b1_x: characters::garcia {
        \\    }
        \\    weapon "x_la": weapons::garcialong {
        \\        owner = "b1_x";
        \\    }
        \\    hero bt {
        \\    }
        \\}
        \\
    ;
    const logic =
        \\    component sejf_are for area {
        \\        fn OnStart() {
        \\            item::New("01pch_g1", "items::grenade");
        \\            item::NewWeapon("01pch_g2", "weapons::grenade");
        \\            object::Impulse("09_SEJF");
        \\            sound::Play(~s"09_sejf");
        \\            scene::Start(~e"sejf_are");
        \\            Place(who = @b1_x, other = @bt, q = @"x_la");
        \\            actor::Place("09_sejf", "09_sejf", 0);
        \\            actor::WalkOnTrack("09_sejf", "09_sejf", 0.0, 5);
        \\        }
        \\    }
        \\
    ;
    const names = try ogObjectNames(a, &.{ objects, logic });
    try std.testing.expectEqual(@as(usize, 6), names.len);
    try std.testing.expectEqualStrings(
        \\battle "b1" {
        \\    area "b2_sejf_are" {
        \\        var string itm_2 = "b2_01pch_g1,b2_01pch_g2";
        \\        areaName = "sejf";
        \\        attach battles::b2::sejf_are();
        \\    }
        \\    active_anim "b2_09_sejf" {
        \\        sprite = "09_sejf";
        \\    }
        \\    fighter "b2_x": characters::garcia {
        \\    }
        \\    weapon "b2_x_la": weapons::garcialong {
        \\        owner = "b2_x";
        \\    }
        \\    hero bt {
        \\    }
        \\}
        \\
    , try ogRenameObjects(a, objects, names, "b1", "b2"));
    try std.testing.expectEqualStrings(
        \\    component sejf_are for area {
        \\        fn OnStart() {
        \\            item::New("b2_01pch_g1", "items::grenade");
        \\            item::NewWeapon("b2_01pch_g2", "weapons::grenade");
        \\            object::Impulse("b2_09_sejf");
        \\            sound::Play(~s"09_sejf");
        \\            scene::Start(~e"sejf_are");
        \\            Place(who = @"b2_x", other = @bt, q = @"b2_x_la");
        \\            actor::Place("b2_09_sejf", "09_sejf", 0);
        \\            actor::WalkOnTrack("b2_09_sejf", "09_sejf", 0.0, 5);
        \\        }
        \\    }
        \\
    , try ogRenameObjects(a, logic, names, "b1", "b2"));
}

test ogLevelBlock {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ true, false }) |battle| {
        const l = try blank(a, if (battle) "09__b" else "09_l", battle, blankSize(battle));
        const lev = l.other[l.other.len - 1].data;
        const t = try ogLevelBlock(a, if (battle) "09__b" else "09_l", battle, lev);
        // It parses as OG Script, the camera's fields those of the Classic script.
        var diag: og.script.ogs.parser.Diagnostic = .{};
        const u = try og.script.ogs.parser.parse(a, t, "x.ogs", &diag);
        const e = u.modules[0].entities[0];
        try std.testing.expectEqualStrings(if (battle) "battle" else "level", e.kind);
        try std.testing.expectEqualStrings("camera", e.fields[0].name);
        try std.testing.expect(std.mem.indexOf(u8, t, "perspective = true, near_plane = 0.8") != null);
        if (battle) try std.testing.expect(std.mem.indexOf(u8, t, "placement = [Place(who = @Sullivan, tile = [7, 16]), Place(who = @Trantigne, tile = [9, 16]), Place(who = @Ovitz, tile = [10, 14])];") != null) else try std.testing.expect(std.mem.indexOf(u8, t, "entry = \"capt_start\";\n    actor_scale = ") != null);
    }
}
