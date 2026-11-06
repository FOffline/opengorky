//! The inspector: an entity's fields drawn from the model (model.zig), one
//! row each — the value in force (its own value bold, an inherited one dim), its layer
//! ("from the archetype", "overridden" with × back to the layer under it, "start (.var)"),
//! "OpenGorky only" for the port's fields (locked in a Classic project), a picker where
//! the caller gives one. Typing a value writes it through `model.set`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const search = @import("search.zig");
const textedit = @import("textedit.zig");
const picker = @import("picker.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const font_mod = @import("font.zig");
const schema = @import("opengorky").core.schema;

const Opts = struct {
    /// Where a value the file lacks goes (model.set).
    after: ?[]const u8 = null,
    /// Drawn when no layer sets it ("—" or the schema default).
    show_missing: bool = true,
    /// A choice field showing this instead of a number box: `row` is true while its list is
    /// open (the caller draws it).
    choice: ?[]const u8 = null,
    /// The row's end: × back to the layer under an own value (the slot kept when none).
    reset: bool = false,
};

/// Field `names[0]` of entity `file` (`names` written together: hp and max_hp) labelled
/// `label`, row `k`. True while its choice list is open.
pub fn row(app: *App, a: Allocator, k: u32, label: []const u8, file: usize, names: []const []const u8, o: Opts) bool {
    const v = model.field(app, file, names[0]);
    if (v.value == null and !v.own and !o.show_missing) return false;
    // The port's own fields: none in a Classic project.
    if (v.only_og and !app.ogLayout()) return false;
    var open = false;
    gui.fieldRow(label);
    if (o.choice) |c| open = picker.field(app, clay.idi("insp_pick", k), c, false) else numberBox(app, a, k, file, names, o.after, v);
    // A choice keeps the row's room for its long label ("1 · medium: …"): its layer
    // goes under it.
    if (o.choice == null) layerChip(v);
    if (o.reset) {
        if (o.choice == null) gui.spacer();
        const over = v.own and v.below_layer != .schema;
        if (gui.trail(app, if (over) clay.idi("insp_reset", k) else null)) model.unset(app, file, names) catch |err| app.failed(err);
    }
    clay.close();
    if (o.choice != null) if (layerOf(v)) |m| gui.fieldNote(tx.get(m), if (v.own) theme.accent_hover else theme.dim);
    return open;
}

/// Its layer, where it tells something: an override (of the archetype, the `.var`), an
/// inherited value, a starting one.
fn layerChip(v: model.View) void {
    if (layerOf(v)) |x| gui.chipOf(tx.get(x), if (v.own) theme.accent_hover else theme.dim, theme.button_edge);
}

fn layerOf(v: model.View) ?tx.Msg {
    return if (v.own and v.below_layer != .schema) tx.in_override else switch (v.layer) {
        .archetype => if (v.own) null else tx.in_archetype,
        .vars => tx.in_vars,
        .schema, .instance => null,
    };
}

/// A number box: shows the value, a click types a new one (written at Enter or a click
/// away, textedit `value`).
fn numberBox(app: *App, a: Allocator, k: u32, file: usize, names: []const []const u8, after: ?[]const u8, v: model.View) void {
    const vid = clay.idi("val", k);
    const typing = textedit.typedIn(app, vid);
    gui.fieldBox(vid, typing != null, clay.fixed(lay.width.number), clay.fixed(lay.height.small));
    const n = model.num(v.value);
    // Typing starts from the value shown (left as it was, nothing is written).
    if (clay.hovered() and app.clicked and typing == null) textedit.begin(app, .{ .id = vid, .field = .begin(if (n != null) app_mod.fmtNum(a, n) else "", search.keep.number), .value = .{ .file = file, .names = names, .after = after } });
    if (typing) |e| @import("fields.zig").typedText(a, e.field, gui.txt) else gui.txt(app_mod.fmtNum(a, n), .body, if (v.own) theme.text else theme.dim, if (v.own and v.below_layer != .schema) font_mod.bold else font_mod.regular);
    clay.close();
}

/// Rows of `names` (each written alone, labelled by `label`), from row `k0`: by the
/// schema host that declares them, most derived first (a weapon's, then an item's, an
/// object's: a head over each after the first), the class's own variables last.
pub fn fields(app: *App, a: Allocator, k0: u32, file: usize, names: []const []const u8, label: *const fn ([]const u8) []const u8, o: Opts) void {
    const done = a.alloc(bool, names.len) catch return;
    @memset(done, false);
    var k = k0;
    var at = model.hostOf(app, file);
    var first = true;
    while (true) : (first = false) {
        var head = !first;
        for (names, done) |n, *d| {
            if (d.* or (at != null and !declares(at.?, n))) continue;
            d.* = true;
            // No head over the port's own fields alone in a Classic project.
            if (!app.ogLayout() and model.field(app, file, n).only_og) continue;
            if (head) gui.subhead(if (at) |h| hostLabel(h.name) else tx.get(tx.host_own));
            head = false;
            _ = row(app, a, k, label(n), file, a.dupe([]const u8, &.{n}) catch continue, o);
            k += 1;
        }
        const h = at orelse break;
        at = if (h.parent) |p| schema.host(p) else null;
    }
}

fn declares(h: *const schema.Host, name: []const u8) bool {
    for (h.fields) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return true;
    return false;
}

fn hostLabel(name: []const u8) []const u8 {
    const labels = .{
        .{ "fighter", tx.host_fighter }, .{ "actor", tx.host_actor }, .{ "weapon", tx.host_weapon },
        .{ "item", tx.host_item },       .{ "level", tx.host_level }, .{ "gameobject", tx.host_object },
    };
    inline for (labels) |l| if (std.mem.eql(u8, name, l[0])) return tx.get(l[1]);
    return name;
}
