//! wgpu.zig — wgpu-native v29 的呈现层 extern 薄封装(窗口表面 + 渲染通路)
//!
//! 只封装 launcher 需要的最小面:实例/表面/适配器/设备/队列/编码器/呈现。
//! 全部是 extern C 直声明,零包装——webgpu.h 是唯一的真源。

pub const StringView = extern struct { data: ?[*]const u8 = null, length: usize = 0 };
pub const Chained = extern struct { next: ?*Chained, sType: u32 };

pub const Instance = *opaque {};
pub const Surface = *opaque {};
pub const Adapter = *opaque {};
pub const Device = *opaque {};
pub const Queue = *opaque {};
pub const Texture = *opaque {};
pub const TextureView = *opaque {};
pub const CommandEncoder = *opaque {};
pub const RenderPassEncoder = *opaque {};
pub const CommandBuffer = *opaque {};

pub const FORMAT_BGRA8: u32 = 0x1B;
pub const USAGE_RENDER_ATTACHMENT: u64 = 0x10;
pub const PRESENT_FIFO: u32 = 1;
pub const LOAD_CLEAR: u32 = 2;
pub const STORE_STORE: u32 = 1;
pub const STYPE_SURFACE_HWND: u32 = 5;
pub const CB_PROCESS_EVENTS: u32 = 2;

pub const SurfaceSourceWindowsHWND = extern struct {
    chain: Chained,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};

pub const SurfaceDescriptor = extern struct { chain: ?*Chained, label: StringView };

pub const SurfaceConfiguration = extern struct {
    chain: ?*Chained = null,
    device: Device,
    format: u32,
    usage: u64 = USAGE_RENDER_ATTACHMENT,
    width: u32,
    height: u32,
    viewFormatCount: usize = 0,
    viewFormats: ?*const anyopaque = null,
    alphaMode: u32 = 0, // Auto
    presentMode: u32 = PRESENT_FIFO,
};

pub const STATUS_SUCCESS: u32 = 1;
pub const SURFACE_SUCCESS_OPTIMAL: u32 = 1;
pub const SURFACE_SUCCESS_SUBOPTIMAL: u32 = 2;

pub const SurfaceTexture = extern struct {
    chain: ?*Chained = null,
    texture: ?Texture = null,
    status: u32 = 0,
};

pub const Color = extern struct { r: f64, g: f64, b: f64, a: f64 };

pub const RenderPassColorAttachment = extern struct {
    chain: ?*Chained = null,
    view: TextureView,
    depthSlice: u32 = 0xFFFFFFFF, // WGPU_DEPTH_SLICE_UNDEFINED
    resolveTarget: ?*anyopaque = null,
    loadOp: u32,
    storeOp: u32,
    clearValue: Color,
};

pub const RenderPassDescriptor = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    colorAttachmentCount: usize,
    colorAttachments: ?[*]const RenderPassColorAttachment,
    depthStencilAttachment: ?*const anyopaque = null,
    occlusionQuerySet: ?*const anyopaque = null,
    timestampWrites: ?*const anyopaque = null,
};

