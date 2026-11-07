//! Per-frame BGRA textures for `ui.texture` on Direct3D 11. Slots are reused,
//! recreated when dimensions change, and never left holding an invalid source.
const std = @import("std");
const gpu = @import("gpu.zig");
const api = @import("d3d11_glue.zig");
const Com = api.Com;

const Slot = struct {
    texture: ?*Com = null,
    srv: ?*Com = null,
    width: u32 = 0,
    height: u32 = 0,

    fn clear(slot: *Slot) void {
        if (slot.srv) |view| view.release();
        if (slot.texture) |texture| texture.release();
        slot.* = .{};
    }
};

pub const Textures = struct {
    slots: std.ArrayListUnmanaged(Slot) = .empty,

    pub fn deinit(textures: *Textures) void {
        textures.releaseAll();
        textures.slots.deinit(std.heap.c_allocator);
    }

    fn releaseAll(textures: *Textures) void {
        for (textures.slots.items) |*slot| slot.clear();
        textures.slots.clearRetainingCapacity();
    }

    pub fn sync(textures: *Textures, device: *Com, context: *Com, sources: []const gpu.Texture) void {
        while (textures.slots.items.len < sources.len) {
            textures.slots.append(std.heap.c_allocator, .{}) catch {
                textures.releaseAll();
                return;
            };
        }
        if (textures.slots.items.len > sources.len) {
            for (textures.slots.items[sources.len..]) |*slot| slot.clear();
            textures.slots.items.len = sources.len;
        }
        for (sources, textures.slots.items) |source, *slot| {
            const stride = if (source.stride == 0) @as(usize, source.width) * 4 else source.stride;
            const row = @as(usize, source.width) * 4;
            const required = if (source.height == 0) 0 else (source.height - 1) * stride + row;
            if (source.width == 0 or source.height == 0 or stride < row or source.bgra.len < required) {
                slot.clear();
                continue;
            }
            if (slot.texture == null or slot.width != source.width or slot.height != source.height) {
                slot.clear();
                slot.texture = api.texture2D(device, api.bgra8, source.width, source.height, api.bind_shader_resource);
                if (slot.texture) |texture| slot.srv = api.textureSrv(device, texture);
                slot.width = source.width;
                slot.height = source.height;
            }
            if (slot.texture == null or slot.srv == null) {
                slot.clear();
                continue;
            }
            context.slot(*const fn (*Com, *Com, u32, ?*const anyopaque, [*]const u8, u32, u32) callconv(.winapi) void, api.UpdateSubresource)(context, slot.texture.?, 0, null, source.bgra.ptr, @intCast(stride), 0);
        }
    }

    pub fn get(textures: *const Textures, index: usize) ?*Com {
        if (index >= textures.slots.items.len) return null;
        return textures.slots.items[index].srv;
    }
};
