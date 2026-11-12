const std = @import("std");

pub fn main(init: std.process.Init) !void {
    @import("bootstrap").runAttached(init, .desktop, struct {
        fn run(process: std.process.Init, _: []const u8, config: *const @import("vne").abi.ShellConfig, api: *const @import("vne").abi.ShellApi, hooks: anytype) !void {
            return @import("nanoui_desktop").run(process, config, api, hooks);
        }
    }.run) catch |err| {
        std.debug.print("CUTRANS_SHELL_FAIL {s}\n", .{@errorName(err)});
        return err;
    };
}
