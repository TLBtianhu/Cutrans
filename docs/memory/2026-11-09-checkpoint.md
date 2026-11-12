# 当前进度检查点（2026-11-09）

## 用途

这是供后续工作接续的当前快照。历史记录保留各自切片当时的边界；发生冲突时以 `docs/memory/current.md` 与最新实施记录为准，不把旧待办当成当前实现。

本次只整理与记录，没有新增业务实现、安装、发布、提交或推送。记录时没有运行中的后台任务。

## 当前已实现的架构

### 界面与环境

- 主桌面、编辑器、资源库、本机文件、CLI 和任务视图已统一为 NanoUI，旧 zgui／zglfw／wgpu 与旧 CUI 已移除。
- `EnvironmentSession` 以既有 Host 附着、Shell 校验、一致 Runtime 快照与随机 epoch 建立环境身份。桌面、资源库和本机文件以“虚拟环境已经建立”为先验，App 不自行选择 EXE、DLL 或 Runtime 物理路径。
- `ShellConfig` 中的物理资源／数据路径仍是过渡输入，尚未完全收口；不能把 Session 当成授权凭证或 OS 沙箱。

### 同 EXE 多角色

`cutrans.exe` 同时提供：

- 默认控制器：校验并启动／复用环境；
- `--role=host`：独立 Host 进程；
- `--role=shell`：NanoUI 桌面进程；
- `--role=library`：独立资源库进程。

**同 EXE 不等于同进程。** VM 仍持有文档、资源、授权与任务真源；Shell 是投影，Host 可在没有 Shell 时继续已有任务。

### 静态 Runtime 与动态回退

- 统一 Host 默认使用静态 Runtime，不需要 `cutrans_vm_runtime.dll`。
- 同一 `runtime/native_api.zig` 同时生成动态 DLL 和缓存内静态库，静态库链接进 `cutrans.exe`，见 `runtime/static_api.zig` 的同一窄 C ABI。
- 静态与动态共用 `bootstrap/activation.zig` 的激活、能力握手、选择锁和 Shell 提交。
- `--runtime=<绝对目录>` 仍选择经过完整校验的动态 Runtime Pack；`--runtime=builtin` 用于显式静态选择与锁迁移。不同身份默认拒绝，旧动态入口不接受 `builtin`。
- 主 Host／Shell ABI 保持 10，Resource API 保持 v4，Host 控制协议版本保持 1。

### PayloadSource

- `vne/payload.zig` 区分 `builtin` 与 `legacy_shell`。
- 默认桌面载荷为 `payload/desktop/`，资源库载荷为 `payload/nanoui-library/`；`payload.json` 使用 `cutrans-payload/1`、`entry=builtin`，只要求资源、清单和许可证，不要求旧 Shell EXE。
- 载荷文件仍逐项验证大小与 SHA-256；锁记录 Payload 清单哈希，不是 EXE 签名。
- 只有显式 `--shell-dir=<目录>` 才允许旧 `shell-pack.json`；默认缺失或损坏 Payload 不得隐式回退。
- 旧 EXE、Runtime DLL 与旧 Pack 当前仍随便携包保留，供回退；默认统一路径不再依赖它们。

### 环境内安全退出

NanoUI 首页已有独立“退出虚拟环境…”入口，与窗口关闭严格分开：

```text
草稿保护检查
  → prepare_stop 停止新业务
  → 等待已有任务，或 cancel_jobs 协作取消
  → 没有活动任务与待保存终态
  → 提交已成功的 Shell 身份
  → 既有 stop：暂停驱动、冲刷结果、保存文档、持久化 stopped
  → 关闭 Shell
```

- `resume_work` 可在尚未最终停止时恢复原 Host。
- `task.cancel_all` 复用原有持久取消语义；编码器和系统调用不能承诺强制抢占。
- 保存失败进入 `degraded`，界面保留重试入口，不报告安全退出成功。
- `runAttached` 不重复提交已提交的 Shell 身份；只有 Host 正常停止且 Shell 正常返回才输出 `CUTRANS_SAFE_EXIT_OK`。
- 普通 `stop` 仍是控制命令，不因新增界面自动变成全部退出编排。
- Host 的 RPC 停止受理不是不可信插件的 OS 安全边界。

## 当前业务能力

