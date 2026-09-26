//! Shared fixtures and aliases for Screen regression tests.
pub const Screen = @import("../../Screen.zig");
pub const std = @import("std");
pub const Selection = @import("../../Selection.zig");
pub const PageList = @import("../../PageList.zig");
pub const pagepkg = @import("../../page.zig");
pub const point = @import("../../point.zig");
pub const size = @import("../../size.zig");
pub const style = @import("../../style.zig");
pub const Page = pagepkg.Page;
pub const Cell = pagepkg.Cell;
pub const Pin = PageList.Pin;
pub const init = Screen.init;
pub const resize_tw = Screen.TestAccess.resize_tw;
pub const selectWord = Screen.selectWord;
pub const PromptClickMove = Screen.PromptClickMove;

pub const cursorDownOrScroll = Screen.TestAccess.cursorDownOrScroll;
