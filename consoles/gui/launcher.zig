//! cutrans.exe — 唯一公开入口：一个进程运行整个虚拟环境及其 App。
const std = @import("std");
const abi = @import("vne").abi;
const Control = @import("vne").environment_control.Control;

fn desktop(init: std.process.Init, config: *const abi.ShellConfig, api: *const abi.ShellApi, control: *Control) anyerror!void {
    return @import("nanoui_desktop").run(init, config, api, control);
}

fn library(init: std.process.Init, config: *const abi.ShellConfig, api: *const abi.ShellApi, _: *Control) anyerror!void {
    return @import("nanoui_library").run(init, config, api);
}

pub fn main(init: std.process.Init) !void {
    return @import("bootstrap").main(init, .{ .desktop = desktop, .library = library });
}
