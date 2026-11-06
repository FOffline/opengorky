//! Launcher window: shown before the game when it starts without arguments (a double
//! click, the macOS app, `opengorky` on Linux without a path), with `launcher = 1`,
//! Shift held, or no usable game folder. Picks the game folder and edits opengorky.cfg in
//! four tabs. Play saves the settings and the game opens its own window; Exit (Esc,
//! closing the window) quits without saving. Layout by the editor's Clay kit.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl");
const ui = @import("ui");
const og = @import("opengorky");
const kit = @import("kit");
const config = @import("config.zig");
const startup = @import("startup.zig");
const packages = @import("packages.zig");
const gfx = @import("../media/gfx.zig");
const clay = kit.clay;
const Io = std.Io;
const Scaling = config.Scaling;

pub const Tab = enum { play, display, game, advanced };
pub const Result = enum { play, exit };

const Fonts = kit.font.Fonts(&.{
    .{ .ttf = @embedFile("font_regular"), .sizes = &.{ 12, 13, 14 } },
    .{ .ttf = @embedFile("font_bold"), .sizes = &.{ 11, 12, 14, 16 } },
    .{ .ttf = @embedFile("font_heading"), .sizes = &.{ 16, 32, 42 } },
}, 1280);
const regular = 0;
const bold = 1;
/// Oswald Bold: titles and tabs.
const heading = 2;

/// The concept's minimal revision (its HTML prototype's last style block).
const theme = struct {
    const background = clay.rgb(0x11120f);
    const main = clay.rgb(0x141511);
    const surface = clay.rgb(0x1b1c18);
    const tile = clay.rgb(0x161713);
    const raised = clay.rgb(0x25251f);
    const border = clay.rgb(0x45443a);
    const border_subtle = clay.rgb(0x33352d);
    const field_border = clay.rgb(0x3d3e33);
    const divider = clay.rgb(0x34362e);
    const text = clay.rgb(0xeae5d8);
    const label = clay.rgb(0xc9c4b8);
    const text_secondary = clay.rgb(0xa39e90);
    const muted = clay.rgb(0x8e8c80);
    const faint = clay.rgb(0x707267);
    const nav = clay.rgb(0xb8b3a7);
    const accent = clay.rgb(0xf18a1b);
    const accent_hover = clay.rgb(0xffa33b);
    const accent_pressed = clay.rgb(0xd87816);
    const accent_line = clay.rgb(0xb9661c);
    const accent_ink = clay.rgb(0x211509);
    const accent_tint: clay.Color = .{ .r = 0xf1, .g = 0x8a, .b = 0x1b, .a = 0x16 };
    const success = clay.rgb(0xa5d38b);
    const err = clay.rgb(0xe37b68);
    const disabled = clay.rgb(0x2c2a24);
    const clear: clay.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

/// Icons (assets/launcher/icons, scripts/launcher-icons.swift): white, tinted when drawn.
const Icon = enum { home, display, game, advanced, check, warning, play, close };

const Folder = enum { unset, missing, no_dat, ok };

/// The native folder dialog's answer; its callback may run on another thread (SDL docs)
/// and after the window is gone, so it lives here.
const Pick = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    done: std.atomic.Value(bool) = .init(true),

    fn picked(ud: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const p: *Pick = @ptrCast(@alignCast(ud));
        if (list != null and list[0] != null) {
            const path = std.mem.span(list[0]);
            p.len = @min(path.len, p.buf.len);
            @memcpy(p.buf[0..p.len], path[0..p.len]);
        }
        p.done.store(true, .release);
    }
};
var pick: Pick = .{};

