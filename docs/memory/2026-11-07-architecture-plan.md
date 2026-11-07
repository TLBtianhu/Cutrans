# 连续创作会话的架构优化计划（2026-11-07）

用户已授权“将优化计划记忆，然后推进”。本条将上一轮架构评估确认为后续施工计划；以下未完成内容是计划，不能视为现役能力。实施按完整场景逐步交付，不要求一次完成所有阶段。

## 目标与边界

“游刃有余”的工程含义：可读声明、可回到真源的检查器、修改后按依赖失效并刷新投影、可组合扩展的器具与模板；工作台同时呈现多任务信息，保持空间稳定与会话连续。文档、资源、作业和视图各有所有权，不能新造一棵包揽全部状态的万能树。

GUI、CLI、Agent 共享业务语义入口。Shell 持有投影与本地交互，Host 持有权威会话并自主推进作业；关闭 Shell 默认不终止工作。视图本地搜索、选择、滚动、焦点和纹理不强塞回 VM。虚拟桌面与 Surface 保留，按实际创作场景发展。

## 推进顺序

1. **A 身份与提交一致性。** 结构化操作经校验形成候选变更，明确执行／持久化／投影更新的结果；文档、History和dirty不可在失败时留下半提交。持久节点ID有作用域且高水位不随撤销回退。后续逐步补文档revision、请求身份、创建对象ID、重试与前置版本约束。命令成功与镜像刷新失败分账，不诱导客户端重复执行。
2. **B Host 自主作业与恢复。** 作业声明保存操作、文档／资源版本、输出意图及重试规则；执行尝试持有worker、租约、进度和临时文件。Host自主推进有界队列，支持多作业、取消、终态归档及可解释恢复；输出有提交边界。先做简单可用机制，不先造分布式调度器。
3. **C 资源版本与求值服务。** 保留稳定库ID、引用／拥有状态、内存Station和缓存分层。补重新定位、明确采用新版、固定版本／独立化及保留政策；哈希不能代替旧字节。工程Source逐步收敛为稳定库引用＋内容版本，旧external／Session Source经兼容和迁移边界退出主通路。预览／播放／导出共用装配求值语义，FrameLease绑定文档版本、输出、时间和制式，迟到结果不可覆盖新版本。
4. **D 声明注册与检查器。** 现有六个内置效果先经静态声明注册，持有名称／版本、参数schema、输入输出与依赖；通用文档编辑和History不再随每个效果新增专用分支。命令描述供GUI／CLI／Agent共享。缺效果时保留声明并原地标记，不抹除作品。动态加载与不可信沙箱另行演进。
5. **E 完整场景迁移 NanoUI并清退旧栈。** 先迁“打开工程→资源选择→编辑→预览→导出→关闭Shell任务继续→重连恢复”，经过真实场景和IME验收再删对应旧视图、桥接和依赖。共享palette与产品语言保留。

贯穿阶段：拆权威VmContext、Host设施与Shell本地投影，避免GUI再构造完整业务Context；读取绑定稳定快照／revision，按页与有限变化集刷新。永久目录容量、活跃作业、终态档案、在途消息、可重建缓存分别采用增长／预算／分页／归档／背压政策。协议记录与批次可定长，总业务量不等于数组长度。

容量改造须与快照所有权一起推进：当前History和Export Job依赖Document值拷贝，不能直接替换成共享可变动态数组。声明变更的派生刷新不等于插件代码可以任意热换；外部自动同步仍只归可选插件，核心不加入监听或后台覆盖。

## 删除与保留纪律

- 可独立清理便携根重复wgpu及core VM Pack的强制依赖：仅desktop Shell需要它，仍须保留该Shell闭包DLL、许可证及哈希；同步改清单和验证后再删除，不全仓删库。
- 正式Outcome与命令描述接入后，删除手抄命令名单、根据名称猜created id、执行成功与镜像失败混报的通路。
- 版本化快照与分页接入后，删除逐字段轮询和固定总容量语义；不能用无界内存队列替代背压。
- 场景迁移通过后删除对应旧UI；旧格式与Source先移入兼容／迁移边界，保留真实作品读取能力。
- 保留资源库／Station／缓存分层、单写者、窄OS Port、显式授权、内容／ABI校验和已经验收的环境隔离。不得以减行数为理由删除这些边界。
- 所有安装／发布仍遵守独立OS验收与同一产物哈希纪律，不覆盖现有体验安装、不改真实数据。

## 验收场景

导入素材、调整参数并撤销；提交绑定不同文档版本的两个导出；继续编辑并关闭Shell；Host继续工作；重新打开恢复现场；外部素材变化时能解释旧／新版本并提供重新定位或显式采用新版。每个阶段实现其中有明确证据的部分，不能把整条场景提前报为完成。

## 本轮开工范围 A1

先实现撤销／分支后节点ID不复用、文档编辑与History持久化失败的一致回退，以及命令结果和镜像刷新失败分账。维持现有命令协议，完整revision／request去重／通用ChangeSet、Host自主作业和其它阶段仍待后续。施工、验证及剩余边界在收尾追加。

## A1 实际实施与验收（2026-11-07）

计划已先独立提交为 `81bc32d5`，随后实施本切片。

- `runtime/edit_transaction.zig` 提供未发布的文档候选、单个Edit或undo／redo游标变化。`history_journal.View/saveView` 借用有效History前缀与一个候选条目；原子持久化成功后才发布文档、History单槽与游标。每次调参不复制整份约1.1MiB的History。所有文档编辑、打开／替换、图片／Asset插入、undo／redo均接入；HistoryFull或IO失败保留旧文档、高水位、dirty、游标和redo尾。
- Document新增持久节点发号高水位，撤销、新分支、图片替换和History恢复不回退；图片替换创建新节点身份。内容指纹不包含行政高水位。仅在高水位超过当前可见最大节点ID时，v3文本附加版本化保留注释 `// cutrans.node-id-high-water-v1=N`；旧日志恢复可从全部历史和redo条目推导高水位。非法、重复、未知版本或低于现有节点的保留注释拒绝。常规规范文本仍保持原形，NaN／Inf等非法参数在发布前拒绝。
- 同内容指纹不等于同一发号状态：当前只支持默认基线的输入录制／回放加高水位检查，避免晚发现ID分配漂移；未实现任意会话基线。
- Shell保留已收到的权威命令status和task_id，投影读取失败另记document/playback/library/assets的stale状态，后续泵重试读取而不重放命令。文档镜像校验完成才发布；stale时普通业务修改拒绝，取消／释放／停止仍可用。外部资源已成功接受时保留句柄，UI不再把随后投影失败说成加载失败。
- GUI缓存预览和真实帧提交受镜像新鲜度门禁约束；语义输入保留观测记录，通过 `editing_unavailable` 上下文显式抑制编辑动作，避免陈旧视图触发当前文档的快捷键操作。没有注入真实键鼠输入。
- `doc.save`先校验目标并持久化内部History，再写目的地，防止History故障时先覆盖外部目标；此顺序不构成跨文件事务。诊断器与素材验收移除“图片节点总是c0”的假设，读取真实output身份。

实际DLL负例发现并定位：固定Zig 0.17的Windows atomic rename未映射SHARING_VIOLATION，进入 `windows.unexpectedStatus` 的Debug堆栈追踪，在ctypes小栈调用中溢出。没有改测试宿主栈或工具链，也没有删除独占锁负例。显式command(_result)现沿用创建入口的VM自有4MiB同步调用栈，保留NTSTATUS诊断和真实失败码；out_task_id进入时清零。修复后同一独占锁、解除后重试均通过。这是命令ABI栈边界，尚非Host自主执行器；后续B应复用常驻执行所有者，消除每命令建线程的临时成本。

验证证据：

- `test-core test install portable library-probe` 构建155/155步骤通过，执行1225/1225测试通过；最后命令栈修复后的 `test-core test install portable` 为152/152步骤、93/93执行测试通过，其余复用缓存。数字为构建器执行统计，含模块间重复，不作独立产品场景总数。
- 新增显式vm_client测试模块，5个mock ShellApi场景验证权威ok／accepted／task_id保留、拒绝结果、镜像候选失败不发布、恢复不重放和资源句柄保留。源内负例覆盖所有文档编辑、真实IO阻断、HistoryFull、redo尾、目标哨兵与修复重试。
- `verify-edit-commit` 的真实分发DLL有4组通过：独占锁下编辑／undo／redo不变且可重试；非有限参数拒绝；undo→Runtime销毁恢复→新分支不复用ID；满History拒绝后仍可撤销并创建新分支。每次同步／失败命令不残留旧task_id。报告：`scratch/verification/edit-commit-f3952b270f83/report.json`。
- `verify-isolation` 12组全部通过，原件及74个portable文件哈希不变，无staging data。报告：`scratch/verification/isolation-6381f9c4c6fb/report.json`。
- 实际Runtime、input、playback、replay、assets、Host、真实Shell、四次attach以及NanoUI development／portable均通过；development／portable诊断通过。GUI使用真实提交与隔离cwd日志，不截图、不自动输入，不冒充视觉／IME验收。
- 完成后没有Cutrans Host活动进程；只操作新认领验证案例，不改真实安装、注册项或用户数据。没有构建／验收／发布本轮安装器，上一隔离切片的安装器哈希和预检证据不能替代本轮新代码验收。

