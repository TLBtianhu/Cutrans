> 历史记录：当前事实以 [现役状态](current.md) 为准；按日期与勘误判断取代关系。个人画像已移除，部署公网地址以文档示例地址替代。

- **JVM环境激活与class执行顺序(2026-10-25 讲解定稿)**:
  - 主线=OS启动原生java.exe→解析classpath/JVM参数并加载jvm.dll→JNI_CreateJavaVM→HotSpot初始化堆/类元数据/GC/解释器/JIT代码缓存/线程锁异常/启动类加载器与java.base最小环境→应用类加载器按需找Main.class→**装载Loading→验证Verification→准备Preparation(静态字段默认零值)→解析Resolution(常量池符号到实际引用,可延迟)→初始化Initialization(静态显式赋值/static块=clinit,首次主动使用一次)→调用main→逐方法建帧(局部变量/操作数栈/PC)→解释执行与画像→热点分层JIT本机码进代码缓存→必要时deopt→main返回且非守护线程结束→关闭钩子/JVM销毁/OS回收**。JDK类并非启动全载,按需加载;类已加载≠已初始化。
  - **JVM规范与HotSpot实现分层**:规范定义class格式/装载连接初始化/字节码语义/运行时数据区;解释器/C1C2/OSR/PGO/deopt是HotSpot执行优化,不是class格式必然。解释执行=取opcode→查语义→取操作数→执行→更新PC与栈;JIT后热点调用直接跑本机码,不再逐条解释。
  - **CUI对照**:独立环境激活无(宿主main已运行);class装载验证≈CUI校验;符号解析≈id/命令名/输入缓冲绑定;类实例对象图≈Node树物化;持续调度=main UI帧泵。**CUI只有类文件+类加载器+运行对象图的虚拟机前庭,没有PC/方法帧/操作数栈/任意跳转/通用执行引擎/JIT/GC**;控件与排版已是Zig原生码。

- **运行时/加载物/权限/真理四层分家律(2026-10-25 对话结晶)**:
  - "先启VM再自动执行load"可作心智模型但非当前实现:宿主main已运行,pages.init当前是普通Zig直调非既有CCB命令。初始runtime=**零UI文档实例但解释先验已在场**(分配器/id与命令注册表/节点类型与校验/主题画笔/状态绑定目标),CUI只把文档带进有能力的环境,不带来整个世界。
  - **CUI=加载物,Node树=内存实例**。多CUI分两义:加载多份不同文档/同一CUI多实例化;后者须实例id与命名空间/独立输入选中状态/动作带实例上下文/明确arena寿命,**声明可共享,实例状态必须分家**。当前仅一份四页CUI,多文档装配后议。
  - 现场create_button/set_property/append_child可行,但权限不应按静态声明vs现场创建划分。改变UI结构/注册执行命令/伪装官方UI是三种不同风险;**稳定性**(不毁树不崩溃)靠schema校验/单写者/事务/撤销/不变量,**安全性**(不可信来源不作恶)靠权限/能力声明/沙箱/来源认证。开发者模式=功能与信任政策非稳定性措施;可信内部代码可直接建树仍须结构校验,不可信插件优先受限模板非任意create与原生调用。
  - **仓库权威性≠UI权威性**:官方仓库可声明其目录内容,不能因此改写本地工程;工程列表是数据投影非真源;按钮文本无执行权,真正裁决=命令注册表/handler/poll/权限上下文;官方权威性来源认证/签名/信任链,不来自官方样式UI。**三层=声明装载(初始UI)/状态命令(运行变化)/权限来源(副作用资格);UI=状态投影+意图输入口,真理住文档/注册表/存储/经认证来源,不住按钮外观**。

- **声明式工作台与启动器降格律(2026-10-25 用户哲学结晶)**:
  - **宿主—声明架构**:极薄宿主运行时先起(泵/分配器/注册表/命令分派/UI解释器/插件加载),此时无具体任务视图;用户/预设/插件声明后装载launcher.cui,当前空间呈现为启动器。exe不必天然叫启动器,更像工作台宿主/声明泵;自动加载也只是启动预设,不是天然必须有主页。当前实现仍是启动器exe自动内嵌加载,本条为后续方向非现状。
  - **纯洁性正解**:不是每个节点都靠人手写,而是**没有不可追溯的隐式绝对节点**;声明可由人/预设/插件/工程索引/AI生成,人可只声明任务意图,系统投影出适配节点。视图必须能追溯至声明/命令/数据投影。
  - **启动器=默认任务预设不是应用本体**:宿主上启动器/编辑器/下载器/临时任务视图本体平级;启动器保留发现性与便利性但不再是所有操作的祖宗。平级≠无依赖,编辑器需工程/下载器需仓库等从UI父子关系改为显式数据文档能力引用。启动器归宿=默认工作区预设/任务索引页/入口集合,需要召唤不需要绕开。
  - **体验本质**:从"启动应用"转为"让当前工作空间呈现成某任务形态"——不是打开启动器,而是召唤启动器视图;声明式工作台让用户把视图当可召唤可消失的任务姿态,CLI/GUI/AI发同种声明。
  - **抽象隐藏因果律**:成熟抽象越成功,用户越只记表面名词而看不见共同底层。Windows双击=文件关联→ShellExecute→目标参数→进程;.lnk≈小型任务声明(目标/参数/工作目录/图标),GUI与CLI不是两种能力;浏览器宿主与网页视图同理。游戏化/全息工作台把声明/装载/召唤/消失重新物化为可操作对象,使被隐藏本质显形——**不是原理新,而是本质首次成为用户可感知对象**。

