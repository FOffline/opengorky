//! Drawing the code window's text (codeview.zig): highlighted lines, gutter,
//! squiggles under problems, the sideways scroll bar.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const render = @import("render.zig");
const font_mod = @import("font.zig");
const code = @import("code.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const View = code.View;
const codeview = @import("codeview.zig");
const codetips = @import("codetips.zig");
const codecomplete = @import("codecomplete.zig");

const findFrom = codeview.findFrom;
const gutter = codeview.gutter;
const line_h = codeview.line_h;
const offsetAt = codeview.offsetAt;
const overText = codeview.overText;
const pt = codeview.pt;
const bracketPair = codetips.bracketPair;
const drawHint = codetips.drawHint;
const hoverTip = codetips.hoverTip;
const linkAt = codetips.linkAt;
const drawPopup = codecomplete.drawPopup;
const next = codecomplete.next;

/// Width of `s` drawn: a tab as four spaces (the font has no tab glyph).
pub fn width(app: *App, s: []const u8) f32 {
    var w: f32 = 0;
    var it = std.mem.splitScalar(u8, s, '\t');
    var first = true;
    while (it.next()) |part| {
        if (!first) w += app.font.measure("    ", font_mod.regular, pt)[0];
        first = false;
        w += app.font.measure(part, font_mod.regular, pt)[0];
    }
    return w;
}

/// Draws `s` at x, tabs as spaces; returns the x after it.
fn drawText(app: *App, s: []const u8, x: f32, y: f32, col: [4]u8) f32 {
    var cx = x;
    var it = std.mem.splitScalar(u8, s, '\t');
    var first = true;
    while (it.next()) |part| {
        if (!first) cx += app.font.measure("    ", font_mod.regular, pt)[0];
        first = false;
        app.font.draw(app.r, part, font_mod.regular, pt, cx, y, col);
        cx += app.font.measure(part, font_mod.regular, pt)[0];
    }
    return cx;
}

fn kindColor(k: code.Kind) [4]u8 {
    return switch (k) {
        .plain => lay.canvas.code.plain,
        .keyword => lay.canvas.code.keyword,
        .call => lay.canvas.code.call,
        .string => lay.canvas.code.string,
        .number => lay.canvas.code.number,
        .comment => lay.canvas.code.comment,
        .directive => lay.canvas.code.directive,
        .path => lay.canvas.code.path,
        .field => lay.canvas.code.field,
    };
}

/// `text[start..end]` as a code excerpt on a page: each non-empty line with its line
/// number in `text`, highlighted as in the window, tabs as four spaces.
pub fn excerpt(a: Allocator, text: []const u8, start: usize, end: usize) void {
    // The indent all its lines share is left out.
    var indent: usize = std.math.maxInt(usize);
    var it = std.mem.splitScalar(u8, text[start..end], '\n');
    while (it.next()) |raw| if (std.mem.trim(u8, raw, " \t\r").len > 0) {
        indent = @min(indent, raw.len - std.mem.trimStart(u8, raw, " \t").len);
    };
    var n = std.mem.count(u8, text[0..start], "\n") + 1;
    var lines = std.mem.splitScalar(u8, text[start..end], '\n');
    while (lines.next()) |raw| : (n += 1) {
        const full = std.mem.trimEnd(u8, raw, " \t\r");
        if (full.len == 0) continue;
        const l = full[indent..];
        clay.open(.{ .layout = .{} });
        // The line number's column: four digits.
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(5 * lay.unit) } } });
        gui.txt(std.fmt.allocPrint(a, "{d}", .{n}) catch "", .body, render.clayColor(lay.canvas.code.line_no), font_mod.regular);
        clay.close();
        for (code.highlight(a, l, false) catch &.{}) |sp| {
            gui.txt(std.mem.replaceOwned(u8, a, l[sp.start..sp.end], "\t", "    ") catch "", .body, render.clayColor(kindColor(sp.kind)), font_mod.regular);
        }
        clay.close();
    }
}

