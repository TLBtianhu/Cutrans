# Runtime与创作工作台

本文介绍当前职责分工。实现状态以[现役记忆](../memory/current.md)为准；资源细则与环境策略由各自专题维护。

## 声明与应用

> An everything-is-a-plugin creative workstation for video editing and beyond, written in Zig.

Cutrans 的核心不是复制一个传统剪辑器，而是建立一个**声明式 VM 与创作工作台**：文档是源代码，编辑器是可视化编程环境，UI、CLI、预览和未来的 Agent 都只是投影。

## 三条宪法

1. **一切皆插件**：核心保持极薄，模态、效果器和编辑器都可以被替换；宿主性取决于入度，而不是某个固定 EXE。
2. **声明唯一真源，一切皆投影**：文档、任务和视图状态不依赖某个界面；`.cut` 是可读、可 diff、可恢复的文本声明。
3. **机制与策略分家**：协议定义“做什么”，插件和 OS Port 决定“如何执行”。

当前实例化RuntimeContext，支持Surface的full／dock／floating、焦点与命中、系统任务栏、CCB启动清单和CUI视图声明。桌面、CLI、编辑器和资源管理器按App分责，不要求每个App独立进程。

`.cut v3`描述图像DAG，支持resolution、fps、testsrc、gain、invert、over、image、resize与显式output。规范身份`Birth{inspire,transform,aggregate}`和聚合参数`AggIn{x,y,opacity,t}`进入规范化文本；指纹使用固定宽度、小端整数及明确浮点位模式。v1／v2仍可读并迁移。

## 文档、History与作业

文档API v1使用Runtime epoch＋revision、一致快照、请求去重及明确节点／任务结果。响应未知时保留原请求核对；陈旧意图拒绝执行，已知结果与投影失败分账。回执只在当前Runtime有效；save、旧资源命令及原始输入尚未全部迁入受管理请求。节点发号持久高水位避免撤销、恢复和新分支复用ID。

History原子保存声明快照、指纹、游标和增量编辑；新会话可继续undo／redo，损坏记录不覆盖有效状态。任务声明、就绪、执行、完成和持久提交各自对账。

导出先持久化声明，再返回accepted与task_id；队列有界，终态逐Job归档并分页查询。Host无Shell仍自主推进，嵌入式手动Runtime保留pump。decode／求值／encode在会话锁外的单worker执行，owner锁内捕获owned Source；worker不读取live Context／Catalog。PNG先prepare／sync／记录再原子提交，终态日志失败只补持久化，不重渲染或再次覆盖。

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

`zig-out/vm-runtime/` 是独立、可装载的 Runtime Pack，包含 `cutrans_vm_runtime.dll`、启动清单、示例与许可证；`runtime-pack.json` 记录 OS/CPU ABI、入口、三种 schema、7 项能力及实际载荷文件的大小和 SHA-256。核心不依赖 wgpu，GUI 原生依赖属于独立 Shell Pack。

`cutrans_bootstrap` 在加载前校验清单与文件，经 LibraryPort 显式装载 DLL，再执行能力握手和文档命令。默认 Runtime 位置由 context 形态决定：开发输出根的 `vm-runtime/`、便携根的 `runtime/`、安装根的 `runtime-envs/default/`，不从 cwd/PATH 猜库。`--diag --data=<独立绝对路径>` 验证保存与另一实例恢复；`--headless --open <绝对路径> --purpose=verification --data=<独立绝对路径>` 只读外部原件，将规范化副本保存到验证 Session，再验证恢复。

`bootstrap/activation.zig` 统一无头诊断、回放、旧桌面入口和独立 Host 的 Runtime 激活顺序：完整性与选择锁检查 → 从当前根解析 Pack → 真实创建与 ABI/能力握手 → 文档恢复、回放或保存/恢复诊断 → 再次校验完整性 → 原子提交选择。缺文件、ABI 不符、创建失败或握手失败都不会改写原有锁。选择锁不含宿主绝对路径，`verify-runtime` 包含完整人工安装布局移动后的资源重定位用例；这不等于迁移 Windows 登记，真实安装根移动仍需处理快捷方式和关联。`activate-runtime` 只在 Host 已停止后校验候选并提交 Runtime 锁，不能证明程序文件复制和登记具备升级事务。

`zig-out/vm-shell/` 包含 `cutrans_desktop.dll`、wgpu 和桌面资源；`shell-pack.json` 使用 `cutrans-shell-pack/1`，审计实际载荷文件。默认 `--open` 会完成 `Bootstrap → VM → Shell → doc.open → editor`，GUI 文档命令全部转发给 VM，界面只接收经过指纹校验的文档镜像。`cutrans_vm.exe` 是 Bootstrap 薄入口，也提供新的 Host 控制命令。

## Host生命周期

公开控制命令见[命令参考](../reference/commands.md)。

`cutrans_vm_host.exe` 在独立进程中加载同一 Runtime Pack、完成能力握手并持有 Runtime。控制台只通过本机消息管道读取真实状态，不以 PID 冒充就绪；Detached 进程不会在控制台退出时被关闭。不同数据根使用不同管道和 `session/host.lock` 单实例锁，Host 运行时无头诊断和回放会拒绝成为第二写者，默认桌面启动则复用该 Host。

- `start` 幂等，重复启动复用同一 `boot_id`；`status` 返回真实阶段、模式、ABI、文档指纹和上次是否异常中断。
- `stop` 先进入 stopping 并保存文档，成功后才写 stopped；保存失败进入 degraded，保留 Host 供诊断和重试，不强杀进程。
- 未正常停止的实例下次启动会标记 `last_shutdown_abnormal=1`，并继续增加 `boot_id`；正常停止后该标记清零。`restart` 必须先正常停止再启动。
- `verify-host` 覆盖重复启动、第二 Host 和旧入口拒绝、幂等停止、保存失败重试、异常终止恢复及暂存目录纯净。人工 installed 布局与真实系统安装的验收须分别记录。

