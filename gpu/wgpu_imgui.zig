//! wgpu_imgui.zig — ImGui DrawData → wgpu-native v29 的最小渲染器
//!
//! 自写口岸:不借 Dawn 方言的 imgui_impl_wgpu.cpp,全程零方差。
//! 职责:管线+字体纹理+顶/索引缓冲+按 cmd 裁剪矩形绘制。纹理走
//! draw_data.textures 的增量队列(1.92 纹理协议:want_create/updates/destroy)。

const std = @import("std");
const zgui = @import("zgui");
const wgpu = @import("wgpu.zig");

const VERTEX_SHADER: [:0]const u8 =
    \\struct U { scale: vec2f, offset: vec2f, };
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@group(0) @binding(1) var tex: texture_2d<f32>;
    \\@group(0) @binding(2) var smp: sampler;
    \\struct Vin { @location(0) pos: vec2f, @location(1) uv: vec2f, @location(2) col: vec4f, };
    \\struct Vout { @builtin(position) pos: vec4f, @location(0) uv: vec2f, @location(1) col: vec4f, };
    \\@vertex fn vs(v: Vin) -> Vout {
    \\    var o: Vout;
    \\    o.pos = vec4f(v.pos * u.scale + u.offset, 0.0, 1.0);
    \\    o.uv = v.uv;
    \\    o.col = v.col;
    \\    return o;
    \\}
    \\@fragment fn fs(v: Vout) -> @location(0) vec4f {
    \\    return v.col * textureSample(tex, smp, v.uv);
    \\}
;

const TexEntry = struct {
    tex: wgpu.Texture,
    view: wgpu.TextureView,
    bg: wgpu.BindGroup,
    w: i32,
    h: i32,
};

fn shouldDestroyTexture(td: *const zgui.TextureData) bool {
    return td.status == .want_destroy and td.unused_Frames > 0;
}

