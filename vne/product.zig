//! Product identity and default service policy. Build/installer projections read this source.
pub const id = "org.cutrans.Cutrans";
pub const name = "Cutrans";
pub const version = "0.1.0";
pub const default_channel = "development";
pub const app_id = "{6EFD818C-D468-44A5-A9DE-23EBF7DD9B32}";
pub const document_progid = "Cutrans.Document";
pub const document_extension = ".cut";
pub const updates_enabled = false;
pub const accounts_enabled = false;
pub const telemetry_enabled = false;

pub const Channel = enum { development, preview, stable };
