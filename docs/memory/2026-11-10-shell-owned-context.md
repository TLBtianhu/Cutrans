# 2026-11-10 Shell 自有投影上下文

本片把桌面 Shell 从“构造完整 RuntimeContext”改成“持有纯投影 Context”。这是纯架构切片里最关键的一步。

## 改动

- `consoles/gui/vm_client.zig` 新增 `Context` 结构，只包含 Shell 需要的镜像/视图字段：
  - `allocator`、`io`、`paths`
  - `command`（`vne.command`）
  - `status`（`vne.status`）
  - `document`、`document_revision`（`vne.documents`）
  - `asset_view`、`library_view`、`playback_view`、`devices`
- `Context.init` 只初始化命令注册表和默认文档；`deinit` 只释放视图、路径和注册表。
- 不再实例化 `runtime.context.Context`，Shell 也不拥有 surfaces/session/tasks/library/assets/history/mounts/export 等 VM 业务状态。
- `apps/desktop/nanoui_model.zig`、`apps/editor/nanoui.zig`、`consoles/cli/nanoui.zig` 统一使用 `vm_client.Context`。
- `nanoui_console` 的 build 依赖从 `runtime` 改为 `vm_client`。
- 命令转发、文档镜像、资源/库/播放/设备视图行为不变；preview 仍走 VM ABI。

## 依赖形状

```text
apps/desktop, apps/editor, console -> vm_client.Context, vne, nanoui
vm_client                           -> vne.*, runtime.image/render (仅资源预览/source provider)
runtime                             -> 仍拥有真正的 RuntimeContext
```

Shell 不再构造 `RuntimeContext`；`RuntimeContext` 只存在于 Runtime/Host/legacy 控制台路径。

## 验证

- `build test`：退出 0，`developer-9d798e4212a1/`。
- `verify-payload`：退出 0，`developer-8de59b7e7976/`。
- `verify-architecture`：退出 0，`developer-35d6fab88f14/`。
- `verify-repository`：退出 0，`developer-26275c218efe/`，selected=753、required=757、markdown=90、local_links=286。
- 未重新构建安装器；ABI 11 / Shell context 变更后旧安装包不可用。

## 仍未解决

- `vm_client` 仍用 `runtime.image` 解码资源预览/导出 PNG，和 `runtime.render` 的 source provider（目前主要在测试中使用）。
- `RuntimeContext` 里仍有 Shell 视图字段，Runtime 还没有完全拆成“纯业务 Context”。
- 无真实 GUI/IME、视觉、安装验收。
- 未提交、未推送、未发布。