- 当前仍是单文档、静态 PNG 创作原型，不是完整视频／音频编辑器。
- `.cut v3` 支持 testsrc／gain／invert／over／image／resize；PNG 导入、预览、合成、导出可经同一 Runtime 命令入口完成。
- 工作正文具有持久草稿、显式工作 revision、请求回执与冷恢复；退出不自动提交正文。Document／History／排队 Job 固定原输入。
- Resource API v4 提供一层只读本机目录浏览与临时读取；浏览不隐式创建 ResourceId、授权、留存或 Station，显式收录后才登记。
- Catalog、Source、Station、持久 Source 版本、History、Task 与导出任务已有恢复语义。
- 活跃队列 8 项、每页 32 项、单 worker 与协作取消仍是当前原型边界。

## 已实际验证

- 同 EXE 的真实控制器、Host、桌面与资源库进程路径、身份提交、停止、异常恢复和重启。
- 隔离副本无 `runtime/` 时的静态 Host、NanoUI、保存恢复；真实动态 Pack 回退与锁迁移。
- 隔离副本移除旧 EXE、Runtime、旧 Shell Pack 与重复根资源后的桌面／资源库；显式旧 Pack 回退成功，缺失与损坏 Payload 被拒绝。
- 真实 Host 中等待已有任务、协作取消、拒绝新业务、撤销退出及保存失败重试。
- NanoUI 真实退出按钮、草稿保护、隔离保存失败与修复后重试、冷草稿恢复和正常重启。
- 最后一次完整无头回归 `developer-93850326d438/` 退出0；同 EXE、静态 Runtime、旧动态 Host、资源、正文、本机文件、独立库、便携、Runtime 隔离和异步作业均通过，异步作业 `inconclusive=0`。
- 2026-11-09 工作回执与恢复修复：工作正文 70 次连续草稿后仍可提交、旧序号被拒；Host 停在 `stopping` 后普通启动可收尾并重启，`degraded` 保存路径修复后也可收尾并启动新 Host；非法 `resume_work` 不再终止 Host；默认桌面同 id 载荷哈希变化被拒，内置桌面→资源库切换仍提交 `nanoui-library`。`build test`、`verify-work-documents`（ring=1）、`verify-safe-exit`（stranded=1 control=1 degraded=1）与 `verify-payload` 均退出0；真实 GUI／IME、安装升级卸载和强制抢占仍未验收，详见[本轮修复记录](2026-11-09-work-recovery.md)。
- 2026-11-10 宿主边界切片：桌面默认原生边框最大化、F11 最大化/还原；外部文件统一经 Resource API `register_file` 登记，OS 拖入和系统文件对话框接入，资源库保留引用/拥有和来源状态，VM 私有目录拒绝。`verify-local-sources`（`CUTRANS_DROP_IMPORT_OK ... register_file=1 managed_root_refused=1`）、`verify-payload`、`verify-safe-exit` 与最终 `build test` 均退出0；真实 Explorer 拖放、系统对话框、无边框全屏和安装未验收，详见[宿主边界记录](2026-11-10-host-boundary.md)。
- 2026-11-10 自定义 chrome：原生 X/Alt+F4 先进入安全退出，桌面改无边框自绘标题栏，自绘最小化/最大化/安全退出；NanoUI 本地补丁增加 borderless `WM_NCHITTEST` 边缘缩放，隐藏窗口测试通过，VENDOR/lock 已更新。`test-nanoui`、`build test`、local-sources、safe-exit、payload 通过；真实拖拽/缩放、Snap、系统菜单、视觉与安装未验收，上游 PR 未创建/合并，详见[自定义 chrome 记录](2026-11-10-custom-chrome.md)。
- 2026-11-10 上游核对：官方 v0.14 已有 `src/windows/chrome.zig`（`decorations=true` + `title_bar=.hidden`，保留原生 resize/Snap/阴影）。本地 borderless resize 分支 `5d8fce7` 只作备选，不应提交重复 PR；下一步优先 backport `chrome.zig` 或同步 0.14。
- 2026-11-10 NanoUI v0.14 同步：vendor 改为官方 `7b32272`/v0.14，采用 `chrome.zig`，退休 borderless/D3D11 纹理/stride 补丁，只保留 `ui.d3d11`、`window_maximize`、`on_present`、`kv` 六文件本地补丁；`build test`、payload、local-sources、safe-exit、test-nanoui-library、verify-nanoui-library/portable、repository 通过。`test-nanoui` 后来连续四次 585 pass / 21 skip / 0 fail，此前一次 `WS_EX_TOPMOST` 失败未复现；新增 `verify-nanoui-chrome` 复用隐藏窗口 chrome 回归；真实 GUI/Snap/缩放/安装未验收。详见 [v0.14 同步记录](2026-11-10-nanoui-v014-sync.md)。
- 2026-11-10 Shell 命令边界：命令队列从 `runtime/command.zig` 提升为 `vne.command`，Runtime 与 Shell 共用；desktop view 不再直接导入 runtime，PNG 尺寸检查经 `vm_client`。命令语义、ABI 和协议字节未变；`build test`、payload、portable-single、verify-single-exe、installer/artifact 通过。详见 [Shell 命令边界](2026-11-10-shell-command-boundary.md)。
- 2026-11-10 Shell 投影边界：`apps/desktop` 与 `apps/editor` 不再直接导入 `runtime`，改用 `vm_client` 的 Context/Preview/Frame/Paths；build 依赖同步移除。`runtime/status.zig` 移到 `vne.status`，路径边界移到 `vne.paths`，文档模型移到 `vne.documents`，Runtime 继续 re-export。Shell 直接依赖 Runtime 的位置收口到 `vm_client`；本地预览求值已改走 VM preview ABI。详见 [Shell 投影边界](2026-11-10-shell-projection-boundary.md)。
- 2026-11-10 架构边界守卫：新增 `verify-architecture`，扫描第一方层直接 `@import` 并拒绝 apps/shell 导入 runtime、vne/runtime/host/bootstrap 跨层 UI 导入；六层通过。它是直接导入扫描，不是完整模块图证明。详见 [架构边界守卫](2026-11-10-architecture-guard.md)。
- 2026-11-10 Preview ABI：ShellApi 升到 11，新增 preview info/read；Runtime 按 fingerprint 缓存 BGRA8 帧，Host RPC 与 Shell client 接通，编辑器改用 `vm_client.previewFrame`，不再本地跑文档预览 DAG。源内负例、Host mock、payload/single-exe 通过；没有专门真窗口视觉验收。详见 [Preview ABI](2026-11-10-preview-abi-contract.md)。
- 2026-11-10 Shell 自有投影上下文：桌面/编辑器/控制台改用 `vm_client.Context`，不再实例化 `RuntimeContext`；Shell 只持有命令、文档镜像、资源/库/播放/设备视图与路径。`build test`、payload 通过；`vm_client` 仍用 runtime.image/render 做资源预览与 source provider。详见 [Shell 自有投影上下文](2026-11-10-shell-owned-context.md)。
- 2026-11-10 Shell 与 imaging 解耦：PNG 编解码移到共享 `imaging` 模块，`vm_client` 不再导入 runtime；sourceProvider 改为 Shell 本地类型，架构守卫增加 `vm_client` 文件级 runtime 禁入。`build test` `developer-d7143bcbbd67/`、`verify-payload` `developer-58c5d2215692/`、`verify-architecture` `developer-b1bb936bfbca/` 通过。详见 [Shell 与 imaging 解耦](2026-11-10-shell-imaging-decoupling.md)。
- 2026-11-11 Preview 验证与 RuntimeContext 修剪：desktop verify 请求两帧、校验 generation/像素、短 buffer 和 stale fingerprint，`CUTRANS_PREVIEW_OK` 经真实 Host + 隐藏 Shell 验证，Host 重启后旧 epoch 请求被拒绝并重试；RuntimeContext 移除仅 Shell 使用的 asset_view/library_view/playback_view。`build test` `developer-d7fc20774630/`、`verify-preview` `developer-62aa78245f68/`、`verify-payload` `developer-edc9e74650a7/` 通过。详见 [Preview 验证与 RuntimeContext 修剪](2026-11-11-preview-verification-context-trim.md)。
- 2026-11-11 Host 重连 v1：Shell 增加 `reconnect()`，镜像读取失败后重新 verify Host 并重试一次；成功清空 preview epoch/identity/stamp，pending 请求保留不自动重放。`build test` `developer-35f7f6816445/`、`verify-payload` `developer-5b4030f073d1/` 通过；`verify-reconnect` `developer-7209f5f99183/` 已通过真实 Host 停止/重启 + 隐藏 Shell 自动检测、重连（auto_detect=1）。详见 [Host 重连 v1](2026-11-11-host-reconnect-v1.md)。
- 2026-11-11 受管理 doc.save：`doc.save` 纳入 `vne.workspace.manages`，复用 client identity/sequence/expected 与 receipt；丢回复重试同一请求可回放，不重复保存。`build test` `developer-151cdd3ab6d4/`、`verify-payload` `developer-0d38f3c94ead/` 通过；最终单文件 `developer-56b85e2e5683/`、`verify-single-exe` `developer-714828c556d5/`、`build installer` `developer-dc81a30da1de/`、`verify-installer-artifact` `developer-68b0fd17d776/`；receipt 仍只在单 Runtime 生命周期内有效。详见 [受管理 doc.save](2026-11-11-managed-save.md)。
- 2026-11-10 内嵌 payload 原型：构建期把 desktop/资源库 payload 打成 blob 编入 `cutrans.exe`，外部缺失时物化到 `%TEMP%/cutrans-embedded-payload/<id>/<flavor>` 并复用 PayloadSource 校验；显式 `--shell-dir` 和损坏 manifest 仍拒绝。portable context 也内嵌，只有 `cutrans.exe` 的 headless 场景通过；完整安装/发布未做。详见 [内嵌 payload](2026-11-10-embedded-payload.md)。
- 2026-11-10 安装器入口与瘦身：installer 快捷方式/关联/卸载停止改指统一 `cutrans.exe`，preflight 改用 `cutrans.exe --diag`；安装包只带 exe/licenses/README/context/vm-pack，约 4.8 MB；旧多目录布局明确拒绝自动升级；`build installer` 与 `verify-installer-artifact` 通过（preflight=1、registration_untouched=1）。真实安装/更新/卸载未验收，详见 [安装器入口与瘦身](2026-11-10-installer-entry.md)。
- Zig 格式检查通过；最终 `verify-repository` 为 `developer-8a1c9d596e20/`，selected=1084、required=1088、Markdown=78、local_links=242，新增 Python 脚本语法检查通过。
- NanoUI 固定 fork 为 `00e5813`／0.12.0，Zig 为 0.17.0；本轮没有更新上游源码或依赖锁。