### A1 仍保留的边界

- 完整请求身份／幂等去重、文档epoch／revision前置条件、正式created_id及一致快照仍是A2；跨文档延迟命令与远端执行后回包丢失的未知Outcome尚未解决。
- 多次镜像RPC不绑定同一revision；本轮支持单项镜像读取故障重试，完整Host断线时语义输入通道仍可能使Shell退出，不能宣称窗口自动重连。
- 旧客户端会忽略高水位注释，重新保存可能丢失该元数据。历史文件继续可读，未承诺旧客户端重存后的身份保证。
- 文件保存与内部History仍非跨文件事务；外部目的地的原子保存不是本轮新增保证。资源库／作业的事务、长期容量政策和自主任务推进尚未实现。
- VM自有栈仅覆盖创建和显式命令入口；pump、输入录制执行等其它ABI未统一收口，不能宣称所有异常IO路径都已与调用方栈完全解耦。
- 无持久化IO的源内Context只提供内存提交；持久化成功的承诺适用于有数据根与IO的正常Runtime。单写者边界仍须遵守，候选对象不是跨线程锁。

下一切片先推进A2的版本／结果／一致快照契约，再接B的持久作业声明和Host自主推进。其它计划保持待办，不提前迁移或删除旧UI、旧数据格式及资源表达。

## A2 契约定案（2026-11-07，用户再次指令“推进”）

以下取代A1相应待办的施工边界；实际验证另记，未通过前不作为验收结论。

- 显式升到ABI8，不以旧ABI7的struct_size兼容读取新增函数。ShellApi尾部提供独立版本v1的workspace getter；Runtime、Host管道和desktop使用同一文档契约。Python Pack生成和验收从`vne/abi.zig`读取ABI声明，不再手写多个7／8；构建图声明该文件依赖。
- 文档发布身份为Runtime随机128位epoch＋单调revision。每次成功候选提交都递增，包括同内容和undo／redo回到相同指纹；保存改变dirty／legacy标记也递增。失败及revision耗尽不发布，不用内容指纹冒充并发版本。Runtime重建产生新epoch，revision从1开始，历史恢复不承诺恢复旧请求回执。
- 受管理请求含随机client身份、从1连续递增的sequence、观察时的expected stamp和原命令参数。先找回执再判expected，重复回原status、created_id和task_id；同token不同参数或expected拒绝。回执保留最近64个，client高水位不随回执淘汰；过期token拒绝重做。client表动态增长，默认最多4096个客户端，预算用尽显式拒绝；在命令执行前预留client项，避免执行成功后因分配失败丢回执。
- Runtime统一互斥文档相关ABI的读写与旧命令／输入／pump；不能仅靠Host当前串行收包方式声称并发安全。新snapshot在该边界同时取stamp、fingerprint、节点高水位、flags和规范正文。先查询长度，再携原stamp读取；变更、epoch不符或短buffer不写文档字节。GUI校验完整候选后才发布，不再逐字段拼接文档镜像。
- GUI在帧队列入队时冻结expected，不因刷新自动改绑；每次仅持有一个未确认的owned请求。传输非零或Outcome不完整时保留原token／expected／参数，由pump重试同一请求并阻止新修改；收到明确Outcome后才推进sequence。投影失败继续另账，不能把已知成功改成执行失败。旧epoch或回执过期只证明当前不重做，不能断言旧Runtime从未执行；提示核对文档，下一次显式新意图才重新生成client。

### A2 的明确范围

管理入口为doc.open／write、编辑器文档操作、undo／redo与绑定文档快照的PNG导出受理；created_id仍由中央静态命令分类提取，尚非通用ChangeSet。doc.save、资源库／授权和原始语义输入仍使用各自旧调用契约；它们的文档变更参与revision，但没有全部转为expected请求。Library／Asset／Playback列表尚非与文档同版本的全局工作台快照。

回执在单个Runtime生命周期内有效，没有持久化exactly-once或Host重启后的原结果恢复；未知结果不能自动换token执行。完整断线重连、常驻执行所有者、任务受理事务／自主调度／多作业及跨文件保存事务继续归后续切片。本轮不删除旧UI／旧格式、不做系统安装或发布；样式仍遵循共享深靛蓝、冰蓝淡紫与克制金属反光规范。

## A2 实际实施与验收（2026-11-07）

上述单文档契约已接通Runtime原生ABI、Host显式小端管道编码、Shell client和desktop镜像。GUI在unknown时保留owned请求，晚到结果另存`lastDocumentOutcome()`；外部导入、编辑、预览和语义编辑门禁均考虑未确认请求。取消、释放、停止仍可用。新入口没有取代所有legacy ABI，也没有把全工作台多镜像拼成一个原子快照。

复核与负例另修三处实际问题：工作区原生入口沿用legacy read会合并显式空参数与缺省参数，造成错误的默认输出编辑及token冲突漏检，现保留presence并用真实DLL双客户端验证；超限参数现于GUI发送前拒绝，避免非法输入永久停留unknown；Shell snapshot thunk与原生入口统一要求携原stamp读取正文。旧epoch和过期回执的提示明确“原结果无法确认”，不能声称旧操作没有执行。

实际验证：

- `test-core test install portable library-probe` 为157/157步骤通过；完整轮执行1452/1452测试通过。最后空参数修正后的同一命令为157/157步骤、99/99执行测试通过，其余复用有效缓存。统计含模块重复，不等于独立产品场景数。GUI定向13项、帧队列4项、Shell codec／thunk6项通过；源内还覆盖same-content／undo-redo ABA、版本耗尽前无IO、分配失败前无执行、client预算拒绝且不丢高水位。
- 新`verify-workspace`真实分发DLL7组通过：快照版本／短buffer拒绝且不覆写，重复／冲突／stale／跳号／回执淘汰，独占journal锁失败缓存、解锁后同token仍回失败、新sequence恢复，Runtime重建拒绝旧epoch；8线程同token仅一次提交、8客户端同版竞争仅一成功；双客户端空参数／缺省参数分离。证据`staging`之外：`scratch/verification/workspace-cc2a575bf4e7/report.json`。
- 新`verify-workspace-rpc`通过真实Host管道，刻意收响应头后断开并丢弃导出Outcome，两次重发得到同一task_id且journal仅1任务；同时验证created_id、旧版本拒绝、冲突、同版快照、重启后旧epoch拒绝和文档恢复。20次原始帧及产物哈希：`scratch/verification/workspace-rpc-1300be77d9e9/workspace-rpc.json`。
- 同一份最终产物另通过`verify-edit-commit`4组、`verify-isolation`12组，及Runtime／input50事件／playback／replay／assets／Host。真实Shell、四次attach与NanoUI development／portable集成均通过；只有提交／隔离cwd／离屏功能证据，没有截图、自动真实输入或视觉／IME验收。
- 汇总证据：`scratch/verification/a2-acceptance-e01d3c4a7580/`，含两轮源码日志、10项headless和4项集成结果。最终验收前后portable74文件、bin30文件、Runtime Pack11文件、desktop Shell Pack21文件、NanoUI Pack13文件的哈希完全相同；Runtime DLL SHA-256为`46eba328780184e3830f1d902f338dffc17857fde5768b616226216d619e3c2d`。测试后Cutrans进程为0。

未删除真实安装、未知目录或用户数据，保留所有新认领案例和审计证据；未运行旧卸载器、未系统注册、未安装或发布。本轮没有安装器全流程验收，不能使用旧隔离切片的预检替代新ABI8安装验收。后续先做B的持久作业声明和常驻执行所有者，再推进Host自主多作业／取消／恢复；本条“单Runtime重试安全”不能提前代称这些能力。

## B1 契约定案（2026-11-07，用户继续推进）

本轮先完成可独立验收的持久导出与Host自主推进切片；B的非阻塞worker、运行中取消、显式重试尝试与完整任务UI仍不是本轮承诺。

