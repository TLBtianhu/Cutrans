//! anim.zig — productive motion 属性动画:短反馈、连续 retarget、无过冲
//!
//! 缓动曲线参考 PCL ModAnimation,但参数归 Cutrans 自己的工作型界面:
//!   out_fluent=快入缓停,inout_fluent=同屏连续,out_fluent_initial=带初速度。
//! 时长由 theme 统一声明;不做装饰性循环,也不以动画阻塞输入。
//!
//! 时钟纪律:UI 帧率自报(tick 由主循环每帧喂 dt),不另开系统时钟。
//! 通道=分 map 存储(value=颜色/透明度,scale=按下缩放),同一 id 多属性并行不撞键。

const std = @import("std");
const theme = @import("theme.zig").theme;

pub const Power = enum(u5) { weak = 2, middle = 3, strong = 4, extra_strong = 5 };

pub const Ease = union(enum) {
    linear,
    out_fluent: Power,
    inout_fluent: Power,
    out_fluent_initial: f32,
};

pub fn easeAt(e: Ease, t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return switch (e) {
        .linear => x,
        .out_fluent => |p| 1 - std.math.pow(f32, 1 - x, @floatFromInt(@backingInt(p))),
        .inout_fluent => |p| blk: {
            const pw: f32 = @floatFromInt(@backingInt(p));
            if (x < 0.5) break :blk std.math.pow(f32, 2 * x, pw) / 2;
            break :blk 1 - std.math.pow(f32, 2 * (1 - x), pw) / 2;
        },
        .out_fluent_initial => |a| if (a <= 0) x else (a + 1) * x / (1 + a * x),
    };
}

const Anim = struct {
    from: f32,
    target: f32,
    t: f32, // 已进行秒
    dur: f32, // 总时长秒
    ease: Ease,
};

var value_map: std.StringHashMap(Anim) = undefined; // 颜色/透明度通道
var scale_map: std.StringHashMap(Anim) = undefined; // 缩放通道
var allocator: ?std.mem.Allocator = null;
var clock: f32 = 0;
var dt_frame: f32 = 1.0 / 60.0;

pub fn init(alloc: std.mem.Allocator) void {
    if (allocator != null) deinit();
    allocator = alloc;
    value_map = std.StringHashMap(Anim).init(alloc);
    scale_map = std.StringHashMap(Anim).init(alloc);
    clock = 0;
    dt_frame = 1.0 / 60.0;
}

fn deinitMap(map: *std.StringHashMap(Anim), alloc: std.mem.Allocator) void {
    var it = map.keyIterator();
    while (it.next()) |key| alloc.free(key.*);
    map.deinit();
}

pub fn deinit() void {
    const alloc = allocator orelse return;
    deinitMap(&value_map, alloc);
    deinitMap(&scale_map, alloc);
    allocator = null;
}

/// 每帧一次(主循环喂):统一推进所有通道,绘制次数不再改变动画速度。
pub fn tick(dt: f32) void {
    dt_frame = @min(0.05, dt);
    clock += dt_frame;
    var value_it = value_map.valueIterator();
    while (value_it.next()) |a| a.t += dt_frame;
    var scale_it = scale_map.valueIterator();
    while (scale_it.next()) |a| a.t += dt_frame;
}

pub fn now() f32 {
    return clock;
}

fn valueAt(a: Anim) f32 {
    if (a.dur <= 0) return a.target;
    const k = easeAt(a.ease, a.t / a.dur);
    return a.from + (a.target - a.from) * k;
}

/// 读当前值,不推进(画笔在绘制前取)
pub fn peek(map: *std.StringHashMap(Anim), id: [:0]const u8, default: f32) f32 {
    const a = map.get(id) orelse return default;
    return valueAt(a);
}

/// 推进/改目标(画笔在绘制后喂):目标变了从当前值起新段,运动惯性不被打断
pub fn drive(map: *std.StringHashMap(Anim), id: [:0]const u8, target: f32, dur_ms: f32, ease: Ease) void {
    const alloc = allocator orelse return;
    const gop = map.getOrPut(id) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = alloc.dupe(u8, id) catch {
            _ = map.remove(id);
            return;
        };
        gop.value_ptr.* = .{ .from = target, .target = target, .t = 0, .dur = dur_ms / 1000, .ease = ease };
        return;
    }
    const a = gop.value_ptr;
    if (a.target != target) {
        a.* = .{ .from = valueAt(a.*), .target = target, .t = 0, .dur = dur_ms / 1000, .ease = ease };
    }
}

// ════ PCL 控件语义封装 ════

/// 悬停值(画笔用):0..1
pub fn hoverPeek(id: [:0]const u8) f32 {
    return peek(&value_map, id, 0);
}
/// 悬停驱动:PCL 时长表——进 120ms(middle),出 150ms(weak)
/// (MyIconButton AnimationColorIn=120/Out=150;MyComboBoxItem 100/300 取中间值)
pub fn hoverDrive(id: [:0]const u8, hovered: bool) void {
    if (hovered)
        drive(&value_map, id, 1, theme.hover_in_ms, .{ .out_fluent = .middle })
    else
        drive(&value_map, id, 0, theme.hover_out_ms, .{ .out_fluent = .weak });
}

/// 按下缩放值(画笔用):1=原大,press_scale=按下(克制反馈)
pub fn scalePeek(id: [:0]const u8) f32 {
    return peek(&scale_map, id, 1);
}
/// 按下驱动:压 80ms(extra_strong),松开 140ms(middle),无过冲回弹
pub fn scaleDrive(id: [:0]const u8, pressed: bool) void {
    if (pressed)
        drive(&scale_map, id, theme.press_scale, theme.press_ms, .{ .out_fluent = .extra_strong })
    else
        drive(&scale_map, id, 1, theme.release_ms, .{ .out_fluent = .middle });
}

test "easing clamps endpoints and stays continuous" {
    try std.testing.expectEqual(@as(f32, 0), easeAt(.{ .out_fluent = .strong }, -1));
    try std.testing.expectEqual(@as(f32, 1), easeAt(.{ .out_fluent = .strong }, 2));
    try std.testing.expectEqual(@as(f32, 0.5), easeAt(.{ .inout_fluent = .middle }, 0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), easeAt(.{ .out_fluent_initial = 1 }, 0.5), 0.0001);
}

test "animation keys are owned after the caller buffer changes" {
    init(std.testing.allocator);
    defer deinit();
    var buf: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "button", .{}) catch unreachable;
    hoverDrive(id, true);
    buf[0] = 'X';
    try std.testing.expectEqual(@as(f32, 1), hoverPeek("button"));
    try std.testing.expectEqual(@as(usize, 1), value_map.count());
}

test "animation clock resets and clamps long frames" {
    init(std.testing.allocator);
    defer deinit();
    tick(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), now(), 0.0001);
    try std.testing.expectEqual(@as(f32, 140), theme.release_ms);
    try std.testing.expectEqual(@as(f32, 0.98), theme.press_scale);
    try std.testing.expectEqual(@as(f32, 6), theme.view_rise);
}