详细证据分别见 [同 EXE](2026-11-09-same-exe-roles.md)、[静态 Runtime](2026-11-09-static-runtime.md)、[PayloadSource](2026-11-09-payload-source.md) 与 [安全退出](2026-11-09-safe-exit.md)。

## 还需要解决的问题

### 1. 最终发行与载荷内嵌

- `payload/` 仍是外置目录，尚未把资源内嵌进最终 EXE。
- 需要受管发布、内容校验与发布签名、版本选择、失败回滚和旧版本保护；不能把所有文件直接塞进不受控临时目录。
- 用户文档、草稿、任务、授权与 Session 不能混入可重建载荷目录。
- 最终只公开一个 `Cutrans.exe` 的目标尚未完成，当前便携包仍带旧回退文件。

### 2. 安装器与真实系统验收

- 安装器快捷方式和 `.cut` 关联仍指向旧 `cutrans_vm.exe`，尚未切换。
- 没有本轮完整安装、升级、卸载、失败回滚或真实系统登记验收。当前仍只允许相同程序资产幂等重装，变更资产升级在复制前拒绝，完整事务未实现。
- 真实安装测试需要独立 OS 用户或虚拟机，不能拿当前用户体验安装直接试验。

### 3. 真实界面与交互

- 隐藏 NanoUI Tester、离屏 D3D readback 和 Host 帧回执不等于真实窗口视觉、IME、焦点、剪贴板或操作手感验收。
- 桌面窗口已改为无边框自绘标题栏（最小化/最大化/安全退出）；真实拖拽/边缘缩放、Snap Layouts、系统菜单、视觉和安装仍未验收。
- 2026-11-10 起桌面已改为无边框自绘标题栏；真实拖拽/边缘缩放、Snap Layouts、系统菜单、阴影/圆角和视觉验收仍未做。
- 外部素材口岸由 Tester 的 `drop` 模拟 OS 拖放；真实 Explorer 拖入、系统文件对话框、目录拖入和网络/云路径未自动验收。
- 安全退出的实际界面体验、长任务等待提示、失败提示和退出中焦点仍需单独验收。
- 不使用截图、真实键鼠自动化来冒充验收。

