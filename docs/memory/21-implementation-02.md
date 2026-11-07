> 历史记录：当前事实以 [现役状态](current.md) 为准；按日期与勘误判断取代关系。个人画像已移除，部署公网地址以文档示例地址替代。


- **独立 VM Host 与统一生命周期第一阶段实装(2026-11-03)**:
  - 新增 `cutrans_vm_host.exe`,复用现有 Runtime Pack 校验、LibraryPort、4MiB Runtime 创建与能力握手,在独立进程中持有 Runtime。`cutrans_vm.exe start|status|stop|restart` 是统一控制台;默认旧 GUI/诊断路径不变,未宣称 Shell attach。VM Pack 必需文件由 4 增为 5,Host 随便携与安装包分发。
  - `vne/host_protocol.zig` 定义 `cutrans_vm_host=1` 的 status/stop 请求与状态快照:state/mode/boot_id/last_shutdown_abnormal/abi/document。不同数据根的 SHA-256 映射到不同本机管道,不传宿主路径。`ports/host_control.zig` 只做 Windows 本机消息管道、5 秒 I/O 超时与每数据根排他实例锁,不反向依赖 VM 语义;拒绝 remote clients,但这不是多用户安全沙箱。
  - `host/lifecycle.zig` 持有并原子保存 `session/vm-host.txt`。启动记录 starting,能力握手成功才 ready/running;重复 start 复用 boot_id,第二 Host 被实例锁拒绝。stop 先写 stopping、执行 doc.save,成功才写 stopped;保存失败写 degraded,Host 继续接受诊断和停止重试,不强杀进程。重复 stop 幂等。
  - ProcessPort 新增 Detached:不加入 kill-on-close Job,父进程只关闭自己的句柄,控制台退出不终止 Host。上次未正常停止时,下次 boot 继续递增并标 `last_shutdown_abnormal=1`;正常 stop 清零。启动等待有界且使用单调时钟。Host 运行或状态不可达但未正常停止时,旧进程内 GUI/诊断路径拒绝成为同数据根第二写者,没有拿“附着”当借口允许双写。
  - 实证 `tools/verify_host.py` 使用真实控制台、独立 Host 和管道:首次/重复启动、第二 Host 拒绝、旧入口拒绝、幂等停止、以 documents 路径冲突制造保存失败→degraded→恢复后重试、restart、只终止本次隔离 Host 后异常恢复,以及应用目录哈希不变。输出 `CUTRANS_VM_HOST_VERIFY_OK start=1 idempotent=1 singleton=1 stop=1 stop_failure=1 abnormal_recovery=1 isolated_data=1`。安装版也运行同一探针并输出 `CUTRANS_INSTALLED_HOST_OK lifecycle=1 recovery=1`。
  - 实测曾发现控制台漏用显式 `--data` 而误用默认目录,造成验证实例分离和 staging 污染;已修为显式数据根优先,清理本轮测试目录后以哈希与 staging 断言复核。另修正 restart 探针误读停止响应为最终状态的问题,不放宽任何运行断言。
  - 最终 `build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-host`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建全部通过;`CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。无后台测试进程残留,便携 staging 无 data。
  - 边界:这是独立 Host 生命周期底座,不是完整跨进程 Shell/持续任务泵/正式控制台 UI。默认旧 GUI 仍销毁自己的直接 Runtime;后续必须实现版本化 Shell 会话附着,不能把 start Host 当成 GUI 已接入。未做系统级 Windows Service、跨 OS Host、自动空闲停止或不可信插件隔离。本轮未提交、推送或发布。


- **独立资源管理 App、Shell 附着与真实帧计数实装(2026-11-03)**:
  - **纠正资源管理器耦合**:资源面板从 `apps/editor/assets_panel.zig` 移到 `apps/library/panel.zig`,新增 `apps/library/library.zig` 与 `RuntimeContext.library_state`。`app:library` 与 desktop/editor 平级并进入任务栏,不再由编辑器持有素材状态、文件对话框或资源管理生命周期。VM 资源管理 App 只投影真实 `library/catalog.json`;Windows 文件管理器负责真实目录,**不是两个管理器各有一份真源,也不做镜像或自动同步**。
  - 新增 `cutrans_shell.exe` 与 `cutrans_vm.exe attach`。`shell/protocol.zig` 以固定 32 字节头+独立负载传递 command_result、文档、输入、播放、目录、素材和外部授权,不传指针或 Zig 对象布局。Host 通过原 Runtime ShellApi 执行,Shell 仍复用原 GUI/vm_client;大素材字节与库目录支持按需读取,读写均有超时,单次错误不摧毁 Host。
  - Shell 首次附着用 `shell_handshake` 提交 id/version/abi/manifest SHA-256,Host 校验并原子更新 `runtime.lock`;已有不同锁仍要求显式 `--shell-dir`,不静默换包。外部文档由 Host 授权后打开。关闭 Shell 只断开 UI,Host 保留 Runtime、Station 与 Catalog;重开可恢复同一 boot_id 和文档。默认旧进程内 GUI 保留,不能与 Host 双写。
  - Host 状态快照新增 `present_count`,直接来自 `PlaybackReport`/FrameSink。验收不再依赖同进程日志:`verify-attach` 检查 attach 拉起后 Host 不退出,再做普通 Shell、素材和播放,断言真实提交计数与 boot_id、文档、Shell 锁及正常重启。输出 `CUTRANS_VM_ATTACH_VERIFY_OK attach=4 host_survives=1 assets=1 frame=1 lock=1 restart=1`;安装版输出 `CUTRANS_INSTALLED_ATTACH_OK reattach=1`。
  - **输出生命周期实证**:曾让 Detached 继承控制台标准输出,导致 `subprocess.run` 等待长期 Host 持有的管道 EOF,表现为“启动卡住”。已撤销继承,Detached 只保持独立进程,不让输出句柄寿命绑定控制台。启动等待仍读真实状态,未放宽超时或文档校验。
  - **独立 App 的 Surface 实证**:资源管理 App 打开后成为全屏活动应用,编辑器隐藏,不再产生编辑器候选帧;素材演示结束必须显式 `app.open editor` 切回文档视图才有编辑器帧。新增 `CUTRANS_SHELL_FRAME_OK`,只在真实 GPU 提交且 Host 接受时按新代际记录,旧 Shell 与 attach 均据此/计数验收,不拿 `present_count==1` 的首次日志当唯一证据。
  - 最终 `build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-host`、`verify-attach`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建全部通过;VM Pack 必需文件为 6(Runtime、Host、Shell、wgpu 与示例/启动),旧 C ABI 与文档 schema 不变。便携和安装态均完成附着与素材闭环,`CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。
  - 边界:这是第一阶段可重连 Shell,不是持续后台任务泵或正式控制台 UI;attach 的 `--record-input` 尚未迁移,仍走原无头 Runtime 探针。没有 Windows Service、跨 OS Host、自动同步、不可信插件隔离或视觉/手感自动验收。未提交、推送或发布。


