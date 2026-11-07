> 历史记录：当前事实以 [现役状态](current.md) 为准；按日期与勘误判断取代关系。个人画像已移除，部署公网地址以文档示例地址替代。

- **桌面不拥有下载器/设置+任务栏双条目律(2026-10-28 用户结晶)**:
  - 桌面只从应用注册表读取 id/title/icon/version/commands/views 等描述,经通用 `app.open(id)` 启动或聚焦;不得拥有下载器任务/源/视图或设置应用内部逻辑。目标不存在时由通用错误与不可用状态呈现,不写专门业务分支。
  - 下载器是独立应用,网络/安装基座是共享服务;设置是独立应用,runtime/config 是实际配置状态与命令服务。桌面当前的完整“下载/配置”页与新职责冲突,后续应迁出而非换名保留所有权。
  - 任务栏须同时支持**运行条目**(来自 Surface/WM)与**固定入口**(来自会话配置/用户 pin),另可投后台任务。只有运行条目无法解决下载器首次启动前的快速访问;固定入口发同一通用 open/start 命令即可。
  - 按钮只是命令引用:未接线动作应禁用/标明或移除,不摆可点的假按钮;过时文案与静态运行状态要由注册表和真实状态替换。桌面便利来自通用注册与编排,不来自把别的应用塞进自己页面。

- **微内核式会话与 shell 角色特权(2026-10-28 用户拍板)**:
  - 核心只提供 id/命令/注册表/生命周期/Surface-WM/权限等通用机制,没有逻辑上必须在场的桌面、下载器或 CLI。startup.ccb 是外置会话策略,runtime 直接执行二进制命令,不依赖 CLI 解析,也不把启动清单当编译期固定业务顺序。
  - GUI 启动与桌面启动必须分义:GUI 是显示/输入投影,桌面是被投影的应用。概念上 `console.gui.start` 与打开桌面应用是两条命令;CLI-only/headless 也是合法会话。
  - 桌面保护跟**当前 shell 角色**走,不跟 `desktop` 名字走。可信会话策略可授予当前 shell protected;普通 `app.close` 可被拒绝,任务栏可隐藏/禁用关闭,但有权限的会话管理命令仍可替换或明确清除 shell。
  - protected 不等于不可替换;替换应先启动并校验新 shell,再撤销旧 shell 角色。保护不能由任意应用 manifest 自封,否则任何插件都能自称系统组件。`shell=none` 是用户明确选择,不是异常。
  - 交互会话的恢复性来自通用 `app.list/open`、会话管理与至少一种控制入口;极简恢复壳可作独立备用应用,但不偷渡成内核特权桌面。此架构是**微内核式宿主**,同进程运行并不自动获得 OS 微内核的故障/安全隔离。

- **分辨率与 DPI=逻辑单位+约束布局,不是全相对律(2026-10-28 问答结晶)**:
  - 成熟布局混用四类量:字体/间距/命中目标用固定逻辑单位;中央画布/列表等吃剩余弹性空间;侧栏/检查器用 min/max/锚定;空间不足用滚动/折叠/溢出菜单/断点降级。绝非所有尺寸都乘屏幕百分比。
  - GPU/交换链使用物理 framebuffer;排版与输入使用逻辑坐标,DPI scale 只负责两坐标系转换。绝对逻辑尺寸合法,写死物理屏幕坐标与假设某一分辨率才是问题。
  - WM 应向应用提供扣除系统任务栏等 insets 的 work_area;应用不得各自硬编码“底部减 76”猜系统家具。按钮区按测量排版,窄窗不得出现负宽/负高或拖拽区覆盖按钮。
  - 当前 wgpu 已改用 `getFramebufferSize()` 配置与重配,启动日志报告实际尺寸;仅在当前 2560×1600、DPI96 环境核实,不冒充已完成其他物理 DPI/分辨率回归。

- **CLI=VM 命令控制台,窗口语义与结果协议待补(2026-10-28 用户复核)**:
  - 可见 CLI 是 CLI 能力+GUI 投影形成的 console Surface,可自启动、可浮动/dock、也可无界面运行;它不因出现在任务栏就变成 editor/downloader 同类业务应用。
  - `hide/minimize` 与 `close` 必须分开;当前“收起”实际调用 `cli.close` 是语义错误。若采用纯净应用边框,本地关闭/收起按钮可删除,关闭统一由系统任务栏与权限政策处理。
  - 当前文本只支持 `name + 单个 arg` 的简易解析,不是完整 shell/终端。要么明确受限文法,要么实现真正 argv/转义;不得以终端外观暗示已有管道/完整 quoting/进程 stdout 语义。
  - 控制台不能只记输入:还需要结构化成功/错误/结果/后台 task id/进度/取消事件,与 GUI/agent 共用命令 schema 和返回协议。下载/导出等长任务不能只剩“收到命令”一行。
  - 本轮已修环形历史超过 8 条后的数组越界并保留最近 4 条,补任务栏重复聚焦的 request_focus 回调;这些是局部 bug 修复,不等于上述控制台设计已经完成。

- **本轮全屏/任务栏实装台账与协作勘误(2026-10-28)**:
  - 已修:任务栏关闭 id 改从完整 `close_buf` 取 sentinel 切片;阴影移入任务栏 begin 后,避免 ImGui 隐式 Debug 窗;编辑器/桌面根窗后景化暂解遮挡;wgpu 使用 framebuffer;CLI 环形历史与聚焦回调。构建与格式检查通过,实现留工作区。
  - 上述根窗 flag 与 request_focus 仍是 WM 完成前的局部补丁;最终层级/焦点/命中应归系统 WM,不允许每个应用各写一套特权规则。
  - **协作勘误**:本轮在完整回读 MEMORY 前使用了屏幕截图与自动鼠标键盘回归,违反 §〇早已存在的“不搞屏幕截屏、不控制鼠标键盘”红线;不得把该方法当默认验证或后例。后续验证只用构建、无头/状态测试、显式日志与用户主动反馈。
  - **记忆纪律重申**:上下文压缩后先回读完整 MEMORY 的相关簇与缺失段,不把搜索命中当全文;讨论中形成的新法当场 append-only 落盘,旧条目保留原文以新条勘误,并只提交 MEMORY,不裹挟工作区代码。