### 4. 业务与 VM 尚未完成的范围

- 真实时变视频／音频、完整时间轴、共享异步求值和完整 FrameLease 尚未实现。
- 目录整体收纳、流式超大目录、工程目录独立化、云来源、通用换源与完整恢复 UI 仍待分片。
- 声明 schema／检查器、旧 `save`／旧命令的受管理收口、完整失败回执、未决 Shell 请求恢复、自动重连仍不完整。
- 完整跨文件事务、通用不可信插件隔离与跨 OS 实机仍未完成。

### 5. 安全、取消与异常边界

- 工作回执现在是最近64条环形＋128个客户端高水位；超过128个不同客户端且回执也淘汰后，序号1的伪造请求无法再与首次请求区分。这是原型边界，不是强身份。
- `degraded` 且保存持续失败时，普通启动仍会返回保存错误；修复只保证不再停在 `HostNotReady` 或静默丢状态。
- 默认启动同 id、不同 manifest 哈希会拒绝；自定义载荷仍需显式 `--shell-dir` 才能迁移。安装器／旧 Pack 回退不在该规则内。
- 协作取消不是强制抢占；编码器、系统调用、来源慢 I/O 与部分持久化操作仍可能延迟停止。
- 退出中的控制传输失败或结果未知不能显示“已安全退出”，也不能用强杀冒充正常停止。
- Host 业务 RPC 门禁不提供 OS 沙箱，不能把它宣传为任意不可信插件安全隔离。
- 历史 Zig loader／导入库间歇异常仍未定位，不应因当前回归通过而宣称根因已消失。

