# Cutrans 现役记忆入口

本文件是项目记忆的唯一入口。每条事实的权威位置可以分文件，历史记录与现役摘要分开维护。

## 先读什么

1. [现役状态与已知边界](docs/memory/current.md)：从这里判断当前实现，不能把历史通过记录当成本轮验收。
2. [界面配色与材质](docs/ui-style.md)：用户认可的深靛蓝、冰蓝与紫色、轻微金属反光方向。
3. 按任务阅读下方对应的宪法簇与实施历史。历史提案不自动视为现役实现。
4. 代码头注释和实现用于对账；git 历史用于查证当时状态。退役项目不作为现役事实来源。

## 持续约束

- 一切皆插件；声明唯一真源，一切皆投影；机制与策略分家。
- VM 持有文档、资源、授权与任务语义；Shell 只持有镜像和本地交互状态。
- 文档、内存 Station、持久资源库与可重建缓存分层。自动同步仅可由可选插件触发。
- 记录格式定长，不等于容量固定；每条命令只有一个语义入口，接受、就绪、完成、提交分别对账。
- 开发、便携、安装、临时验证互不混用数据；安装单根，升级和卸载保留用户数据。
- 不读取 VocalSet、VoiceLab 或相关私人项目；不采集屏幕、不控制真实键鼠。离屏 UI 测试不替代真实视觉与 IME 手感。
- 凭证和个人敏感信息不入库。公开记忆只留项目必要信息，不留个人画像或无关部署地址。
- 用户决定方向，讨论先行；获得实施指令后完成已授权工作。新决定及时记录。
- 自动构建、测试、CLI、PowerShell查询与后台辅助进程默认不弹命令行窗口，统一通过隐藏自动化入口启动并保留日志、输入输出和退出码；真实GUI验证单独安排，不用隐藏控制台替代GUI验收。（2026-11-07用户要求）

## 维护方式（2026-11-06 重构）

- 本轮按用户“开始重构”的指令，将原单文件按主题及段落迁入下方文件，保留非个人历史内容与取代顺序。
- 决策历史继续追加，修正用新条目说明；现役状态摘要允许依据已验证事实更新。
- 隐私脱敏是保留历史的例外，不再通过追加注释继续公开原始个人内容。
- 既有 Git 历史没有改写。当前文本脱敏不能撤回旧提交中的原始内容。
- 2026-11-07补充：用户随后明确授权force-push并确认撤下旧试验发布。公开master已重建快照历史，旧标签／Release已备份后删除；旧完整历史保留本机私有备份。用户指定fork不处理，GitHub缓存与其它副本不宣称已物理擦除。[实际记录](docs/memory/2026-11-07-public-history-reset.md)。
- 所有新实施记录必须写清实际验证与未验证范围，README 仅作对外投影。

## 主题与历史索引

