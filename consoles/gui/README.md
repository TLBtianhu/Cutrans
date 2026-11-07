# Cutrans VM 系统宿主与操作台

## 当前结构

```text
apps/
  desktop/        可替换的默认桌面 App(最近启用/应用目录)
  editor/         独立编辑器 App 壳
consoles/
  gui/            原生宿主、系统空工作区与系统任务栏
  backend.zig     ImGui/wgpu 初始化、输入后端、帧重配、纹理与呈现边界
  cli/            CLI 能力 + floating 控制台投影
ports/            OS 能力口岸:WindowPort、PathPort、ProcessPort、LibraryPort、FileDialogPort
runtime/
  context.zig     一个 VM 会话拥有的 surfaces/session/command/paths/mounts/devices/clock/playback/assets/config/status/console/document
  documents.zig   最小 .cut 文档、校验、规范化输出与文件往返
  command.zig     共享命令注册与分派
  startup.zig     直接执行 startup.ccb
  apps.zig        业务应用注册、打开/隐藏/关闭
  surfaces.zig    生命周期、可见性、最小化、焦点、矩形与基础 z 层
  session.zig     当前 shell 角色、保护策略与任务栏固定入口
  status.zig      不依赖桌面实例的系统状态文本
uikit/            通用控件、CUI 解释、排版、字体与 productive motion
gpu/              wgpu 与 ImGui 渲染后端
config/
  startup.ccmd    启动策略的可读源码
  startup.ccb     构建期生成的二进制启动清单
```

`apps/desktop` 与 `apps/editor` 是平级业务应用;`consoles/gui` 是系统显示与输入宿主,
不是桌面子页面。`backend.zig` 独占 ImGui 核心、官方 GLFW 输入后端和 wgpu-native 的
初始化/帧重配/纹理/呈现及释放顺序,业务层只接收 DrawData。设备丢失回调只写状态,
backend 停止渲染并明确失败;纹理按 `unused_Frames` 延迟销毁,不伪装成已有自动恢复。
CLI 是 console Surface,不因出现在任务栏就变成业务应用。

## 独立 VM Host（第一阶段已实现）

`cutrans_vm.exe start|status|stop|restart` 新增统一生命周期入口,接受 `--mode` 和可选的绝对
`--data`。`cutrans_vm_host.exe` 复用 Runtime Pack 校验、动态装载与能力握手,在独立进程中
持有 Runtime;ProcessPort 的 Detached 只关闭父进程句柄,不在控制台退出时杀 Host。
`vne/host_protocol.zig` 定义版本化状态快照,`host/lifecycle.zig` 持久化 `session/vm-host.txt`,
`ports/host_control.zig` 只负责带超时的本机消息管道和每数据根实例锁,不反向依赖 VM 语义。
不同数据根映射不同管道;控制台读真实状态,不用 PID 冒充 ready。

重复 start 复用同一 boot_id,重复 stop 幂等。stop 先写 stopping、保存文档,成功才写 stopped;
保存失败进入 degraded 并可重试,不强杀 Host。上次未正常停止时,下次 boot 标记
`last_shutdown_abnormal=1`,boot_id 继续递增。默认启动复用 Host,无头诊断和回放拒绝成为第二写者。
`cutrans_vm.exe attach` 和 `cutrans_shell.exe` 已实现第一阶段 Shell 附着:Shell 回调经
`shell/protocol.zig` 转发给 Host,关闭 Shell 不销毁 Runtime;重开可恢复文档、目录和 Station。
`shell_handshake` 只做身份与锁预检,前端正常返回并复核清单后才由 `shell_commit` 原子更新选择。
`library` 和 `desktop` 自动启动或复用同根 Host,再显式附着对应 Pack,不要求用户填写绝对路径;
`library --assets-demo` 等待真实前端退出并传播失败,普通附着仍立即返回。外部文档由 Host 授权打开。
`input_begin/input_end` 让桌面 Shell 经 Host 开始和结束真实 Runtime 录制,不再依赖旧进程内 GUI。
状态快照包含真实 `present_count`,验收不依赖同进程日志。Detached 不继承控制台标准输出,避免后台进程使命令
等待 EOF。持续后台任务泵与正式控制台 UI 尚未实现。`verify-host` 与 `verify-attach`
覆盖生命周期、附着、素材与播放,安装版也运行同一探针。

## NanoUI 资源管理器（独立 Shell）

