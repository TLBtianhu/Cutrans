# 现役状态（2026-11-12）

这是当前实现的摘要。业务最近完成到 C2c3 第一片（目录成员显式收纳）；此前已完成工作正文、本机文件、环境启动屏障、同 EXE 进程角色、静态 Runtime、PayloadSource、环境内安全退出、Host 重连与未决结果闭环。各次实际验收以对应记录为准。当前进度、剩余问题与接续顺序见文末[2026-11-12 进度快照](#2026-11-12-进度快照)；[旧检查点](2026-11-09-checkpoint.md)与[旧进度台账](2026-11-08-progress.md)保留为历史记录。各次历史测试只证明当次代码及产物。

## 产品与边界

- Cutrans 是声明式 VM 与多域创作工作台的早期原型；当前实现最小单文档静态图像闭环。
- `.cut v3` 支持 testsrc/gain/invert/over/image/resize，规范化文本、稳定引用与内容指纹。
- A1已加入节点发号持久高水位及文档／History候选提交；失败不发布半编辑，撤销／恢复／新分支不复用节点ID。A2的文档API v1提供Runtime epoch＋revision、文档操作前置版本、请求去重与一致文档快照；当前Host／Shell为ABI11（2026-11-10 Preview ABI 升级；以 `vne/abi.zig` 的 `version` 为准），独立资源API已在C2c2显式升v2，并在工作正文切片升v3，在本机文件切片升v4；保留旧定位／采用／登记语义，新增工作快照／提交与一层只读浏览。Shell分账已知Outcome和投影失败，结果未知时仅重试原请求。工作成功回执已可跨恢复，旧文档／普通资源回执仍不跨Runtime重启保存；save／旧资源命令／原始语义输入尚未全部转为受管理请求。
- PNG 导入、预览、合成与导出可经同一命令入口完成；History、Task、Catalog 和授权有恢复记录。
- 默认公开入口启动或复用独立 Host，再附着 desktop；关闭 Shell 与停止 VM 分开。
- B1已接通持久导出声明、有界FIFO和Host无Shell自主推进；输出先prepare／sync／记录再原子提交，终态落盘失败只补日志。可分页查询归档与错误；重启保留声明并标interrupted，不自动重做可能已经写出的输出。
- 资源库持有稳定 ID、引用/拥有状态、虚拟文件夹和显式独立化；Station 是内存活动对象，缓存可重建。
- C1在素材插入／Job受理前，将采用的库Source按稳定ID＋SHA-256留存到`library/versions/`。库刷新不改已有文档／History／Job；外链变化或删除后可读取已留存旧字节，严格来源读取仍检查漂移，已加载浏览另走C2c1入口。旧未留存版本仅允许同hash兼容读取，不承诺恢复未保存过的外链字节；版本列表及保留UI仍待完善。
- C2a修正Win32文件信息布局及读取身份与字节的竞争窗口；已知持久文件授权拒绝被目录快照替换。新外链catalog以v2身份scheme保存，旧v1保留为待确认且不自动改写；已留存库版本仍可读。`source.reauthorize`仅显式核对原路径／预期hash、保存真实身份，不改库head／作品；[规则与底层命令](../source-identity.md)不代称完整恢复UI。
- C2b实现资源独立stamp／一致快照、无副作用候选proof、relocate／adopt和当前Runtime回执；Runtime、Host与共享Shell客户端使用同一契约。相同内容才能重新定位，明确采用只更新库head；同路径新对象使用新授权绑定。create／detach统一不可变版本，失败不覆盖／删除旧内容；恢复保持发号高水位并使Station归属投影失效。完整GUI入口尚未接入，[契约与边界](../resource-operations.md)，实际本轮验收另记。
- C2c1新增已登记资源的`asset.ensure id sha256`：VM按当前head核对后复用完整Station字节，命中不回源／不增lease。`asset.check handle`只记录指定已加载对象的来源观察，绑定变化后旧观察失效，来源失联仍保留内存。detach优先从匹配当前head的完整RAM独立保存，保持ID／显示名／父级。两UI精确选择版本，候选失败留旧预览，桌面必经动作区分同步结果与投影失败；严格open／fixed版本读取保持原校验。仍是PNG、同步核对、lease归零释放；没有LRU、全局F5或新代际自动采用。
- C2c2新增Resource API v2普通只读文件登记与`resource.acquire id sha256`，TXT／PNG／未知／空及16MiB文件不依赖解码；默认reference，登记与消费支持分账，公共Shell交付验证精确Ref及bytes哈希。新来源口岸在同handle读正文前排除真实托管根／junction别名并拒多硬链；旧URI／mount仍兼容，非全局IO中介或强沙箱。旧换源仍限PNG，通用目录／完整App入口未实现。
- 工作正文切片将Resource API升v3：owned资源具有独立工作revision和草稿token，自动保存草稿不推进工作头，显式提交才发布新正文。正文与草稿按revision完整发布，Catalog v4同次提交资源头、草稿元数据、成功回执与客户端高水位；最近64条回执为环形覆盖，不再有终身64次上限，跨恢复重放不重复创建或提交。自动保存按空闲400ms防抖，Ctrl+S／关闭强制落盘。NanoUI支持创建、编辑和关闭保护，Document／History／排队Job继续固定原hash。失败回执、未决Shell队列、目录和共享异步求值仍按既有边界处理。
- 本机文件切片将Resource API升v4：新增RPC31一层只读浏览与RPC32临时成员读取。浏览只保留路径／游标／条目投影，不隐式创建ResourceId、授权、留存或Station；目录最多4096项、每页128项。NanoUI本机文件页支持导航、刷新、文本／PNG预览和显式收录，登记与预览／消费分账，插入文档仍走既有资源库动作。
- Task活跃队列8项（含执行中）、近期缓存40项、分页32项，终态逐Job归档且默认保留，已移除终身32项上限；文档8节点、库32资源仍是原型限额。B2已将导出decode／求值／编码移至会话锁外的单worker，支持持久协作取消与新ID／attempt重试；原输入版本不随当前编辑变化。
- 2026-11-12 评审确认的两项结构性边界（已核码，见[评审交接](2026-11-12-review-handoff.md)第三节）：
  - **文档模型是格式死路，不只是容量问题**：`vne/documents.zig` 为 `nodes: [8]Node`、单一 `output_id`、fps 写在文档内、没有时间维度；`Op` 只有 testsrc／gain／invert／over／image／resize。有合成运算，但没有可复用、有作用域的合成单元（宪法“一 comp 一流”）。History 每条按值保存完整 before／after Document（`runtime/history_journal.zig`），放开 `[8]` 需要改快照所有权，不是改数组长度；v3 强制单一 `output=` 进一步固化单输出。后续以 v4 格式 ADR 处理。
  - **“一切皆插件”尚无实现**：`runtime/capabilities.zig` 是手写静态声明表，只与 adapter_ids 对账，是校验表而不是装载器；没有按依赖 DAG 装载插件的机制，运行时唯一可装载物是整个 Runtime DLL Pack。`Op` 含 `image` 而声明表无 `node.image`，是否有意未确认。
- 真实视频音频、通用不可信插件、强制抢占式取消、Runtime 下载/自动更新、多版本安装和跨 OS 实机仍未完成。

## 安装与 UI

- Windows 当前用户安装，单根包含 app/runtime-envs/shells/payload/data；只有一个公开 Cutrans 快捷方式。
- 当前只允许同程序资产幂等重装；变更资产升级在复制前拒绝，完整回滚事务待实现。默认卸载保留用户数据。已有真实体验安装未被本轮更新或清理。
- desktop 已统一为 NanoUI，包含首页、编辑器、资源库、本机文件、CLI 与任务视图；独立 NanoUI 资源库诊断 Shell 保留。窗口使用原生 frame + 自绘标题栏（`decorations=true`、`title_bar=.hidden`）：自绘最小化/最大化/还原/安全退出，Alt+F4/任务栏关闭也先进入安全退出；默认以 Windows 最大化启动，F11 最大化/还原，原生 resize/Snap/系统菜单/DWM 阴影由 NanoUI `chrome.zig` 保留。资源库仍可新建和编辑工作正文、自动保存草稿、显式提交并阻止关闭丢失未确认输入。外部文件可拖入窗口或经系统对话框走 `register_file` 登记，资源库显示引用/拥有和来源状态，VM 私有目录拒绝。本机文件页只读浏览并在显式收录时登记，文本和 PNG 可临时预览。图片仍走原预览。zgui/zglfw/wgpu 与旧 CUI 已移除，完整构建和源码包审计通过，实际 Host/Shell 场景回归另行记录。
- `EnvironmentSession` 以既有 Host 附着、Shell 校验和一致 Runtime 快照建立无物理路径的 epoch 环境身份。桌面、资源库和本机文件在启动屏障后共享该先验，主 ABI 不变；它不是授权凭证或实时状态机。详见[环境先验记录](2026-11-09-environment-session.md)。
- `cutrans.exe` 已承担控制器、Host、桌面与资源库角色；这些角色仍是独立进程，经过同一 Pack 校验和 Session 启动屏障。统一 Host 默认使用静态 Runtime，不需要 Runtime DLL；显式目录仍选择动态 Pack，锁身份切换需显式 `--runtime=builtin`。默认 NanoUI 载荷位于 `payload/`，不再要求旧 Shell EXE；缺失外部 payload 时会从 exe 内嵌 blob 物化到临时缓存并重新校验，显式 `--shell-dir` 与损坏 manifest 仍失败、不回退内嵌。旧 Pack 仅在显式 `--shell-dir` 时回退。默认桌面启动不再把解析后的默认载荷路径当作显式 `--shell-dir`：同 id 但 manifest 哈希变化默认拒绝 `ShellLockMismatch`，内置桌面／资源库兄弟 id 之间切换仍允许。portable 与 installed context 都已内嵌；外部 `app/cutrans-context.json` 仍优先，安装器已不再复制该文件或 `vm-pack.json`，只装 exe/licenses/README；安装器已切到 `cutrans.exe`、瘦身并通过 preflight-only，真实安装/更新/卸载/发布仍未完成；[角色实施](2026-11-09-same-exe-roles.md)、[静态 Runtime](2026-11-09-static-runtime.md)、[PayloadSource](2026-11-09-payload-source.md)、[内嵌 payload](2026-11-10-embedded-payload.md)、[安装器入口](2026-11-10-installer-entry.md)。
- NanoUI 已有独立“退出虚拟环境…”入口：停止新业务、等待或协作取消任务、提交 Shell 身份、保存并停止 Host；失败可重试，草稿不自动提交。普通窗口关闭（原生 X/Alt+F4/任务栏/自绘 X）现在也先进入同一安全退出，退出进行中拒绝关闭，失败后才允许“仅关闭窗口”，下次启动会收尾 Host。[安全退出实施与验证](2026-11-09-safe-exit.md)。portable payload/context 已内嵌进 `cutrans.exe`，只有 exe 的 headless 场景通过；安装版也内嵌 installed context，但外部 context 仍优先，安装器只通过 preflight/artifact，真实安装未做；[目标与状态机](2026-11-08-single-exe-safe-exit.md)。
- 用户于本轮指定深靛蓝底、冰蓝到淡紫强调、少量暖金、细高光与轻微金属渐变。颜色纯数据由 `uikit/palette.zig` 共享，具体规则见 [UI规范](../ui-style.md)。
- 无头功能与 D3D 离屏 readback 不代替真实窗口视觉、IME、焦点与操作手感，后者仍需用户主动体验。

## 本轮工程重构

- NanoUI 对齐官方 `7b32272` / v0.14.0，官方基线 + 六个 Cutrans 本地补丁（`ui.d3d11`、`window_maximize`、`on_present`、`kv`），归档哈希和补丁清单在 `third_party/nanoui/VENDOR.json`。
- Zig 保持 0.17.0，编译器和标准库由同一固定归档恢复；源码不再携带整套工具链。
- Pack 使用缓存生成路径声明输入输出；安装前缀仅承接最终投影。测试模板、验证输出根与安装验收互斥统一管理。
- 自动化Python子进程统一无控制台启动；Zig构建树使用预先隐藏的共享控制台，日志和退出码保留。Agent／无人值守构建须经统一隐藏入口，真实GUI窗口另行验证；[实施与证据](2026-11-07-quiet-automation.md)。
- 记忆由单一入口索引主题与历史。个人画像已移除，历史公网部署地址已换为文档示例地址；公开Git历史的后续授权重置与私有备份见下条。
- 当前分支收尾提交与实际测试结果见下方后续记录，不以这些施工说明冒充验收。
- 仓库入口已整理：短README、分类docs导航、研究／历史与现役分开、公开源码与便携README分开；隐藏开发入口`tools/dev.ps1`和源码包守卫已接入。生成UI／启动二进制只进入缓存，Git不再跟踪旧pyc；源码包补齐现役工具。旧输出中的安装备份与验收数据继续保留，不能整目录删。随后用户明确授权，公开master已重建为干净快照历史、旧标签／试验Release已备份后撤下，本机私有历史和用户指定fork保留；见[历史重置记录](2026-11-07-public-history-reset.md)。

## 后续切片

用户于2026-11-07授权连续创作会话优化计划：身份与提交一致性→Host自主作业与恢复→资源版本与求值服务→声明注册与检查器→完整场景迁移NanoUI并清退旧栈，之后引入真实时变媒体。以PNG创作、双导出、关闭Shell后继续及重连恢复场景牵引；[计划与本轮A1范围](2026-11-07-architecture-plan.md)区分未完成项和实际验证，不把计划提前算作现役能力。

A1／A2、B1／B2完成各自已记录的切片；C已推进到C2c2通用只读单文件登记与统一Ref交付，重新定位／明确采用核心已在C2b实现，工作正文与固定版本分离及本机文件薄App入口已落地，但完整恢复UI、通用换源与共享求值尚未完成。D声明schema／检查器仍待办。E的主场景NanoUI迁移与旧栈清退已完成，真实视觉／IME／焦点和操作手感仍未验收，不把主场景完成等同于完整体验验收。

下一片可补目录成员显式收纳关系，再继续完整FrameLease、共享异步求值及会话恢复；目录整体收纳、工程目录独立化、流式超大目录、云来源和通用换源分片推进，随后接D和真实时变媒体。工作正文与本机文件实施验收分别见[工作正文记录](2026-11-08-work-documents.md)和[本机文件记录](2026-11-08-local-file-sources.md)。

发行推进已建立 `EnvironmentSession` 启动屏障、同 EXE 多角色入口、默认静态 RuntimeProvider、外置 PayloadSource、payload/portable context 内嵌回退与环境内安全退出；动态 Runtime Pack 和显式旧 Shell Pack 保留回退。portable-single 已产出单 exe；安装器入口已切到统一 `cutrans.exe` 并瘦身，但真实安装、安装版 context 迁移、旧布局升级和受管发布仍未完成；物理 ShellConfig 路径、真实 GUI／IME 和安装验收仍待后续。

save／旧命令受管理收口、跨文件通用事务、完整失败回执、未决Shell请求恢复、自动重连、完整任务／恢复工作流及其它ABI栈边界仍未齐；单worker／协作取消和单次I/O期限不是强制抢占或整体停机保证。原型容量、来源慢IO、旧URI／mount兼容、symlink未覆盖、上游新提交未适配、Zig间歇异常未定位、缓存／证据无自动预算及安装升级卸载未验收均继续保留为问题。下一轮大量构建前需治理缓存增长，后续上游更新前需审官方／fork／Cutrans差异；旧数据、证据和体验安装不据此自动清理或更新。

## 本轮验收

工程基线、NanoUI 与共享暗色材质已经实现并验证，具体命令、通过项和故障修正见 [2026-11-06实施记录](2026-11-06-foundation.md)。真实窗口/IME与真实安装升级卸载未在本轮验收。

开发／分发／本机测试隔离已实现统一 product 与运行 context、purpose/form/channel 标记、物理路径分离、构建根禁写、只读 Pack 与独立诊断；GUI 禁用隐式 cwd ini，DLL 搜索限定所选包与 System32。完整契约见 [环境隔离说明](../environment-isolation.md)。旧正常会话仅从对应形态默认位置识别格式，非默认无标记旧目录保留待核实迁移。

隔离实施的最终源码构建为155/155 steps、1126/1126 tests通过。真实分发 Runtime/Host/Shell、NanoUI、12组环境与故障负例、全新带空格 prefix 均通过；本机既有4清单／48应用文件及系统入口前后相同、Cutrans进程0。安装器仅通过真实提取预检（约定退出7、未登记）及哈希复核；当前用户完整安装、变更资产升级和卸载失败行为均未实测，没有发布。证据与限制见 [隔离实施记录](2026-11-06-isolation.md)，不能把源码或预检通过当作安装包全流程通过。

B1最新源码构建161/161步骤通过，封存产物15项命令验证全部通过，含8组持久作业与无Shell自主推进、12组隔离负例及真实Shell／NanoUI集成。最终包哈希前后相同、测试进程0；没有安装或发布。[B1实施记录](2026-11-07-architecture-plan.md)单列源内故障注入、实际DLL／Host证据与未覆盖的崩溃窗口。

B2最终构建163/163步骤通过，封存17项产物验证命令全通过：含9组异步作业（0不确定）、8组真实管道负例、B1／A2／隔离及GUI集成回归。4K作业运行时编辑／快照／帧泵／取消均返回；取消保护旧输出，重试去重、外部授权复用拒绝与owned Source验证通过。新帧服务永不抢导出，Host与direct Shell均显式启用driver。编码器单次调用不可强行抢占，Source捕获／持久化IO仍在owner临界区；不代称完整交互／视觉／IME验收。最终包哈希未变、测试进程0，无安装发布，详见[B2实施记录](2026-11-07-architecture-plan.md)。

C1最终构建165/165步骤通过，真实DLL／Host的版本留存11组与同一产物14项headless回归全通过；包含原文件变／删、双版本Job／undo／重启重试、坏版本与NTFS junction拒绝、RPC丢回复后Station不变。GUI Source改为本地owned字节／帧，fake API验证版本与面板租约边界，未打开真实GUI。最终各Pack哈希前后相同，测试进程0，没有安装或发布。首轮stdlib文件读取Unexpected同代码复验通过但根因未确定，详情见[C1实施记录](2026-11-07-architecture-plan.md)。

C2a修正真实文件身份与旧授权确认，最终165/165步骤、真实DLL／Host8组及同一产物15项headless回归全部通过；各Pack哈希前后相同、测试进程0，现有安装与真实授权数据未改。旧v1不自动改绑，已留存作品仍可读，完整重新定位／采用和资源CAS后续实现。Zig间歇loader异常的只读审计未定位根因，不作环境归因，详见[C2a实施记录](2026-11-07-architecture-plan.md)。

C2b核心已完成ABI9、资源独立CAS／proof／回执、重新定位与采用、不可变owned存储及共享Shell客户端。最终171/171构建步骤、实际DLL／Host13组和同一产物16项headless命令通过；Pack哈希未变、测试进程0。真实GUI按钮／目录整体迁移、安装升级卸载和发布未验收；旧loader间歇异常仍未定位，测试夹具失败与产品结果分别记录。详见[C2b实施记录](2026-11-07-architecture-plan.md)。

用户随后明确文件资源管理器应偏向FileHub式通用资源空间，下载器等为专门应用。现评估将来源绑定／RAM驻留与作品固定版本进一步分层，并建议在新增UI前先验证缓存优先、限定刷新和完整内存独立保存闭环；这些是后续设计建议，当前C2b代码和验收范围未改变，具体见同一实施记录末尾的方向补充。

用户又明确独立App粒度及来源分区：本地外部浏览、VM资源管理、桌面、CLI、类PS均为App，云来源也可独立App；消费应用统一使用已登记VM资源，本地／云拖入默认只读引用，显式独立化保留显示名，外部直接拖入消费App走相同登记再交付。直接内容编辑仅限VM专属区，外部出境为显式复制；通用外部删除／移动不属目标能力。此为目标设计，尚未改造当前mount授权、旧外部URI或实现强制沙箱，命名建议与解释见实施记录末尾。

C2c1最终175/175构建步骤通过，真实DLL／Host的驻留闭环8组及最终同产物17项headless命令通过；Pack哈希未变。源码UI模型验证不替代真实GUI／IME，未安装或发布；Zig间歇loader／导入库Unexpected仍未定位，所有失败及同源码复验保留在本片证据中，详见实施记录。

C2c2最终179/179构建步骤、新实际DLL／Host14组及同产物18项headless命令全通过，Pack哈希不变、结束进程0。junction／hardlink真实验证；symlink因Win32 1314未覆盖，没有改权限。NanoUI官方与fork有新提交但仍报0.12.0，本地6依赖未漂移、未升级；编译器loader间歇异常仍未定位。完整GUI、安装与发布未验收，详见[C2c2独立记录](2026-11-07-resource-registration.md)。

仓库整理最终184/184步骤、10项仓库负例与6项隐藏进程检查通过，同产物4项Runtime／Host／隔离／资源回归hash不变。实际源码快照暴露的两项空目录声明已移除，解包与核心构建另记最终报告。该次整理当时未改写历史，后续另获用户明确授权；安装器完整验收仍未完成。

其后按用户明确授权，原验收树以无parent新根推送master，原v0.1.0标签及Release先备份后删除；后续提交只收尾文档及记忆。不是重新发布应用，也未更新既有安装；独立网络克隆与源码核对的实际结果见本片证据，fork按用户要求不处理。

随后按用户清理指令，仅删除已定位的`.zig-cache/o/`与一处异常递归临时副本，共67.327GiB；目录复测由75.339降至8.013GiB。五组当前产物、验收源码ZIP和私有历史bundle哈希不变，旧数据与全部验证证据保留；没有重建、安装或发布。自动缓存预算／证据保留策略尚未实现，递归副本起因未定位，见[清理记录](2026-11-07-cache-cleanup.md)。

2026-11-08统一 NanoUI 前端完成：主桌面包含首页、编辑器、资源库、CLI与任务视图，旧zgui/zglfw/wgpu与CUI已移除。最终完整构建166/166步骤、`test-nanoui-desktop` 6/6、Shell 31/31、独立库53/53、附着31/31、便携31/31、Runtime与隔离61/61、作业与通用资源32/32步骤通过，仓库审计selected=1050/required=1054通过。没有真实GUI／IME、完整安装升级卸载或发布验收，详见[统一 NanoUI 实施记录](2026-11-08-nanoui-unification.md)。

随后完成工作正文切片：Resource API v3、Catalog v3、草稿与工作revision、成功回执跨恢复及NanoUI正文编辑已落地。`test-core test install portable`、桌面测试、正文DLL／Host、通用登记、Shell、独立资源库、附着、便携、Runtime／隔离、异步作业和仓库审计均退出0；正文专项证明旧导出固定输入、丢回复及重启不重复提交，原生无头场景覆盖多行输入、草稿、提交和关闭保护。真实GUI／IME、完整安装升级卸载与发布仍未验收，详见[工作正文实施记录](2026-11-08-work-documents.md)。

本机文件切片随后完成：Resource API v4、RPC31／32、一层只读浏览、临时文本／PNG预览、显式登记与插入文档已落地。真实DLL／Host／NanoUI验证通过，浏览不隐式创建资源、授权、留存或Station；完整目录收纳、工程目录独立化和流式超大目录未完成。详见[本机文件实施记录](2026-11-08-local-file-sources.md)。

2026-11-09新增 `EnvironmentSession` 启动屏障：桌面、资源库和本机文件以既有 Host 附着、Shell 校验和 Runtime epoch 建立无物理路径的环境身份。完整构建、桌面、正文、登记、主 Shell、资源库、本机文件、附着、便携、Runtime／隔离和异步作业回归均退出0；单 EXE 多角色、静态 Runtime、内嵌载荷和完整安全退出仍未实现。详见[环境先验实施记录](2026-11-09-environment-session.md)。

随后 `cutrans.exe` 同 EXE 多角色已落地：控制器、Host、桌面和资源库共享同一可执行文件，进程边界、Pack 校验与 Shell 提交不变。全隐藏专项真实进程与生命周期验证通过，最终完整构建及 Host、桌面模型、正文、登记、本机文件、资源库、便携、Runtime／隔离和异步作业回归退出0；旧 EXE 与 Pack 仍为回退。未切换安装器入口，未完成静态 Runtime、内嵌载荷、最终单文件发行或完整安全退出；可见播放、真实视觉／IME 和安装验收不在本轮通过范围。详见[同 EXE 角色实施记录](2026-11-09-same-exe-roles.md)。

其后统一 Host 默认静态 Runtime 已完成：无 Runtime 目录的真实 Host／NanoUI／保存恢复通过，显式动态 Pack 与锁迁移也通过；完整构建、同 EXE 与旧动态 Host、资源、正文、本机文件、资源库、便携、Runtime 隔离和异步作业回归退出0。当前仍需 Shell 资源 Pack，最终载荷收口、安装器切换与完整安全退出未完成。详见[静态 Runtime 实施记录](2026-11-09-static-runtime.md)。

随后 PayloadSource 已建立：桌面与资源库使用 `payload/` 中的 `cutrans-payload/1` 清单和只读资源，`entry=builtin` 不再要求旧 Shell EXE。无旧 EXE／Runtime／旧 Pack 的真实场景通过；显式旧 Pack 回退成功，缺失或损坏 Payload 当时拒绝且没有隐式回退。2026-11-10 已增加 exe 内嵌 payload 回退（见[内嵌 payload](2026-11-10-embedded-payload.md)）；受管发布、安装器切换与完整单文件发行仍未完成。详见[PayloadSource 实施记录](2026-11-09-payload-source.md)。

环境内安全退出已接通：Host 停止新业务、等待／协作取消、撤销退出、保存并正常停止，NanoUI 在成功前不关闭并支持失败重试。实际任务、草稿保护、Shell 身份提交、冷恢复和重启均通过；没有自动提交工作 revision。协作取消不是强制抢占，真实 GUI／IME 与安装验收未覆盖；完整单文件发行（外部 context/安装器）仍未完成，payload 内嵌已原型。详见[安全退出实施记录](2026-11-09-safe-exit.md)。

2026-11-09 工作回执与恢复修复：自动保存改为空闲防抖，Catalog v4 以环形64条回执＋128个持久客户端高水位取代终身64次上限；Host 的 stopping／degraded 可由普通启动收尾并重启，控制转换失败不再终止 Host，退出进行中拒绝关窗。默认桌面不再以默认载荷路径伪装显式选择，同 id 哈希变化拒绝，内置桌面／资源库兄弟切换保留。`build test`、工作正文专项（70次连续草稿＋旧序号拒绝）、安全退出专项（stranded／control）与 Payload 专项均退出0；未做真实 GUI／IME、安装升级卸载与强制抢占验收，回执表满后的极端伪造边界仍按记录保留。详见[本轮修复记录](2026-11-09-work-recovery.md)。

2026-11-10 宿主边界切片：桌面默认原生边框最大化、F11 最大化/还原；外部文件统一经 Resource API `register_file` 登记，支持 OS 拖入和系统文件对话框，资源库保留引用/拥有与来源状态，VM 私有目录拒绝。本机文件页测试覆盖显式登记、拖入登记和 managed 目录拒绝；Payload 与安全退出回归通过。真实 Explorer 拖放、系统文件对话框、无边框全屏、真实 F11/最小化手感与安装仍未验收。详见[宿主边界记录](2026-11-10-host-boundary.md)。

2026-11-10 NanoUI 同步：vendor 从 fork 0.12 切到官方 v0.14.0（`7b32272`），采用官方 `chrome.zig` 的原生 frame + 自绘标题栏，退休 borderless、D3D11 纹理、CPU stride 等已上游补丁；保留 `ui.d3d11`、`window_maximize`、`on_present`、`kv` 六文件本地补丁。`build test`、payload、local-sources、safe-exit、test-nanoui-library 通过；`test-nanoui` 连续四次 585 pass / 21 skip / 0 fail（此前一次 `WS_EX_TOPMOST` 失败未复现），新增 `verify-nanoui-chrome` 跑隐藏窗口的顶边/hit-test/caption/maximize 回归。真实拖拽/缩放、Snap、视觉与安装未验收。详见 [NanoUI v0.14 同步记录](2026-11-10-nanoui-v014-sync.md)。

2026-11-10 内嵌 payload/context：portable `payload/` 与 `cutrans-context.json` 已编入 `cutrans.exe`；缓存逐文件校验、损坏重建，并用 staging+rename 让并发启动只产生一个完整缓存，旧于30天的目录尽力清理。外部缺失时内嵌副本物化到 `%TEMP%` 并重新校验，只有 exe 的 portable headless 场景通过。ABI 11 后 `zig-out/single/cutrans.exe` 为 12,708,352 字节（目录内仅此文件），`verify-single-exe` 通过 start/shell/stop 且不生成外部 payload/context。安装器入口已改指统一 `cutrans.exe` 并瘦身到 exe/licenses/README（4,840,425 字节），不再复制 context 或 vm-pack；旧多目录布局明确拒绝自动升级；ABI 11 后 `build installer` 与 preflight-only `verify-installer-artifact` 通过（未写系统登记）；真实安装/更新/卸载/发布未做。详见[内嵌 payload](2026-11-10-embedded-payload.md)和[安装器入口与瘦身](2026-11-10-installer-entry.md)。

2026-11-10 Shell 命令边界：命令队列从 Runtime 私有模块提升为 `vne.command`，Runtime 与 Shell 共用；desktop view 不再直接导入 runtime，PNG 尺寸检查经 `vm_client`。命令语义、ABI 和协议字节未变；Shell 仍持有 `RuntimeContext` 与 runtime documents/render/image，后续继续拆投影边界。详见 [Shell 命令边界](2026-11-10-shell-command-boundary.md)。

2026-11-10 Shell 投影边界：`apps/desktop` 与 `apps/editor` 不再直接导入 `runtime`，改用 `vm_client` 暴露的 Context/Preview/Frame/Paths；build 依赖同步移除。`runtime/status.zig` 移到 `vne.status`，路径边界移到 `vne.paths`，文档模型移到 `vne.documents`，Runtime 继续 re-export。Shell 直接依赖 Runtime 的位置收口到 `vm_client` 一个适配层；本地预览求值已改走 VM preview ABI，但 RuntimeContext、image 解码仍未拆除。详见 [Shell 投影边界](2026-11-10-shell-projection-boundary.md)。

2026-11-10 架构边界守卫：新增 `tools/verify_architecture.py` 和 `build verify-architecture`，拒绝 `apps`/`shell` 直接导入 runtime，以及各层跨层 UI/host 导入。当前六层通过；这是直接 `@import` 扫描，不是完整模块图证明。详见 [架构边界守卫](2026-11-10-architecture-guard.md)。

2026-11-10 Preview ABI：ShellApi 升到 11，新增 preview info/read；Runtime 按 fingerprint 缓存并返回 BGRA8 帧，Host RPC 与 Shell client 接通，编辑器改用 `vm_client.previewFrame`，不再本地跑文档预览 DAG。源内负例、Host mock、payload/single-exe 通过；没有专门真窗口视觉验收。详见 [Preview ABI](2026-11-10-preview-abi-contract.md)。

2026-11-10 Shell 自有投影上下文：桌面/编辑器/控制台改用 `vm_client.Context`，不再实例化 `RuntimeContext`；Shell 只持有命令、文档镜像、资源/库/播放/设备视图与路径。`build test`、payload 通过。详见 [Shell 自有投影上下文](2026-11-10-shell-owned-context.md)。

2026-11-10 Shell 与 imaging 解耦：PNG 编解码移到共享 `imaging` 模块，`vm_client` 不再导入 runtime；sourceProvider 改为 Shell 本地类型，架构守卫增加 `vm_client` 文件级 runtime 禁入。详见 [Shell 与 imaging 解耦](2026-11-10-shell-imaging-decoupling.md)。

2026-11-11 Preview 验证与 RuntimeContext 修剪：真实 Host + 隐藏 Shell 的 desktop verify 请求两帧、校验 generation/像素、短 buffer 和 stale fingerprint；PreviewInfo 携带 Runtime epoch/revision，新 Runtime 实例 epoch 必变；新增独立 `verify-preview`；Shell client 携带已知 epoch，Host 重启后旧 epoch 请求被拒绝并重试。RuntimeContext 移除仅 Shell 使用的 asset_view/library_view/playback_view。status/devices 仍有真实 Runtime 消费者，保留。详见 [Preview 验证与 RuntimeContext 修剪](2026-11-11-preview-verification-context-trim.md)。

2026-11-11 受管理 doc.save：`doc.save` 纳入 `vne.workspace.manages`，复用 client identity/sequence/expected 与 receipt；丢回复重试同一请求可回放，不重复保存。没有新增 ABI/协议；receipt 仍只在单 Runtime 生命周期内有效。详见 [受管理 doc.save](2026-11-11-managed-save.md)。

2026-11-11 Host 重连 v1：Shell 增加 `reconnect()`，镜像读取失败后重新 verify Host 并重试一次；成功清空 preview epoch/identity/stamp，pending 请求保留不自动重放。普通命令仍不自动重试；`verify-reconnect` 已通过真实 Host 停止/重启 + 隐藏 Shell 自动检测、重连；pump 失败触发连接重建并有冷却窗口。详见 [Host 重连 v1](2026-11-11-host-reconnect-v1.md)。

2026-11-11 事故恢复与快照：本机清理事件永久删除了 DSH 会话 `Cutrans-zig0.1` 的 75 轮正文（仓库源文件未受损）；核对发现 2026-11-09～11-11 的全部切片都还在工作区、未提交。修复 `tools/verify_reconnect.py` 的语法错误和停机窗口竞态，补齐重连 v2 的 `pump`/冷却/未受管命令语义，并把 uv CPython 3.12 加入用户 PATH 以恢复隐藏入口。`build test`、`verify-payload`、`verify-reconnect`（auto_detect=1）与 `verify-repository` 通过；工作区已作为 master 快照提交并推送 `origin/master`。未做真实 GUI/IME、安装更新或强制抢占验收；事故根因未查明，桌面索引备份与验证证据不得清理。详见 [事故恢复与快照](2026-11-11-incident-recovery.md)。

2026-11-12 命令清单单一真源：新增 `vne/commands.zig`，把 Shell 转发、Runtime 内部、workspace managed、过期白名单和建节点命令集中到一处；`workspace.manages`/`createsNode`、`vm_client.register`/`allowedWhileStale` 改为读取该清单，Runtime 注册表测试断言与清单完全一致。`build test`、`verify-architecture`、`verify-repository` 通过；命令参数仍是字符串，schema/检查器和文档自动生成未做。详见 [命令清单单一真源](2026-11-12-command-manifest.md)。

2026-11-12 ABI 接线审计与构建残留清理：ShellApi 表字段和 Host RPC `Kind` 分支已由编译期强制，新增字段仍需人工补 Kind/客户端映射；删除 `zig-out/portable` 下 9 个 2026-11-07 的旧 UI 残留（顶层/shell 的 wgpu、旧 desktop DLL 与六份旧许可证，约 19.8 MB），重建 portable 后未再生，`verify-payload` 通过。安装器与单文件发行不受影响；自动纯净化未实现。详见 [ABI 与残留审计](2026-11-12-abi-and-staging-audit.md)。

2026-11-12 目录成员显式收纳：本机文件页新增“收录到同名文件夹”，以当前目录名在资源库根下创建/复用逻辑文件夹，登记单个成员后用既有 `library.move` 建立 `parent_id` 关系；资源身份、内容哈希和来源授权不变，没有新增 ABI、命令或 Catalog 格式。`verify-local-sources` 的隐藏 GUI 场景断言文件夹与成员关系（`CUTRANS_LOCAL_FOLDER_OK`），DLL/Host/UI 回归通过。文件夹按标签复用，不记录源目录绝对路径，也不是目录整体收纳；真实 GUI/IME 与安装仍未验收。详见 [目录成员收纳](2026-11-12-directory-member-collection.md)。

2026-11-12 未决请求停止等待（Host/Shell 两段闭环）：`vm_client` 新增 `hasPending`/`abandonPending`，编辑器在结果未确认时显示警告和“停止等待未确认修改”。停止等待只结束客户端等待，不重放也不回滚；刷新后的文档镜像显示 VM 真实状态，后续编辑用刷新后的 expected stamp 防止旧请求晚到造成静默覆盖。`data/shell/pending-unknown.txt` 在 Shell 重启后继续提示“可能已执行”，确认后清除且标记不携带可重放请求。新增 `verify-unknown-result`：真实 Host 提交后丢回复、Shell 保留 pending、重启后 `wrong_epoch` 清空且不重复提交、新 identity 显式编辑成功；并验证 pending 时 Shell 退出后下一个 Shell 打印 `CUTRANS_UNKNOWN_HISTORICAL` 并完成普通桌面场景。单元测试、`test-nanoui-desktop` 与 `verify-payload` 通过；按钮点击、取消/回滚协议、真实 GUI/IME 与安装验收仍未覆盖。详见 [停止等待入口](2026-11-12-pending-wait-stop.md)。

2026-11-12 保存原子性与 v3 显式输出：`.cut` 落盘改用 `vne/atomic_write.zig` 的临时文件＋flush＋原子替换（此前是全仓唯一一处截断式持久写，同文件已存在正确原语）；History journal 记录并还原 `dirty`/`legacy`，恢复不再无条件声称已保存；`doc.save` 改为写前日志(pending)→原子目标→确认标记，确认失败只降级状态栏。canonical v3 要求显式 `output=`，行对齐截断不再被接受（v1/v2 隐式输出迁移不变）。新增 `verify-write-order`（4 项真机断言）与 `vne/documents.zig` 测试根。同片暴露三项未修复问题：vne 模块根测试从未执行、两个既有锁测试因 `SHARING_VIOLATION` panic 稳定失败、panic 型失败不改变 `build test` 退出码。（**锁测试归因已被下一条更正**：两个锁测试本身通过，失败只出现在构建运行器路径，运行器型失败不改变退出码；见[评审交接](2026-11-12-review-handoff.md)。）`build test`、`verify-write-order`、`verify-architecture`、`verify-repository` 退出 0；真实 GUI/IME、安装与掉电注入未验收。详见 [保存原子性](2026-11-12-atomic-save-and-v3-output.md)。

2026-11-12 工作正文发布顺序与草稿基线：`library/work|drafts/<id>/` 的正文改名为「revision/token + 内容哈希」，旧 `<revision>.bin` 只读兼容；Catalog 提交失败留下的未引用正文不再与同一 revision 的重试冲突。`save_draft` 的 `base_revision` 必须等于当前工作头，落后客户端的草稿保存直接返回过期版本，不再写入一份提交时必然被拒的草稿。`verify-work-documents`（`CUTRANS_WORK_DOCUMENTS_VERIFY_OK`）、`verify-architecture`、`verify-repository` 退出 0；`resource_library` 测试二进制单独运行 143/143 通过。同片修正上一片对两个锁测试的错误归因：测试本身通过，失败只在构建运行器路径（HEAD 同样复现）。GUI 客户端缺少"落后后重读快照"的重同步，真实操作中会停在拒绝状态。详见 [发布顺序](2026-11-12-work-publication-order.md)。

## 2026-11-12 进度快照

- ~~**进行中（未编译、未验证、未提交）**：接续顺序第 1 步“容量与回收（窄版）”的代码已写入工作区……在其“验证”一节补齐前，不得把 `library.remove`、授权释放或容量错误当作现役能力。~~（被下一条取代）
- **容量与回收（窄版）已在本机验证（2026-11-12）**：代码一次编译通过、零修改。`build test` 第三次运行退出 0，前两次因 Zig loader 间歇异常失败；三个被标失败的测试二进制单独运行分别为 112/112、178/178、114/114，四个新测试逐条 OK。`verify-assets` 新增了真实 DLL 上的 `library.remove` 拒绝、空文件夹删除、ID 不复用和重启持久化断言并通过；`verify-architecture`、`verify-work-documents`、`verify-local-sources`、`verify-repository` 也都退出 0。`library.remove` 只验证了 DLL 命令入口和单元测试，Host RPC、Shell、CLI 端到端以及 GUI 删除按钮未覆盖。详见[容量与回收（窄版）](2026-11-12-capacity-reclaim.md)“验证”一节。
- **验证中新发现的两个既有问题（均不是本片引入）**：
  - `verify-resource-registration` 在 HEAD `22cc8907` 上就失败：`native_boundaries` 的四个受管路径中至少一个 `register_file` 探针返回成功而不是 `DENIED`（`tools/verify_resource_registration.py:335`）。已通过 stash 本片后重跑确认与本片无关。该验证上一次运行是 2026-11-08；具体是哪个路径被接受、边界何时改变都没有定位，未修。这意味着“受管根拒绝登记”这一已记录的边界当前**不能视为成立**，需要排期。
  - `verify-assets` 自 2026-11-07 起从未运行，它的 catalog 格式断言（`/2`）对 Catalog v4 早已失效，本片已修正。说明多个 `verify_*` 脚本可能长期没跑；“曾经通过”不代表当前通过。
- Git（2026-11-12 评审交接后复核）：`master` 与 `origin/master` 同为 `22cc8907`，审计检查点记为未推送的 4 个提交已推送；评审交接页及本次记忆刷新随后单独提交。
- 当前 `master` 已包含本会话三个片：`0bc7ba51`（保存原子性与 v3 显式输出）、`fb124808`（其后的记忆更新）、`714ebafd`（工作正文发布顺序与草稿基线）；其后为记忆检查点提交，工作区干净。审计结论与接续顺序见[审计结论与进度检查点](2026-11-12-audit-checkpoint.md)。
- 本日连续完成：
  - `51efd2af` 命令清单单一真源；
  - `a8769edb` ABI 接线审计与 portable 残留清理；
  - `560868f9` 未决请求停止等待；
  - `ad8af954` 真实 Host 丢回复 + 重启闭环；
  - `1e82ecc1` 跨 Shell 未确认标记；
  - `64f601ea` 闭环记忆；
  - `56388fd3` 目录成员显式收纳；
  - `fdbe3ab6` README／文档导航刷新，并确立“用户可见能力变化时同片更新 README”的长期规则；
  - `0bc7ba51` 保存原子性与 v3 显式输出；
  - `714ebafd` 工作正文发布顺序与草稿基线。
- 最近一次验证：本片 `verify-work-documents` `developer-55b6032eaaef/`（`CUTRANS_WORK_DOCUMENTS_VERIFY_OK`）、`resource_library` 测试二进制单独运行 143/143、`build test` `developer-6230dc80ded0/`、`verify-architecture` 退出 0、`verify-repository` 退出 0；此前 `verify-write-order` `developer-5b8e33bdb0d2/`（`CUTRANS_WRITE_ORDER_OK checks=4`）、`test-nanoui-desktop` `developer-ae8b73268866/`、`verify-local-sources` `developer-593019ce8e31/`（证据 `local-sources-f511496e014d/`）、`verify-unknown-result` `developer-deaa34671ca8/`（证据 `unknown-result-acbfc979349f/`）。
- 当前边界：未决结果的 Host/Shell 两段已闭环；目录收纳只按标签复用逻辑文件夹，不记录源目录绝对路径，不是目录整体收纳；`.cut` 保存与工作正文/草稿的发布顺序已修；库条目和空文件夹已可经 `library.remove` 删除（无活引用才允许），最后一个引用删除时释放持久授权，容量满时显式返回 `queue_full`。但非持久授权（`doc.open`、`asset_open_external`、导出快照）在会话内仍不释放，孤儿字节没有物理回收，`asset.export` 目标边界仍未修；真实 GUI/IME、安装升级卸载和真实媒体仍未验收。
- 下一步顺序（2026-11-12 用户确认，取代审计检查点与本段旧版“下一步建议”；只保留这一份，理由见[评审交接](2026-11-12-review-handoff.md)第四节）：
  1. ~~**容量与回收（窄版）**~~（2026-11-12 已验证，见上）：容量错误显式化 + “无引用才可删除”，覆盖库资源／文件夹 `[32]`、外部来源 `[8]`、授权槽 `[8]`；删除前检查 History before／after 文档、排队／归档 Job 固定的 hash、`library/versions/` 留存及共用授权槽的 `doc.open`／`asset_open_external`／导出快照。
  2. **vne 测试根**：`vne/root.zig` 没有 `test` 块，`vne/*.zig` 的测试不被发现；启用后预期会暴露从未运行过的失败，并须确认发现的测试数上升。
  3. **v4 格式 ADR（无代码）**：作用域化 comp ID、多输出、时间维度、不整份复制文档的快照模型、v1–v3 迁移规则。
  4. **D 声明注册表**，建立在 v4 上。
  5. **两项小修**（可插到更早位置）：`allow_migration` 从 RPC `id` 移入 payload（客户端与 Host 两侧）；`.command_result` 依 `vne/commands.zig` 拒绝 managed／runtime_only。其它小修候选：`asset.export` 目标白名单、`work_model` 收到 `stale_version` 后重读快照。
  - `build test` 构建运行器失败仍需单独排期；“退出 0”不能单独作为全绿证据。
  - 新增待排期：`verify-resource-registration` 的受管根边界回归（见上）；Zig 标准库 loader 间歇异常本日连续出现（本会话 12 次构建中 4 次触发，每次文件不同，HEAD 上同样出现），已明显影响验证效率。
