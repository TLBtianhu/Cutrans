# Runtime与创作工作台

本文介绍当前职责分工。实现状态以[现役记忆](../memory/current.md)为准；资源细则与环境策略由各自专题维护。

## 声明与应用

> An everything-is-a-plugin creative workstation for video editing and beyond, written in Zig.

Cutrans 的核心不是复制一个传统剪辑器，而是建立一个**声明式 VM 与创作工作台**：文档是源代码，编辑器是可视化编程环境，UI、CLI、预览和未来的 Agent 都只是投影。

## 三条宪法

1. **一切皆插件**：核心保持极薄，模态、效果器和编辑器都可以被替换；宿主性取决于入度，而不是某个固定 EXE。
2. **声明唯一真源，一切皆投影**：文档、任务和视图状态不依赖某个界面；`.cut` 是可读、可 diff、可恢复的文本声明。
3. **机制与策略分家**：协议定义“做什么”，插件和 OS Port 决定“如何执行”。

当前实例化RuntimeContext，支持Surface的full／dock／floating、焦点与命中、系统任务栏和CCB启动清单。主桌面已统一为NanoUI页面投影，旧CUI已移除；桌面、CLI、编辑器和资源管理器按App分责，不要求每个App独立进程。命令注册表和帧边界队列是`vne.command`，Runtime与Shell共享；Runtime继续通过`runtime.command`兼容导出。预览帧经ABI11的`preview_info`/`preview_read`由VM产出，Shell只接收BGRA8帧并回执，不再在本地跑文档预览DAG。桌面Shell改用`vm_client.Context`，只持有命令、文档镜像、资源/库/播放/设备视图与路径，不再实例化`RuntimeContext`；PNG编解码在共享`imaging`模块，`vm_client`不再直接导入Runtime。

`.cut v3`描述图像DAG，支持resolution、fps、testsrc、gain、invert、over、image、resize与显式output（v3必须显式写 `output=`，省略即解析失败，防止行对齐截断被当成合法文档）。规范身份`Birth{inspire,transform,aggregate}`和聚合参数`AggIn{x,y,opacity,t}`进入规范化文本；指纹使用固定宽度、小端整数及明确浮点位模式。v1／v2仍可读并迁移。

## 文档、History与作业

文档API v1使用Runtime epoch＋revision、一致快照、请求去重及明确节点／任务结果。响应未知时保留原请求核对；陈旧意图拒绝执行，已知结果与投影失败分账。回执只在当前Runtime有效；save、旧资源命令及原始输入尚未全部迁入受管理请求。节点发号持久高水位避免撤销、恢复和新分支复用ID。

History原子保存声明快照、指纹、游标和增量编辑；新会话可继续undo／redo，损坏记录不覆盖有效状态。任务声明、就绪、执行、完成和持久提交各自对账。

导出先持久化声明，再返回accepted与task_id；队列有界，终态逐Job归档并分页查询。环境实例的作业驱动线程在同一进程内自主推进（受理后由空闲轮询拾取，无需前端通知），无前端的 `exec` 实例同样执行；嵌入式手动Runtime保留pump。decode／求值／encode在会话锁外的单worker执行，owner锁内捕获owned Source；worker不读取live Context／Catalog。PNG先prepare／sync／记录再原子提交，终态日志失败只补持久化，不重渲染或再次覆盖。

支持持久协作取消与保留原输入的新attempt显式重试。重启保留声明，中断项不自动重做，已持久取消收敛为cancelled；编码器单次调用不可强抢占，来源捕获和持久化IO仍可能占用owner。文档8节点、活跃作业8项、近期缓存40项、分页32项是当前原型限额，终态归档不限于近期缓存容量。

## 资源、驻留与版本

Catalog保存稳定身份、逻辑目录、名称、归属和来历；Source绑定定位内容；Station保存本次运行中的完整字节、hash、handle和lease。派生预览、用户工作正文及作品固定版本分别管理。

`library/catalog.json`使用`cutrans-resource-library/2`，文件夹和资源共用单调ID，parent_id=0为根。目录恢复检查重复ID、孤儿、父类型与循环；逻辑改名／移动不搬物理内容，也不镜像Windows子目录。虚拟目录是Catalog投影，不另存一份目录真相。

owned及已采用版本保存在`library/versions/<id>/<sha>.bin`，旧`library/content/<id>.bin`只作兼容读取。外部真实路径仅在Session授权目录，不能写入作品、库catalog或内容快照。普通登记不复制原件，也不自动留存永久版本。