### 6. 工程与回退治理

- 默认附着验证曾因固定 30 秒上限在重负载下未完成，已统一为与直接场景一致的 90 秒并通过；这是测试等待窗口修正，不是身份协议修复。
- 缓存与验证证据没有自动预算；旧数据、真实作品、历史安装与验证证据不能据此自动删除。
- 本轮所有源码改动与此前连续切片仍在工作区，尚未提交或推送。后续不得把当前无头通过写成完整发行或安装验收。
- NanoUI 后续更新仍需审查官方→fork→Cutrans 的差异，不因版本号相同而自动升级。

## 建议接续顺序

1. 先做 PayloadSource 的资源内嵌／受管发布切片，保持业务接口不变，针对同一最终 EXE 验收。
2. 再切换安装器公开入口、收缩公开诊断与回退文件，分别做提取预检和独立 OS 用户／VM 的完整安装验收。
3. 继续业务缺口与真实 GUI／IME 体验验收，不把发行切片与真实媒体能力混为一谈。

每个切片继续使用隐藏自动化入口、独立验证数据根和保留的日志／退出码。不得读取私人项目、控制真实键鼠、修改 NanoUI vendor 或删除历史证据来绕过问题。

本检查点写入后 `verify-repository` 退出0，证据 `developer-c0b9031f1202/`；差异空白检查通过。本次只有文档与索引变化，没有新增产品代码、安装、发布、提交或推送。

2026-11-09 修复回执／Host／Shell 锁后，工作正文专项 `developer-d0f414dc212c/`（ring=1）、安全退出专项 `developer-c8dba0d85780/`（stranded=1 control=1 degraded=1）、Payload 专项 `developer-b309a6b87e84/` 和最终 `build test` `developer-225888fcb10a/` 均退出0；最终 `verify-repository` 为 `developer-4749ffd2f4ed/`，selected=1086、required=1090、markdown=80、local_links=251，retained_sdk_binaries=0。仍无真实 GUI／IME、安装升级卸载、强制抢占或发布验收。

2026-11-10 宿主边界切片后，`verify-local-sources` `developer-ba39d27891b2/`（`register_file=1 managed_root_refused=1`）、`verify-payload` `developer-648320312da3/`、`verify-safe-exit` `developer-56113493bec6/` 和 `build test` `developer-1cae13653ec2/` 均退出0；`verify-repository` 为 `developer-0f828d2e5365/`，selected=1087、required=1091、markdown=81、local_links=254。仍无真实 Explorer 拖放、系统对话框、无边框全屏或安装验收。