- Job声明保存规范文档、受理来源epoch／revision／指纹、Source SHA、输出URI及当次已授权的绝对目标。原文档继续可编辑；Job克隆补Source SHA不反写作品。执行重新校验Source，缺失／漂移明确失败，不声称保存了所有旧资源字节。
- `tasks/jobs/<20位ID>.json`每项原子记录为真源，初始queued持久后才发布Task／队列并返回accepted。单项128KiB预算，终态档案可增长且默认保留；活跃队列8项、近期Task缓存40项、分页最多32项，均不是终身总任务上限。同ID不允许改声明或改写终态。任务／事件高水位拒绝回绕，受理先留足后续状态转换的事件身份。
- 单槽pending_export退出，改为有界FIFO；同一活跃绝对目标拒绝冲突。默认路径继续兼容`exports/output.png`，完成后再次提交仍采用显式既有覆盖政策；不能把两个默认导出假装成两个不同作品。
- PNG先编码到同目录临时文件，校验尺寸／像素、累计digest／长度并sync；prepared记录持久后才原子替换目标。输出成功、终态记录失败时保留已知结果，只补写记录，不再求值或覆盖。取消只针对排队Job，先持久记录再移队；已完成输出不因取消而删除。
- Runtime常驻4MiB执行所有者替代command／submit逐次建线程，并覆盖pump／jobs服务；一个同步有界inbox借用调用参数直到完成。其它legacy ABI仍共用Runtime锁，句柄销毁必须先停止调用。PNG当前仍在该锁内串行求值，运行中不可抢占，不能宣称长任务时交互已不阻塞。
- Host显式启用独立jobs driver：通知唤醒，空闲等待，失败100～1600ms退避并自主重试；不驱动后台播放，不改变手动Runtime／回放的择时。停止先暂停并等当前尝试、补写已知终态、保存文档；任一步失败报告degraded并恢复driver，退出先join driver／worker再卸载Runtime。
- 重建将未完成Job标interrupted并保留原阶段／声明，不自动重新入队。prepared记录意味着输出待核对，不凭存在文件或时间猜成功，也不重新解析旧external数字授权后写入。新Job需新用户意图；`retry_of`只是预留元数据，尚未实现task.retry命令或多Attempt状态机。
- 旧v1 Task日志仅作为近期投影及兼容来源；有无JobSpec须区分。原旧记录另存只读`legacy-journal-v1.txt`，高水位即使近期投影被删除也参与恢复。已完全由JobRecord表示的投影不制造多余旧备份。源内事件环恢复只读已初始化事件；恢复计数以权威Job转换及没有JobSpec的旧活跃项分账。
- 新增显式jobs_pump／jobs_flush／jobs_read原生服务、Host分页RPC及`cutrans_vm jobs` JSON查询；保留ABI8已有结构布局，新增服务符号由当前Host严格检查。任务页展示版本、阶段、输出hash／长度、错误与待持久化状态；旧无声明记录另列，不仅在Host stderr打印后就声称可重连查询。

仍保留的管道控制链问题需单独修复：连接／取消OVERLAPPED完成与无超时FlushFileBuffers边界。本轮独立jobs driver不依赖阻塞accept，但不把这代称为整个Host控制通道已有界停机。实际验收结果在下条追加。

## B1 实际实施与验收（2026-11-07）

上述契约已落实到Runtime、Host、CLI和真实产物。删除单槽pending_export、PNG直接截断最终文件及command／submit每次新建线程的通路；保留手动pump、旧Task读取与真实作品格式。输出目标在受理时作词法规范与Windows大小写比较，`exports/x.png`／`exports/./x.png`不再绕过活跃目标冲突保护；这不等于通用文件身份或任意目录联接别名识别。

施工与复验实际定位了以下问题并修正，没有统一归因于环境：

- 原子PNG替换会更换文件身份，原资源库测试原先通过原地截断来模拟内容变化；现显式构造替代PNG再原地写入作负例，继续验证同身份内容刷新，产品仍拒绝未经采用的文件身份变化。
- Source版本校验提前到受理，已知坏hash／缺资源不再先发孤立Task。现记录具体校验错误；旧assets脚本同步验证拒绝时task_id为0且无输出。执行后才漂移仍形成有声明的failed记录。
- 可重建近期投影缺失时，旧归档高水位最初未参与恢复；现总是合并archive／projection／JobRecord高水位，源内验证旧clock500、删除投影后下一个ID为501。合并事件clock跳跃时清空不匹配的事件窗口，避免读取未初始化槽。
- 陈旧v1 running投影不能把权威succeeded记录降级或虚报中断；恢复计数以原始非终态JobRecord与没有JobSpec的旧恢复事件分账。已经完全由JobRecord表示的投影不制造额外旧备份，实际隔离retry／rollback快照再次保持不变。
- Bootstrap新分页Reply类型推断错误已明确定位并修复。正常Host停止另补jobs_flush，避免已知输出结果仅因处于日志退避而在正常退出时丢失；先flush后保存文档，失败degraded并恢复driver。

实际验证：

- `test-core test install portable library-probe`完整轮161/161步骤、1524/1524执行测试通过；最后路径规范化后的封存轮161/161步骤、764/764执行测试通过，其余复用有效缓存。数字含模块重复，不作独立场景数。ledger6项、Task／Journal14项、PNG5项、driver3项、bootstrap2项定向机制均进入构建验证。
- 源内确定性注入“最终PNG已提交，但成功记录写入失败”：保留pending结果，先阻断record再解除，并故意把已完成输出换成用户哨兵；后续pump只完成record，绝不再次渲染或覆盖哨兵。另覆盖prepared保留／中断、不可改同ID声明／终态、OOM与坏JSON／hash／canonical、事件ID耗尽先拒绝及目标路径别名。
- 新`verify-jobs`真实分发DLL与Host **8组通过**：两个不同revision的7×5输出像素、digest与大小独立正确；8活跃背压／同目标拒绝；排队取消落盘且无输出；52终态不受40缓存上限限制，分页可查旧ID；受理目录阻断不发task_id且修复后仍从ID1开始；独占锁下保留旧输出、任务failed不自动重跑；重建保留声明并中断；受理后替换有效PNG则Source版本Mismatch且不产出错误图片。真实Host从无Shell状态受理后，仅等待文件出现，不发pump或状态轮询，即自行完成；随后RPC／真实CLI查询与stop/start仍找到同一Job。报告：`scratch/verification/jobs-c885b2172c0d/report.json`。
- 同一最终产物通过Workspace7组、edit-commit4组、isolation12组，以及真实Runtime／input50事件／playback／replay／assets／Host／Workspace RPC；真实Shell、四次attach和NanoUI development／portable集成均通过。使用日志、真实提交与离屏功能证据；未采屏、未注入真实键鼠，不作视觉／IME结论。
- 总证据目录：`scratch/verification/b1-acceptance-a2a35a75549f/`，保留失败施工日志、前轮通过记录及`sealed-*`最终11项headless＋4项集成命令结果。最终Runtime DLL SHA-256：`aa0ae8aedc0cba8982cf3c9f04a30505dac7a8a31f13abf82755eb78047e3379`；`sealed-summary.json`确认15项全通过，portable74／bin30／Runtime Pack11／desktop Pack21／NanoUI Pack13文件前后哈希一致。测试后Cutrans进程0。

本轮没有安装、发布、系统登记或清理真实数据；原安装与用户作品不作为试验对象，新认领证据均保留。安装器全流程没有因这些源码／DLL／Host测试而获得验收。尚未实测真实Host输出提交前后强杀的全部窗口，也未在真实Host注入恰好成功记录落盘失败；目前这两个阶段的严格证据在源内机制测试，不能冒充实际安装产物的全部崩溃窗口。

下一切片B2先将不可变输入／Source租约与worker执行从会话锁分离，保持owner短事务，补可持久取消意图、安全提交门禁和显式新Attempt重试；任务UI只投影这些业务状态。同时专项修管道超时／取消完成边界，再验证长任务期间编辑与真实关闭Shell后重连。旧资源字节留存和采用／重新定位仍归C；完整NanoUI迁移不抢在这些业务边界前冒进。

## B2 契约定案（2026-11-07，用户继续推进）

- 会话owner负责受理／捕获输入／状态与最终提交；独立常驻worker只拿Job值、owned Source字节、线程安全allocator、Io及窄原子取消令牌，不访问live Context／Station／Catalog。一次至多一个执行尝试，队列8项含正在执行的项；这不是多渲染worker并行。
- `export_inputs.captureLocked`逐Source读并核对声明SHA，复制到尝试私有内存；单源编码16MiB、总编码64MiB，解码前按PNG IHDR限制Source总RGBA64MiB。捕获后原文件或库发生变化不改本次输入；捕获前漂移仍失败。此预算不覆盖所有派生帧／编码器内存，不构成旧版本字节的持久保留。
- decode／DAG求值／PNG编码与临时文件写入在会话锁外执行。owner和jobs gate分离，完成后必须回owner核对当前active ID与最新取消状态，不能用worker旧Job覆盖后来取消。最后检查、prepared记录、atomic rename与已知成功标记在同一临界区。
- cancel先持久`cancel_requested=true`，再发布worker原子令牌；重复取消已受理／已取消的同一Task幂等。渲染在Source／节点／行／小块边界检查，取消清理本次未提交临时产物，不删除已有输出。stb单次decode／encode不可强行抢占；取消确认与取消完成分开。提交成功或结果已确定的pending-finalize拒绝晚到取消。
- 重建将durable cancel收敛为cancelled，保留prepared hash／长度而不改最终文件；其它未完成项仍interrupted／待核对，不自动重做。ledger严格限制阶段前进，拒绝旧快照回退及撤销取消，终态不可重写。
- `task.retry <id> [URI]`只允许failed／cancelled／interrupted且有声明的父项；创建新Task ID、递增attempt、用retry_of保留来源，原输入文档／SHA／origin／source_fingerprint不变，旧终态不改。attempt溢出或不完整旧lineage拒绝推测。新Job重新解析当次授权，不直接复制旧物理target。
- 外部输出重试必须显式给当前URI，默认还要与旧绝对目标规范路径匹配，避免Host重启后同数字external grant指向另一文件。确实要换输出时使用`--retarget URI`明确表达新意图，仍受当前授权校验。task.retry纳入A2 managed请求；丢响应只重发同token，不能重复创建尝试。
- Shell帧API只做frame／playback pump，永不抢先启动或等待导出；手动Runtime的旧pump继续确定性推进。Host明确启用jobs driver；direct Shell入口也显式启用同一通用driver，退出先暂停等待、补写已知结果，再清引用／join。通用实现移入VNE，Host仅投影；没有给所有Runtime添加隐式后台调度。
- 任务页真实输出attempt／retry_of／cancel_requested，并把running计入active_count。完整Task GUI控件和自动断线重连不是本轮实现；GUI命令入口可以调用同一受管理retry，取消按Task ID限定尝试。
- Windows管道连接使用有效OVERLAPPED／event；超时CancelIoEx之后确认该操作终结，才释放buffer／event／栈记录。删除无界FlushFileBuffers，按“一请求一连接、读完关闭”保留回复至peer关闭，使用有界等待；坏peer不读／不关闭时放弃交付，未知结果仍归A2原token重试。5秒是每次I/O或退场窗口，不是长业务请求总时限；OS本身失灵时不能以释放仍在用的OVERLAPPED换取伪安全超时。

