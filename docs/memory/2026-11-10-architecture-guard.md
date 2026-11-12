# 2026-11-10 架构边界守卫

本片把 Shell/VM 分层从“口头约定”变成可执行检查：`verify-architecture` 扫描第一方 Zig 源文件的直接模块导入，拒绝跨层依赖。

## 规则

```text
vne        -> 不可导入 runtime/host/bootstrap/apps/shell/consoles
runtime    -> 不可导入 host/bootstrap/apps/nanoui/consoles
apps       -> 不可导入 runtime/host/bootstrap
shell      -> 不可导入 runtime/host/bootstrap
host       -> 不可导入 apps/nanoui/bootstrap
bootstrap  -> 不可导入 apps/nanoui
consoles/gui/vm_client.zig -> 不可导入 runtime/host/bootstrap
consoles/cli/nanoui.zig -> 不可导入 runtime/host/bootstrap
```

`consoles/gui/vm_client.zig` 仍是允许的 Shell 侧 Runtime 适配层，不在扫描的 `apps`/`shell` 层内。

## 实现

- 新增 `tools/verify_architecture.py`：读取各层 `*.zig`，匹配 `@import("...")`，按上表拒绝；输出
  `CUTRANS_ARCHITECTURE_OK layers=6 shell_runtime_leak=0`。
- `build.zig` 新增 `verify-architecture` 步骤，经统一隐藏 runner 执行。
- `build.zig.zon` 收录新工具。
- [building.md](../development/building.md) 加入该目标。

## 验证

- `build verify-architecture`：退出 0，`developer-2ca29f68f1f8/`。
- `build test` / payload / single / installer 结果见本轮最终记录；本片只加边界检查，不改变运行时行为。
- `verify-repository`：退出 0，`developer-26275c218efe/`，selected=752、required=756、markdown=89、local_links=283。

## 边界

- 这是**直接 `@import` 扫描**，不是 Zig 模块图证明：相对路径导入、别名间接依赖、generated import 仍可能绕过。
- 当前扫描只覆盖第一方层，不覆盖 vendor、`tools/` 脚本和测试注入。
- `vm_client` 仍是 Runtime 适配器；真正的纯 ABI Shell 仍需 preview 帧 ABI 和 RuntimeContext 拆分。
- 未提交、未推送、未发布。