`cutrans_library_nanoui.exe` 是内部候选 Shell,不是第二个 Cutrans 产品。它经
`bootstrap.runAttached` 复用 Host 预检、ShellApi 和成功后的提交,但直接运行 NanoUI,不再加载旧 GUI DLL;
其 Pack 有独立 id、入口 EXE、清单哈希和许可证,构建图不含 zgui/wgpu。便携版位于 `nanoui-library/`,
安装版位于 `shells/nanoui-library/`,只通过开发诊断命令 `library` 显式启动,不创建开始菜单入口。
日常默认启动统一为 Host＋desktop,资源库由桌面内部 VM App 打开。
Shell Pack 入口不再固定为 `cutrans_desktop.dll`,但 ABI、schema、相对路径、清单成员与逐文件哈希仍全部校验。

`apps/library/nanoui_model.zig` 只持有目录/Asset 镜像、选择与预览;`nanoui_view.zig` 是金属主题
目录树和检查器。旧 `vm_client` 与新前端共用 `shell/mirror.zig`,不各写一套 ABI 校验。PNG 以编码
字节和完整覆盖信息交给 NanoUI 解码,内容 SHA-256 不符时拒绝预览;不经过旧纹理后端。
目录导入、显式刷新、独立化、移动、新建文件夹和中文重命名都提交真实 Host 命令,不自动同步,不新建 VM。
长名称使用中间省略,Catalog 始终保存完整值。移动只改逻辑父节点,不改稳定 ID、物理内容或工程引用。

`verify-nanoui-library` 在全新开发数据根启动真实 Host,以 NanoUI Tester 的完整右键/点击序列验证
导入、预览、刷新、独立化、移动、长中文重命名和 900×700 重排,再确认 Host 存活与 Pack 纯净;不显示窗口、
不注入真实键鼠。另用 `ui.d3d11.Renderer` 将同一真实视图绘制到离屏 D3D11 纹理并 readback,与 CPU
结果比较平均差异且两路都必须非空,不再只以 CPU snapshot 判断 GPU 路径。底层 `ui.texture` 另支持逐帧
预乘 BGRA、stride、多纹理、UV 和尺寸更新;CPU 对最后一行无 padding 的合法缓冲区也按同一规则验收。
`test-nanoui-library` 额外编译真实 EXE;`verify-nanoui-portable` 和 `verify-installer-headless`
进一步覆盖便携/安装分发、一键 `library` 命令、失败退出传播和默认数据根。真实窗口视觉与手感仍未验收;
正式媒体帧管线、零拷贝 GPU 互操作、删除/批量操作和完整桌面迁移尚未实现。

## 桌面与任务栏

桌面只保留:

- **首页**:真实最近启用与“查看全部应用”导航;没有编辑器/CLI 的重复启动按钮;
- **应用**:全宽注册表目录,按应用/操作台分组,显示真实运行、后台、最小化与当前状态;
  当前 shell 不列为自己的启动入口。

旧下载页、配置页、静态版本/运行状态、假搜索和未接线按钮已删除。下载器与设置
只有在具备真实能力后才注册,不用空壳占位。

系统任务栏独立于桌面,合并两类条目:

- Session 中的固定入口,未运行时也能启动;
- 当前运行的 app/console Surface,后台或最小化时仍保留。

同一固定应用与运行项只出现一次。任务栏支持启动/恢复/聚焦/隐藏,关闭通过条目右键菜单,
保护当前 shell 的普通关闭,并在空间不足时把条目收进“更多”菜单。`workArea` 统一扣除任务栏
区域,桌面内容与 CLI 不再分别猜测底部间距。

任务栏的状态投影分开:`is_open` 决定蓝字与运行指示线,`active_full` 决定浅蓝工作区背景,
`focused` 决定独立焦点框;最小化保留运行标记但降低文字权重。后台运行与未运行不使用
同一种灰色,不再用 `focused or active_full` 合成一个 selected 状态。

## 生命周期语义

- `open`:确保启动并激活;已打开应用不会重复调用启动回调;
- `hide`:退出合成但保留生命周期与任务栏条目;
- `close`:真正调用业务关闭;
- full A → full B:A 保持后台运行,再次激活可切回;
- 关闭或隐藏当前编辑器后,若当前 shell 存在则恢复 shell;隐藏 shell 自身不会立即重开。

`apps/desktop` 只是默认 shell 实现。`session.shell` 先成功打开新 shell 再转移角色,
失败保留旧角色;`shell=none` 的 CLI-only 会话也不强制加载桌面 CUI。