- **NanoUI 独立 vendored 与上游协作纪律(2026-11-03 用户定案)**:
  - NanoUI 更接近“金属、纯净的 VM UI”中的纯净底座:Zig 原生窗口/输入/D3D11/CPU 出口可减少 zgui→C++ ImGui 后端→wgpu-native→GLFW 的 UI 专属链,但金属视觉语言、VM 桌面语义和纯净状态边界仍由 Cutrans 自己负责;Host、ShellApi、RPC、资源库与文档真源不随 UI 重写。
  - 不与 OTTO 共用 `C:\src\nanoui` 工作区。Cutrans 在 `third_party/nanoui/` 持有独立物理源码副本,固定 `TLBtianhu/nanoui` 的 `otto-091` 提交 `8a502ad120730e6b8484cdae5404211cccb88ff2`(声明版本 0.10.0),由 `git archive` 导入,不带 `.git`、缓存、构建输出或本机路径;`VENDOR.md` 记录来源、MIT/第三方 notices 与本地偏差。接入关闭 WebView2,继承 Cutrans target/optimize,现有 zgui/wgpu GUI 暂保留作对照。
  - 通用成熟改进可以反哺 NanoUI,但不频繁提交碎 PR:先在独立副本中完成聚焦测试、CPU/D3D 对照和真实需求验证,再把少量完整通用改动整理成上游 PR;Cutrans 专属桌面、Catalog、Host、资源库和 VM 语义永不塞给 NanoUI。当前未提交任何 NanoUI PR。
  - 已核对当前 fork 的 GPU 边界:普通 UI 确有 D3D11 instancing/HLSL/图集/glass 与 CPU 回退,不只是 CPU 像素 present;但 `gpu.Kind.texture` 的逐帧纹理虽由 API、CPU 和 Metal 支持,当前 Windows D3D11 renderer/HLSL 尚未接入,不能宣称视频帧 GPU 预览已成立。后续可先补通用 D3D11 BGRA/stride 动态纹理上传及 CPU 一致性测试,再按实测考虑共享纹理;不因此武断删除 Cutrans 媒体合成所需 wgpu。
  - OTTO 指南约束仍有效:snapshot 固定 CPU,只能验功能/布局,不能证明 D3D 中文与视觉质量;真实 D3D 需离屏/窗口 readback。VM 内容、预览副本与 UI 图集须分别做峰值预算。下一阶段只先做独立 NanoUI 资源管理 App 垂直切片并附着同一 Host,不一次性全迁编辑器;本轮仅复制与构建接线,不宣称切片或迁移已完成。
  - 构建与实证:`build.zig.zon` 新增本地 `.nanoui` 依赖,`test-nanoui` 使用 vendored 模块并关闭 WebView2,不并入旧 `test` 或分发 Shell。独立副本共 788 个导入文件加 `VENDOR.md`,无 `.git`、符号链接、exe/dll/lib/pdb、嵌套 cache/zig-out。Debug 与 ReleaseSafe 的 `test-nanoui` 均通过 313 项中的 302 项、跳过 11 项,D3D11/CPU readback 对照实际执行;Cutrans 原 `build test` 与默认 `build` 随后通过。测试未增加额外 tracked 产物,也未做视觉/手感验收或提交/推送/PR。


