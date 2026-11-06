//! Dark neutral greys with one blue accent, as Unreal Engine's and Unity's editors:
//! docked panels on a darker frame, inset fields, rounded controls (`app.theme`).

const clay = @import("clay.zig");

/// The frame behind the panels (gaps, status bar).
pub const bg = clay.rgb(0x15171b);
pub const panel = clay.rgb(0x1b1e23);
/// Panel title bars and toolbars.
pub const header = clay.rgb(0x20242a);
pub const row_hover = clay.rgb(0x272b32);
pub const row_selected = clay.rgb(0x2f7cf6);
pub const viewport = clay.rgb(0x101114);
pub const text = clay.rgb(0xe3e6ea);
pub const dim = clay.rgb(0x8b919b);
pub const line = clay.rgb(0x2a2e35);
pub const accent = clay.rgb(0x2f7cf6);
pub const accent_hover = clay.rgb(0x5a98f8);
pub const warn = clay.rgb(0xe8a33d);
pub const ok = clay.rgb(0x3fb950);
/// Inset value fields and their frame.
pub const field = clay.rgb(0x14161a);
pub const field_border = clay.rgb(0x333842);
/// Buttons: their face (hovered, pressed) and outline; title bars.
pub const button = clay.rgb(0x23272e);
pub const button_hover = clay.rgb(0x2c313a);
pub const button_down = clay.rgb(0x1c1f25);
pub const button_edge = clay.rgb(0x363b45);
pub const title = clay.rgb(0x20242a);
/// A step's changed lines in History: gone, new.
pub const removed = clay.rgb(0xe06c75);
pub const added = clay.rgb(0x98c379);
/// The mark of an object that comes later (reinforcements).
pub const later = clay.rgb(0x969696);
