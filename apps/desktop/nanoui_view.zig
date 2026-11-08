const std = @import("std");
const nanoui = @import("nanoui");
const model = @import("nanoui_model.zig");
const library = @import("nanoui_library");
const palette = @import("palette");

const ui = nanoui.ui;
const Page = model.Page;

pub fn theme() ui.Theme {
    return library.metalTheme();
}

fn navigation(state: *model.State, c: *ui.Context) void {
    ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 8 });
    {
        defer ui.end(c);
        ui.text(c, "◆", .{ .size = 12, .color = .hex(palette.gold) });
        ui.text(c, "CUTRANS", .{ .size = 14, .weight = .bold, .color = c.theme.accent });
        ui.spacer(c);
        inline for (.{
            .{ Page.home, "首页" },
            .{ Page.editor, "编辑器" },
            .{ Page.library, "资源库" },
            .{ Page.console, "CLI" },
            .{ Page.jobs, "任务" },
        }) |item| {
            if (ui.button(c, item[1], .{ .variant = if (state.page == item[0]) .primary else .secondary }).clicked) state.showPage(item[0]);
        }
    }
    ui.divider(c);
}

fn home(state: *model.State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(28), .gap = 18 });
    defer ui.end(c);
    ui.text(c, "声明式 VM 与多域创作工作台", .{ .size = 28, .weight = .bold });
    ui.label(c, "文档、资源和任务由 VM 持有；NanoUI 只负责投影与本地交互。");
    ui.row(c, .{ .width = .fill, .gap = 12 });
    {
        defer ui.end(c);
        ui.column(c, .{ .grow = 1, .padding = .all(18), .gap = 10, .background = c.theme.surface, .border = c.theme.border, .radius = 8 });
        {
            defer ui.end(c);
            ui.text(c, "当前文档", .{ .size = 18, .weight = .semibold });
            ui.textf(c, .{ .color = c.theme.muted }, "revision {d} · {d} 个节点 · {d}×{d}", .{
                state.ctx.document_revision, state.ctx.document.count, state.ctx.document.width, state.ctx.document.height,
            });
            ui.textf(c, .{ .color = c.theme.muted, .mono = true }, "fingerprint {d}", .{state.ctx.document.fingerprint()});
            if (ui.button(c, "打开编辑器", .{ .variant = .primary }).clicked) state.showPage(.editor);
        }
        ui.column(c, .{ .grow = 1, .padding = .all(18), .gap = 10, .background = c.theme.surface, .border = c.theme.border, .radius = 8 });
        {
            defer ui.end(c);
            ui.text(c, "统一工作流", .{ .size = 18, .weight = .semibold });
            ui.label(c, "选择资源 → 编辑预览 → 导出任务 → 关闭 Shell 后继续。");
            if (ui.button(c, "打开资源库", .{}).clicked) state.showPage(.library);
            if (ui.button(c, "查看任务", .{}).clicked) state.showPage(.jobs);
        }
    }
    ui.text(c, "开始", .{ .size = 17, .weight = .semibold });
    ui.row(c, .{ .width = .fill, .gap = 8 });
    {
        defer ui.end(c);
        if (ui.button(c, "编辑当前文档", .{ .variant = .primary }).clicked) state.showPage(.editor);
        if (ui.button(c, "管理素材", .{}).clicked) state.showPage(.library);
        if (ui.button(c, "打开 CLI", .{}).clicked) state.showPage(.console);
    }
    ui.divider(c);
    ui.label(c, "当前闭环：.cut v3、PNG DAG、History、持久 Job、Catalog / Source / Station。真实视频、音频和完整时间轴仍未实现。");
}

pub fn view(state: *model.State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12), .gap = 10 });
    defer ui.end(c);
    navigation(state, c);
    switch (state.page) {
        .home => home(state, c),
        .editor => state.editor.view(c),
        .library => library.view(&state.library, c),
        .console => state.console.consoleView(c),
        .jobs => state.console.jobsView(c),
    }
    if (state.page != .library) ui.text(c, state.ctx.status.get(), .{ .size = 12, .color = c.theme.muted });
}