## 启动清单

`startup.ccb` 由 `config/compile_startup.py` 在 build 时生成,runtime 直接执行:

```text
console.cli.start       启动并显示 CLI 控制台
session.shell desktop   打开默认桌面并赋予当前 shell 保护
taskbar.pin app:desktop
taskbar.pin app:editor
taskbar.pin console:cli
font.main ...           默认字体
locale.default ...      默认语言包
```

`console.gui.start` 不再兼任桌面装载;`cutrans_vm.exe` 是 Bootstrap 薄入口,VM 校验并装载 `cutrans_desktop.dll` 作为 GUI Shell。
启动分两段执行:`startup.execute configure` 先设置字体/语言并完成 backend 初始化,
`startup.execute session` 再启动应用、操作台和固定入口。这样应用 open 回调不会早于宿主能力。
`cli.load` 仍可在 CLI 启动后手工加载 `.ccmd` 资源,但示例不再由 startup 自动执行。

## 修改与验证

```bash
# 以下两个编译步骤也已接入 zig build,通常无需单独执行
python apps/desktop/assets/ui/compile_ui.py
python config/compile_startup.py

./tools/zig/zig.exe build
./tools/zig/zig.exe build test
./tools/zig/zig.exe build portable
./tools/zig/zig.exe build diag-user
./tools/zig/zig.exe build runtime-pack
./tools/zig/zig.exe build verify-runtime
./tools/zig/zig.exe build shell-pack
./tools/zig/zig.exe build verify-shell
./tools/zig/zig.exe build verify-replay
./tools/zig/zig.exe build verify-input
./tools/zig/zig.exe build verify-playback
./tools/zig/zig.exe build verify-assets
python tools/bootstrap.py --installer-tool   # 仅在构建安装器前需要
./tools/zig/zig.exe build installer
./tools/zig/zig.exe build verify-installer
./tools/zig/zig.exe build run-portable   # 启动 GUI,由用户主动验收
```

`portable` 在 `zig-out/portable` 生成自包含 staging,不预写用户数据;
`diag-user` 使用独立的 `zig-out/verification/portable-data`,运行真实便携副本并审计
`vm-pack.json`,结束后断言 staging 不含 `data/`。`diag` 则运行开发态诊断。
`installer` 用便携模式恢复的 Inno 7.1.1 编译 `packaging/windows/installer.iss`。
`verify-installer` 使用全新安装、数据和外部文档目录,验证预检失败、安装、绝对路径打开、
语义输入录制回放、播放、Asset 独立快照与篡改拒绝、覆盖更新、现有关联保护及卸载保留,
成功后清理临时目录。已存在 Cutrans
安装或 `.cut` 关联时拒绝测试;不覆盖日常用户数据。输入 ABI 探针在独立子进程运行并退出,
不在覆盖更新前持有安装目录 DLL。便携与安装验收会启动真实桌面并读取启动日志,
但不截图、不自动输入,不把日志当作视觉或手感验收。

## 独立 VM Runtime 第一阶段

`vne/` 持有启动参数、窄 C ABI 和 Runtime Pack 协议,不依赖 GUI。`runtime/native_api.zig`
让 `cutrans_vm_runtime.dll` 自己拥有 `RuntimeContext`、I/O 和分配器;Bootstrap 只见固定版本
配置、字节切片、不透明句柄与整数结果,不传 `RuntimeContext`、`std.Io` 或 Zig 对象布局。
ABI 提供 create/destroy、命令分派、能力握手和文档指纹;直接测试与动态装载均验证保存后
在另一 Runtime 实例恢复。create 在 VM 自有的 4MiB 启动线程中同步构造并 join,不依赖宿主
调用方的栈容量;该线程不是常驻渲染泵。History 恢复本体由 `history_journal.zig` 堆持有,
不把小栈 ABI 调用方压在大对象下。

`runtime-pack.json` 记录 `cutrans-runtime-pack/1`、OS/CPU ABI、入口、三种 schema、能力和
10 个载荷文件的 SHA-256。`bootstrap/main.zig` 先校验清单和文件,再通过 `ports/library.zig`
显式装载;不从 cwd/PATH 猜库。独立核心包含 stb,不包含 wgpu。便携和安装包都携带同一
Runtime,Inno 安装前后也会运行独立 Runtime 诊断。`verify-runtime` 另验证便携绝对路径
打开、篡改拒绝、无 wgpu 和 staging 无用户数据。

