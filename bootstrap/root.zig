pub const payload_blob = @import("payload_blob");
pub const main = @import("main.zig").main;
pub const runHost = @import("main.zig").runHost;
pub const runShell = @import("main.zig").runShell;
pub const runAttached = @import("main.zig").runAttached;
pub const AttachedShell = @import("main.zig").AttachedShell;
pub const roles = @import("roles.zig");

test {
    _ = roles;
}
