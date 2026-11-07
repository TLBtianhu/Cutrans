> 历史记录：当前事实以 [现役状态](current.md) 为准；按日期与勘误判断取代关系。个人画像已移除，部署公网地址以文档示例地址替代。

- **下一阶段重构蓝图:三操作台/两指令域/三实体(2026-10-27 先讲后做)**:
  - **目标结构**:apps/editor/downloader为真业务应用;consoles/gui/cli/agent为操作台(桌面视图点击/CLI文本dock/agent编排)非应用;runtime/services/install/network/assets为必需基座服务;plugins/effects/formats/sources为可选共享能力;runtime/command/startup/apps/surfaces/documents/config/host分责,uikit/gpu/assets/config共享。
  - **两指令域**:VM指令域(app.open/doc.read write save/asset.import/source.install/启动资源)与应用专用域(editor.export/gain.set/model.mesh.edit)共享CCB编码与注册表,handler分属VM和应用;VM不解析应用业务,应用指令无需先翻译为VM指令。
  - **能力清单统一**:每应用一份skill/manifest(id/version/entry/commands/views/documents/assets/permissions),同时生成CLI帮助补全/AI function schema/GUI按钮菜单提示/启动注册。DocumentProvider提供read(document_id)→当前声明树与write→校验后替换合并,使agent直接操作内存.cut,无需手动存盘或理解内部结构体。
  - **启动语义重排**:startup.ccb保留二进制先验,改为console.cli.start/console.gui.start/font.main/locale.default/cli.load,可选app.open editor;启动清单只负责操作台/默认配置/初始任务,不承载业务。
  - **虚拟窗口独立成层**:runtime/apps管应用注册生命周期,runtime/surfaces管full/dock/rect/z/focus/state与输入路由;Surface含owner_kind(app|console)/owner_id,编辑器full/CLI dock/agent可dock或隐藏/桌面GUI默认非特权;VM背景仅未覆盖区域中立兜底,不替应用重复画背景。
  - **下载与agent**:runtime/services/install内置app.install,apps/downloader仅源搜索任务失败处理UI,下载不必先开下载器;全局agent同一引擎分全局上下文(应用源任务配置)与应用上下文(文档专用命令skill),需要细节时调用应用能力包,不造特权第二agent。
  - **迁移顺序**:①语义边界(apps/desktop→consoles/gui,apps/cli→consoles/cli,拆surfaces,workspace.launch→app.open/editor.close→app.close/desktop.load→console.gui.start,保行为);②最小skill.json+DocumentProvider,以最小.cut验证内存读写;③首页/应用/下载/配置+surfaces+虚拟任务栏;④app.install服务与全局agent复用skill。下一步先做阶段1,不先写agent或下载器。

- **共享显示后端≠共享显示策略(2026-10-27 用户补正)**:
  - 桌面=系统对VM应用注册表/会话/虚拟窗口/任务状态的GUI投影;编辑器UI=编辑器应用对其文档/工具/选区/画布的GUI投影。二者可共用字体/GPU/纹理/ImGui/wgpu/绘制上传等显示后端,但**投影规则必须分别维护**,CLI对命令历史/输入/返回结果的文本投影亦独立。
  - 三层=应用状态→应用自己的显示策略(视图模型/场景/布局)→共享显示渲染器→原生表面。桌面策略管工作区/任务栏/焦点/通知,编辑器策略管文档画布工具检查器;同一策略可有多实例,策略归属应用/视图类型而非GPU。
  - **CCB是命令输入不是GUI描述**:正常链路=CCB→状态→显示策略→GUI,不是CCB→GUI;CUI才是视图声明,且CUI按应用/视图分属,不是所有应用统一策略。共享uikit只提供通用控件,不替各应用决定业务如何呈现。
  - 结论:共享显示后端可以只有一套,显示策略必须按应用分别维护,否则统一UI会重新长成懂所有业务的巨型核心。

- **呈现后端与三操作台平级律(2026-10-27)**:
  - "显示器"须拆为物理显示/呈现后端(像素/纹理/表面/scanout)与GUI显示策略(控件/布局/焦点/命中/视图语义)。呈现后端更底层;GUI显示策略不到像素级,与CLI显示策略(文本/历史/提示符)/Agent显示策略(对话/计划/任务/结果)同属操作台呈现层。
  - **GUI/CLI/agent语义平级但实现可复用**:三者都把意图翻成Command并选择结果呈现方式;CLI文本面板/Agent对话面板/桌面GUI控件可共用GUI渲染后端,但CLI也可输出stdout/文件/socket,agent也可返回结构化数据,不必然化归为GUI窗口。
  - **屏幕文字游标不是输入本体**:键盘硬件→OS输入→文本控件改当前文本→解析成Command;游标只是当前输入状态的GUI投影。文件/管道/网络输入无需屏幕和游标,故输入不必须经GUI。
  - **VM显示/播放指令属呈现服务非某操作台专属**:present.view/surface.show/play.frame/audio.play等输出端口让应用不直摸GPU/OS窗口。双向链路=输入(OS事件/文本/自然语言→控制台适配→二进制Command→改状态);输出(状态→应用显示策略→VM呈现服务→像素/文本/网络返回)。**显示后端管怎么画,操作台管怎么理解输入与组织输出,谁也不天然是谁上级**。

- **操作台/业务应用/虚拟窗口三层实装(2026-10-27)**:
  - **目录**:apps/desktop→consoles/gui(VM稀疏GUI投影),apps/cli→consoles/cli(文本操作台),apps/editor保留为业务应用。runtime/surfaces.zig独立管理Surface{owner_kind=app|console,id,mode=full|dock,open/close/draw,is_open},runtime/apps.zig只保留业务应用注册与open/close,主循环用surfaces.drawActive/drawDocks。uikit/gpu明确为通用绘制设施,不与VM专属稀疏GUI混淆。
  - **命令统一**:app.open editor/app.close editor取代workspace.launch/editor.close;desktop.load→console.gui.start,cli.start→console.cli.start,cli.load保留资源加载。startup.ccb由config/compile_startup.py按新名字生成,runtime/startup直接执行;CUI action解析升级为name+可选arg,app.open按id走VM注册表。
  - **交互修正**:CLI dock的setNextWindowFocus改为focus_next仅首次打开执行,避免每帧抢焦点导致编辑器返回按钮失效;app.open/app.close失败分支补日志。实测四视图/app.open editor/editor.open/app.close/editor.close均通过,CLI资源加载与dock显示正常,VM原生标题固定Cutrans VM。
  - **下一步**:consoles/agent、skill/manifest、DocumentProvider和首页/应用/下载/配置信息架构尚未实现,本阶段仅证明操作台与业务应用/虚拟窗口边界。实现与README留工作区,本条只记重构与实测。

