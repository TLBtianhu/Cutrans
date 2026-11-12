# 2026-11-11 本机清理事故后的仓库核对与快照

## 事故与本仓库

- 2026-11-11 21:46–21:58 本机发生未查明的批量清理（用户侧说明见桌面《AI工具故障与数据丢失说明_20261111.md》）：5 个 AI 编码工具的程序文件与 DSH 会话正文被永久删除，回收站没有会话文件。
- 本仓库源文件未被删除。丢失的是 DSH 会话 `Cutrans-zig0.1`（75 轮，2026-11-01 起）的正文；桌面 3 MB 索引备份保留了每轮提问与回答前段，是那批提纲的唯一载体。
- 中断点：源码最后修改为 21:46:55 `shell/client.zig`、21:47:20 `consoles/gui/vm_client.zig`、21:47:53 `apps/desktop/nanoui.zig`、21:47:58 `tools/verify_reconnect.py`；21:47:46 的 `build test` 仍然通过，此后没有验证。
- 恢复清单显示第 69 轮已声称“Host 自动重连 v2 完成”，第 72 轮建议先做完整回归再收口未决请求，第 73 轮“继续”之后正文为空。

## 恢复前状态

- HEAD 为 `b4ef39d3`（2026-11-08 19:38），master 领先 origin 2 个提交；无 stash；2026-11-09～11-11 的全部切片均未提交。
- `git status` 共 933 项：495 删除、252 修改、186 未跟踪。删除主要来自 NanoUI v0.14 同步；非 vendor 差异 94 文件、+2565/−2123。未跟踪新增包括 `vne/command.zig`、`vne/documents.zig`、`vne/paths.zig`、`vne/status.zig`、`vne/payload.zig`、`vne/preview.zig`、`imaging/` 与多份 `tools/verify_*.py`。

## 修复与补齐

1. `tools/verify_reconnect.py` 第 70 行两个 `require` 之间误写了字面量 `\n`，造成 Python 语法错误并使仓库审计失败；已拆为两行。
2. 重连验证存在停机窗口竞态：原脚本写完 `reconnect.host-lost` 后 0.5 秒即重启 Host，Shell 可能在停机窗口之外才被调度，导致 `task.list` 在 Host 恢复后才执行并触发 `UnknownCommandWasRetried`。改为轮询 Shell 的 `CUTRANS_COMMAND_UNKNOWN`（上限 60 秒；Host 停机时 RPC 超时可能需十余秒才给出结论）后再重启 Host，使“停机期间普通命令失败且不重试”确定性成立。
3. 补记重连 v2 语义：`vm_client.pump` 在镜像刷新失败时调用 `maybeReconnect`；失败进入 30 次 pump 冷却并显示“Host 不可用，等待重新连接”；`CUTRANS_RECONNECT_AUTO` 由标记文件驱动隐藏演示；停机期间只有 `allowedWhileStale` 白名单命令可尝试，未受管命令返回 `not_ready`，不自动重放。
4. Python 工具链：Python 3.11 安装目录已不存在（`py -0p` 仍列出该路径，属于注册表残留），`uv.exe` 不在 PATH，`tools/dev.ps1` 找不到 `pythonw.exe`，隐藏 runner 无法启动。已将 uv 托管的 CPython 3.12.13 目录加入用户 PATH 首项；新启动的进程可直接使用隐藏入口。当前 DSH 会话仍继承旧环境，需重启 DSH 才会自动生效。
5. GitHub 认证：全局 `credential.https://github.com.helper` 指向已被删除的 WinGet `GitHub.cli` 包内 `gh.exe`，推送因此失败。备份用户 `.gitconfig` 为 `.gitconfig.bak-20261111` 后移除该失效键，回落到系统 `credential.helper=manager`；默认配置下推送恢复。

## 实际验证（2026-11-11 深夜）

- `build test`：退出 0，`developer-7bfc7d788665/`。
- `verify-payload`：退出 0，`developer-c1725f97bc7d/`；真实 Host + 隐藏 Shell，含 `CUTRANS_PREVIEW_OK` 与 `CUTRANS_NANOUI_DESKTOP_OK`。
- `verify-reconnect`：退出 0，`developer-375bbeb12171/`；`reconnect-56e4baa9eda8/` 记录 Host 停止、Shell 检测、Host 重启、自动重连与之后完整桌面场景，`auto_detect=1`。
- `verify-repository`：退出 0；快照提交前为 `developer-f311979387cc/`，补充推送与认证记录后复跑为 `developer-fd4eb297ad9f/`。
- 以上均为隐藏控制台运行；没有真实 GUI/IME、安装/更新/卸载或强制抢占验收。

## 快照

- 提交 `0fd618fd`（`feat: snapshot creation slices through 2026-11-11`）包含 2026-11-08 之后的全部工作区变更、NanoUI v0.14 同步与本记录；已推送 `origin/master`，远端 `refs/heads/master` 与本地一致，工作区除忽略项外为干净状态。
- 未改写历史、未发布 Release、未改安装或运行数据。

## 边界与后续

- 重连仍是标记驱动的隐藏演示，不是生产故障注入；未决 managed 请求不自动换 token 重放，Host 重启后旧 epoch 回执不可恢复。
- 事故根因未查明，清理行为可能再次发生：桌面 3 MB 索引备份、`scratch/verification/` 与 `zig-out/` 中的历史数据不得清理。
- 下一步按恢复清单第 72 轮建议：先做未决请求/结果未知恢复，再接完整 FrameLease 与共享异步求值；真实 GUI/IME 与安装验收仍需单独安排。