pub const AdapterCb = *const fn (u32, Adapter, StringView, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const DeviceCb = *const fn (u32, Device, StringView, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const QueueDescriptor = extern struct { chain: ?*Chained = null, label: StringView = .{} };
pub const DeviceLostCallback = *const fn (Device, u32, StringView, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const UncapturedErrorCallback = *const fn (Device, u32, StringView, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const DeviceLostCallbackInfo = extern struct {
    chain: ?*Chained = null,
    mode: u32,
    callback: ?DeviceLostCallback = null,
    ud1: ?*anyopaque = null,
    ud2: ?*anyopaque = null,
};
pub const UncapturedErrorCallbackInfo = extern struct {
    callback: ?UncapturedErrorCallback = null,
    ud1: ?*anyopaque = null,
    ud2: ?*anyopaque = null,
};
pub const DeviceDescriptor = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    requiredFeatureCount: usize = 0,
    requiredFeatures: ?*const anyopaque = null,
    requiredLimits: ?*const anyopaque = null,
    defaultQueue: QueueDescriptor = .{},
    deviceLostCallbackInfo: DeviceLostCallbackInfo,
    uncapturedErrorCallbackInfo: UncapturedErrorCallbackInfo,
};
pub const CbInfo = extern struct { chain: ?*Chained = null, mode: u32, callback: *const anyopaque, ud1: ?*anyopaque = null, ud2: ?*anyopaque = null };
pub const RequestAdapterOptions = extern struct {
    chain: ?*Chained = null,
    featureLevel: u32 = 0, // Undefined
    powerPreference: u32 = 0, // Undefined
    forceFallbackAdapter: u32 = 0,
    backendType: u32 = 0, // Undefined
    compatibleSurface: ?Surface = null,
};

pub extern fn wgpuCreateInstance(?*const anyopaque) Instance;
pub extern fn wgpuInstanceRequestAdapter(Instance, ?*const anyopaque, CbInfo) u64;
pub extern fn wgpuAdapterRequestDevice(Adapter, ?*const anyopaque, CbInfo) u64;
pub extern fn wgpuInstanceProcessEvents(Instance) void;
pub extern fn wgpuInstanceCreateSurface(Instance, *const SurfaceDescriptor) Surface;
pub extern fn wgpuDeviceGetQueue(Device) Queue;
pub extern fn wgpuSurfaceConfigure(Surface, *const SurfaceConfiguration) void;
pub extern fn wgpuSurfaceGetCurrentTexture(Surface, *SurfaceTexture) void;
pub extern fn wgpuSurfacePresent(Surface) u32;
pub extern fn wgpuSurfaceRelease(Surface) void;
pub extern fn wgpuQueueRelease(Queue) void;
pub extern fn wgpuDeviceRelease(Device) void;
pub extern fn wgpuAdapterRelease(Adapter) void;
pub extern fn wgpuInstanceRelease(Instance) void;
pub extern fn wgpuTextureCreateView(Texture, ?*const anyopaque) TextureView;
pub extern fn wgpuTextureRelease(Texture) void;
pub extern fn wgpuTextureViewRelease(TextureView) void;
pub extern fn wgpuDeviceCreateCommandEncoder(Device, ?*const anyopaque) CommandEncoder;
pub extern fn wgpuCommandEncoderBeginRenderPass(CommandEncoder, *const RenderPassDescriptor) RenderPassEncoder;
pub extern fn wgpuRenderPassEncoderEnd(RenderPassEncoder) void;
pub extern fn wgpuRenderPassEncoderRelease(RenderPassEncoder) void;
pub extern fn wgpuCommandEncoderFinish(CommandEncoder, ?*const anyopaque) CommandBuffer;
pub extern fn wgpuCommandBufferRelease(CommandBuffer) void;
pub extern fn wgpuCommandEncoderRelease(CommandEncoder) void;
pub extern fn wgpuQueueSubmit(Queue, usize, *const CommandBuffer) void;

// ── 渲染管线/纹理/缓冲(自写 ImGui 渲染器用) ──
pub const ShaderModule = *opaque {};
pub const RenderPipeline = *opaque {};
pub const PipelineLayout = *opaque {};
pub const BindGroupLayout = *opaque {};
pub const BindGroup = *opaque {};
pub const Buffer = *opaque {};
pub const Sampler = *opaque {};

pub const STYPE_WGSL: u32 = 2;
pub const BUF_VERTEX: u64 = 0x20;
pub const BUF_INDEX: u64 = 0x10;
pub const BUF_UNIFORM: u64 = 0x40;
pub const BUF_COPY_DST: u64 = 0x08;
pub const TEXUSAGE_COPY_DST: u64 = 0x02;
pub const TEXUSAGE_TEXTURE_BINDING: u64 = 0x04;
pub const TEXDIM_2D: u32 = 0x02; // 不是 1!v29: 1D=1, 2D=2, 3D=3
pub const FORMAT_RGBA8: u32 = 0x16;
pub const STAGE_VERTEX: u64 = 1;
pub const STAGE_FRAGMENT: u64 = 2;
pub const VERTEX_FORMAT_FLOAT32x2: u32 = 0x1D;
pub const VERTEX_FORMAT_UNORM8x4: u32 = 0x09;
pub const TOPOLOGY_TRIANGLE_LIST: u32 = 4;
pub const INDEX_FORMAT_UINT16: u32 = 1;
pub const CULL_NONE: u32 = 1;
pub const FRONTFACE_CCW: u32 = 1;
pub const BLEND_OP_ADD: u32 = 1;
pub const BLEND_SRC_ALPHA: u32 = 5;
pub const BLEND_ONE_MINUS_SRC_ALPHA: u32 = 6;
pub const BLEND_ONE: u32 = 2;
pub const WRITE_MASK_ALL: u64 = 0xF;
pub const FILTER_LINEAR: u32 = 2;
pub const MIPMAP_NEAREST: u32 = 1;
pub const ADDRESS_CLAMP: u32 = 1;
pub const COMPARE_UNDEFINED: u32 = 0;
pub const BIND_BUFFER_UNIFORM: u32 = 2;
pub const BIND_SAMPLER_FILTERING: u32 = 2;
pub const BIND_TEXTURE_FLOAT: u32 = 2;
pub const VIEW_DIM_2D: u32 = 2;
pub const ASPECT_ALL: u32 = 1;

pub const BufferDesc = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    usage: u64,
    size: u64,
    mapped: u32 = 0,
};
pub const ShaderSourceWGSL = extern struct { chain: Chained, code: StringView };
pub const ShaderModuleDesc = extern struct { chain: ?*Chained = null, label: StringView = .{} };
pub const VertexAttribute = extern struct { chain: ?*Chained = null, format: u32, offset: u64, shaderLocation: u32 };
pub const VertexBufferLayout = extern struct {
    chain: ?*Chained = null,
    stepMode: u32 = 0, // vertex
    arrayStride: u64,
    attributeCount: usize,
    attributes: [*]const VertexAttribute,
};
pub const VertexState = extern struct {
    chain: ?*Chained = null,
    module: ShaderModule,
    entryPoint: StringView,
    constantCount: usize = 0,
    constants: ?*const anyopaque = null,
    bufferCount: usize,
    buffers: ?[*]const VertexBufferLayout,
};
pub const PrimitiveState = extern struct {
    chain: ?*Chained = null,
    topology: u32,
    stripIndexFormat: u32 = 0,
    frontFace: u32 = FRONTFACE_CCW,
    cullMode: u32 = CULL_NONE,
    unclippedDepth: u32 = 0,
};
pub const MultisampleState = extern struct {
    chain: ?*Chained = null,
    count: u32 = 1,
    mask: u32 = 0xFFFFFFFF,
    alphaToCoverageEnabled: u32 = 0,
};
pub const BlendComponent = extern struct { operation: u32, srcFactor: u32, dstFactor: u32 };
pub const BlendState = extern struct { color: BlendComponent, alpha: BlendComponent };
pub const ColorTargetState = extern struct {
    chain: ?*Chained = null,
    format: u32,
    blend: ?*const BlendState,
    writeMask: u64 = WRITE_MASK_ALL,
};
pub const FragmentState = extern struct {
    chain: ?*Chained = null,
    module: ShaderModule,
    entryPoint: StringView,
    constantCount: usize = 0,
    constants: ?*const anyopaque = null,
    targetCount: usize,
    targets: [*]const ColorTargetState,
};
pub const RenderPipelineDesc = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    layout: ?PipelineLayout = null,
    vertex: VertexState,
    primitive: PrimitiveState,
    depthStencil: ?*const anyopaque = null,
    multisample: MultisampleState = .{},
    fragment: ?*const FragmentState,
};
pub const BufferBindingLayout = extern struct { chain: ?*Chained = null, type: u32 = 0, hasDynamicOffset: u32 = 0, minBindingSize: u64 = 0 };
pub const SamplerBindingLayout = extern struct { chain: ?*Chained = null, type: u32 = 0 };
pub const TextureBindingLayout = extern struct { chain: ?*Chained = null, sampleType: u32 = 0, viewDimension: u32 = 0, multisampled: u32 = 0 };
pub const StorageTextureBindingLayout = extern struct { chain: ?*Chained = null, access: u32 = 0, format: u32 = 0, viewDimension: u32 = 0 };
pub const BindGroupLayoutEntry = extern struct {
    chain: ?*Chained = null,
    binding: u32,
    visibility: u64,
    bindingArraySize: u32 = 0,
    buffer: BufferBindingLayout = .{},
    sampler: SamplerBindingLayout = .{},
    texture: TextureBindingLayout = .{},
    storageTexture: StorageTextureBindingLayout = .{},
};
pub const BindGroupLayoutDesc = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    entryCount: usize,
    entries: [*]const BindGroupLayoutEntry,
};
pub const PipelineLayoutDesc = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    bindGroupLayoutCount: usize,
    bindGroupLayouts: [*]const BindGroupLayout,
    immediateSize: u32 = 0,
};
pub const BindGroupEntry = extern struct {
    chain: ?*Chained = null,
    binding: u32,
    buffer: ?Buffer = null,
    offset: u64 = 0,
    size: u64 = 0,
    sampler: ?Sampler = null,
    textureView: ?TextureView = null,
};
pub const BindGroupDesc = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    layout: BindGroupLayout,
    entryCount: usize,
    entries: [*]const BindGroupEntry,
};
pub const SamplerDesc = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    addressModeU: u32 = ADDRESS_CLAMP,
    addressModeV: u32 = ADDRESS_CLAMP,
    addressModeW: u32 = ADDRESS_CLAMP,
    magFilter: u32 = FILTER_LINEAR,
    minFilter: u32 = FILTER_LINEAR,
    mipmapFilter: u32 = MIPMAP_NEAREST,
    lodMinClamp: f32 = 0,
    lodMaxClamp: f32 = 1,
    compare: u32 = COMPARE_UNDEFINED,
    maxAnisotropy: u16 = 1,
};
pub const Extent3D = extern struct { width: u32, height: u32, depthOrArrayLayers: u32 };
pub const Origin3D = extern struct { x: u32 = 0, y: u32 = 0, z: u32 = 0 };
pub const TextureDesc = extern struct {
    chain: ?*Chained = null,
    label: StringView = .{},
    usage: u64,
    dimension: u32 = TEXDIM_2D,
    size: Extent3D,
    format: u32,
    mipLevelCount: u32 = 1,
    sampleCount: u32 = 1,
    viewFormatCount: usize = 0,
    viewFormats: ?*const anyopaque = null,
};
pub const TexelCopyTextureInfo = extern struct {
    texture: Texture,
    mipLevel: u32 = 0,
    origin: Origin3D = .{},
    aspect: u32 = ASPECT_ALL,
};
pub const TexelCopyBufferLayout = extern struct { offset: u64 = 0, bytesPerRow: u32, rowsPerImage: u32 };