pub fn visibleLines(v: *const View) usize {
    return @intFromFloat(@max(1, @floor((textH(v) - 8) / line_h)));
}

/// The text's height: the view's, less the horizontal bar's strip (it never covers a line).
fn textH(v: *const View) f32 {
    return v.rect.h - if (hbar(v) != null) clay.bar_thick + 6 else 0;
}

/// Text, cursor, selection and the completion list into `rect`; long lines scroll
/// sideways under the fixed line numbers, a bar below shows where.
pub fn draw(app: *App, v: *View, rect: c.SDL_FRect) void {
    v.rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    const r = app.r;
    const f = app.font;
    const t = v.buf.str();
    const ogs = codecomplete.isOgs(app, v);
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    _ = c.SDL_SetRenderClipRect(r, &clip);
    defer _ = c.SDL_SetRenderClipRect(r, null);
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    measureWide(app, v);
    // The lines' clip ends above the horizontal bar; the text's own is right of the line
    // numbers too (the cursor at column 0 shows).
    const th = textH(v);
    const lclip: c.SDL_Rect = .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = @intFromFloat(th) };
    const tclip: c.SDL_Rect = .{ .x = clip.x + @as(c_int, @intFromFloat(gutter)) - 3, .y = clip.y, .w = clip.w - @as(c_int, @intFromFloat(gutter)) + 3, .h = lclip.h };
    if (v.follow_x) {
        v.follow_x = false;
        const cx = width(app, t[code.lineStart(t, v.buf.cursor)..v.buf.cursor]);
        const margin: f32 = 40;
        if (cx < v.hscroll + margin) v.hscroll = cx - margin;
        if (cx > v.hscroll + textW(v) - margin) v.hscroll = cx - textW(v) + margin;
    }
    clampH(v);
    const sel = v.buf.selection();
    const q = if (v.find_open) v.findText() else "";
    const pair = bracketPair(t, v.buf.cursor);
    // The token under the pointer with Cmd/Ctrl held: underlined when it leads somewhere.
    const link: ?code.Token = if ((c.SDL_GetModState() & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0 and overText(v, app.mouse)) linkAt(app, v, offsetAt(app, v, app.mouse)) else null;
    var ls: usize = 0;
    var n: usize = 0;
    while (n < v.scroll and ls < t.len) : (n += 1) ls = next(t, ls);
    var cursor_xy: ?[2]f32 = null;
    var y = rect.y + 4;
    const x0 = rect.x + gutter - v.hscroll;
    while (ls <= t.len and y < rect.y + th) : (n += 1) {
        const le = code.lineEnd(t, ls);
        const line = t[ls..le];
        _ = c.SDL_SetRenderClipRect(r, &lclip);
        f.draw(r, std.fmt.allocPrint(a, "{d}", .{n + 1}) catch "", font_mod.regular, lay.Type.body.pt(), rect.x + 8, y + 2, lay.canvas.code.line_no);
        if (v.err_line == n + 1) {
            render.ink(r, lay.canvas.code.err_line);
            _ = c.SDL_RenderFillRect(r, &.{ .x = rect.x, .y = y, .w = rect.w, .h = line_h });
        }
        for (v.unknown[0..v.unknown_n]) |*u| if (u.line == n + 1) {
            render.ink(r, lay.canvas.code.unknown);
            _ = c.SDL_RenderFillRect(r, &.{ .x = rect.x, .y = y, .w = rect.w, .h = line_h });
            break;
        };
        _ = c.SDL_SetRenderClipRect(r, &tclip);
        if (sel) |s| if (s[0] <= le and s[1] >= ls) {
            const a0 = @max(s[0], ls);
            const a1 = @min(s[1], le);
            const sx = x0 + width(app, t[ls..a0]);
            const sw = width(app, t[a0..a1]) + if (s[1] > le) @as(f32, 6) else 0;
            render.ink(r, lay.canvas.alpha(lay.canvas.code.accent, 110));
            _ = c.SDL_RenderFillRect(r, &.{ .x = sx, .y = y, .w = sw, .h = line_h });
        };
        // Find matches on the line; the bracket at the cursor and its pair.
        if (q.len > 0) {
            var i: usize = 0;
            while (findFrom(line, q, i)) |k| : (i = k + q.len) {
                render.ink(r, lay.canvas.code.match);
                _ = c.SDL_RenderFillRect(r, &.{ .x = x0 + width(app, line[0..k]), .y = y, .w = width(app, line[k .. k + q.len]), .h = line_h });
            }
        }
        if (pair) |pp| for (pp) |bi| if (bi >= ls and bi < le) {
            render.ink(r, lay.canvas.code.bracket);
            _ = c.SDL_RenderRect(r, &.{ .x = x0 + width(app, t[ls..bi]), .y = y + 1, .w = width(app, t[bi .. bi + 1]), .h = line_h - 2 });
        };
        var x = x0;
        for (code.highlight(a, line, ogs) catch &.{}) |sp| {
            x = drawText(app, line[sp.start..sp.end], x, y, kindColor(sp.kind));
        }
        // Problems under their names (a wavy line); the link under the pointer.
        for (v.unknown[0..v.unknown_n]) |*u| if (u.line == n + 1) if (nameIn(line, u.name[0..u.len], u.kind == .missing or u.quoted)) |k| {
            squiggle(r, x0 + width(app, line[0..k]), width(app, line[k .. k + u.len]), y + line_h - 3);
        };
        if (link) |lk| if (lk.start >= ls and lk.end <= le) {
            render.ink(r, lay.canvas.code.link);
            _ = c.SDL_RenderFillRect(r, &.{ .x = x0 + width(app, t[ls..lk.start]), .y = y + line_h - 2, .w = width(app, t[lk.start..lk.end]), .h = 1 });
        };
        if (v.buf.cursor >= ls and v.buf.cursor <= le) cursor_xy = .{ x0 + width(app, t[ls..v.buf.cursor]), y };
        y += line_h;
        if (le >= t.len) break;
        ls = next(t, le);
    }
    _ = c.SDL_SetRenderClipRect(r, &clip);
    const rad = clay.bar_thick / 2;
    const cr: ui.Clay_CornerRadius = .{ .topLeft = rad, .topRight = rad, .bottomLeft = rad, .bottomRight = rad };
    if (hbar(v)) |b| {
        render.fillRounded(r, b.track, cr, render.clayColor(lay.canvas.bar_track));
        render.fillRounded(r, b.thumb, cr, render.clayColor(if (v.hbar != null) lay.canvas.bar_held else lay.canvas.bar_thumb));
    }
    if (vbar(v)) |b| {
        render.fillRounded(r, b.track, cr, render.clayColor(lay.canvas.bar_track));
        render.fillRounded(r, b.thumb, cr, render.clayColor(if (v.vbar != null) lay.canvas.bar_held else lay.canvas.bar_thumb));
    }
    if (cursor_xy) |cxy| if (cxy[0] >= rect.x + gutter - 3) {
        // A blinking bar.
        if ((c.SDL_GetTicks() / 500) % 2 == 0 or v.popup) {
            render.ink(r, lay.canvas.code.cursor);
            _ = c.SDL_RenderFillRect(r, &.{ .x = cxy[0], .y = cxy[1] + 2, .w = 2, .h = line_h - 4 });
        }
        if (v.popup) drawPopup(app, v, a, .{ cxy[0], cxy[1] + line_h }) else if (v.menu == null) drawHint(app, v, a, cxy, rect);
    };
    if (!v.popup and v.menu == null) hoverTip(app, v, a);
}