const Launcher = struct {
    io: Io,
    gpa: std.mem.Allocator,
    r: *c.SDL_Renderer,
    window: *c.SDL_Window,
    fonts: *Fonts,
    cfg: config.Config,
    cfg_path: []const u8,
    tab: Tab,
    size: [2]f32 = .{ 0, 0 },
    mouse: [2]f32 = .{ -1, -1 },
    down: bool = false,
    clicked: bool = false,
    result: ?Result = null,
    picking: bool = false,
    icons: [std.enums.values(Icon).len]?*c.SDL_Texture = @splat(null),
    badge: ?*c.SDL_Texture = null,
    metal: ?*c.SDL_Texture = null,
    folder: Folder = .unset,
    /// The settings' folder (its `mods/` holds packages too).
    cfg_dir: ?[]const u8 = null,
    /// The packages of the `mods/` folders (`pkg_arena`'s), found with the game folder.
    pkgs: []const packages.Package = &.{},
    /// Each package's line under its title (made with the list).
    pkg_descs: []const []const u8 = &.{},
    pkg_arena: std.heap.ArenaAllocator = undefined,
    lang: u8 = 0,
    avi: bool = false,
    /// Texts made per frame (clay keeps pointers until the frame is drawn).
    path_buf: [2][1100]u8 = undefined,
    detail_buf: [200]u8 = undefined,
    fps_buf: [2][200]u8 = undefined,

    /// Looks at the game folder: set, there, with `dat` (and `avi`), its language.
    fn check(self: *Launcher) void {
        const path = self.cfg.gamePath();
        _ = self.pkg_arena.reset(.retain_capacity);
        const pa = self.pkg_arena.allocator();
        self.pkgs = packages.find(self.io, pa, path, self.cfg_dir);
        const descs: [][]const u8 = pa.alloc([]const u8, self.pkgs.len) catch &.{};
        for (descs, self.pkgs) |*d, p| d.* = if (p.supported) std.fmt.allocPrint(pa, "OpenGorky package · mods/{s}", .{p.file}) catch p.file else "Made for a newer OpenGorky: update it to play this package.";
        self.pkg_descs = descs;
        self.folder = .unset;
        if (path.len == 0) return;
        var d = Io.Dir.cwd().openDir(self.io, path, .{}) catch {
            self.folder = .missing;
            return;
        };
        defer d.close(self.io);
        var dat = d.openDir(self.io, "dat", .{ .iterate = true }) catch {
            self.folder = .no_dat;
            return;
        };
        defer dat.close(self.io);
        self.lang = og.formats.lang.language(self.io, self.gpa, dat);
        self.avi = if (d.openDir(self.io, "avi", .{})) |a| blk: {
            var avi = a;
            avi.close(self.io);
            break :blk true;
        } else |_| false;
        self.folder = .ok;
    }

    fn texture(self: *Launcher, png: []const u8, smooth: bool) ?*c.SDL_Texture {
        var img = og.formats.jpeg.decode(self.gpa, png) catch return null;
        defer img.deinit(self.gpa);
        const t = c.SDL_CreateTexture(self.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
        _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureScaleMode(t, if (smooth) c.SDL_SCALEMODE_LINEAR else c.SDL_SCALEMODE_NEAREST);
        return t;
    }

    fn icon(self: *Launcher, ic: Icon, px: f32, color: clay.Color) void {
        const k = @backingInt(ic);
        if (self.icons[k] == null) self.icons[k] = self.texture(switch (ic) {
            inline else => |t| @embedFile("launcher_" ++ @tagName(t)),
        }, true);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(px), .height = clay.fixed(px) } }, .image = .{ .imageData = self.icons[k] }, .backgroundColor = color, .userData = &kit.render.tinted });
    }

    /// The package chosen (none: the original game, or the chosen one not found).
    fn chosen(self: *const Launcher) ?packages.Package {
        const file = self.cfg.package.get();
        if (file.len == 0) return null;
        for (self.pkgs) |p| if (std.ascii.eqlIgnoreCase(p.file, file)) return p;
        return null;
    }

    /// Play can start: the game folder found and the choice playable.
    fn playable(self: *const Launcher) bool {
        if (self.folder != .ok) return false;
        return if (self.chosen()) |p| p.supported else true;
    }

    fn deinit(self: *Launcher) void {
        self.pkg_arena.deinit();
        for (self.icons) |t| if (t) |tt| c.SDL_DestroyTexture(tt);
        if (self.badge) |t| c.SDL_DestroyTexture(t);
        if (self.metal) |t| c.SDL_DestroyTexture(t);
    }

    /// Opens the system folder dialog (non-blocking; the answer comes in `pick`).
    fn changeFolder(self: *Launcher) void {
        if (self.picking) return;
        var start: [1025]u8 = undefined;
        const cur = self.cfg.gamePath();
        const loc: ?[*:0]const u8 = if (cur.len > 0 and cur.len < start.len) blk: {
            @memcpy(start[0..cur.len], cur);
            start[cur.len] = 0;
            break :blk start[0..cur.len :0];
        } else null;
        pick.len = 0;
        pick.done.store(false, .release);
        self.picking = true;
        c.SDL_ShowOpenFolderDialog(Pick.picked, &pick, self.window, loc, false);
    }

    fn pollPick(self: *Launcher) void {
        if (!self.picking or !pick.done.load(.acquire)) return;
        self.picking = false;
        if (pick.len == 0) return;
        self.cfg.setGamePath(pick.buf[0..pick.len]);
        self.check();
    }
};

/// Shift held right now (at startup: show the launcher with `launcher = 0`).
/// shortcut: Linux has no query without a window (X11/Wayland), so only macOS and Windows.
pub fn shiftHeld() bool {
    switch (builtin.os.tag) {
        .windows => return GetAsyncKeyState(0x10) < 0, // VK_SHIFT
        .macos => {
            // CoreGraphics is loaded with SDL; looked up so the build needs no framework.
            const f = std.c.dlsym(@ptrFromInt(std.math.maxInt(usize) - 1), "CGEventSourceFlagsState") orelse return false; // RTLD_DEFAULT
            const flags: *const fn (c_int) callconv(.c) u64 = @ptrCast(@alignCast(f));
            return flags(1) & 0x20000 != 0; // combined session state, kCGEventFlagMaskShift
        },
        else => return false,
    }
}
extern "user32" fn GetAsyncKeyState(key: c_int) callconv(.winapi) c_short;

pub const Start = struct {
    tab: Tab = .play,
    /// A game folder given on the command line (not saved unless Play).
    folder: ?[]const u8 = null,
    /// `--launcher-shot`: draw the window hidden into this PNG and quit.
    shot: ?[]const u8 = null,
};

