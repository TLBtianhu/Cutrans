# 2026-11-09 工作回执、Host 恢复与 Shell 锁修复

本轮按用户“给自己定一个目标，开始修复”的指令，处理此前审查中优先级最高的三组问题：工作正文按帧自动保存耗尽 64 条持久回执后无法继续；Host 停在 `stopping`／`degraded` 后普通启动只返回 `HostNotReady`，控制动作失败还可能终止 Host；默认桌面启动把解析后的默认 Shell 路径当作显式 `--shell-dir`，会静默迁移 Shell 锁。只整理本轮实际改动与验证，历史切片仍以各自记录为准。

## 工作正文：回执环形缓冲与持久客户端高水位

- 自动保存从“每个 generation 变化都立即写盘”改为 400ms 空闲防抖；输入期间只重置窗口，停止输入后才写草稿。Ctrl+S、`beforeClose` 和退出流程强制立即保存。桌面与独立资源库在草稿待保存时用 `frameIn` 安排计时帧，避免没有输入就不再有帧、草稿永远不落盘。
- Catalog 格式升到 `cutrans-resource-library/4`，新增 `work_clients` 持久客户端高水位；仍接受 v3，v3 从最近回执重建客户端水位。最近 64 条回执改为环形覆盖，不再因为第 65 次成功而返回 `WorkReceiptLimit`。
- `request_receipts.Book` 新增 `seed(client, high)`；Runtime 启动后先把持久高水位灌入内存回执簿。旧序号若回执已被覆盖，按 `receipt_expired` 拒绝；未来序号按 `bad_sequence` 拒绝，不会重新执行创建或提交。
- 客户端表容量 128，超过后淘汰最久未见的客户端。若某客户端的回执已被环形覆盖、客户端高水位也已被淘汰，且伪造请求使用序号 1，现有持久信息无法再与首次请求区分；正常 Shell 使用随机 client 身份，不会在一轮生命周期内达到这一规模，但这仍是边界而不是强认证。
- 保存失败时回执和客户端高水位只回滚回执表；内存高水位可能高于已持久值。失败操作会作为已知拒绝记入回执簿，重试必须使用新序号，不能把失败保存当作“未执行”再发同一序号。

## Host：可恢复的停止状态与控制错误

- `startConsole` 遇到 `stopping` 或 `degraded` 时不再直接返回 `HostNotReady`：先走正常 `stop`（必要时保存/降级重试），等待控制端点真正消失后再启动新 Host。`stopped` 也等待旧进程释放单实例锁；`starting` 短暂等待进入运行。`HostTimeout` 不再被当作“没有 Host”而盲目再启动一个实例。
- Host 控制循环不再用 `try` 让 `beginStop`／`resume_work`／`completeStop` 的持久化错误终止进程。无效转换或写状态失败会回复当前快照并继续服务；`failStop` 失败也只记录错误并恢复任务驱动，让 UI 看到 `degraded` 并重试。
- `Server.beginStop`／`resume_work`／`completeStop` 在持久化失败时回退内存状态；`completeStop` 同时恢复 `last_shutdown_abnormal`。这样“文件没写成”不会留下一个内存已 stopped、磁盘仍 stopping 的假完成状态。
- 桌面窗口关闭在显式退出进行中（确认、等待、取消、停止）被拒绝；退出失败或已 stopped 后仍允许“仅关闭窗口”。若用户在失败后关窗，下次启动由上面的 `startConsole` 收尾，不再需要只能靠 CLI 手工恢复。

## Shell 锁：默认载荷不静默替换

- 默认桌面启动不再把解析后的默认 `payload/desktop` 作为 `--shell-dir` 传给子 Shell；显式 `--shell-dir` 仍保留迁移语义。桌面和资源库作为两个内置 Shell 之间切换时，允许迁移到另一个内置 id；同一 id 但 manifest 哈希变化（例如替换/篡改默认载荷）默认拒绝 `ShellLockMismatch`。
- 未知 id、非内置载荷变化仍需显式 `--shell-dir`。资源库 controller 默认不再传路径，靠内置兄弟切换规则工作；显式路径仍优先。
- 该规则只覆盖默认启动；安装器/旧 Pack 回退和任意自定义 Pack 的迁移策略不变。

## 实际验证

- `tools/dev.ps1 build test-core`：退出 0。
- `tools/dev.ps1 build test --summary all -j1`：退出 0，最终日志 `developer-225888fcb10a/`；包含新增 `request_receipts` 高水位测试、Catalog v3 兼容恢复测试和 Host 生命周期测试。未变步骤存在缓存复用，不能记成一次全新全量执行。
- `tools/dev.ps1 build verify-work-documents --summary all -j1`：退出 0，`developer-d0f414dc212c/`，`CUTRANS_WORK_DOCUMENTS_VERIFY_OK ... ring=1 ...`。新增 70 次连续 `save_draft`、提交、以及已被环形覆盖的旧序号拒绝检查；随后冷恢复和 Host 丢回复/重启场景仍通过。
- `tools/dev.ps1 build verify-safe-exit --summary all -j1`：最终退出 0，`developer-c8dba0d85780/`，`CUTRANS_SAFE_EXIT_VERIFY_OK ... stranded=1 control=1 save_retry=1 draft=1 restart=1 ...`。新增“Host 停在 stopping 后普通 controller start 能恢复”、“非法 resume_work 只回复、不杀 Host”以及“保存路径仍坏时普通 start 返回 HostStopFailed 而不是 HostNotReady，修复后能收尾 degraded 并启动新 Host”场景。
- `tools/dev.ps1 build verify-payload --summary all -j1`：最终退出 0，`developer-b309a6b87e84/`，`CUTRANS_PAYLOAD_VERIFY_OK ... builtin=1 explicit_fallback=1 no_implicit_fallback=1 ...`。检查列表包含同一 id 的默认载荷哈希变化被拒绝，以及桌面→资源库内置兄弟切换仍提交 `nanoui-library`；桌面/资源库内置场景、显式旧 Pack 回退和损坏拒绝继续通过。
- `tools/dev.ps1 verify-repository`：最终退出 0，`developer-4749ffd2f4ed/`，`selected=1086 required=1090 markdown=80 local_links=251 retained_sdk_binaries=0 git=1`。

## 未覆盖与保留边界

- 未做真实 GUI/IME、真实键鼠、安装器升级/卸载验收；D3D 离屏与 NanoUI Tester 不等于真实窗口体验。退出进行中拒绝窗口关闭的路径由 `desktop.State.shouldClose` 覆盖，没有自动化点击真实窗口 X。
- 防抖依赖真实空闲时间；测试用强制 `pump(true)` 覆盖保存路径，没有测量真实用户停笔 400ms 的手感。
- `degraded` 且底层保存持续失败时，普通启动仍会失败并返回保存错误；本轮只保证不再停在 `HostNotReady` 或静默丢状态。
- 回执环形缓冲的“128 个客户端后彻底淘汰”边界如上；不宣称强身份或防伪造。
- 旧 v3 Catalog 会按最近回执重建客户端水位；已被旧版本淘汰的历史成功无法补回，只能保证升级后的新回执。
- 默认同 id 哈希变化拒绝后，需要显式 `--shell-dir` 才能切换自定义载荷；这是有意的安全边界，不是自动修复。

