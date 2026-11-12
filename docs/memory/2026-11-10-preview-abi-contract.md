# 2026-11-10 Preview ABI

本片把 preview 从 Shell 本地求值改为 **VM 产出、Host 传输、Shell 显示** 的 ABI 通道。

## 契约与 ABI

- `vne/preview.zig`：
  - `version = 2`
  - BGRA8
  - `Info { struct_size, abi_version, width, height, format, reserved, generation, fingerprint, epoch_hi, epoch_lo, revision, bytes_len }`
  - 宽高非零、字节数精确为 `width * height * 4`、generation/fingerprint 非零、Runtime epoch/revision 非零、短 buffer 拒绝。
- `ShellApi` 升到 **ABI 11**，尾部新增：
  - `preview_info(context, expected_fingerprint, out_info)`
  - `preview_read(context, expected_fingerprint, buffer, capacity, out_len)`
- 静态 Runtime、动态 Runtime lookup、Shell client 和 Host RPC 都已接入。

## Runtime

- `Runtime` 持有 `render.Preview`，按 document fingerprint 缓存帧。
- `preview_info` / `preview_read` 在 Runtime 锁内读取当前文档、求值并返回；`expected_fingerprint` 不符返回 `invalid_state`，短 buffer 返回 `buffer_too_small`。
- `PreviewInfo` 携带 Runtime epoch/revision；新 Runtime 实例的 epoch 不同，旧帧可据此识别。
- 新增源内测试：`native preview ABI returns one bounded frame and rejects stale or short reads`，以及 `native preview epoch changes across runtime recreation`。

## Host / Shell

- Shell RPC 新增 `preview_info=33`、`preview_read=34`。
- Host `shell_rpc` 转发到 Runtime ShellApi；Host 侧先查 info，再分配并读取像素。
- `shell/client.zig` 实现两个 API 回调。
- `vm_client.previewFrame` 负责 info→分配→read→校验长度。

## 编辑器

- `apps/editor/nanoui.zig` 的 `drawPreview` 改为调用 `vm_client.previewFrame(ctx, doc.fingerprint(), allocator)`。
- 删除编辑器本地 `vm_client.Preview` 字段和 `runtime.render` 调用；Shell 不再自己跑文档 DAG 预览。
- `convert` 仍做 BGRA 预乘转换，像素来自 VM。
- 帧仍通过既有 `frame_report` 回执。

## 验证

- `build test`：退出 0，`developer-b7617a908c68/`；包含 Runtime preview 负例、preview epoch 重建测试和 Host preview RPC mock。
- `verify-preview`：退出 0，`developer-62aa78245f68/`；标记包含 `epoch=... revision=1 cache=1 short_buffer=1`，停止/重启 Host 后旧 epoch 被拒绝并触发 `CUTRANS_PREVIEW_EPOCH_RESET`。
- `verify-payload`：退出 0，`developer-edc9e74650a7/`。
- `build portable-single`：退出 0，`developer-56b85e2e5683/`；最终单文件 12,708,352 字节，SHA-256 `784EA7FC96A609ECCB8EE0CE47203294121147F9F8AFC712B8AAC94A3D18AF0E`。
- `verify-single-exe`：退出 0，`developer-714828c556d5/`。
- `build installer`：退出 0，`developer-dc81a30da1de/`；最终安装包 4,840,425 字节，SHA-256 `BEC22283BB3286D4249E3C1D9BF95E8EBEEBA2A189DBE7F7C0E6CA28C5D60F2C`。
- `verify-installer-artifact`：退出 0，`developer-68b0fd17d776/`；preflight=1、override_rejected=1、registration_untouched=1。
- `verify-architecture`：退出 0，`developer-7e4b3e207d9b/`（最终产物前）。
- `verify-repository`：退出 0，`developer-2f03ee6a5497/`，selected=757、required=761、markdown=92、local_links=292。

## 仍未覆盖

- Host 重启后旧 preview epoch 请求会被拒绝：Shell client 携带已知 epoch，Host 比对当前 Info epoch；旧值返回 `invalid_state`，client 清空后重试。仍没有持久化 exactly-once 回执。
- 没有真窗口/多帧视觉、GUI/IME、缩放、播放平滑度或安装验收。
- 未提交、未推送、未发布。
