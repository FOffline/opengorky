//! Composition: the packer over the loaders (src/loaders.zig). It makes and writes what
//! a project is made of: the converter (Classic → OpenGorky), the OG writer (a project's
//! model as its OG Script texts), the OG build (a project checked and packed as
//! `dist/<id>.ogp`), glTF export and import of the models, the model cache's and the
//! sound bank's sources, save files as the core's saved game. Its clients: the viewer
//! (viewer/app/run.zig), gorky-tool (tool/common.zig) and the editor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const archive = @import("formats.zig").archive;
const rules_text = @import("loaders.zig").rules_text;
/// Save files as the core's saved game.
pub const save = @import("compose/save.zig");
/// Models (actor/model_cache.zig's source), glTF export and import, the sound bank.
pub const models = @import("compose/models.zig");
pub const gltf_export = @import("compose/gltf_export.zig");
pub const gltf_import = @import("compose/gltf_import.zig");
pub const sounds = @import("compose/sounds.zig");
/// The OG writer: an OpenGorky project's model as the `src/` texts of OG Script; one block's edit in its range.
pub const og_write = @import("compose/og/write.zig");
/// The OG build: an OpenGorky project's `src/` checked and packed as `dist/<id>.ogp`,
/// what «Play» and `gorky-tool build`/`play` run.
pub const og_build = @import("compose/og/build.zig");
/// The converter, Classic → OpenGorky.
pub const convert = @import("compose/convert.zig");

/// The rules in force as the archive entries `rules\<name>.ss` (conversion, rules-dump).
pub fn rulesFiles(arena: Allocator) ![]archive.File {
    const texts = try rules_text.dumpTexts(arena);
    const out = try arena.alloc(archive.File, texts.len);
    for (out, texts) |*f, t| f.* = .{ .name = t.name, .data = t.data };
    return out;
}

test {
    _ = save;
    _ = models;
    _ = gltf_export;
    _ = gltf_import;
    _ = sounds;
    _ = og_write;
    _ = og_build;
    _ = convert;
    _ = @import("compose/gltf.zig");
}
