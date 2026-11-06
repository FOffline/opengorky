//! Built-in rules: campaign.ss — the exe's new game and menu shell
//! (viewer/app/flow.zig, viewer/app/run.zig, viewer/menu.zig, world/start.zig).

const rows = @import("rows.zig");

pub const builtin = [_]rows.Campaign{.{
    // 0x413386: the port with Sullivan selected, intro introkon first.
    .level = "01_port",
    .leader = "Sullivan",
    // 0x431550: every gamestart\*.hro.
    .party = "",
    // The party panel's first heroes (state/world.zig party).
    .panel_first = "Sullivan Ovitz Trantigne",
    .area = "",
    .point = 0,
    .scene = "",
    .intro = "introkon.avi",
    // 0x40fd06: whichever exist.
    .startup = "logo1.avi monolith.avi topware.avi logo.avi presents.avi intro.avi",
    .menu_logo = "gorky.3df",
    .menu_music = "menu",
    .credits_music = "credits",
    .credits = "credits.inf",
    .credits_video = "",
    .note = "Gorky 17",
}};