- **交互能力/可见应用/agent服务与GUI职责(2026-10-27 用户结晶)**:
  - **CLI/agent纯形态可无界面**:CLI实例={输入文本/历史/补全/解析/执行/返回事件},agent实例={goal/plan/conversation/pending calls/memory/observations},均不必然有GUI显示策略。可见终端app=CLI能力+GUI显示与输入,agent app=agent能力+GUI显示与输入;bash可无终端窗口运行,模型仍同一主体,skill/上下文/工具/任务状态变化而非意识分裂。
  - **agent两输入路线非纯洁判据**:模型输出可直接映射CCB(短但需严格schema+poll权限),也可输出ccmd经CLI解析成CCB(多一层但复用语法/错误提示/审计/可读性);选哪条不决定agent是基础设施还是应用,headless agent服务也可走ccmd。
  - **agent不是简单擅长CLI**:CLI=显式命令解析执行;agent=带目标规划/工具选择/执行观察/状态记忆/失败恢复的任务执行器。agent loop=执行器内结构体实例非独立意识。
  - **MCP与CLI不是agent底层论vs agent app论**:MCP=工具发现/调用/传输的协议与能力边界,CLI=人或agent表达意图的交互方式;MCP可服务headless agent,CLI可用于可见agent app。真正正交的是**agent服务(无界面)vs agent UI(服务的投影)**。
  - **GUI职责=交互式投影三部分**:输出投影(状态→视图布局控件像素)/输入翻译(指针键盘焦点手势→命令)/失效更新(版本脏标记事件唤醒重投影,不必须轮询);GUI不管业务逻辑,窗口只是其surface。最终=CLI文本→命令,agent目标→计划→命令→反馈,GUI状态↔视图交互,可见应用=能力组合+业务状态。

- **agent原生协议vs CLI中间层(2026-10-27 用户澄清)**:
  - 用户所谓agent底层论/app论=**agent是否要有自己的原生命令语言,还是必须借CLI作中间载体**,与agent是服务还是应用不同维度。原生路线=目标→结构化工具调用→schema/poll→二进制Command(类型安全/复杂参数/工具发现/审计回放,但需schema);CLI路线=目标→ccmd→CLI解析→Command(人类共用脚本/可读可改,但有转义歧义弱类型二次解析且依赖CLI在场)。headless agent也可走CLI,原生协议不自动等于更底层。
  - **Cutrans推荐**:保留ccmd作人类可读脚本与CLI输入,同时由同一skill/command schema自动生成agent原生function-calling协议;GUI/CLI/agent三投影统一映射到同一CCB,**不另造一套命令宇宙,不强迫agent必须经CLI**。agent协议更像带类型的函数签名(app.open(id="editor")),不必另创自然语言DSL,模型输出仍须schema/poll/权限校验。
  - 选型:小命令集/人AI共享脚本多→CLI中间层方便;多应用/复杂参数/结构化文档/异步任务/权限回放要求高→agent原生function calling更合适。原生不是取消验证,CLI不是低一等,二者只是不同入口协议。

- **前端适配成本与命令粒度(2026-10-27)**:
  - **共用skill时,MCP原生与CLI的边际维护成本同量级**:昂贵的命令语义/参数约束/poll/handler/权限/文档相同,差异在外壳——CLI额外=转义解析/交互历史/补全/错误提示/shell兼容,MCP额外=生命周期/工具发现/传输/错误格式/会话互操作。现成MCP库可使适配器很薄,手写MCP或完整CLI解析器均不免费;不是新增前端应比新增命令更贵。
  - **CLI颗粒度小是历史与交互习惯不是协议本质**:Unix传统=小工具+可组合+管道+脚本,交互人需要可预测可拆可重复,故常见小步命令;但make/git/ffmpeg/docker/apt均可大任务,Cutrans write.cut/app.install/editor.export也可大颗粒。MCP/原生function calling同样可大可小(read_file或build_project),**粒度由命令语义与事务设计决定,不由协议决定,也不是之前没人想过**。Cutrans应同时保留小命令(组合调试精细控制)与大命令(装配导出安装文档写入,减少agent规划往返)。

- **进程CLI已存在与应用语义CLI空缺+MCP真实动因(2024-11-25)**:
  - 进程级CLI早有ps/kill/jobs/top/pgrep/tasklist/systemctl/docker等;用户真正指出的是**GUI应用内部对象与语义动作缺少统一命令接口**(app.focus/doc.save/editor.export/window.close),过去多靠坐标点击/图像识别/辅助功能树/AppleScript/AutoHotkey/xdotool等脆弱GUI自动化。AI时代细粒度语义命令价值骤增:agent无需看懂按钮,直接调用明确命令。
  - **MCP vs CLI不只是语法**:CLI=进程调用+stdout/stderr/exit code,擅长人读/管道/文本/一次性执行;MCP=AI工具与资源交互协议,含initialize能力协商/tools/list工具与schema发现/tools/call结构化调用/resources list read资源发现读取/通知错误及按实现的进度取消。差别在反馈策略/发现/资源/会话,不只JSON外形。
  - **2024 Anthropic为何不直接用CLI**:CLI语法输出各异(文本/JSON/表格/错误码),无统一工具发现与资源模型,进程生命周期不适合长会话的进度取消流式状态,权限同意难统一,N×M集成重复。MCP目标=标准化AI应用发现调用外部能力,非再造人机命令语言。**当CLI被当agent工具协议,很快会重新发明MCP所需设施**。
  - 对Cutrans:ccmd继续作人/CLI文本入口,skill/command schema统一命令与反馈真源,agent用结构化function calling,MCP仅作外部互操作适配层。**CLI解决怎么输入命令,MCP解决agent如何发现调用并理解外部能力**。

