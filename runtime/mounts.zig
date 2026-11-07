const std = @import("std");
const RuntimeContext = @import("context.zig").Context;

pub fn configure(ctx: *RuntimeContext) !void {
    const paths = ctx.paths;
    try ctx.mounts.setRoot(ctx.allocator, .runtime, paths.resource_dir);
    try ctx.mounts.setRoot(ctx.allocator, .pack, paths.resource_dir);
    try ctx.mounts.setRoot(ctx.allocator, .session, paths.data_dir);
    const cache = try std.fs.path.join(ctx.allocator, &.{ paths.data_dir, "cache" });
    defer ctx.allocator.free(cache);
    try ctx.mounts.setRoot(ctx.allocator, .cache, cache);
    const temp = try std.fs.path.join(ctx.allocator, &.{ paths.data_dir, "temp" });
    defer ctx.allocator.free(temp);
    try ctx.mounts.setRoot(ctx.allocator, .temp, temp);
}
