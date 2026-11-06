//! Software renderer for 3D actors (viewer and gorky-tool only; game logic does not use it).

pub const layer = @import("render/layer.zig");
pub const raster = @import("render/raster.zig");
pub const depth_fit = @import("render/depth_fit.zig");
pub const textures = @import("render/textures.zig");
pub const post = @import("render/post.zig");

test {
    _ = layer;
    _ = raster;
    _ = depth_fit;
    _ = textures;
    _ = post;
}