/// The text's left edge's width shown (right of the line numbers).
pub fn textW(v: *const View) f32 {
    return @max(1, v.rect.w - gutter - 12);
}

/// The widest line, measured again after an edit.
fn measureWide(app: *App, v: *View) void {
    if (v.wide_ver == v.buf.version) return;
    v.wide_ver = v.buf.version;
    var w: f32 = 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, v.buf.str(), '\n');
    while (it.next()) |l| : (n += 1) w = @max(w, width(app, std.mem.trimEnd(u8, l, "\r")));
    v.wide = w;
    v.lines = n;
}

/// Points scrolled past the widest line (it never ends under the bar or the edge).
pub const h_margin: f32 = 48;

pub fn clampH(v: *View) void {
    v.hscroll = std.math.clamp(v.hscroll, 0, @max(0, v.wide + h_margin - textW(v)));
}

/// The horizontal bar (as clay's scroll bars): its track along the text's bottom and the
/// thumb; null when every line fits.
pub fn hbar(v: *const View) ?struct { track: c.SDL_FRect, thumb: c.SDL_FRect } {
    const vw = textW(v);
    const content = v.wide + h_margin;
    if (content <= vw + 1) return null;
    // Short of the vertical bar's column when it shows (the corner stays free; counted with
    // this bar's strip, visibleLines would ask hbar again).
    const right: f32 = if (@as(f32, @floatFromInt(v.lines)) * line_h > v.rect.h - clay.bar_thick - 14) clay.bar_thick + 6 else 4;
    const track: c.SDL_FRect = .{ .x = v.rect.x + gutter, .y = v.rect.y + v.rect.h - clay.bar_thick - 2, .w = v.rect.w - gutter - right, .h = clay.bar_thick };
    const len = @min(track.w, @max(clay.bar_min, track.w * vw / content));
    const at = track.x + std.math.clamp(v.hscroll / (content - vw), 0, 1) * (track.w - len);
    return .{ .track = track, .thumb = .{ .x = at, .y = track.y, .w = len, .h = track.h } };
}