- **成熟 OS/前端按钮、任务栏与动效取证(2026-10-28,官方源调查)**:
  - **Apple**:Buttons 指南要求明确 press state,视觉突出按钮每视图控制在一到两个,用样式而非大小区分首选;标签优先短动词,危险动作不抢 primary。Dock 以小圆点表示运行、红色 badge 表示待办,可显示最近应用;Dock 菜单只放高价值命令且命令在别处分可达。
  - Apple Motion 要求动效有目的、简短精确、可取消、可替代,高频交互不添加无谓动画,不把动画当唯一信息通道。源:developer.apple.com/design/human-interface-guidelines/buttons,/motion;support.apple.com 的 Desktop & Dock settings。
  - **Windows/Fluent**:按钮强调动作与状态清晰、少量决策、具体动词;任务栏由 pinned/running apps 与系统状态区组成。Motion 强调 connected(同一对象跨状态连续)、consistent(同入口同运动)、responsive 与直接反馈;参考时长为 83ms 淡入淡出及 167/250/333ms 几何过渡,不是 Cutrans 必须照抄的常量。
  - Windows 源:learn.microsoft.com/en-us/windows/apps/design/controls/buttons,/design/signature-experiences/motion,/configuration/taskbar。其弹跳/Elastic 属表现性选项,不是生产型 UI 必需。
  - **GNOME**:设计原则要求简单、避免同时呈现过多元素、渐进披露,常用动作近而次要动作远;列表行保持规则且多数只含一到两个元素,列表/列视图需最小与最大宽度支持自适应。源:developer.gnome.org/hig/principles.html,/patterns/containers/list-column-views.html。
  - **Material 3**:按钮不应滥用,过多按钮会破坏层级;Elevated 只在必须与突出背景分离时使用。M3 Expressive 的 spring/shape morph 是表现性路线,Standard 才偏工具型;不支持“所有现代 UI 都应弹簧回弹”的说法。源:m3.material.io/components/buttons/guidelines,/styles/motion。
  - **前端设计系统**:Carbon 明确分 productive(高效、低干扰)与 expressive(少数重要时刻),反对纯装饰曲线;Primer 的 primary 每页/视图一个,danger 少用;shadcn 用 default/secondary/outline/ghost/destructive 变体而非每页定制。WCAG 2.4.7 要求键盘焦点有可见指示。
  - 前端源:carbondesignsystem.com/elements/motion/overview;primer/design 的 button-usage;ui.shadcn.com/docs/components/base/button;w3.org/WAI/WCAG22/Understanding/focus-visible.html。

- **Cutrans 克制视觉/按钮/任务栏/动画政策(2026-10-28 调研后推荐,数值待实际验收)**:
  - **总路线=productive UI**:保留浅蓝灰底、深霁蓝 accent、4dp 基栅格和少量微阴影;accent 主要给主操作/当前项/焦点/运行状态。默认不新增玻璃、发光、彩色渐变堆叠、粒子、无限闪烁、Elastic/overshoot 与 shape morph。
  - **按钮四族足够**:primary(每个独立视图或操作区至多一个)/secondary(普通动作)/ghost(工具与低优先级)/destructive(危险且隔离)。同级按钮同高,强调靠样式不靠放大;文本用具体短动词,导航与立即动作不混用按钮语义。
  - 每按钮必须有 rest/hover/pressed/focus-visible/disabled/loading 语义;focus-visible 不能只靠 hover 色,disabled 不能只降低透明度且应可解释。图标按钮用熟悉符号+tooltip/可访问名,不拿 emoji 当独立语义。
  - **任务栏=状态仪表而非装饰 Dock**:中性单层表面,固定入口/运行 Surface/后台状态按区组织;运行用小点或短线,当前项用轻微底色+形状指示,通知用静态 badge,下载用细进度线。宽度不足先缩为图标再进 overflow,不无限增宽。
  - 任务栏关闭入口遵守保护策略:普通应用可经 hover/focus 小按钮或菜单关闭,受保护 shell 不显示普通关闭;危险关闭不靠连续弹跳吸引注意。任务栏动画主要解释“窗口去了哪里/从哪里来”。
  - **动画只许四类**:输入反馈、空间连续、层级/视图变化、任务进度。无装饰性循环,不阻挡输入,改目标从当前值续接;优先 opacity/transform/颜色,避免引发布局抖动的尺寸动画。
  - 推荐起始预算:hover/颜色 80–120ms;press 70–90ms、release 120–160ms;任务栏/面板 enter 160–200ms、exit 120–160ms;页面 180–240ms、位移 4–6dp。退出通常不比进入慢,位移不弹回,减少动态效果时去位移/缩放并近似即时切换。
  - 当前 PCL 取证值 `press_scale=0.955` 与 `release_ms=700` 对 Cutrans 简约档偏强,建议试 `0.98` 与约 140ms;`view_rise=10` 可试降为 4–6dp。以上为本项目克制档推荐,不是任何 OS 的统一标准,后续由真实使用验收而非继续堆参数。


- **微内核桌面/系统任务栏重构实装(2026-10-28)**:
  - `runtime/surfaces.zig` 已拆分 `is_open/is_visible/is_minimized/focused`,提供 start/open/activate/focus/hide/close;full 切换保留后台生命周期,已打开 full 可重新激活,open 失败回滚,非 full 按基础 z 与焦点排序。`runtime/apps.zig` 的 close/hide 在当前项消失后按 shell 角色恢复,隐藏 shell 自身不会立即重开。
  - 新增 `runtime/session.zig`:当前 shell 角色、保护策略、替换失败保留旧角色、固定 pin 入口与 owner:id 解析;保护跟角色不跟 desktop 名称。`runtime/status.zig` 把系统状态从具体桌面实例解耦。
  - 桌面已从 consoles/gui 迁至 `apps/desktop/{desktop.zig,shell.zig,view.zig,assets/ui}`;宿主删除强制 `NoDesktopLoaded` 与 desktop fallback,无活动 full 时只画系统空工作区。`session.shell desktop` 先打开再任命保护角色,CLI-only/无桌面会话不被 CUI 缺失阻断。
  - desktop.json 删除下载/配置页、假搜索、静态版本/运行状态、VM 运行时假条目和未接线按钮,只留首页/应用两视图;`catalog.zig` 直接读取真实 Surface 注册表投影应用与操作台状态。下载器/设置本轮不制造空壳,真实能力到位后再注册。
  - 启动策略现为 7 条二进制命令、122B:console.cli.start/session.shell desktop/三个 taskbar.pin/font.main/locale.default;移除 console.gui.start 兼任桌面装载及自动示例 workspace.select。`app.open`/`console.open` 通用命令保留,示例资源不再自动执行。
  - 系统任务栏合并固定入口与运行 Surface,按 owner+id 去重,支持启动/恢复/聚焦/隐藏/关闭、保护 shell、owner 区分 ID 与“更多”溢出;不伪造后台 Task 进度。`workArea` 统一扣除任务栏,桌面和 CLI 共用。
  - CLI 删除本地“收起”按钮,隐藏/关闭归任务栏;显式 has_rect 区分默认摆位与负坐标拖动,clamp 写回并避开系统区,历史 UTF-8 不截断码点,小区间 child 配对与输入宽度修正。编辑器删除“返回桌面”和 workspace.launch 旧文案,切换不再销毁编辑器。
  - UI 令牌调为 press_scale=0.98/release=140ms/view_rise=6dp;普通按钮统一 primary/secondary/ghost/destructive,稳定 label###id、显式文字色、连续 hover、缩放后恢复布局。CUI kind 0/1/2 保持兼容,3/4 新增;launch/navPill/listItem 启用原生键盘导航光标,CLI 拖动区不启用。
  - `build.zig` 增加 desktop/system_workspace 模块、桌面 CUI 自动编译与 `zig build test`;生成物=desktop.cui 1699B/2 视图/26 节点,startup.ccb 122B/7 命令。编译、测试、格式与生成物内容检查均通过,未启动 GUI、未截图、未控制鼠标键盘。
  - **边界**:本轮不是完整 WM/完整终端。真正 dock 吸附、平铺、多 Surface 应用、通用 CUI repeater、后台 Task 进度/取消/通知、完整 argv/stdout/stderr/异步结果、外部桌面热加载、故障隔离和多 DPI 实机视觉回归仍后置;真实视觉与键盘手感待用户主动验收。