`cutrans_vm.exe attach` 和独立 `cutrans_shell.exe` 已实现第一阶段 Shell 附着：ShellApi 经版本化 RPC 转发到 Host，关闭 Shell 不会销毁 Runtime，重开可恢复文档、目录和 Station。`shell_handshake` 只做身份与选择预检；前端正常返回并再次通过清单校验后，`shell_commit` 才原子更新选择锁。启动失败或异常终止不会提交 Shell，外部文档仍由 Host 授权打开。`status` 同时返回真实 `present_count`，`verify-attach` 据此验证普通启动、素材和播放，而不依赖同进程日志。默认 `cutrans_vm.exe` 与 `desktop` 都会启动或复用 Host，再显式附着桌面；不再创建第二个进程内 Runtime。低级附着使用 `attach` 或 `cutrans_shell.exe`，`library` 仅作为 NanoUI 的开发诊断入口。无头诊断与回放仍使用独立 Runtime，并拒绝成为 Host 的第二写者。Host已有独立导出作业驱动；正式控制台UI、自动断线重连和完整任务GUI尚未实现。

## 帧与播放

FrameSink 将预览 `offer`、GPU `submitted`、内容 `underflow` 和输出 `unavailable` 分开记录。Shell 在纹理更新、帧获取与 `wgpuSurfacePresent` 成功后，才把带文档指纹的提交回执交给 VM；陈旧指纹会被拒绝。`verify-shell` 通过提交日志或 Host 状态验证，历史安装探针也读取过 `CUTRANS_FRAME_PRESENT_OK`；本轮安装包预检没有 GUI 提交验收。这类回执只证明 GPU 提交成功，不代表已观察到屏幕扫描完成或获得精确呈现时间。

`runtime/playback.zig` 持有每实例的静态文档流、游标、截止时间和就绪帧。首帧预取完成后才启动首个截止时间，之后同步预取下一帧；缓存命中不刷新物化时间，到点未物化才记 `underflow` 并跳过。`document_commands.pump` 驱动 `playback.start/status/stop`。`PlaybackReport` 提供游标、帧数、offer、欠账和独立的生产 `last_t`，不受静态预览候选影响。`vne/playback.zig` 的只读 View 计算当前帧，编辑器显示静态序列播放头并以 `offerAt` 上报；`--playback=N` 在桌面与 GPU 就绪后启动。`verify-playback` 验证真实时钟，`verify-shell` 必须读到 `CUTRANS_PLAYBACK_SUBMIT_OK t=3`；这是有限静态序列及投影，不是视频、音频、后台解码或视觉/手感验收。

## Pack与ABI

`vm-pack.json` 是实际被诊断消费的清单，记录：

- `vm_schema / host_api / document_schema`；
- `required_capabilities`；
- 原生依赖的 `id / abi / path`；
- 文件的 `path / byteLength / sha256`。

构建器直接从 `runtime/capabilities.zig` 读取能力真源，并计算 staging 文件哈希。诊断不仅检查清单存在，还实际读取文件验证大小和哈希。`runtime-pack.json` 是独立 Runtime 的装载清单，不与完整宿主的 `vm-pack.json` 混用。

独立Runtime的窄C ABI只传固定版本配置、字节切片、不透明句柄、整数状态和文档指纹；`RuntimeContext`、`std.Io`、分配器和Zig对象布局由DLL持有，不跨边界暴露。实例在VM自有的4MiB启动线程中同步构造，该构造线程随后结束；命令owner和导出worker另外持续运行，不能由构造线程生命周期推断没有后台驱动。History恢复状态在堆上持有，调用方无需承担内部Zig大栈要求。

**语义 ABI 与 C/C++ ABI 分家**：`.cut`、CCB/CUI、Task、History 和 VM Pack 不继承 C++ 对象布局、虚表、RTTI、STL 或异常模型，只承诺固定宽度、端序、长度、数量、版本、id、引用和生命周期。OS、CPU 和原生库的 ABI 则只留在窄 Port 中，并经过布局与真实能力自检。

`ProcessPort` 的 Job Object 是进程树资源管理边界，**不是安全沙箱**；`vm-pack.json` 也只是兼容性与依赖清单，**不是签名系统、安装器或回滚系统**。Runtime 与 Bootstrap 同进程运行，同样不构成不可信代码隔离。

当前Host／Shell ABI10、Document API v1、Resource API v2；不稳定期明确拒绝旧接口。Runtime构造和命令执行使用自有栈，不要求外部调用方提供内部Zig大栈；工作线程、owner与渲染worker按职责分离，不能由创建线程的历史记录推断当前无持续驱动。

`session/runtime.lock` 记录 Runtime 与 Shell 的 id、version、abi 和清单 SHA-256，不记录宿主路径。默认包与锁不一致会拒绝启动；显式 `--runtime=<绝对目录>` 或 `--shell-dir=<绝对目录>` 才允许迁移或回滚，验证后原子更新选择。同 payload 重装和默认卸载都保留该锁。

这还不是完整的 Runtime 管理器：没有多版本自动发现、频道下载或自动回滚；`runtime-pack.json` 与 `shell-pack.json` 是完整性清单，不是签名或安全沙箱。

语义输入、录制与回放详见[命令参考](../reference/commands.md)；运行context、安装布局、数据及服务关闭策略见[环境隔离](../environment-isolation.md)。