- **OTTO 通用优化的选择性移植(2026-11-03)**:
  - 仍不与 OTTO 共用源码,只把经审查的通用补丁复制进 Cutrans 自己的 vendored NanoUI。当前相对基座仅 7 个源文件有偏差,均与 OTTO 对应实现逐字对账;未搬 OTTO 的设置、媒体、资源库、应用布局或产物。
  - 第一组为 D3D11 RGB 子像素文字:`TLBtianhu/nanoui@a8ae11a789ec2c3cd943557deb67b204ab558b47`、OTTO 集成 `6bfd78ee369b06e4f0fe6b380b074bab440c86bc`,改 `d3d11.zig/d3d11_glue.zig/shader.hlsl/tests_d3d11.zig`。上传 native RGB 字形覆盖、双源混合并保留灰度回退;像素测试 `[115,128,89,255]` 精确命中。现有上游 PR #71 已确认 OPEN,Cutrans 跟踪而不重复开 PR。
  - 第二组为 OTTO `59c6f8bb18755bb89c5a6238262a93cf41355560`(审查于 `cd5f775aed36900ef5cb0b22ac997f2c8b56ab9b`):小物理 em≤16 时 DirectWrite 选 GDI Classic+整数 pen position,大字号保留 Natural;`Window.setSize` 加 `SWP_NOACTIVATE`;改 `dwrite.zig/tests_dwrite.zig/windows/window.zig`。OTTO 的 System.Drawing 对照平均误差改善约 7.71%仅是其实测,不能冒充 Cutrans 视觉验收或逐像素一致。
  - 连续布局不塞入通用库、不照搬音频栏目;后续 Cutrans 资源管理器只借鉴“辅助列连同 gap 连续让位、名称优先、遍历每个整数宽度验证相邻变化≤1px、尺寸不变不重算”的方法。
  - 最终实证:Debug 与 ReleaseSafe `test-nanoui` 均为 304 passed/11 skipped/0 failed(315 总项),D3D11/CPU readback、ClearType 分通道、GDI Classic 模式及整数相位测试实际执行;Cutrans `build test` 与默认 `build` 通过,NanoUI `zig build lines` 为 362 files all within 600 lines,Linux `aarch64-linux-gnu` 测试二进制交叉编译通过。未做 macOS/iOS/Android 构建或 Cutrans 真实 GUI 视觉/手感验收。交叉编译临时输出已清理;除既有 PR #71 外未新开 PR,未 commit/push。


- **NanoUI 独立资源管理 App 垂直切片实装(2026-11-03)**:
  - 新 `cutrans_library_nanoui.exe` 直接附着现有 Host,不再经“EXE→旧 GUI DLL”路径;`bootstrap.runAttached` 统一 Pack 校验、选择锁、握手和 RPC,旧 desktop 仍按原路径装载。Shell Pack 可声明不同入口 EXE/DLL,但仍强制 ABI、schema、相对路径、清单成员与逐文件哈希。`zig-out/nanoui-library/` 有独立 id、12 个载荷文件及完整 NanoUI/第三方 notices;新前端构建图不含 zgui/wgpu,尚未加入便携或安装分发。
  - `shell/mirror.zig` 统一旧 `vm_client` 和新前端的目录/Asset 镜像及 PNG 读取校验,不制造第二套 VM 真源。新 `apps/library/nanoui_model.zig` 只持有镜像、选择和预览,命令均发 Host;`nanoui_view.zig` 为金属色目录树+检查器。原生对话框导入 PNG,预览直接交编码字节并核对 SHA-256、尺寸与完整覆盖,不经过旧纹理后端或额外 RGBA 解码副本。
  - 已实现虚拟目录树、按需载入、完整 PNG 预览、显式刷新、独立化、新建文件夹和中文重命名;预览不等于插入文档或启动其他 App,右键不隐式同步。长名称中间省略,Catalog 保存完整值。移动/删除/批量操作、连续逐像素布局、视频帧 GPU 纹理、完整桌面/编辑器迁移尚未实现。
  - `verify-nanoui-library` 用全新开发数据根启动真实 Host,NanoUI Tester 离屏渲染并以完整右键/点击序列驱动真实命令:导入→完整预览→刷新→独立化→长中文重命名→900×700 重排,再检查 Host 同 boot_id 存活与 Pack 哈希不变。曾发现第三次仅 `secondaryDown` 未命中,改完整 rightClick 后菜单真实可见并完成动作,未以直接调用命令替代 UI 验收。输出 `CUTRANS_NANOUI_LIBRARY_OK attach=1 preview=91x69 refresh=1 detach=1 rename=1 folder=1` 和 `CUTRANS_NANOUI_LIBRARY_VERIFY_OK attach=1 host_survives=1 pack_pure=1`。
  - `test-nanoui-library` 明确依赖真实 EXE 编译。最终完整回归 `build test`、`test-nanoui`、`test-nanoui-library`、`diag-user`、runtime/replay/input/playback/host/attach/assets/shell 全部验收、全新 `verify-installer` 与安装器重建通过;NanoUI 测试保持 304 passed/11 skipped。未显示窗口、未注入真实键鼠、未宣称 Cutrans 视觉/手感已验收。OTTO 交接已更新:#71 APPROVED 且测试打印清理已带入,#72 已开并跟踪,不重复开 PR;本轮未 commit/push。


- **NanoUI 资源移动与真实 D3D 视觉链验收(2026-11-03)**:
  - 新前端补齐 `library.move`:右键可移入根目录或任一合法文件夹,文件夹自身/后代目标被排除;Host 先提交真实 Catalog,再同步投影,稳定 ID、物理内容与工程引用不变。真实 UI 验收已将资源移入“素材”并检查 parent_id。移动/重命名后的镜像指针不再跨同步使用。
  - 长中文名称验证修正为正确三层对账:Catalog 保存完整名称,视图实际生成中间省略文本,900×700 下相关节点均在窗口内;不能把未省略字符串是否直接命中当作布局正确性的判据。输出增加 `move=1 narrow=1`。
  - `ui.zig` 在 Windows 导出 `ui.d3d11.Renderer`,让原生 App 能复用同一真实实例/文字/图片图集做离屏 D3D11 绘制与 readback;该 API 偏差已记录 VENDOR,候选后续通用 PR,不单独频繁提交。
  - `verify-nanoui-library` 现同时将最终 900×700 视图交给真实 D3D11 renderer 和 CPU renderer,检查尺寸一致、两路均非空、平均字节差≤3。实测 `CUTRANS_NANOUI_D3D_OK size=900x700 mean=0.0085 nonblank=1`,不是 CPU snapshot 或双空白假阳性。仍不等于真实窗口视觉、IME 手感或扫描呈现验收;视频逐帧 `ui.texture` 的 D3D 路径尚未实现。


