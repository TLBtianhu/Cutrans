//! 通用 UI 工具包入口:画笔/声明解释/控件,不是 VM 的专属稀疏 GUI 操作台。
//! VM 的 GUI 投影归 consoles/gui;本目录只提供可复用绘制设施。

pub const anim = @import("anim.zig");
pub const paint = @import("paint.zig");
pub const theme = @import("theme.zig").theme;
pub const widgets = @import("widgets.zig");
pub const node = @import("node.zig");
pub const bytecode = @import("bytecode.zig");
pub const icons = @import("icons.zig");