2026-11-10 自定义 chrome 切片后，`test-nanoui` `developer-81669e1c13f0/`、`build test` `developer-70647601a155/`、`verify-local-sources` `developer-1cdadba2de77/`、`verify-safe-exit` `developer-fb194cdaf890/`、`verify-payload` `developer-8badcb4a2cef/` 均退出0；`verify-repository` 为 `developer-5ebacc57c378/`，selected=1089、required=1093、markdown=82、local_links=258。真实窗口拖拽/缩放、Snap、系统菜单、视觉、IME 与安装仍未验收；官方 0.14 已有更完整的 `chrome.zig`，本地 borderless 分支只作备选。

2026-11-10 NanoUI v0.14 同步后，`build test` `developer-f7476e1261de/`、`verify-payload` `developer-1f250e99ebe8/`、`verify-local-sources` `developer-0458c0d81070/`、`verify-safe-exit` `developer-924f223c6643/`、`test-nanoui-library` `developer-4d68e7bd2e88/`、`verify-nanoui-library` `developer-fc3c86ef026b/`、`verify-nanoui-portable` `developer-f4fc9ed4fb0d/` 均退出0；`verify-repository` 为 `developer-beb42a64f9ae/`，selected=739、required=743、markdown=83、local_links=261。`test-nanoui` 当时有一次 `WS_EX_TOPMOST` 隐藏窗口失败（584 pass / 21 skip / 1 fail）；之后连续三次 585 pass / 21 skip / 0 fail（`developer-c8abc37985e8`、`developer-18a3c47919f7`、`developer-a21fd2eb1465`），未复现，真实 GUI/Snap/缩放/安装未验收。

2026-11-10 内嵌 payload/context 原型后，`build test` `developer-253e6cac4927/`（含缓存损坏、四线程并发及 portable/installed/development context 单测）、`verify-payload` `developer-03a647bbba14/`、`verify-local-sources` `developer-0faee7b1a3a3/`、`verify-safe-exit` `developer-4cf94b6d931b/` 退出0；`build portable-single` `developer-4accf781f265/` 只产出 `zig-out/single/cutrans.exe`（14,042,112 字节），`verify-single-exe` `developer-7c2d8634eb1d/` 通过（缓存修复 + installed 无 context）。`verify-repository` 为 `developer-2f03ee6a5497/`，selected=757、required=761、markdown=92、local_links=292。安装器入口改指 `cutrans.exe` 并瘦身，不再复制 installed context 或 vm-pack，旧多目录布局明确拒绝自动升级；`build installer` `developer-0fbd0d898f75/`、`verify-installer-artifact` `developer-c15ca7350023/`（preflight=1、registration_untouched=1）通过。Shell 命令边界切片后，`build test` `developer-b12cd3d952ca4e18/`、`verify-payload` `developer-55e9d6bd178a/`、`verify-single-exe` `developer-0605a3df9bfe/`。Shell 投影边界后，`build test` `developer-4dd874e75105/`、`verify-payload` `developer-a2c927b010e4/`、`build portable-single` `developer-1ef0a865732f/`、`verify-single-exe` `developer-903831803030/`、`build installer` `developer-e342f7f5afdd/`、`verify-installer-artifact` `developer-c59aa30876bd/`。status/paths 边界后 `build test` `developer-1e2e5f2546ba/`、`verify-architecture` `developer-3a91ad99b398/`、`verify-payload` `developer-570911ac2610/`。Preview ABI 接线后 `build test` `developer-f8d82bb733bf/`、`verify-payload` `developer-62c3d39a34bd/`、`build portable-single` `developer-083dea26f4f3/`、`verify-single-exe` `developer-8cbc802aa800/`、`verify-architecture` `developer-9288c845ded6/`。ABI 11 最终产物刷新：`build portable-single` `developer-35f8b9643e26/`、`verify-single-exe` `developer-b4ade9041a44/`（12,694,016 字节）、`build installer` `developer-8597a3b4839a/`、`verify-installer-artifact` `developer-3a922e656979/`（4,837,106 字节，preflight=1）。Preview epoch 后最终刷新：`build portable-single` `developer-8e218fc45b72/`、`verify-single-exe` `developer-75b5ba8958c2/`（12,708,352 字节）、`build installer` `developer-e7239c52a3ec/`、`verify-installer-artifact` `developer-0d5f719aa816/`（4,839,995 字节，preflight=1）；真实安装/更新/卸载与视觉验收未做。

