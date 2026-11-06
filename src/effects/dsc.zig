//! Effect resource record: blend mode and frame list (composition reads the `.dsc`:
//! formats/dsc.zig, compose/models.zig).

/// Resource blend mode (0x408ad0).
pub const Blend = enum(u3) {
    opaque_ = 0,
    /// ONE / ONE
    add = 1,
    /// SRCALPHA / INVSRCALPHA
    alpha = 2,
    /// ZERO / INVSRCCOLOR
    darken = 3,
    /// ONE / INVSRCCOLOR — default for effects without a header (D3D)
    screen = 4,
    /// DESTCOLOR / ZERO
    multiply = 5,
};

/// An effect: its blending and its frames' `.3df` file names (same folder).
pub const Dsc = struct {
    blend: Blend = .screen,
    frames: []const []const u8 = &.{},
};
