# 2026-11-12 未决请求：停止等待入口

## 背景

受管理命令在 Host 回复丢失时保留原请求，`pump` 只重试同一请求；Host 重启后旧 epoch 会被拒绝并清空 pending。若 Host 长时间不可用，Shell 会一直停在“结果尚未确认”，此前只有状态文字，没有让用户主动结束等待的入口。

## 改动

- `consoles/gui/vm_client.zig`：
  - 新增 `hasPending()`，供界面判断是否存在未决受管理请求。
  - 新增 `abandonPending(ctx)`：清空 pending、重置 client identity 与 sequence，并刷新镜像；不重放请求，也不声称回滚。Host 仍不可用时提示稍后刷新。
  - `beginPending` 在发送前把 `name/sequence` 写入 `data/shell/pending-unknown.txt`（临时文件 + rename）；成功或明确拒绝时删除；`wrong_epoch`/`bad_sequence`/`receipt_expired` 保留标记。
  - 新增 `recoverPendingMarker(ctx)`：Shell 启动时发现标记就置 `historical_unknown` 并提示；新增 `hasHistoricalUnknown()` / `acknowledgeHistoricalUnknown(ctx)`，确认后删除标记。恢复过程不重放旧请求。
- `apps/editor/nanoui.zig`：pending 时显示“停止等待未确认修改”；仅有历史标记时显示“上次会话有未确认的修改”和“已核对，清除提示”。
- `apps/desktop/nanoui_model.zig`：`vm_client.init/register` 后调用 `recoverPendingMarker`。
- 新增单元测试：
  - 丢失回复但实际已提交的 gain：停止等待后 pending 清空、不重放，文档镜像仍显示 0.25；
  - 无 pending 时停止等待是 no-op；
  - 写入标记后模拟 Shell 退出，下一次 `recoverPendingMarker` 置位、`acknowledge` 删除标记。

## 验证

- `build test`：退出 0，`developer-2a494ccdcb0a/`（标记实现后）；此前的 `developer-d27aab7e00d4/` 覆盖停止等待版本。
- `test-nanoui-desktop`：退出 0，`developer-85c3629142d9/`。
- `verify-payload`：退出 0，`developer-1f3bc3a7b66a/`；真实 Host + 隐藏 Shell 桌面场景仍通过。
- `verify-unknown-result`：退出 0，`developer-deaa34671ca8/`；证据 `unknown-result-acbfc979349f/`。
  - Host 在验证环境变量下先提交第一条 workspace 请求，再关连接不回包；
  - Shell 保留原请求并打印 `CUTRANS_UNKNOWN_PENDING`；
  - Host 正常停止、重启（新 epoch）后，Shell 重试原请求得到 `wrong_epoch`，打印 `CUTRANS_UNKNOWN_CLEARED`，节点数未增加；
  - 随后新 identity 的显式编辑成功，打印 `CUTRANS_UNKNOWN_RECOVERED`；
  - 同一数据的普通隐藏桌面场景另行跑通；
  - 第二个 Shell 在 pending 时直接退出，标记保留；新数据根上的下一个 Shell 打印 `CUTRANS_UNKNOWN_HISTORICAL` 并完成普通桌面场景。
- 没有 ABI/协议字节变化；没有真实 GUI/IME 或安装验收。

## 边界

- Host 的丢回复故障注入只由 `CUTRANS_TEST_DROP_WORKSPACE_REPLY` 在启动时读取一次，且只在验证脚本中使用；生产路径不设置该变量。
- pending 标记只在 Shell 内存之外保留“可能已执行”的提示；标记本身不携带可重放的请求，恢复时不会重放。标记文件位于 `data/shell/pending-unknown.txt`。
- 没有取消或回滚协议；“停止等待”不保证旧请求未提交，只保证后续编辑靠 expected stamp 拒绝晚到的旧提交。
- 真实 GUI 视觉/IME 与安装验收仍不在本片范围。