- [〇、现状声明与检索纪律(2026-10-09 立)](docs/memory/00-reading.md)
- [使命宣言:剪辑软件界的 GNU(2026-10-09,用户口述种子)](docs/memory/01-mission.md)
- [一、身份宪法](docs/memory/02-identity.md)
- [二、流协议(细腰核心)](docs/memory/03-stream.md)
- [三、树(声明层)](docs/memory/04-declarations.md)
- [四、模态与制式](docs/memory/05-modalities.md)
- [五、参数世界](docs/memory/06-parameters.md)
- [六、素材与器具(源宪法)](docs/memory/07-sources.md)
- [七、依赖与装配](docs/memory/08-assembly.md)
- [八、物化点与存储经济学(L1/L2/L3)](docs/memory/09-storage.md)
- [九、压缩与格式法](docs/memory/10-formats.md)
- [十、时机与消费(调度立法闭环)](docs/memory/11-scheduling.md)
- [十一、触发与泵（分段 1）](docs/memory/12-pumps-01.md)
- [十一、触发与泵（分段 2）](docs/memory/12-pumps-02.md)
- [十二、音频域](docs/memory/13-audio.md)
- [十三、内存哲学](docs/memory/14-memory.md)
- [十四、Zig 地方法规(0.17 实况)](docs/memory/15-zig.md)
- [十五、工程现状台账(历史基线;现役状态见文末最新实施台账)](docs/memory/16-historical-baseline.md)
- [十六、哲学散记与参照系（分段 1）](docs/memory/17-discussion-history-01.md)
- [十六、哲学散记与参照系（分段 2）](docs/memory/17-discussion-history-02.md)
- [十六、哲学散记与参照系（分段 3）](docs/memory/17-discussion-history-03.md)
- [十六、哲学散记与参照系（分段 4）](docs/memory/17-discussion-history-04.md)
- [十六、哲学散记与参照系（分段 5）](docs/memory/17-discussion-history-05.md)
- [十六、哲学散记与参照系（分段 6）](docs/memory/17-discussion-history-06.md)
- [十六、哲学散记与参照系（分段 7）](docs/memory/17-discussion-history-07.md)
- [十六、哲学散记与参照系（分段 8）](docs/memory/17-discussion-history-08.md)
- [十六、哲学散记与参照系（分段 9）](docs/memory/17-discussion-history-09.md)
- [十七、现役索引与认知校准(2026-11-02)](docs/memory/18-calibration.md)
- [十八、分发四物、OS 依赖轴与新旧 VM 路线(2026-11-02 调研定案)](docs/memory/19-distribution.md)
- [十九、分阶段推进流程(2026-11-02 定)](docs/memory/20-phases.md)
- [二十、VM Runtime 与 VNE 实施台账(2026-11-02)（分段 1）](docs/memory/21-implementation-01.md)
- [二十、VM Runtime 与 VNE 实施台账(2026-11-02)（分段 2）](docs/memory/21-implementation-02.md)


## 最新实施记录

- [2026-11-12 未决请求：停止等待入口](docs/memory/2026-11-12-pending-wait-stop.md)：新增 `hasPending`/`abandonPending`，编辑器在结果未确认时显示警告和“停止等待未确认修改”；停止等待不重放、不回滚，镜像刷新后显示 VM 真实状态，后续编辑靠 expected stamp 防止静默覆盖。单元测试、`test-nanoui-desktop`、`verify-payload` 通过；新增 `verify-unknown-result` 用真实 Host 的提交后丢回复 + 重启，验证只提交一次、`wrong_epoch` 清空和显式恢复编辑。

- [2026-11-12 ABI 接线审计与构建残留清理](docs/memory/2026-11-12-abi-and-staging-audit.md)：确认 ShellApi 表字段与 Host RPC 分支由编译期强制，剩余人工映射已记录；精确删除 `zig-out/portable` 下 9 个旧 UI 残留文件（约 19.8 MB），重建后未再生，`verify-payload` 通过。

- [2026-11-12 命令清单单一真源](docs/memory/2026-11-12-command-manifest.md)：新增 `vne/commands.zig` 统一 forwarded/runtime_only/managed/stale_allowed/node_creating；Shell 注册、过期白名单、workspace 分类改为读取同一清单；Runtime 注册表用测试断言与清单完全一致。`build test`、`verify-architecture`、`verify-repository` 通过，无行为变化。

- [2026-11-11 事故恢复与工作区快照](docs/memory/2026-11-11-incident-recovery.md)：本机清理事件丢失 DSH 会话正文（Cutrans 75 轮），仓库源文件幸存；核对发现 11-09～11-11 全部改动未提交。修复 `verify_reconnect.py` 语法错误与停机窗口竞态，补齐重连 v2 语义和 Python 隐藏入口；`build test`、`verify-payload`、`verify-reconnect`、`verify-repository` 通过；工作区已提交并推送 `origin/master`。

- [2026-11-11 Host 重连 v1](docs/memory/2026-11-11-host-reconnect-v1.md)：Shell 增加 `reconnect()`，镜像读取失败后重新 verify Host 并重试一次；成功清空 preview epoch/identity/stamp，pending 请求保留不自动重放。普通命令仍不自动重试；`verify-reconnect` 已通过真实 Host 停止/重启 + 隐藏 Shell 自动检测、重连；pump 失败触发连接重建并有冷却窗口。

- [2026-11-11 受管理 doc.save](docs/memory/2026-11-11-managed-save.md)：`doc.save` 纳入 `vne.workspace.manages`，复用 client identity/sequence/expected 与 receipt；丢回复重试同一请求可回放，不重复保存。没有新增 ABI/协议；receipt 仍只在单 Runtime 生命周期内有效。

