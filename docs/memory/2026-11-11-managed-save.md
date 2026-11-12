# 2026-11-11 受管理 doc.save

本片把 `doc.save` 接入已有的 Workspace 请求回执，而不是再造一套 save 协议。

## 改动

- `vne.workspace.manages` 现在包含 `doc.save`。
- Shell 的 `vm_client` 命中 `forwardManaged`：
  - 捕获当前文档 stamp；
  - 发送带 client identity/sequence/expected 的 `workspace.Request`；
  - 成功或失败都由 Workspace receipt 记录；
  - 丢回复时重试同一 sequence，Runtime 返回 `replayed`，不会重复保存。
- Runtime 仍由 `document_commands` 处理实际保存；崩溃恢复、History、dirty 和 revision 语义不变。
- 没有新增 ABI、Host RPC 或协议字节。

## 验证

- `build test`：退出 0，`developer-151cdd3ab6d4/`；包含 workspace 路由和 vm_client 测试。
- `verify-payload`：退出 0，`developer-0d38f3c94ead/`；真实 Host + 隐藏 Shell 场景仍通过。
- 最终产物刷新：单文件 12,708,352 字节 SHA-256 `784EA7FC96A609ECCB8EE0CE47203294121147F9F8AFC712B8AAC94A3D18AF0E`；安装包 4,840,425 字节 SHA-256 `BEC22283BB3286D4249E3C1D9BF95E8EBEEBA2A189DBE7F7C0E6CA28C5D60F2C`；`verify-single-exe` `developer-714828c556d5/`、`verify-installer-artifact` `developer-68b0fd17d776/`。

## 边界

- `doc.save` 的 receipt 与 Workspace 其它 managed request 一样，只在单个 Runtime 生命周期内有效；Host 重启后旧 receipt 不再恢复。
- 目录级/跨文件事务、完整失败回执和自动重连未实现。
- 真实安装、GUI/IME、视觉验收未做。
- 未提交、未推送、未发布。