桌面 Shell 也已独立为 `cutrans_desktop.dll`:`shell-pack.json` 使用 `cutrans-shell-pack/1`,
记录 20 个载荷文件。VM 先验证 Shell Pack 和能力,再执行 `--open`、装载 Shell 并传入有限
函数表。`consoles/gui/vm_client.zig` 把 GUI 文档命令转发给 VM,以规范文本同步只读镜像,
每次同步校验指纹;dirty/legacy 状态单独传递。GUI 不再直接恢复文档或修改 VM 真源,
也不再拥有全局 `zglfw.Window`。默认 `cutrans_vm.exe` 只是 Bootstrap 薄入口,
`--diag`/`--headless` 保留无窗口路径。`verify-shell` 验证缺失 Shell 拒绝和真实启动日志,
不截图、不自动输入。

`session/runtime.lock` 使用 `cutrans_runtime_lock=1`,记录 Runtime/Shell 的 id、version、abi
和清单 SHA-256,不记录宿主路径。默认包与锁不一致时,Runtime 在装载 DLL 前拒绝,Shell
在创建实例前拒绝;显式 `--runtime`/`--shell-dir` 才允许迁移或回滚,验证后原子更新锁。
`verify-runtime` 实测显式迁移、默认漂移拒绝和显式回滚,`verify-shell` 验证双重身份锁,
安装验收也检查锁存在且随 Session 保留。`vne/clock.zig` 提供实例逻辑时钟,
`vne/replay.zig` 与 `runtime/replay.zig` 执行版本化命令日志,校验预期结果并推进 Task,
对账文档指纹、History、Task 状态哈希、逻辑时间与导出 PNG。`--replay=<VNE URI>` 自动区分
命令 `kind=0` 与语义输入 `kind=1` 日志;后者由 `runtime/input_replay.zig` 消费,不是 OS
输入注入。`verify-replay` 比较两个隔离实例并拒绝结果不符、命令/输入时间倒退。多版本自动发现和
真正跨 OS 回放仍未完成。

`vne/devices.zig` 提供每实例 `FrameSink`,区分预览 `offer`、确认提交、内容欠账和输出不可用;
`vne/input.zig` 提供有界语义 Input Queue,包含逻辑时间、指针、按键、文本和焦点,不包含
HWND、原生扫描码或其他 OS 句柄。队列只负责传递,实时输入与回放均逐条消费;输入历史也纳入
全新 Session 检查。`runtime/escapement.zig` 和编辑器预览只 `offer`,不直接增加呈现次数。

`FrameReport` 经 `ShellApi.frame_report` 回到 VM,提交回执携带文档指纹与 Shell 预览代际,
VM 拒绝陈旧内容;`submitted/underflow/unavailable` 分别记账。backend 检查纹理更新、帧获取
和 `wgpuSurfacePresent` 状态,失败不发送成功回执。`verify-shell` 必须读到 VM 首次确认
`CUTRANS_FRAME_PRESENT_OK` 才结束。该回执证明 GPU 提交成功,不是扫描完成或精确呈现时间;
当前静态预览的 `t=-1`,欠账与输出不可用有无头和 ABI 测试,不注入设备故障冒充实测。

`runtime/playback.zig` 持有每实例的静态文档流、游标、截止时间和就绪帧。首帧预取完成后才启动
首个 deadline,之后同步预取下一帧;缓存命中不刷新物化时间,到点未物化才记 `underflow` 并跳过。
`document_commands.pump` 驱动 `playback.start/status/stop`。`PlaybackReport` 提供游标、帧数、offer、
欠账和独立的生产 `last_t`,不受静态预览候选影响。`vne/playback.zig` 的只读 View 计算当前帧,
编辑器显示静态序列播放头并以 `offerAt` 上报,`--playback=N` 在桌面与 GPU 就绪后启动。
`verify-playback` 验证真实时钟,`verify-shell` 必须读到 `CUTRANS_PLAYBACK_SUBMIT_OK t=3`;
这是有限静态序列及投影,不是视频、音频、后台解码或视觉/手感验收。

