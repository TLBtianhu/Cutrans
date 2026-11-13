# 2026-11-12 统一为单进程虚拟环境：删除 Host 进程

## 用户决定

- 用户要求“先将其真的统一”为一个进程，“防止以后记忆混乱，改完后再继续讨论”。
- 在 AskUserQuestion 中，用户选择**彻底删除 Host 进程**（理由是“架构纯粹”），并要求另找调试方法。由此“已有 Host 在同一数据目录运行时怎么办”的问题不再存在。
- 本决定**取代** [2026-11-08 单一发行入口](2026-11-08-single-exe-safe-exit.md)里 Claude 的推荐“保留 Host／Shell 进程边界”。那份记录中用户明确提出的三点（只发一个 exe、它是进入环境的入口、内部有安全退出）全部保留。
- 用户的措辞是“单线程”，实施按**单进程**理解：Runtime 的命令 owner 线程与导出 worker 保留，否则导出会卡住界面。该理解已在会话中向用户说明。

## 现在的形态

```text
cutrans.exe（唯一公开入口）= 一个环境实例 = 一个进程
  ├─ Runtime（默认静态；文档、资源、授权、History、Job 真源）
  ├─ 作业驱动线程（vne.job_driver，空闲时每 50ms 轮询一次队列）
  ├─ 生命周期记录 session/lifecycle.txt + 单写者锁 session/instance.lock（另持旧 session/host.lock）
  └─ 前端：桌面 App ／ library 资源库 App ／ exec 无窗口脚本
cutrans_bootstrap.exe：无界面，只做动态 Runtime Pack 诊断、无头打开与回放
```

- **进程内环境**：`bootstrap/main.zig` 的 `runEnvironment` 加上 `bootstrap/instance.zig` 的 `Lifecycle`／`Environment`。App 拿到的是进程内的 `ShellApi` 表，以及 `vne/environment_control.zig` 的 `Control` 表（prepareStop／cancelJobs／resumeWork／stopEnvironment／jobsRead）。
- **业务受理闸门下沉到 VM**：新增 `cutrans_vm_set_admission`。退出开始时，Runtime 拒绝新命令、受管文档提交、资源提交、工作提交和外部打开；读取、清理（`vne.commands.stale_allowed`）以及 `task.cancel_all`、`doc.save` 仍然执行。这条语义原来由 Host RPC 层把关，现在所有前端一致。
- **前端失败也会正常停止**：App 或脚本出错返回时，环境先完成正常停止，再返回前端的错误。进程被强制结束时，下次启动报告 `abnormal_previous=1`。
- **进程内没有“结果未知”**：`vm_client` 遇到被拒绝的提交时直接丢弃该请求并换新的客户端身份；pending 标记、停止等待、重连以及跨 Shell 未确认提示全部删除。受管请求的回执与幂等机制仍保留在 Runtime 中，供将来跨进程的 agent 边缘使用。
- **新增 `cutrans.exe status`**：只读最后一次持久化的生命周期记录。

## 删除

- 源码：`host/`（lifecycle、shell_rpc、pump_driver）；`shell/client.zig`、`protocol.zig` 及四个 `*_wire.zig`；`ports/host_control.zig`（命名管道），其中的锁移入 `ports/instance_lock.zig`；`vne/host_protocol.zig`，其中的记录格式移入 `vne/lifecycle.zig`；`bootstrap/roles.zig`；`consoles/cli/vm_host.zig`、`vm_shell.zig`、`nanoui_library.zig`；`consoles/gui/vm_launcher.zig`。
- 可执行文件与包：`cutrans_vm.exe`、`cutrans_vm_host.exe`、`cutrans_shell.exe`、`cutrans_library_nanoui.exe`、旧 Shell Pack（`vm-shell`／`shell`）与旧资源库 Pack（`nanoui-library`）；`--role=`；控制台动作 `start`／`stop`／`restart`／`attach`／`jobs`。
- 遗留死代码：`cutrans_vm_start_shell`（进程内加载 Shell DLL，没有任何产物导出 `cutrans_shell_run`）、`abi.ShellRequest`、Runtime 的 `shell_driver`。
- 验证脚本：`verify_host`、`verify_host_transport`、`verify_attach`、`verify_reconnect`、`verify_unknown_result`、`verify_workspace_rpc`、`verify_same_file`、`verify_shell`、`verify_nanoui_library`，以及对应的 build step（还包括 `verify-nanoui-portable`、`shell-pack`、`nanoui-library-pack`）。其余脚本中的 Host／管道用例已移除，DLL（ctypes）用例保留。
- 安装器：不再执行 `cutrans.exe stop`。本安装仍有进程在运行时中止，并提示用户先在应用内安全退出；安装器从不替用户结束进程。