- **桌面=默认工作区壳非内核律(2026-10-25 Windows/Linux一手源调查)**:
  - 用户推导成立:空运行时=headless会话,默认常用布局=桌面会话核心,常用应用自动启动=会话注册表/启动预设;完整桌面还含窗口管理/会话/通知/后台服务,不止一张布局。当前启动器若承担工程发现/插件/下载/任务入口,角色开始接近桌面壳但尚非完整桌面。
  - **Windows确证**:Windows3.0=Program Manager,Windows95=新Explorer/Desktop/Taskbar(Microsoft Shell Roadmap);登录时Winlogon按HKLM/.../Winlogon的Shell=explorer.exe/Userinit启动用户壳;Shell Launcher官方允许普通桌面/UWP应用替换Explorer,自定义壳权限=登录账户同级;UAC文档明确显示桌面Explorer.exe也使用**标准用户令牌**,日常桌面非天然SYSTEM。Winlogon/UAC安全桌面是另一受限特殊UI表面;NT Desktop对象=可保护对象(窗口菜单hook/Default/Winlogon/ScreenSaver),与Explorer桌面UI不同。**Windows=官方默认壳集成高,但可替换且不是内核**。
  - **Linux确证**:内核只提供DRM/KMS/evdev等,显示服务器/合成器/窗口管理器/桌面环境全在用户空间;Wayland compositor兼显示服务器与窗口管理/合成,客户端自绘;GNOME/KDE/Xfce=完整程序集合,可只装i3/Openbox并自选组件或完全无图形(ArchWiki DE/WM)。**Linux桌面环境=可选可替换用户空间套件,内核无桌面业务概念**。
  - **DOS→Windows**:DOS/COMMAND.COM默认文本解释器→早期Windows在DOS上跑图形环境/Program Manager→Win95 Explorer默认图形壳→NT继续Explorer但不依赖DOS;变化=默认人机壳,非桌面变内核,CLI/GUI从来是同一系统能力上的不同入口。
  - **Cutrans四层**:平台能力(进程窗口GPU文件网络)→运行时宿主(泵注册表命令UI解释器插件加载)→会话声明(默认桌面布局+自动加载常用应用服务)→任务视图(启动器/编辑器/下载器/临时面板)。**桌面=默认工作区声明,不是天然绝对主页**;Windows做成Explorer,Linux发行版做成GNOME/KDE,Cutrans可做成平级可替换且CLI/GUI/AI共同生成的任务工作区。

