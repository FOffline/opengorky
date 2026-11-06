//! The after-battle report's kill icons: the exe picks a monster's by its classic_id
//! from a fixed table (0x523f00; rules ui.ss, src/rules/ui.zig) — not by the fighter's
//! `spriteFile`, so a classic_id missing there (the shoggoth's 117) shows no icon.

const rules = @import("../rules.zig");
const entity = @import("../core.zig").entity;

/// OpenGorky: by the fighter's class first (a copy's own row).
pub fn iconOf(who: rules.Who) ?[]const u8 {
    return entity.enemyOf(who).kill_icon;
}