- **D3D11 逐帧 ui.texture 通用实现与 Cutrans 实证(2026-11-03)**:
  - 新 `d3d11_texture.zig` 按帧同步预乘 BGRA,支持合法行 stride、多纹理 slot、尺寸变化释放重建、无效率源清理;`Renderer.draw` 接收帧纹理列表,每个 texture 实例按顺序绑定单独绘制,HLSL 新增 kind=8 采样并保留 UV/圆角/透明度,真实 Windows surface 同步接入。外部 GPU 纹理零拷贝、视频解码与正式媒体管线是后续独立问题。
  - 新增单纹理逐像素、两个不同尺寸/stride 纹理、UV 和尺寸替换对照。初次发现第二张图在 CPU 消失,根因是 CPU raster 旧 guard 要 `stride*height`,错误包含最后一行 padding;正确所需长度=`(height-1)*stride+width*4`。已统一 CPU/D3D 合法性而非放宽阈值。最终 317 项 NanoUI 测试 306 passed/11 skipped,三组动态对照 mean≈0.0732–0.0763,worst≤10。
  - Cutrans 真实 EXE 另跑动态 BGRA/stride/UV 场景:`CUTRANS_NANOUI_D3D_OK size=100x100 mean=0.0447 nonblank=1` 与 `CUTRANS_NANOUI_DYNAMIC_OK bgra=1 stride=1 uv=1`,证明实际链接的 vendored 能力可用;正式资源预览仍保留编码 PNG→`ui.image` 的较省副本路径,未为使用新 API 而额外解码复制。
  - VENDOR 记录通用补丁与 PR 候选,不急于单独频繁开 PR;旧 CPU raster 文件保持 600 行上限。未 commit/push。


- **全项目开发/构建/分发/权限/更新宪法补充(2026-11-03 用户十条规范)**:
  - **源码≠产品,编译产物≠分发形态**:源码只描述项目,用户自行准备编译器/依赖属开发流程;`zig-out` 仅作可删除重建的分发中间物,不写设置、应用缓存、索引、模型、日志、任务历史或秘密。`.zig-cache` 只允许编译器缓存。开发数据独立,正式便携/安装包只能由明确发布流程生成。
  - **便携=自包含而非简单免安装**:必要程序/资源/依赖齐全,不要求先装运行时或执行 bootstrap;默认不需管理员,不注册系统卸载/关联,不静默读写其他形态数据。数据目录必须明确稳定,程序删除与用户数据处置分开,不能随复制/升级隐式清理。
  - **安装=安装器登记而非目录特权**:整机或当前用户安装都成立,安装版不必然需要管理员或 Program Files;权限只匹配实际系统修改范围。开始菜单、卸载项、文件关联、URL 协议、服务/计划任务、PATH/App Paths 是不同机制,特殊目录不会自动赋予这些能力。当前 Cutrans 默认当前用户安装,安装器明确处理开始菜单/卸载/.cut;新单根布局下数据在安装根的 `data/`,旧 `%LOCALAPPDATA%\Cutrans` 仅作显式迁移来源。


