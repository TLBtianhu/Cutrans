const std = @import("std");

fn runRole(init: std.process.Init, role: @import("bootstrap").roles.Role) !void {
    switch (role) {
        .host => return @import("bootstrap").runHost(init),
        .shell => return @import("bootstrap").runAttached(init, .desktop, struct {
            fn run(process: std.process.Init, _: []const u8, config: *const @import("vne").abi.ShellConfig, api: *const @import("vne").abi.ShellApi, hooks: anytype) !void {
                return @import("nanoui_desktop").run(process, config, api, hooks);
            }
        }.run),
        .library => return @import("bootstrap").runAttached(init, .nanoui_library, struct {
            fn run(process: std.process.Init, _: []const u8, config: *const @import("vne").abi.ShellConfig, api: *const @import("vne").abi.ShellApi, _: anytype) !void {
                return @import("nanoui_library").run(process, config, api);
            }
        }.run),
    }
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    if (!args.skip()) return error.MissingExecutableName;
    if (args.next()) |first| {
        const parsed = @import("bootstrap").roles.parse(first) catch |err| {
            std.debug.print("CUTRANS_ROLE_FAIL {s}\n", .{@errorName(err)});
            return err;
        };
        if (parsed) |role| {
            runRole(init, role) catch |err| {
                std.debug.print("CUTRANS_ROLE_FAIL {s} role={s}\n", .{ @errorName(err), @tagName(role) });
                return err;
            };
            return;
        }
    }
    return @import("bootstrap").main(init);
}