本轮CPU求值已离开会话锁；Source捕获与状态持久化等IO仍在owner临界区，不能宣称任何慢设备均不阻塞。ABI8既有结构布局保留，当前Shell严格查新增frame_pump服务；旧Job记录缺省新字段可读，不承诺旧程序能读写新能力。实际验收另条追加。

## B2 实际实施与验收（2026-11-07）

上述owner／worker分工、持久取消、新尝试重试、帧服务与管道修复已实现。`export_inputs.zig`新增尝试私有Source；`render.Preview`提供默认关闭的取消检查；Runtime维持一个owner与一个compute worker，旧手动Context／replay仍保持确定性同步语义。Host driver机制移入`vne/job_driver.zig`，旧Host文件只作投影，避免重复实现。真实系统注册／安装和用户数据没有参与试验。

复核发现并修正两项会破坏目标的细节：

- 只让普通pump对“已有”worker tryLock还不够：GUI若先抢空闲gate，仍会同步做整次导出。现bootstrap及direct Shell的ShellApi都绑定frame-only pump，显式driver负责作业。direct Shell退出还暂停等待并flush已知结果，不能报告成功却只在内存保有终态；默认独立Host关闭Shell不会终止其driver。
- 仅要求retry显式URI不能阻止旧external数字在重启后指向新文件。现默认比较规范绝对目标，不匹配拒绝；只有`--retarget`允许明确改目标，仍重新校验当前授权。原Task与输入声明不变，retry纳入A2 receipt去重。

构建与验证：

- `test-core test install portable library-probe`最终163/163步骤通过，最后原生退出收尾后的135/135执行测试通过，其余复用有效缓存；初轮1825项执行测试通过但desktop曾遇到施工中的旧array-repeat语法，改为固定Zig 0.17支持的`@splat`后后续完整构建均通过。数字含模块重复，不作产品场景总数。
- 新增owned Inputs4项、render取消2项、ledger扩至11项、真实OS管道5项，通用driver／既有规则继续通过。源内确定性barrier将compute暂停时，编辑、持久取消、frame pump、manual pump均先完成；取消字段在释放worker前已存在durable running记录，释放后cancelled且无输出。另验证固定token retry只建一个attempt2并输出旧gain0.8，当前文档gain0.25不影响它；以及Runtime重建grant1从A改指B时，默认／旧URI拒绝、明确retarget才输出B。
- 新`verify-jobs-async`真实DLL／Host **9组通过、0项不确定**。实际观察到4096²运行窗口，edit／snapshot／frame_pump／cancel调用前后worker均仍在运行；取消持久化、旧输出哨兵无损及本次临时文件清理通过。managed retry新ID／attempt2／retry_of／同token replay、旧输入像素、终态取消规则、外部grant复用拒绝／明确retarget／同路径新授权、Source捕获后修改原PNG而4K输出仍用旧色、无Shell Host自主重试与CLI／重启查询均通过。Source大图检查包含PNG所有chunk CRC、首像素和durable文件digest，不冒充逐像素全图比较。报告：`scratch/verification/jobs-async-d24d4f6cb0a1/report.json`。
- 新`verify-host-transport`真实产物 **8组通过**：约262KiB PNG的延迟读取完整一致；silent peer、不读取小回复、只读大回复header且不关闭坏handle时，独立客户端约5秒恢复服务；截断payload、16次断链及后续32次快照成功。超时read／write完成取消后可复用连接／endpoint；小回复缓存没有因删Flush而被提前Disconnect丢弃。报告：`scratch/verification/host-transport-e6782742e30b/report.json`。首轮probe曾误把既有asset_open_external的accepted=1当成ok=0，只修脚本接口预期，失败证据保留，不以此冒称产品环境故障。
- 同一封存产物另通过B1 jobs8组、Workspace7组、edit-commit4组、isolation12组及Runtime／Host／Workspace RPC／input50事件／playback／replay／assets；真实Shell、四次attach、NanoUI development／portable均通过，没有采屏或注入真实键鼠，也没有视觉／IME结论。
- 总证据：`scratch/verification/b2-acceptance-dfb040fe0e7d/`，保留施工／集成日志及`sealed-*`最终13项headless＋4项集成命令结果。`sealed-summary.json`确认17项全通过，portable74／bin30／Runtime Pack11／desktop Pack21／NanoUI Pack13文件前后哈希一致；最终Runtime DLL SHA-256为`64c2a5ddee83ed595f5df9dd2bae846b629f38255d6b5e7140b770fbad88cfc2`。测试后Cutrans进程0。

没有清理真实安装、作品、未知目录或旧会话；新认领证据全部保留，没有运行卸载器、安装器或系统登记，也没有发布。direct Shell完整窗口退出组合与rename门槛两侧的所有真实DLL／OS崩溃竞态仍未穷尽；目前有实际异步窗口、源内同步门禁与分立driver测试，不能代称所有实际路径都已验收。安装器全流程结论仍未新增。

后续按C推进资源版本／旧字节保留和共享求值服务，预览／播放／导出继续共享求值语义与版本绑定；完整任务GUI和NanoUI场景迁移在这些业务状态之上推进。没有把本轮Source内存副本、cooperative cancel或单worker误称为持久版本库、硬抢占或多worker并行。

## C1 契约定案（2026-11-07，用户继续推进）

本切片先补“已采用版本”的真实字节留存和一致读取，不提前实现整个C。库引用导入／浏览仍是reference，只有插入文档或受理导出等明确采用行为才留存对应Source；不隐式将全部外链复制为owned。稳定库ID＋既有SHA-256继续进入`.cut v3`，不新增缓存地址或用户物理路径。

- `library/versions/<id>/<sha256>.bin`属于实例的持久Source数据，不属于cache／temp／构建输出。逐级不跟随链接打开目录并核验实际handle类型，叶文件也不跟随链接，避免嵌套联接把Source引到程序或缓存根。字节写完并sync后以不覆盖方式原子发布；重试只复用相同内容，腐坏版本拒绝读取与隐式修复。没有自动版本GC，失败编辑可能留下无引用版本，保留等待后续显式保留政策。
- 文档／History候选发布之前先留存其采用的library Station字节；可采用仍在Station中的旧版本，即使库当前head已更新。留存失败不发布文档或History；History失败可留下孤立版本，但作品状态不变。Job成功受理前也先确保绑定版本持久存在。
- 预览／播放、导出受理和worker捕获均按URI＋声明hash读取。已有retained版本优先，损坏绝不退回current；旧作品没有retained记录时只允许库head和实际字节均与声明hash相等的兼容路径，读取不新增版本留存，漂移失败，不用最新字节冒充旧版本。既有external读取仍可能核对并记录授权元数据，不据此宣称整个读取调用绝无IO写入。
- `library.refresh`仍是用户显式更新库head，不修改已有文档、History、Job和Station租约；重新插入新版本形成普通可撤销编辑。完整重新定位／跨文件替换采用命令、历史版本列表和保留UI继续后置。
- Shell新增指定URI／hash的Source字节读取服务，经同一Runtime所有者、窄ABI和Host协议投影。GUI拿到owned字节／解码帧，不申请远端Station租约，不按URI猜第一个镜像handle，也不借用面板租约再代其释放。丢回复只丢本次拷贝，不留远端新租约；Source释放是本地操作，不在求值提交栈内刷新镜像并改写输入文档。旧字段布局保留，新Shell明确要求新增服务。

完整FrameLease的epoch／revision／output／time／format身份、迟到提交门禁和共享异步求值调度仍是后续C；本轮只让现有共享DAG求值路径读同一指定版本。租约跨Shell异常断线的所有者回收与未知回复去重也未在此切片承诺。真实GUI／IME与安装包全流程仍遵守既有边界，验收在实施后追加，不以本条计划代替结果。

## C1 实际实施与验收（2026-11-07）

