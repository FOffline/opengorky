//! Shared bits of gorky-tool commands.

const std = @import("std");
const Io = std.Io;
const og = @import("opengorky");

/// `<game>/dat`, read as its manifest says (loaders.openGame: the OpenGorky layer and
/// rules) with the core's texts and records (loaders.loadCore); the game dir is closed
/// right away.
pub fn openDat(io: Io, game_dir: []const u8) !Io.Dir {
    var game = try og.loaders.openGame(io, game_dir);
    game.root.close(io);
    og.loaders.loadCore(io, game.dat);
    return game.dat;
}

/// "X,Y" — a background point.
pub fn parseXY(s: []const u8) ![2]f32 {
    var it = std.mem.splitScalar(u8, s, ',');
    return .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") };
}