/// Runs the launcher on `cfg`; on Play `cfg` holds the new settings, saved to `cfg_path`.
pub fn run(io: Io, gpa: std.mem.Allocator, cfg: *config.Config, cfg_dir: ?[]const u8, cfg_path: ?[]const u8, start: Start) !Result {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (start.shot != null) c.SDL_WINDOW_HIDDEN else 0);
    if (!c.SDL_CreateWindowAndRenderer("OpenGorky", 900, 650, flags, &window, &renderer)) return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetWindowMinimumSize(window, 800, 600);
    startup.setWindowIcon(gpa, window.?);
    const r = renderer.?;
    _ = c.SDL_SetRenderDrawBlendMode(r, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderVSync(r, 1);
    const density = @max(1, c.SDL_GetWindowPixelDensity(window));
    _ = c.SDL_SetRenderScale(r, density, density);
    const fonts = try Fonts.init(gpa, r, density);
    defer fonts.deinit(gpa);
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &w, &h);
    try clay.init(gpa, fonts, @floatFromInt(w), @floatFromInt(h));
    defer clay.deinit(gpa);

    var l: Launcher = .{ .io = io, .gpa = gpa, .r = r, .window = window.?, .fonts = fonts, .cfg = cfg.*, .cfg_path = cfg_path orelse "opengorky.cfg", .tab = start.tab, .cfg_dir = cfg_dir, .pkg_arena = .init(gpa) };
    defer l.deinit();
    if (start.folder) |f| l.cfg.setGamePath(f);
    l.badge = l.texture(@embedFile("icon_png"), true);
    l.metal = l.texture(@embedFile("launcher_metal"), true);
    l.check();

    if (start.shot) |path| {
        // Hover and boxes need a previous frame's layout.
        for (0..3) |_| present(&l, .{ @floatFromInt(w), @floatFromInt(h) }, 0);
        try writeShot(&l, path);
        return .exit;
    }
    while (l.result == null) {
        l.clicked = false;
        var wheel: f32 = 0;
        var ev: c.SDL_Event = undefined;
        // Idle: wait for input instead of drawing at the display rate.
        if (c.SDL_WaitEventTimeout(&ev, 100)) {
            var more = true;
            while (more) : (more = c.SDL_PollEvent(&ev)) switch (ev.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => l.result = .exit,
                c.SDL_EVENT_MOUSE_MOTION => l.mouse = .{ ev.motion.x, ev.motion.y },
                c.SDL_EVENT_WINDOW_MOUSE_LEAVE => l.mouse = .{ -1, -1 },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT) {
                    l.down = true;
                    l.clicked = true;
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => if (ev.button.button == c.SDL_BUTTON_LEFT) {
                    l.down = false;
                },
                c.SDL_EVENT_MOUSE_WHEEL => wheel += ev.wheel.y,
                c.SDL_EVENT_KEY_DOWN => switch (ev.key.key) {
                    c.SDLK_ESCAPE => l.result = .exit,
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => if (l.playable()) {
                        l.result = .play;
                    },
                    // Up / Down: the previous / next tab.
                    c.SDLK_UP => l.tab = @fromBackingInt(@backingInt(l.tab) -% 1),
                    c.SDLK_DOWN => l.tab = @fromBackingInt(@backingInt(l.tab) +% 1),
                    else => {},
                },
                c.SDL_EVENT_WINDOW_RESIZED => _ = c.SDL_GetWindowSize(window, &w, &h),
                else => {},
            };
        }
        l.pollPick();
        present(&l, .{ @floatFromInt(w), @floatFromInt(h) }, wheel);
        _ = c.SDL_RenderPresent(r);
    }
    if (l.result.? == .exit) return .exit;
    cfg.* = l.cfg;
    if (cfg_dir != null and cfg_path != null) cfg.save(io, cfg_dir.?, cfg_path.?);
    return .play;
}

fn present(l: *Launcher, size: [2]f32, wheel: f32) void {
    l.size = size;
    clay.begin(.{ .size = size, .mouse = l.mouse, .down = l.down, .wheel = .{ 0, wheel * 30 }, .dt = 1.0 / 60.0 });
    layout(l);
    const cmds = clay.end();
    _ = c.SDL_SetRenderDrawColor(l.r, 0x10, 0x11, 0x0f, 255);
    _ = c.SDL_RenderClear(l.r);
    kit.render.draw(l.r, l.fonts, cmds, paint, l);
}

fn writeShot(l: *Launcher, path: []const u8) !void {
    const surf = gfx.readFrame(l.r) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(surf);
    var img = try og.image.Image.init(l.gpa, @intCast(surf.*.w), @intCast(surf.*.h));
    defer img.deinit(l.gpa);
    const src: [*]const u8 = @ptrCast(surf.*.pixels.?);
    const stride = img.width * 4;
    for (0..img.height) |y| @memcpy(img.pixels[y * stride ..][0..stride], src[y * @as(usize, @intCast(surf.*.pitch)) ..][0..stride]);
    var out: Io.Writer.Allocating = .init(l.gpa);
    defer out.deinit();
    try og.formats.png.write(l.gpa, &out.writer, img);
    try Io.Dir.cwd().writeFile(l.io, .{ .sub_path = path, .data = out.written() });
}

// ---- Layout ----

const center: ui.Clay_ChildAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER };
const middle: ui.Clay_ChildAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER };

fn txt(s: []const u8, pt: u16, col: clay.Color, font_id: u16) void {
    clay.text(s, .{ .textColor = col, .fontSize = pt, .fontId = font_id, .wrapMode = ui.CLAY_TEXT_WRAP_NONE });
}

/// Text wrapped at words to its parent's width.
fn para(s: []const u8, pt: u16, col: clay.Color) void {
    clay.text(s, .{ .textColor = col, .fontSize = pt, .fontId = regular, .lineHeight = pt + 5 });
}

fn edges(w: u16) ui.Clay_BorderWidth {
    return .{ .left = w, .right = w, .top = w, .bottom = w };
}

fn pad(x: u16, y: u16) ui.Clay_Padding {
    return .{ .left = x, .right = x, .top = y, .bottom = y };
}

fn spacer() void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
}

fn divider() void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(1) } }, .backgroundColor = theme.divider });
}

/// `customData` of CUSTOM elements: the metal texture, or a scaling preview.
const metal_paint = 1;
fn previewPaint(mode: Scaling, selected: bool) ?*anyopaque {
    return @ptrFromInt(2 + @as(usize, @backingInt(mode)) * 2 + @intFromBool(selected));
}

fn layout(l: *Launcher) void {
    clay.open(.{ .id = clay.id("root"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .backgroundColor = theme.main });
    sidebar(l);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    clay.openScroll(.{ .id = clay.id("content"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 32, .right = 32, .top = 28 }, .childGap = 14 } });
    switch (l.tab) {
        .play => playTab(l),
        .display => displayTab(l),
        .game => gameTab(l),
        .advanced => advancedTab(l),
    }
    clay.close();
    footer(l);
    clay.close();
    clay.close();
}