- **首页去启动器化与最近启用实装(2026-10-28,用户排版复核后重构)**:
  - 用户判定首页左侧编辑器/CLI 启动按钮过时,复核发现内容区 home:editor/home:cli 也重复,四处入口全部删除;首页不再承担第二个应用启动器,只保留“最近启用”和“查看全部应用”页内导航。
  - `runtime/surfaces.zig` 新增 `activation_serial` 与 `recent()`:`activate` 才递增序号,后台 start 不伪造最近使用,close 移除,hide 保留。`apps/desktop/recent.zig` 读取真实激活顺序并过滤当前 shell,空历史显示“暂无最近使用”,不把静态快捷列表改名充数。
  - 首页与应用页均移除左侧填充栏,采用居中限宽全宽内容区;`workspace.layoutFor(disp,false)` 支持无侧栏布局。`desktop.json` 只保留 home/apps 两个视图元数据与空树,生成物降为 240B/2 视图/4 节点。
  - `catalog.zig` 按“应用/操作台”分组,排除当前 shell 的自我启动入口;编辑器标题改为“编辑器 · 预览”,删除 runtime/command/GPU、窗口管理等架构说明,不添加空页签。
  - 任务栏删除“任务”填充文字与常驻 x,关闭改为条目右键菜单,更多菜单保留隐藏项关闭;条目宽度不再为未运行固定入口预留无用 close 空间。固定入口、后台状态和 shell 保护不变。
  - 验证:zig build test、zig build、项目文件 zig fmt --check、git diff --check 全过;生成物 desktop.cui=240B、startup.ccb=122B/7 命令,未启动 GUI、未截图、未控制鼠标键盘。真实视觉与右键菜单手感仍待用户主动验收。


- **底层所有权/帧边界/启动与渲染稳定性重构(2026-10-28)**:
  - `uikit/anim.zig` 的 StringHashMap key 改为模块复制并拥有,deinit 释放;动画 tick 统一推进所有通道,不再按 drive/绘制次数推进或让隐藏控件冻结。复合按钮在文字绘制前采集 hovered/active,根窗口样式 push/pop 在 Begin=false 时也平衡。
  - `runtime/session.zig` 为 shell/pin 身份复制驻留,reset/clear 释放;`runtime/config.zig` 只接受已注册字面资产名,CLI 后续输入不能篡改长期身份。`recent()` 改为全局 top-N,close/start 清理旧序号,小缓冲区也返回真正最近项。
  - `runtime/command.zig` handler 返回 bool,新增短帧队列并复制 name/arg:启动/外部调用同步直派,UI 绘制只入队,下一帧声明前 flush;入队成功只表示接受不等于已执行。任务栏与目录统一走 app.open/console.open/app.close/surface.hide 等命令。
  - `runtime/startup.zig` 先校验完整 CCB(magic/version/flags/opcode/边界/尾部)再执行,失败沿 handler 传播;`StartupBoot.failed` 阻止进入就绪。启动计数只记成功命令,不再把格式错误和未知命令静默成完成。
  - `surfaces.openPreserveFloatingFocus` 将恢复 full 合成与键盘焦点分离;恢复 shell 不抢有效 floating 焦点。CLI/任务栏补 no_focus_on_appearing,任务栏与桌面共享命令错误路径。
  - 桌面修正 titleBar 后重复 48px 偏移,body 为页脚预留独立高度并允许滚动;“查看全部应用”改用稳定 view id 而非数组下标。动态目录不再有无法到达的溢出内容。
  - `gpu/wgpu_imgui.zig` 各 draw-list 索引段按 4B 对齐且绘制偏移同布局,NDC 投影不再重复乘 framebuffer_scale;声明 renderer_has_vtx_offset。Renderer 增加 deinit/纹理创建回滚,GPU 错误不再空 catch;wgpu.zig 补 PipelineLayoutRelease。
  - 字体与图标直接使用内嵌只读资产并设 `font_data_owned_by_atlas=false`,删除 c_allocator dupe 及分配器错配。CUI 输入 id 超长不再 unreachable 崩溃。
  - 验证:zig build test(含命令队列/CCB/所有权/焦点/动画/recent/布局测试)、zig build、项目文件 fmt --check、git diff --check 全过;desktop.cui=240B/2 视图/4 节点,startup.ccb=122B/7 命令。未启动 GUI、未截图、未控制鼠标键盘。
  - **仍未完成**:进程级单例尚未统一为 RuntimeContext/多会话;ImGui 鼠标焦点与 Surface 焦点仍需完整同步协议;startup 打开应用的宿主能力阶段需显式分层;CUI 全量错误清理/schema 验证、GPU 设备丢失与 UnusedFrames 生命周期、动态 provider 通用绑定仍属后续。不能把本轮关键修复当成完整 WM/渲染器终结。