- **单一安装根与用户立法(2026-11-04)**:
  - 用户明确否决“应用根+数据根”的方案:安装时只选择一个根,解耦发生在子目录,不是物理路径分散。独立 Runtime、编程语言环境、插件、配置、模型和用户数据同样遵守;独立的是资产与生命周期,不是安装路径。
  - 新布局固定为 `app/`(主程序/启动器/诊断)、`runtime-envs/default/`(Runtime Pack)、`shells/desktop/`(Shell Pack)、`data/`(文档/配置/History/Catalog/Session)。安装记录只保存一个规范化根,子目录由应用固定管理。开发、便携和安装各有独立根,不共享目录、链接或缓存,仍不承诺多版本平行共存。
  - `vne/install_layout.zig` 只在新 Runtime 布局存在时把安装数据解析为根内 `data/`,旧安装继续走旧数据路径以免静默失联;Bootstrap 同时支持新 `runtime-envs/default` 与 `shells/desktop`,旧开发/便携结构不变。
  - 安装器按三类资产分别展开到对应子目录,开始菜单/文件关联/卸载图标均指向 `app/cutrans_vm.exe`。旧双根数据仅当 legacy 存在且新 data 不存在时询问迁移;目标存在绝不合并/覆盖,拒绝则原样保留,静默验收必须显式 `MigrateLegacy=yes` 才移动,测试 legacy 路径独立,不碰真实用户目录。
  - Runtime 激活合同按“完整性→重定位→创建→能力握手→诊断→提交选择”执行,不提前写 active/lock;卸载默认保留 data,未来清理 Runtime/模型/缓存也须按子目录由用户选择,静默卸载不弹交互窗。
  - 本条是用户新立法,取代此前双根表述;README 已同步为单根,安装验收补齐 legacy 标记、默认数据路径、子目录布局与卸载哈希保留。完整实证结果另记,未 commit/push。
  - **卸载与数据保留**:不存在统一 Windows 卸载器,`unins000.exe` 仅是 Inno 默认名;卸载程度由安装器和应用定义。登记项由安装器清理,直接删目录不等于完整卸载;配置、缓存、模型、工程默认保留,删除数据须单独提示与明确授权。后台运行、阻止卸载、继续收集或自动重装与残留配置是不同问题,不混谈。
  - **同机共存≠多版本兼容**:开发、便携、安装与临时验证的程序/数据/权限/生命周期分开,不共享 History、缓存、配置、插件注册或签名凭据。多份安装只有显式多版本设计才允许:独立产品 ID、数据根、默认版本、关联、入口与更新策略;当前 Cutrans 只有一个稳定 AppId,不承诺多个安装版平行共存。
  - **测试/发布/密钥**:写状态的验证只用可安全删除的临时根,不触真实用户数据。发布必须明确版本、环境、大小、哈希、数据迁移/保留/回滚与更新方式;签名私钥和令牌永远在仓库及构建/分发目录之外,密钥/公钥更换须另写旧客户端过渡,不能假定旧验证器自动理解。
  - **本轮 NanoUI 边界实证与修正**:发现 Windows `App.create` 默认会打开应用数据目录 `kv.json`,即使 Cutrans 不使用 KV 也会读取另一形态可能遗留的设置,属于隐式环境混用。已给 NanoUI 增加 `Options.kv`(默认 true 保持其他应用行为),Cutrans 显式 `.kv=false` 仅内存态;条件测试覆盖显式 opt-in、关闭与 headless。VENDOR 已记录该通用候选补丁。此修正与十条宪法共同生效,不因编译测试全绿而免除数据边界审计。
  - **验收**:NanoUI 318 项测试 307 passed/11 skipped,Cutrans `build test`、`test-nanoui-library`、`diag-user`、`verify-nanoui-library` 均通过,动态与 Host 标记不变;全新 `verify-installer` 再次输出 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`,安装器重建成功,363 个 NanoUI 文件均不超 600 行。验证目录仅剩既定的 portable-data/runtime-data,未 commit/push。


- **单根安装实装与全链实证(2026-11-04)**:
  - 安装器预检在临时新布局中通过,legacy 标记在预检失败时原地不动;真实安装后标记迁入 `<root>/data`,输出 `CUTRANS_INSTALL_OK association=Cutrans.Document command=verified single_root=1 migration=1`。默认诊断路径明确为 `<root>/data`,不再有第二个用户数据安装路径;程序入口没有泄漏到根外。
  - 首次迁移步骤曾因 `{param:...}` 默认值直接嵌 `%LOCALAPPDATA%` 解析失败,已改为先用 `{localappdata}` 求值再套参数;异常安装的注册表已清理,最终从全新环境完整通过,未把失败当成功。
  - 完整 `verify-installer` 验证新布局下 Runtime 动态装载、文档往返、回放、输入、播放、Host、Shell 附着、素材、覆盖更新、卸载保留及关联保护。两次卸载均同时校验外部验证数据与根内 data 哈希,legacy 标记和用户数据不变。输出 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。
  - 最终全量回归 `build test`(1067 项)、`test-nanoui`、`test-nanoui-library`、`diag-user`、runtime/replay/input/playback/host/attach/assets/shell、`verify-nanoui-library` 和安装器重建均通过;NanoUI 资源切片动态纹理标记保持 `CUTRANS_NANOUI_DYNAMIC_OK bgra=1 stride=1 uv=1`。验证目录仅剩既定 portable-data/runtime-data,卸载项与 Cutrans ProgID 均无残留,未 commit/push。
  - 边界:本轮完成单根安装与显式迁移,不包含独立 Runtime 下载、自动更新、多版本共存或通用回滚系统;激活提交仍必须先完成真实创建/握手/诊断,不能仅凭解包写 active。


- **卸载 owned Host 与安装路径生命周期收尾(2026-11-04)**:
  - 卸载器在 `usUninstall` 先调用根内 `app/cutrans_vm.exe stop --mode=installed --data=<root>/data`。Inno 卸载阶段不支持 `ExecAsOriginalUser`,已改 `Exec`;停止或保存失败时中止卸载,保留 Runtime、安装登记和重试入口,不删除用户数据。正常卸载真实写入 `state=stopped` 后才继续清理登记。
  - 新验收先制造 documents 保存冲突使 Host degraded,确认卸载非零且 Runtime 仍存在;恢复目录后正常卸载停止 Host,输出 `CUTRANS_HOST_UNINSTALL_OK stop_rejected=1 host_stopped=1 data_preserved=1`。哈希比较仅排除 Host 停止时按设计更新的 vm-host/host.lock/history/session 文件,其余用户文件保持一致,不是把 documents 整体忽略。
  - 非法安装根以“已存在的普通文件”验证,安装必须失败且不改默认目录、不创建文件关联、不移动 legacy,输出 `CUTRANS_INSTALL_PATH_REJECT_OK fallback=0 registry=unchanged`。自定义安装根仍用于覆盖升级。
  - 后续关联保护和 Host 卸载诊断改用各自全新数据根,避免反复诊断触达现有 32 任务上限,不扩大生产容量或清理用户历史。手动 Git Bash 调用 Windows 卸载器统一 `MSYS2_ARG_CONV_EXCL='*'`,避免 `/VERYSILENT` 被转换成 Git 路径。
  - 最终 `verify-installer` 全链通过并再次输出 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`;测试注册表和进程已清理。未 commit/push。