- [2026-11-11 Preview 验证与 RuntimeContext 修剪](docs/memory/2026-11-11-preview-verification-context-trim.md)：真实 Host + 隐藏 Shell 的 desktop verify 请求两帧、校验 generation/像素、短 buffer 和 stale fingerprint；PreviewInfo 携带 Runtime epoch/revision，新 Runtime 实例 epoch 必变；新增独立 `verify-preview`；Shell client 携带已知 epoch，Host 重启后旧 epoch 请求被拒绝并重试；RuntimeContext 移除仅 Shell 使用的 asset_view/library_view/playback_view。status/devices 仍有真实 Runtime 消费者，保留。

- [2026-11-10 Shell 与 imaging 解耦](docs/memory/2026-11-10-shell-imaging-decoupling.md)：PNG 编解码移到共享 `imaging` 模块，`vm_client` 不再导入 runtime；sourceProvider 改为 Shell 本地类型，架构守卫增加 `vm_client` 文件级 runtime 禁入。`build test`、payload 通过。

- [2026-11-10 Shell 自有投影上下文](docs/memory/2026-11-10-shell-owned-context.md)：桌面/编辑器/控制台改用 `vm_client.Context`，不再实例化 `RuntimeContext`；Shell 只持有命令、文档镜像、资源/库/播放/设备视图与路径。`build test`、payload 通过；`vm_client` 仍用 runtime.image/render 做资源预览与 source provider。

- [2026-11-10 Preview ABI](docs/memory/2026-11-10-preview-abi-contract.md)：ShellApi 升到 ABI 11，新增 preview info/read；Runtime 缓存并按 fingerprint 返回 BGRA8 帧；Host RPC 和 Shell client 接通；编辑器改用 `vm_client.previewFrame`，不再本地跑文档预览 DAG。源内负例、Host mock、payload/single-exe 通过；没有专门真窗口视觉验收。

- [2026-11-10 架构边界守卫](docs/memory/2026-11-10-architecture-guard.md)：新增 `tools/verify_architecture.py` 与 `build verify-architecture`，拒绝 `apps`/`shell` 直接导入 runtime，及 vne/runtime/host/bootstrap 的跨层 UI 导入；当前六层通过。它是直接 `@import` 扫描，不是完整模块图证明。

- [2026-11-10 Shell 投影边界](docs/memory/2026-11-10-shell-projection-boundary.md)：`apps/desktop` 与 `apps/editor` 不再直接导入 `runtime`，改用 `vm_client` 暴露的 Context/Preview/Frame/Paths；build 依赖也移除。Shell 直接依赖 Runtime 的位置收口到 `vm_client` 一个适配层；本地预览求值、documents/render/image 和 preview 帧 ABI 仍未拆除。

- [2026-11-10 Shell 命令边界](docs/memory/2026-11-10-shell-command-boundary.md)：命令队列从 Runtime 私有模块提升为 `vne.command`，Runtime 与 Shell 共用；desktop view 不再直接导入 runtime，PNG 尺寸检查经 `vm_client`。命令语义/ABI/协议字节未变；Shell 仍持有 RuntimeContext 与 documents/render/image，后续继续拆投影边界。

- [2026-11-10 安装器入口与瘦身](docs/memory/2026-11-10-installer-entry.md)：安装器快捷方式/关联/卸载停止改指统一 `cutrans.exe`，preflight 用 `cutrans.exe --diag`；安装包只带 exe/licenses/README，不再复制 context 或 vm-pack（context 已内嵌，vm-pack 不再需要），约 4.8 MB；旧多目录布局明确拒绝自动升级。`build installer` 与 `verify-installer-artifact` 通过（preflight=1、registration_untouched=1）；真实安装/更新/卸载/发布未做。

- [2026-11-10 内嵌 Payload 原型](docs/memory/2026-11-10-embedded-payload.md)：构建期把 desktop/资源库 payload 打成 blob 编入 `cutrans.exe`，portable 和 installed run context 也分别内嵌；`build portable-single` 只产出约 14 MB 的 `zig-out/single/cutrans.exe`，`build verify-single-exe` 通过 portable start/shell/stop、缓存修复和 installed 无 context 场景且不生成外部 payload/context。缓存逐文件校验、损坏重建，staging+rename 支持并发物化，旧于30天的目录尽力清理；显式/损坏 Shell 仍拒绝。安装器/真实安装/发布未做。