const build_version = @import("version").version;

fn sidebar(l: *Launcher) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(185), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 24, .left = 8, .right = 8 }, .childGap = 4 }, .custom = .{ .customData = @ptrFromInt(metal_paint) }, .border = .{ .color = clay.rgb(0x30312a), .width = .{ .right = 1 } } });
    const items = [_]struct { tab: Tab, icon: Icon, label: []const u8 }{
        .{ .tab = .play, .icon = .home, .label = "PLAY" },
        .{ .tab = .display, .icon = .display, .label = "DISPLAY" },
        .{ .tab = .game, .icon = .game, .label = "GAME" },
        .{ .tab = .advanced, .icon = .advanced, .label = "ADVANCED" },
    };
    for (items, 0..) |it, k| {
        const eid = clay.idi("nav", @intCast(k));
        const sel = l.tab == it.tab;
        const over = clay.pointerOver(eid);
        if (over and l.clicked) l.tab = it.tab;
        const col = if (sel) theme.accent else if (over) theme.text else theme.nav;
        clay.open(.{
            .id = eid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(50) }, .padding = .{ .left = 16 }, .childGap = 13, .childAlignment = middle },
            .backgroundColor = if (sel) theme.accent_tint else if (over) .{ .r = 255, .g = 255, .b = 255, .a = 8 } else theme.clear,
            .cornerRadius = clay.radius(4),
            .border = if (sel) .{ .color = clay.rgb(0x8b5c2d), .width = edges(1) } else .{},
        });
        // The selected tab's accent edge, over its frame.
        if (sel) clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(3), .height = clay.fixed(50) } }, .backgroundColor = theme.accent, .cornerRadius = .{ .topLeft = 4, .bottomLeft = 4 }, .floating = .{ .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
        l.icon(it.icon, 20, if (sel) theme.accent else if (over) theme.text else clay.rgb(0x9a978d));
        txt(it.label, 16, col, heading);
        clay.close();
    }
    spacer();
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 16, .bottom = 25 }, .childGap = 5 } });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(38), .height = clay.fixed(2) } }, .backgroundColor = clay.rgb(0xa96a2b) });
    clay.leaf(.{ .layout = .{ .sizing = .{ .height = clay.fixed(5) } } });
    txt("INDEPENDENT", 11, theme.faint, bold);
    txt("OPEN SOURCE", 11, theme.faint, bold);
    txt("COMMUNITY DRIVEN", 11, theme.faint, bold);
    clay.close();
    clay.close();
}

/// The Play button (on every tab; off without a game folder) and Exit beside it.
fn footer(l: *Launcher) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 32, .right = 32, .top = 16, .bottom = 24 }, .childGap = 10 } });
    const ok = l.playable();
    const pid = clay.id("play");
    const over = ok and clay.pointerOver(pid);
    if (over and l.clicked) l.result = .play;
    clay.open(.{
        .id = pid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(52) }, .childGap = 12, .childAlignment = center },
        .backgroundColor = if (!ok) theme.disabled else if (over and l.down) theme.accent_pressed else if (over) theme.accent_hover else clay.rgb(0xef891f),
        .cornerRadius = clay.radius(5),
    });
    const ink = if (ok) theme.accent_ink else theme.muted;
    l.icon(.play, 18, ink);
    txt("PLAY", 16, ink, bold);
    clay.close();
    const xid = clay.id("exit");
    const xover = clay.pointerOver(xid);
    if (xover and l.clicked) l.result = .exit;
    clay.open(.{
        .id = xid,
        .layout = .{ .sizing = .{ .width = clay.fixed(52), .height = clay.fixed(52) }, .childAlignment = center },
        .backgroundColor = if (xover) theme.raised else clay.rgb(0x1d1e19),
        .cornerRadius = clay.radius(5),
        .border = .{ .color = if (xover) clay.rgb(0x8a7960) else clay.rgb(0x3e4036), .width = edges(1) },
    });
    l.icon(.close, 20, if (xover) theme.text else theme.label);
    clay.close();
    clay.close();
}

/// A panel; `title` in amber at its top.
fn card(id: []const u8, title: []const u8) void {
    clay.open(.{ .id = clay.id(id), .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = pad(20, 18), .childGap = 12 }, .backgroundColor = theme.surface, .cornerRadius = clay.radius(6), .border = .{ .color = theme.border_subtle, .width = edges(1) } });
    if (title.len > 0) section(title);
}

fn section(s: []const u8) void {
    txt(s, 12, theme.accent, bold);
}

fn hint(s: []const u8) void {
    para(s, 12, theme.muted);
}

/// A tab's title and, at the right, what it holds.
fn pageTitle(title: []const u8, sub: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .bottom = 8 }, .childGap = 16, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } } });
    txt(title, 32, theme.text, heading);
    spacer();
    clay.open(.{ .layout = .{ .padding = .{ .bottom = 8 } } });
    txt(sub, 11, clay.rgb(0x928e80), bold);
    clay.close();
    clay.close();
}

/// A switch: the knob right and amber when on.
fn switchLeaf(on: bool, enabled: bool) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(46), .height = clay.fixed(25) } }, .backgroundColor = if (!enabled) theme.disabled else if (on) theme.accent else clay.rgb(0x4d4c43), .cornerRadius = clay.radius(12.5), .border = .{ .color = if (on and enabled) theme.accent else clay.rgb(0x676457), .width = edges(1) } });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(19), .height = clay.fixed(19) } }, .backgroundColor = if (!enabled) theme.muted else if (on) clay.rgb(0x20170e) else clay.rgb(0xbab5a6), .cornerRadius = clay.radius(9.5), .floating = .{ .offset = .{ .x = if (on) 24 else 3, .y = 3 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
    clay.close();
}

/// A checkbox, amber with a tick when on.
fn checkLeaf(l: *Launcher, on: bool) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(16), .height = clay.fixed(16) }, .childAlignment = center }, .backgroundColor = if (on) theme.accent else theme.background, .cornerRadius = clay.radius(3), .border = .{ .color = if (on) theme.accent else clay.rgb(0x5a594d), .width = edges(1) } });
    if (on) l.icon(.check, 12, theme.accent_ink);
    clay.close();
}