`runtime/assets.zig` 提供每实例内存 Asset Workspace:`Source` 保存 VNE URI、可选来源身份与
内容 SHA-256,`Asset` 保存实际字节与会话内句柄/租约,不要求 Station 持久化。`asset.open`
只加载字节并登记来源,不解码成通用媒体对象;`asset.preview` 用该 Asset 自己的字节生成
只读投影,`asset.export` 写出 `snapshot.json + content.bin` 的 Content Snapshot,
`asset.release` 在租约归零时释放内存。相同来源与哈希复用句柄,哈希变化不覆盖活动对象;
重复导出也验证已有内容,损坏或篡改拒绝。

`apps/library/library.zig` 与 `apps/library/panel.zig` 是独立资源管理 App,拥有 `library_state`,
不再依附编辑器。它分为“资源库”与“内存对象”两区:前者按真实 Catalog 的父子关系
显示虚拟文件夹树,后者仍只列活动 Asset 与租约。真实 Windows 目录交给 Windows 文件管理器,
虚拟目录不是第二份真源。未加载库项在选择时才执行 `asset.open("library://<id>")` 并生成
PNG 预览,不在启动时批量加载。缺失、内容变化或损坏保留目录项并显示错误,不生成成功预览。
Pack 示例、原生外部 PNG 选择、显式刷新与独立化仍走共享命令;外部导入后立即同步目录,
不必等待下一帧。
`ports/file_dialog.zig` 只在用户动作下调用 `IFileOpenDialog`,无头测试只验路径过滤,不弹窗;
`asset_open_external` 默认经 `library.importExternal` 生成库内引用,同文件同内容复用,不重复建库项。
真实 `library/catalog.json`(`cutrans-resource-library/2`)是 VM 目录的唯一持久真源,保存共享 ID
空间、folder/resource 节点、parent_id、逻辑名称、reference/owned、external/created/detached 和哈希;
`library/content/<id>.bin` 保存全量内容。VM 树只是投影,不是另一份目录真相,也不镜像 Windows
子文件夹。v1 Catalog 可读入根目录,后续写为 v2。
`library.folder.create/rename/move` 先原子提交 Catalog,再同步投影;移动和重命名不改物理内容、
稳定 ID 或工程引用,并拒绝自身/后代循环。恢复检查重复 ID、孤儿、父类型与循环,不静默修复。
`library.detach` 保留 ID、内容哈希与工程引用,`library.create` 新建 created 资源,`library.refresh`
仅显式触发,旧文档版本不自动替换。资源库不是 Station 或渲染缓存;`library://` 必须经过目录服务,
文件夹 ID 不能作为 Asset 打开。`editor.asset.insert` 接受 Pack、快照、持久 external 和 library 引用。
`vne/library.zig` 是拥有逻辑名称的只读目录投影,Catalog 有独立 revision,不与 Workspace
revision 混用;Shell 经 `library_list/library_label` 读取父子关系、节点类型、归属、来历和 SHA-256。
右键提供新建文件夹、重命名、移动、显式刷新与独立化;重命名在下方编辑框完成。
当前最多 32 个文件夹和 32 个资源;尚未实现删除、手动排序、批量操作或 Agent 目录 API。

`runtime/external_sources.zig` 在 `session/external-sources.json` 保存稳定 ID、规范路径、文件身份和最近读取哈希;
路径只住用户 Session,重启先恢复授权再按需加载,不复活 Station。同路径重复授权复用,身份变化与损坏目录拒绝。
`editor.asset.insert` 对临时 external 仍拒绝,外部文件也可显式固定为快照。
`.cut v3` 图片保存 Source URI/授权 ID+SHA-256,v1/v2 可读并迁移;内容变化不自动覆盖旧版本。

`vne/assets.zig` 只在 Workspace revision 变化时同步只读元数据,Shell 经 Asset ABI 读取内容并核对
SHA-256、尺寸和完整覆盖,不接触宿主路径。`render.SourceProvider` 让预览、播放和导出各自持有
Source 租约:Runtime 直接共享 Workspace,Shell 经 `vm_client.sourceProvider` 使用同一份 VM Asset。
释放面板引用不会杀掉仍在渲染的素材,Preview deinit/文档变更/导出结束会释放对应租约。
`--assets-demo` 覆盖文件夹创建、移动、重命名、未加载库项的目录可见性、选择时加载、
Source 插入和 GPU 提交,不注入输入;没有音频或通用媒体管理器。

