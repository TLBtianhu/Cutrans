pub const lifecycle = @import("lifecycle.zig");
pub const shell_rpc = @import("shell_rpc.zig");
pub const pump_driver = @import("pump_driver.zig");

test "Host module tests are included in the headless suite" {
    _ = lifecycle;
    _ = shell_rpc;
    _ = pump_driver;
}
