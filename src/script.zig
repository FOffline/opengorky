//! Entry point of `script/` for other engine folders. Script language core: values, objects,
//! the IR and its runtime, the Classic front end. Files not exported here are internal to the folder.

pub const ast = @import("script/ast.zig");
pub const ir = @import("script/ir.zig");
pub const object = @import("script/object.zig");
pub const parser = @import("script/parser.zig");
pub const runtime = @import("script/runtime.zig");
pub const value = @import("script/value.zig");
/// The engine's built-in traits and their call on hosts' components.
pub const traits = @import("script/traits.zig");
pub const hosts = @import("script/hosts.zig");
pub const dispatch = @import("script/dispatch.zig");
pub const classic = struct {
    pub const import = @import("script/classic/import.zig");
    pub const print = @import("script/classic/print.zig");
    pub const @"export" = @import("script/classic/export.zig");
    /// Pass 3: creation events' data lifted into the object's model.
    pub const lift = @import("script/classic/lift.zig");
    /// The exe's field names ↔ the engine's (`charSize` ↔ `footprint_tiles`).
    pub const names = @import("script/classic/names.zig");
    /// Builtin names between Classic and OGS (`FighterSetHp` ↔ `fighter::SetHp`).
    pub const rename = @import("script/classic/rename.zig");
    /// Classic code as OG Script components.
    pub const ogsify = @import("script/classic/ogsify.zig");
};
/// OGS, the engine's own language: parser → IR, printer, program (namespaces).
pub const ogs = struct {
    pub const lexer = @import("script/ogs/lexer.zig");
    pub const parser = @import("script/ogs/parser.zig");
    pub const print = @import("script/ogs/print.zig");
    pub const link = @import("script/ogs/link.zig");
    /// A level's block in several texts of its folder made one.
    pub const levels = @import("script/ogs/levels.zig");
};

test {
    _ = @import("script/lexer.zig");
    _ = @import("script/exe.zig");
    _ = ir;
    _ = parser;
    _ = runtime;
    _ = value;
    _ = traits;
    _ = dispatch;
    _ = classic.print;
    _ = classic.@"export";
    _ = classic.lift;
    _ = classic.rename;
    _ = classic.names;
    _ = classic.ogsify;
    _ = hosts;
    _ = ogs.lexer;
    _ = ogs.print;
    _ = ogs.link;
    _ = ogs.levels;
    _ = @import("script/ogs/tests.zig");
}