/// The first line shown when scrolled to the end: the last line a third of the view
/// above its bottom edge (0: every line fits).
pub fn maxScroll(v: *const View) usize {
    const vis = visibleLines(v);
    return if (v.lines <= vis) 0 else v.lines + vis / 3 - vis;
}

/// The vertical bar (as hbar): along the text's right edge, above the horizontal bar's
/// strip; null when every line fits.
pub fn vbar(v: *const View) ?struct { track: c.SDL_FRect, thumb: c.SDL_FRect } {
    const vis = visibleLines(v);
    if (v.lines <= vis) return null;
    const track: c.SDL_FRect = .{ .x = v.rect.x + v.rect.w - clay.bar_thick - 2, .y = v.rect.y + 2, .w = clay.bar_thick, .h = textH(v) - 4 };
    const total: f32 = @floatFromInt(maxScroll(v) + vis);
    const len = @min(track.h, @max(clay.bar_min, track.h * @as(f32, @floatFromInt(vis)) / total));
    const frac = std.math.clamp(@as(f32, @floatFromInt(v.scroll)) / @as(f32, @floatFromInt(maxScroll(v))), 0, 1);
    return .{ .track = track, .thumb = .{ .x = track.x, .y = track.y + frac * (track.h - len), .w = track.w, .h = len } };
}

/// Offset of `name` on `line` as a whole word (`quoted`: inside quotes).
fn nameIn(line: []const u8, name: []const u8, quoted: bool) ?usize {
    if (name.len == 0) return null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, name)) |i| {
        pos = i + name.len;
        if (quoted) {
            if (i > 0 and line[i - 1] == '"') return i;
            continue;
        }
        if (i > 0 and code.isIdent(line[i - 1])) continue;
        if (pos < line.len and code.isIdent(line[pos])) continue;
        return i;
    }
    return null;
}

/// A wavy line from `x`, `w` long, along `y`.
fn squiggle(r: *c.SDL_Renderer, x: f32, w: f32, y: f32) void {
    render.ink(r, lay.canvas.code.squiggle);
    var px = x;
    var up = false;
    while (px < x + w) : (px += 3) {
        _ = c.SDL_RenderLine(r, px, y + if (up) @as(f32, 0) else 2, px + 3, y + if (up) @as(f32, 2) else 0);
        up = !up;
    }
}
