//! backend.zig — Cutrans 的第三方图形宿主边界
//!
//! ImGui 核心与官方 GLFW 输入后端保留在此处;wgpu-native 设备、纹理、
//! 帧重配与呈现也由本模块拥有。业务层只接收 DrawData,不接触这些生命周期。

const std = @import("std");
const zglfw = @import("zglfw");
const zgui = @import("zgui");
const wgpu = @import("gpu").wgpu;
const imgui_renderer = @import("gpu").imgui_renderer;
const RuntimeContext = @import("runtime").context.Context;
const paint = @import("uikit").paint;
const anim = @import("uikit").anim;

extern fn ImGui_ImplGlfw_InitForOther(window: *anyopaque, install_callbacks: bool) bool;
extern fn ImGui_ImplGlfw_NewFrame() void;
extern fn ImGui_ImplGlfw_Shutdown() void;

const cjk_ranges = [_]zgui.Wchar{ 0x0020, 0x00FF, 0x3000, 0x30FF, 0x4E00, 0x9FFF, 0xFF00, 0xFFEF, 0, 0 };
const embedded_icons = @import("assets").remix_icons;

const CallbackState = struct {
    adapter: ?wgpu.Adapter = null,
    device: ?wgpu.Device = null,
    adapter_ready: bool = false,
    device_ready: bool = false,
    failed: bool = false,
};

fn onAdapter(status_code: u32, adapter: wgpu.Adapter, _: wgpu.StringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const state: *CallbackState = @ptrCast(@alignCast(ud1 orelse return));
    if (status_code != 1) {
        state.failed = true;
        state.adapter_ready = true;
        return;
    }
    state.adapter = adapter;
    state.adapter_ready = true;
}

fn onDevice(status_code: u32, device: wgpu.Device, _: wgpu.StringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const state: *CallbackState = @ptrCast(@alignCast(ud1 orelse return));
    if (status_code != 1) {
        state.failed = true;
        state.device_ready = true;
        return;
    }
    state.device = device;
    state.device_ready = true;
}

const ErrorState = struct {
    device_lost: bool = false,
    uncaptured_error: bool = false,
    error_reported: bool = false,
};

fn onDeviceLost(_: wgpu.Device, _: u32, _: wgpu.StringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const state: *ErrorState = @ptrCast(@alignCast(ud1 orelse return));
    state.device_lost = true;
}

fn onUncapturedError(_: wgpu.Device, _: u32, _: wgpu.StringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const state: *ErrorState = @ptrCast(@alignCast(ud1 orelse return));
    state.uncaptured_error = true;
}