已实现`resource_versions.zig`的不可覆盖Source留存、Catalog指定版本读取，以及插入／Job受理前的留存门槛。`assets.readVersion/openVersion`为预览、播放、导出受理和worker捕获共享解析规则；旧Station版本与库current可以并存，reference不因留存变owned，浏览不产生版本副本。Catalog替换Source URI另改为先分配后释放，避免OOM时deinit重复释放。所有新留存数据位于实例数据根，程序／缓存根不承接它们。

GUI删除按URI扫描第一个镜像handle及借用后释放他人租约的路径。最终采用`cutrans_vm_source_read`与ShellApi末尾新回调、Host RPC25：版本化定长头＋URI／可选64字符十六进制hash，返回有界encoded字节，GUI核对hash并解码为自有Image。读取在Runtime既有owner线程上执行，失败清空长度且不写调用方buffer；GUI release不调用command／refresh，不在求值提交期间重入改写输入镜像。ABI8既有前缀不变，新Shell要求完整新表与符号。

复核中收紧了两处真实边界：版本目录逐级nofollow且核对opened handle类型，叶文件也拒绝重解析点；跨进程Source不创建持久Station租约，丢回复只丢本次字节拷贝。没有为每次预览再引入请求账本／租约会话管理。原有资源面板的Asset命令未知结果与断线所有者回收仍是后续事项，不能把新读取的无远端租约性质外推到所有旧资源命令。

实际验证与证据：

- 总目录`scratch/verification/c1-acceptance-aaf4745814c3/`。`test-core test install portable library-probe`最终`build-final.log`为**165/165步骤通过**；新接通Host入口的5项测试执行通过，其余复用有效缓存。首轮有2083/2083执行测试通过，但Host测试编译发生stdlib读取失败，不能称首轮命令成功；这些数量含模块重复。
- 版本存储2项机制测试通过；新增Station版本与租约边界、文档／History失败、legacy Job留存门槛、冷恢复和队列消费等源内场景进入完整测试。GUI fake API验证同URI A/B完整PNG像素、失败／坏hash／超限读取恢复、面板租约与文档不变及旧API表拒绝。发现Host根仅声明pub模块时原先实际执行0项，已显式接通子模块测试；不把编译成功冒充执行了mock负例。
- 新`verify-resource-versions`真实DLL／Host **11组通过**，报告`scratch/verification/resource-versions-41b8c90ceb02/report.json`：浏览不留存／不detach；pin写失败不发布Doc／revision／History；save后原外链变／删仍冷读旧字节；两版本queued输出、Station并存和undo／redo；重启后新attempt重试原版与token去重；只删本case cache／temp不损固定版本；坏版本不fallback／不自动修复／不覆盖输出哨兵；未留存legacy同hash兼容与Job受理失败无孤立ID；真实NTFS junction拒绝越界读写且目标全部哈希不变；真实Host无Shell自主导出和重启、RPC坏包以及3次发送完整请求后故意不读回复断链，后续读取正常且Station不变。1×1 PNG逐像素对账；headless播放求值不冒充GUI纹理验收。
- 最终同一产物的`sealed2-*` **14项headless命令全通过**：C1、assets、B1 jobs、B2 jobs-async、Host transport、Workspace／RPC、edit-commit、Runtime、input、playback、replay、Host和12组isolation负例。`sealed2-summary.json`核对portable74／bin30／Runtime Pack11／desktop Pack21／NanoUI Pack13文件前后哈希全部相同。最终Runtime DLL SHA-256：`4c761f49caaf77073871571220723cb7308073792367084cd1b6ce55d19607e4`，测试后Cutrans进程0。

施工失败均保留并定位：旧`verify_assets`仍预期“已采用的库版本随原文件变化／缺失而导出失败”，与C1目标冲突；现验证旧工程精确输出留存版本，同时保持current浏览报告原文件缺失，以及非库Source缺失／坏hash拒绝。另首轮Host测试编译读取`std/debug/no_panic.zig`报`Unexpected`；本机2523字节及SHA-256与固定归档完全一致，未修改工具链，同代码单并发复验与最终构建均通过。该间歇读取异常根因仍未确定，未统一归因于环境；负例中故意持锁造成的sharing violation日志也未误算为产品回归失败。

本轮所有自动化进程使用统一隐藏入口，6项控制台策略测试和6源依赖树审计通过；未打开GUI测试窗口、未采屏或注入键鼠。没有运行安装／卸载／系统登记、更新现有体验安装或发布。仅新认领案例中明确创建的Source、blocker、cache／temp被用于故障注入并按脚本记录删除；真实会话、作品、凭据、归属不明数据、失败日志与junction证据全部保留。

后续C继续做同一稳定ID的重新定位／明确采用、版本投影和完整FrameLease／共享求值服务。版本留存与Source读取IO仍在owner上，不保证任意慢盘不影响交互；通用异步求值尚未实现。版本默认保留，无自动GC；目录32资源与文档8节点的原型限额未改，任意未留存的历史外链字节不能凭hash恢复，`.cut`单文件也未自动打包实例资源。该存储边界要求调用方提供可信数据根，不宣称抵御同用户任意并发文件系统改写的完整沙箱。真实GUI／IME与安装包全流程没有因本轮测试获得新增验收。

## C2a 契约定案：真实文件身份与旧授权边界（2026-11-07）

推进资源重新定位时发现现役Windows Port的`BY_HANDLE_FILE_INFORMATION`布局错误：`dwFileAttributes`应在首字段，旧实现放到末尾，导致volume／file index从错误偏移读取，不同文件可能得到同一伪身份。旧测试仅检查非0不足以证明身份正确；旧记录里的数值不能直接作为修正后的文件身份。当前切片优先修复这个前提，完整重新定位／采用新版及资源CAS协议后置，不能将仅检查文档revision的请求管理直接套到资源变更。

- Win32结构按本地SDK核对size和offset；文件身份、元数据与字节来自同一打开句柄。Windows外部Source读取短时只共享read，拒绝已有writer／delete冲突，并在读取前后核验元数据；非Windows仅保留单句柄／元数据核验，不提前承诺相同共享锁保证。
- 新授权写`cutrans-external-sources/2`，每项明确身份scheme。旧v1只读加载为`legacy-cutrans-layout/1`，保留原始数值与last hash，不自动探测、洗白或重写；未明确确认的旧外链读取返回独立错误。last hash可能只是旧程序的观察记录，不能替代显式授权。
- C1已留存库版本仍优先读取持久字节，不因旧外链身份待确认而丢失作品。未留存旧外链需要`source.reauthorize <id> <expected-sha256> <absolute-path>`显式核对：只允许原canonical路径、单句柄实际字节匹配预期hash，确认后原grant ID和路径不变，仅记录新的真实身份。已确认项仅允许相同真实身份／hash的幂等核对，禁止借此把原授权偷偷改给另一个文件。
- 确认只提交一份授权catalog，失败回退内存，文档／History／库head／Job／已有Station不变；混合v2保存仍明确保留未确认的legacy项。不能将此动作冒称重新定位或更新作品内容。新布局不承诺旧程序可降级重写。
- 外部grant发号穷尽显式返回错误，不回卷或复用旧ID；MAX记录可恢复而不触发整数溢出。8项总授权预算尚未改造，不靠覆盖旧槽或放大数组解决长期量。

通过真实DLL／Host验证之后另条追加实际结果；本条仅为施工契约。保持隐藏自动化，不启动真实GUI、不修改现有安装或真实数据。

## C2a 实际实施与验收（2026-11-07）

上述真实身份、旧scheme隔离与显式确认已实现。`ports/file_identity.zig`按固定SDK逐项断言52字节Win32布局，提供`queryFile`与单句柄`readStable`；外部Source身份与内容不再由两次按路径打开拼接。`external_sources`写v2混合身份记录，v1不probe／不重写，未确认读取用ABI状态16明确返回。显式确认只改一份授权catalog，wrong path／hash／file identity拒绝，持久化失败回退记录；已确认同对象核对完全不写。旧raw数值及未确认的其它项继续保留，观察hash不作为自动授权凭据。

同时封住两个类型／权限绕过：已记录持久文件授权在Source分流前直接走普通文件读取，不能被原路径上的合法snapshot目录绕过；文档插入按URI而非SourceKind检查临时external授权，临时目录快照仍可浏览，显式Session快照才可形成对应可恢复引用。外部grant发号的0值代表耗尽，MAX记录能恢复，恢复中途失败撤本次挂载并还原计数，不回卷或覆盖旧槽。原有8项授权预算未扩大。

实际验收：

