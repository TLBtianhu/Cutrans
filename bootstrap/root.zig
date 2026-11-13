pub const payload_blob = @import("payload_blob");
pub const main = @import("main.zig").main;
pub const Apps = @import("main.zig").Apps;
pub const AppRun = @import("main.zig").AppRun;
pub const instance = @import("instance.zig");

test {
    _ = @import("main.zig");
    _ = instance;
}
