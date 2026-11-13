# 2026-11-11 Host 重连

> **2026-11-12 取代说明**：Host 进程与 RPC 已删除，重连机制随之移除，见 [单进程统一](2026-11-12-single-process.md)。原文保留为历史。

本片建立 Shell 侧的 Host 自动重连：镜像读取失败后由 `pump` 触发连接重建，并用真实 Host 停止/重启验证。

## 自动检测

- `vm_client.pump` 在镜像刷新失败时调用 `maybeReconnect`；
- `reconnect_cooldown` 限制重试频率，避免 Host 离线时每帧重连；
- 重连成功后清空 cooldown，并刷新全部镜像；
- 失败时状态栏显示“Host 不可用，等待重新连接”。

## 改动

- `shell/client.zig` 新增 `reconnect()`：
  - 对已有 endpoint 重新 `verifyHost`；
  - 清空 preview epoch；
  - 不重新分配 endpoint，也不替换 Shell API 函数表。
- `consoles/gui/vm_client.zig` 的镜像刷新增加一次重连重试：
  - 首次文档/播放/库/资源镜像读取失败；
  - 调 `shell.client.reconnect()`；
  - 重试全部镜像；
  - 成功后在 Shell 状态栏显示“Host 已重新连接，投影已刷新”。
- 重连成功且没有 pending 请求时，清空 vm_client identity/stamp，让下一次 managed 请求建立新会话。
- 有 pending 请求时保留原请求，不自动换 token 重放。
- 新增 `tools/verify_reconnect.py` / `build verify-reconnect`：
  - 启动真实 Host；
  - 隐藏 Shell 自动等待；
  - 停止 Host，写 `reconnect.host-lost`；
  - Shell 的下一次 `pump` 发现失败并进入重连；
  - 重启 Host，写 `reconnect.host-restarted`；
  - Shell 自动重连并完成普通隐藏桌面场景。

实际标记：

```text
CUTRANS_RECONNECT_LOST_DETECTED
CUTRANS_RECONNECT_VERIFY_OK host_restart=1 auto_detect=1 shell_reconnect=1 normal_scenario=1 hidden=1
```

## 边界

- 普通命令失败仍不会自动重试；只有镜像读取（无副作用）和显式 `reconnect` 会自动重连。
- `doc.save` 已走 managed receipt，可保留原请求；Host 重启后旧 epoch 会拒绝，不能承诺跨重启 exactly-once。
- 真实测试覆盖停止/重启 Host 后 Shell 自动发现并重连，但不证明真实 GUI/IME 手感。
- 未做真实安装或视觉验收。
- 未提交、未推送、未发布。

## 验证

- `build test`：退出 0，`developer-7282526be116/`。
- `verify-payload`：退出 0，`developer-5b4030f073d1/`（自动检测改动前）。
- `verify-reconnect`：退出 0，`developer-7209f5f99183/`；`auto_detect=1`。

## 下一步

扩展重连到交互式 Shell：保留未决请求、重连后恢复 UI、验证 managed save 在 Host 重启后的明确 unknown/replay 行为；当前 demo 是显式标记触发，不是生产自动检测。
