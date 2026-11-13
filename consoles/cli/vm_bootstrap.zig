//! cutrans_bootstrap.exe — 无界面入口：只做 Runtime Pack 诊断、无头打开与回放。
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    return @import("bootstrap").main(init, .{});
}