/// A setting's title and explanation, growing to push its control right.
fn rowText(title: []const u8, desc: []const u8, enabled: bool) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 3 } });
    txt(title, 14, if (enabled) theme.text else theme.muted, bold);
    if (desc.len > 0) para(desc, 12, if (enabled) theme.text_secondary else theme.muted);
    clay.close();
}

/// A setting with a switch; the whole row toggles `v`.
fn toggleRow(l: *Launcher, id: []const u8, title: []const u8, desc: []const u8, v: *bool) void {
    const eid = clay.id(id);
    const over = clay.pointerOver(eid);
    if (over and l.clicked) v.* = !v.*;
    clay.open(.{ .id = eid, .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = pad(0, 6), .childGap = 12, .childAlignment = middle } });
    rowText(title, desc, true);
    switchLeaf(v.*, true);
    clay.close();
}

/// A checkbox and its label (the whole line toggles `v`), `desc` under it.
fn checkLine(l: *Launcher, id: []const u8, label: []const u8, desc: []const u8, v: *bool) void {
    const eid = clay.id(id);
    const over = clay.pointerOver(eid);
    if (over and l.clicked) v.* = !v.*;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 4 } });
    clay.open(.{ .id = eid, .layout = .{ .childGap = 9, .childAlignment = middle } });
    checkLeaf(l, v.*);
    txt(label, 14, if (over) theme.text else theme.label, regular);
    clay.close();
    if (desc.len > 0) {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 25 } } });
        hint(desc);
        clay.close();
    }
    clay.close();
}

/// A setting with a choice of `labels` (`sel` highlighted, none for a value not among
/// them); returns the one clicked.
fn choiceRow(l: *Launcher, id: []const u8, title: []const u8, desc: []const u8, labels: []const []const u8, sel: ?usize, enabled: bool) ?usize {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 16, .childAlignment = middle } });
    rowText(title, desc, enabled);
    var hit: ?usize = null;
    clay.open(.{ .layout = .{ .padding = pad(3, 3), .childGap = 3 }, .backgroundColor = theme.background, .cornerRadius = clay.radius(5), .border = .{ .color = clay.rgb(0x424238), .width = edges(1) } });
    for (labels, 0..) |s, k| {
        const eid = clay.idi(id, @intCast(k));
        const on = sel == k;
        const over = enabled and !on and clay.pointerOver(eid);
        if (over and l.clicked) hit = k;
        clay.open(.{ .id = eid, .layout = .{ .sizing = .{ .height = clay.fixed(28) }, .padding = .{ .left = 11, .right = 11 }, .childAlignment = center }, .backgroundColor = if (on) (if (enabled) theme.accent else theme.disabled) else if (over) theme.raised else theme.clear, .cornerRadius = clay.radius(3) });
        txt(s, 13, if (!enabled) theme.muted else if (on) theme.accent_ink else if (over) theme.text else clay.rgb(0xaaa598), if (on) bold else regular);
        clay.close();
    }
    clay.close();
    clay.close();
    return hit;
}

fn edition(n: u8) ?[]const u8 {
    // Language number (string.tab line 950, formats/strtab.zig); 5 is the Russian edition.
    return switch (n) {
        0, 1 => "English",
        2 => "Polish",
        3 => "German",
        4 => "French",
        5 => "Russian",
        6 => "Dutch",
        7 => "Spanish",
        8 => "Italian",
        9 => "Hungarian",
        else => null,
    };
}

/// `path` cut from the left with "…" (into `buf`) to fit `max` points.
fn fitPath(l: *Launcher, buf: []u8, path: []const u8, max: f32) []const u8 {
    if (max <= 0 or l.fonts.measure(path, regular, 14)[0] <= max) return path;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] & 0xc0 == 0x80) continue; // not mid-letter
        const out = std.fmt.bufPrint(buf, "…{s}", .{path[i..]}) catch return path;
        if (l.fonts.measure(out, regular, 14)[0] <= max) return out;
    }
    return path;
}

/// A path in a field: cut to its width, the whole of it under the pointer; `empty` when none.
fn pathField(l: *Launcher, id: []const u8, buf: []u8, path: []const u8, empty: []const u8) void {
    const fid = clay.id(id);
    const shown = fitPath(l, buf, path, if (clay.box(fid)) |b| b.width - 24 else 0);
    clay.open(.{ .id = fid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(39) }, .padding = .{ .left = 12, .right = 12 }, .childAlignment = middle }, .backgroundColor = theme.background, .cornerRadius = clay.radius(4), .border = .{ .color = theme.field_border, .width = edges(1) }, .clip = .{ .horizontal = true } });
    if (path.len > 0) txt(shown, 14, clay.rgb(0xcfc8b9), regular) else txt(empty, 14, clay.rgb(0x74756c), regular);
    if (shown.ptr != path.ptr and clay.pointerOver(fid)) {
        clay.open(.{ .layout = .{ .padding = pad(10, 6) }, .backgroundColor = theme.raised, .cornerRadius = clay.radius(4), .border = .{ .color = theme.border, .width = edges(1) }, .floating = .{ .offset = .{ .x = 0, .y = 4 }, .zIndex = 10, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_LEFT_TOP, .parent = ui.CLAY_ATTACH_POINT_LEFT_BOTTOM }, .pointerCaptureMode = ui.CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH } });
        txt(path, 13, theme.text, regular);
        clay.close();
    }
    clay.close();
}