- 总证据`scratch/verification/c2a-acceptance-24d1ab902af7/`。最终`test-core test install portable library-probe`为**165/165步骤通过**（`build-final.log`），最后4项执行测试通过，其余复用有效缓存。修正夹具后的前轮1959/1959执行测试通过，但3个std loader编译失败，故不将前轮命令称作成功；数字含模块重复。
- 源内新增真实不同文件／同文件身份、旧打开句柄不随路径替换、普通writer／delete双向冲突、metadata变化／短读／预算／非file；相同内容不同文件Station不混并、持久文件变目录拒绝；v1原始证据无写、确认失败回退、verified确认byte-noop、混合scheme严格恢复、ID耗尽与部分挂载回退；另验证临时目录快照不能绕过插入持久性，GUI明确区分legacy错误后可恢复，不消费面板租约或修改文档。
- 新`verify-source-identity`真实DLL／Host **8组通过**，最终报告`scratch/verification/source-identity-d37865b7e42c/report.json`。独立Python Win32结构交叉核对volume／完整file index及52字节偏移；同hash不同file不混并；原子换file或合法snapshot目录仍拒旧文件权限，已留存作品继续导出；真实旧错位布局v1只读保留且raw读取返回状态16；错误hash／path／语法及锁authfile失败不改Doc／History／授权和库catalog；显式确认保留grant／library ID并冷恢复；幂等确认、混合保存不洗白其它旧记录、已verified换file拒绝；实际Host经RPC返回状态16→显式确认→正确字节、无Shell导出与重启均通过。
- 同一最终产物的`sealed-*` **15项headless命令全部通过**：C2a、C1版本11组、assets、B1 jobs、B2 jobs-async、Host transport、Workspace／RPC、edit-commit、Runtime、input、playback、replay、Host及12组isolation。`sealed-summary.json`记录portable74／bin30／Runtime Pack11／desktop Pack21／NanoUI Pack13文件前后哈希完全相同；最终Runtime DLL SHA-256为`ba78e6e2129b7b9146777ef3b31c02ad42fd1e984984fbd966ba1549040e4c23`。测试后Cutrans进程0。隐藏进程6项测试和6源依赖树审计也通过。

首轮失败已明确分账并保留：新external测试夹具把`realPathFileAlloc`的sentinel类型擦掉后按短一字节长度释放；新文档测试深比较了未使用的undefined节点槽。前者保留sentinel类型并单独释放，后者改为有效文档／History语义状态对账；均为测试实现错误，没有将它们归因于环境或作品损坏。

固定Zig的`Unexpected`仍未定位。此次初轮4个、复验3个不同std名字报告unable to load，同源码最终构建通过。只读审计确认编译器／归档哈希匹配、11个本轮及历史相关std文件逐字节匹配，无文件或父级reparse；176次Python读取、160次非空native read及176次native stat均成功，未捕获失败NTSTATUS。对前述“标准库文件读取异常”的补充：这仍只是loader诊断标签，尚未定位源文件IO或派生缓存操作；官方master提供的loader线索不是固定0.17实现的直接证据，未拿其它版本／平台issue作本机归因。证据和缺口见同目录`toolchain-read-audit-notes.md`、JSON、脚本及日志；没有改toolchain、缓存或系统，没有宣称此问题已修复。

本轮没有真实GUI／IME、安装／卸载／系统登记、升级或发布，也没有读取或自动迁移实际用户授权、作品与安装。仅独立案例合成文件用于替换、锁和legacy注入；被换文件按脚本保留，实际数据与全部失败证据保留。底层确认命令不代称完整恢复向导；普通GUI帧队列长参数限制仍在。重新定位／明确采用新版、资源独立epoch＋revision及回执、候选身份／hash冻结、完整FrameLease与异步求值继续后续C，不能把文档A2的版本保护直接套给资源操作。

## C2b 契约定案（2026-11-07，施工中，尚非验收）

本片完成资源重新定位／明确采用的VM协议、同一Runtime重试保护、共享Shell客户端和实际DLL／Host负例；完整恢复向导与两套GUI按钮另片接入，不能提前称为可视交互完成。

- 资源独立stamp为Runtime epoch＋Catalog单调revision，不复用文档版本。一次成功实际库变更只前进一次，无操作不前进，失败和耗尽先于IO拒绝；同Runtime恢复不能重用旧版本号。一致快照只包含库业务声明，不把授权观察日志拼作库版本。
- probe为无副作用读取，返回stateless proof，冻结目标ID、模式、库stamp、原head、新hash、规范路径hash、长度与真实file identity；不分配持久候选、grant、Station或版本。submit重新稳定读取并逐项核对，candidate变更拒绝。proof是调用前提，不是假称为插件权限令牌。
- relocate仅允许同hash修复引用位置；adopt显式更新库head。稳定库ID不变，原文档、History和已受理Job不自动改版。采用字节先按ID＋hash不可变留存，再发布新head。
- 同路径原子换文件需新immutable授权绑定；旧grant保持旧真实身份，不能借重新授权洗白共享旧引用。授权依赖先持久化，库catalog再原子提交；后者失败允许未引用的授权／版本对象保留，业务head与revision不变，不宣称跨文件原子事务。不自动GC现有8项grant预算。
- 资源受管理请求独立client／sequence与有界回执，先回原结果再校验当前stamp／候选，丢回复后仅重试原请求。回执仅在当前Runtime内，旧epoch不能证明旧执行结果。共享客户端将已知提交结果与投影刷新失败分账。
- 新owned内容与detach复用不可变version存储，移除先覆盖后删除的失败清理；旧content文件仅作缺失时兼容读取，坏版本不可回退。ABI显式升9，新增独立resource API v1，原文档API语义保留。
- 所有自动验证隐藏控制台，只使用认领的合成数据，封存实际产物哈希后再测试。不启动真实GUI／旧卸载器、不触碰现有安装或系统注册，不以源码测试代替安装验收。

## C2b 核心实际实施与验收（2026-11-07）

上述核心契约已接通ABI9、Runtime owner、Host RPC 26～28和无GUI依赖的共享资源客户端。文档与资源共用`request_receipts.Book`的内存预留、序号高水位与有界回执机制，仍保留独立版本域、请求内容和业务执行策略。候选proof无server状态，提交先回原回执再核对当前stamp／文件；同路径新对象采用新的不可变授权绑定，不改旧grant。回执仅当前Runtime内有效，不宣称跨重启exactly-once。

create／detach已删除先替换content再失败删除的通路，改用不可变versions；owned当前读取仅在对应version缺失时兼容旧content，损坏或链接错误不回退。资源普通无操作不推进版本，**恢复目录视作一次独立发布，即使同声明也推进库和Station投影revision**，以免旧归属镜像继续命中缓存；此处补充前条普通noop规则。恢复旧目录保持同Runtime已发号高水位。owned旧来源只允许空或严格非零数字external URI，拒绝物理路径／其它scheme并保留原catalog字节；允许detached和旧created的失效external来历，不因此恢复已失授权。

Shell公共客户端冻结owned路径、proof、client和sequence，未知时保留原请求；读取目录可以继续，新的资源意图被拒。已知提交与投影刷新分账；除wrong_epoch之外，异epoch或倒退revision的Outcome均继续按unknown核对。旧epoch／回执过期明确提示旧结果不能确认，只有随后显式新意图才取新nonce。NanoUI修复Api拷贝前大小／版本检查，两套GUI按钮和旧mirror的整体切换尚未接入，不能将公共客户端完成代称可视恢复操作完成。

实际验收：

- 总证据`scratch/verification/c2b-acceptance-db52e5a466f6/`。最终`test-core test install portable library-probe --summary all -j1`为**171/171步骤通过**（`build-final-2.log`，最后16项执行测试通过，其余有效缓存）。此前完整轮2258/2258执行测试、171/171步骤通过，随后最后修正的恢复／URI规则经最终构建复验；数字含模块重复，不是独立场景数。
- 源内覆盖共享回执高水位／预算／OOM、库mutation精确版本与耗尽先于IO、恢复不倒退ID且使Station归属失效、不可变owned／legacy兼容与失败哨兵、samepath新授权及legacy确认别名恢复、PNG预算和实际decode；公共资源客户端11项fake测试覆盖ABI早拒、owned临时投影、完整pending冻结、stale／冲突／epoch／过期、投影失败与坏Outcome。Native／Host／wire负例验证短buffer、坏frame和已知业务拒绝。没有打开真实GUI。
- 新`verify-resource-operations`实际DLL／Host **13组通过**，最终报告`scratch/verification/resource-operations-617570d956e1/report.json`。覆盖无副作用重复probe、一致快照／短buffer／stale／epoch、旧路径缺失后的同hash relocate、不同内容拒绝、adopt只改head并保留旧Station实际字节／文档／History／排队Job、新插入采用新版本、丢回复后另client改C及候选B被移走仍回原receipt、token冲突与回执淘汰、候选同文件变hash／同hash换file拒绝、versions阻断／auth锁／catalog锁失败不发布半head且明确保留依赖、owned拒绝、同路径多真实身份冷恢复；8线程同token只执行一次、8客户端同stamp仅一成功；真实Host malformed frames、丢回复重放与重启旧epoch拒绝均通过。
- 同一最终产物的`sealed-*` **16项headless命令全部通过**：新资源操作、C2a身份8组、C1版本11组、assets、B1 jobs、B2 jobs-async、Host transport、Workspace／RPC、edit-commit、Runtime、input、playback、replay、Host及isolation12组。portable74／bin30／Runtime Pack11／desktop Pack21／NanoUI Pack13文件前后哈希完全相同；Runtime DLL SHA-256为`a7ad2bbe5b94d9bd7f3af45365d1b1ccba50863a56958d4a590b429a636aef54`。隐藏自动化6项测试、6源依赖树审计均通过，测试后Cutrans进程0。

