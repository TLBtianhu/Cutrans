const std = @import("std");

pub fn main(init: std.process.Init) !void {
    @import("bootstrap").runAttached(init, .nanoui_library, struct {
        fn run(process: std.process.Init, _: []const u8, config: *const @import("vne").abi.ShellConfig, api: *const @import("vne").abi.ShellApi, _: anytype) !void {
            return @import("nanoui_library").run(process, config, api);
        }
    }.run) catch |err| {
        std.debug.print("CUTRANS_NANOUI_LIBRARY_FAIL {s}\n", .{@errorName(err)});
        return err;
    };
}
