//! The project manifest (`opengorky.mod` in the game folder's root; not in the exe):
//! "key = value" lines, `#` comments, as the editor's and port's settings. It says what
//! the folder is: a Classic game (what the original exe reads, also without a manifest)
//! or an OpenGorky project of OG Script (`format = ogs`; loaders/ogs.zig reads it and
//! its own keys). Nothing is guessed.

const std = @import("std");
const Io = std.Io;

pub const file_name = "opengorky.mod";

/// The data format this engine reads: a manifest asking a newer one is refused.
pub const engine_version: Version = .{ 0, 1 };

/// `ogs`: an OpenGorky project of OG Script texts (`src/`) over the installed game,
/// read by loaders/ogs.zig (its own keys are that reader's).
const Format = enum { classic, ogs };
/// The edition the project is built on (its texts' code page).
const Base = enum { en, ru };
/// "major.minor".
const Version = [2]u16;

pub const Manifest = struct {
    format: Format = .classic,
    /// The oldest engine the project needs.
    engine: Version = engine_version,
    id_buf: [64]u8 = undefined,
    id_len: usize = 0,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    base: Base = .en,

    pub fn id(self: *const Manifest) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn title(self: *const Manifest) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn setId(self: *Manifest, s: []const u8) void {
        self.id_len = @min(s.len, self.id_buf.len);
        @memcpy(self.id_buf[0..self.id_len], s[0..self.id_len]);
    }

    pub fn setTitle(self: *Manifest, s: []const u8) void {
        self.title_len = @min(s.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], s[0..self.title_len]);
    }

    /// This engine can run it.
    pub fn supported(self: *const Manifest) bool {
        return !newer(self.engine, engine_version);
    }

    /// Unknown keys and bad values are ignored.
    pub fn parse(data: []const u8) Manifest {
        var m: Manifest = .{};
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const key = std.mem.trim(u8, t[0..eq], " \t");
            const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "format")) {
                m.format = std.meta.stringToEnum(Format, val) orelse m.format;
            } else if (std.mem.eql(u8, key, "engine")) {
                m.engine = parseVersion(val) orelse m.engine;
            } else if (std.mem.eql(u8, key, "id")) {
                m.setId(val);
            } else if (std.mem.eql(u8, key, "title")) {
                m.setTitle(val);
            } else if (std.mem.eql(u8, key, "base")) {
                m.base = std.meta.stringToEnum(Base, val) orelse m.base;
            }
        }
        return m;
    }

    pub fn write(self: *const Manifest, buf: []u8) ![]const u8 {
        var w: Io.Writer = .fixed(buf);
        try w.print(
            \\# OpenGorky project. classic: the original exe's game; ogs: OG Script (src/), the port only.
            \\format = {t}
            \\# The oldest OpenGorky that runs it
            \\engine = {d}.{d}
            \\id = {s}
            \\title = {s}
            \\# The edition it is built on: en, ru
            \\base = {t}
            \\
        , .{ self.format, self.engine[0], self.engine[1], self.id(), self.title(), self.base });
        return w.buffered();
    }

    pub fn save(self: *const Manifest, io: Io, game: Io.Dir) !void {
        var buf: [1024]u8 = undefined;
        try game.writeFile(io, .{ .sub_path = file_name, .data = try self.write(&buf) });
    }
};

/// "1.2" (a missing minor is 0).
fn parseVersion(s: []const u8) ?Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseInt(u16, it.first(), 10) catch return null;
    const minor = if (it.next()) |n| std.fmt.parseInt(u16, n, 10) catch return null else 0;
    return .{ major, minor };
}

fn newer(a: Version, b: Version) bool {
    return a[0] > b[0] or (a[0] == b[0] and a[1] > b[1]);
}

/// The manifest of game folder `game`; none: a Classic game.
pub fn load(io: Io, game: Io.Dir) !Manifest {
    var buf: [4096]u8 = undefined;
    const data = game.readFile(io, file_name, &buf) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return Manifest.parse(data);
}

/// `load`; a project needing a newer engine: error.EngineTooNew.
pub fn apply(io: Io, game: Io.Dir) !Manifest {
    const m = try load(io, game);
    if (!m.supported()) return error.EngineTooNew;
    return m;
}

test "manifest: parse, format back, defaults, engine check" {
    const m = Manifest.parse("# x\nformat = ogs\nengine = 0.1\nid = sewers\ntitle = The Sewers\nbase = ru\nbad\nnope = 1\n");
    try std.testing.expectEqual(Format.ogs, m.format);
    try std.testing.expectEqualStrings("sewers", m.id());
    try std.testing.expectEqualStrings("The Sewers", m.title());
    try std.testing.expectEqual(Base.ru, m.base);
    var buf: [1024]u8 = undefined;
    const back = Manifest.parse(try m.write(&buf));
    try std.testing.expectEqual(m.format, back.format);
    try std.testing.expectEqual(m.engine, back.engine);
    try std.testing.expectEqualStrings("The Sewers", back.title());
    try std.testing.expectEqual(Base.ru, back.base);
    // Bad values keep the defaults: a Classic game.
    const d = Manifest.parse("format = opengorky\nformat = exe\nengine = x\nbase = de\n");
    try std.testing.expectEqual(Format.classic, d.format);
    try std.testing.expectEqual(engine_version, d.engine);
    try std.testing.expect(d.supported());
    try std.testing.expect(!Manifest.parse("engine = 99.0\n").supported());
    try std.testing.expect(!Manifest.parse("engine = 0.99\n").supported());
    try std.testing.expectEqual(Version{ 2, 0 }, parseVersion("2").?);
}

test "manifest: apply refuses a newer engine" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(Format.classic, (try apply(io, tmp.dir)).format);
    var m: Manifest = .{ .format = .ogs };
    try m.save(io, tmp.dir);
    try std.testing.expectEqual(Format.ogs, (try apply(io, tmp.dir)).format);
    m.engine = .{ 9, 0 };
    try m.save(io, tmp.dir);
    try std.testing.expectError(error.EngineTooNew, apply(io, tmp.dir));
}