pub const Backend = struct {
    alloc: std.mem.Allocator,
    error_state: *ErrorState,
    runtime: *RuntimeContext,
    instance: wgpu.Instance,
    adapter: wgpu.Adapter,
    device: wgpu.Device,
    surface: wgpu.Surface,
    queue: wgpu.Queue,
    renderer: imgui_renderer.Renderer,
    size: [2]c_int,

    pub fn init(arena: std.mem.Allocator, window: *zglfw.Window, runtime: *RuntimeContext) !Backend {
        const instance = wgpu.wgpuCreateInstance(null);
        errdefer wgpu.wgpuInstanceRelease(instance);
        const hwnd = zglfw.getWin32Window(window);
        var hwnd_src = wgpu.SurfaceSourceWindowsHWND{
            .chain = .{ .next = null, .sType = wgpu.STYPE_SURFACE_HWND },
            .hinstance = null,
            .hwnd = @ptrCast(hwnd),
        };
        const surface = wgpu.wgpuInstanceCreateSurface(instance, &.{
            .chain = @ptrCast(&hwnd_src.chain),
            .label = .{},
        });
        errdefer wgpu.wgpuSurfaceRelease(surface);

        var state = CallbackState{};
        const adapter_opts = wgpu.RequestAdapterOptions{ .compatibleSurface = surface };
        _ = wgpu.wgpuInstanceRequestAdapter(instance, @ptrCast(&adapter_opts), .{ .mode = wgpu.CB_PROCESS_EVENTS, .callback = @ptrCast(&onAdapter), .ud1 = &state });
        while (!state.adapter_ready) wgpu.wgpuInstanceProcessEvents(instance);
        if (state.failed) return error.AdapterRequestFailed;
        const adapter = state.adapter orelse return error.AdapterRequestFailed;
        errdefer wgpu.wgpuAdapterRelease(adapter);
        const error_state = try arena.create(ErrorState);
        errdefer arena.destroy(error_state);
        const descriptor = wgpu.DeviceDescriptor{
            .deviceLostCallbackInfo = .{
                .mode = wgpu.CB_PROCESS_EVENTS,
                .callback = onDeviceLost,
                .ud1 = error_state,
            },
            .uncapturedErrorCallbackInfo = .{
                .callback = onUncapturedError,
                .ud1 = error_state,
            },
        };
        _ = wgpu.wgpuAdapterRequestDevice(adapter, &descriptor, .{ .mode = wgpu.CB_PROCESS_EVENTS, .callback = @ptrCast(&onDevice), .ud1 = &state });
        while (!state.device_ready) wgpu.wgpuInstanceProcessEvents(instance);
        if (state.failed) return error.DeviceRequestFailed;
        const device = state.device orelse return error.DeviceRequestFailed;
        errdefer wgpu.wgpuDeviceRelease(device);
        const queue = wgpu.wgpuDeviceGetQueue(device);
        errdefer wgpu.wgpuQueueRelease(queue);
        std.debug.print("[gpu] 适配器与设备就绪\n", .{});

        const size = window.getFramebufferSize();
        if (size[0] <= 0 or size[1] <= 0) return error.InvalidFramebufferSize;
        wgpu.wgpuSurfaceConfigure(surface, &.{
            .device = device,
            .format = wgpu.FORMAT_BGRA8,
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
        });

        zgui.init(arena);
        errdefer zgui.deinit();
        // VM-owned view state must never be implicitly loaded/saved in cwd.
        zgui.io.setIniFilename(null);
        zgui.io.setConfigFlags(.{ .nav_enable_keyboard = true });
        anim.init(arena);
        errdefer anim.deinit();
        const main_font_data = try runtime.config.mainFont();
        const font_main = zgui.io.addFontFromMemoryWithConfig(main_font_data, 20.0, paint.fontConfig(false, 1.0), &cjk_ranges);
        paint.setFont(font_main);
        _ = zgui.io.addFontFromMemoryWithConfig(embedded_icons, 20.0, paint.fontConfig(true, 1.0), null);
        const font_bold = zgui.io.addFontFromMemoryWithConfig(main_font_data, 20.0, paint.fontConfig(false, 1.22), &cjk_ranges);
        paint.setFontBold(font_bold);
        paint.applyStyle();
        var backend_flags = zgui.io.getBackendFlags();
        backend_flags.renderer_has_textures = true;
        backend_flags.renderer_has_vtx_offset = true;
        zgui.io.setBackendFlags(backend_flags);

        if (!ImGui_ImplGlfw_InitForOther(@ptrCast(window), true)) return error.ImGuiBackendInitFailed;
        errdefer ImGui_ImplGlfw_Shutdown();
        var renderer = imgui_renderer.Renderer.init(arena, device, wgpu.FORMAT_BGRA8);
        errdefer renderer.deinit();
        return .{
            .alloc = arena,
            .error_state = error_state,
            .runtime = runtime,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .surface = surface,
            .queue = queue,
            .renderer = renderer,
            .size = size,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.renderer.deinit();
        ImGui_ImplGlfw_Shutdown();
        anim.deinit();
        zgui.deinit();
        wgpu.wgpuSurfaceRelease(self.surface);
        wgpu.wgpuQueueRelease(self.queue);
        wgpu.wgpuDeviceRelease(self.device);
        wgpu.wgpuAdapterRelease(self.adapter);
        wgpu.wgpuInstanceRelease(self.instance);
        self.alloc.destroy(self.error_state);
    }

    pub fn deviceLost(self: *const Backend) bool {
        return self.error_state.device_lost;
    }

    /// 处理 framebuffer 变化并启动 ImGui 帧;false 表示最小化,不可渲染。
    pub fn nextFrame(self: *Backend, window: *zglfw.Window) bool {
        if (self.error_state.device_lost) {
            self.runtime.status.set("GPU 设备已丢失,停止渲染");
            return false;
        }
        if (self.error_state.uncaptured_error and !self.error_state.error_reported) {
            self.error_state.error_reported = true;
            self.runtime.status.set("GPU 出现未捕获错误");
        }
        const cur = window.getFramebufferSize();
        if ((cur[0] != self.size[0] or cur[1] != self.size[1]) and cur[0] > 0 and cur[1] > 0) {
            self.size = cur;
            wgpu.wgpuSurfaceConfigure(self.surface, &.{
                .device = self.device,
                .format = wgpu.FORMAT_BGRA8,
                .width = @intCast(cur[0]),
                .height = @intCast(cur[1]),
            });
        }
        if (cur[0] == 0 or cur[1] == 0) return false;
        ImGui_ImplGlfw_NewFrame();
        anim.tick(1.0 / @max(1.0, zgui.io.getFramerate()));
        return true;
    }

    pub const Presentation = enum { submitted, unavailable, device_lost };

    pub fn render(self: *Backend, draw_data: zgui.DrawData) Presentation {
        if (self.error_state.device_lost) return .device_lost;
        self.renderer.updateTextures(draw_data) catch |err| {
            self.runtime.status.set("GPU 纹理更新失败");
            std.debug.print("[gpu] 纹理更新失败: {s}\n", .{@errorName(err)});
            return .unavailable;
        };
        var st: wgpu.SurfaceTexture = undefined;
        wgpu.wgpuSurfaceGetCurrentTexture(self.surface, &st);
        if (st.status != wgpu.SURFACE_SUCCESS_OPTIMAL and st.status != wgpu.SURFACE_SUCCESS_SUBOPTIMAL) {
            if (st.texture) |texture| wgpu.wgpuTextureRelease(texture);
            self.runtime.status.set("GPU 当前帧不可用");
            return .unavailable;
        }
        const tex = st.texture orelse return .unavailable;
        defer wgpu.wgpuTextureRelease(tex);
        const view = wgpu.wgpuTextureCreateView(tex, null);
        defer wgpu.wgpuTextureViewRelease(view);

        const enc = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null);
        const attach = [_]wgpu.RenderPassColorAttachment{.{
            .view = view,
            .loadOp = wgpu.LOAD_CLEAR,
            .storeOp = wgpu.STORE_STORE,
            .clearValue = .{ .r = 0.055, .g = 0.059, .b = 0.078, .a = 1.0 },
        }};
        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(enc, &.{
            .colorAttachmentCount = 1,
            .colorAttachments = &attach,
        });
        self.renderer.render(draw_data, pass);
        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);
        const buf = wgpu.wgpuCommandEncoderFinish(enc, null);
        wgpu.wgpuCommandEncoderRelease(enc);
        wgpu.wgpuQueueSubmit(self.queue, 1, &buf);
        wgpu.wgpuCommandBufferRelease(buf);
        if (wgpu.wgpuSurfacePresent(self.surface) != wgpu.STATUS_SUCCESS) {
            self.runtime.status.set("GPU 呈现提交失败");
            return .unavailable;
        }
        return .submitted;
    }
};

test "wgpu callbacks keep adapter and device state per backend" {
    var first = CallbackState{};
    var second = CallbackState{};
    onAdapter(1, @ptrFromInt(0x1), .{}, &first, null);
    onAdapter(2, @ptrFromInt(0x2), .{}, &second, null);
    try std.testing.expect(first.adapter_ready and !first.failed);
    try std.testing.expect(second.adapter_ready and second.failed);
    try std.testing.expect(first.adapter != second.adapter);
    onDevice(1, @ptrFromInt(0x3), .{}, &first, null);
    try std.testing.expect(first.device_ready and !first.failed);
    try std.testing.expectEqual(@as(usize, 0x3), @intFromPtr(first.device.?));
}

test "device error callbacks only update explicit error state" {
    var state = ErrorState{};
    onDeviceLost(@ptrFromInt(0x1), 1, .{}, &state, null);
    try std.testing.expect(state.device_lost);
    onUncapturedError(@ptrFromInt(0x1), 1, .{}, &state, null);
    try std.testing.expect(state.uncaptured_error);
}