`asset.ensure`／`resource.acquire`先核对权威当前head，命中完整Station时不回源、不重新hash、不增加lease；后者支持通用文件纯读取。严格asset.open／固定版本路径继续验证持久内容。lease归零释放，没有LRU。库及文件夹各32项、Station16项／64MiB、完整文件16MiB仍是原型限制。

`asset.check`只观察指定已加载对象，显示上次核对；变化、缺失与RAM仍可用可同时成立。绑定变化使旧观察失效，逻辑改名／移动不失效。检查不采用head、不改授权观察或作品，不是全局F5。detach优先采用匹配当前head的完整RAM，成功保持ID／显示名／父级／来历，坏版本不靠RAM自动修复。

`asset.export`生成`cutrans-content-snapshot/1`的snapshot.json＋content.bin，记录长度、SHA和来源，不含宿主路径；重新打开核验实际内容。目录快照不能冒充完整媒体或目录备份。Station重启为空，持久Source与已采用版本负责冷恢复。

现有资源UI区分未加载Catalog与内存对象，选择时按需PNG预览；库内创建与独立化分别记录created／detached。通用登记接受TXT、PNG、未知及空文件，格式解释留给App；并不因此提供全文编辑、音视频播放或完整目录provider。

定位／采用、Resource API v2、来源门禁和交付见[资源契约](../resource-operations.md)，旧授权处理见[来源身份](../source-identity.md)。GUI获取owned Source字节后本地解码，不持有可因丢回复泄漏的远端渲染租约。

本地外部／云端外部／VM专属内容及独立App是产品目标；当前尚无完整来源App、可变owned工作正文、通用目录或VM全局IO中介。用户澄清与后续规划见[架构记录](../memory/2026-11-07-architecture-plan.md)。

## 独立 VM Runtime（第一阶段已实现）

`zig-out/vm-runtime/` 是独立、可装载的 Runtime Pack，包含 `cutrans_vm_runtime.dll`、启动清单、示例与许可证；`runtime-pack.json` 记录 OS/CPU ABI、入口、三种 schema、7 项能力及实际载荷文件的大小和 SHA-256。核心不依赖旧 wgpu/zgui 栈，NanoUI 原生依赖属于独立 Shell Pack。

`cutrans_bootstrap` 在加载前校验清单与文件，经 LibraryPort 显式装载 DLL，再执行能力握手和文档命令。默认 Runtime 位置由 context 形态决定：开发输出根的 `vm-runtime/`、便携根的 `runtime/`、安装根的 `runtime-envs/default/`，不从 cwd/PATH 猜库。`--diag --data=<独立绝对路径>` 验证保存与另一实例恢复；`--headless --open <绝对路径> --purpose=verification --data=<独立绝对路径>` 只读外部原件，将规范化副本保存到验证 Session，再验证恢复。

`bootstrap/activation.zig` 统一无头诊断、回放、单进程环境实例的 Runtime 激活顺序：完整性与选择锁检查 → 从当前根解析 Pack → 真实创建与 ABI/能力握手 → 文档恢复、回放或保存/恢复诊断 → 再次校验完整性 → 原子提交选择。缺文件、ABI 不符、创建失败或握手失败都不会改写原有锁。选择锁不含宿主绝对路径，`verify-runtime` 包含完整人工安装布局移动后的资源重定位用例；这不等于迁移 Windows 登记，真实安装根移动仍需处理快捷方式和关联。`activate-runtime` 只在没有环境实例运行时（取得数据根锁后）校验候选并提交 Runtime 锁，不能证明程序文件复制和登记具备升级事务。

默认 `--open` 会完成 `Bootstrap → VM → doc.open → editor`，GUI 文档命令全部转发给同进程的 VM，界面只接收经过指纹校验的文档镜像。主桌面统一使用 NanoUI，包含首页、编辑器、资源库、CLI 和任务视图；`cutrans.exe` 是唯一公开入口，`cutrans_bootstrap.exe` 只做无界面诊断与回放。

## 单进程环境实例