`consoles/gui/input_bridge.zig` 在 ImGui 初始化前注册 GLFW 回调,由官方后端继续链式调用,
因此现有 GUI 输入路径不变,VM 同时接收语义事件。ABI 与 Pack 的 `host_api=7`;VM 分配事件序号
和时间,Shell 不传 OS 扫描码,只读取 `getWantTextInput()` 作为文本上下文,不注入键盘事件。
`runtime/input_actions.zig` 将 `Ctrl+I/Ctrl+Z/Ctrl+Y` 映射到共享的 invert.add/history.undo/redo;
文本输入状态抑制全局动作,不支持的修饰组合不产生命令。

`--record-input=<可写 VNE URI>` 启动 `runtime/input_recording.zig`,按事件泵批次写入并在正常结束时
flush/sync。`cutrans_input_replay=3` 保存 action/code/mods/context、坐标、十六进制 UTF-8 文本、
逐动作结果、基线指纹及最终文档指纹/History 游标。v1/v2 保持纯设备回放,旧日志未指明的
按钮/按键用 `code=0` 表示。当前可判定录制要求默认文档、空 History/Task 和未消费输入,
尚未序列化任意会话基线;日志中的命令字符串不会成为任意命令入口。

`verify-input` 通过真实分发 Runtime DLL 消费并录制 50 条事件,覆盖 insert/undo/redo/文本抑制,
把日志复制到全新数据根后校验相同文档指纹和 History 游标,同时验证非法事件、重复开始/结束与
Pack 只读拒绝。它不注入 OS 输入;当前不覆盖滚轮、IME 组合状态或指针控件命中回放,文本录制
也不应用于密码等敏感输入。真实视觉、IME 和鼠标键盘手感仍由用户主动验收。

`apps/desktop/assets/ui/desktop.json` 是静态视图骨架;动态应用目录由
`apps/desktop/catalog.zig` 从注册表投影,首页最近启用由 `recent.zig` 从真实激活顺序投影。
按钮声明支持 primary/secondary/ghost/destructive,旧 CUI kind 0/1/2 保持兼容。

当前生成物为 **240 字节、2 视图、4 节点**。无头测试覆盖 full 切换不销毁、
shell 替换失败保留旧角色、pin 合并、任务栏投影、工作区、最近激活顺序、CLI 坐标与 UTF-8、
动画和 CUI kind 映射。真实视觉与键盘手感由用户主动验收,不使用截图或输入自动化。

## 帧边界与资源所有权

- `RuntimeContext` 原地初始化,拥有 Surface 注册表、Session shell/pin、命令表与队列、
  Task/Event 注册表、VNE 挂载/设备/时钟/播放状态、内存 Asset Workspace、配置、系统状态和 CLI 历史/输入/拖动状态。
  回调接收所属上下文,不再依赖进程级单例。Shell 的 `asset_view` 只持有复制出的只读元数据,
  随 revision 替换并在 Context deinit 释放;Asset 内容按预览请求复制,不外借 VM 内部指针。
  文档与 Asset 预览各自拥有像素和延迟销毁纹理,关闭编辑器先停止上传再释放像素。
  `render.Preview` 通过 SourceProvider 持有各图片节点的租约,求值失败释放新租约,
  成功替换文档或 deinit 才释放旧租约;面板释放与渲染租约互不争用同一所有权。
- backend 也显式接收同一上下文,字体/配置/状态读取路径一致;GPU 回调则使用独立的
  `CallbackState`,不与 VM 会话状态混放。
- UI 绘制阶段的命令进入短队列,下一次生成声明前由 `command.flush()` 统一提交;
  启动阶段仍同步执行。队列复制名字和参数,不保存调用方的栈缓冲区。
- `CommandResult` 区分 `accepted` 与最终执行结果;CLI 历史显示结构化结果代码。
  Task 只允许 queued/running 进入终结态,每次变化写入每会话独立的事件环;
  版本化任务账本原子落盘,恢复时将遗留活跃任务标为 interrupted。PNG 导出经统一
  `document_commands.pump` 执行,支持 `task.cancel` 排队取消和 `task.list` 查询;
  当前仍是协作式单待执行导出,不是后台线程或运行中取消。
- 动画 key 由动画模块复制并拥有,clock/tick 统一推进,不随控件绘制次数改变速度。
- shell/pin 的身份字符串由 Session 驻留;配置只接受已注册的字面资产名。
- CCB 先整体验证再执行,启动只接受 `.ok`,启动失败不会覆盖成“就绪”。
- Renderer 有统一 deinit 和纹理创建回滚,索引段按 4 字节对齐,投影不重复乘 DPI scale。
- 恢复 shell 时保留仍有效的 floating 焦点;任务栏与目录走同一命令入口。