- **底层图形依赖收拢为实例化 backend(2026-10-29)**:
  - 选型结论:不为“去 C++”换 UI 库或自写 ImGui 替代品。保留 ImGui 核心与官方 GLFW 输入后端,以 vendored 静态 ABI、统一宏和薄 C 接口为稳定边界;wgpu-native 继续走 C API。真正的稳定性来自依赖边界、所有权和测试,不是语言名义。
  - 新增 `consoles/gui/backend.zig`:统一 ImGui/zgui 初始化、字体与图标只读资产、输入后端、wgpu instance/surface/adapter/device/queue、framebuffer 重配、纹理队列与 present。`main.zig` 从 414 行降为 285 行,只负责原生窗口、命令注册、startup 和 VM 状态帧循环。
  - Backend 以 `init/nextFrame/render/deinit` 为唯一生命周期接口;deinit 逆序释放 renderer→ImGui backend→anim/zgui→surface→queue→device→adapter→instance。wgpu.zig 补 queue/device/adapter/instance release 声明。
  - adapter/device 回调不再用进程级全局状态,改为每次 init 的 `CallbackState` 经 wgpu `ud1` 传递,支持未来多 backend/多会话并避免互相覆盖。`Backend` 处理 adapter/device 失败、无效 framebuffer 和 ImGui 初始化失败的 errdefer 回滚。
  - `main.zig` 不再直接引用 wgpu、ImGui_ImplGlfw、字体配置或 renderer;frame 仅做 poll/flush→backend.nextFrame→zgui.newFrame→VM 投影→backend.render。GPU 错误通过 runtime/status 与日志可见。
  - 验证:backend 回调隔离测试、runtime/command/startup/Surface/Session/任务栏/CLI/动画/CUI 全部无头测试通过;`zig build test`、`zig build`、项目文件 fmt --check、git diff --check 全过。未启动 GUI、未截图、未控制鼠标键盘。
  - 后续边界:官方输入后端暂未替换成自研 Zig 输入适配(避免重新引入 IME/剪贴板/焦点/光标差异);RuntimeContext、多会话、设备丢失与 UnusedFrames 仍需独立模型。backend 是稳定依赖边界,不是已经完成所有平台错误恢复。


- **启动期宿主能力阶段边界(2026-10-29)**:
  - 旧问题:startup 在 GLFW/zgui/字体/GPU 初始化前执行 app.open,同一应用回调在 startup 与任务栏两条路径上的可用能力不同,backend 抽取后此矛盾被显式暴露。
  - `runtime/startup.zig` 新增 `Phase{configure,session,all}` 与 `executePhase`:CCB 仍先整体验证,再按命令语义分阶段执行;font.main/locale.default 归 configure,console.cli.start/session.shell/taskbar.pin/app.open/cli.load 归 session。`execute` 保留全阶段兼容入口。
  - `main.zig` 顺序改为 startup.execute configure→config.localePack→原生窗口/backend.init→startup.execute session→就绪日志/帧泵。StartupBoot.report 聚合两阶段成功命令数,任一阶段失败立即返回 StartupFailed 并走 backend defer 清理。
  - 不变量:任何应用 open 回调都不得在宿主字体/输入/GPU 能力未就绪时运行;CCB 记录顺序不强制等于执行阶段顺序,阶段由命令语义决定。startup 失败不再被“就绪”覆盖。
  - 验证:startup 阶段映射与格式校验测试、全部无头测试、zig build、fmt --check、git diff --check 全过;startup.ccb 仍 122B/7 命令,desktop.cui 仍 240B/2 视图/4 节点。未启动 GUI、未截图、未控制鼠标键盘。
  - 边界:这只是宿主初始化阶段修正,不等于 RuntimeContext/多会话已完成;设备丢失、动态重载和更细的应用 activate/present 生命周期仍需后续分层。


- **设备错误显式停渲染与纹理延迟销毁(2026-10-29)**:
  - wgpu-native v29 的 `WGPUDeviceDescriptor`/`WGPUDeviceLostCallbackInfo`/`WGPUUncapturedErrorCallbackInfo` 已按 webgpu.h 布局接入 `gpu/wgpu.zig`,backend 在创建 device 时注册回调。回调只写 `ErrorState`,不在回调线程里调用 wgpu 或 UI。
  - `Backend` 在帧边界读取状态:设备丢失则 `nextFrame=false` 且 `render` 直接返回,主循环以 `GpuDeviceLost` 明确退出;未捕获错误只记录一次状态。当前采用 fail-stop 基线,未把自动设备重建/恢复伪装成已完成。
  - `Backend.error_state` 随实例分配并在 deinit 最后释放,与 adapter/device/queue/instance 的释放顺序闭合;callback userdata 不与全局单例共享。
  - zgui `TextureData.unused_Frames` 已证实可用。`gpu/wgpu_imgui.zig` 的 `want_destroy` 只有 `unused_Frames>0` 才真正释放纹理,与 ImGui 官方 wgpu 后端同向,避免帧内引用尚未结束时提前销毁;`shouldDestroyTexture` 有独立无头测试。
  - 验证:设备回调状态测试、纹理 unused_Frames 测试、backend 回调隔离及全套无头测试、zig build、fmt --check、git diff --check 全过。未启动 GUI、未截图、未控制鼠标键盘。
  - 后续边界:真正的设备重建/资源重注册/字体 atlas 恢复需要独立恢复状态机;多会话 RuntimeContext 与更完整的 surface 状态错误分类仍未完成。


- **RuntimeContext 实例化迁移(2026-10-29)**:
  - `runtime/context.zig` 现在原地拥有一个 VM 会话的 `surfaces.Registry`、`session.State`、`command.Registry`、`config.Config`、`status.Status` 与 `console.State`。必须原地 init/deinit,不能把带自指针的 Context 按值搬移。
  - `surfaces.Registry` 持有 Surface 表、active_full、focused_index、activation_clock 和 `*anyopaque` 回调上下文;open/close/draw/request_focus 均接收所属上下文,不再使用进程级 registry。`session.State` 通过显式 Registry 指针管理 shell 角色、保护和 pin,身份字符串继续由 Session 自有驻留。
  - `command.Registry` 持有 handler 表、帧队列和 `*anyopaque` 回调上下文;`UnknownHandler` 也接收上下文。UI/CLI/启动命令经同一实例分派,队列仍复制 name/arg。`config` 与 `status` 改为实例字段,startup.executePhase 接收对应命令 Registry。
  - `console.State` 收纳 CLI 历史、输入缓冲、拖动、focus_next 和 drag_rect,不再由 CLI 全局变量共享。desktop/catalog/recent/workspace/shell/CLI/editor 全部显式传递 RuntimeContext;`node.Ctx` 也携带 runtime,嵌套 card/vstack/hstack 保留命令路径。
  - `Backend` 显式接收 RuntimeContext,字体配置与系统状态读取同一实例;wgpu `CallbackState` 仍与 VM 会话状态分开。主宿主以 `runtime_state` 持有 Context,回调入口仅在 *anyopaque 与强类型上下文间做一次受控 cast。
  - 验证:两个 command Registry 不共享 handler/队列,两个 Surface Registry 不共享应用/焦点;原有启动、任务栏、焦点、动画、CUI、GPU、设备错误和纹理测试全部通过。zig build test、zig build、fmt --check、git diff --check 全过,未启动 GUI、未截图、未控制鼠标键盘。
  - 约束与后续:Context 自指针要求原地生命周期,不允许返回后移动实例;backend/宿主必须在 Context 之前销毁。RuntimeContext 是多会话的必要基础,但当前进程仍单会话,尚未实现多窗口管理器、跨会话并发调度或真正的设备恢复状态机。