fn playTab(l: *Launcher) void {
    // Badge and name.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 23, .childAlignment = middle, .padding = .{ .bottom = 8 } } });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(124), .height = clay.fixed(124) } }, .image = .{ .imageData = l.badge } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 8 } });
    txt("OPENGORKY", 42, theme.text, heading);
    txt("INDEPENDENT PROJECT  ·  GORKY 17", 12, theme.text_secondary, bold);
    txt("OPEN-SOURCE ENGINE FOR THE ORIGINAL GAME", 12, theme.text_secondary, bold);
    clay.close();
    clay.close();

    // Game folder: path, Change, what was found.
    card("folder_card", "");
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childAlignment = middle } });
    section("GAME FOLDER");
    spacer();
    const cid = clay.id("change");
    const cover = !l.picking and clay.pointerOver(cid);
    if (cover and l.clicked) l.changeFolder();
    clay.open(.{ .id = cid, .layout = .{ .sizing = .{ .height = clay.fixed(32) }, .padding = .{ .left = 14, .right = 14 }, .childAlignment = center }, .backgroundColor = if (cover) .{ .r = 0xf1, .g = 0x8a, .b = 0x1b, .a = 0x20 } else theme.clear, .cornerRadius = clay.radius(4), .border = .{ .color = if (l.picking) theme.border else theme.accent_line, .width = edges(1) } });
    txt(if (l.picking) "Choosing…" else "Change", 14, if (l.picking) theme.muted else if (cover) theme.accent_hover else theme.accent, regular);
    clay.close();
    clay.close();

    pathField(l, "path", &l.path_buf[0], l.cfg.gamePath(), "No folder chosen");

    const ok = l.folder == .ok;
    const status: [2][]const u8 = switch (l.folder) {
        .ok => .{ "Game folder found", if (edition(l.lang)) |e|
            (if (l.avi) std.fmt.bufPrint(&l.detail_buf, "{s} edition. All required folders are present.", .{e}) else std.fmt.bufPrint(&l.detail_buf, "{s} edition. No avi folder: videos and some music will not play.", .{e})) catch ""
        else if (l.avi) "All required folders are present." else "No avi folder: videos and some music will not play." },
        .unset => .{ "Game folder not set", "Choose the Gorky 17 folder (with dat and avi) to play." },
        .missing => .{ "Folder not found", "It may have been moved or deleted. Choose the Gorky 17 folder again." },
        .no_dat => .{ "Not a Gorky 17 folder", "It has no dat folder. Choose the folder with dat and avi." },
    };
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 10, .childAlignment = middle } });
    const tone = if (ok) theme.success else theme.err;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(26), .height = clay.fixed(26) }, .childAlignment = center }, .backgroundColor = tone, .cornerRadius = clay.radius(13) });
    l.icon(if (ok) .check else .warning, 16, clay.rgb(0x142011));
    clay.close();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 1 } });
    txt(status[0], 14, tone, bold);
    para(status[1], 12, theme.text_secondary);
    clay.close();
    clay.close();
    clay.close();

    gameCard(l);

    // Ready state and version.
    card("ready_card", "");
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 16, .childAlignment = middle } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 8 } });
    if (ok) section("READY TO PLAY") else txt("GAME FOLDER NEEDED", 12, theme.err, bold);
    para(if (ok) "Press Play or Enter to start the game; Esc closes this window." else "Play is available once the game folder is found.", 13, theme.text_secondary);
    clay.close();
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 2 } });
    txt("VERSION", 12, theme.text_secondary, regular);
    txt(build_version, 14, theme.text, bold);
    clay.close();
    clay.close();
    clay.close();

    checkLine(l, "launcher", "Show launcher at startup", "Off: the game starts at once. Hold Shift while starting it to see this window.", &l.cfg.launcher);
}

const modes = std.enums.values(Scaling);

/// What Play starts: the original game or one of the packages found (app/packages.zig); a
/// click picks it (kept in the settings' `package`).
fn gameCard(l: *Launcher) void {
    card("game_card", "GAME");
    const sel = l.chosen();
    if (gameRow(l, 0, "Gorky 17", "The original game, as it is.", sel == null, true)) l.cfg.package.set("");
    for (l.pkgs, 1..) |p, k| {
        const desc = if (k - 1 < l.pkg_descs.len) l.pkg_descs[k - 1] else p.file;
        if (gameRow(l, @intCast(k), p.title, desc, sel != null and std.mem.eql(u8, sel.?.file, p.file), p.supported)) l.cfg.package.set(p.file);
    }
    const missing = l.cfg.package.get().len > 0 and sel == null;
    if (missing) para(std.fmt.bufPrint(&l.detail_buf, "{s} is not in a mods folder any more: the original game starts.", .{l.cfg.package.get()}) catch "", 12, theme.err);
    if (l.pkgs.len == 0) hint("Put OpenGorky packages (.ogp) into the mods folder of the game folder or of the settings folder to play them here.");
    clay.close();
}

/// One choice of the game card: a round mark, the title and what it is; true when clicked.
fn gameRow(l: *Launcher, k: u32, title: []const u8, desc: []const u8, on: bool, enabled: bool) bool {
    const eid = clay.idi("game_row", k);
    const over = enabled and clay.pointerOver(eid);
    clay.open(.{ .id = eid, .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = pad(10, 8), .childGap = 12, .childAlignment = middle }, .backgroundColor = if (on) theme.raised else if (over) theme.tile else theme.clear, .cornerRadius = clay.radius(4), .border = .{ .color = if (on) theme.accent_line else theme.clear, .width = edges(1) } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(16), .height = clay.fixed(16) }, .childAlignment = center }, .cornerRadius = clay.radius(8), .border = .{ .color = if (on) theme.accent else clay.rgb(0x5a594d), .width = edges(1) } });
    if (on) clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(8), .height = clay.fixed(8) } }, .backgroundColor = theme.accent, .cornerRadius = clay.radius(4) });
    clay.close();
    rowText(title, desc, enabled);
    clay.close();
    return over and l.clicked and !on;
}