- [2026-11-10 NanoUI 同步到官方 v0.14](docs/memory/2026-11-10-nanoui-v014-sync.md)：vendor 从 fork 0.12 切到官方 `7b32272`/v0.14，采用 `chrome.zig` 自绘标题栏（保留原生 resize/Snap/阴影），退休 borderless/D3D11 纹理/stride 等已上游补丁；只保留 `ui.d3d11`、`window_maximize`、`on_present`、`kv` 六文件本地补丁。`build test`、payload、local-sources、safe-exit 通过；`test-nanoui` 连续四次 585 pass / 21 skip / 0 fail（此前一次 `WS_EX_TOPMOST` 失败未复现），`verify-nanoui-chrome` 覆盖隐藏窗口 chrome 回归；真实 GUI/安装未验收。

- [2026-11-10 自定义窗口 chrome 与安全关闭](docs/memory/2026-11-10-custom-chrome.md)：原生 X/Alt+F4 先进入安全退出；桌面改为无边框自绘标题栏，自绘最小化/最大化/安全退出；该页的 borderless 方案已被 v0.14 同步取代，安全关闭语义保留。

- [2026-11-10 宿主边界：窗口与外部素材口岸](docs/memory/2026-11-10-host-boundary.md)：桌面默认启动最大化、F11 最大化/还原并保留原生最小化；外部文件统一走 Resource API `register_file`，支持 OS 拖入、系统文件对话框、来源/引用状态和 VM 私有目录拒绝。实际 local-sources、payload、safe-exit 与仓库审计通过；真实 Explorer 拖放、系统对话框、无边框全屏与安装未验收。

- [2026-11-09 工作回执、Host 恢复与 Shell 锁修复](docs/memory/2026-11-09-work-recovery.md)：工作正文自动保存改为空闲防抖，Catalog v4 用环形回执＋持久客户端高水位消除 64 次硬上限；Host 停在 stopping／degraded 后普通启动可收尾重启，控制转换错误不再杀 Host；默认桌面与同 id 载荷变化拒绝迁移 Shell 锁，内置桌面／资源库兄弟切换保留。实际 DLL／Host／安全退出／Payload 场景已验证，真实 GUI、安装与强制抢占未覆盖。

- [2026-11-09 当前进度检查点](docs/memory/2026-11-09-checkpoint.md)：集中记录当前架构、业务边界、实际验证、发行／安装／安全与工程待办，以及后续接续顺序；只整理记忆，没有新增实现或发布。

- [2026-11-09 环境内安全退出](docs/memory/2026-11-09-safe-exit.md)：独立 NanoUI 退出入口已接通停止受理、等待／取消、草稿保护、失败重试和正常停止；冷恢复与真实 Host 场景已验证，强制抢占和真实 GUI／安装验收仍未覆盖。

- [2026-11-09 PayloadSource 与内置 NanoUI 载荷](docs/memory/2026-11-09-payload-source.md)：统一桌面与资源库改用独立资源清单，默认不再要求旧 Shell EXE；无旧文件场景、显式旧 Pack 回退及损坏拒绝已验证，资源内嵌与安全退出仍待后续。

- [2026-11-09 静态 RuntimeProvider 与动态回退](docs/memory/2026-11-09-static-runtime.md)：统一 Host 默认使用静态 Runtime，无 Runtime DLL 的真实启动／NanoUI／恢复已验证；动态 Pack 与显式锁迁移保留，最终载荷与安全退出仍待后续。

- [2026-11-09 同 EXE 控制器、Host 与 NanoUI 角色](docs/memory/2026-11-09-same-exe-roles.md)：`cutrans.exe` 统一承担控制器、Host、桌面和资源库角色，保留独立进程、Pack 校验与旧入口回退；静态 Runtime、内嵌载荷和完整安全退出仍待实现。

- [2026-11-09 虚拟环境先验与 EnvironmentSession](docs/memory/2026-11-09-environment-session.md)：以现有 Host 附着、Shell 校验和 Runtime epoch 建立无物理路径的环境身份；桌面、资源库和本机文件共用启动屏障，单 EXE 与完整安全退出仍待实现。