- **Runtime 统一激活与可重定位选择锁实装(2026-11-04)**:
  - 新增 `bootstrap/activation.zig`,集中持有 Runtime Api、已验证 Manifest、Pack 身份、Session 选择锁和 committed 状态;无头诊断、命令/输入回放、旧进程内 GUI 和独立 Host 不再各自决定校验与写锁顺序。统一顺序=完整性/锁检查→从当前根解析 Pack→真实创建与 ABI/能力握手→文档恢复、回放或保存/恢复诊断→复核完整性→原子提交 Runtime 选择。
  - `Activation.commit` 只能提交一次并保留既有 Shell 选择;提交后重读真实锁。Host 在 ready 之前完成 Runtime 恢复、能力握手、指纹诊断和选择提交;旧桌面路径的 Shell 锁延后到 `start_shell` 返回成功之后。**Host 附着路径仍在 shell_handshake 时提交 Shell 身份**,这是下一阶段 NanoUI 正式分发要收尾的边界,不能声称所有 Shell 都已延后到界面启动成功。
  - `tools/verify_runtime.py` 用真实 Runtime 和隔离数据根验证:缺配置文件、错误 OS ABI、损坏 History 导致真实 create 失败、声明不存在能力导致握手失败,四种情况均不改旧锁。首次用 documents 目录冲突只能触发后续 `doc.open` 的 RuntimeCommandFailed,已改用损坏 History 触发构造期恢复失败,不把晚期错误冒充创建失败。
  - 真实移动验收构造 `app/`、`runtime-envs/default/`、`data/` 单根副本,先以 installed 默认路径诊断,再整体移动含空格的根并直接重启;无需重传 `--runtime` 或 `--data`,锁字节不变且不写 `app/data`。重定位=从当前根重新解析同 Pack,不是改写 DLL 或在锁中更新绝对路径。输出 `CUTRANS_RUNTIME_ACTIVATION_OK missing=1 abi=1 create=1 handshake=1 relocate=1`。
  - `build test`、`verify-runtime`、`verify-host`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`test-nanoui-library`、`verify-nanoui-library` 和 `installer` 全过;NanoUI 真实 Host 附着与 D3D 离屏标记保持通过。未弹桌面测试窗口、未注入真实键盘鼠标;本轮未重跑会启动旧 GUI 的完整 `verify-installer`,其上一轮通过记录不回溯冒充新激活实现的 GUI 验收。未 commit/push。
  - 下一步=NanoUI 纳入 `shells/nanoui-library/` 正式单根分发,同时把附着 Shell 的授权预检与最终选择提交分开,前端创建/诊断失败不得改变旧 Shell 选择;默认桌面仍是 desktop。独立 Runtime 下载、资产复用、自动更新与多版本共存仍不提前展开。


- **NanoUI 正式分发与 Shell 两阶段提交实装(2026-11-04)**:
  - Shell RPC 新增 `shell_commit=19`:`shell_handshake` 只检查身份和当前锁,不写选择;`runAttached` 等前端 handler 正常返回后重新校验 Shell 全文件哈希,再发 commit 由 Host 原子写锁并重读。旧进程内 GUI 同样在 `start_shell` 成功返回后复核并提交。启动失败、诊断失败或强制终止都不能留下新 Shell 选择;`verify-shell`/`verify_attach` 的旧断言已改为异常终止只保留 Runtime、不得出现 Shell 锁。
  - `vne/install_layout.zig` 新增 installedRoot/portableRoot:安装态可从 `app/` 或 `shells/<id>/` 找到唯一根,便携态仅在当前目录有 Shell 清单、父目录有 Runtime 清单和启动器时认可便携根。Bootstrap 的 Runtime/Shell/data 解析共用此边界;子目录 NanoUI 不会再写 `shells/nanoui-library/data` 或便携 Pack 内 data,也不靠 cwd/PATH 猜路径。新增两组真实目录单测。
  - 便携构建新增独立 `nanoui-library/` Pack;安装器展开到 `shells/nanoui-library/` 并从 app 拷贝排除该目录,保留自己的 12 文件清单、哈希和许可证,不与 desktop 或 OTTO 共用物理副本。默认 desktop 不变,显式选择 NanoUI 且成功返回后才迁移 Shell 锁。
  - `tools/verify_nanoui_library.py` 同一真实验收覆盖 development、隔离 portable 副本和 installed:坏 PNG 及其合法更新后的清单可通过完整性与 Host 预检,真实解码失败后不得写锁;成功前端才写 `shell_id=nanoui-library`;随后坏候选也不能覆盖已有选择。空选择失败、成功提交、已有选择失败使用三个独立数据根,因为失败导入留下不可预览引用是合法业务状态,不能让它污染后续点击目标。初次合根导致的 TestUnexpectedResult 已按此修正,未放宽断言。
  - 新 `verify-nanoui-portable` 验证默认数据根和 Pack 纯净;新 `verify-installer-headless` 复用真实安装/升级/卸载全链并加入 NanoUI 附着、D3D、动态纹理、失败保护与默认根验收,只跳过旧 ImGui GUI 探针,明确输出 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1 gui=skipped`,不冒充视觉验收。
  - 最终 `build test`、`verify-runtime`、`verify-host`、`test-nanoui-library`、`verify-nanoui-library`、`verify-nanoui-portable`、`installer` 与 `verify-installer-headless` 全过;关键标记=`CUTRANS_NANOUI_SELECTION_OK mode=installed precheck_only_failure=1 commit_after_success=1 default_attach=1` 和 `CUTRANS_INSTALLED_NANOUI_OK attach=1 default_data=1 failed_commit=0 pack_pure=1`。测试注册表、Host 和临时根清理,未注入真实键盘鼠标、未打开旧桌面窗口。默认完整 `verify-installer` 的旧 GUI 路径及更新后的异常终止探针本轮未运行,真实 GUI 视觉/IME/手感仍待人工验收。未 commit/push。
  - 当前边界=NanoUI 是正式可选资源库 Shell,不是整个桌面迁移完成;没有删除/批量素材操作、正式媒体帧接线、独立 Runtime 下载/资产复用、自动更新或多版本共存。后续先评估 Runtime 资产复用,再决定下载器,不扩大本轮分发合同。


- **NanoUI 一键入口与分发最后一公里实装(2026-11-04)**:
  - ConsoleAction 新增 `library` 与 `desktop`:两者先调用既有幂等 startConsole 启动/复用同根 Host,再显式附着对应 Pack。library 从已验证 Shell 清单读取入口 EXE,desktop 继续经 app/cutrans_shell 装载 desktop DLL;高级 `--shell-dir` 仍可覆盖候选。低级 attach 的“Host 必须已运行、默认不显式迁移”行为保持不变,默认桌面不变。
  - `library --assets-demo` 是真实诊断动作而非只拉起进程:等待 Detached 子进程退出,非零返回 `Shell Attach Failed`,成功才报告 `CUTRANS_VM_ATTACH_OK`;普通 library/desktop 附着后立即返回,不关闭 Host。Detached 不继承标准输出,所以父进程标记与退出码、真实锁和 Host 状态共同验收,不伪称捕获了子进程日志。
  - 安装器新增开始菜单“Cutrans 资源库 (NanoUI)”,目标仍为根内 `app/cutrans_vm.exe`,参数固定 `library --mode=installed`;便携版用同一 CLI,不写注册表。README 与 consoles/gui/README 已去掉手动启动 Host 和填写 Pack 绝对路径的日常流程,并保留高级候选诊断入口。
  - `verify_nanoui_library` 新增一键命令场景:开发、隔离便携副本、真实安装版均自动启动 Host、完成无头素材验收并提交 NanoUI;损坏候选经同一命令返回非零且只保留 Runtime 锁。输出 `CUTRANS_NANOUI_COMMAND_OK mode=<形态> auto_host=1 wait_exit=1 failure_passthrough=1`。
  - 最终 `build test`、`verify-nanoui-library`、`verify-nanoui-portable` 和 `verify-installer-headless` 全过;安装验收仍输出 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1 gui=skipped`。未启动 desktop 的真实窗口、未注入真实键鼠;desktop 命令已复用既有附着实现,但正常 GUI 视觉、关闭后的提交和 IME/手感仍需人工验收。本阶段在收尾时统一提交并推送,提交哈希见 git 历史。
  - 下一步建议先由用户通过开始菜单或 `library`/`desktop` 做一次真实体验;代码侧再盘点 Runtime/Shell 实际资产体积与重复项,只有确有共享大资产时才实现本地复用,不提前造通用下载与更新系统。


