//! node.zig — 排版引擎:声明树 → measure/arrange 的单趟走树
//!
//! 分层地位:视图声明经 view.zig 物化为 Node 树,**游标数学的唯一合法居所是本文件**。
//! WPF 对照:Node=XAML 元素;vstack/hstack=StackPanel;card=Border;space=Margin。
//! measure/arrange 合流:宽度自顶向下给定,高度"先量后落"(card 等容器需要先量)。
//! 每帧重建整棵树=立即模式语义,保留模式语法。

const std = @import("std");
const zgui = @import("zgui");
const w = @import("widgets.zig");
const paint = @import("paint.zig");
const theme = @import("theme.zig").theme;
const RuntimeContext = @import("runtime").context.Context;

/// 控件行为:null=无动作;字符串=命令名。导航也由外壳或命令处理,不在节点里特判。
pub const Action = ?[:0]const u8;

pub const Align = enum { start, center, end };
pub const ButtonKind = enum { primary, secondary, ghost, launch, destructive };

pub const Node = union(enum) {
    text: Text,
    button: Button,
    list_item: ListItem,
    input: Input,
    card: Card,
    vstack: Stack,
    hstack: Stack,
    space: f32,
    custom: Custom,
};

pub const Text = struct {
    s: [:0]const u8,
    color: [4]f32 = theme.text,
    halign: Align = .start,
    size: f32 = 0, // 0=默认;字号角色见 theme.zig 的 f_*
};
pub const Button = struct {
    id: [:0]const u8,
    label: [:0]const u8,
    kind: ButtonKind = .secondary,
    h: f32 = theme.button_h,
    sub: [:0]const u8 = "", // launch 种的第二行(版本/制式小字)
    action: Action = null,
};
pub const ListItem = struct {
    id: [:0]const u8,
    icon: [:0]const u8,
    title: [:0]const u8,
    info: [:0]const u8, // 空串=单行 42px;非空=双行 56px(标题+灰信息)
    selected: bool = false,
    action: Action = null,
};
pub const Input = struct { id: [:0]const u8, hint: [:0]const u8, buf: [:0]u8 };
pub const Card = struct {
    id: [:0]const u8,
    pad: f32 = theme.g3,
    w: ?f32 = null, // null=撑满容器;给定则水平居中
    h: ?f32 = null, // null=按内容量
    children: []const Node,
};
pub const Stack = struct { gap: f32 = theme.g2, margin: f32 = 0, children: []const Node };
pub const Custom = struct { h: f32, draw: *const fn (x: f32, y: f32, width: f32) void };

/// 走树上下文:当前容器的内容矩形(x,y,width)。导航与命令处理在树外。
pub const Ctx = struct {
    x: f32,
    y: f32,
    width: f32,
    runtime: ?*RuntimeContext = null,
};

fn dispatch(ctx: *Ctx, a: Action) void {
    if (a) |text| {
        const separator = std.mem.indexOfAny(u8, text, " \t");
        const name = if (separator) |at| text[0..at] else text;
        const arg = if (separator) |at| std.mem.trim(u8, text[at..], " \t") else null;
        if (ctx.runtime) |runtime| _ = runtime.command.dispatch(.{ .name = name, .arg = arg });
    }
}

/// measure:给定宽度量高度(WPF Measure 的垂直版;文本按字形实测)
pub fn measure(node: Node, width: f32) f32 {
    return switch (node) {
        .text => |t| (if (t.size > 0) t.size else zgui.getFontSize()) * 1.35,
        .button => |b| b.h,
        .list_item => |li| if (li.info.len > 0) theme.list_double + theme.list_tail else theme.list_single + theme.list_tail,
        // 输入框按真实框高量:字号 + ImGui 默认 FramePadding.y(3)×2 + 呼吸边。
        // (不读 getStyle():zgui 的 Style.colors 有 0.17 不兼容的 comptime 表达式,
        //  字段访问会触发全结构解析——懒编译陷阱,要读先修 vendored 源码)
        .input => zgui.getFontSize() + theme.input_extra,
        .space => |v| v,
        .vstack => |s| blk: {
            const inner = width - 2 * s.margin;
            var sum: f32 = 0;
            for (s.children, 0..) |child, i| {
                sum += measure(child, inner);
                if (i + 1 < s.children.len) sum += s.gap;
            }
            break :blk sum;
        },
        .hstack => |s| blk: {
            const inner = width - 2 * s.margin;
            var mx: f32 = 0;
            for (s.children) |child| mx = @max(mx, measure(child, inner));
            break :blk mx;
        },
        .card => |cd| cd.h orelse blk: {
            const inner = (cd.w orelse width) - 2 * cd.pad;
            var sum: f32 = 0;
            for (cd.children, 0..) |child, i| {
                sum += measure(child, inner);
                if (i + 1 < cd.children.len) sum += theme.g2;
            }
            break :blk sum + 2 * cd.pad;
        },
        .custom => |c| c.h,
    };
}