pub const Renderer = struct {
    device: wgpu.Device,
    queue: wgpu.Queue,
    pipeline: wgpu.RenderPipeline,
    pipeline_layout: wgpu.PipelineLayout,
    bgl: wgpu.BindGroupLayout,
    sampler: wgpu.Sampler,
    uniform_buf: wgpu.Buffer,
    vtx_buf: wgpu.Buffer,
    vtx_cap: usize,
    idx_buf: wgpu.Buffer,
    idx_cap: usize,
    textures: std.ArrayList(*TexEntry),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, device: wgpu.Device, rt_format: u32) Renderer {
        const queue = wgpu.wgpuDeviceGetQueue(device);

        // 着色器
        var wgsl_chain = wgpu.ShaderSourceWGSL{
            .chain = .{ .next = null, .sType = wgpu.STYPE_WGSL },
            .code = .{ .data = VERTEX_SHADER.ptr, .length = VERTEX_SHADER.len },
        };
        const module = wgpu.wgpuDeviceCreateShaderModule(device, &.{
            .chain = @ptrCast(&wgsl_chain.chain),
        });
        defer wgpu.wgpuShaderModuleRelease(module);

        // 绑定组布局:0=uniform(vs) 1=纹理(fs) 2=采样器(fs)
        const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
            .{ .binding = 0, .visibility = wgpu.STAGE_VERTEX, .buffer = .{ .type = wgpu.BIND_BUFFER_UNIFORM } },
            .{ .binding = 1, .visibility = wgpu.STAGE_FRAGMENT, .texture = .{ .sampleType = wgpu.BIND_TEXTURE_FLOAT, .viewDimension = wgpu.VIEW_DIM_2D } },
            .{ .binding = 2, .visibility = wgpu.STAGE_FRAGMENT, .sampler = .{ .type = wgpu.BIND_SAMPLER_FILTERING } },
        };
        const bgl = wgpu.wgpuDeviceCreateBindGroupLayout(device, &.{
            .entryCount = bgl_entries.len,
            .entries = &bgl_entries,
        });

        const blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BLEND_OP_ADD, .srcFactor = wgpu.BLEND_SRC_ALPHA, .dstFactor = wgpu.BLEND_ONE_MINUS_SRC_ALPHA },
            .alpha = .{ .operation = wgpu.BLEND_OP_ADD, .srcFactor = wgpu.BLEND_ONE, .dstFactor = wgpu.BLEND_ONE_MINUS_SRC_ALPHA },
        };
        const vtx_attrs = [_]wgpu.VertexAttribute{
            .{ .format = wgpu.VERTEX_FORMAT_FLOAT32x2, .offset = 0, .shaderLocation = 0 },
            .{ .format = wgpu.VERTEX_FORMAT_FLOAT32x2, .offset = 8, .shaderLocation = 1 },
            .{ .format = wgpu.VERTEX_FORMAT_UNORM8x4, .offset = 16, .shaderLocation = 2 },
        };
        const vtx_layout = [_]wgpu.VertexBufferLayout{.{
            .arrayStride = @sizeOf(zgui.DrawVert),
            .attributeCount = vtx_attrs.len,
            .attributes = &vtx_attrs,
        }};
        const target = [_]wgpu.ColorTargetState{.{
            .format = rt_format,
            .blend = &blend,
        }};
        const fragment = wgpu.FragmentState{
            .module = module,
            .entryPoint = .{ .data = "fs", .length = 2 },
            .targetCount = target.len,
            .targets = &target,
        };
        // 显式管线布局:layout=null 的自动布局会被 wgpu-native 标为"管线独占",
        // 跟手工建的绑定组布局不兼容——必须显式建管线布局
        const bgls = [_]wgpu.BindGroupLayout{bgl};
        const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(device, &.{
            .bindGroupLayoutCount = bgls.len,
            .bindGroupLayouts = &bgls,
        });
        const pipeline = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .layout = pipeline_layout,
            .vertex = .{
                .module = module,
                .entryPoint = .{ .data = "vs", .length = 2 },
                .bufferCount = vtx_layout.len,
                .buffers = &vtx_layout,
            },
            .primitive = .{ .topology = wgpu.TOPOLOGY_TRIANGLE_LIST },
            .fragment = &fragment,
        });

        const sampler = wgpu.wgpuDeviceCreateSampler(device, &.{});
        const uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BUF_UNIFORM | wgpu.BUF_COPY_DST,
            .size = 16,
        });

        const vtx_cap: usize = 8192;
        const idx_cap: usize = 16384;
        return .{
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,
            .bgl = bgl,
            .sampler = sampler,
            .uniform_buf = uniform_buf,
            .vtx_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{ .usage = wgpu.BUF_VERTEX | wgpu.BUF_COPY_DST, .size = vtx_cap * @sizeOf(zgui.DrawVert) }),
            .vtx_cap = vtx_cap,
            .idx_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{ .usage = wgpu.BUF_INDEX | wgpu.BUF_COPY_DST, .size = idx_cap * @sizeOf(zgui.DrawIdx) }),
            .idx_cap = idx_cap,
            .textures = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.textures.items) |entry| {
            wgpu.wgpuBindGroupRelease(entry.bg);
            wgpu.wgpuTextureViewRelease(entry.view);
            wgpu.wgpuTextureRelease(entry.tex);
            self.alloc.destroy(entry);
        }
        self.textures.deinit(self.alloc);
        wgpu.wgpuRenderPipelineRelease(self.pipeline);
        wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
        wgpu.wgpuBindGroupLayoutRelease(self.bgl);
        wgpu.wgpuSamplerRelease(self.sampler);
        wgpu.wgpuBufferRelease(self.uniform_buf);
        wgpu.wgpuBufferRelease(self.vtx_buf);
        wgpu.wgpuBufferRelease(self.idx_buf);
    }

    /// 每帧:先处理纹理增量队列(1.92 纹理协议),必须在录渲染通道之前
    pub fn updateTextures(self: *Renderer, draw_data: zgui.DrawData) !void {
        if (!draw_data.valid) return;
        const texs = draw_data.textures.items[0..@intCast(draw_data.textures.len)];
        for (texs) |td| {
            switch (td.status) {
                .want_create => try self.createTexture(td),
                .want_updates => self.reuploadTexture(td),
                .want_destroy => if (shouldDestroyTexture(td)) self.destroyTexture(td),
                else => {},
            }
        }
    }

    fn createTexture(self: *Renderer, td: *zgui.TextureData) !void {
        const w: u32 = @intCast(td.width);
        const h: u32 = @intCast(td.height);
        const tex = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .usage = wgpu.TEXUSAGE_TEXTURE_BINDING | wgpu.TEXUSAGE_COPY_DST,
            .size = .{ .width = w, .height = h, .depthOrArrayLayers = 1 },
            .format = wgpu.FORMAT_RGBA8,
        });
        var entry: ?*TexEntry = null;
        errdefer {
            if (entry) |e| {
                wgpu.wgpuBindGroupRelease(e.bg);
                wgpu.wgpuTextureViewRelease(e.view);
                wgpu.wgpuTextureRelease(e.tex);
                self.alloc.destroy(e);
            } else {
                wgpu.wgpuTextureRelease(tex);
            }
        }
        entry = try self.alloc.create(TexEntry);
        const e = entry.?;
        e.* = .{
            .tex = tex,
            .view = wgpu.wgpuTextureCreateView(tex, null),
            .bg = undefined,
            .w = td.width,
            .h = td.height,
        };
        e.bg = self.makeBindGroup(e.view);
        self.upload(e, td.pixels);
        try self.textures.append(self.alloc, e);
        td.backend_user_data = e;
        td.tex_id = @fromBackingInt(@intCast(@intFromPtr(e.bg)));
        td.status = .ok;
    }

    fn reuploadTexture(self: *Renderer, td: *zgui.TextureData) void {
        const entry: *TexEntry = @ptrCast(@alignCast(td.backend_user_data orelse return));
        self.upload(entry, td.pixels);
        td.status = .ok;
    }

    fn destroyTexture(self: *Renderer, td: *zgui.TextureData) void {
        const entry: *TexEntry = @ptrCast(@alignCast(td.backend_user_data orelse return));
        wgpu.wgpuBindGroupRelease(entry.bg);
        wgpu.wgpuTextureViewRelease(entry.view);
        wgpu.wgpuTextureRelease(entry.tex);
        for (self.textures.items, 0..) |e, i| {
            if (e == entry) {
                _ = self.textures.swapRemove(i);
                break;
            }
        }
        self.alloc.destroy(entry);
        td.backend_user_data = null;
        td.tex_id = @fromBackingInt(@intCast(0)); // 1.92 协议:Destroyed 必须双字段清零(TexID+BackendUserData),否则 ImGui 断言
        td.status = .destroyed;
    }

    fn upload(self: *Renderer, entry: *TexEntry, pixels: [*]u8) void {
        const w: u32 = @intCast(entry.w);
        const h: u32 = @intCast(entry.h);
        wgpu.wgpuQueueWriteTexture(self.queue, &.{
            .texture = entry.tex,
        }, @ptrCast(pixels), @as(usize, w * h * 4), &.{
            .bytesPerRow = w * 4,
            .rowsPerImage = h,
        }, &.{ .width = w, .height = h, .depthOrArrayLayers = 1 });
    }

    fn makeBindGroup(self: *Renderer, view: wgpu.TextureView) wgpu.BindGroup {
        const entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.uniform_buf, .size = 16 },
            .{ .binding = 1, .textureView = view },
            .{ .binding = 2, .sampler = self.sampler },
        };
        return wgpu.wgpuDeviceCreateBindGroup(self.device, &.{
            .layout = self.bgl,
            .entryCount = entries.len,
            .entries = &entries,
        });
    }

    /// 录进已开的渲染通道
    pub fn render(self: *Renderer, draw_data: zgui.DrawData, pass: wgpu.RenderPassEncoder) void {
        if (!draw_data.valid) return;
        const dw = draw_data.display_size[0];
        const dh = draw_data.display_size[1];
        if (dw <= 0 or dh <= 0) return;

        // 正交投影只使用逻辑 display_size;framebuffer_scale 仅用于物理 scissor。
        const scale = [2]f32{
            2.0 / dw,
            -2.0 / dh,
        };
        const offset = [2]f32{
            -1.0 - 2.0 * draw_data.display_pos[0] / dw,
            1.0 + 2.0 * draw_data.display_pos[1] / dh,
        };
        const uniform = [4]f32{ scale[0], scale[1], offset[0], offset[1] };
        wgpu.wgpuQueueWriteBuffer(self.queue, self.uniform_buf, 0, &uniform, 16);

        wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);

        // 三遍法:ImGui 一帧有多个 draw list(背景/窗口/前景),
        // 顶点缓冲在 submit 时才生效——逐 list 上传会互相覆盖,必须拼成全局缓冲
        const lists = draw_data.cmd_lists.items[0..@intCast(draw_data.cmd_lists.len)];
        // 一遍:总量
        var total_vtx: usize = 0;
        var total_idx_bytes: usize = 0;
        for (lists) |list| {
            total_vtx += list.getVertexBuffer().len;
            const raw = list.getIndexBuffer().len * @sizeOf(zgui.DrawIdx);
            total_idx_bytes = (total_idx_bytes + raw + 3) & ~@as(usize, 3);
        }
        if (total_vtx == 0 or total_idx_bytes == 0) return;
        self.ensureBuffers(total_vtx, total_idx_bytes / @sizeOf(zgui.DrawIdx));
        // 二遍:每个 list 的索引段都按 4 字节对齐,绘制偏移使用同一布局。
        var vtx_base: u64 = 0;
        var idx_byte_base: u64 = 0;
        for (lists) |list| {
            const vtx = list.getVertexBuffer();
            const idx = list.getIndexBuffer();
            if (vtx.len > 0) {
                wgpu.wgpuQueueWriteBuffer(self.queue, self.vtx_buf, vtx_base * @sizeOf(zgui.DrawVert), vtx.ptr, vtx.len * @sizeOf(zgui.DrawVert));
            }
            if (idx.len > 0) {
                const raw = idx.len * @sizeOf(zgui.DrawIdx);
                const padded = (raw + 3) & ~@as(usize, 3);
                if (padded == raw) {
                    wgpu.wgpuQueueWriteBuffer(self.queue, self.idx_buf, idx_byte_base, idx.ptr, raw);
                } else {
                    const scratch = self.alloc.alloc(u8, padded) catch continue;
                    defer self.alloc.free(scratch);
                    @memcpy(scratch[0..raw], std.mem.sliceAsBytes(idx));
                    @memset(scratch[raw..], 0);
                    wgpu.wgpuQueueWriteBuffer(self.queue, self.idx_buf, idx_byte_base, scratch.ptr, padded);
                }
                idx_byte_base += padded;
            }
            vtx_base += vtx.len;
        }

        wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vtx_buf, 0, total_vtx * @sizeOf(zgui.DrawVert));
        wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, self.idx_buf, wgpu.INDEX_FORMAT_UINT16, 0, total_idx_bytes);

        // 三遍:绘制(cmd 的局部偏移 + list 的全局基址)
        var vtx_global: c_uint = 0;
        var idx_global: u32 = 0;
        for (lists) |list| {
            const cmds = list.getCmdBuffer();
            for (cmds) |cmd| {
                if (cmd.elem_count == 0) continue;
                if (cmd.user_callback) |cb| {
                    if (@intFromPtr(cb) == std.math.maxInt(usize)) continue; // ImDrawCallback_ResetRenderState
                    continue; // 自定义回调不支持
                }
                const scale_x = draw_data.framebuffer_scale[0];
                const scale_y = draw_data.framebuffer_scale[1];
                const x0: f32 = (cmd.clip_rect[0] - draw_data.display_pos[0]) * scale_x;
                const y0: f32 = (cmd.clip_rect[1] - draw_data.display_pos[1]) * scale_y;
                const x1: f32 = (cmd.clip_rect[2] - draw_data.display_pos[0]) * scale_x;
                const y1: f32 = (cmd.clip_rect[3] - draw_data.display_pos[1]) * scale_y;
                const fb_w: f32 = dw * scale_x;
                const fb_h: f32 = dh * scale_y;
                const sx0: i32 = @intFromFloat(@max(0.0, x0));
                const sy0: i32 = @intFromFloat(@max(0.0, y0));
                const sx1: i32 = @intFromFloat(@min(fb_w, x1));
                const sy1: i32 = @intFromFloat(@min(fb_h, y1));
                if (sx1 <= sx0 or sy1 <= sy0) continue;
                wgpu.wgpuRenderPassEncoderSetScissorRect(pass, @intCast(sx0), @intCast(sy0), @intCast(sx1 - sx0), @intCast(sy1 - sy0));

                // 纹理引用两路:tex_id(已建纹的指针值)或 tex_data(首帧现建的 TextureData)
                var bg: ?wgpu.BindGroup = null;
                if (@backingInt(cmd.texture_ref.tex_id) != 0) {
                    bg = @ptrFromInt(@as(usize, @backingInt(cmd.texture_ref.tex_id)));
                } else if (cmd.texture_ref.tex_data) |td| {
                    if (td.backend_user_data) |ud| {
                        const entry: *TexEntry = @ptrCast(@alignCast(ud));
                        bg = entry.bg;
                    }
                }
                if (bg == null) continue; // 纹理未建/已销:跳过
                wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, bg.?, 0, null);
                wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @intCast(cmd.elem_count), 1, @intCast(cmd.idx_offset + idx_global), @as(i32, @intCast(cmd.vtx_offset + vtx_global)), 0);
            }
            vtx_global += @intCast(list.getVertexBufferLength());
            const padded = (@as(usize, @intCast(list.getIndexBufferLength())) * @sizeOf(zgui.DrawIdx) + 3) & ~@as(usize, 3);
            idx_global += @intCast(padded / @sizeOf(zgui.DrawIdx));
        }
    }

    fn ensureBuffers(self: *Renderer, vtx_need: usize, idx_need: usize) void {
        if (vtx_need > self.vtx_cap) {
            self.vtx_cap = vtx_need * 2;
            wgpu.wgpuBufferRelease(self.vtx_buf);
            self.vtx_buf = wgpu.wgpuDeviceCreateBuffer(self.device, &.{ .usage = wgpu.BUF_VERTEX | wgpu.BUF_COPY_DST, .size = self.vtx_cap * @sizeOf(zgui.DrawVert) });
        }
        if (idx_need > self.idx_cap) {
            self.idx_cap = idx_need * 2;
            wgpu.wgpuBufferRelease(self.idx_buf);
            self.idx_buf = wgpu.wgpuDeviceCreateBuffer(self.device, &.{ .usage = wgpu.BUF_INDEX | wgpu.BUF_COPY_DST, .size = self.idx_cap * @sizeOf(zgui.DrawIdx) });
        }
    }
};

test "texture destruction waits for an unused frame" {
    var td = std.mem.zeroes(zgui.TextureData);
    td.status = .want_destroy;
    td.unused_Frames = 0;
    try std.testing.expect(!shouldDestroyTexture(&td));
    td.unused_Frames = 1;
    try std.testing.expect(shouldDestroyTexture(&td));
    td.status = .ok;
    try std.testing.expect(!shouldDestroyTexture(&td));
}