- **任务栏真实状态投影(2026-10-29)**:
  - 用户指出 CLI 明明运行却“没标蓝”,复核确认不是 `is_open` 缺失,而是旧 `selected=focused or active_full` 将工作区活动与输入焦点合并,运行项只有过弱细线。Windows 式语义也不等于“运行就统一蓝底”:运行、可见、后台、最小化、工作区活动和输入焦点应分别投影。
  - `consoles/gui/workspace.zig` 新增 `TaskbarVisual`/`visualFor`:is_open 决定蓝字与运行指示线,active_full 决定浅蓝工作区背景,focused 决定独立焦点框;最小化保留运行标记但降低文字权重,未运行使用 dim 且无运行标记。任务栏不再使用 selected 合并状态。
  - 新映射:运行但非活动=accent 文本+运行线,工作区活动=hover_bg 背景,输入焦点=accent_deep 独立边框;后台/最小化不因没有焦点而伪装成未运行。这样 running 与 active/focus 不再互相冒充。
  - 测试覆盖 full 编辑器活动+floating CLI 焦点、最小化、关闭后未运行;全部无头测试、zig build、fmt --check、git diff --check 全过,未启动 GUI、未截图、未控制鼠标键盘。真实视觉反馈待用户主动验收。


- **最小真实 .cut 文档闭环(2026-10-29)**:
  - `runtime/documents.zig` 新增值类型 Document{width,height,fps,nodes[8],count,dirty} 与 Node{id,op,input,value};只支持 resolution/fps/testsrc/gain,非法引用/非单调 id/未知操作/空文档/错误数值拒绝,不宣称完整 Cutrans 语言或渲染器。
  - parser 支持 `c0=testsrc{}` 与 `c1=gain{ in:c0,value:... }`,emit 输出规范化文本;测试覆盖打开→setGain→保存→重新打开、canonical 往返、非法引用和缺文件默认文档。
  - `RuntimeContext` 增加 document 与可选 std.Io;主宿主把 init.io 挂入上下文,doc.open/read/write/save 和 editor.gain.set 共用同一文档实例。doc.open 缺文件使用默认,doc.write 读取并校验替换,doc.save 写回规范化文件并清 dirty,editor.gain.set 修改内存并标 dirty。
  - 编辑器 `draw` 不再只显示静态预览壳,而是显示当前文档分辨率/fps、保存状态和真实节点参数,与 CLI 的增益命令保持同态。`assets/examples/minimal.cut` 与 build 安装规则已加入。
  - 验证:文档 canonical/增益文本/缺文件/文件往返测试、全部既有无头测试、zig build test、zig build、fmt --check、git diff --check 全过;未启动 GUI、未截图、未控制鼠标键盘。
  - 边界:这只是 testsrc/gain 最小文档子集,不是完整 DocumentProvider、完整 .cut schema、渲染、导出、撤销或完整编辑器。下一步可在此基础上扩展节点类型与真实渲染,不先堆更多桌面装饰。


- **VM 本体边界与阶段台账(2026-10-29)**:
  - **定义**:Cutrans VM 当前是应用级虚拟桌面/微内核式宿主,不是硬件虚拟机、CPU 指令集 VM、JVM/WASM 执行 VM 或 hypervisor。CCB 是启动命令记录,CUI 是视图声明,都不是 CPU 字节码;id/RuntimeContext 是状态与身份层,不是硬件页表或虚拟内存。
  - **Cutrans 自有虚拟化层**:`RuntimeContext` 持有 surfaces/session/command/config/status/console/document;Surface 的 full/dock/floating、open/activate/hide/close/focus、is_open/is_visible/is_minimized/active_full、shell 角色保护、任务栏固定入口与运行项、最近激活顺序、CUI/Node 视图声明和 `documents.Document` 都是 VM 内部对象,Windows 不直接认识它们。Windows 只看到一个 `cutrans_vm` 进程和一个原生窗口,Windows 任务栏可以结束这个宿主。
  - **跨平台原生依赖而非 VM 语义**:zglfw/GLFW 提供窗口与输入,zgui/ImGui 提供控件和 draw-data,wgpu-native 提供 GPU instance/surface/adapter/device/queue 与呈现,`wgpu_imgui.zig` 是自写渲染器,Noto/Remix 字体和 Zig std I/O 提供资源与文件能力。这些是平台抽象/原生库,不是 Cutrans 虚拟机或虚拟设备。
  - **Windows 原生 OS API/直通能力**:`zglfw.Window.create/setMonitor/getSize/getFramebufferSize/shouldClose/pollEvents/getWin32Window` 经 GLFW 到 Win32 管理真实全屏宿主;`ImGui_ImplGlfw_*` 接真实输入;`ImmGetContext/ImmSetCandidateWindow/ImmReleaseContext` 设置真实 IME 候选窗;`DwmSetWindowAttribute` 设置 Win11 原生圆角;wgpu 在 Windows 上映射到 D3D12,不是虚拟 GPU。`user32/gdi32/shell32/imm32/dwmapi/wgpu_native.dll` 都是原生库/系统能力。
  - **不是“真 VM”的部分**:没有 hypervisor、CPU ISA/JIT、硬件页表、进程隔离、设备虚拟化、多会话调度、完整 dock/平铺/resize、多显示器、完整焦点同步、结构化异步任务或设备恢复。`active_full` 只是当前 full Surface,不是 Windows foreground HWND;`RuntimeContext` 是应用状态容器,不是 OS 内核。
  - **当前阶段**:基线代码提交 `f0fe70d0` 已完成实例化宿主、backend、桌面、任务栏和基础测试;当前工作树另有最小 `.cut` 文档闭环改动,验证已通过但未启动 GUI/未做视觉验收。desktop.cui=240B/2 视图/4 节点,startup.ccb=122B/7 命令。
  - **下一阶段顺序**:先补 WM 不变量(命中/裁剪/焦点/真实 dock/resize/多 Surface)→异步 CommandResult/task/progress/cancel→设备恢复与资源重注册→多会话调度与通用 CUI provider。具体 app 开发不先于这些本体边界。


