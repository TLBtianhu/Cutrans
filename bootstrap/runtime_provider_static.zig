const std = @import("std");
const activation = @import("activation");
const abi = @import("vne").abi;
const native = @import("native_runtime");
const capabilities = @import("runtime").capabilities;

pub const static_default = true;

const capability_ids = blk: {
    var ids: [capabilities.declarations.len][]const u8 = undefined;
    for (capabilities.declarations, 0..) |capability, index| ids[index] = capability.id;
    break :blk ids;
};

fn manifest() @import("vne").runtime_pack.Manifest {
    return .{
        .format = "cutrans-runtime-static/1",
        .id = "cutrans-vm",
        .version = @import("vne").product.version,
        .abi = abi.nativeAbi(),
        .entry = "builtin",
        .vm_schema = 1,
        .host_api = abi.version,
        .document_schema = 3,
        .required_capabilities = &capability_ids,
        .files = &.{},
    };
}

fn loadShellApi(_: *const activation.Api, context: ?*anyopaque) !abi.ShellApi {
    return .{
        .struct_size = @sizeOf(abi.ShellApi),
        .abi_version = abi.version,
        .context = context,
        .command_result = native.cutrans_vm_command_result,
        .document_fingerprint = native.cutrans_vm_document_fingerprint,
        .document_flags = native.cutrans_vm_document_flags,
        .document_read = native.cutrans_vm_document_read,
        .pump = native.cutrans_vm_frame_pump,
        .input_push = native.cutrans_vm_input_push,
        .input_flush = native.cutrans_vm_input_flush,
        .frame_report = native.cutrans_vm_frame_report,
        .playback_report = native.cutrans_vm_playback_report,
        .library_list = native.cutrans_vm_library_list,
        .library_label = native.cutrans_vm_library_label,
        .asset_list = native.cutrans_vm_asset_list,
        .asset_source = native.cutrans_vm_asset_source,
        .asset_preview = native.cutrans_vm_asset_preview,
        .asset_read = native.cutrans_vm_asset_read,
        .asset_open_external = native.cutrans_vm_asset_open_external,
        .workspace_api = native.cutrans_vm_workspace_api,
        .source_read = native.cutrans_vm_source_read,
        .resource_api = native.cutrans_vm_resource_api,
        .preview_info = native.cutrans_vm_preview_info,
        .preview_read = native.cutrans_vm_preview_read,
    };
}

pub fn prepare(allocator: std.mem.Allocator, io: std.Io, runtime_dir: []const u8, data_dir: []const u8, explicit_runtime: bool, use_static: bool) !activation.Activation {
    if (!use_static) return activation.Activation.prepare(allocator, io, runtime_dir, data_dir, explicit_runtime);
    return activation.Activation.prepareStatic(allocator, io, data_dir, explicit_runtime, manifest(), native, loadShellApi);
}