- **按钮=意图引用,应用=能力状态集合律(2026-10-25)**:
  - 按钮不是小应用,应用不是大按钮;按钮=可命中声明节点+动作引用(id/视觉/命中区/action),只回答长什么样与发什么意图,不拥有应用不执行业务。应用=代码或插件/文档状态/命令处理器/若干视图/后台任务或泵/加载激活休眠退出生命周期;应用不等于窗口或进程,可无窗口/多视图/宿主内能力集合。
  - 按钮与应用=多对多,常见四关系:**加载**(app.launch创建未运行应用)/**激活**(切到已运行视图)/**调用**(发应用内保存导出等命令)/**无直接关系**(换页/菜单/主题/窗口状态)。一应用多入口,一按钮按上下文路由不同处理器,按钮可先于应用存在(点击后未知命令红标),应用也可由CLI/AI/定时器启动无需按钮。
  - Windows亲证:桌面.lnk=声明由Shell解析目标;任务栏按钮通常激活既有窗口非每次新建进程,同图标也可不同语义。
  - Cutrans链路=按钮声明→输入命中→发命令→注册表handler+poll+权限→应用/文档/运行时执行→状态改变→UI重投影。应用可注册能力与入口,宿主按注册表生成按钮;**按钮不直接绑应用私有函数,中间必须隔命令与上下文**,否则CLI/AI/回放/多实例路由被绑死。

- **输入输出与真源解耦+状态/指令语义分家律(2026-10-25)**:
  - 一帧四阶段:D_t=文档与UI状态,G_t=按D_t/主题/窗口尺寸算布局几何,像素_t=Paint(G_t),指令_t=HitTest(G_t,指针事件),D_{t+1}=Execute(D_t,指令_t)。**显示=状态投影,点击坐标=物理事件非命令**;点击→命中声明按钮→生成命令→改状态→重新投影,不是点像素直接改图。输入输出可共享布局几何以保证所见即所点,但不共享真源也不直接互写。当前启动器=逻辑解耦/实现共享ImGui遍历,非两套独立引擎已完工。
  - **最纯因果核心不是只有结构帧与指令**:状态=现在什么是真的,指令=希望发生什么,机器/解释器=意图是什么意思怎么执行,泵/调度=何时读取执行投影;输入输出=边界翻译。纯粹=每物一角不越权:**帧管事实/指令管意图/机器管解释/泵管时机/输入输出管翻译**。
  - **结构帧与指令在存储上都是数据**:ccb也可为定长记录并进日志/分析/复制/序列化,区别不在内存区/定长/持久化/是否修改/文件后缀,而在**语义角色与时间方向**:结构帧描述当前事实,指令描述待执行意图或动作;新状态=机器(旧状态,指令)。寿命只是倾向非定义(帧可短命,命令日志可长命),判据=被谁以何语义读取:回放器眼里是指令,撤销分析器眼里是数据;按钮action排版时是字符串,点击后在注册表才成执行意图。**身份随读者可变,物理字节不必变**。

- **重画触发/绘制动作/输入事件/语义命令四层律(2026-10-25)**:
  - "没有绘制事件"需修正:Win32 WM_PAINT/X11 Expose/Wayland frame callback/浏览器rAF存在,但多为**重画时机通知**非屏幕向应用输入图片;GPU fence/呈现完成=输出后反馈。当前启动器=立即模式+自有帧泵,main主动ui.draw→zgui.render→GPU,绘制是函数调用与输出动作,不依赖OS绘制事件。
  - **OS事件⊂外部事件**:硬件HID/中断,OS鼠标键盘窗口焦点,GLFW/ImGui工具库输入,网络/IPC,插件/AI/回放/定时任务均可跨运行时边界;只有经OS输入系统规范化者叫OS输入事件,不能把全部外部事件统称OS事件。
  - **事件=已发生的事实,命令=希望执行的意图**。同一坐标事件随布局状态产生不同命令,同一命令可来自点击/快捷键/CLI/AI/回放;鼠标移动可只改悬停无命令,命令可无真实输入由程序生成。原始坐标事件不宜直接作撤销日志(布局变则语义变),语义命令更接近可回放意图;GPU draw/submit=图形输出指令,与打开工程等语义命令分属不同指令空间。
  - **鼠标到命令层级**:USB HID只报相对dx/dy/按钮/滚轮,不知屏幕坐标窗口按钮click→OS驱动做指针加速/屏幕坐标/按键状态→OS窗口事件→zglfw→zgui.io位置与按钮事件→ImGui按当前控件矩形命中→按压释放+时间位移阈值判click→语义命令→改状态→重渲染。**硬件说手动了/OS说指针在哪/UI说点中哪控件/命令系统说用户想做什么;重画归帧泵或重画触发器,与鼠标输入是另一条边界**。

- **输入/绘制唤醒源分家与懒等待等价性勘定(2026-10-25)**:
  - 独立绘制泵同样需要等待/唤醒,区别不在输入轮询而绘制免轮询,而在**唤醒信号来源与等待条件**。绘制"可预判"只对一半:**画什么由状态推导,何时画由失效通知/外部事件/时钟决定**(输入/缩放遮挡DPI显示器/动画播放/依赖帧写完/vsync)。
  - 输入泵等待输入队列写游标变化;绘制泵等待状态版本≠已渲染版本或下一deadline/vsync。生产者写状态→推进版本/置脏→唤醒绘制泵,绘制无需反复检查;两者共用空即睡写即醒,只是写者与条件不同。
  - **轮询≠懒等待**:轮询=反复读比耗CPU;懒等待=futex/事件睡眠零指令,写路径唤醒;底层OS调度/中断/比较器/扫描仍守望归轮询守恒。若说底层仍有人守望则对,若说效果等于应用忙等则错。
  - 输入并非必须OS轮询:本质=内容来自外部无法算出,总得有人观察;USB HID可周期报告,设备可中断,OS入队后应用睡等,应用直持设备也可自接收。"必须OS监督"是桌面常见所有权安排非计算必然。
  - **显示扫描与绘制分家**:无新帧时framebuffer不变,显示器仍按120Hz扫同一帧;扫描负责继续显示,绘制泵只在新内容时产图——扫描勤快内容供应链全懒。**输入泵睡到外部输入被写,绘制泵睡到状态版本被写或时钟到,显示硬件持续扫描旧帧**。

- **广义守望≠周期轮询+futex显式唤醒勘误(2026-10-25)**:
  - 旧说"futex睡到地址被写"过度简化,精确版=**futex睡到有人对地址调用FUTEX_WAKE;只写内存不wake不会自动醒**。MWAIT(硬件地址监视)/HLT(等中断)/futex(OS等待桶)不可混谈。
  - 狭义轮询=周期性重复查询;futex若轮询需OS定期遍历睡眠线程并检查条件,实际没有。消费者先查空→futex_wait时内核再核对期望值并挂入按地址哈希等待桶(堵查睡竞态)→从可运行队列移除;等待期消费者零指令,**内核也不周期扫描其等待条件**。生产者写内容/推进游标→显式FUTEX_WAKE→内核从等待桶取线程放回可运行队列→消费者醒来while复查。检查只在入睡前和唤醒后,中间无周期查询。
  - **轮询守恒的真义=观察责任守恒,不是周期查询必须存在**:状态变化后系统要有感知路径,形态可为周期轮询/事件触发(写路径顺手通知)/物理守望(比较器连续看/触发器沿采样)。futex=把查询通知挂到生产者写路径,消费者与OS均不为睡眠条件周期轮询;事件到来仍有人执行唤醒逻辑,故广义守望未消失。
  - 时间线实证:T0查空,T1睡,T2~T999消费者零指令且内核不扫描条件,T1000写+wake,T1001醒后复查。若狭义轮询,中间应有大量再查,实际一次也没有。

- **宿主+桌面架构正名与CUI内容边界(2026-10-25)**:
  - **结构体不限于UI**:命令记录/输入事件/id表项/插件注册/效果参数/布局矩形/缓存元数据/机器与泵状态均可为结构记录。须分通用**结构体**(任意定长记录)与Cutrans**结构帧**(定长schema的机器数据实例,供合成渲染参数计算);按钮声明可为定长记录但属视图文档,不自动等于合成结构帧;不显示的效果参数仍可为结构帧,**显示与否不是判据,读者与语义角色才是**。
  - **CUI=可持久化视图声明文档**:应存schema版本/视图节点树/初始布局静态参数/命令名/状态绑定路径/未来when repeater模板;不应存裸指针函数地址GPU句柄/鼠标命中像素/当前输入悬停动画/进程线程OS对象/工程业务与仓库结果/权限凭证。默认值仅是实例化起点非后续状态。三相=CUI视图文档(初始声明)/Node视图树(内存实例)/UI状态树(当前页输入选择动画)。
  - **命名定案建议**:结构记录=任意定长记录;结构帧=机器计算用定长实例;ViewNode=视图节点(text/button/card);视图文档=.cui及可读源;视图实例=物化Node树及实例状态;命令=语义意图;能力包/应用=代码命令状态视图生命周期集合可headless;工作区/桌面会话=视图实例+当前任务+默认布局+会话服务;宿主运行时=id/分配器/注册表/装载/命令/泵。"VM"只留真正执行通用字节码的子系统,当前称宿主运行时避免名字逼造多余设施。
  - **架构六层**:桌面会话(默认布局/视图实例/当前任务/自动启动)→视图引擎(CUI装载/Node实例/布局命中绘制)→文档与状态(.cut工程/.cui视图/UI与会话状态)→能力与插件(编辑器/仓库/下载器/效果器/命令处理器)→宿主运行时(id/内存/注册表/装载/命令/泵)→平台口岸(OS输入/文件/网络/GPU/显示/CLI/AI)。宿主可无桌面(headless),桌面=默认会话声明非最大应用,应用与视图不互有(应用供能力命令,视图引用,多对多)。桌面声明(哪些视图/怎么排/加载何能力)与视图声明(某视图长什么样)可复用容器技术但语义不混。

- **视图实例=结构+本地状态+外部引用,反对另立UI状态树(2026-10-25 对前条勘误)**:
  - 前条把CUI/Node视图树/UI状态树三相并列,过度拆分会诱发同值两份与同步双写。**更干净三层=声明(CUI)→运行实例(视图结构+本地状态+外部状态引用)→投影(布局/绘制/像素/命中几何)**;视图树与视图状态不是两个必分实体,而是同一实例的两个方面。
  - 共享状态按所有权与寿命归位不按"UI状态"大类归树:搜索文本若仅属当前搜索框=视图实例本地状态,多视图共享=会话状态且实例只存引用;当前工程/素材=工程文档状态;当前页面=桌面会话状态;悬停插值/按下缩放=动画派生表现状态非业务真源。**不存在一棵统一UI状态树装所有值,每个值只留一个真源**。
  - 当前启动器实际只有CUI物化的Node定义树与page/search_buf/status_buf/动画表等散装变量,没有现成UI状态树;后续应把这些散装状态按视图实例/会话/工程文档归位,不为名字整齐硬造大树。
  - HTML对照=HTML源→DOM对象(结构+当前属性值)→渲染结果,不再长统一DOM状态树。**终版:CUI是声明,运行实例=结构+状态+引用统一体,共享数据按文档/会话归属,布局像素只是投影**。

- **CUI硬盘格式清单与内存实例三类增维(2026-10-25)**:
  - **CUI1硬盘三层**:24B文件头(magic/version/header_size/page_count/record_size/strings_offset/strings_size);40B定长节点记录(op/flags/action/kind/a,b,c:f32/s0..s3/action_arg/child_count),8种节点(text/button/list_item/input/card/vstack/hstack/space),树=先序+child_count;UTF-8 NUL字符串区按内容去重(文本/id/图标/命令名/hint/状态绑定名)。硬盘不含指针/颜色对象/函数地址/真实输入缓冲/动画状态/布局坐标/GPU对象。
  - **Node实例=声明的原生表示**:text=字符串切片+实际颜色+halign+size;button=id/label/kind/h/sub/Action;list=id/icon/title/info/selected/Action;input=id/hint+真实缓冲区切片;card=id/pad/w/h/children切片;stack=gap/margin/children;space=f32;runtime-only custom=h+绘制函数指针不序列化。增维第一类=offset→指针切片/先序+count→children数组/flags→theme颜色枚举/绑定名→真实缓冲,不是新增业务参数。
  - **ViewInstance建议最小形**(当前仅有PageDef+散装状态,未独立成对象):id(多实例命名空间)/definition(共享定义或Node树)/local_state(输入选择展开滚动)/context_refs(会话工程共享状态引用)/layout_cache(可选派生矩形尺寸)/generation(可选版本代际)。definition多实例可共享,允许结构独改再私有树或COW;local_state不回写共享定义,context_refs不复制共享数据,cache/generation非声明。
  - **内存增维三类不可混**:①声明的内存表示;②实例级运行结构(id/本地状态/上下文引用/布局缓存/版本);③宿主级共享结构(命令插件注册表/分配器/动画表/字体ImGui上下文/GPU device queue surface/OS window/输入队列/线程泵)。宿主设施每实例只留必要引用,不能每视图复制一套。**CUI=声明最小集,Node=原生表示,ViewInstance=定义引用+身份+本地状态+上下文引用+派生缓存,宿主运行时另层共享**。

- **页面角色化+资源资产化+泵权限三轴分家(2026-10-25)**:
  - **页面树不本质**:当前PageDef{side,content}/Page四枚举/page_count=4只是原型特化。统一形式=Document{id,kind/schema_version,roots[],records[]};side/content只是根的区域角色,页面=视图根被注册为导航目标后的角色,页数/页面id/区域名全是数据。通用CUI应为文档表+根引用表而非永远四页两树。
  - **Blender对照**:Workspace→Area(编辑器实例)→Region→注册Panel/UIBlock,SpaceType决定内容,同类多Area各持状态上下文;核心单位=编辑器实例+区域+注册内容非页面树。Blender核心C类型也大量写死,动态的是实例/布局/注册能力/上下文。可变性三层=规范schema(可官方闭集版本化)/能力实现(插件注册)/实例内容(页面视图文档字体工作区绝不写死)。
  - **字体/语言=资源资产数据块非系统固有物**:FontAsset{id,bytes/source,license,fallback_chain,rasterizer/shaping配置,派生atlas};文件/内嵌/系统/网络只是来源,当前Noto/Remix内嵌也是资产,atlas是派生缓存非真源。LocalePack{locale_id,string_table,fallback_locale,方向复数日期规则};若需i18n,CUI存文本key由LocalePack投影,当前中文仅原型内容。Blender VectorFont=ID数据块,Bfont内置与外部文件仅来源不同。
  - **应用≠有泵**:结构体/文档=被动数据;机器=泵+本体状态+探测口+烧录函数;应用/能力包=代码/命令/文档/视图/机器/生命周期集合,**泵可选**。下载器可有工作泵,格式转换器可被宿主直调,仓库插件可仅命令触发,均可为应用。**泵是执行设施不是应用身份证**。
  - **泵统治力=写入与时机非类型公开性**:写入权/串行化与发布时机/明确绑定的生命周期/调度背压;公开性=谁能看见/寻址/调用,是另一轴。可公开可读仅所属泵可写,可隐藏地址但允许命令修改,可schema公开实例隐藏,可实例可寻址只读;公开读≠公开写,隐藏地址≠禁止命令。
  - **Java对照**:class=字段方法schema,对象=堆实例,方法默认在调用者线程执行;有run()不自动有线程,须Thread.start/Executor/事件循环,JVM不按对象配泵。public/private=源码访问许可,不管线程或单写者;public字段多线程仍可错,private可经public方法间接访问。JMM/synchronized/volatile/concurrent管可见性;Swing EDT/JavaFX应用线程的UI单写规则=额外线程约束非access modifier或JVM自动能力,正证泵绑定/公开性是独立两轴。

- **View文档化与启动器文件架构简化实装(2026-10-25)**:
  - **Page/PageDef退役**:View{id,label,icon,side,content}成为统一单位,视图数量/id/导航标签图标全由声明提供,不再写死四页或Page枚举。CUI v2=24B头+N×12B视图索引(id/label/icon)+40B定长节点先序树+UTF-8字符串区,允许N=0..1024;headless与多视图语义同源。
  - **Action极简**:Action=?[:0]const u8(null=无动作,字符串=命令名),删除未使用goto与Page依赖;node.Ctx只剩x/y/width,导航由shell或命令处理不再节点特判。controls.zig无调用者已删除,不为未来预留空壳。
  - **JSON源码**:launcher.txt→launcher.json(format=cutrans-view-v2,views数组,视图含id/label/icon/side/content),IDE高光友好;compile_ui.py仍只读同目录源码,无双真源。产物=3264B/4视图/54节点/75字符串1032B。
  - **目录定形**:launcher/main.zig=装配,shell.zig=桌面外壳,view.zig=视图注册与当前状态,command.zig=命令;gpu/wgpu.zig+gpu/wgpu_imgui.zig=稳定底层图形设施(从根目录收拢);uikit/theme/anim/paint/widgets/node/bytecode/icons各一职;README更新修改入口和依赖方向。
  - **PCL感与桌面适配评估**:PCL式卡片/ restrained accent/侧栏/导航/动画**视觉语言可配桌面外壳**,但当前全屏单视图切换+固定侧栏仍只是启动页/任务壳,不是完整桌面;桌面还需多视图并存/区域组合/会话与窗口管理/动态repeater,皮肤不能替代这些能力。
  - **验证**:Zig fmt/build通过,四视图真实点击与workspace.launch命令回归通过;gpu目录迁移后再次build通过。实现与README留工作区,本条只记架构与实测。

- **唯一自举命令=执行startup目录(2026-10-27 实装)**:
  - exe改名**cutrans_vm**,窗口标题=Cutrans桌面;视图源与产物改desktop.json/desktop.cui。main只负责命令注册+`startup.executeAll`,不再直接view.init或逐项写默认值;DesktopLoad以模块级小结构显式注入arena(不捕获main局部变量)。
  - **startup目录模型**:exe同级config/startup,文件按名字排序,每文件按行`command.name [arg]`,空行与#注释忽略;build.zig用installDirectory(.bin)安装配置,开发run与双击exe同路径。00-desktop.ccmd=`desktop.load`,10-defaults.ccmd=`font.main NotoSansSC`+`locale.default zh-CN`;Command增加可选arg。
  - **默认项=启动命令非第二配置系统**:font.main经config.setFontMain校验并由config.mainFont解析实际内嵌资产(不支持的值启动边界失败);locale.default设置默认运行值;startup执行后检查views非空,无桌面则拒绝继续。实测日志=2文件/3命令,CUI 3264B/4视图/54节点,四视图点击与workspace.launch通过。
  - **真正桌面感实现路径(下一阶段非本次完成)**:①从全屏页面切换改为**多区域多视图共存**(导航/任务列表/主工作区/检查器/底部任务控制台,区域引用视图实例);②启动器降为任务与文档中心的一种视图,打开工程不必先回首页;③视图实例焦点/关闭/移动/拆分与键盘快捷键全部命令化;④后台下载导出进常驻任务面板与完成通知,体现1+n;⑤工作区声明保存恢复布局与打开视图,startup=重放会话命令;⑥视觉从嵌套卡片改为区域框架/中立表面/明确焦点,PCL令牌沿用。**桌面感核心=同时呈现多任务信息+空间稳定+会话连续,不是改名或蓝色皮肤**。

- **多应用共享运行时与资产区/协议后缀分治(2026-10-27 架构立法)**:
  - **配置目录≠资产目录**:config/startup只存启动命令;字体与语言包是被命令解析的资产,应有独立资产区(assets/fonts/manifest+字体文件,assets/locales/zh-CN.json等)。font.main=默认名→注册表→资产id→文件/内嵌字节;当前config.mainFont仅单资产证明非完整注册表。locale.default指向语言包,CUI国际化时存文本key由LocalePack投影。
  - **根目录按应用集合布局**:apps/desktop(当前外壳)/editor(类PS及后续编辑器)/downloader,runtime(id/命令/装载/startup/文档会话),uikit,gpu,assets/fonts+locales,protocols(ccb/cbb/cui等)。当前launcher只是desktop应用雏形,编辑器是其兄弟非其子。
  - **多应用=同进程能力总线非必然MCP**:应用声明能力/命令/文档/视图,UI/CLI/global agent同入口;同进程传Zig结构/id/函数调用时是本进程命令ABI非跨进程JSON-RPC。MCP只作边缘投影。全局agent需自省命令app.list/app.describe/command.describe/document.list/view.list,不能只知应用名。共享内存≠任意互写:各应用自有本体状态,外部只读探测或命令,权限来自命令与上下文。
  - **多应用同时解两问题**:同进程统一id与使命令可达解决global agent全局视角;各模态保有独立文档schema/编辑命令/视图交互/后台泵,只共享id/帧/命令/注册/装载生命周期,不必把建模图片视频音频压成同一编辑范式。Blender多编辑器证明需求亦警示共享文档与操作符过度缠绕。代价=同进程崩溃可拖垮全体,GPU/分配器/全局注册表可隐藏串行,多应用≠自动故障隔离。
  - **后缀统一原则**:后缀给人/IDE/文件管理器,magic/container kind/schema version/注册表给机器;版本号不另立后缀(CUI v2仍.cui)。文本配置优先.json,命令脚本.ccmd;原生.cop与便携.cbb因加载权限执行不同继续分;.ctb/.ccb/.cui只有真共享容器头+通用TLV装载器时才可合并为统一二进制容器并以kind区分,否则不硬造总格式。**后缀按角色少量分化,格式按magic/kind/version统一,加载器按注册表分派**。

- **多应用骨架与通用应用注册表实装(2026-10-27)**:
  - **根布局落地**:apps/desktop(桌面应用)与apps/editor(类PS壳)平级;runtime(command/startup/config/host/apps/root)共享;根级uikit/gpu/assets/config跨应用共享。build.zig用命名模块runtime/uikit/gpu/assets/editor显式构图,不再允许../../绕模块边界。启动配置移根config/startup并继续安装到exe同级。
  - **应用注册表**:runtime/apps.zig定义App{id,open,close,draw}并管理活动应用;open会关闭当前应用,无活动应用时回默认桌面。main只注册editor并调用apps.open/close/drawActive,不为未来应用增加专门分支。editor.open/close同时切窗口标题与记日志,workspace.launch激活编辑器,editor.close返回桌面,实测两次均True。桌面首页id改home/label桌面,CUI 3262B/4视图/54节点,四视图回归通过。
  - **共享资产**:fonts移根assets/fonts并新增assets/locales/zh-CN.json,assets/root.zig统一嵌字节;runtime/config经assets模块解析字体与语言包,startup后config.localePack验证存在,杜绝"指向不存在的包"。
  - **精简删除**:删除证据明确的bench/gpu_demo.zig及其build target/run-gpu,清理旧cutrans_launcher.exe/gpu_demo.exe生成物;工具链/third_party/scratch与旧档案保留。
  - **桌面设计下一阶段**:当前仍单窗口单活动应用,只是多应用激活证明非完整桌面。下一形态=会话组合器:应用注册表提供视图与命令,默认工作区多区域共存(应用/任务列表+主工作区+检查器+后台任务台),后台任务与完成通知可见,工作区可保存恢复;多模态编辑器各自业务独立但共享runtime/id/命令/资产。**桌面设计先靠多应用组合与任务连续,不靠继续增加首页装饰**。

- **部署目录与命令文本/二进制分工(2026-10-27)**:
  - `zig-out/bin/config/startup`是运行时必需的启动输入:startup.executeAll按exe同级config/startup读取并执行,build须安装,否则FileNotFound。早期.prefix误装留下外层zig-out/config已清理。**config/startup=启动时执行的意图;assets=被命令/应用读取的资源**,自举器只执行startup目录,绝不把assets当命令执行。当前bin无assets目录因desktop.cui与字体均@embedFile内嵌,未来外置资源应与config并列独立assets而非混放。
  - **指令编码按读者分**:startup/人工配置保留可读.ccmd(手改/diff/注释/排序/审计,低频解析税可忽略);高频运行命令/日志/回放/IPC用二进制ccb(定长解析/类型/版本/紧凑);CUI=机器消费的二进制产物,JSON=人类可编辑真源。**人authored内容用文本,机器高频交换用二进制,可读源码与编译产物同源共存**,不为统一强改startup为二进制。

- **CLI应用=文本方言边界,核心只收二进制Command(2026-10-27 用户纠正后实装)**:
  - 用户指正:CLI本身是开机自启动应用,系统最本质理解的是二进制命令而非ccmd。此前runtime/startup直接解析文本=把CLI职责偷塞进核心,已纠正。**core只见Command二进制记录;.ccmd是CLI应用的输入方言,不是核心命令格式**。
  - runtime/startup.zig已迁至**apps/cli/cli.zig**,职责=按文件名排序读取exe同级config/startup,逐行把command.name [arg]解析成runtime/command.Command;runtime/root不再导出startup。main不再直接调用解析器,而是只`command.dispatch(.{name="cli.startup"})`,由CLI应用自动执行启动目录。CLI与desktop/editor同属apps,文本可编辑与核心二进制并不冲突。
  - **编码边界终版**:人编写/修改的脚本与配置可用.ccmd,由CLI或编译器翻译;核心调用/日志/回放/IPC的权威形态是二进制Command/CCB。startup文本不需要为了纯化而改二进制,关键是**它只能由CLI解释,核心不得直接理解它**。当前CCB序列化格式未实现,不假装已有;现有的是内存二进制Command。
  - 验证:cli.startup自举日志仍2文件/3命令,CUI 3262B/4视图/54节点,桌面启动与editor.open/editor.close均通过。实现留工作区,本条只记纠正与实测。

- **启动清单二进制先验与VM空间策略(2026-10-27)**:
  - **启动循环依赖勘定**:若CLI未启动却由CLI解析"启动哪些应用"清单,该清单就不能依赖CLI。严格模型=VM内置二进制读取器执行startup.ccb→cli.start/desktop.load/font.main/locale.default→可选cli.load用户脚本.ccmd。**startup.ccb=系统级先验;.ccmd/.cut=资源/源码非系统先验**。人可写startup.ccmd但须构建期编译成startup.ccb,避免运行时编译与CLI循环依赖。ccmd只剩两用法:CLI启动后现场输入/作为资源由二进制cli.load加载。
  - **CUI与ccmd分界修正**:区别不在KB大小或作者身份(ccmd也可大,CUI也可小,用户插件未来也可生成CUI),而在**启动/加载确定性**(schema/版本/构建期校验)/信任复杂度边界(启动不能先装复杂文本编译器)/使用频率。CUI如字体=随应用装载的二进制资源,JSON=编写投影;过审是信任政策非格式本质,信息密度只是优化收益。
  - **VM默认最大化非独占全屏**:最大化=当前显示器工作区保留窗口管理;沉浸=预览播放可选;独占全屏仅特殊播放/游戏再议。真正质变=固定尺寸画布→随环境可变工作区,非"全屏"词本身(全屏在单屏也有确定像素,最大化跨屏仍变)。PCL固定小窗适合表单启动器,编辑器1120×680会挤画布时间线检查器故应占满。
  - **应用只声明空间策略不有全屏意识**:editor=fill,desktop=centered/preferred(最大化VM内仍居中限宽),cli=dock bottom 240~320可展开收起,preview=immersive可选。VM按窗口客户区统一分矩形,应用只用VM坐标,不各自Win32挪窗算偏移;空间索要全在VM内,支持多显示器工作区而非默认跨所有屏。**VM默认最大化,应用声明fill/centered/dock/immersive,VM负责映射真实屏幕**。

- **虚拟应用/虚拟窗口单一原生宿主律(2026-10-27 用户钉死前提)**:
  - desktop/editor/cli/downloader=VM内虚拟应用,其窗口=VM内虚拟窗口非独立HWND;Windows任务栏只显示一个cutrans_vm进程与一个原生窗口,任务管理器只见VM总CPU/内存/GPU。虚拟应用生命周期/标题/最小化/关闭/焦点/任务切换必须VM自管,不能依赖Windows分别呈现。
  - 当前win.setTitle("Cutrans 编辑器")只是激活验证临时手段非终态;终态=原生窗口标题Cutrans VM不变,VM内部虚拟标题栏显示编辑器/CLI/下载器。虚拟窗口=记录{id,app_id,rect,z_order,focus,state,view_id},VM分配矩形/管理焦点层级移动缩放最小化关闭/输入坐标转VM坐标后路由/各应用画面裁剪合成到原生表面。
  - **桌面必须有虚拟任务栏/应用切换器**:Windows不显示虚拟应用,用户须在VM桌面看到editor运行/downloader后台/CLI打开等状态;虚拟任务栏比Windows任务栏更贴近多应用模型。
  - **共享进程≠故障隔离**:任务管理器不能单独结束虚拟应用,须VM应用管理器停止/重启/卸载;不可信插件需硬隔离时越过VM边界改独立进程,不继续冒充虚拟应用。**原生窗口只是VM显示屏,虚拟应用与窗口全为VM内部对象;Windows管显示屏,VM统治其中应用与窗口**。

- **二进制启动清单与full/dock虚拟窗口实装(2026-10-27)**:
  - **启动先验已二进制化**:config/startup.ccmd仅人类源码,config/compile_startup.py在build时生成startup.ccb(CCB1:12B头+opcode/flags/arg_len记录+UTF-8参数);runtime/startup.zig直接执行,main仅dispatch startup.execute,不再由CLI解析启动清单,消除CLI未启动的循环依赖。当前清单=cli.start/desktop.load/font.main/locale.default/cli.load example,startup.ccb=98B/5命令,构建自动重编并安装到exe同级config。
  - **CLI两用法落地**:cli.start由二进制启动后以dock打开虚拟终端;cli.load仅在CLI启动后读取exe相对路径的.ccmd文本资源并翻成runtime/command.Command(拒绝绝对路径与..)。实测assets/commands/00-example.ccmd被加载1条命令;在可见CLI输入框粘贴workspace.launch并回车,日志收到editor.open与workspace.launch,editor.close正常。
  - **full/dock虚拟窗口**:runtime/apps.App增加mode与is_open;full切换主工作区,dock可与full共存。主循环drawActive/drawDocks,CLI底部220px面板用setNextWindowFocus避免被全屏桌面根窗口遮挡。VM默认最大化且原生标题固定Cutrans VM,editor.open/close不再改OS标题;Windows只见一个进程与原生窗口。
  - **验证与边界**:Zig build通过,桌面四视图/编辑器激活返回/二进制启动/文本资源/CLI输入均实测。当前=一个full应用+一个dock面板,不是完整桌面;下一步按此基础扩展多区域/虚拟任务栏/会话恢复,而不是把CLI或编辑器塞回桌面页面。实现与README留工作区,本条只记模型与实测。

- **桌面信息架构/下载基座/VM背景分工(2026-10-27)**:
  - **git事实**:C:/Cutrans/Cutrans-zig0.1已属C:/Cutrans仓库,不应嵌套git init成双仓库;若需独立项目应迁移拆分非覆盖现状。
  - **full/dock定义**:full=占主工作区,当前full活动替换前一个full,适合编辑器画布;dock=底部/侧边面板可与full或其他dock共存,CLI当前底部dock。它们是VM虚拟窗口空间模式,不是进程类型或Windows全屏。
  - **VM背景≠桌面应用背景**:VM背景只负责未覆盖空隙/letterbox/空工作区,建议中立兜底色或无空隙不画,不做第二张桌面背景盖在应用后;桌面应用背景由桌面自己绘制,CLI/编辑器背景各自负责。透明只是合成alpha可选项,不需要为模型做Windows真透明,关键是VM不替应用重复画背景。
  - **导航四职责**:首页=项目介绍/账号/最近会话/快速继续/agent入口;应用=已安装清单/版本/运行状态/详情/打开关闭更新卸载;下载=源/仓库/搜索/下载安装任务/失败重试;配置=VM默认项/启动策略/语言字体/资源路径/权限主题。版本已装与当前运行归应用,默认配置/资源目录/启动策略归配置,配置不复制整套应用列表。
  - **应用启动业务**:完整目录与管理的明确入口在应用页;最近任务/常用应用/命令输入在首页;agent/命令面板随时app.open,不要求先导航Tab。多应用快速调用=命令优先,页面是投影不是必经路径。
  - **插件vs应用**:应用可独立激活有生命周期/窗口或后台任务,插件被宿主加载提供能力通常不要求独立窗口/生命周期。同一能力包可standalone包应用壳或plugin暴露宿主ABI;exe/dll是近似非严格等价,特制头可声明入口权限但不是魔法转换器,独立运行与插件加载都需宿主支持。
  - **下载器=自带基座能力+可选管理UI**:app.install可从首页/应用页/agent/其他应用/CLI直接发起,不要求先打开下载器。自带不等于任意权限或不可卸载,合理权限=网络/指定资产目录写入/签名校验/门卫加载;可随VM更新或允许替换,但保留最小恢复下载器防最后获取通道被删。桌面同理=默认外壳非太上皇,可替换但留最小安全桌面/恢复入口。
  - **OS先例**:apt/dnf/winget/softwareupdate可CLI调用不必先开商店;Android包安装服务与Play商店UI分离;VS Code code--install-extension绕过扩展页;浏览器/游戏平台可链接命令触发安装;Windows Explorer可替换/Linux DE可选——均是能力内置UI可选。
  - **全局agent=任务编排者与命令客户端,非超级UI/超级权限**:查应用源文档任务,直接app.open/install/focus,执行搜索下载与元策略,后台任务经dock/通知报告;权限按命令上下文授权。收口:首页=我要做什么/应用=我有什么/下载=从哪获得/配置=VM怎么运行/agent=直接执行,下载器与桌面只是内置能力与视图。

- **主仓库独立与网络底座/依赖/agent分层(2026-10-27)**:
  - **主仓库已独立**:C:/Cutrans/Cutrans-zig0.1拥有独立.git,首提交d88dff1d(feat: establish multi-app VM desktop),父目录老仓库未改。此前git init误在父目录执行已纠正,以git -C明确路径。
  - **VM底座能力应通用非业务专化**:网络底座=DNS/TCP/TLS/HTTP(S)/代理/超时重试缓存/Range断点续传/流式/并发速率限制/错误分类,服务下载源/AI/B站资源抓取/更新等;源插件只提供URL规则认证元数据内容解析,核心无需写物理NIC驱动,继续使用OS socket/TLS/驱动栈。渲染计算同理=通用GPU/缓冲/计算,具体效果器归应用插件。
  - **依赖/应用/插件是关系非包天然身份**:依赖=某应用必需共享前提,应用=可独立激活有生命周期视图或后台,插件=可选能力扩展可多应用共享非专属子集。同一包可对A必需依赖对B可选插件,必需性随消费者而变。好依赖=稳定窄接口通用能力;坏依赖=补核心抽象失败的胶水/补丁/语义分叉。口号修精确=**少而稳定的依赖,丰富而自治的插件**,不把依赖多必丑/插件多必好当绝对律。
  - **agent≈CLI+规划反馈而非仅解析器**:CLI与agent共享命令执行/资源加载/网络下载/应用文档自省/文本到二进制边缘翻译;CLI=明确命令直接映射,agent=目标→规划→选工具→执行→观察→修正,是CLI+目标规划+状态记忆+反馈循环,不天然增加权限。
  - **全局agent与专用agent=同一引擎不同上下文/能力包**:全局任务层桌面/CLI/agent都能下载配置启动因同命令总线;应用内部细节只对暴露命令可达,agent不能凭空改内存。全局agent管跨应用编排,应用专用agent/工具包管文档细节,共享网络/记忆/命令执行/审计,需要细节时全局调用当前应用能力包,不复制两套agent基础设施。

- **三操作台/能力清单/VM指令与文档投影律(2026-10-27 用户结晶)**:
  - **思维主体同一agent,应用无独立意识**:应用差异=向同一agent提供skill(命令schema/参数约束/poll/资源id/副作用/返回错误/示例版本权限)与上下文。skill同时生成CLI帮助补全/AI function calling schema/GUI按钮菜单提示,**应用只维护一份能力清单,不写三套业务适配器**。
  - **GUI/CLI/agent=三操作台非应用**:GUI点击快捷键命中→二进制Command,CLI文本→二进制Command,agent目标+skill+函数调用→二进制Command;核心只校验/分派/执行/返回事件。当前apps/cli与apps/desktop只是实现包装,语义应归CLI/GUI操作台,不与editor/downloader同类。
  - **AI格式与MCP边界**:内部Command{name,arg}/未来CCB比MCP JSON-RPC短且适合共享内存,但不天然具备MCP生命周期/工具发现/资源/通知/传输互操作。内部不改成JSON,外部以MCP适配器映射tools/list/tools/call到同一注册表,AI schema从skill自动生成。
  - **VM指令vs应用专用指令**:VM指令=应用管理/文档读写/资源/启动/全局任务;应用专用=调色裁切图层建模下载策略等领域动作。write快在**聚合声明式事务**(一次校验装配状态替换),ccmd构建=N次解析分派中间态,非write魔法或小任务必快;write仍须schema/poll/权限/事务校验,不得绕不变量。
  - **文档实例必须可被VM指令read/write**:不应手动存盘才能协作;每应用提供稳定可序列化声明投影(当前编辑状态/伪代码),doc.read(app/document id)读当前树,doc.write校验后替换或合并,读写对象=内存文档实例非仅硬盘文件。不要求内部结构全文本人工化,要求稳定声明投影+应用校验+内存态可协作,这就是可被VM指令直接读写的伪代码设计理念。

- **VM/应用专用指令归属与分派路径(2026-10-27)**:
  - 插件下载器可为实打实应用(状态/源/任务/视图/专用命令),GUI/CLI/agent经同一能力清单调用;但"下载基座能力"与"下载器应用"仍两角色,自带不等于非应用。
  - **按钮语义归属**:打开应用=VM app.open;打开文档=VM doc.open交对应应用(特殊格式由应用专用补充);导入素材=可抽象VM asset.import但格式解析由应用/导入插件;保存文档=VM doc.save/doc.write canonical投影;导出视频图片音频=应用专用(editor.export.h264等)。按钮无类型属性,归属看实际发出命令;生命周期走VM,通用文档资产走VM,具体业务格式走应用。
  - **二进制应用专用指令不是先翻成VM指令更不是Windows指令**:路径=控制台→二进制Command→注册表按命名空间分派→应用原生handler→应用业务逻辑→按需VM服务或OS接口。editor.export.h264由编辑器求值/编码器插件/文件后端完成,核心不懂H264。应用提供的是原生处理函数非Windows命令,只有平台后端碰Win32/CoreAudio,业务保持平台中立。
  - **编码统一语义分域**:VM与app专用可共享CCB编码,差别在语义所有者不在格式。app.open由VM激活,doc.save由VM定义协议应用提供读写器,editor.export由编辑器定义,cli.load由CLI定义。长期生命周期命令统一app.close("editor")优于editor.close,领域命令留应用命名空间。
