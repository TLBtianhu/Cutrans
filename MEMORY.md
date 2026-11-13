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
- 2026-11-12 起：用户可见能力、入口、构建步骤或限制变化时，同一片同步更新 `README.md` 与[文档导航](docs/README.md)；README 只写外部可理解的事实，不灌入内部施工细节。（用户要求，长期有效）

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

- [2026-11-12 时间三分：时间线不是底层概念（v4 ADR 一节）](docs/memory/2026-11-12-time-three-senses.md)：序数时间 `t` 是核心（流的自变量）；秒和 fps 属于制式与参数，归消费者；时间线是编辑器投影，片段在时间线上的位置就是聚合输入的相对时间参数。Blender 采用同一分法。纯粹性的止损规则是问“这条规则对任意类型成立吗”，不问“它在物理上存不存在”。v4 需要处理 `Document.fps` 与宪法不一致的问题。同日在[界面模型页](docs/memory/2026-11-12-app-plugin-ui-model.md)末尾补记：在新模型下，NanoUI 降为宿主内部的实现工具，并重排了缺口与上游 PR 的优先级。

- [2026-11-12 App／插件界面模型：自渲染像素 + 稀疏界面 schema（用户提出，讨论中）](docs/memory/2026-11-12-app-plugin-ui-model.md)：所有 App 和插件分为“自渲染像素”与“稀疏界面 schema”两部分，界面使用以 NanoUI 为基础的 Cutrans 原生 GUI schema API；素材预览就是一个功能性插件。Claude 的分析：与 VST／CLAP、OpenFX、AE、Blender 同构；一份参数 schema 同时投影为 GUI、MCP 工具 schema 和文档；分为标准控件、宿主富组件、自渲染区三层；schema 保持稀疏，不演变成排版语言。它是 2026-10 CUI 的继任者。同日补记：两类“舒服”的化归（宿主参考前端二级 API 工作流，schema 参考 AE／Blender 定义风格），以及用户修正：暂不考虑版本迁移，宿主契约几乎不变，插件更新即新插件（同 VST），排版克制参考“MC 自由但不会成为编程语言”（原讨论在记忆中缺失，待用户复述）。

- [2026-11-12 界面渲染与媒体渲染分家（用户立法）](docs/memory/2026-11-12-gui-media-split.md)：GUI 用 NanoUI；视频、图片等媒体渲染必须完全自研并归 VM，不得使用 NanoUI（类比 AE：界面框架与原生特效分开）。两侧只通过帧与数据交付接触，叠层由 GUI 绘制，分析结果由 VM 计算。核对到一处灰区：GUI 仍在本地解码素材预览 PNG，待定。待定接口：媒体侧 GPU 后端，以及与 NanoUI 的 D3D11 纹理零拷贝互操作。

- [2026-11-12 统一为单进程虚拟环境：删除 Host 进程](docs/memory/2026-11-12-single-process.md)：用户决定彻底删除 Host（取代 11-08 中 Claude 关于保留进程边界的推荐）。一个进程就是一个环境实例：进程内 `ShellApi` 加 `Control` 安全退出，业务受理闸门下沉到 Runtime，单写者锁，生命周期记录；删除 Host、RPC、管道、重连、未决标记、`--role`、旧 exe 与旧 Shell Pack；调试改用 `cutrans.exe exec --script=<jsonl>`、App 隐藏场景、DLL ctypes 与只读 `status`。全部改写的验证与回归通过；注册边界的既有回归仍未修。**新会话先读这一页。**

- [2026-11-12 参照系：FilmCraft／EffectCraft 现状与对齐方案（调研，未实施）](docs/memory/2026-11-12-artcraft-reference.md)：用户决定以两者最新版本为参照系，学习并做理念的解耦与对齐（“Linux 对照 Unix”）。记录两者的分层、命令注册表、Tick 时间基准、`Arc` 结构共享快照撤销、效果定义即数据、CPU 参照答案与 GPU 对比测试；对照 Cutrans 列出对齐、借鉴与应保持的差异（声明式 comp 图，人与 AI 共写源码）；Claude 对整体用 Zig 重写持保留意见，建议学接口、复用零件。同页悬置两项待确认：v4 改为先定内存模型、`.cut` 后置；“三种生法已被推翻”在记忆中查无记录，待用户复述。只读了文档，未读源码。

- [2026-11-12 容量与回收（窄版）：本机已验证](docs/memory/2026-11-12-capacity-reclaim.md)：（本机验证补记）代码一次编译、零修改；`build test` 退出 0，三个被标失败的测试二进制单独运行全部通过，四个新测试 OK；`verify-assets` 新增真实 DLL 上的 `library.remove` 断言并修正自 11-07 起失效的 catalog 格式断言；architecture／work-documents／local-sources／repository 均通过。另发现 `verify-resource-registration` 受管根边界在 HEAD 上就已回归（未修，见 `current.md`）。以下为编写时原文——`library.remove`（只删无活引用的条目与空文件夹，终态归档作业不阻止，磁盘字节留作孤儿，ID 不复用，清理该资源的工作回执以免冷恢复失败）、最后引用删除时自动释放持久来源授权、库／授权槽满统一返回 `queue_full`（UI 显示 `ResourceCapacityReached`）、四个新测试。云端 Linux VM 无法运行 `tools/dev.ps1`，**全部未编译**、工作区未提交；由本机 Windows Claude Code 会话接手验证。**新会话先读这一页，再读评审交接。**