- [2026-11-08 本机文件只读浏览与显式登记](docs/memory/2026-11-08-local-file-sources.md)：Resource API v4、Host 一层浏览／成员读取、NanoUI 本机文件页、显式收录与插入文档及实际 DLL／Host 验收。

- [2026-11-08 单一发行入口与虚拟环境安全退出目标](docs/memory/2026-11-08-single-exe-safe-exit.md)：用户明确最终只公开一个控制启动／进入 VM 的 EXE，内部提供独立安全退出；记录单文件与进程边界、启动校验、退出状态机及未实现范围。

- [2026-11-08 工作正文、草稿与固定版本分离](docs/memory/2026-11-08-work-documents.md)：Resource API v3、持久草稿与工作 revision、成功回执跨恢复、NanoUI 正文编辑及实际 DLL／Host 验收。

- [2026-11-08 统一 NanoUI 前端与旧 UI 清理](docs/memory/2026-11-08-nanoui-unification.md)：主桌面、编辑器、资源库、CLI 与任务统一为 NanoUI；移除 zgui/zglfw/wgpu 与旧 CUI，保留 VM/Host 业务语义并补实际验证。

- [2026-11-08 当前进度、遗留问题与后续顺序](docs/memory/2026-11-08-progress.md)：业务到C2c2，A／B主切片已验收、C未整体完成、D／E待办；集中登记工作正文、会话／求值、独立App、安全、安装、上游和缓存问题，下一片先做工作正文与固定版本分离。本次仅记忆归档。

- [2026-11-07 自动化隐藏控制台与日志继承修复](docs/memory/2026-11-07-quiet-automation.md)
- [2026-11-07 连续创作会话架构优化计划与A1／A2／B1／B2／C1／C2a实施](docs/memory/2026-11-07-architecture-plan.md)
- [2026-11-06～07 开发、分发与本机安装测试隔离审计](docs/memory/2026-11-06-isolation.md)
- [2026-11-06 工程基线、上游与界面重构及验收](docs/memory/2026-11-06-foundation.md)

- [2026-11-07 C2b资源重新定位／采用核心、独立版本与回执及实际DLL／Host验收](docs/memory/2026-11-07-architecture-plan.md)：ABI9；GUI恢复入口尚待C2c接入，完整协议见[资源操作](docs/resource-operations.md)。

- [2026-11-07 FileHub方向补充与资源分层建议](docs/memory/2026-11-07-architecture-plan.md)：用户明确资源管理器偏向通用资源空间，下载器为独立应用；来源／驻留／消费版本的具体调整仍标为讨论建议。

- [2026-11-07 独立App、来源区域与VM资源入口](docs/memory/2026-11-07-architecture-plan.md)：用户明确本地／云来源与VM专属区、默认引用和显式独立化、拖入其它App的统一登记快捷路径、专属区直接编辑及显式出境复制；名称和具体隔离机制仍待细化。

- [2026-11-07 C2c1已加载资源优先、来源观察与完整RAM独立化实施及验收](docs/memory/2026-11-07-architecture-plan.md)：ABI10；当前PNG闭环，完整缓存、异步刷新与来源App继续后续。

- [2026-11-07 C2c2通用只读文件登记、App交付与实际DLL／Host验收](docs/memory/2026-11-07-resource-registration.md)：Resource API v2，179步骤／14组新验证／18项同产物回归；真实联接／硬链已测、符号链接未覆盖。另记录NanoUI官方／fork新提交，未盲目升级。

- [2026-11-07 仓库、README、生成物与GitHub源码交付整理](docs/memory/2026-11-07-repository-organization.md)：分类文档、隐藏开发入口、源码包守卫与缓存生成；保留旧输出内数据／证据，Git历史未改写或推送。

- [2026-11-07 用户授权的公开历史重置与旧发布撤下](docs/memory/2026-11-07-public-history-reset.md)：验收树建立新根、逐ref lease原子推送、私有bundle及旧发布资产校验备份；用户指定fork保持原样。

- [2026-11-07 构建缓存盘点与用户授权清理](docs/memory/2026-11-07-cache-cleanup.md)：精确删除67.327GiB编译缓存及异常递归副本，目录由75.339降至8.013GiB；产物、数据、全部验收证据与私有备份保留。缓存自动治理及递归副本起因仍未解决。
