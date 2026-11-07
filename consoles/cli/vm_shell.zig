const std = @import("std");

pub fn main(init: std.process.Init) !void {
    @import("bootstrap").runShell(init) catch |err| {
        std.debug.print("CUTRANS_SHELL_FAIL {s}\n", .{@errorName(err)});
        return err;
    };
}