失败记录分别保留：初轮两处旧Zig数组重复语法、一处运行期tuple迭代及公共client fake误存Request指针均已修正；实际产物首轮verifier试图对整个活跃Host数据根计算hash，误读独占`host.lock`而失败，改为核对probe明确不能修改的授权／库／版本／History声明，仍分别核对文档和Station，未忽略权限错误或放宽产品校验。首轮报告`scratch/verification/resource-operations-419df10112f7/report.json`与全部日志保留，不归因环境。

固定Zig再次间歇报告不同std条目的loader `Unexpected`；最终同源码重试通过。最后失败轮1464/1464执行测试通过但1个loader编译失败，整体失败明确保留在`build-final.log`，不称作成功。根因仍未定位，未修改toolchain、缓存或系统，也没有据此推断Defender、磁盘或源码损坏；延续C2a的证据边界。

本片没有安装／卸载／系统登记、发布或真实GUI／IME验收，没有读取或修改实际会话、凭据、作品和现有体验安装。所有替换均为认领案例的合成文件，旧对象和阻断哨兵移到同案例保存；未清理未知目录、未运行旧卸载器。允许留下的不可变版本和未引用授权默认保留，当前8项grant预算继续存在。

下一片C2c先将资源目录投影和操作接到同一个公共客户端，再加入“重新定位（相同内容）／采用所选内容（仅更新资源库）”的薄UI。必须绕开旧128字节帧参数限制，未知提交期间门禁覆盖旧库操作，保留旧Station预览与稳定选中ID，并分开显示已知结果／投影刷新失败；继续使用共享深靛蓝、冰蓝淡紫、克制金属反光。完整FrameLease／共享异步求值、版本列表／保留UI、自动重连及通用声明注册仍归后续切片。

## FileHub方向补充与资源分层建议（2026-11-07，讨论，未实施）

用户在阅读`C:/FileHub/MEMORY.md`后明确：**Cutrans的文件资源管理器应更偏向FileHub的资源空间思路；下载器等在Cutrans中是专门应用，不内嵌到文件资源管理器。** 这是产品方向补充。资源管理器服务整个创作工作台，剪辑、下载及其它应用通过公共资源能力协作；文件管理器不承担各应用完整业务。沿用VM掌握权威状态、Shell拥有投影与交互的边界。

以下是此次评估建议，尚未作为已实施功能或用户逐项定案：

- 分开稳定资源身份／逻辑组织／附言与来历、实际来源绑定及其代际、内存载荷代际／覆盖范围／租约、文档和Job采用的固定内容版本。持久目录及用户正文不是可丢缓存；来源说明也不自动成为持续读取／同步关系。
- FileHub已明确的内存命中不回源、限定已加载对象刷新，对Cutrans通用资源管理器有直接参考意义。当前`assets.openVersion`先read再查驻留，release零即销毁；已有`render.Preview`缓存命中不必回源，不能笼统说全部预览都在重复IO。建议补真正的RAM acquire和有预算驻留，来源状态与内存可用状态分账，刷新产生新代际并保护旧租约／脏编辑；统一F5不直接绑定现有持久`library.refresh`。
- “owned使用普通可变文件”在FileHub记忆中仍是助手架构建议，本轮也仅建议Cutrans通用资源层考虑。普通文件可继续被专业应用保存，已发布内存载荷与已采用版本保持不可变；C1/C2b的不可变版本存储服务作品／History／Job的恢复保证，不据此要求全部普通文件永久不可变。既有留存字节和旧作品不得自动改写或清理。
- 保留C2b的身份核对、候选proof、CAS、失败保护和回执机制；PNG限制、编码／解码预算及reference-only relocate/adopt是当前素材切片政策，不扩为所有文件、目录和Note的通用规则。未来一致目录stamp继续服务投影，目标资源／绑定代际可减少无关目录变更对操作的冲突。对象型与位置型来源授权须各自定义，不能借刷新扩大既有授权。
- 支持完整目录来源、逻辑文件夹、原生正文及附言；格式解释交给provider／应用。目录列表、缩略图、PCM不等同完整原始文件或完整目录，只有实际持有完备内容／依赖才能独立保存。跨产品借用契约或模块不意味着共享Cutrans与FileHub的用户数据根、授权或活动对象。

建议将原C2c“立即补按钮”的顺序先调整为资源契约与驻留闭环，再接公共客户端与UI：引用完整文本入RAM→原件删除→命中继续使用→限定刷新报告缺失而保留RAM→从完整字节独立保存→重启恢复；再验证修改owned后旧作品／Job仍消费原版本。具体类型、持久格式、SQLite与否、实现步骤尚待细化；本次未修改源码、升级依赖或运行应用测试。

## 独立App、来源区域与VM资源入口（2026-11-07，用户澄清，未实施）

用户进一步明确以下目标边界，取代把资源管理器只当剪辑器附属面板的理解：

- 分类细化到独立App：外部本地文件浏览应用、VM专用资源管理应用、桌面、命令行、类PS编辑器都是独立应用。云存储浏览也可作为独立应用；下载器继续是专门应用。共享VM服务不使它们合并成同一应用，也不要求每个App独立进程。
- 来源有本地外部区、云端区、VM专属内容区。本地来源浏览排除VM托管区；VM全屏下仍应能通过自己的应用／协议访问外部磁盘，Agent与CLI使用相同VM指令。此为能力目标，不是授权本次扫描全盘或接入真实云账户。
- VM资源空间收纳已登记的引用及独立内容，其逻辑集合可以同时引用本地和云端；它不等于只列出VM专属物理文件夹。其它消费App统一通过VM资源身份／协议使用内容，来源路径及云定位由公共服务解析。资源管理App是该空间的交互入口，目录、身份和任务由VM服务持有，窗口关闭不撤销资源或停止其它App。
- 外部文件／文件夹拖入默认引用。右键显式独立化后保留显示名，以引用／独立标记区别；不强行加“副本”后缀。对同一资源独立化沿用已有稳定ID并切换来源绑定，原来源可作为来历保留。文件夹作为完整来源单元处理，不打散相对依赖。
- OS文件直接拖入其它App，是“先登记到VM资源空间，再交付给目标App”的快捷组合，不能成为旁路来源访问。目标App接收统一资源引用；同一操作重试不重复登记。登记已成功而打开失败须分别呈现，保留已登记资源并可重试交付，不回滚删除外部原件。
- VM普通内容编辑只发生在专属区；外部本地和云来源不提供通用删除、重命名、移动或写回原件。导出到本地／云是明确的出境复制，不建立持续同步关系。资源库移除引用与删除外部原件语义分离。
- 用户提出从资源空间向B站／QQ等交付的可能性；可由“发送到／发布到”的应用协作承接，尚未决定实现具体接入，不表示授权读取账号、发送消息或公开发布。

下列是为保持以上规则一致的解释和待细化建议，尚非新增实现或用户逐项确认：

- 将“复制进来”区分为读取所需字节进RAM与独立保存完整内容到托管区。前者可保留reference，后者才成为owned；不将默认登记引用伪称已复制原件。类PS／剪辑器读取引用并在专属区保存自身作品可正常成立；要直接修改该资源本体，先显式独立化，或把结果另存为新资源，不静默改变归属。
- 建议App显示名为“本机文件”“资源库”“云端文件”；来源浏览器、资源空间、托管内容区是不同层面的术语，名称仍待用户选定。三App可以复用列表／树／预览组件，入口与职责独立。
- 三个区域按来源归属和权限定义，不按是否同一硬盘定义。云缓存落在本地不等于owned；引用记录保存到VM目录不等于原媒体已经搬入。托管根由运行上下文声明并在来源解析层排除，目录别名／链接及直接指令都遵守同一边界；UI隐藏路径不是沙箱实现。
- 直接导出应使用绑定目标／操作的细粒度能力，与普通来源只读能力分离；不能以一个通用external read_write许可间接开放外部删除。默认创建新对象、同名覆盖另列写意图的具体政策仍待细化。原生作品向其它应用交付时按目标能力材料化，目标App持有账号、格式、传输和回执策略，资源库保留统一发起入口。
- 能访问全盘是可按需导航／查询的能力，不要求启动全盘递归扫描，也不要求把所有文件提前登记入库。云对象定位与版本条件由云provider定义，不照搬Windows File ID或将云版本标识当内容SHA。
- 当前原生同进程模块仍是受信任代码，这次确定的是资源与写入边界的目标模型。强制约束不可信App／插件还需要受控IO口岸及实际隔离，不能因命令门禁或界面分区就宣称已有OS级沙箱。现有mount仍有通用read_write和旧外部URI通路，后续须在兼容与迁移计划中审计，不自动扩大旧授权或改写旧作品。

本轮只记录和讨论架构，没有修改运行代码、扫描实际磁盘内容、安装应用、升级依赖或执行新应用验收；C2b现役功能及其证据范围保持原记录。

## C2c1 实施契约（2026-11-07，施工中，尚非验收）

用户授权继续改代码。本片先完成当前PNG路径中的已加载资源闭环：取得当前已加载版本→来源失联后仍可预览／核对→从完整Station原始字节独立化→冷重启恢复；本机来源浏览App、云App、通用目录／文字、可变owned保存及OS强制沙箱继续后续实施。

