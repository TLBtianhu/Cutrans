# 2026-11-10 Shell 命令边界

本片把命令队列从 Runtime 私有模块提升为 `vne.command`：它是 VM/Shell 共享的协议级帧队列，不再是 Runtime 内部实现。

## 改动

- `runtime/command.zig` 移到 `vne/command.zig`，只依赖 `vne.workspace`。
- `vne/root.zig` 导出 `command`；`runtime/root.zig` 继续 re-export，旧 `runtime.command` 调用保持兼容。
- Runtime 内部改为 `@import("vne").command`。
- Shell 侧：
  - `consoles/gui/vm_client.zig` 的 command 类型改用 `vne.command`；
  - `apps/desktop/nanoui.zig`、`apps/editor/nanoui.zig` 的 Result 类型改用 `vne.command`；
  - `apps/desktop/nanoui.zig` 不再直接导入 `runtime`，PNG 尺寸检查经 `vm_client.imageDimensions`。
- 命令队列语义、帧边界、32 项容量、expected stamp 冻结逻辑不变。

## 验证

- `build test`：退出 0，`developer-b12cd3d952ca4e18/`（含 command 队列测试）。
- `verify-payload`：退出 0，`developer-55e9d6bd178a/`。
- `build portable-single`：退出 0，`developer-fd247f819abe/`。
- `verify-single-exe`：退出 0，`developer-0605a3df9bfe/`；`installed_context=1`。
- `build installer`：退出 0，`developer-60c96272e343/`。
- `verify-installer-artifact`：退出 0，`developer-f6f2c8fcccab/`。
- `verify-repository`：退出 0，`developer-8340f4abe9c5/`，selected=746、required=750、markdown=86、local_links=273。

## 仍未改变

- `apps/desktop/nanoui_model.zig`、`consoles/gui/vm_client.zig`、`apps/editor` 仍持有 `RuntimeContext`、`runtime.documents`/`render`/`image`；Shell 还没有完全退化为纯 ABI 投影。
- 命令 RPC 仍无持久化 exactly-once；save/旧命令受管理收口、Host 自动重连未做。
- 本片是模块边界移动，不改变 ABI、协议字节或产品行为。
- 未提交、未推送、未发布。