## 最小真实文档与单帧闭环

`runtime/documents.zig` 支持 `version=3` 与 `resolution/fps/testsrc/gain/invert/over/image/resize`
的最小 `.cut` 子集,不是完整剪辑语言。v1/v2 和无版本输入按兼容规则读取,保存统一迁移到 v3;
未知、重复版本及 v2 中新 Source 语义拒绝。Session 图片必须带 SHA-256,不接受临时 external 授权;
`doc.open/read/write/save` 与 `editor.gain.set` 共用 RuntimeContext.document;
`runtime/documents.zig` 以 `Birth{inspire,transform,aggregate}` 区分节点来历,
聚合输入使用带 `x/y/opacity/t` 的 `AggIn`,文档以显式 `output_id` 选择求值根;
输出 id 与全部聚合参数进入规范化文本和固定宽度小端指纹,未写 `output=` 的旧文档默认最后节点。`runtime/render.zig` 按需逐节点装配并复用中间帧,
连续 gain/invert 融合执行;over 暂保留标量 f32 兼容路径,避免中间量化改变像素。
resize 按输出坐标映射输入并检查最终制式。`runtime/stream.zig` 把静态文档映射为有限帧序列,
`get` 按需物化,`has` 只查询当前工作帧是否已就绪。`runtime/escapement.zig` 提供
Clock/Sink/UnderflowPolicy 骨架,先查 has 再 offer 或 skip,不拿未物化帧冒充当前帧;
`runtime/playback.zig` 按 deadline 同步预取并推进该骨架,播放头已只读投影到编辑器;真实媒体流仍未实现。
编辑器经 ImGui 用户纹理显示真实像素,
尺寸变化先销毁旧纹理
再于下一帧创建,不在绘制命令仍引用旧资源时重建。
`doc.save` 输出规范化文本,可重新打开验证。无参数 `doc.open` 从 exe 只读资源目录
打开 `assets/examples/minimal.cut`;无参数 `doc.save` 写入独立数据根的
`documents/session.cut`。显式 `doc.open`/`doc.save` 只接受 VNE URI;Pack 只读,
Session/Cache/Temp 可写,External 必须经授权句柄。文件关联绝对路径只在 Native 边界换成
`external://<id>` 后使用,授权撤销即失效。启动参数支持 `--open <path>` 和 `--open=<path>`,
重复或空参数拒绝。VM 在装载 Shell 前完成显式打开,session 启动后激活 editor。诊断器以
`CUTRANS_OPEN_OK` 报告授权后的真实打开、保存和重读。开发态数据根为工作目录下的
`.cutrans-dev`(已 gitignore),便携版为 exe 旁 `data`,安装版为用户数据目录。`runtime/document_commands.zig`
统一注册文档命令,VM 与诊断器共享 handler;除 `editor.gain.set` 外,现支持
`editor.invert.add [in]`、`editor.over.add bottom top [opacity]` 和
`editor.over.opacity.set id opacity`、`editor.image.open`、`editor.export.png` 和
`editor.resize.add in width height`,以及 `history.undo/redo`。History 使用增量日志:
字段记录前后值,add 撤销删除节点并恢复输出,整文档替换单独记录,不保存像素帧;
`documents/history.txt` 原子保存声明快照、指纹和游标,损坏文件不会覆盖有效状态。
诊断通过真实命令创建四节点 DAG,并导入 libpng 官方
`pngtest.png`,验证 invert、最近邻 91×69→182×138、保存、重开、导出及再解码;
另验证排队取消、遗留任务 interrupted 和新会话中的 History undo/redo。
素材来源与哈希见 `assets/examples/SOURCES.md`,默认导出为数据根 `exports/output.png`。
完整流协议、后台渲染和运行中取消尚未实现。

## 参考

- [Apple Dock settings](https://support.apple.com/en-lamr/guide/mac-help/mchlp1119/26/mac/26):运行指示与最近应用;
- [GNOME Design Principles](https://developer.gnome.org/hig/principles.html):简单与渐进披露;
- [Windows Motion](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/motion):连续、直接、与入口一致的运动;
- [Carbon Motion](https://carbondesignsystem.com/elements/motion/overview/):productive 与 expressive 的分界;
- Blender Workspace/Area/Region:共享布局骨架,应用各自维护显示策略。