pub extern fn wgpuDeviceCreateShaderModule(Device, *const ShaderModuleDesc) ShaderModule;
pub extern fn wgpuDeviceCreateRenderPipeline(Device, *const RenderPipelineDesc) RenderPipeline;
pub extern fn wgpuDeviceCreateBindGroupLayout(Device, *const BindGroupLayoutDesc) BindGroupLayout;
pub extern fn wgpuDeviceCreatePipelineLayout(Device, *const PipelineLayoutDesc) PipelineLayout;
pub extern fn wgpuDeviceCreateBindGroup(Device, *const BindGroupDesc) BindGroup;
pub extern fn wgpuDeviceCreateBuffer(Device, *const BufferDesc) Buffer;
pub extern fn wgpuDeviceCreateTexture(Device, *const TextureDesc) Texture;
pub extern fn wgpuDeviceCreateSampler(Device, *const SamplerDesc) Sampler;
pub extern fn wgpuQueueWriteBuffer(Queue, Buffer, u64, *const anyopaque, usize) void;
pub extern fn wgpuQueueWriteTexture(Queue, *const TexelCopyTextureInfo, *const anyopaque, usize, *const TexelCopyBufferLayout, *const Extent3D) void;
pub extern fn wgpuRenderPassEncoderSetPipeline(RenderPassEncoder, RenderPipeline) void;
pub extern fn wgpuRenderPassEncoderSetBindGroup(RenderPassEncoder, u32, BindGroup, usize, ?*const u32) void;
pub extern fn wgpuRenderPassEncoderSetVertexBuffer(RenderPassEncoder, u32, Buffer, u64, u64) void;
pub extern fn wgpuRenderPassEncoderSetIndexBuffer(RenderPassEncoder, Buffer, u32, u64, u64) void;
pub extern fn wgpuRenderPassEncoderSetScissorRect(RenderPassEncoder, u32, u32, u32, u32) void;
pub extern fn wgpuRenderPassEncoderDrawIndexed(RenderPassEncoder, u32, u32, u32, i32, u32) void;
pub extern fn wgpuRenderPassEncoderDraw(RenderPassEncoder, u32, u32, u32, u32) void;
pub extern fn wgpuBufferRelease(Buffer) void;
pub extern fn wgpuSamplerRelease(Sampler) void;
pub extern fn wgpuBindGroupRelease(BindGroup) void;
pub extern fn wgpuBindGroupLayoutRelease(BindGroupLayout) void;
pub extern fn wgpuRenderPipelineRelease(RenderPipeline) void;
pub extern fn wgpuPipelineLayoutRelease(PipelineLayout) void;
pub extern fn wgpuShaderModuleRelease(ShaderModule) void;
