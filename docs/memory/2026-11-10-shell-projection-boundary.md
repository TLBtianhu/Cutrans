# 2026-11-10 Shell 投影边界

本片把桌面和编辑器 App 从 Runtime 模块的直接依赖中拆出来：App 只通过 `vm_client` 暴露的 Shell 侧类型与能力工作，Runtime 细节收口到一个适配层。

## 改动

- `vm_client` 新增 Shell 侧别名：
  - `Context`（原 `runtime.context.Context`）；
  - `Preview`（原 `runtime.render.Preview`）；
  - `Frame`（`vne.frame.Frame`）；
  - `Paths`（原 `runtime.paths.Paths`）。
- `apps/desktop/nanoui_model.zig` 不再导入 `runtime`，改用 `vm_client.Context`/`Paths`。
- `apps/editor/nanoui.zig` 不再导入 `runtime`，改用 `vm_client.Context`/`Preview`/`Frame`。
- `build.zig` 的 `desktop_app` 和 `editor` 模块不再声明 `runtime` 依赖。
- `vne.command` 仍是共享命令队列；本片不放宽 ABI，也不改变命令/协议字节。

## 当前依赖形状

```text
apps/desktop, apps/editor  ->  vm_client, vne, nanoui, palette
vm_client                 ->  runtime.context/documents/render/image, vne, shell
```

也就是说，Shell 直接依赖 Runtime 的位置已经收口到 `vm_client` 一个适配层；App 层不再知道 RuntimeContext 的具体来源。

## 验证

- `build test`：退出 0，`developer-4dd874e75105/`。
- `verify-payload`：退出 0，`developer-a2c927b010e4/`。
- `build portable-single`：退出 0，`developer-1ef0a865732f/`。
- `verify-single-exe`：退出 0，`developer-903831803030/`；`installed_context=1`。
- `build installer`：退出 0，`developer-e342f7f5afdd/`。
- `verify-installer-artifact`：退出 0，`developer-c59aa30876bd/`。
- `verify-repository`：退出 0，`developer-2bc631dcc4a3/`，selected=752、required=756、markdown=89、local_links=283。

## 后续小步

- `runtime/status.zig` 已移到 `vne.status`；`runtime.context` 使用 `vne.status`，`runtime.root` 继续 re-export。
- `runtime/paths.zig` 的路径边界已移到 `vne.paths`；Runtime 保留一个薄 shim 和需要 documents 的保存测试，`vm_client.Paths` 改用 `vne.paths.Paths`。
- `runtime/documents.zig` 的文档模型移到 `vne.documents`；Runtime 继续 re-export，`vm_client` 的镜像解析改用 `vne.documents`。
- `build test` `developer-abbb71cbd788/`、`build verify-architecture` `developer-7ba370411802/`、`verify-payload` `developer-d4dad017b1cc/` 通过。

## 仍未解决

- `vm_client` 仍直接使用 `runtime.context`、`runtime.documents`、`runtime.render`、`runtime.image`；
- 文档预览仍在 Shell 本地求值，没有 VM→Shell preview 帧 ABI；
- save/旧命令仍未受管理收口；Host 自动重连、未决 Shell 请求恢复未做；
- 本片只改依赖边界，不改产品行为、ABI 或协议。
- 未提交、未推送、未发布。
