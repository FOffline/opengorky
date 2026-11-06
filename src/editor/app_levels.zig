//! The open level and the levels kept in tabs (App methods, app.zig): opening one,
//! parking and unparking, a level loaded for a look, the edit mode left and taken
//! up again with its tool and layers.

const std = @import("std");
const level = @import("level.zig");
const Doc = level.Doc;
const tx = @import("text.zig");
const paint = @import("paint.zig");
const doctabs = @import("doctabs.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const PaintKeep = app_mod.PaintKeep;
const Parked = app_mod.Parked;

/// The open level closed (its tab closed): nothing shown in the centre.
pub fn closeLevel(self: *App) void {
    _ = self.endPaint();
    if (self.doc) |d| d.deinit();
    self.doc = null;
    self.current = null;
    self.dropLevelSelection();
}

/// What is picked on the open level gone: the object, its menu, the box and trigger
/// windows (their names point into its Doc), a move under way. The one reset of all of
/// them, whenever the Doc closes or another one opens.
pub fn dropLevelSelection(self: *App) void {
    self.selected = null;
    self.enemy_of = null;
    self.menu = null;
    self.box = null;
    self.trigger = null;
    self.moving = null;
}

/// Levels whose folder is gone (a made level undone) out of the list; the open one
/// among them closed.
pub fn dropMissingLevels(self: *App) void {
    var kept: usize = 0;
    var buf: [160]u8 = undefined;
    const cur = if (self.current) |i| self.levels[i].name else null;
    var reopen: ?usize = null;
    for (self.levels) |lv| {
        const p = std.fmt.bufPrint(&buf, "{s}/other.dat", .{lv.name}) catch continue;
        // OpenGorky: a level of the project's own (made in the editor) is its folder of src/.
        const own = if (self.store.root) |r| level.ownLevel(self.io, r, lv.name, lv.battle) else false;
        if (own or (if (self.dat.access(self.io, p, .{})) |_| true else |_| false)) {
            if (cur != null and std.mem.eql(u8, cur.?, lv.name)) reopen = kept;
            self.levels[kept] = lv;
            kept += 1;
        } else {
            self.setStatus(tx.st_level_unmade, .{lv.name});
            if (cur != null and std.mem.eql(u8, cur.?, lv.name)) {
                _ = self.endPaint();
                if (self.doc) |d| d.deinit();
                self.doc = null;
                self.dropLevelSelection();
            }
            self.clearParked();
            // shortcut: the entry's name string is left (templates may still point into it).
        }
    }
    if (kept == self.levels.len) return;
    // A copy of the kept ones: the list is freed whole (App.deinit), never a part of it.
    const less = self.gpa.dupe(level.LevelEntry, self.levels[0..kept]) catch return;
    self.gpa.free(self.levels);
    self.levels = less;
    self.current = reopen;
}

/// The levels kept in tabs: their docs closed (the archives changed), each read
/// again when its tab is shown.
pub fn dropParked(self: *App) void {
    for (self.parked.items) |*pk| if (pk.doc) |d| {
        d.deinit();
        pk.doc = null;
    };
}

/// Every kept level forgotten (level indices changed).
pub fn clearParked(self: *App) void {
    self.dropParked();
    self.paint_left.clearRetainingCapacity();
    self.parked.clearRetainingCapacity();
}

/// The open level kept in its tab; nothing open after.
pub fn park(self: *App) void {
    const i = self.current orelse return;
    // An older copy of it in the tabs goes (its left edit mode stays).
    if (self.unpark(i)) |pk| if (pk.doc) |d| d.deinit();
    self.parked.append(self.gpa, .{ .doc = self.doc, .current = i }) catch {
        if (self.doc) |d| d.deinit();
    };
    self.doc = null;
    self.current = null;
}

/// Level `i` kept in a tab: taken out (its doc, null if not kept or dropped).
pub fn unpark(self: *App, i: usize) ?Parked {
    for (self.parked.items, 0..) |pk, k| if (pk.current == i) return self.parked.orderedRemove(k);
    return null;
}

/// Level `name` loaded for a look (the scene page's map): the open one, a kept one,
/// or read now and kept (as a tab's).
pub fn levelDoc(self: *App, name: []const u8) ?*Doc {
    const i = self.levelIndex(name) orelse return null;
    if (self.current == i) return self.doc;
    for (self.parked.items) |*pk| if (pk.current == i) {
        if (pk.doc == null) pk.doc = Doc.load(&self.store, self.r, self.levels[i].name) catch return null;
        return pk.doc;
    };
    const d = Doc.load(&self.store, self.r, self.levels[i].name) catch return null;
    self.dropLooks();
    self.parked.append(self.gpa, .{ .doc = d, .current = i }) catch {
        d.deinit();
        return null;
    };
    return d;
}

/// Levels loaded only for a look (no tab of theirs): the oldest goes past two, so
/// browsing scenes does not keep every level loaded.
pub fn dropLooks(self: *App) void {
    var looks: usize = 0;
    for (self.parked.items) |pk| looks += @intFromBool(!doctabs.hasLevel(self, pk.current));
    if (looks < 2) return;
    for (self.parked.items, 0..) |pk, k| if (!doctabs.hasLevel(self, pk.current)) {
        if (pk.doc) |d| d.deinit();
        _ = self.parked.orderedRemove(k);
        return;
    };
}

/// Level `i` no longer kept (its tab closed).
pub fn forgetLevel(self: *App, i: usize) void {
    if (self.unpark(i)) |pk| if (pk.doc) |d| d.deinit();
    _ = self.paint_left.remove(i);
}

/// Every loaded level: the open one and those kept in tabs.
pub fn eachDoc(self: *App, buf: []*Doc) []*Doc {
    var n: usize = 0;
    if (self.doc) |d| {
        buf[n] = d;
        n += 1;
    }
    for (self.parked.items) |pk| if (pk.doc) |d| if (n < buf.len) {
        buf[n] = d;
        n += 1;
    };
    return buf[0..n];
}

/// Kept level `k` open again as it was (read again if its doc was dropped: open()).
pub fn unparkInto(self: *App, k: usize) void {
    const pk = self.parked.orderedRemove(k);
    self.doc = pk.doc;
    self.current = pk.current;
}

pub fn open(self: *App, i: usize, keep_view: bool) void {
    // A level opened (not read again after an edit): the one left keeps its edit mode.
    if (!keep_view) self.leavePaint();
    const painted = self.endPaint();
    var view: ?struct { origin: [2]f32, zoom: f32 } = null;
    // Another level: the open one stays in its tab (read again with what the mode changed).
    if (self.current != null and self.current.? != i) {
        if (painted) if (self.doc) |d| {
            d.deinit();
            self.doc = Doc.load(&self.store, self.r, self.levels[self.current.?].name) catch null;
        };
        self.park();
    }
    if (self.doc) |d| {
        if (keep_view) view = .{ .origin = d.origin, .zoom = d.zoom };
        d.deinit();
    }
    self.doc = null;
    const kept = self.unpark(i);
    self.dropLevelSelection();
    self.stopEditing();
    self.current = i;
    const name = self.levels[i].name;
    if (kept) |pk| if (pk.doc) |d| if (keep_view) d.deinit() else {
        self.doc = d;
    };
    if (self.doc == null) self.doc = Doc.load(&self.store, self.r, name) catch |err| {
        self.setStatus(tx.st_open_failed, .{ name, err });
        return;
    };
    const d = self.doc.?;
    if (view) |v| {
        d.origin = v.origin;
        d.zoom = v.zoom;
        d.fitted = true;
    }
    if (!keep_view) self.backToPaint();
    var editable: usize = 0;
    for (d.objects.items) |o| editable += @intFromBool(o.call != null);
    if (d.isBattle()) {
        self.setStatus(tx.st_battle, .{ name, d.objects.items.len, editable });
    } else self.setStatus(tx.st_location, .{ name, @as(u32, @intFromFloat(d.bg_size[0])), @as(u32, @intFromFloat(d.bg_size[1])), d.objects.items.len });
}

/// The open level read again from the Store, the edit mode open again over it.
pub fn reloadLevel(self: *App) void {
    // The mode opens again with its tool, layer and shown layers.
    const keep = self.paintKeep();
    _ = self.endPaint();
    if (self.current) |i| self.open(i, true);
    if (keep) |k| self.paintAgain(k);
}

pub fn paintKeep(self: *const App) ?PaintKeep {
    const p = self.paint orelse return null;
    return .{ .tool = p.tool, .layer = p.layer, .show = p.show, .locked = p.locked, .show_objects = p.show_objects, .scene = p.scene };
}

pub fn paintAgain(self: *App, k: PaintKeep) void {
    self.openPaint();
    const p = self.paint orelse return;
    p.tool = k.tool;
    if (paint.hasLayer(p, k.layer)) p.layer = k.layer;
    p.show = k.show;
    p.locked = k.locked;
    p.show_objects = k.show_objects;
    p.scene = k.scene;
}

/// The open level left in the edit mode: remembered to come back in it.
pub fn leavePaint(self: *App) void {
    const i = self.current orelse return;
    const k = self.paintKeep() orelse return;
    self.paint_left.put(self.gpa, i, k) catch {};
}

/// The open level shown again: its edit mode back if it was left in it.
pub fn backToPaint(self: *App) void {
    const i = self.current orelse return;
    if (self.paint != null or self.doc == null) return;
    if (self.paint_left.fetchRemove(i)) |kv| self.paintAgain(kv.value);
}

/// The level edit mode over the open location.
pub fn openPaint(self: *App) void {
    const d = self.doc orelse return;
    const p = paint.open(self, d) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
    self.paint = p;
    if (self.sceneName()) |n| p.scene.set(n);
    self.selected = null;
    self.moving = null;
}

/// Leaves the edit mode; the map is drawn again from the changed files.
pub fn closePaint(self: *App) void {
    if (self.endPaint()) if (self.current) |i| self.open(i, true);
}

/// The mode's changed layers into the Store (Save writes them); true if any.
pub fn endPaint(self: *App) bool {
    const p = self.paint orelse return false;
    self.paint = null;
    defer p.destroy(self.gpa);
    const changed = p.undo.items.len > 0;
    paint.commit(self, p) catch |err| self.setStatus(tx.st_paint_failed, .{err});
    return changed;
}