- 新`asset.ensure <资源ID> <预期SHA-256>`只面向已登记资源，要求当前catalog head匹配预期；按ID＋hash取得完整Station内容，命中不回源、不分配新对象、不增加远端租约。未命中才走严格加载并建立一次Station根引用；同参数丢回复重试不累积lease。lease归零仍释放，本片不承诺LRU驻留或释放后的命中。
- 原`asset.open`／`openVersion`／`source_read`保留严格当前／固定版本读取语义，不用RAM隐藏持久version损坏。两套资源UI通过共享helper精确选择当前head，移除“同library_id任挑handle”；新候选预览成功后再替换旧预览。
- 新`asset.check <已加载handle>`只核对指定已加载资源，不加载未驻留资源。检查只发布来源观察状态，不改catalog head／授权观察记录／Doc／Job／原始字节。缺失、内容变化、真实身份变化、legacy未确认及不可核对分别表达，旧内容仍可用；状态标为“上次核对”，绑定变化后作废。此同步owner检查不代称异步刷新、新代际切换或全局F5。
- `library.detach`优先借用匹配当前head的完整Station字节，再以既有不可变版本和catalog提交规则独立化，保持ID、名称、父级及原来历。只有旧版本驻留时不得倒退head；无匹配时保留原严格读取兼容路径，所有失败保护继续成立。未保存编辑不进入该原始字节缓存。
- Asset列表携带实际内容hash和带绑定范围的来源状态，显式升ABI10，Host、Shell、GUI和验证结构同时对齐。文档／资源独立API版本保持原语义；新命令不通过未登记外部路径直接消费。
- 源码与实际DLL／Host负例覆盖：锁／删原件后命中、重复ensure不增lease、多版本选择、核对不写真源、从RAM独立化及持久化失败、坏version严格拒绝。全部自动化经隐藏入口，保留认领案例及失败证据，不运行真实GUI、安装或发布。

## C2c1 实施与验收（2026-11-07，已完成当前PNG切片）

以上施工契约现已落实到Runtime、公共Shell投影及两套资源UI。它是当前完整PNG载荷的资源闭环，不等于通用文件资源空间、来源App或完整缓存系统已经完成。

### 实际行为与修复

- `asset.ensure`先核对权威catalog当前head，再按资源ID＋内容hash复用Station完整字节；纯RAM命中不回源、不重算内容hash、不分配对象、不递增lease或资产revision。未命中沿用严格加载路径。同参数丢回复重试不重复建立远端引用，lease归零仍释放。严格`asset.open`、固定版本和`source_read`继续核验持久内容，不能拿RAM掩盖损坏的留存版本。
- `asset.check`仅检查指定已加载资源，区分一致、缺失、内容变化、身份变化、旧授权未确认、不可读和被新head取代。状态不修改catalog、授权观察、文档、History、Job或已加载字节。观察绑定资源ID／归属／来源URI／head，独立化或重新绑定后失效，逻辑改名／移动不失效；界面显示“上次核对”。这仍是owner同步IO，不是全局F5、监听或自动采用新代际。
- `external_sources.Catalog.observe`不产生新授权或持久观察写入；legacy、临时、撤销或locator不匹配的mount在IO前拒绝。同一打开对象核对字节和真实文件身份，锁／访问错误归为不可核对并保留实际诊断，不能统称原件缺失。
- `library.detach`优先使用匹配当前head的完整Station原始字节。原件失联时仍能留存并独立化，保留ID、显示名、父级和来历；只有旧A驻留而head已是B时拒绝以A回退。版本写入、catalog锁和revision预检失败保护已有状态；已有坏版本不被RAM自动修复。无匹配RAM时保留原严格来源兼容路径。
- Asset列表增加实际hash及来源观察，ABI显式升10，结构由40增为80字节并验证保留字段／状态范围，旧ABI9拒绝。Runtime中央注册表、Host、Shell及验证结构同时接入新命令；复核补上了中央命令注册测试，避免“dispatcher已实现但真实入口未注册”。
- 两套UI每次显式选择都通过公共`ensureLibrary`核对VM当前head，即使本地投影已有旧handle也不绕过权威检查。新预览成功后再替换旧预览。桌面帧内普通命令仅表示排队，新增同步窄helper处理来源核对及允许的detach／refresh，分别呈现已知执行结果、结果未确认和执行成功后投影失败；不自动重试旧动作。旧detach／refresh仍非C2b受管理CAS／回执接口，完整恢复向导尚未迁入UI。

### 实际验证和证据

证据根：`scratch/verification/c2c1-acceptance-e55b0ef982db/`；最终汇总为`acceptance-summary.json`，同产物命令／逐文件哈希为`sealed-final-summary.json`。

- 最终源码命令：`tools/zig/zig.exe build test-core test install portable library-probe --summary all -j1`。`build-ui-final-2.log`为175/175步骤通过、21/21本次执行测试通过，其余采用有效构建缓存；不将多次构建中重复发现的模块测试相加成唯一测试数。
- 新实际DLL／Host验证为`tools/verify_resident_resources.py`，最终报告`scratch/verification/resident-resources-88c2bc7b0be6/report.json`的8组全通过。覆盖原件独占锁后12次ensure不增lease／revision、内容变化与缺失只作观察、版本／catalog锁与坏版本失败保护、从完整RAM独立化后冷恢复、head B不被旧A降级、同内容不同ID不合并、旧Doc／History／排队Job继续A，以及真实Host丢回复重试和重启后的空Station。
- 最终封存17项headless命令全部通过：驻留资源、资源操作、来源身份、资源版本、assets、同步／异步jobs、Host transport、workspace及RPC、编辑提交、runtime、input、playback、replay、Host、环境隔离。使用实际分发Runtime／Host／Shell／NanoUI组件；没有打开真实GUI窗口。
- portable／bin／runtime／shell／nanoui分别74／30／11／21／13个文件，验证前后hash一致；最终Runtime DLL SHA-256为`8b7d591cfbe53466f15ff0c787d86912f71ab86e6114d1462d1abb9bc1c55fb6`。隐藏进程工具6项、上游固定源码6项及Python语法检查通过；本轮没有更新依赖。最终Cutrans进程为0。
- 初次构建分别有标准库loader `Unexpected`导致6／4／1个编译步骤失败；后续UI helper构建另遇Zir loader与CRT导入库生成`Unexpected`。这些命令整体失败，不能因其中已执行测试通过而称构建通过；原日志全部保留。同源码复验最终通过，但根因仍未定位，本轮未修改工具链、清缓存或更改系统设置，不归因于环境／杀软。故意持锁用例里的`SHARING_VIOLATION`诊断与这些编译器失败分开记录。

自动化通过统一隐藏入口及Zig隐藏共享控制台运行。仅使用认领的合成验证目录；被替换的原对象、锁阻塞物和失败证据保留。本轮没有删除真实用户文件、修改既有安装／授权／凭据或系统注册，没有运行旧卸载器，没有安装或发布。真实GUI／IME、完整安装升级卸载和发布仍未经本片验收；发布须继续使用已验收同一产物并核hash。

### 剩余边界与后续

现有16个Station对象／64MiB及32资源／32文件夹限制保留；没有LRU、异步检查、通用文件／目录provider、可变owned工作正文、新来源App或OS强制沙箱。下一片先将当前素材专用声明与通用资源身份／内容／来源契约分开，再落实受控来源口岸、统一登记交付和可变工作内容与作品固定版本分离，逐步接入独立App。不能以现有PNG的hash／不可变版本政策强套所有文件，也不自动改写或清理旧资源。

## C2c2 实施契约（2026-11-07，施工中，尚非验收）

用户批准推进“只读本地来源→登记通用资源→交付统一引用→消费App接受或拒绝”。本片以TXT、PNG、未知格式及空文件验证，不扩为完整文件浏览App、目录provider、云接入或可变owned正文实现。

- 复用现有完整字节存储／Station机制，普通文件登记不依赖PNG解码，预算暂仍16MiB。Resource API显式升v2，新增register_file候选／提交，保留同Runtime epoch的回执／CAS和丢回复重试；旧客户端拒绝新契约，结构布局及Host ABI10不变。
- 登记默认只读引用；保留稳定ID及原名，资源登记与App消费结果分账。公共Shell交付接收ID＋内容hash，不接受host原路径，失败不删除登记或外部文件，重试交付不重复登记。
- 新来源口岸读取同一打开文件的身份／字节／最终路径，排除context托管根及可识别产品根的链接别名；为拒绝托管文件硬链绕入，新通用入口暂拒多硬链接文件。旧授权／旧作品不自动迁移或扩大授权，不宣称OS级强沙箱。
- 严格固定版本／旧PNG候选政策继续保留；通用工作正文与作品固定版本的分离、全GUI入口、可变owned和细粒度导出事务仍待后续。自动化继续隐藏入口、隔离合成目录、保留失败证据，不启动真实GUI、安装器或发布。

C2c2现已完成当前单文件切片：179/179构建步骤、新实际DLL／Host14组及同产物18项headless命令通过，实施、证据、符号链接未覆盖项及上游远端差异单列于[C2c2通用登记与交付记录](2026-11-07-resource-registration.md)。完整来源App、工作正文和OS强沙箱仍未完成。