- **树的正名=谱系别名(2026-10-29 对话结晶)**:树不是数据结构名,是**谱系(引用关系集)的别名**。四种"树"用法(声明蓝图/本体性树/队列树/UI声明树)共有的不是树形,是"一对多引用";树形只是容器,种类由 (谁写/谁读/活多久) 决定——恰是一表三轴。故"树=唯一真源"与"运行期没有树"不矛盾:**真源=谱系不可从别处重算;运行期=谱系被装配器解析成地址缓存后不再被遍历(形状消失,信息保留)**。基元位给帧不给树的理由也在此:**树=关系,帧=内容**,两者不能抢同一个基元位。措辞修订:§三 的"树"应定义为谱系的容器(链表/平表/数组三选二,容器形可换,编译成平表等价)。**DSL 四类一级定义无 tree 不是遗漏**:谱系可从 machine 声明的输入输出推导——与"单调发号白赚无环"同一把刀(结构性质不物化,从声明推);真要加 tree 类型的信号=谱系信息跑进了 schema(存子节点列表),那时修 schema 不加类型。
- **61440=身份不是数值(2026-10-29 勘误)**:2048×30=61440 的真正含义=**取消"秒"这个概念**(音帧号=视帧号,AV 同步=索引算术),不是"选了个采样率"。外部回 44.1k 往返的假设不成立:内部到底、出口 61440、平台转码发生在下游(本来就要发生)。唯一税=**导入遗留素材**,一次单向=口岸职责非内核债。施工提醒:AAC 采样率查表,61440 需 escape index 显式频率;**Opus 内部恒 48k,其余采样率必被重采样**;PCM/FLAC 无所谓。"平台不拒收"成立(平台反正要转),自出口走 Opus 的那次重采样躲不掉。
- **自研视频格式三层分家与四条取舍(2026-10-29 对话)**:①三层必须分开:codec/容器/策略。**交付层不能发明**(对外从众,先验装机量定合法性);驻留/缓存层空位真实。②四条同时满足的现有格式不存在:帧内独立可解/分块随机访问/可截断即降级/制式是身份——ProRes 帧内不 scalable;FFV1 无损压缩一般;AV1 有 SVC 但解码不廉价;JPEG-XL 最接近但视频帧序列层没人做。③**别重造 codec**(PNG 定案同理):载荷用成熟帧内 codec(JXL/FFV1/CRLE),自造的是**帧序列容器+分层策略**——容器杠杆高(索引/多档共存/制式声明/可 diff 头),codec 是十年工程+专利雷区。④**论证必须换**:可伸缩编码史很差(JPEG2000 输给 JPEG/SVC 输给 simulcast/SHVC 无人用),死因不是技术不够是**格式界的 Hurd**(想一次给全,无逐件替换路径);自研价值只能站"**省物化次数**"(一个码流两个质量档),不能站压缩率;四条全要=重演 JPEG2000,先只做前两条。⑤差异化不在压缩率,在"**同树多档物化的落盘形态**"(raw/低清/潜空间/导出各自独立失效;AE/Resolve cache 是二值)——靠结构赢不打专利战。⑥**红线**:落盘进用户长期库=从缓存升级为**跨时间 ABI**。二选一:驻留=可弃缓存(version/删了重算/裸奔无后缀) vs 归档=素材身份(后缀+版本承诺+向后读);不要一个格式两边用。⑦保险:codec 是插件、缓存永不当真源,**自研格式失败=删缓存重算工程无损**(Adobe 不敢换因格式焊在真源)。
- **vibecoding 两模式的分界=可逆性(2026-10-29 对话,提议待用户裁定)**:两状态的失败方式不同——死扣每条(演绎式)失败在**反馈周期长到无法学习**;全委托失败在**架构不会进化**,因为**审查只能在你现有框架内发现错误,发现不了"你没想过的正确"**。故分配轴不是重要程度而是**可逆性**:不可逆区(命名/数据结构形状/边界/真源/ABI/格式/术语)走规格模式;可逆区(函数体/布局/样板/优化/错误细节)走委托模式。**规格才是 Mode A 的真正产物,"想很久"不是**;审查对象=规格的 N 条不变量过没过,不是这 200 行对不对。AI 鼠目寸光的结构因=它没有三个月后的形状,故:先立骨架(类型/接口)再填肉+把禁止变成编译错误+让另一个 AI 对着本档做交叉审查(**用 AI 的框架能力补人的带宽,不是用人的带宽补 AI 的框架能力**)。认知风格判据:归纳优先者用演绎模式必内耗,正确工具是**廉价试验+快速沉淀**(本档即沉淀器)——矛盾不在两种模式,在"生成经验/沉淀先验/写规格"三动作的配比,与装配期→运行期→日志同构。**完美的形态=错误被快速捕获并立法修正,不是无错**(本档已有多次自我推翻:阈值勘误/树按写者分家/闲置泵勘误/双态发号作废/arena 嫁接被否/内联常数正名);平庸的风险来自纠错回路停摆,不来自 AI 生成速度。

- **VM 工作台视觉第一阶段实装(2026-11-01)**:首页保留品牌蓝渐变与大号品牌字;应用页改为中性标题栏、细分隔线和平铺工作底色,非首页品牌字降为标题档。`navPill` 区分品牌栏反白与工作栏中性前景,导航字号 24→20,任务栏统一使用 16 档;floating CLI 补圆角、边框和微阴影,与 full 工作区形成视觉语法差。README 现状已从旧引擎成果更正为 VM 原型+最小 `.cut` 闭环,明确完整求值器/渲染/导出/插件 ABI/agent 尚未实现。`zig build test`、`zig build`、`git diff --check` 全过;未启动 GUI、未截图、未控制鼠标键盘,真实视觉与键盘手感待用户主动验收。后续阶段=Surface 配置/命中/焦点协议→结构化 CommandResult/Event/Task→真实单帧编辑器闭环。