2026-11-12 起没有独立 Host 进程、Shell 附着、RPC 或重连（[决定与验证](../memory/2026-11-12-single-process.md)）。每次运行 `cutrans.exe` 都是一个环境实例，`bootstrap/main.zig` 的 `runEnvironment` 依次：解析 context 与数据根 → 校验 App 载荷与选择锁 → 准备 Runtime（默认静态）→ 认领数据根 → 取得 `session/instance.lock`（同时持有旧 `session/host.lock`）并写生命周期记录 → 创建 Runtime、能力握手、提交 Runtime 选择 → 启动作业驱动线程 → 把进程内的 `ShellApi` 表与 `vne.environment_control.Control` 交给前端。

- 前端可以是桌面、`library` 资源库，或无窗口的 `exec` 脚本；App 代码不知道、也不需要知道 VM 在本进程。
- 生命周期记录 `session/lifecycle.txt` 有 starting／running／stopping／stopped／degraded 与 `boot_id`；上一次未写 stopped 即在下次启动报告 `abnormal_previous=1`。旧 `session/vm-host.txt` 只读兼容一次以延续序号。`status` 只读这份记录。
- 安全退出：`prepareStop` 写 stopping 并关闭 Runtime 的业务受理（`cutrans_vm_set_admission`：拒绝新的命令、文档提交、资源登记、工作提交和外部打开；读取、清理与 `task.cancel_all`、`doc.save` 仍执行）；`cancelJobs` 协作取消；`resumeWork` 撤销退出并重开受理；`stopEnvironment` 提交 App 选择、暂停驱动、冲刷作业终态、保存文档并写 stopped。保存失败写 degraded、重开受理，App 可重试。
- 前端出错返回时，环境仍执行正常停止，再返回前端的错误；进程被强制结束只会让下一次启动报告异常结束。
- 语义输入事件未经过受理闸门：退出界面是模态的，桌面每帧都会推送输入。

## 帧与播放

FrameSink 将预览 `offer`、GPU `submitted`、内容 `underflow` 和输出 `unavailable` 分开记录。Shell 在 NanoUI 纹理同步与 swap-chain present 成功后，才通过 `on_present` 把带文档指纹的提交回执交给 VM；陈旧指纹会被拒绝。`verify-shell` 通过提交日志或 Host 状态验证，历史安装探针也读取过 `CUTRANS_FRAME_PRESENT_OK`；本轮安装包预检没有 GUI 提交验收。这类回执只证明 GPU 提交成功，不代表已观察到屏幕扫描完成或获得精确呈现时间。

`runtime/playback.zig` 持有每实例的静态文档流、游标、截止时间和就绪帧。首帧预取完成后才启动首个截止时间，之后同步预取下一帧；缓存命中不刷新物化时间，到点未物化才记 `underflow` 并跳过。`document_commands.pump` 驱动 `playback.start/status/stop`。`PlaybackReport` 提供游标、帧数、offer、欠账和独立的生产 `last_t`，不受静态预览候选影响。`vne/playback.zig` 的只读 View 计算当前帧，编辑器显示静态序列播放头并以 `offerAt` 上报；`--playback=N` 在桌面与 GPU 就绪后启动。`verify-playback` 验证真实时钟，`verify-shell` 必须读到 `CUTRANS_PLAYBACK_SUBMIT_OK t=3`；这是有限静态序列及投影，不是视频、音频、后台解码或视觉/手感验收。

## Pack与ABI

`vm-pack.json` 是实际被诊断消费的清单，记录：

- `vm_schema / host_api / document_schema`；
- `required_capabilities`；
- 原生依赖的 `id / abi / path`；
- 文件的 `path / byteLength / sha256`。

构建器直接从 `runtime/capabilities.zig` 读取能力真源，并计算 staging 文件哈希。诊断不仅检查清单存在，还实际读取文件验证大小和哈希。`runtime-pack.json` 是独立 Runtime 的装载清单，不与完整宿主的 `vm-pack.json` 混用。

独立Runtime的窄C ABI只传固定版本配置、字节切片、不透明句柄、整数状态和文档指纹；`RuntimeContext`、`std.Io`、分配器和Zig对象布局由DLL持有，不跨边界暴露。实例在VM自有的4MiB启动线程中同步构造，该构造线程随后结束；命令owner和导出worker另外持续运行，不能由构造线程生命周期推断没有后台驱动。History恢复状态在堆上持有，调用方无需承担内部Zig大栈要求。

**语义 ABI 与 C/C++ ABI 分家**：`.cut`、CCB、Task、History 和 VM Pack 不继承 C++ 对象布局、虚表、RTTI、STL 或异常模型，只承诺固定宽度、端序、长度、数量、版本、id、引用和生命周期。OS、CPU 和原生库的 ABI 则只留在窄 Port 中，并经过布局与真实能力自检。