fn modeLabel(m: Scaling) []const u8 {
    return switch (m) {
        .integer => "Integer",
        .sharp => "Sharp",
        .smooth => "Smooth",
        .stretch => "Stretch",
        .adaptive => "Adaptive",
        .@"stretch-blur" => "Stretch-blur",
    };
}

fn modeText(m: Scaling) []const u8 {
    return switch (m) {
        .integer => "Integer zoom of the 640×480 frame: crisp pixels, may leave borders.",
        .sharp => "Fills the window keeping 4:3, sharp pixels.",
        .smooth => "Fills the window keeping 4:3, smoothed.",
        .stretch => "Stretches the frame to the whole window or screen, no borders; 4:3 is distorted on wide screens.",
        .adaptive => "Wide windows show more of large locations at the sides; battles and rooms are zoomed in to fill the width. The interface stays in the middle; the menu and inventory stand over a blurred copy.",
        .@"stretch-blur" => "4:3 in the middle over a blurred, darkened copy of the frame instead of black borders.",
    };
}

fn displayTab(l: *Launcher) void {
    pageTitle("DISPLAY", "IMAGE AND WINDOW");
    card("modes", "IMAGE MODE");
    // Two rows of three.
    for (0..2) |row| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 8 } });
        for (modes[row * 3 ..][0..3], row * 3..) |m, k| {
            const eid = clay.idi("mode", @intCast(k));
            const sel = l.cfg.scaling == m;
            const over = !sel and clay.pointerOver(eid);
            if (over and l.clicked) l.cfg.scaling = m;
            clay.open(.{
                .id = eid,
                .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(76) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 12 }, .childGap = 8, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER } },
                .backgroundColor = if (sel) theme.accent_tint else theme.tile,
                .cornerRadius = clay.radius(5),
                .border = .{ .color = if (sel) theme.accent else if (over) clay.rgb(0x9b845e) else theme.border, .width = edges(1) },
            });
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(48), .height = clay.fixed(27) } }, .custom = .{ .customData = previewPaint(m, sel) } });
            txt(modeLabel(m), 13, if (sel) clay.rgb(0xffffff) else theme.label, if (sel) bold else regular);
            clay.close();
        }
        clay.close();
    }
    hint(modeText(l.cfg.scaling));
    clay.close();

    card("image", "");
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 24 } });
    toggleRow(l, "hires", "Sharp models and effects", "At window resolution. Off: 640×480 like the original.", &l.cfg.hires);
    toggleRow(l, "fullscreen", "Fullscreen", "Start in fullscreen. In the game: F11 or Alt+Enter.", &l.cfg.fullscreen);
    clay.close();
    divider();
    if (choiceRow(l, "upscale", "Interface and portraits", "With sharp models on: smoothed edges or the original pixels, just larger.", &.{ "Smooth (xBR)", "Original pixels" }, @backingInt(l.cfg.upscale), l.cfg.hires)) |k|
        l.cfg.upscale = @fromBackingInt(@as(u1, @intCast(k)));
    clay.close();
}

fn gameTab(l: *Launcher) void {
    pageTitle("GAME", "FRAME RATE AND FOCUS");
    card("fps_card", "FRAME RATE");
    const limits = [_]u32{ 30, 60, 0 };
    const lsel = std.mem.indexOfScalar(u32, &limits, l.cfg.fps_limit);
    const ldesc = if (lsel != null) "Frames per second in the active window. The world always runs at 30 ticks per second, like the original." else std.fmt.bufPrint(&l.fps_buf[0], "Frames per second in the active window; now {d}, set in opengorky.cfg. The world always runs at 30 ticks per second.", .{l.cfg.fps_limit}) catch "";
    if (choiceRow(l, "fps", "Frame rate", ldesc, &.{ "30", "60", "Match display" }, lsel, true)) |k| l.cfg.fps_limit = limits[k];
    divider();
    const backs = [_]u32{ 15, 30, 0 };
    const bsel = std.mem.indexOfScalar(u32, &backs, l.cfg.fps_background);
    const bdesc = if (bsel != null) "When the window is not focused. A minimized or fully covered window is not drawn at all." else std.fmt.bufPrint(&l.fps_buf[1], "When the window is not focused; now {d}, set in opengorky.cfg. A minimized or covered window is not drawn.", .{l.cfg.fps_background}) catch "";
    if (choiceRow(l, "fps_bg", "In background", bdesc, &.{ "15", "30", "Same as active" }, bsel, true)) |k| l.cfg.fps_background = backs[k];
    clay.close();
    card("focus_card", "BEHAVIOUR");
    checkLine(l, "pause_bg", "Pause in background", "The game and sound pause when the window loses focus or is minimized.", &l.cfg.pause_background);
    clay.close();
}

fn advancedTab(l: *Launcher) void {
    pageTitle("ADVANCED", "FOR DEVELOPERS");
    card("debug_card", "DEBUGGING");
    checkLine(l, "debug", "Debug overlays", "Battle status line, health bars, F1 line.", &l.cfg.debug);
    checkLine(l, "console", "Developer console", "In the game ` or F2 opens it: debug commands (heal, win the battle, give items…).", &l.cfg.console);
    divider();
    if (choiceRow(l, "log", "Terminal messages", "What the game prints to the terminal it was started from.", &.{ "None", "Warnings", "Info" }, @backingInt(l.cfg.log), true)) |k|
        l.cfg.log = @fromBackingInt(@as(u2, @intCast(k)));
    clay.close();
    card("cfg_card", "SETTINGS FILE");
    pathField(l, "cfg_path", &l.path_buf[1], l.cfg_path, "");
    hint("Play saves the settings here (the file is rewritten with explanations of every key); Exit leaves it unchanged.");
    clay.close();
}

