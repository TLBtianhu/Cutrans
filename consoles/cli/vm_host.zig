const std = @import("std");

pub fn main(init: std.process.Init) !void {
    @import("bootstrap").runHost(init) catch |err| {
        std.debug.print("CUTRANS_VM_HOST_FAIL {s}\n", .{@errorName(err)});
        return err;
    };
}
