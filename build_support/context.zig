const std = @import("std");

pub const Generated = struct { manifest: std.Build.LazyPath, inno: ?std.Build.LazyPath };

pub fn generate(b: *std.Build, form: []const u8, channel: []const u8) Generated {
    const run = b.addSystemCommand(&.{"python"});
    run.addFileArg2(b.path("tools/build_context.py"), .{});
    run.addFileInput(b.path("tools/product.py"));
    run.addFileInput(b.path("vne/product.zig"));
    run.addFileInput(b.path("vne/abi.zig"));
    run.addFileInput(b.path("build.zig.zon"));
    run.addArgs(&.{ "--form", form, "--channel", channel });
    if (std.mem.eql(u8, form, "development")) {
        run.addArg("--source-root");
        run.addDirectoryArg2(b.path(""), .{ .make_absolute = true });
    }
    run.addArg("--output");
    const manifest = run.addOutputFileArg2("cutrans-context.json", .{});
    const inno = if (std.mem.eql(u8, form, "installed")) blk: {
        run.addArg("--inno-output");
        break :blk run.addOutputFileArg2("product.iss", .{});
    } else null;
    return .{ .manifest = manifest, .inno = inno };
}