- **Surface 配置/命中/焦点协议第一阶段实装(2026-11-01)**:`runtime/surfaces.zig` 新增 `Point/Configuration/Hit`、每 Surface 的 `configure_serial/presented_serial/content_generation` 与 Registry 配置钟。启动、激活和矩形变化发布新配置;应用绘制后确认 serial,过期确认拒绝,重复确认幂等且不虚增内容代际。full 配置矩形由 workArea 解析,floating 使用自有 rect。统一命中按 z/焦点/注册序选择最上层可见非 full,再回落 active full;返回 Surface 局部坐标,最小化/隐藏项不参与。主帧循环左键按下经 `focusAt` 路由,任务栏排除在 workArea 外;desktop/editor/CLI 已接入配置确认。无头测试覆盖过期 serial、重复 ack、full/floating 矩形、遮挡与最小化、局部坐标、焦点和矩形边界;`zig build test`、`zig build`、`git diff --check` 全过。未启动 GUI、未截图、未控制鼠标键盘。边界:本轮未实现 pointer grab、输入事件 serial/时间戳、完整裁剪和多 Surface 应用身份;下一阶段=结构化 CommandResult/Event/Task。

- **CommandResult/Event/Task 协议第一阶段实装(2026-11-01)**:`runtime/command.zig` 的 handler 从 bool 迁移为 `Result{code,task_id?}`;代码覆盖 ok/accepted/unknown_command/invalid_arguments/permission_denied/invalid_state/not_ready/queue_full/failed/cancelled。UI 入队只返回 accepted,flush 才给执行结果,启动清单只接受 ok;队列满与非法载荷分别报错,缺参和文档 IO 未初始化已映射到对应代码。新增 `runtime/tasks.zig`:每会话独立 TaskId/事件 serial,状态 queued→running→succeeded/failed/cancelled(queued 也可直接终结),终结后不可改写;progress 仅 0..1000,最近事件环非破坏读取,重复读取不推进游标。`RuntimeContext` 已持有 tasks,CLI 历史显示 `命令 -> 结果代码`,资源加载遇失败不再静默计数。无头测试覆盖结果代码、队列背压、过期执行、任务生命周期、终结不可逆、失败/取消和会话隔离;`zig build test`、`zig build`、`git diff --check` 全过,未启动 GUI/截图/输入自动化。边界:任务所有者/权限/取消政策、通用事件订阅与真实导出下载任务尚未接入,不能把本轮状态机当成业务任务已完成。

- **最小真实单帧编辑器闭环实装(2026-11-01)**:新增 `runtime/render.zig`,同步执行 testsrc → gain → RGBA8;`Document.fingerprint` 覆盖制式与节点参数,Preview 只保留当前工作帧,指纹变化才重算并推进 generation,保存 dirty 变化不伪造内容失效。编辑器经 ImGui 1.92 用户纹理显示真实像素,vendored zgui 仅补 Register/UnregisterUserTexture 薄 C 接口;同尺寸更新走 want_updates,尺寸变化先 want_destroy、下一帧重建,避免绘制命令持有已释放绑定组。无头测试覆盖精确 RGBA、重复拉取不重算、gain/分辨率失效、纹理重建条件和“编辑增益→保存→重开→同像素”端到端闭环。`zig build test`、`zig build`、`git diff --check` 全过;未启动 GUI、未截图、未控制鼠标键盘,真实视觉待用户验收。边界:这是单文档、单当前帧、同步 CPU 求值,不是完整流协议/时间轴/L1L2/导出;后续先验证真实预览与 CLI 联动,再扩节点和装配,不提前引入每合成线程或缓存层级。

- **最小 DAG 装配与 invert/over 实装(2026-11-01)**:`.cut` 词汇扩为 `testsrc/gain/invert/over`;`invert{ in:c0 }` 与 `over{ .{in:c0}, .{in:c1,opacity:0.25} }` 支持规范化 emit∘parse,over 暂固定双输入,第二路 opacity 默认 1。解析要求所有输入指向已存在的较小 id,缺引用/自引用/非法透明度拒绝。求值从线性数组假设改为按 comp id 递归装配,同源可被多分支复用;over 按 top alpha×opacity 做标准 alpha 合成。编辑器节点文本与真实预览沿用同一文档和指纹失效。无头测试覆盖 invert/over 规范化往返、缺引用、双分支精确像素和既有增益/保存回归;`zig build test`、`zig build`、`git diff --check` 全过,未启动 GUI/截图/输入自动化。边界:仍是固定 8 节点、双输入 over、同步单帧 CPU 求值,不支持任意聚合参数、时间轴或完整流协议。

- **开发/分发/使用三态与运行时数据分层(2026-11-01 用户规范+校准)**:①开发、分发、使用是三件事。开发产物只验证能力,应用运行数据(配置/文档/会话/索引/用户缓存)不得写入构建或待打包目录;`.zig-cache` 的编译器缓存合法,禁的是应用数据不是编译中间物。②便携版=可移动自包含副本,数据在程序旁、不碰注册表;安装版=系统目录+注册表/文件关联/卸载,数据在用户配置/状态/文档目录,卸载默认保留。三态路径与数据命名空间必须不同,可同机并存,不共享、不建链接、不复用缓存。③便携数据不机械包含凭证:默认仍住系统私有存储,不明文入便携目录,不打进分发/测试包。④运行时独立大包=唯一正源+lock/ABI/平台/摘要校验+可复用可回滚,不随应用更新重复打包;但安装包必须保留最小自举闭包(启动器/必要装载库/诊断入口),wgpu_native 这类 main 前硬依赖不能抽走后指望程序再自举下载。⑤不稳定期应用层可完整覆盖更新、不做增量包,但 `.cut` 等用户格式仍须版本化、拒绝静默误读,破坏变更给迁移路径;稳定后增量也只作可选。覆盖更新须原子且不动数据目录,只保留必要回滚副本。⑥测试两层:开发态无头验证能力;用户态以全新应用目录+全新数据目录走下载/安装/运行时/启动/诊断/文档读写/覆盖更新/回滚,不借开发缓存。GUI 仍由用户主动验收,不用截图或输入自动化。⑦当前落点:先立统一路径服务与只读资源/用户数据边界,`assets/examples/session.cut` 不得成为正式用户文档默认位置;安装器/便携包/运行时管理在路径宪法后做,不提前堆分发设施。