- **AI格式先验与私有协议防错律(2026-10-27)**:
  - "MCP刻进AI基因"不准确:更多是JSON/JSON-RPC/function calling/工具schema的训练先验+宿主在上下文注入可用工具签名,不是自带完整MCP规范。当前ZCode环境确有搜索/文档/CloudBase等MCP工具的名称/参数schema/说明,可用性来自宿主接口注入而非模型背诵规范。
  - **私有ccmd/ccb/自定义JSON若无明确schema,模型易退回JSON-RPC/MCP method+params或OpenAI name+arguments并猜字段,确有格式错配风险;原始二进制更不该让模型直接手写**。
  - 防错首选=给AI熟悉的结构化JSON/function-calling投影(name+arguments或标准tools/call),由Cutrans适配器转内部CCB;若需互操作可用MCP外形但内部仍CCB。skill必须含命令用途/参数类型必填默认/poll权限/返回错误结构/完整示例/禁用写法,错误返回结构化原因+正确示例供自纠,不只报未知命令。
  - **MCP只降低格式学习与互操作成本,不能消除id错/命令错/参数非法/状态不允许等语义错误**;私有格式可行关键是明确schema+示例+验证+反馈,而非强推MCP。

- **MCP可用于进程内+AI知识/学习/自我估量三层(2026-10-27)**:
  - **MCP首先是工具发现/调用/结果/生命周期协议,跨进程只是常见部署**:同进程可用内存队列传JSON-RPC或适配器直接映射initialize/tools/list/tools/call到本地handler,保留自省/schema/错误/权限/会话并便于未来外泄与测试;简单app.open直接查注册表即可,不必为MCP而MCP。
  - **AI自我估量=训练形成的错误风险监控非可靠内省**:典型信号=版本漂移/既往编译错误/任务失败代价/工具可用性/陌生签名与行为矛盾,促使其先查本地源码文档再写;无可靠"记忆量仪表",也会高估自己而未觉察错误,故只能把可能不熟当验证提示。
  - **记得多 vs 学得快部分解耦**:参数化知识=训练写入的记得;上下文学习/推理时适应=现场读文档/示例/工具/反馈修正。Zig 0.17案例=旧语言编程先验+当前源码证据+编译错误反馈+修正实现,可在具体任务接近原生熟悉,但非全局等同且依赖资料上下文。
  - **学到学习≠后训练**:模型训练时学会利用示例/指令/检索/工具在新任务上调整行为(in-context learning/推理时适应/工具增强生成),推理不自动更新权重;写MEMORY/skill并下次重读=外部记忆与上下文注入非重新训练。非条件反射/条件反射仅可作有限比喻,实质=训练先验与上下文触发的检索-推理-修正循环。

- **上下文≠权重更新与快速权重/Transformer取舍(2026-10-27)**:
  - 标准Transformer中W=训练参数,K/V=输入激活,KV cache=推理中间状态非权重;"把上一次V当整体"更接近工作记忆/动态状态,非通常反向传播更新。只有把状态显式映射成fast weights才可谈有效权重更新,那已不是普通KV cache。
  - **VCP核查**:当前检索到较明确的是Variable & Command Protocol(AI中间层,工具/记忆/插件/上下文管理),未找到"每次更新权重替代上下文"的可靠架构定义,不据此评价其潜力;同名项目须另行对齐,不虚构。
  - **更新权重方向分层**:fast weights/动态状态(长序列流式/省KV/持续任务,线性注意力/SSM/DeltaNet等)有潜力但通常不是全模型反向传播;测试时小范围adapter/LoRA/偏置更新较现实(低成本可回滚少破坏);每次交互全量更新权重=高延迟/灾难性遗忘/复现回滚安全评估困难/恶意输入污染/多用户权限冲突,目前不宜作通用上下文替代。
  - **Transformer仍主流的原因**:训练并行度高/优化与kernels框架分布式量化部署成熟/上下文无需训练且易隔离回放删除/通用能力强,效率新架构尚未全面抵消质量稳定生态差距。上下文贵但全量权重更新通常更贵更难管。
  - **更有潜力混合路线**:Transformer通用能力+上下文当前任务+RAG/文档可检索长期知识+小fast-weight/adapter持续适配,兼顾成熟部署/长期记忆/流式/个性化,而非每次对话重写整个模型。

