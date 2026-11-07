//! view.zig — 视图文档注册表与当前视图状态(不再是四页硬编码)
//!
//! 声明真源:apps/desktop/assets/ui/desktop.json;编译产物由构建图在缓存中生成。
//! 文档数量、id、导航标签和图标均由声明提供;这里只负责装载、索引与状态绑定。

const std = @import("std");
const bytecode = @import("uikit").bytecode;

const embedded = @embedFile("desktop_cui");

pub const View = bytecode.View;
pub const bytecode_size = embedded.len;

var views: []View = &.{};
var current_index: usize = 0;
pub var decoded_nodes: u32 = 0;

fn bindInput(_: [:0]const u8) ?[:0]u8 {
    return null;
}

pub fn init(allocator: std.mem.Allocator) !void {
    const result = try bytecode.decode(allocator, embedded, bindInput);
    views = result.views;
    decoded_nodes = result.node_count;
    current_index = 0;
}

pub fn all() []View {
    return views;
}

pub fn current() View {
    std.debug.assert(views.len > 0);
    return views[current_index];
}

pub fn currentIndex() usize {
    return current_index;
}

/// 返回是否真的切换;只有变化时外壳才需要重播过渡动画。
pub fn select(index: usize) bool {
    if (index >= views.len or index == current_index) return false;
    current_index = index;
    return true;
}

pub fn selectId(id: []const u8) bool {
    for (views, 0..) |item, i| {
        if (std.mem.eql(u8, item.id, id)) return select(i);
    }
    return false;
}
