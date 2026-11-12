# 2026-11-11 Preview 验证与 RuntimeContext 修剪

本片完成两件事：把 preview 接入真实 Host + 隐藏 Shell 的验证，并移除 RuntimeContext 中已证明只属于 Shell 投影的字段。

## Preview 验证

`apps/desktop/nanoui.zig` 的 `verify` 新增：

- 同一 fingerprint 请求两帧，比较 generation 和像素，要求缓存一致；
- 查询 `preview_info`，输出 Runtime epoch/revision；
- 用 4 字节 buffer 调 `preview_read`，要求 `buffer_too_small` 且返回完整所需长度；
- 添加 invert 后旧 fingerprint 再查，要求 `invalid_state`；
- Runtime 重建测试：新实例 epoch 必变，旧帧可据此识别；
- 打印：

```text
CUTRANS_PREVIEW_OK width=1920 height=1080 generation=8 bytes=8294400 epoch=90af...:e0ad... revision=1 cache=1 short_buffer=1
```

`tools/verify_same_file.py` 的 desktop 场景要求 `CUTRANS_PREVIEW_OK`；`verify-payload` 通过真实 Host + 隐藏 Shell 路径验证该标记。

新增独立 `build verify-preview`（`tools/verify_preview.py`）：依赖 `portable`，调用同一 desktop 场景；随后停止并重启 Host，再跑一次隐藏 Shell，要求新 epoch 且旧 epoch 请求被拒绝。

```text
CUTRANS_PREVIEW_VERIFY_OK host=1 hidden_shell=1 frames=2 cache=1 short_buffer=1 stale=1 restart_epoch_changed=1
```

Host 重启会生成新 Runtime epoch；Shell client 把已知 epoch 附在 preview RPC 上，旧 epoch 被 Host 拒绝并触发一次 `CUTRANS_PREVIEW_EPOCH_RESET` 重试。仍没有持久化 exactly-once 回执。

## RuntimeContext 修剪

已移除仅被 Shell 使用的三个字段：

- `asset_view`
- `library_view`
- `playback_view`

RuntimeContext 现在只保留真正被 Runtime/Host/控制台使用的 `status` 和 `devices` 等状态；Shell 的投影视图由 `vm_client.Context` 自己持有。

`runtime/context.zig` 的 init/deinit 同步删除对应初始化和释放。`status`、`devices` 仍有真实 Runtime 消费者（文档命令、输入/回放、播放、帧回执），所以保留。

## 验证

- `build test`（P1）`developer-9682699be623/`。
- `verify-payload`（P1，含 preview 标记）`developer-c9d67251cef5/`。
- `build test`（P2 + epoch）`developer-b7617a908c68/`。
- `verify-payload`（P2 + epoch，含 preview 标记）`developer-edc9e74650a7/`。
- `verify-preview`：退出 0，`developer-62aa78245f68/`；Host 重启后旧 epoch 被拒绝并重试。
- `verify-architecture`：退出 0，`developer-7e4b3e207d9b/`。
- `verify-repository`：退出 0，`developer-2f03ee6a5497/`，selected=757、required=761、markdown=92、local_links=292。

## 剩余边界

- 没有 Host 重启后旧 preview 请求的验证。
- 真实安装/更新/卸载、GUI/IME、视觉验收未做。
- 真实安装/更新/卸载、GUI/IME、视觉验收未做。
- 安装器仍是 P0 产出的 preflight 验证包，未做真实安装。
- 未提交、未推送、未发布。
