//! Entry point of `audio/`: mixer, sounds, location sound logic (no device). Decoding
//! is a parser (formats/sound.zig). Files not exported here are internal to the folder.

pub const mixer = @import("audio/mixer.zig");
pub const scene = @import("audio/scene.zig");
pub const sound = @import("audio/sound.zig");

test {
    _ = sound;
    _ = mixer;
    _ = scene;
}
