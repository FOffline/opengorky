//! The one field typed into — a text field (names, descriptions, lines; Cyrillic too),
//! a number field or stepper, a script value: a click types into it (all of it selected),
//! Enter (Tab) or a click elsewhere gives the text, Esc drops it. One at a time; its text
//! lives in the App (`text_edit`) while typed, then (`text_given`) until its field takes
//! it at the next layout; a script value is written at once (its row may be gone).
//! A search or a new level's name types straight into its App buffer (`live`: a list
//! filters as it is typed). Also where the App's typing goes (`typed`).

const ui = @import("ui");
const clay = @import("clay.zig");
const app_mod = @import("app.zig");
const model = @import("model.zig");
const App = app_mod.App;
const search = @import("search.zig");
const std = @import("std");
const c = @import("sdl");

pub const Edit = struct {
    /// The field typed into (its box: a click outside it gives the text).
    id: ui.Clay_ElementId,
    field: search.Field(1024) = .{},
    /// Laid out this frame (else it was left: dropped).
    seen: bool = false,
    /// Given by Enter (not by a click away).
    entered: bool = false,
    /// A script value's (valueField) variable: `names` of `file`, a missing one after the
    /// line holding `after`.
    value: ?struct { file: usize, names: []const []const u8, after: ?[]const u8 } = null,
    /// The buffer following each change (`live`); Esc puts back what it held.
    live: ?Live = null,

    pub fn text(self: *const Edit) []const u8 {
        return self.field.text();
    }
};

pub const Live = struct { buf: []u8, len: *usize };

/// An App.Name as a field's `live` buffer.
pub fn live(name: anytype) Live {
    return .{ .buf = &name.buf, .len = &name.len };
}

/// Field `id` typed into from `value`, at its end (a search, a name: nothing selected),
/// each byte as `filter` takes it (search.keep); `to`: the buffer following it.
pub fn focusEnd(app: *App, id: ui.Clay_ElementId, value: []const u8, filter: *const fn (u8, usize) ?u8, to: ?Live) void {
    var f: search.Field(1024) = .begin(value, filter);
    f.all = false;
    begin(app, .{ .id = id, .field = f, .live = to });
}

/// Field `key` is the one typed into (not marking it laid out).
pub fn typingIn(app: *const App, key: []const u8) bool {
    return if (app.text_edit) |e| e.id.id == clay.id(key).id else false;
}

/// The field's text into its `live` buffer (cut to its room, never inside a letter).
fn changed(e: *Edit) void {
    const l = e.live orelse return;
    e.field.fit(l.buf.len);
    @memcpy(l.buf[0..e.field.len], e.field.text());
    l.len.* = e.field.len;
}

/// Field `key` typed into now (as clicked), starting from `value`.
pub fn focus(app: *App, key: []const u8, value: []const u8) void {
    begin(app, .{ .id = clay.id(key), .field = .begin(value, search.keep.any) });
}

/// Typing `e` begun (the one typed into before given first).
pub fn begin(app: *App, e: Edit) void {
    if (app.text_edit) |old| if (old.id.id != e.id.id) give(app, false);
    app.text_edit = e;
    app.text_edit.?.seen = true;
}

/// Field `id` typed into (it is laid out: kept).
pub fn typedIn(app: *App, id: ui.Clay_ElementId) ?*Edit {
    const e = &(app.text_edit orelse return null);
    if (e.id.id != id.id) return null;
    e.seen = true;
    return e;
}

/// Field `id`'s typing given (Enter, a click away): taken, once.
pub fn taken(app: *App, id: ui.Clay_ElementId) ?Edit {
    const g = app.text_given orelse return null;
    if (g.id.id != id.id) return null;
    app.text_given = null;
    return g;
}

/// A number field's given text as a finite number; null: left as it was or not a number.
pub fn number(e: Edit) ?f32 {
    const x = std.fmt.parseFloat(f32, e.field.give() orelse return null) catch return null;
    return if (std.math.isFinite(x)) std.math.clamp(x, -1e5, 1e5) else null;
}

/// Before a layout: a click outside the field typed into gives its text.
pub fn clickAway(app: *App) void {
    const e = &(app.text_edit orelse return);
    if (app.clicked and !clay.pointerOver(e.id)) return give(app, false);
    e.seen = false;
}

/// Enter: the typed text given to its field (at its next layout).
pub fn enter(app: *App) void {
    give(app, true);
}

fn give(app: *App, entered: bool) void {
    const e = app.text_edit orelse return;
    app.text_edit = null;
    if (e.value) |val| {
        const v = e.field.give() orelse return;
        _ = std.fmt.parseFloat(f32, v) catch return;
        model.set(app, val.file, val.names, v, val.after) catch |err| app.failed(err);
        return;
    }
    app.text_given = e;
    app.text_given.?.entered = entered;
}

/// Key `k` while a field is typed into; false: not the field's (a shortcut).
pub fn keyDown(app: *App, k: c.SDL_Keycode, mod: c.SDL_Keymod) bool {
    const e = &(app.text_edit orelse return false);
    const cmd = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
    switch (k) {
        c.SDLK_BACKSPACE => {
            e.field.backspace();
            changed(e);
        },
        c.SDLK_DELETE => {
            e.field.delete();
            changed(e);
        },
        // Cmd+←/→ (macOS): to the line's ends.
        c.SDLK_LEFT => e.field.move(if (cmd) .home else .left),
        c.SDLK_RIGHT => e.field.move(if (cmd) .end else .right),
        c.SDLK_HOME => e.field.move(.home),
        c.SDLK_END => e.field.move(.end),
        c.SDLK_A => if (cmd) e.field.selectAll() else return true,
        c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_TAB => enter(app),
        c.SDLK_ESCAPE => {
            if (e.live != null) {
                e.field.buf = e.field.orig;
                e.field.len = e.field.orig_len;
                e.field.caret = e.field.len;
                changed(e);
            }
            app.text_edit = null;
        },
        c.SDLK_V => if (cmd) {
            const p = c.SDL_GetClipboardText() orelse return true;
            defer c.SDL_free(p);
            e.field.add(std.mem.span(p));
            changed(e);
        } else return true,
        // Plain keys are letters, not shortcuts.
        else => return !cmd,
    }
    return true;
}

/// After a layout: a field no longer shown drops its typing (and an unclaimed text).
pub fn afterLayout(app: *App) void {
    if (app.text_edit) |e| if (!e.seen) {
        app.text_edit = null;
    };
}

pub fn typed(app: *App, s: []const u8) void {
    const e = &(app.text_edit orelse return);
    e.field.add(s);
    changed(e);
}

/// A script value typed into: dropped (another level opened).
pub fn stopEditing(self: *App) void {
    if (self.text_edit) |e| if (e.value != null) {
        self.text_edit = null;
    };
}

/// Text input on while something takes typing; a newly opened window starts an
/// empty search.
pub fn syncTextInput(self: *App) void {
    if (self.overlay() and !self.overlay_was) self.query_name.len = 0;
    self.overlay_was = self.overlay();
    const want = self.text_edit != null or self.overlay();
    if (want == self.text_input) return;
    self.text_input = want;
    _ = if (want) c.SDL_StartTextInput(self.window) else c.SDL_StopTextInput(self.window);
}

/// A script value typed into: written now (before a save, a discard, a return).
pub fn commitEditing(self: *App) void {
    if (self.text_edit) |e| if (e.value != null) give(self, false);
}
