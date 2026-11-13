//! OS 能力口岸:语义归调用方,平台差异归各 Port

pub const window = @import("window.zig");
pub const paths = @import("paths.zig");
pub const process = @import("process.zig");
pub const library = @import("library.zig");
pub const file_identity = @import("file_identity.zig");
pub const file_dialog = @import("file_dialog.zig");
pub const instance_lock = @import("instance_lock.zig");