- [2026-11-12 评审交接：审计复核、威胁模型校正与接续顺序](docs/memory/2026-11-12-review-handoff.md)：对审计检查点的四处修正（#9 表述、冲突的下一步清单、`current.md:141` 残留、`runtime.md` ABI/重连漂移）；P0 #1–#3 改判为同用户完整性而非提权，管道抢注归多用户未验收；新增发现“文档模型是格式死路”和“一切皆插件零实现”；商定顺序为容量回收（窄版）→ vne 测试根 → v4 格式 ADR → D 注册表 → 两项小修（两处调整已于后续会话由用户确认）。评审本身只读；其后已按第五节刷新 `current.md`、审计检查点与 `runtime.md`。**新会话先读审计检查点，再读这一页；两者冲突以本页为准。**

- [2026-11-12 审计结论与进度检查点](docs/memory/2026-11-12-audit-checkpoint.md)：全仓审计的完整落盘（P0：RPC 迁移许可来自 wire、本机 RPC 无认证、`.command_result` 绕过受管语义；P1：Pack 校验与装载分离、payload 缓存根、旧 import 绕过来源边界、`asset.export` 目标无边界、容量无回收、GUI 落后不重同步；P2 与基础设施另列），加上本次两个切片已修/未修清单、复现命令与下一步顺序。**恢复会话先读这一页。** 功能提交见 `0bc7ba51` 与 `714ebafd`。

- [2026-11-12 工作正文发布顺序与草稿基线](docs/memory/2026-11-12-work-publication-order.md)：`library/work|drafts/<id>/` 的正文与草稿改为「revision/token + 内容哈希」命名，旧 `<revision>.bin` 只读兼容；这样 Catalog 提交失败留下的未引用正文不会再让同一 revision 的重试撞上 `WorkContentMismatch`。`save_draft` 的 `base_revision` 现在必须等于当前工作头（原来保存接受 `base < head`、提交却要求相等，会写出一份永远提交不了的草稿）。`verify-work-documents`、`verify-architecture`、`verify-repository` 退出 0，`resource_library` 测试二进制单独运行 143/143 通过。同片修正上一片对锁测试的错误归因：两个锁测试**本身通过**，失败只出现在构建运行器路径（HEAD 同样复现，根因未定）。已提交 `714ebafd`。

- [2026-11-12 保存原子性与 v3 显式输出](docs/memory/2026-11-12-atomic-save-and-v3-output.md)：`.cut` 落盘改用 `vne/atomic_write.zig` 的临时文件＋flush＋原子替换（全仓此前唯一一处截断式持久写）；History journal 记录并还原 `dirty`/`legacy`，`doc.save` 改为写前日志→原子目标→确认标记；canonical v3 要求显式 `output=`，行对齐截断被拒。`verify-write-order`（4 项真机断言）、`verify-architecture`、`verify-repository`、`build test` 退出 0，新增 `vne/documents.zig` 测试根 22/22 通过。同片暴露三项未修复问题：**vne 模块根测试从未执行**、两个锁测试在构建运行器下被标记失败但单独运行通过（HEAD 同样复现）、运行器型失败不改变 `build test` 退出码。已提交 `0bc7ba51`。

- [2026-11-12 架构评审与收敛方案（建议，未实施）](docs/memory/2026-11-12-architecture-review.md)：定义“清晰”的可验收标准，列出 Runtime 单体、命令/ABI 多处接线、持久格式分散等结构债，并提出契约冻结、单一真源、域接口、数据生命周期、测试与构建、产品硬化六阶段。**尚未批准或实施**；建议从阶段 0 + 命令 manifest v2 + `verify-contract` 开始。

- [2026-11-12 目录成员显式收纳](docs/memory/2026-11-12-directory-member-collection.md)：本机文件页新增“收录到同名文件夹”，以当前目录名在资源库根下创建/复用文件夹，登记单个成员后用既有 `library.move` 建立 `parent_id` 关系；资源身份、内容哈希与来源授权不变。无新 ABI/命令/Catalog 格式；`verify-local-sources` 的隐藏 GUI 场景验证文件夹与成员关系。

- [2026-11-12 未决请求：停止等待与跨 Shell 标记](docs/memory/2026-11-12-pending-wait-stop.md)：新增 `hasPending`/`abandonPending`，编辑器在结果未确认时显示警告和“停止等待未确认修改”；停止等待不重放、不回滚，镜像刷新后显示 VM 真实状态，后续编辑靠 expected stamp 防止静默覆盖。`data/shell/pending-unknown.txt` 让下一个 Shell 仍能看到“可能已执行”的提示，确认后清除；标记不携带可重放请求。单元测试、`test-nanoui-desktop`、`verify-payload` 与 `verify-unknown-result`（含真实 Host 丢回复 + 重启、Shell 退出后标记警告）通过；Host/Shell 两段已闭环，按钮点击与发行验收仍未覆盖。

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