- **VCP白皮书核查:自学习在记忆检索层而非模型权重(2026-10-27)**:
  - 已读[VCP Whitepaper V3](https://www.vcptoolbox.com/?page=learn-vcp),纠正前条"未证实":VCP确有自学习/动态演化,但不是每次更新LLM参数。8.10三大系统=RAG寻道自学习(按用户采纳/忽略优化检索路径)/Tag权重自学习(按查询频率调权重)/词元组捕网自学习(按查询习惯发现新概念关联);8.11=流式工具调用/查询/阅读触发RAG知识库实时刷新与召回逻辑调整。
  - **VCP真实结构**=外部LLM+VCP工具命令协议+OneRing/VexusMemo长期事实记忆+自学习RAG/检索/元思维+前端多Agent生态;JevRuntime=扩散概率决策公共运行时(重排/自然语言消歧/群聊裁决),主模型仍经API调用,不是W_q/W_k/W_v/FFN等参数更新。VCP2.0另有VexusLite/TDB与TagMemo退役等演进,证明其为运行时/数据检索体系而非权重训练架构。
  - **潜力评价**:路线接近Transformer+外部记忆+自学习检索的混合方案,优点=基础模型稳定/记忆可落盘审计回滚迁移/低成本适配/多应用共享事实,优于每次交互全量改权重;风险=错误记忆强化/检索偏见/召回与隐私权限/来源置信度遗忘机制,自学习不等于自动变聪明。
  - 对Cutrans启发:doc.read/write须支持可审计事实与版本;agent记忆=结构化可回滚可遗忘文档/图而非改模型;skill与元思维可作为独立资源按任务加载更新;检索权重可自学习但必须有来源/置信度/撤销/隐私边界。**VCP潜力在把Transformer外的记忆检索工具应用做成持续演化运行时,而非替代Transformer**。

- **Markdown记忆vs VCP记忆与工具调用差异(2026-10-27)**:
  - **Markdown/MEMORY.md=可读可编辑事实与立法文档**,优在人机共读/Git历史/直接修改,弱在无语义索引/图关联/检索自学习;VCP=事实时间线+数据库+向量图索引+元思维库,优在海量经历中找相关事实/关联/路径,并管理来源时间版本权限审计回滚。二者非竞争:Markdown/.cut=人类可读真源或投影,结构化索引/图/向量库=检索计算派生结构。
  - **VCP工具调用与传统agent核心循环相同**(意图→工具→结果→继续),差异在外层:①Jev自然语言编译器把柔性意图映射结构化调用,JevRuntime处理歧义;②安全双轨,高危CLI/代码重构/破坏性文件编辑拦截模糊调用并强制原生ToolCall或拒绝;③JevCallBridgeEXP分布式本地边缘云插件寻址;④通知/占位符追踪/VCPToolRecord异步审计;⑤工具结果写入OneRing事实时间线与记忆库参与后续检索。**传统agent关注一次调用完成,VCP把调用扩成自然语言编译+分布执行+安全治理+异步审计+长期记忆运行时**。
  - 对Cutrans:MEMORY.md继续做宪法与事实源,另建结构化索引;agent工具结果应含结构化结果/资源id/错误/审计,高风险命令必须poll+权限+原生handler,不必照搬VCP全部复杂度。

- **MCP消息格式与生命周期详录(2026-10-27 官方spec核对)**:
  - **MCP=Host/Client/Server间JSON-RPC协议,非模型提示词格式**:请求={jsonrpc:"2.0",id,method,params},成功响应={jsonrpc,id,result},通知无id不期待响应,错误={jsonrpc,id,error:{code,message,data?}}。id用于并发配对,error与result不并存。
  - **生命周期**:client→initialize(params={protocolVersion,capabilities,clientInfo})→server InitializeResult({protocolVersion,capabilities,serverInfo,instructions?})→client notifications/initialized→正式调用。capabilities=功能类别协商不是工具清单,clientInfo/serverInfo=实现元数据。
  - **工具**:tools/list发现{name,description,inputSchema(JSON Schema),可选title/outputSchema/annotations/icons/_meta};tools/call(params={name,arguments})执行。结果通常{content:[{type:"text",text}...],isError?},可有structuredContent与多模态内容。协议error(方法/参数/服务异常)与工具业务失败(result.isError=true)分开。
  - **资源**:resources/list返回{uri,name,description?,mimeType?}等资源,resources/read(params={uri})返回{contents:[{uri,mimeType?,text|blob}]};资源由URI定位,文本用text,二进制blob。resources主要由应用控制,tools主要由模型控制,prompts主要由用户选择。列表分页常用cursor/nextCursor。
  - **Prompts**:prompts/list发现模板,prompts/get返回{description?,messages:[{role,content:{type:"text",text}}]},是工作流/指令模板不是工具结果。
  - **通知**:notifications/cancelled(params={requestId,reason?}),notifications/progress(params={progressToken,progress,total?,message?}),以及initialized/日志/列表变化等可选通知。传输=stdio(子进程stdin/stdout,换行分隔且消息内无裸换行,stderr日志)与Streamable HTTP(POST JSON-RPC,Accept json+SSE,可SSE流,Mcp-Session-Id与MCP-Protocol-Version头,通知常202);允许自定义传输故可进程内。
  - **Cutrans映射**:initialize=运行时能力协商,tools/list=skill/command schema,tools/call→CCB,resources/list=文档素材工程列表,resources/read=doc.read,prompts=任务模板,progress/cancel=后台事件,error/isError=结构化错误。最小实现=initialize/tools/list/tools/call/resources/list/resources/read/ping,sampling/roots/elicitation/新版扩展后加。**协议版本必须协商,不把2025-06-18当永久规范;2026-07-28在连接协商上有更新**。

- **CLI vs MCP本质与收益(2026-10-27)**:
  - **CLI=启动程序传参数读输出的进程调用接口;MCP=发现能力资源按schema调用并在持续会话交换结构化结果的互操作协议**。差别不在JSON外形,而在能力发现/调用/资源/结果/生命周期整体标准化。
  - CLI典型对象=进程/命令/脚本,参数+stdin→stdout/stderr/exit code;MCP对象=tools/resources/prompts,tools/list与resources/list发现工具资源及schema,tools/call结构化arguments,result.content/structuredContent与URI资源,initialize能力协商+持续会话+进度取消通知列表变化。
  - **MCP核心收益**:①agent先知道有什么及参数约束而非猜命令方言;②结果可被机器继续利用(文本/图片/资源引用/结构化内容/业务与协议错误分家);③长任务初始化/进度/取消/通知一等公民;④一个client对多个server,降低N×M适配器。
  - **CLI不被取代**:人/脚本直接调用、一次性小任务、管道批处理文本、低成本本地工具、直接看stdout调试仍最优;给CLI强加schema/发现/URI/结构化结果/进度会话最后也会造出类MCP,故MCP=把这些该标准化的事物做成协议。**CLI优化人怎么跑命令,MCP优化agent怎么发现调用并持续利用能力**。

- **内部CCB不是MCP,但可作MCP子集暴露(2026-10-27)**:
  - **MCP子集=只实现部分协议功能,不是任意内部命令格式都天然是MCP**。内部CCB[opcode/flags/arg]或Command{name,arg}仅是二进制执行与注册分派,无JSON-RPC外层,故不是MCP。
  - 若外层使用`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{...}}`并支持初始化/能力协商/所声明功能的方法,则可称功能较少的MCP server或子集实现。MCP不要求tools/resources/prompts/通知取消全做,但JSON-RPC/生命周期/所声明能力行为必须合规。
  - Cutrans三层=内部CCB原生执行格式/skill生成MCP tools与resources清单/MCP适配器把tools/call映射为CCB。**CCB是内部执行语言,MCP是外部互操作协议;可实现MCP功能子集,不可把CCB直接等同MCP**。

- **agent对外传输协议定案=MCP(2026-10-28 用户拍板)**:
  - **决定**:agent对外传输格式以MCP为准,不再自造协议。链路=agent/外部工具→标准MCP JSON-RPC(initialize/tools/list/tools/call/resources/list/resources/read等)→Cutrans MCP适配器→内部CCB/原生handler。**内部CCB不改名不改格式,ccmd不再承担agent对外传输角色,仅作CLI文本资源**。
  - 收益=工具发现/schema/结构化结果与错误统一,降低私有格式写错风险,保留内部二进制效率。首期最小实现=initialize/tools/list/tools/call/resources/list/resources/read/ping,progress/cancel等后补。**本项为传输标准定案,尚未实现**。

- **三操作台分类的准确边界(2026-10-28 用户复核)**:
  - 作为Cutrans主要操作台分类成立:**GUI=交互式投影(显示/布局/命中/焦点/输入翻译),CLI=显式命令解析执行(文本→二进制Command),Agent=目标驱动规划与反馈执行(任务拆命令并观察结果)**。三者不是应用类型、不互斥、可嵌套、可无界面;可见终端/agent窗口/桌面是能力与具体应用/视图的组合。
  - **MCP不是第四控制台**:它是agent调用工具与资源的传输协议,可承载CLI/agent交互。若称“所有交互方式”则不成立,尚有API/脚本/语音/自动化事件/硬件输入。准确说法=**GUI/CLI/agent是VM三类主要操作台,分别对应图形交互/显式命令交互/目标编排交互,统一归一到二进制命令**。

- **headless GUI与CLI显示路径及主流OS分层(2026-10-28)**:
  - **GUI无界面≠无GUI语义**:可有视图结构/声明实例/布局/焦点/命中/离屏纹理/截图/远程显示,只是没有物理显示设备;但GUI不必都是持久对象树,也可立即模式每帧声明。显示引擎=把结构投影成像素/图片/远程客户端,可只做布局不绘制。
  - **CLI/agent显示不必走app弯路**:文本或结构化结果可直接stdout/file/socket,也可喂给现有GUI文本视图,不必重建完整GUI应用;只有窗口有独立生命周期/打开关闭焦点设置和业务逻辑时,才更像"终端/agent app"路线。CLI/agent可直接被GUI显示,GUI自己有视图结构与呈现器。
  - **主流OS分层**:GUI=窗口系统+显示合成+控件框架+事件模型(Win32/DWM/WPF,Cocoa/AppKit,X11/Wayland+GTK/Qt,Android View/Compose),CLI=进程+TTY/PTY/管道/stdin stdout stderr+shell(bash/cmd/PowerShell/REPL)。终端模拟器(Windows Terminal/xterm/iTerm)是GUI应用负责显示与输入,bash/cmd/PowerShell是CLI进程负责命令解析执行,二者经TTY/PTY/Console连接。
  - **headless GUI普遍存在**:Xvfb虚拟帧缓冲/远程桌面VNC/离屏截图/headless浏览器保留DOM布局点击,说明是否显示到物理屏是部署呈现方式而非GUI概念本身。**GUI无界面可只有结构+交互状态,CLI/agent结果可直接投影也可包装成独立应用,非必须app路线**。

- **领域结构体与显示策略/显示实现分层(2026-10-28 用户解惑)**:
  - 四层地位=领域状态(它是什么)/指令(如何改变)/显示策略(如何呈现)/显示实现(如何变像素与输入响应)。CUI/view model/theme/layout属声明与策略,uikit/GPU/presenter属实现;GUI结构体还含派生呈现状态(选中/展开/滚动/悬停/焦点/动画),不是更丰富领域结构体。
  - **可自带显示提示但不该把策略当真源**:name/icon/unit/visible/editable/preferred_view可内嵌;像素位置/焦点动画/窗口尺寸/主题色/设备排版/按钮点击逻辑不应混入领域结构。内嵌完整策略会导致单一UI绑架/多视图冲突/文档版本与撤销缓存被UI污染/跨应用复用困难/agent被迫理解视觉结构。
  - **GUI=交互式投影能力**:领域状态+显示策略→视图声明/视图模型→显示引擎→像素;输入坐标键盘→命中→命令→新状态。GUI负责输出/输入/更新,不是一张图或一个结构体。可取消独立GUI应用(CLI/agent/API/脚本直接操作),但让结构体自己draw/present只是合并GUI职责而非取消它;单稳定视图可合并,多应用多操作台应保留领域真源→显示策略→显示实现。
  - 例:Gain.value可投成滑块/数字dB输入/不显示仅agent调用,三者合理;若把滑块几何颜色动画写进Gain,则其他读者被迫接受特定UI。**结构体可带"适合怎么展示"的提示,不要带"必须画成什么样"的命令**。

- **显示投影与输入派发双流律+Blender映射(2026-10-28)**:
  - **修正表述**:GUI不是把内存指令投影成点击策略,而是**把点击/输入事件翻译成指令**;按钮action=声明中的命令引用,点击时由输入系统变成实际命令。输出=状态S→显示策略→视图声明V→渲染器→像素;输入=鼠标键盘e→用当前V命中→语义命令c→分派→新状态S'。两流可共享布局几何保证所见即所点,但职责不同。
  - **CLI/agent并非无显示策略**:CLI有文本呈现(历史/提示符/补全/错误格式/颜色/滚动/输出流),agent有任务对话呈现(计划/工具调用/观察/结果/状态),它们没有GUI的空间布局/控件树/点击命中,而非没有显示策略。CLI=文本输入→命令,状态结果→文本/stdout;agent=目标→计划→命令→观察,状态计划结果→对话/任务视图/结构化事件。
  - **实时投影与指令派发必须分责但不必拆进程**:状态是可持续事实,指令是带顺序副作用的意图;渲染可重复不应改业务,同状态可被多视图/agent读取。混流会导致画UI顺手改业务/输入直改画面绕撤销/多视图双写/绘制顺序误当命令顺序。同一帧可按输入处理→命令分派与状态更新→按新状态重投影,输入不得直接改画面。
  - **Blender映射**:RNA=属性路径类型getter setter管状态;Depsgraph=标记变化并重算依赖不画UI;SpaceType/Region/uiBlock/uiBut=各编辑器显示策略与瞬态布局;wmOperator+poll=语义命令与可用性;wmEvent/event system=输入分派到区域控件操作符;RenderResult=独立渲染数据模型。典型链=RNA→各编辑器UI代码→uiBlock/uiBut显示;事件→wmEvent→wmOperator(poll执行)→RNA/文档→Depsgraph更新。**共享RNA/operator/depsgraph不等于共享显示策略,显示与输入不是一回事**。
  - Cutrans接口应拆为present(state)→view/draw-data,translate_input(event)→command,dispatch(command)→new_state,而非draw_and_handle_everything。

- **交互回合/状态生命/连续呈现与事件时间(2026-10-28 用户结晶)**:
  - **交互回合**=输入→命令→结果→结束,通常有成功/失败/取消/超时等完成条件,即使长期未决也有可定义终止态;**状态结构体**=文档/工程/应用状态/选区/记忆,无内在死亡条件,只能删除替换卸载或由生命周期拥有者回收。**长寿与可预判死亡不同:操作可长期未决仍有完成条件,状态无天然终止**。
  - **GUI/CLI/agent可有回合交互但不等于回合制**:GUI点击是回合,GUI动画/视频/实时预览是连续呈现;CLI命令是回合,CLI日志流/REPL/管道可持续;agent问答可回合,agent规划工具执行中间结果可持续。
  - **事件≠变化**:输入事件(点击/按键/网络)≠状态变更(文档/选区/参数)≠输出变化(像素声音动画进度)。周期放光可参数文档不变而引擎tick持续计算亮度,用户语义上无新事件,引擎时间上持续运行;无用户事件不等于无输出变化,无状态变化不等于无呈现过程。
  - **音频播放不是静态值**:静态图片可近似frame=像素缓冲,播放音频=时钟推进→取下一批采样→混音处理→声卡输出,有缓冲连续输出与实时截止。playing/position/queue可存为状态,播放行为本身不可压成静态结构体。静态显示、命令回合、连续播放是不同事物。
  - **Cutrans三层**:命令回合=输入→命令→状态改变→回合结束;状态呈现=状态+显示策略→当前画面/文本/任务视图;连续呈现=引擎tick→时间参数变化→动画/播放/进度/音频。**回合有完成条件,状态无天然死亡;事件可触发状态变化,时间也能驱动输出变化**。

- **自研播放引擎回读:escapement=时钟门禁呈现服务(2026-10-28)**:
  - 回读MEMORY:218/357确认原设想:escapement(擒纵引擎)不是播放器按钮集合,而是**时钟门禁呈现引擎**。三件套=Clock{waitNext/period/now(钟面→帧号)}/Sink(F){present(frame)}/UnderflowPolicy{skip/black_silence/degrade},骨架=睡到钟敲→has(t)门禁→present或欠账→睡下一周期。**play/pause/seek/stop是交互回合,播放是连续时间驱动过程,必须分开**。
  - **has(t)与播放头诚实**:帧身份(stream,t)在声明层可恒在,但字节可能未产/在算/L2/L1;has(t)检查是否已物化到可交付状态,不是检查概念存在。**播放器可等/跳/降级,不得拿不存在帧冒充已准备好,播放头永不撒谎**。
  - **共享骨架不共享政策**:视频呈现队列有保持性可跳帧停帧,音频DAC持续掏空无保持性欠账爆音,故共享时钟门禁/填充骨架但视频vsync与音频DAC时钟/缓冲/欠账分开;当时定音频主钟视频跟随,AV同步=帧号索引算术非独立时钟对齐。
  - **与三操作台分家**:GUI/CLI/agent可发play/pause/seek/stop命令但不拥有播放过程;escapement是独立呈现服务,不是GUI显示策略或CLI/agent命令回合。落地顺序=NullClock/NullSink无头验证骨架→wgpu Surface/miniaudio等真实口岸,不先做大而全播放器。

- **画面/声音的状态-过程对偶修正(2026-10-28)**:
  - **不是画面=状态声音=事件**:图像帧=时刻空间完整状态,音频窗口=时间段采样完整状态;play/pause/seek/stop=控制播放过程的命令事件,视频/音频播放=持续消耗帧/窗口的时间过程。音频文件/窗口/playing/position/queue/deadline均可为状态,只有播放行为本身不是状态。
  - **最小有意义单位差异**:一张静态图像在瞬间即有完整空间结构,一个采样点本身不构成可听声音;声音须时间窗连续采样才有音高节奏音色与正在播放意义。故画面更易被当状态,声音更需过程,但不是绝对本体对立。
  - **硬件/API放大差异**:显示器可保持上一帧→视频可跳帧停帧/按vsync呈现;DAC持续掏空音频缓冲→音频须周期填流,欠账爆音。视频看似状态驱动/音频看似事件时钟驱动,主要是输出约束非本体差异。
  - **Cutrans映射**:(stream,t)标识帧/窗口,has(t)只判物化非存在;escapement以时钟决定呈现,欠账只处理未物化不伪造内容。共享帧与播放抽象,视频音频按各自输出政策分治。**画面和声音都可状态化,播放皆过程;图像瞬间完整,音频须时间窗完整**。

- **声音物理过程与escapement归属(2026-10-28)**:
  - 用户物理直觉成立:声音须持续机械振动(振膜/空气压力波)才能作为正在发生的声音,画面可作为静止光学状态被保持。修正=画面也耗能(显示器/光源/显卡),只是**不一定需要宏观机械运动**;故声音对持续机械过程依赖更强,但不能据此说画面不需能量。
  - **escapement归属=VM共享呈现服务,按需加载非全应用强制**:VM持有输出后端/设备/时钟/播放实例注册表,应用持有自己的播放状态/时间轴/队列/播放头/欠账策略。服务编辑器时间线预览、桌面工程预览/通知媒体、下载器素材预览、agent结果预览及语音视频输出;普通GUI仍走状态→显示策略→渲染器,escapement主要服务时间轴/播放/连续输出。
  - **共享引擎不共享播放头**:EngineId/StreamId独立,防止A视频与桌面预览/通知声音争游标队列。VM统一协调设备后端,每应用/流独立实例;不需播放的应用不加载,避免把escapement变成核心强制依赖。

- **桌面/窗口管理器/任务栏/悬浮窗关系(2026-10-28)**:
  - **桌面=系统壳/工作区投影,非普通应用也非窗口管理器**:VM native host只给OS一个窗口;runtime/surfaces=VM窗口管理器(存在性/矩形/层级/焦点/拖动缩放关闭最小化/输入路由),consoles/gui=桌面壳(背景导航任务栏通知应用切换与全局状态),业务应用只管内容不拥有系统窗口管理权。
  - **任务栏=特殊系统表面非runtime/apps**:读窗口注册表并发surface.focus/minimize/close/open,显示打开应用窗口/后台任务/通知状态;不是普通业务app,近似Explorer/Dock/GNOME Shell。悬浮窗=VM Surface{owner_kind,owner_id,rect,z_order,focus,state},full=主工作区/dock=边缘保留区/floating=自由矩形独立z序,均非HWND,Windows只见一个原生VM窗口。
  - **OS对照**:Windows USER/Win32管窗口对象输入,DWM管合成,Explorer管桌面任务栏开始菜单(任务栏不属DWM);macOS WindowServer管合成,Dock管应用切换任务,Finder管桌面文件;Linux X Server管显示输入,Mutter/KWin/i3等管窗口布局,GNOME/KDE/Xfce管任务栏启动器通知,X无统一任务栏;Wayland compositor常合并显示与WM但桌面壳仍另一层;Android WindowManagerService/SystemUI/Launcher分责。共同结论=**窗口管理/合成与桌面壳分责**。
  - **Cutrans映射**:runtime/host=原生窗口进程,runtime/surfaces=VM WM,consoles/gui=系统桌面壳,apps/editor=业务内容,consoles/cli/agent=dock或floating表面,Taskbar=特殊系统表面读surfaces并发令。桌面可实现特殊root surface但不注册普通业务app。
  - **现状缺口**:当前surfaces只有open/close/draw/full/dock与活动调度,非完整WM;下一补rect/z_order/focus/visibility/resizing/moving/clipping,并升级consoles/gui为root workspace+system chrome+多surfaces的桌面环境。

- **系统GUI与应用GUI交换边界(2026-10-28)**:
  - **主流OS应用一般只交像素/表面与窗口元数据,不交任意GUI结构体**:应用用自己的UI工具包/绘制逻辑→窗口表面/纹理,系统窗口管理器/合成器合成,系统桌面壳自绘任务栏通知开始菜单。系统可读标题/图标/窗口id/缩略图/通知/快捷方式等元数据,但不是完整应用UI树;原因=框架schema差异/版本ABI/安全/样式一致/输入路由。**桌面不是所有应用GUI的总父节点,系统GUI是系统级投影,应用GUI是应用文档投影**。
  - **VM内部可支持双内容形态**:PixelSurface=应用自渲染纹理,DeclarativeSurface=应用提供的稀疏视图声明/CUI/视图模型。后者须schema校验/命名空间与动作权限/布局裁剪焦点输入路由/生命周期约束,由VM共享渲染器解释。**共享渲染器不共享显示策略也不共享UI真源**:系统桌面声明归系统,应用视图声明归应用。
  - **Cutrans接口建议**:SurfaceInfo={id,owner,title,icon,mode,rect,z,focus,visibility}供桌面绘制任务栏/焦点框/窗口管理;ContentProvider=PixelSurface或DeclarativeView供应用提供内容。桌面主要消费SurfaceInfo,不应直接拿编辑器业务GUI树当系统GUI;编辑器经自己的显示策略在分配区域呈现。
  - **桌面与系统GUI关系**:桌面=系统级GUI投影(系统外壳/任务栏/通知/应用切换),应用GUI=应用文档投影,可共用后端不可混策略。OS先例=Explorer/Dock/GNOME Shell均自绘系统壳而非拿应用XAML/NSView/DOM拼桌面。

- **系统GUI定义与组成层级(2026-10-28)**:
  - 系统GUI不能定义为桌面+任务栏+悬浮窗+窗口参数+像素/schema地址探测的总和;那些是**可见产物与实现机制不同层级**。定义=**系统状态模型+窗口/布局管理+显示策略与呈现+输入路由+系统壳服务**。
  - 桌面=系统壳/根工作区投影;任务栏=特殊系统表面负责窗口任务操作;悬浮窗=一种布局形态(rect/z/focus/visibility);窗口分配参数=WM维护的几何与呈现状态非独立本体;像素声明/地址=渲染后端或资源定位实现细节非GUI必备;schema直输/命中=输入翻译与命中测试一部分,不等于整个GUI;schema=可选视图声明格式。
  - **命中测试≠地址/身份解析**:命中=坐标落在哪个声明矩形归输入路由;id/URI/schema指向哪份数据归注册表文档系统不归GUI。系统GUI可headless,也可只用PixelSurface而无schema,故这些探测不是定义必要项。
  - 统一链=系统状态与窗口注册表→WM分配矩形层级焦点→系统显示策略生成桌面/任务栏/悬浮窗→渲染器输出像素→输入经命中翻译为命令。**系统GUI=交互与呈现机制总和,不是零件名清单**。

- **系统级CLI与命令行软件及二进制底座(2026-10-28)**:
  - **系统级CLI=系统提供的命令词汇/参数结构/handler/权限规则,用于操作系统状态与能力**(app.open/doc.read/surface.focus/asset.import/startup.execute),不是可见黑框或终端应用;可被GUI按钮/agent/脚本/其他应用调用,无需可见终端。命令行软件=有生命周期的应用(bash/cmd/PowerShell/本VM CLI dock),有当前输入历史/会话目录/补全别名/显示策略/打开关闭挂起恢复;Shell≠终端,CLI≠Shell,命令行软件≠CLI能力。
  - **底座顺序**:先定义系统二进制状态模型(Document/Application/Surface/Asset/Task/Stream/Session及id/schema/版本/所有权/寿命/持久化)与二进制命令模型(namespace/opcode/args/version/poll/permissions/result/error),再由应用动态注册文档类型与读写器/专用命令schema/handler/poll/显示策略/skill,最后GUI/CLI/agent投影与输入适配。应用扩展不要求核心预先认识所有业务类型。
  - **系统级CLI vs 应用级CLI**:可共用解析器与CCB编码,系统级=app.open/doc.read/surface.focus/asset.import,应用级=editor.export/editor.gain.set/downloader.source.add;编码统一handler分域,系统无需懂editor.export,应用无需懂全部系统状态。若先写GUI/CLI,命令易退化为按钮动作/文本别名并导致三入口语义漂移,故语义先于呈现。
  - **Shell/Terminal/CLI分家**:bash/zsh/cmd/PowerShell=命令解释器应用,Windows Terminal/xterm/iTerm=GUI终端应用,CLI dock=CLI能力+GUI显示的控制台应用。**系统级CLI是能力协议不是app,命令行软件是使用该协议的app,GUI/CLI/agent不是最底层真源,最底层是二进制状态与命令模型**。

- **列表桌面与floating虚拟窗口实装(2026-10-28)**:
  - **调研落地**:Apple Finder list view(列/排序/显示选项),GNOME Files list columns(名称/大小/类型/权限/时间等元数据),Windows Terminal command palette(动作面板),VS Code terminal basics(标签/分组/终端管理),Blender Workspace/Area/Region(共享平铺骨架+类型驱动内容)。据此采用**列表+元数据而非图标墙**,桌面四页=首页/应用/下载/配置,首应用=CLI操作器。
  - **信息架构**:首页=项目/用户/最近任务/快速操作;应用=名称/版本/状态/启动动作;下载=源/仓库/搜索/任务;配置=默认项/启动策略/资源语言。CUI=6007B/4视图/89节点/109字符串,列表项可携带动作,首页/应用条目可直接打开或聚焦。
  - **Workspace/Area/Region解耦**:consoles/gui/workspace.zig提供WorkspaceLayout(side_w/content_x/content_w/body_h/taskbar_h),最大化时内容区居中限宽1080,避免卡片过宽与侧栏遮挡;runtime/surfaces增加Rect/z/focus/is_open与full/dock/floating,虚拟窗口非OS HWND。系统任务栏=特殊表面读surfaces并发open/focus,不是业务应用。
  - **CLI首个floating应用**:标题栏/最近命令/底部输入/清空收起,record记录用户输入与资源加载,默认右下并避开任务栏,支持拖动。focus_next只在首次打开或开始拖动时置位,解决根窗口遮挡与拖动后丢焦点;关闭与重开已验证。
  - **命令联动**:app.open editor/app.close editor保持工作,console.cli.start打开CLI,cli.load继续加载文本资源;CUI action解析支持name+arg。启动CCB按新名编译安装,desktop.cui为6007B。
  - **验收**:Zig build通过,四视图/列表项动作/编辑器打开返回/CLI关闭重开/悬浮窗拖动/最大化居中均实测通过;源码与README留工作区,本条只记设计调研与实装。


- **全屏原生宿主与退出分级(2026-10-28 用户拍板,勘误旧“VM默认最大化非独占全屏”)**:
  - 新默认:Cutrans VM 启动后占满目标显示器并隐藏 Windows 任务栏;原生 VM 窗口不可拖动,VM 内不提供原生关闭/最小化按钮。旧条“默认最大化”被本条取代;窗口化若将来需要只是另一会话策略,不是当前默认。
  - 退出须分三层:`hide/minimize`=隐藏但保留应用,`app.close`=结束一个应用,`vm.exit`=结束整个宿主。三者不得共用语义;高代价 VM 退出归系统命令与确认政策,不能退化成某个应用的关闭。
  - 应用的窗口管理入口归 VM 系统任务栏;Windows 任务栏/任务管理器等 OS 级出口保留作兜底。无 VM 内退出按钮不等于废除操作系统最后的强制退出能力。
  - 当前实现已走 GLFW monitor 全屏路径且原生标题固定 Cutrans VM;不再以最大化冒充用户要求的真全屏。独占/桌面模式无边框全屏是宿主后端策略,不改变 VM 内部模型。

- **虚拟窗口完整性=生命周期/可见性/焦点分家(2026-10-28 用户复核)**:
  - 当前 `Surface{owner,id,mode,rect,z,focus,is_open,callbacks}` 只是窗口登记与绘制雏形,尚非完整 WM:z 未真正排序,焦点不是栈,统一命中/裁剪/移动/缩放/输入路由未完备。局部 ImGui flag 修补不得冒充窗口系统终态。
  - `is_open`(运行)、`is_visible`(参与合成)、`is_active`(当前工作区)、`is_focused`(输入焦点)、`is_minimized`(收到任务栏)是不同状态。切换 full 可见应用默认不关闭前一个;“返回桌面”是聚焦/可见性动作,不等于 `app.close editor`。
  - 启动也应分“启动后台生命周期”与“启动并显示主表面”两种语义;具体 opcode 后定。下载器自启动不应被迫弹窗,CLI/桌面自启动也不改变其应用或操作台分类。
  - WM 统一管 rect/z/focus/visibility/move/resize/clipping/hit-test/输入坐标转换;应用只交 SurfaceInfo 与内容,不直摸原生窗口,也不各自发明盖住系统表面的层级政策。full/dock/floating 是空间策略,不是应用物种。

- **桌面双名拆分=系统壳与可替换桌面应用(2026-10-28 用户拍板,勘误旧“桌面=系统壳非普通应用”)**:
  - 旧说把两个“桌面”合并了。系统壳=空工作区背景/系统任务栏/通知/系统菜单/会话与恢复;桌面应用=首页/应用目录/最近使用/快捷入口/桌面自己的偏好。前者是系统投影,后者可与编辑器/下载器/设置平级。
  - 桌面应用可关闭、可替换、可缺席;无桌面时系统任务栏仍可工作,CLI/agent 也能打开其他应用。当前 `active_full==null` 时直接 `shell.draw()` 仍是默认 root 投影,尚不是真正注册的桌面应用。
  - 应用顶部页签只切换该应用内部视图/工作区;系统任务栏切换应用或 Surface。不要把每个应用都强制复制成“首页/应用/下载/设置”四页,也不要把系统任务栏退化成桌面应用的一组页签。
  - GUI/CLI/agent 仍是三类主要操作台,不因桌面降格为应用而变成业务应用。任务栏列出的是 app|console Surface,不是只列业务 app。