- **三态路径服务与用户文档迁移实装(2026-11-01)**:新增 `runtime/paths.zig` 并接入 RuntimeContext。`resource_dir` 只读,development=exe 资源目录+cwd 下 `.cutrans-dev`,portable=exe 旁 `data`,installed=Windows LOCALAPPDATA/Cutrans 或 XDG_STATE_HOME/HOME 状态目录;三态各有独立数据根。无参数 `doc.open` 从 exe 资源目录读 minimal.cut,无参数 `doc.save` 写数据根 `documents/session.cut`,不再写 assets/examples;显式路径行为保持。`openDataDir` 只在保存时创建数据目录,普通启动不写状态;`.cutrans-dev/` 已加入 gitignore。无头测试覆盖资源/数据路径隔离、绝对路径与 `..` 拒绝、真实临时目录保存重读;期间修正 createDirPathOpen 返回子目录句柄导致 documents/documents 的问题,最终 `zig build test`、`zig build`、`git diff --check` 全过。未启动 GUI/截图/输入自动化。边界:安装器、便携包、运行时下载/回滚和正式用户环境验收尚未实现,本轮只是路径机制落地。

- **便携目录与干净用户态诊断实装(2026-11-01)**:新增独立 `cutrans_diag`,无 GUI、无默认文档回退,强制读取包内 minimal.cut,检查初始 RGBA→修改 gain→保存到数据根→重读→同指纹同像素,并要求两次求值。`build portable` 在 zig-out/portable 安装 VM、诊断入口、wgpu_native、CCB、命令与示例,不预写 data;`build diag-user` 先清空该副本 data 再执行,开发诊断另有 `build diag`。首轮验收暴露 addRunArtifact 运行缓存 exe 导致资源根错误,已改为运行实际安装副本;随后 `CUTRANS_DIAG_OK mode=portable evaluations=2`。另将整个便携目录复制到 zig-out/relocatable/Cutrans、清空数据后再次通过,测试副本已删除。`zig build test`、`zig build portable`、`git diff --check` 全过,未启动 GUI/截图/输入自动化。边界:这是便携目录与用户态诊断,不是安装器、注册表集成、运行时独立下载或完整更新回滚。

- **真实 VM 运行模式与 .cut v1 实装(2026-11-01)**:`runtime/paths.zig` 新增共享 `parseMode/parseModeArgs`,cutrans_vm 与 cutrans_diag 均支持 `--mode=development|portable|installed`,非法参数明确拒绝,消除 VM 仍硬编码 development 的缺口。`build run-portable` 使用实际便携 exe+portable 参数,GUI 仅留用户主动验收。`.cut` 规范化输出首行 `version=1`;v1 正常解析,未知/重复版本拒绝,无版本输入标记 legacy 并按旧子集接受,保存迁移到 v1 且清 legacy,fingerprint 不将 legacy 视为内容差。示例 minimal.cut 已升级。无头测试覆盖三种模式、非法模式、legacy 迁移、未知/重复版本及既有便携诊断;`zig build test`、`zig build portable`、`zig build diag-user`、`git diff --check` 全过,未启动 GUI/截图/输入自动化。下一步=通过真实命令注册表创建与编辑 DAG,再考虑图片导入导出。

- **共享文档命令与命令化 DAG 实装(2026-11-01)**:新增 `runtime/document_commands.zig`,将 doc.open/read/write/save 与 editor.gain.set 从 GUI main 抽为 VM/诊断共用 handler,避免入口语义漂移。Document 新增 outputId/nextId/addInvert/addOver/setOverOpacity,命令新增 `editor.invert.add [in]`、`editor.over.add bottom top [opacity]`、`editor.over.opacity.set id opacity`;非法 id/引用/透明度/参数拒绝并标 dirty。诊断改为经真实注册表执行 gain.set→invert.add→over.add,生成 4 节点 DAG,保存前后和重开均验证精确 RGBA;`CUTRANS_DIAG_OK mode=portable evaluations=2 nodes=4`(重开同指纹复用帧,不伪增求值次数)。单测另覆盖 opacity.set 和非法引用。`zig build test`、`zig build portable`、`zig build diag-user`、`git diff --check` 全过,未启动 GUI/截图/输入自动化。下一步=真实图片导入导出,优先成熟 codec,不自造格式。

- **真实 PNG 素材导入/效果/导出闭环实装(2026-11-01)**:素材=libpng 官方 `pngtest.png`(91×69/8831B,SHA-256=b7a46832…6148),经 GitHub CLI 下载并读图校验,来源/许可证记 `assets/examples/SOURCES.md`;stb_image v2.30+许可证入 third_party/stb,stb_image_write 复用 vendored ImGui 件。新增 `runtime/image.zig`+静态 cutrans_stb,Dir+相对路径读取,stbi_load_from_memory 解码,stbi_write_png_to_func 写 File,不绕路径边界。`.cut` 新增 `image{path:"..."}` 与 asset 指纹/规范化往返;求值前每个 image 节点仅解码一次,像素递归只读内存,支持效果链和编辑器真实预览。命令新增 `editor.image.open` 与 `editor.export.png`,默认导出数据根 exports/output.png。诊断先验证四节点 DAG 及 PNG 导出,再执行真实素材导入→invert→保存/重开→导出→stb 再解码,结果 `CUTRANS_DIAG_OK mode=portable evaluations=4 nodes=2 png=91x69`;导出图已读回确认。`zig build test`、`zig build portable`、`zig build diag-user`、`git diff --check` 全过,未启动 GUI/截图/输入自动化。边界:仅 PNG、单帧同步 CPU、图片制式不匹配拒绝,未做缩放/视频/后台任务。

- **最近邻 resize 与制式化 DAG 实装(2026-11-01)**:`.cut` 新增 `resize{in:cN,w:W,h:H}` 和 `editor.resize.add in width height`;out_w/out_h 进指纹和规范化往返,addResize 同步更新文档制式。求值新增 compSize:testsrc=文档尺寸,image=素材自然尺寸,resize=声明尺寸,gain/invert 继承,over 要求两路一致;最终输出制式不符拒绝。像素递归带 x/y,resize 用 source_x=x*in_w/out_w、source_y=y*in_h/out_h 做 nearest-neighbor,不再要求素材自然尺寸等于文档尺寸。编辑器显示 resize 节点与真实预览。单测验证两轴重复像素;诊断执行真实 PNG→invert→91×69 放大 182×138→保存/重开→导出→再解码,结果 `CUTRANS_DIAG_OK mode=portable evaluations=4 nodes=3 png=182x138`,导出图已读回。`zig build test`、`zig build portable`、`zig build diag-user`、`git diff --check` 全过,未启动 GUI/截图/输入自动化。边界:仅 nearest-neighbor 单帧 CPU,无双线性/高质量重采样/视频。
