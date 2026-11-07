//! Host reuses the same explicit job policy as other attached callers.
const policy = @import("vne").job_driver;
pub const Driver = policy.Driver;
pub const Pump = policy.Pump;
