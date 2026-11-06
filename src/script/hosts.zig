//! The data block kinds' fields as the language declares them: `foundation/hosts.ogs`, `host
//! fighter : actor { int hp = 0 "Hit points now"; }` — each field's
//! type, default and text (English), for the editor (a field's hover, the
//! completion in a block) and the reference (`fillDoc`). The engine's schema
//! (core/schema.zig) agrees with it: its test checks every field both ways.

const std = @import("std");
const ir = @import("ir.zig");
const parser = @import("ogs/parser.zig");
const lexer = @import("ogs/lexer.zig");

pub const file = "foundation/hosts.ogs";
pub const text = @embedFile("foundation_hosts");

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var cache: ?[]const *const ir.Struct = null;

/// Every `host` declaration, parsed once.
pub fn all() []const *const ir.Struct {
    if (cache) |c| return c;
    const a = arena_state.allocator();
    var diag: parser.Diagnostic = .{};
    const u = parser.parse(a, text, file, &diag) catch {
        std.log.warn("{s}:{d}: {s}", .{ file, diag.line, diag.message });
        cache = &.{};
        return cache.?;
    };
    var out: std.ArrayList(*const ir.Struct) = .empty;
    for (u.modules) |m| for (m.structs) |s| if (s.host) out.append(a, s) catch {};
    cache = out.items;
    return cache.?;
}

/// Host `name`'s declaration; null: none.
pub fn host(name: []const u8) ?*const ir.Struct {
    for (all()) |h| if (std.mem.eql(u8, h.name, name)) return h;
    return null;
}

/// Field `name` of host `host_name` or its parents': the declaring host and the field.
pub fn field(host_name: []const u8, name: []const u8) ?struct { host: *const ir.Struct, field: *const ir.Field } {
    var at = host(host_name);
    var depth: u32 = 0;
    while (at) |h| : (depth += 1) {
        if (depth > 16) return null;
        for (h.fields) |*f| if (std.mem.eql(u8, f.name, name)) return .{ .host = h, .field = f };
        at = if (h.parent.len > 0) host(h.parent) else null;
    }
    return null;
}

/// Field `f` as declared: `float accuracy = 0.0`.
pub fn decl(a: std.mem.Allocator, f: *const ir.Field) []const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    w.writer.print("{s} {s}", .{ f.type_name, f.name }) catch return f.name;
    if (f.default) |d| {
        w.writer.writeAll(" = ") catch {};
        @import("ogs/print.zig").expression(&w.writer, d) catch {};
    }
    return w.written();
}

const doc_begin = "<!-- hosts-doc -->\n";
const doc_end = "<!-- /hosts-doc -->";

/// `md` with its block between `<!-- hosts-doc -->` and `<!-- /hosts-doc -->` made again:
/// every host's fields as a table (the English texts), the block kinds on each from
/// `kinds` (`fighter`: fighter, hero); no block: as it is.
pub fn fillDoc(a: std.mem.Allocator, md: []const u8, kinds: *const fn ([]const u8, *[8][]const u8) []const []const u8) ![]u8 {
    const b = std.mem.indexOf(u8, md, doc_begin) orelse return a.dupe(u8, md);
    const e = std.mem.indexOfPos(u8, md, b, doc_end) orelse return error.NoEndMarker;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(md[0 .. b + doc_begin.len]);
    for (all()) |h| {
        var kb: [8][]const u8 = undefined;
        const ks = kinds(h.name, &kb);
        try w.print("\n**`host {s}`**", .{h.name});
        if (h.parent.len > 0) try w.print(" — over `{s}`", .{h.parent});
        if (ks.len > 0) {
            try w.writeAll(", blocks:");
            for (ks, 0..) |k, i| try w.print("{s} `{s}`", .{ if (i > 0) "," else "", k });
        }
        try w.writeAll("\n\n| Field | Type | What it means |\n|---|---|---|\n");
        for (h.fields) |f| {
            try w.print("| `{s}` | `{s}` | ", .{ f.name, f.type_name });
            for (f.doc) |ch| try if (ch == '|') w.writeAll("\\|") else if (ch == '\n') w.writeByte(' ') else w.writeByte(ch);
            try w.writeAll(" |\n");
        }
    }
    try w.writeAll("\n");
    try w.writeAll(md[e..]);
    return out.toOwnedSlice();
}

test "hosts: foundation/hosts.ogs reads, every field its type and both texts" {
    try std.testing.expect(all().len > 0);
    for (all()) |h| {
        if (h.parent.len > 0) try std.testing.expect(host(h.parent) != null);
        for (h.fields) |f| {
            try std.testing.expect(f.type_name.len > 0 and f.default != null);
            try std.testing.expect(f.doc.len > 0);
        }
    }
    try std.testing.expectEqualStrings("actor", field("fighter", "mesh").?.host.name);
}

fn noKinds(_: []const u8, b: *[8][]const u8) []const []const u8 {
    return b[0..0];
}

test "hosts: the reference's block is made again between its markers" {
    const a = std.testing.allocator;
    const md = try fillDoc(a, "x\n<!-- hosts-doc -->\nSTALE_BODY\n<!-- /hosts-doc -->\ny\n", noKinds);
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "**`host fighter`** — over `actor`") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "STALE_BODY") == null);
    const again = try fillDoc(a, md, noKinds);
    defer a.free(again);
    try std.testing.expectEqualStrings(md, again);
}
