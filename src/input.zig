//! Input layer (over the core): the GUI modes that decide which core command a click issues
//! (`mouse.zig`). The viewer maps SDL events to them; the console and play scripts set them too.
//! The core takes only the commands and never imports this layer (scripts/layercheck.sh).

pub const mouse = @import("input/mouse.zig");

test {
    _ = mouse;
}
