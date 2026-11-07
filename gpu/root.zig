//! 跨应用共享图形设施入口:wgpu 绑定与 ImGui 渲染后端。
//! 这里不是 VM 的 GUI 投影;应用/控制台的显示策略在各自目录。

pub const wgpu = @import("wgpu.zig");
pub const imgui_renderer = @import("wgpu_imgui.zig");