/// arrange+绘制:在 ctx 给定的位置落笔
pub fn render(ctx: *Ctx, node: Node) void {
    switch (node) {
        .text => |t| {
            paint.pushFontSize(t.size);
            const tw = zgui.calcTextSize(t.s, .{})[0];
            const tx = switch (t.halign) {
                .start => ctx.x,
                .center => ctx.x + @max(0, (ctx.width - tw) / 2),
                .end => ctx.x + @max(0, ctx.width - tw),
            };
            zgui.setCursorPos(.{ tx, ctx.y });
            zgui.textColored(t.color, "{s}", .{t.s});
            paint.popFontSize(t.size);
        },
        .button => |b| {
            zgui.setCursorPos(.{ ctx.x, ctx.y });
            const clicked = switch (b.kind) {
                .primary => w.primaryButton(b.id, b.label, ctx.width, b.h),
                .secondary => w.secondaryButton(b.id, b.label, ctx.width, b.h),
                .ghost => w.ghostButton(b.id, b.label, ctx.width, b.h),
                .launch => w.launchButton(b.id, b.label, b.sub, ctx.width, b.h),
                .destructive => w.destructiveButton(b.id, b.label, ctx.width, b.h),
            };
            if (clicked) dispatch(ctx, b.action);
        },
        .list_item => |li| {
            zgui.setCursorPos(.{ ctx.x, ctx.y });
            if (w.listItem(li.id, li.icon, li.title, li.info, li.selected, ctx.width)) dispatch(ctx, li.action);
        },
        .input => |inp| {
            zgui.setCursorPos(.{ ctx.x, ctx.y });
            const sp = zgui.getCursorScreenPos(); // 框的屏幕左上角(IME 锚点用)
            // ImGui 铁律:id 不带 ## 前缀的部分会当可见标签画在框右侧(会甩到窗口边缘)
            var label_buf: [80]u8 = undefined;
            const label_s = std.fmt.bufPrint(label_buf[0..], "##{s}", .{inp.id}) catch {
                std.debug.print("[cui] 输入 id 超过缓冲区,已跳过该控件\n", .{});
                return;
            };
            label_buf[label_s.len] = 0;
            const label: [:0]const u8 = label_buf[0..label_s.len :0];
            zgui.pushItemWidth(ctx.width);
            _ = zgui.inputTextWithHint(label, .{ .hint = inp.hint, .buf = inp.buf });
            zgui.popItemWidth();
            // 输入激活时上报锚点(框左下缘外 4px——候选窗落位的标准位置)
            if (zgui.isItemActive()) paint.ime_anchor = .{ sp[0] + 4, sp[1] + zgui.getFontSize() + 18 };
        },
        .space => {},
        .card => |cd| {
            const cw = cd.w orelse ctx.width;
            const cx = if (cd.w != null) ctx.x + @max(0, (ctx.width - cw) / 2) else ctx.x;
            zgui.setCursorPos(.{ cx, ctx.y });
            if (w.cardBegin(cd.id, cw, measure(node, cw))) {
                var cctx = Ctx{ .x = cd.pad, .y = cd.pad, .width = cw - 2 * cd.pad, .runtime = ctx.runtime };
                for (cd.children) |child| {
                    render(&cctx, child);
                    cctx.y += measure(child, cctx.width) + theme.g2;
                }
            }
            w.cardEnd();
        },
        .vstack => |s| {
            var cctx = Ctx{ .x = ctx.x + s.margin, .y = ctx.y, .width = ctx.width - 2 * s.margin, .runtime = ctx.runtime };
            for (s.children) |child| {
                render(&cctx, child);
                cctx.y += measure(child, cctx.width) + s.gap;
            }
        },
        .hstack => |s| {
            if (s.children.len == 0) return;
            const inner = ctx.width - 2 * s.margin;
            const count: f32 = @floatFromInt(s.children.len);
            const share = (inner - s.gap * (count - 1)) / count; // 均分(WPF 列 1* 的横版)
            var cctx = Ctx{ .x = ctx.x + s.margin, .y = ctx.y, .width = share };
            for (s.children) |child| {
                render(&cctx, child);
                cctx.x += share + s.gap;
            }
        },
        .custom => |c| c.draw(ctx.x, ctx.y, ctx.width),
    }
}

/// 页面根:从 ctx 位置流式排完整棵树,返回占用总高
pub fn layout(ctx: *Ctx, root: Node) f32 {
    render(ctx, root);
    return measure(root, ctx.width);
}
