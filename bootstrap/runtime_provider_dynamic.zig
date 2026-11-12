const std = @import("std");
const activation = @import("activation");

pub const static_default = false;

pub fn prepare(allocator: std.mem.Allocator, io: std.Io, runtime_dir: []const u8, data_dir: []const u8, explicit_runtime: bool, use_static: bool) !activation.Activation {
    _ = use_static;
    return activation.Activation.prepare(allocator, io, runtime_dir, data_dir, explicit_runtime);
}