- **当前用户朴素安装向导实装(2026-11-04)**:
  - 用户以 OTTO 的 NSIS 安装截图为目标,最终确认不是去掉欢迎页,而是经典“欢迎→安装位置→安装”流程。Inno 配置保留欢迎和目录页,新增 `DisableProgramGroupPage=yes`、`DisableReadyPage=yes` 和 `ShowLanguageDialog=no`,接入官方 `ChineseSimplified.isl`;不再出现安装模式、开始菜单文件夹选择和准备安装二次确认。
  - 默认安装根从随模式变化的 `{autopf}\Cutrans` 改为显式 `{localappdata}\Programs\Cutrans`,固定 `PrivilegesRequired=lowest`,移除 `PrivilegesRequiredOverridesAllowed=dialog`。全体用户模式被取消:当前数据固定住安装根 `data/`,普通用户通常不能写 Program Files,不能把一个未验证且权限不一致的选项继续暴露给用户。
  - 移除 `LicenseFile` 产生的许可证点击确认页;MIT 与第三方许可证仍随 Runtime、Shell 和便携目录分发,不是删除法律文本。旧数据迁移询问、安装前诊断失败、完成页诊断错误和卸载停止失败等自定义界面文本同步改为简体中文。
  - `verify_windows_installer.py` 新增静态向导契约:断言默认路径、lowest、中文、保留欢迎/目录、跳过 ready/program-group,并拒绝重新引入安装模式、LicenseFile 或 DisableWelcomePage。实际安装测试不再传 `/CURRENTUSER`,验证固定当前用户登记已足够。静态检查输出 `CUTRANS_INSTALLER_CONTRACT_OK mode=current_user welcome=1 directory=1 ready=0 chinese=1`。
  - 最终安装器重建成功,`verify-installer-headless` 全链通过,仍输出 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1 gui=skipped`。测试继续使用可删除的自定义安装根,没有为验证默认路径写真实 `%LOCALAPPDATA%\Programs\Cutrans`;默认路径是明确的配置事实,真实向导视觉与点击顺序仍需用户打开安装包验收。README 已同步,未 commit/push。


- **真实当前用户默认路径安装验收(2026-11-04)**:
  - 用户指出应允许真实安装并保留注册表,不能永远只测临时目录。此次先确认默认根、legacy、开始菜单目录、卸载登记和相关进程均不存在,仅备份已存在但默认值为空的 `.cut` 键到 `zig-out/verification/real-user-install/cut-extension.reg`,没有读取或导出其他注册表区域。
  - 对最终安装包只传 `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG`,**不传 `/DIR`、`/CURRENTUSER` 或任何数据覆盖参数**。真实落点=`%USERPROFILE%\AppData\Local\Programs\Cutrans`,应用、Runtime、desktop、NanoUI 和根内 data 全部就位;legacy fallback `%LOCALAPPDATA%\Cutrans` 未创建。
  - HKCU `.cut=Cutrans.Document`,open command 指向真实根内 app/cutrans_vm.exe;卸载登记 DisplayName/Version/InstallLocation/UninstallString 均正确,语言为 chinesesimplified。开始菜单两个 `.lnk` 直接位于 Programs 根下而非额外 Cutrans 子目录,已用 WScript.Shell 读取真实目标与参数:Cutrans=`--mode=installed`,资源库=`library --mode=installed`。
  - 在真实安装根执行 `cutrans_vm.exe library --mode=installed --assets-demo`,不传 data,实际启动 Host、完成无头前端并返回 `CUTRANS_VM_ATTACH_OK shell=nanoui_library`;选择锁写入根内 data。随后 stop/status 确认正常停止,无相关进程残留,没有注入输入或打开真实桌面窗口。
  - **本次安装保留给用户直接体验**,没有验收后删除。安装前状态和重置原则记录于 zig-out/verification/real-user-install/before.txt 与 after.txt。将来若用户明确要求恢复新用户状态,先正常卸载,再只删除这次从空状态创建的安装根,必要时恢复备份的 `.cut` 键;不粗暴删除整片 Classes 或用户配置。README/MEMORY 已同步,未 commit/push。


- **单一公开入口与默认 Host＋desktop 实装(2026-11-04)**:
  - 用户实测发现两个 Cutrans 入口及主入口红色报错。复现确认主快捷方式仍走旧进程内 GUI,已有 Host 时实际报 `HostAlreadyRunning`;即使先停 Host,已有 NanoUI 锁还可能继续报 ShellLockMismatch。根因不是缺文件或用户需要删锁,而是公开入口与内部 Shell 选择没有统一。
  - `bootstrap/main.zig` 的默认非 diag/replay/headless 路径改为 runDesktop:启动或复用同根 Host,再显式附着 desktop;旧默认进程内 GUI 分支已删除。desktop 命令与默认入口共用同一实现,open、playback、assets-demo 和 record-input 参数继续转发。无头诊断/回放仍用独立 Runtime 并拒绝第二写者。
  - 独立 Shell 原缺录制 begin/end,统一入口时没有简单砍掉该能力:Shell RPC 新增 input_begin=20、input_end=21,Host 调真实 Runtime 的 cutrans_vm_input_begin/end,前端启动前开始、结束后完成,异常返回也尝试收尾。只读录制目标在打开窗口前失败且不提交 Shell。无头实证 `CUTRANS_DEFAULT_ENTRY_OK attach=1 second_runtime=0 readonly=1`。
  - 安装器只创建一个 `Cutrans.lnk`,参数=`desktop --mode=installed`;`.cut` open command 同步加 desktop。`[InstallDelete]` 清理旧的“Cutrans 资源库 (NanoUI).lnk”。NanoUI EXE 仅作内部候选 Shell 组件,library 保留开发诊断,资源库由桌面内部 VM App 打开,不再把内部技术入口当成第二个产品。
  - 验收同步修正:默认启动复用 Host 的测试用只读录制失败避免开窗;第二写者检查改用 --diag;旧桌面日志探针在需要时先启动 Host再直接读 cutrans_shell 输出。`build test`、verify-input、verify-host、verify-nanoui-library、verify-nanoui-portable 与 verify-installer-headless 全过,安装契约新增 `single_entry=1`。
  - 完整安装回归前先按保护要求正常卸载真实旧版并保留 data,13 个原有数据文件哈希逐项一致;隔离回归全过后再安装修正版。真实开始菜单现有且仅有 `Cutrans.lnk`,旧 NanoUI 链接不存在,目标参数和 .cut command 均含 desktop,原 13 个数据文件均存在。
  - 真实环境用只读录制失败分别执行默认命令和 desktop:两者都复用 boot_id=3 并返回 `CUTRANS_VM_ATTACH_ACCEPTED shell=desktop`,不再出现 HostAlreadyRunning,输出 `CUTRANS_REAL_SINGLE_ENTRY_OK default=1 desktop=1 second_runtime=0 shortcuts=1`。Host 随后正常停止,安装保留供用户点击验收;未注入真实键鼠、未打开真实 GUI 窗口,真实桌面视觉和关闭后 Shell 提交仍需人工确认。未 commit/push。


- **阶段提交与文档同步(2026-11-06)**:
  - 单入口、默认 Host＋desktop、录制 RPC、安装登记与验收修复已提交为 `7e94e04f fix: 统一 Cutrans 启动入口与 Shell 生命周期`(10 个功能文件,147 插入/68 删除)。提交前 `build test` 通过,完整无头安装回归与真实单入口验收沿用本轮已通过结果。
  - README 已同步当前事实:默认启动复用 Host,无头诊断/回放才拒绝第二写者;Windows 安装闭环同时包含隔离安装和真实当前用户默认路径验收;开始菜单只有一个 Cutrans;独立桌面 Shell 的 input_begin/end 不再依赖旧进程内 GUI。consoles/gui/README 同步记录相同边界。
  - 真实安装继续保留在 `%USERPROFILE%\AppData\Local\Programs\Cutrans`,只有一个 `Cutrans.lnk`,原 13 个数据文件保留,Host 正常停止;没有创建 Release,没有上传安装包,本次功能与文档提交均未 push。文档收尾提交哈希见 git 历史。