## 调试与验证的替代方式（用户要求）

1. **`cutrans.exe exec --script=<jsonl>`**（`bootstrap/exec.zig`）：在真实环境实例里无窗口地逐行执行 `command`／`document`／`jobs`／`wait_jobs`／`prepare_stop`／`cancel_jobs`／`resume_work`／`stop`／`crash`，每行输出 `CUTRANS_EXEC {json}`。形状接近 tool call，将来可直接作为 MCP stdio 边缘的雏形，但目前不是 MCP 实现。
2. **App 内置隐藏场景**：`--assets-demo`、`--files-demo`、`--exit-demo`，在同一进程里用 NanoUI Tester／离屏 D3D 运行。
3. **Runtime DLL 的 ctypes 测试**：原有方式保持不变。
4. **`status`**：读取持久化的生命周期记录。
5. 共享 Python 帮助模块 `tools/environment_harness.py`（`run_app`／`exec_script`／`status`／`desktop_case`／`library_case`）。

## 验证（本机 Windows，2026-11-12）

- `build test`：最后一次干净运行 `developer-5c1db791d6bc/` 退出 0，无加载器错误。唯一被构建运行器标记的二进制单独运行 2/2 通过。前几轮的 22 个被标记二进制单独运行全部通过（例如 148/148、178/178）。加载器间歇异常仍在发生：12 次 build 里约 4 次出现，每次重试即可通过。
- 新单元测试：`vne/lifecycle.zig`（往返与旧格式兼容）、`vne/environment_control.zig`、`ports/instance_lock.zig`（单持有者）、`bootstrap/instance.zig`（启动序号、异常标记、模式不符、旧记录延续）、`vm_client`（被拒提交不重试并换身份；畸形回执即拒绝）。
- 改写后通过：`verify-static-runtime`、`verify-payload`、`verify-preview`、`verify-single-exe`、`verify-safe-exit`（wait／cancel／admission／resume／control／abnormal／single_writer／save_retry／draft／restart）、`verify-local-sources`、`verify-jobs`（新增无前端导出与跨实例记录）、`verify-isolation`（12 项）、`verify-input`、`verify-write-order`、`verify-installer-artifact`（仅预检）。
- 回归通过：`verify-jobs-async`、`verify-work-documents`、`verify-resident-resources`、`verify-resource-operations`、`verify-resource-versions`、`verify-source-identity`、`verify-assets`、`verify-workspace`、`verify-edit-commit`、`verify-replay`、`verify-playback`、`verify-runtime`、`diag-user`、`verify-architecture`、`test-nanoui-desktop`、`test-nanoui-library`。
- `verify-resource-registration`：仍然只在受管根边界探针处失败（`status=0, expected=4`）。这是此前已登记的既有回归，与本次无关，未修。

## 本次暴露并修正的既有陈旧断言（不是本次引入）

- `vne/resource_api.zig` 的测试 `work requests separate new drafts from commit and discard` 与 `validWorkRequest` 契约脱节（`save_draft` 不得带 label，`commit` 的 `base_revision` 必须为 0）。该测试从未执行过，这次因新加的测试根被拉进来才暴露。已按代码契约修正测试，代码未改。这是“vne 测试根”问题的又一例证。
- `verify_workspace.py` 用受管的 `doc.save` 当“不支持的命令”来填满回执环。`doc.save` 自 11-11 起已受管理，脚本上次运行是 11-07。已改用只读、不受管的 `task.list`。
- `verify_isolation.py` 断言缺少外部 context 必须报 `MissingRunContext`。11-10 起便携形态按设计回退到内嵌 context，脚本上次运行是 11-08。已改为断言内嵌回退得到完全相同的身份。

## 未覆盖／边界

- 只运行了隐藏场景，没有打开过真实可见窗口；真实关窗、`Alt+F4`、真实 GUI／IME 手感均未验收。
- 关闭环境后导出不再继续，这是有意的代价。导出只在环境运行期间执行；退出界面会提示等待或取消。
- 语义输入事件不经过受理闸门：退出界面是模态的，而桌面每帧都会推送输入。
- 外部 agent 或 CLI 无法附着到正在运行的桌面环境（不再有管道）。将来需要时，在边缘加 stdio／MCP 适配器，而不是恢复 Host。
- 真实安装、升级、卸载未执行，只做了安装器构建与提取预检；“有进程运行时中止”的路径未实测。
- 作业驱动的 50ms 空闲轮询是新的常驻开销，没有做性能测量。
- 动态 Runtime DLL 新增 `cutrans_vm_set_admission` 导出，属于新增符号；旧版 DLL 会因缺少符号而被拒绝装载（`MissingRuntimeSymbol`），这是预期行为。
