//! Compatibility re-export; the codec lives in the shared `imaging` module.

pub const adapter_ids = @import("imaging").adapter_ids;
pub const Image = @import("imaging").Image;
pub const decode = @import("imaging").decode;
pub const load = @import("imaging").load;
pub const PreparedPng = @import("imaging").PreparedPng;
pub const preparePng = @import("imaging").preparePng;
pub const savePng = @import("imaging").savePng;
pub const savePngExternal = @import("imaging").savePngExternal;