// ---- Custom drawing ----

fn paint(ctx: *anyopaque, data: ?*anyopaque, box: c.SDL_FRect) void {
    const l: *Launcher = @ptrCast(@alignCast(ctx));
    const k = @intFromPtr(data);
    if (k == metal_paint) return drawMetal(l, box);
    drawPreview(l.r, box, modes[(k - 2) / 2], (k - 2) % 2 == 1);
}

/// The metal texture over the whole window, the part under `box`.
fn drawMetal(l: *Launcher, box: c.SDL_FRect) void {
    const t = l.metal orelse return;
    var tw: f32 = 0;
    var th: f32 = 0;
    _ = c.SDL_GetTextureSize(t, &tw, &th);
    const k = @max(l.size[0] / tw, l.size[1] / th);
    // Dimmer and warmer: the frame stays behind the content.
    _ = c.SDL_SetTextureColorModFloat(t, 0.62, 0.6, 0.55);
    _ = c.SDL_RenderTexture(l.r, t, &.{ .x = box.x / k, .y = box.y / k, .w = box.w / k, .h = box.h / k }, &box);
    // Barely there under the sidebar's flat colour.
    _ = c.SDL_SetRenderDrawColor(l.r, 0x16, 0x18, 0x13, 0xe4);
    _ = c.SDL_RenderFillRect(l.r, &box);
}

fn fcol(hex: u24, a: f32) c.SDL_FColor {
    return .{ .r = @as(f32, @floatFromInt(hex >> 16)) / 255, .g = @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255, .b = @as(f32, @floatFromInt(hex & 0xff)) / 255, .a = a };
}

/// A rectangle shaded from `top` to `bottom`; `bands` > 0: in that many flat steps (pixels).
fn shaded(r: *c.SDL_Renderer, rect: c.SDL_FRect, top: c.SDL_FColor, bottom: c.SDL_FColor, bands: u32) void {
    if (bands > 0) {
        for (0..bands) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bands - 1));
            _ = c.SDL_SetRenderDrawColorFloat(r, top.r + (bottom.r - top.r) * t, top.g + (bottom.g - top.g) * t, top.b + (bottom.b - top.b) * t, top.a);
            const h = rect.h / @as(f32, @floatFromInt(bands));
            _ = c.SDL_RenderFillRect(r, &.{ .x = rect.x, .y = rect.y + h * @as(f32, @floatFromInt(i)), .w = rect.w, .h = h });
        }
        return;
    }
    const v = [4]c.SDL_Vertex{
        .{ .position = .{ .x = rect.x, .y = rect.y }, .color = top },
        .{ .position = .{ .x = rect.x + rect.w, .y = rect.y }, .color = top },
        .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + rect.h }, .color = bottom },
        .{ .position = .{ .x = rect.x, .y = rect.y + rect.h }, .color = bottom },
    };
    const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
    _ = c.SDL_RenderGeometry(r, null, &v, 4, &idx, 6);
}

/// A scaling mode in miniature: the window (`box`) and the 4:3 picture in it — steps for
/// sharp pixels, a gradient for smoothed, the middle frame for the interface.
fn drawPreview(r: *c.SDL_Renderer, box: c.SDL_FRect, mode: Scaling, sel: bool) void {
    _ = c.SDL_SetRenderDrawColor(r, 0x08, 0x08, 0x07, 255);
    _ = c.SDL_RenderFillRect(r, &box);
    const top = if (sel) fcol(0xf3a45a, 1) else fcol(0x9a9486, 1);
    const bottom = if (sel) fcol(0x6e3c10, 1) else fcol(0x3c3a33, 1);
    const fit: c.SDL_FRect = .{ .x = box.x + (box.w - box.h * 4 / 3) / 2, .y = box.y, .w = box.h * 4 / 3, .h = box.h };
    switch (mode) {
        .integer => shaded(r, .{ .x = box.x + (box.w - (box.h - 8) * 4 / 3) / 2, .y = box.y + 4, .w = (box.h - 8) * 4 / 3, .h = box.h - 8 }, top, bottom, 4),
        .sharp => shaded(r, fit, top, bottom, 5),
        .smooth => shaded(r, fit, top, bottom, 0),
        .stretch => shaded(r, box, top, bottom, 0),
        .adaptive => {
            shaded(r, box, top, bottom, 0);
            _ = c.SDL_SetRenderDrawColorFloat(r, 0.93, 0.9, 0.85, 0.9);
            _ = c.SDL_RenderRect(r, &.{ .x = fit.x + 1, .y = fit.y + fit.h - 9, .w = fit.w - 2, .h = 8 });
        },
        .@"stretch-blur" => {
            shaded(r, box, .{ .r = top.r * 0.45, .g = top.g * 0.45, .b = top.b * 0.45, .a = 1 }, .{ .r = bottom.r * 0.45, .g = bottom.g * 0.45, .b = bottom.b * 0.45, .a = 1 }, 0);
            shaded(r, fit, top, bottom, 0);
        },
    }
    const edge = if (sel) theme.accent else theme.border;
    _ = c.SDL_SetRenderDrawColor(r, @intFromFloat(edge.r), @intFromFloat(edge.g), @intFromFloat(edge.b), 255);
    _ = c.SDL_RenderRect(r, &box);
}
