# 2026-11-12 未决请求：停止等待入口

## 背景

受管理命令在 Host 回复丢失时保留原请求，`pump` 只重试同一请求；Host 重启后旧 epoch 会被拒绝并清空 pending。若 Host 长时间不可用，Shell 会一直停在“结果尚未确认”，此前只有状态文字，没有让用户主动结束等待的入口。

## 改动

- `consoles/gui/vm_client.zig`：
  - 新增 `hasPending()`，供界面判断是否存在未决受管理请求。
  - 新增 `abandonPending(ctx)`：清空 pending、重置 client identity 与 sequence，并刷新镜像；不重放请求，也不声称回滚。Host 仍不可用时提示稍后刷新。
- `apps/editor/nanoui.zig`：pending 时显示警告文字和“停止等待未确认修改”按钮；按钮直接调用 `abandonPending`，不进入命令注册表。
- 语义边界：停止等待只停止客户端的等待。该修改可能已经提交；刷新后的文档镜像显示 VM 当前真实状态。之后的新编辑带刷新后的 expected stamp，若旧请求晚到，会被 stale_version 拒绝，不会静默覆盖。
- 新增两条单元测试：
  - 丢失回复但实际已提交的 gain：停止等待后 pending 清空、不重放，文档镜像仍显示 0.25；
  - 没有 pending 时调用是 no-op，保留 identity/sequence。

## 验证

- `build test`：退出 0，`developer-d27aab7e00d4/`。
- `test-nanoui-desktop`：首次因 `&self.ctx` 类型错误失败，改为 `self.ctx` 后退出 0，`developer-1f422dab92da/`。
- `verify-payload`：退出 0，`developer-1f3bc3a7b66a/`；真实 Host + 隐藏 Shell 桌面场景仍通过。
- `verify-unknown-result`：退出 0，`developer-3ab335f70856/`；证据 `unknown-result-b0817ecb9af8/`。
  - Host 在验证环境变量下先提交第一条 workspace 请求，再关连接不回包；
  - Shell 保留原请求并打印 `CUTRANS_UNKNOWN_PENDING`；
  - Host 正常停止、重启（新 epoch）后，Shell 重试原请求得到 `wrong_epoch`，打印 `CUTRANS_UNKNOWN_CLEARED`，节点数未增加；
  - 随后新 identity 的显式编辑成功，打印 `CUTRANS_UNKNOWN_RECOVERED`；
  - 同一数据的普通隐藏桌面场景另行跑通。
- 没有 ABI/协议字节变化；没有真实 GUI/IME 或安装验收。

## 边界

- Host 的丢回复故障注入只由 `CUTRANS_TEST_DROP_WORKSPACE_REPLY` 在启动时读取一次，且只在验证脚本中使用；生产路径不设置该变量。
- pending 仍只存在 Shell 内存中，关闭 Shell 会丢失“上次结果未确认”的提示；没有持久化 marker。
- 没有取消或回滚协议；“停止等待”不保证旧请求未提交，只保证后续编辑靠 expected stamp 拒绝晚到的旧提交。
- 真实 GUI 视觉/IME 与安装验收仍不在本片范围。