`ProcessPort` 的 Job Object 是进程树资源管理边界，**不是安全沙箱**；`vm-pack.json` 也只是兼容性与依赖清单，**不是签名系统、安装器或回滚系统**。Runtime 与 Bootstrap 同进程运行，同样不构成不可信代码隔离。

当前 Shell ABI、Document API 与 Resource API 版本以 `vne/abi.zig`、`vne/resource_api.zig` 的 `version` 常量和[现役状态](../memory/current.md)为准，本文不复制会漂移的版本号；不稳定期明确拒绝旧接口。Runtime构造和命令执行使用自有栈，不要求外部调用方提供内部Zig大栈；工作线程、owner与渲染worker按职责分离，不能由创建线程的历史记录推断当前无持续驱动。

`session/runtime.lock` 记录 Runtime 与 Shell 的 id、version、abi 和清单 SHA-256，不记录宿主路径。默认包与锁不一致会拒绝启动；显式 `--runtime=<绝对目录>` 或 `--shell-dir=<绝对目录>` 才允许迁移或回滚，验证后原子更新选择。同 payload 重装和默认卸载都保留该锁。

这还不是完整的 Runtime 管理器：没有多版本自动发现、频道下载或自动回滚；`runtime-pack.json` 与 `shell-pack.json` 是完整性清单，不是签名或安全沙箱。

语义输入、录制与回放详见[命令参考](../reference/commands.md)；运行context、安装布局、数据及服务关闭策略见[环境隔离](../environment-isolation.md)。


## EnvironmentSession 与启动屏障

进入 App 之前，App 载荷校验、Runtime 能力握手和一致 Runtime 快照必须已经成功。`vne/environment_session.zig` 以 Runtime 随机 epoch 建立不含物理路径的环境身份；它不包含数据根、资源目录、可执行路径或用户内容，也不代替授权。

桌面、资源库和本机文件初始化必须取得有效 Session。App 建立后只使用环境身份和业务接口，环境失效由 epoch／投影错误处理，不回退到另一条物理路径暗中启动新实例。

`ShellConfig` 的物理路径仍是过渡输入，未在本轮强行隐藏。`cutrans.exe` 是唯一入口，桌面、资源库与 `exec` 都在同一个进程内；旧 Shell EXE、旧 Shell Pack 与 `--role` 已删除。

统一入口默认使用静态 RuntimeProvider：`runtime/native_api.zig` 编成静态库链接进 EXE，经 `runtime/static_api.zig` 的同一 C ABI 调用，不需要 Runtime DLL。`bootstrap/activation.zig` 仍为静态／动态 Provider 共用选择锁、能力握手与 Shell 提交。静态锁身份来自内置语义描述而非磁盘文件哈希；显式 `--runtime=<绝对目录>` 保留动态 Pack，`--runtime=builtin` 用于显式静态选择与迁移。静态运行时的只读资源根是桌面 Payload，详见[静态 Runtime 记录](../memory/2026-11-09-static-runtime.md)。

`vne/payload.zig` 区分 `builtin` 与 `legacy_shell`：`payload/desktop/` 和 `payload/nanoui-library/` 只携带资源、清单和许可证，`entry=builtin` 不要求旧 Shell EXE。`cutrans-payload/1` 复用大小与 SHA-256 文件校验，Shell 身份锁记录 Payload 清单哈希。默认缺失或损坏 Payload 不会隐式回退；显式 `--shell-dir` 只选择另一个 Payload 目录，旧 Shell Pack 已不再受支持。详见[PayloadSource 记录](../memory/2026-11-09-payload-source.md)。

环境内安全退出已实现：`prepare_stop` 先停止新业务，`cancel_jobs` 复用持久协作取消，`resume_work` 可撤销尚未完成的退出，最终暂停驱动、冲刷结果并保存（见上文“单进程环境实例”）。NanoUI 在环境正常停止前不关闭，失败可重试，草稿不自动提交；这不等于强制抢占或 OS 沙箱。详见[安全退出实施记录](../memory/2026-11-09-safe-exit.md)。

portable payload／context 已内嵌进 `cutrans.exe` 并有原型验证（见[内嵌 payload](../memory/2026-11-10-embedded-payload.md)）；受管发布、真实安装与最终单文件发行仍未完成。具体启动屏障见[环境先验记录](../memory/2026-11-09-environment-session.md)。
