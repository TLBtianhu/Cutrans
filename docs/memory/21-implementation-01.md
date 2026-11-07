> 历史记录：当前事实以 [现役状态](current.md) 为准；按日期与勘误判断取代关系。个人画像已移除，部署公网地址以文档示例地址替代。

## 二十、VM Runtime 与 VNE 实施台账(2026-11-02)

- **独立 VM Runtime 与窄 C ABI 第一阶段实装**:新增 `vne/launch.zig`(共享启动参数)、`vne/abi.zig` 和 `runtime/native_api.zig`;`cutrans_vm_runtime.dll` 自己拥有 `RuntimeContext`、`std.Io.Threaded` 和分配器,不跨 ABI 传这些 Zig 类型。ABI v1 只传带 `struct_size/abi_version` 的配置、字节切片、opaque handle、整数状态与文档指纹;导出 create/destroy、命令分派、能力状态和指纹,路径须绝对且 resource/data 不同根。直接 ABI 测试证明 doc.open→gain→undo/redo→save 后另一 Runtime 恢复同指纹,并覆盖 ABI 不兼容、未知能力/命令和无效句柄。现有 GUI 仍静态链接 runtime,是过渡宿主;这一阶段没有宣称完整 Java 式 Shell 启动、通用插件 ABI 或安全沙箱。

- **Runtime Pack、Bootstrap 与真实动态装载实装**:新增 `vne/runtime_pack.zig`、`tools/build_runtime_pack.py`、`bootstrap/main.zig` 和 `ports/library.zig`。`runtime-pack.json` 格式 `cutrans-runtime-pack/1`,包含 OS/CPU ABI、入口、vm/host/document schema、7 能力与 8 个文件(DLL、启动清单、示例、来源与许可证)的大小/SHA-256,不含 wgpu,stb 静态进 Runtime。Bootstrap 只从 exe 旁 `runtime/`、开发态固定 `../vm-runtime` 或显式绝对 `--runtime` 加载,先验文件和 ABI,再解析导出并逐项能力握手;支持三种 mode、默认数据根及显式 `--data`,文档保存后另实例恢复并复检 Pack 未变。Zig 0.17 `std.DynLib` 在本 Windows 目标无实现,故 Win32 LoadLibraryW/GetProcAddress/FreeLibrary 收进窄 LibraryPort。JSON 清单曾发生释放源文本后入口悬空,已改 `.alloc_always` 并加所有权回归,未绕过 UTF-8 校验。清单是完整性检查,不是签名或不可信代码隔离。

- **独立 Runtime 验证与分发第一阶段验收**:`build runtime-pack` 产出独立 `zig-out/vm-runtime`;`build verify-runtime` 实际输出 `CUTRANS_RUNTIME_OK abi=windows-x64 capabilities=7 files=8`,便携绝对路径打开和篡改拒绝经 `tools/verify_runtime.py` 固化,篡改在创建 Runtime/写数据前拒绝,独立包与便携 runtime 均无 wgpu/data。`build verify-installer` 真实调用安装态 Bootstrap,输出 `CUTRANS_INSTALLED_RUNTIME_OK dynamic_load=1 restore=1`;Inno 安装前后也执行独立 Runtime 诊断。标准 `build test`、便携 `diag-user`、独立 Runtime 验收和完整安装验收全过。边界:GUI Shell 尚未迁入独立 Runtime,VNE 虚拟根/设备、Runtime 选择/锁定/下载/回滚、跨 OS 实机回放仍未做;不得把“独立 headless Runtime 已打包并验证”写成“完整 VNE 已完成”。

- **VM 驱动桌面 Shell 实装(2026-11-02)**:`consoles/gui/main.zig` 从 EXE main 改为 `cutrans_shell_run`,独立 `cutrans_desktop.dll` 与 `shell-pack.json`(`cutrans-shell-pack/1`,18 文件)承载 zglfw/ImGui/wgpu、CCB/CUI、资源与许可证。`vne/abi.zig` 新增 ShellRequest/ShellConfig/ShellApi;`cutrans_vm_start_shell` 先验证 Shell Pack 和能力,再执行 `doc.open`,通过 LibraryPort 装载桌面,仅传 opaque handle 与有限函数表。`consoles/gui/vm_client.zig` 代理全部文档命令到 VM,以 `document_read/flags/fingerprint` 同步规范文本镜像并重新计算指纹校验;任务 ID 与 pump 也经 ABI,GUI 不再直接恢复/修改 VM 真源。`cutrans_vm.exe` 现为 Bootstrap 薄入口,默认启动 Shell,`--diag`/`--headless` 保留无窗口路径;`runtime/host.zig` 和 runtime 对 zglfw 的依赖已删除。`cli.executeFile` 改走 `Paths.resource_dir`,不再依赖 cwd/DLL 位置。开发态 sibling 和便携 `shell/` 均真实输出文档镜像同步指纹、GPU 就绪、`app.open editor` 和桌面就绪日志,安装态同链通过;Shell 缺失在打开文档/创建数据前拒绝且不回退旧宿主。测试进程在日志确认后终止,不截图、不自动输入,视觉与手感仍未验收。`build test`、`build verify-shell`、`build verify-installer` 均通过,标准 headless Runtime 验收保持通过。边界:这是 VM 驱动的 GUI Shell 与只读文档镜像,不是完整 VNE 虚拟设备/虚拟根、Runtime 管理器或跨 OS 实现。

- **Runtime/Shell 选择锁与显式回滚实装(2026-11-02)**:新增 `vne/runtime_lock.zig`,Session 下 `session/runtime.lock` 格式 `cutrans_runtime_lock=1`,分别记录 Runtime/Shell 的 id/version/abi/manifest_sha256,不含宿主路径。默认 Runtime 在 `LoadLibraryW` 前必须匹配锁,Shell 在创建实例前必须匹配;显式 `--runtime`/`--shell-dir` 才允许迁移或回滚,成功验证后原子写入,缺字段、重复字段、非法身份和损坏输入拒绝。锁是用户选择而非“latest”或“最后成功快照”,清单签名/信任与自动版本发现仍未完成。`tools/verify_runtime.py` 用不同版本和哈希的验证 Pack 实测显式迁移→默认 RuntimeLockMismatch 且锁不变→显式旧 Pack 恢复,输出 `CUTRANS_RUNTIME_LOCK_OK migrate=1 reject_drift=1 rollback=1`;`tools/verify_shell.py` 验证 Runtime+Shell 双重锁与无宿主路径,安装验收新增锁存在与随 Session 保留断言。`build test`、独立 Runtime/Shell 验收和完整安装验收全过;未启动额外 GUI 视觉或输入自动化。

- **VNE 虚拟命名空间、外部授权与 .cut v2 实装(2026-11-02)**:新增 `vne/uri.zig` 和 `vne/mounts.zig`,定义 `runtime/pack/session/cache/temp/external` 根,Pack/Runtime 只读,Session/Cache/Temp 可写,External 由实例内单调 id 授权并区分 read_only/read_write。`RuntimeContext` 持有挂载表,Runtime 配置映射真实根;URI 与授权解析不接触 IO,宿主绝对路径只在 Native 边界出现。`doc.open/write/save` 不再直接接受宿主路径,只接受 VNE URI;`cutrans_vm_grant_external` 和 `cutrans_vm_start_shell` 把显式绝对路径换成 `external://id` 后再执行,撤销后句柄不可解析。`session://exports/...` 可写,Pack 写入和未授权路径拒绝。`.cut` 升级 `version=2`,v1/无版本输入可迁移,v2 图片必须规范为 `pack://`,资源路径参与规范化与指纹;Runtime/Shell Pack 的 `document_schema` 同步为 2。真实诊断验证 v2 文本、Pack 图片 URI、外部授权打开/保存/恢复、Session 导出、Pack 写保护和安装态完整链,输出 `CUTRANS_VNE_URI_OK version=2 host_path=0`。标准 `build test`、`verify-runtime`、`diag-user`、`verify-shell`、`verify-installer` 全过。边界:当前 runtime/pack 根可映射同一资源目录,授权句柄是能力记录不是完整安全沙箱;完整虚拟设备、跨 OS 回放和多版本自动发现仍未实现。

- **VNE 逻辑时钟与确定性回放实装(2026-11-02)**:新增 `vne/clock.zig` 与 `vne/replay.zig`,`RuntimeContext` 持有实例时钟,正常启动使用 `std.Io.Clock.awake` 单调时间,回放使用独立逻辑时间,deinit 清空。日志格式 `cutrans_replay=1` 固定 serial、单调 time_ns、命令、VNE 参数与预期结果,路径只接受 VNE URI,拒绝宿主路径、时间倒退、非法结果和重复/缺失头部。`runtime/replay.zig` 在全新 Session 中逐步推进真实命令和 `document_commands.pump`,对账文档指纹、History 数、Task 状态哈希、事件数和逻辑时间,不接受已有 History/Task 污染。`cutrans_vm_replay` 经 `pack://` 或 `session://` 加载日志,`--replay` 输出 `CUTRANS_REPLAY_OK` 与 Task 哈希。回放素材 `replay.cvr` 已进入两类 Pack(核心 9 文件、Shell 19 文件)。`tools/verify_replay.py` 在两个隔离数据根得到完全相同的文档、History=2、Task=1、time_ns=6000000、Task 哈希和 PNG,另验证结果不符和时间倒退明确失败;安装态输出 `CUTRANS_INSTALLED_REPLAY_OK deterministic=1`。测试辅助函数曾按值返回带自指针的 RuntimeContext 导致导出 not_ready,已改原地初始化,不再移动 Context。标准 `build test`、`verify-runtime`、`verify-shell`、`verify-replay`、`verify-installer` 全过。边界:当前证明隔离实例语义一致,不是跨 OS 实机回放,也没有全部虚拟设备或实时输入录制。

- **VNE FrameSink 与语义 Input 实装(2026-11-02)**:新增 `vne/frame.zig` 统一帧描述,`vne/devices.zig` 提供每实例 FrameSink,记录 generation、present_count、underflow_count 与 last_underflow_t;`vne/input.zig` 提供有界语义 Input Queue,保存 pointer/key/text/focus 与逻辑时间,不包含 HWND、原生扫描码或 OS 句柄。`runtime/escapement.zig` 使用实例 Sink,编辑器预览上报呈现;欠账仍不冒充已物化帧。新增 `runtime/input_replay.zig` 和 `cutrans_input_replay=1` 日志,按序号/时间回放输入并保留文本与焦点,`--replay` 区分命令 `kind=0` 与输入 `kind=1`。`tools/verify_replay.py` 验证 `kind=1 events=5 time_ns=5000000`,输入时间倒退明确拒绝,安装态输出 `CUTRANS_INSTALLED_INPUT_REPLAY_OK kind=1`;核心 Pack 10 文件、Shell Pack 20 文件。标准 `build test`、`verify-replay`、`verify-runtime`、`verify-shell`、`verify-installer` 全过,未截图或注入真实鼠标键盘事件。收尾补充 Input Queue 对 `text_len>64` 的拒绝与回归测试,拒绝后序号/队列状态可继续正常使用。最终复验 `build test`、`diag-user`、`verify-replay`、`verify-runtime`、`verify-shell`、`verify-installer` 和安装器重建全过,输出 `CUTRANS_INPUT_NEGATIVE_OK time_travel=1`。边界:当前是 Clock/FrameSink/Input 第一阶段,Shell 仍走 GLFW→ImGui 输入后端,OS→语义 Input 适配与实时录制未接入;不是全部虚拟设备或跨 OS 实现。

- **Shell 语义 Input 桥接与实时录制实装(2026-11-02)**:
  - `consoles/gui/input_bridge.zig` 在 ImGui 初始化前挂 GLFW 回调,利用官方后端链式调用保留既有 GUI 输入,同时把 pointer/key/text/focus 送入所属 VM。`InputEvent` 是定长 C ABI,VM 统一分配 serial 与单调时间;不传 HWND、原生扫描码或 RuntimeContext。Shell 注入失败会在下一帧显式失败,不静默生成缺失事件的“成功”记录。
  - `runtime/input_recording.zig` 经 `--record-input=<可写 VNE URI>` 显式启动,事件逐条消费并按事件泵批次写入,正常结束 flush/sync。`cutrans_input_replay=2` 保存 action/code/mods、坐标与十六进制 UTF-8 文本,首个事件相对时间为零;v1 继续接受,未指明按钮/按键保留 `code=0`,不擅自当作左键。队列只负责传递,回放也逐条消费,并用 `last_serial` 拒绝非全新 Session 的重复回放。
  - ABI 与 Runtime/Shell/VM Pack 的 `host_api` 升为 2,Pack 仍各为 10/20 文件。`tools/verify_input.py` 用真实分发 DLL 消费并录制 45 条事件,把日志作为独立素材复制到全新数据根后回放,覆盖非法事件、只读 Pack、重复开始/结束、参数冲突和 staging 纯净;输出 `CUTRANS_INPUT_BRIDGE_OK events=45 replay=1 version=2 os_injection=0`。
  - `build test`、`diag-user`、`verify-replay`、`verify-runtime`、`verify-shell`、`verify-input`、`verify-installer` 和安装器重建均有通过记录;安装态输出 `CUTRANS_INSTALLED_INPUT_RECORD_OK events=45 replay=1`。首次安装覆盖更新失败已定位为 Python `ctypes` 持有安装目录 DLL,而不是录制逻辑;探针改独立子进程退出释放后,覆盖更新、卸载保留与关联保护全过,失败测试副本已正常卸载清理。
  - 边界:这是 VM 设备事件记录,不是 OS 输入注入、命令级 GUI 命中回放或视觉验收;当前不含滚轮与 IME 组合状态,坐标不等于控件身份。录制是显式 opt-in 且包含文本,不应用于密码等敏感输入。真实 GUI 手感、跨 OS 实机回放、完整虚拟设备和 Runtime 自动发现仍未完成。

- **FrameSink 候选、提交与欠账分账实装(2026-11-02)**:
  - `vne/devices.zig` 将 `offer` 与 `markSubmitted` 分离,编辑器与 `escapement` 只登记候选,不再把预览调用计作实际呈现。`FrameSink` 记录候选内容指纹/代际、确认提交、内容欠账和输出不可用,`RuntimeContext.devices` 仍是每实例所有权。
  - `FrameReport` 经 `ShellApi.frame_report` 回传 `submitted/underflow/unavailable` 与 `t`;提交携带文档指纹,VM 拒绝陈旧内容和非法回报。`present_count` 只随 VM 确认增长,不用 Shell 本地镜像计数冒充 VM 输出。
  - `consoles/gui/backend.zig` 检查纹理更新、`wgpuSurfaceGetCurrentTexture` 和 `wgpuSurfacePresent` 状态,失败只记 `unavailable`,不发送成功回执。Shell 仅在可见编辑器本轮确实提供候选且 GPU 提交成功时报告 `submitted`;桌面帧不冒充文档欠账。
  - `verify-shell` 必须读到 `CUTRANS_FRAME_PRESENT_OK` 才结束,便携与安装态均实测 generation=1 与当前文档指纹一致,输出 `frame_submit=1`。标准测试、便携诊断、Runtime/Shell、两类回放、输入录制、安装覆盖更新与卸载保留均通过。负向 ABI 测试覆盖陈旧指纹、非法 kind、内容欠账与输出不可用。
  - 边界:当前证明 GPU 提交成功,不是显示器扫描完成、Wayland presentation feedback 或精确 vblank 时间;静态预览 `t=-1`。未注入设备丢失或纹理故障,无头欠账测试不等于完整播放设备。完整虚拟设备、跨 OS 实机回放和 Runtime 自动发现仍未完成。

- **语义动作与可判定输入回放 v3 实装(2026-11-02)**:
  - `runtime/input_actions.zig` 把 `Ctrl+I`、Ctrl+Z、Ctrl+Y 映射到共享的 `editor.invert.add`、`history.undo/redo`,不另造文档编辑逻辑。Shell 只读取 ImGui `getWantTextInput()` 写入 `context.text_input`,该上下文抑制全局动作;未支持的修饰组合不产生命令。实时事件和 v3 回放共用同一分派器。
  - `cutrans_input_replay=3` 记录 baseline 指纹、事件 context、逐动作结果和最终文档指纹/History 游标。`InputRecordReport` 保持事件数与相对时间,`ReplayReport` 新增 `history_cursor`;v1/v2 仍按纯设备事件回放,不被新动作语义 retroactively 改写。基线在第一条输入前固定,空历史撤销记录为 `invalid_state` 而非伪装成功。
  - 当前可判定录制限定默认文档、空 History/Task 和未消费输入,不序列化任意会话基线。回放拒绝 baseline 不符、动作结果篡改、意外动作和最终状态漂移;日志中的命令字符串只用于对账,不是任意命令执行入口。
  - 无头测试覆盖 insert/undo/redo、文本抑制、非法状态、超过队列容量的日志和结果篡改。`verify-input` 经真实 Runtime DLL 录制 50 条合成语义事件,便携与安装态均在全新数据根得到相同 invert 指纹与 `history=1 history_cursor=1`,输出 `CUTRANS_INPUT_ACTION_OK insert=1 undo=1 redo=1 suppressed=1` 和 `CUTRANS_INPUT_BRIDGE_OK events=50 replay=1 version=3 os_injection=0`。
  - 全程未注入或接管真实键盘,GUI 仍走原 GLFW→ImGui 通路;未做视觉、IME 手感或鼠标命中验收。当前不含滚轮、IME 组合状态和指针控件命令,任意 Session 基线、完整播放泵和跨 OS 实机回放仍未完成。

- **Runtime 静态文档播放泵与真实时钟验收(2026-11-02)**:
  - `runtime/playback.zig` 持有每实例 `Stream`、`Engine`、deadline、ready_t/ready_ns;`document_commands.pump` 在导出 pump 前先推进播放,`RuntimeContext.deinit` 释放播放流。`playback.start [frames]` 返回 accepted,`playback.status` 输出状态,`playback.stop` 停止;`PlaybackReport` 提供 active/cursor/frames/offers/underflow/present/last_t,不含宿主路径。
  - 首帧预取完成后才启动首个 deadline,之后同步预取下一帧。到点未物化或 ready_ns 超过 deadline 才 skip 并计 `underflow`,不把迟到的帧冒充已就绪。`FrameSink.offerAt` 记录实际帧号,`markSubmitted` 也保留 t;静态编辑器仍以 `t=-1` 表示无时间轴帧。
  - 实测首版把首帧物化放在首个 deadline 之后,真实时钟使所有帧被判迟到;已改为先预取再计时,不是放宽欠账判定。无头测试覆盖 deadline 前不推进、逐帧完成、帧号和未就绪 skip。`verify-playback` 用真实 DLL 单调时钟完成 `cursor=4 frames=4 offers=4 underflow=0 last_t=3`,并验证自然结束后 stop 拒绝、启动后停止及停止后不推进。
  - 便携与安装态均输出 `CUTRANS_PLAYBACK_OK frames=4 offers=4 underflow=0 restart_stop=1 os_injection=0`;安装覆盖更新、卸载保留、输入动作回放和 GPU 提交验收保持通过。探针在独立子进程退出,不在更新前持有 DLL。
  - 边界:这是静态文档映射为有限帧序列的 Runtime 播放泵,不是视频解码、后台线程、音频输出或 GUI 播放头;目前 `offer` 不等于 GPU 提交,headless 验证 `present_count=0`。Shell 播放状态投影、连续时间轴和真实媒体流仍未完成。

- **Shell 播放头投影与真实帧号提交实装(2026-11-02)**:
  - `vne/playback.zig` 的 View 只复制 `PlaybackReport`,不携带 VM Playback、Stream 或分配器。`current_t=cursor-1`,`currentOffer()` 仅在独立的生产 `last_t` 与当前帧一致时返回有效帧号;编辑器经 `offerAt` 传给 FrameSink,真实 `FrameReport.t` 回到 VM。播放按钮仍走共享命令。
  - `Playback.last_offered_t` 与 `FrameSink.last_t` 分家:静态预览不匹配时把输出候选重置为 -1,不再能抹掉播放生产进度。`ready_ns` 只在 Preview generation 真正改变时更新,缓存命中不把查询时间误当生产时间;否则 GUI 慢帧会把静态内容全部误判为欠账。
  - `--playback=N` 经 Bootstrap ShellRequest/ShellConfig 传递,拒绝非法数量和 headless/diag/replay 冲突;Shell 在桌面与 GPU 就绪后启动,不把初始化时间算入播放欠账。`ShellApi.playback_report` 与 `vm_client.syncPlayback` 每泵同步只读状态。
  - 实测先暴露游标前进但 last_t 停留、静态预览将 last_t 清为 -1、缓存查询时间造成全员欠账三类问题,均修机制而非降低帧率或放宽断言。便携与安装态均输出 `CUTRANS_PLAYBACK_SUBMIT_OK t=3 cursor=4` 和 `CUTRANS_SHELL_PLAYBACK_OK t=3 frame_submit=1 visual_acceptance=not_run`;标准测试、输入回放、真实时钟播放、安装覆盖更新与卸载保留通过。
  - 边界:这是静态文档有限序列的播放头与提交反馈,不是视频、音频、后台解码或 GUI 视觉/手感验收;未自动键盘鼠标。连续媒体时间轴、精确呈现时间和跨 OS 实机回放仍未完成。

- **内存 Asset Workspace 与独立 Content Snapshot 第一阶段实装(2026-11-03)**:
  - Source 是硬盘文件、目录或快照各自拥有的真源;Station 只是内存活动对象与引用,不需要持久化;Projection 必须标明覆盖范围;Snapshot 是显式导出的新 Source。OTTO 只提供 Source 索引/预览/宿主移交,不充当 Cutrans 内存素材真源;不做实时镜像、隐式刷新、哈希不同自动覆盖或把 open 等同于完整解码。Catalog Snapshot 只恢复目录/注释,本轮是包含实际内容或完备声明的 Content Snapshot。
  - `runtime/assets.zig` 接入每实例 `RuntimeContext.assets`,最多 16 个 Asset/64MiB 总字节/16MiB 单文件。Asset 持有实际字节、VNE 来源 URI、SHA-256、会话内单调句柄与租约;相同来源类型、身份与内容哈希复用句柄,内容变化不覆盖活动对象。`asset.open/preview/export/release/list` 已接入共享命令与 GUI VM 转发;当前预览只承诺完整 PNG 解码并报告 `coverage=complete`,不是通用媒体预览。没有 Station 持久层。
  - Windows `ports/file_identity.zig` 以 `GetFileInformationByHandle` 返回 volume serial/file index;Pack 以来源 URI、快照以内容哈希识别。句柄/授权不是跨会话稳定身份或完整安全沙箱。
  - `asset.export` 输出 `cutrans-content-snapshot/1` 的 `snapshot.json + content.bin`,清单包含 byteLength/SHA-256 与 VNE provenance,不含宿主绝对路径。先写内容再原子写清单;重复导出也验证已有 content.bin,冲突目标拒绝。打开独立快照重新校验格式、内容路径、长度、哈希与 snapshot_id;损坏或篡改明确失败。释放原 Asset 后可从该新 Source 恢复完整字节,删除原外部文件也不影响已持有 Asset 的预览。
  - `tools/verify_assets.py` 在独立子进程通过真实分发 Runtime DLL 验证打开/复用/释放/快照恢复/损坏拒绝,并比较实际字节与哈希。`build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`verify-shell`、`verify-installer` 和安装器重建全过;便携与全新安装态均输出 `CUTRANS_ASSET_WORKSPACE_OK open=1 reuse=1 export=1 restore=1 tamper_rejected=1`,安装态另输出 `CUTRANS_INSTALLED_ASSETS_OK snapshot=1 tamper_rejected=1`。真实 PNG 为 91×69/8831B,`coverage=complete`。
  - 默认 Windows x64 构建基线固定 `x86_64_v2`,避免本机指令集泄入分发物;`-Dcpu=native` 只供开发显式覆盖,未在更早 CPU 上实机验证。未截图或注入真实键盘鼠标。当前只有单 Asset 快照 v1 与 PNG 投影;通用素材管理器 UI、目录浏览、通用 Provider、音频、增量同步、外部编辑、多素材依赖图与多 Asset 快照均未实现。本轮未提交、推送或发 Release。

- **编辑器 Asset 面板、Source 插入与 ABI 启动栈实装(2026-11-03)**:
  - `apps/editor/assets_panel.zig` 提供显式加载 Pack 示例、活动素材/租约列表、选择即只读预览与独立插入按钮。预览直接读取 VM 已持有字节,不访问宿主路径或启动另一个 App;插入通过 `editor.asset.insert` 修改共享 Document 与 History。仅 Pack 可直接插入,持久化保存 Pack Source URI 而不是临时句柄;外部文件与快照可预览但拒绝直接插入,不把 external grant 或 session 临时 id 写成持久引用。
  - `vne/assets.zig` 是 Shell 只读投影,Workspace revision 变化才同步 Source URI 等元数据;Asset ABI 提供固定上限列表、Source、完整 PNG 信息与内容字节,Shell 对账 SHA-256、尺寸、media_kind 和 coverage,再创建独立纹理。Asset 与文档纹理使用不同 texture id,释放活动对象后清除陈旧选择;无自动目录扫描或文件监听。
  - Runtime/Shell/VM Pack 的 `host_api` 与 C ABI 升为 3;没有保留旧 ABI 兼容层,符合不稳定期完整覆盖分发。`--assets-demo` 是显式验证入口,调用面板相同的选择/预览/插入函数,不注入鼠标键盘;便携 Shell 已输出 `CUTRANS_SHELL_ASSETS_OK selected=1 preview=91x69 inserted=1 source_uri=1` 和 `CUTRANS_SHELL_ASSETS_VERIFY_OK ... visual_acceptance=not_run`。
  - **栈事故实证与修复**:真实 Python/ctypes 小栈调用恢复 History 时发生栈溢出;完整 History 当前约 1.1MiB,先移入 `history_journal` 的堆恢复状态。进一步对照发现目录文件打开也受调用方栈限制,不能用单纯改绝对路径掩盖;已撤回该无效尝试。`cutrans_vm_create` 现在在 VM 自有、显式 4MiB 栈的短生命周期启动线程中同步构造 Runtime 并 join,不把宿主调用线程的栈预算变成隐含 ABI 要求;不是常驻渲染线程或后台任务泵。真实小栈 DLL 验证通过,未用扩大 Python 测试栈冒充修复。
  - `tools/verify_assets.py` 验证外部/快照拒绝直接插入、Pack 插入、撤销/重做、文档无 `asset://` 句柄、重启后 Station 为空且 Source 文档恢复,以及 ABI 两侧真实 PNG/SHA-256/完整覆盖。便携输出 `CUTRANS_ASSET_WORKSPACE_OK ... insert=1 history=1 source_restart=1`。标准测试与完整构建、便携 DLL 和真实 Shell 已通过。最终 `diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建均通过;安装态输出 `CUTRANS_INSTALLED_ASSET_SHELL_OK selected=1 preview=1 inserted=1 visual_acceptance=not_run` 和 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。未截图、未自动输入,GUI 视觉与手感仍待用户主动验收;目录浏览、外部/快照直接插入、通用 Provider、音频与多 Asset 快照仍未实现。本轮未提交、推送或发 Release。

- **长期目标:真实素材最小创作闭环(2026-11-03 用户授权自主推进)**:
  - 目标=显式外部导入→内存预览→显式受管快照→稳定 Source 插入→共享租约渲染/导出→重启恢复;开发、便携、安装三态的可无头验收全部做掉。GUI 视觉、真实文件弹窗与输入手感只留用户主动验收,不用截图或 OS 输入自动化冒充。
  - **`.cut v3`**:图片可保存 Pack Source,或 `session://` URI+SHA-256 的自包含 Source 引用;Session 缺哈希、临时 external 授权与 v2 中的新语义拒绝。v1/v2 可读并迁移,规范化输出 v3,Source 哈希进入文档指纹,Pack `document_schema=3`。`editor.asset.insert` 接受 Pack/快照,外部 Source 必须先显式导出,不把临时授权当持久引用。
  - **共享租约**:`render.SourceProvider` 统一预览/播放/PNG 导出的 Source 获取与租约释放。Runtime 直接复用 Workspace,Shell 经 `vm_client.sourceProvider` 调用只读 Asset ABI;同一 Asset 多租约,面板 release 不杀渲染使用者,文档指纹变化与 Preview deinit/导出结束释放对应租约。Station 不在重启时恢复,但可从快照重新加载;History 约 1.1MiB 的恢复状态仍由堆持有,Runtime 创建仍用 VM 自有 4MiB 启动线程。
  - **显式外部导入**:新增 `ports/file_dialog.zig` 的真实 `IFileOpenDialog`,只在用户点击时调用,路径过滤可无头测试,实际弹窗不自动验收。`asset_open_external` 在 Native 边界把绝对路径换成只读 external 授权,再加载 Asset;Runtime/Shell/VM Pack 的 `host_api` 与 C ABI 升为 4。外部面板按钮只在显式动作下导出 `session://snapshots/asset-<handle>` 并插入,重复导出仍校验内容、冲突拒绝,不监听原文件、不静默同步。
  - **故障矩阵实证**:`tools/verify_assets.py` 通过真实分发 DLL 完成外部打开/复用/预览、原文件删除、快照插入、撤销重做、invert/resize、PNG 导出、租约释放、重启后 Station 为空但 Source 可导出,以及缺失快照(not_found=13)、损坏快照、SourceContentMismatch。输出 `CUTRANS_ASSET_SOURCE_OK external=1 snapshot=1 export=1 restart=1 missing=1 mismatch=1`;两次 PNG 导出逐字节一致且为 182×138。真实 Shell 的 `--assets-demo` 已覆盖快照 Source 与 GPU 提交。最终 `build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建全部通过;安装态也完成外部快照导出/恢复并输出 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。
  - 当前边界=单 Asset Content Snapshot+PNG;不做目录浏览、实时镜像、自动刷新、音频、多 Asset 依赖图或通用 Provider。文件选择器视觉与操作、面板手感、跨 OS 实现均未宣称完成。未提交、推送或发 Release。

- **可恢复外部授权与硬盘原文件直接插入实装(2026-11-03)**:
  - 新增 `runtime/external_sources.zig` 与 `session/external-sources.json`(`cutrans-external-sources/1`),保存稳定授权 ID、规范路径、volume serial/file index 和最近读取 SHA-256。宿主路径只住用户 Session,不进入 `.cut`/Pack/快照;这不是 Station 持久层,重启只恢复用户授权的加载意图。
  - `vne.mounts` 区分临时 grant 与 persistent grant;Catalog 恢复发生在 History 前。原生文件选择先规范路径并验真实文件身份,同路径重复导入复用记录;缺失只有实际读取时失败,身份变化明确拒绝,损坏目录不覆盖有效文件。`noteRead` 只更新最近读取哈希,不覆盖活动 Asset,目录写失败回滚内存元数据,保存使用原子替换。
  - `.cut v3` 现在允许 Pack、带哈希 Session 快照与带哈希的持久 external 授权 ID;`editor.asset.insert` 对临时 external 仍拒绝,但持久原文件可直接插入。面板同时提供“插入硬盘 Source”和“固定为快照并插入”,满足先工作再决定是否收编,而不是强迫所有素材先复制。
  - 内容改变会创建新 Asset;旧文档哈希不匹配明确失败,只有用户显式再次插入才更新 Source 版本。无租约对象可以释放,旧文档版本不因此改变。缺失原文件、SourceContentMismatch 和损坏授权目录都拒绝,独立快照行为保持。
  - `tools/verify_assets.py` 已验证原文件直接插入、重启后相同 PNG 导出、内容变化与显式版本更新、缺失和损坏目录,输出 `CUTRANS_EXTERNAL_REFERENCE_OK direct=1 restart=1 version=1 missing=1 corrupt_catalog=1`。探针通过 Asset 列表取新句柄,不把句柄编号当稳定 Source 身份。最终 `build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建全部通过,安装态也输出 `CUTRANS_EXTERNAL_REFERENCE_OK direct=1 restart=1 version=1 missing=1 corrupt_catalog=1` 和 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。目录授权/撤销 UI、交互式 relink、目录浏览、音频与通用 Provider 尚未实现。

- **VM 专属资源库与万物经库引用(2026-11-03 用户架构定案,未实装)**:
  - **先分内存与磁盘**:Station 是真实内存对象,不是 OS 路径代理;进入工作区的素材不论大小都是真正导入内存,文件大小影响的是内存预算、装载与解码策略,不能拿“按需解码”否认导入。完整读取字节与完整解码所有帧不是一回事。VM 专属硬盘文件夹是另一层的持久资源库,不是内存 Station、渲染缓存或临时快照。渲染中间结果与缓存继续住内存/可重建缓存体系,不进入资源库,不冒充原生文件。
  - **资源库是系统级真源与目录,不是工程附属物**:逻辑文件夹树由 VM 自己组织,不要求镜像 Windows 目录。库项分引用态与拥有态;拥有态再分“VM 原生创造”和“由外部独立化的副本”,它们所有权相同但来历不同。引用态存外部路径/授权/身份/版本线索,拥有态存全量内容。颜色或明确徽标区分,不能用颜色掩盖缺失、过期或损坏状态。
  - **工程与插件都只引用稳定库项**:文档不再需要决定记录全量还是外部路径;素材与功能插件在加载时都从 VM 资源库解析稳定 id/URI。复制、独立化、外部换路径、刷新与权限处理归资源库,不改工程引用。插件仍是可执行资源,必须另验 ABI、信任与加载权限,入库不等于可信或可执行。
  - **独立化不改 id**:引用态可“从原文件重新载入”(单件或批量,显式方向,不是实时同步),也可“转为库内文件/独立化”,保存当前全量内容后切断外部加载依赖;工程与插件引用不变。独立化是复制状态与所有权改变,不是重连工程。哈希证明版本不授予覆盖权,外部变化/本地编辑冲突须显式选择,旧活动对象不得静默覆盖。
  - **收益**:副本成为普通系统治理动作而非工程编辑;各应用只管创作,素材来源由 VM 系统层统一管理;外部权限可在独立化后撤销;Agent 只面对高信息密度库与只读预览 API,不必遍历 Windows。预览 API 应返回资源 id、媒体类型、覆盖范围、版本/哈希和明确错误,按能力授权,不默认泄露宿主路径、不隐式刷新、不把预览当 open-with。
  - **施工约束**:逻辑树与物理存储布局分离,稳定 id 不经宿主路径推导;重复内容可按哈希去重但引用与租约独立,清理不得删除仍被引用的唯一副本;资源库/授权目录不等于安全沙箱。现行 persistent external 与 Content Snapshot 是过渡零件,目标不是再建一个镜像文件夹或把现有 Session 换名。

- **自动同步归可选第三方插件,原生永不内置(2026-11-03 用户补充立法)**:
  - VM 原生只提供显式动作:加载、读取、比较、重新载入、独立化、导出与权限管理。批量重新载入仍是用户触发的一次动作,不是同步。不得把文件监听、定时扫描、实时镜像、后台刷新或哈希不同自动覆盖做进原生。
  - 机制与触发分家:若未来有人需要自动同步,其实现只能是可选第三方插件,负责触发、范围、方向、冲突策略与日志;可以完全不安装、不实现这类插件,核心浏览/预览/编辑/独立化能力不因此缺失。不要把同步插件改名为原生功能,也不要让核心依赖它保证正确性。
  - 插件不能绕过资源所有权:哈希只证明版本,不能授予覆盖权;活动对象、正在编辑内容与冲突仍需明确状态和用户/授权策略。插件必须受能力范围、资源预算、审计与失败隔离约束,Agent 也不得借预览 API 隐式触发同步。

- **VM 资源库第一阶段实装(2026-11-03)**:
  - 新增 `runtime/resource_library.zig`:`library/catalog.json`(`cutrans-resource-library/1`)保存单调 ID、逻辑名称、reference/owned、external/created/detached 与 SHA-256,`library/content/<id>.bin` 保存全量内容。逻辑树与物理布局分家,真实路径仍只住 `session/external-sources.json`,不进工程/库目录/快照。`next_id` 在保存目录前分配,失败回滚;目录恢复在 History 前完成,损坏目录与内容明确拒绝。
  - 外部导入默认经 `library.importExternal`,同文件同内容复用库项;不同内容须显式 refresh,不重复隐式建副本。`library.detach` 保留 ID、哈希和工程引用,保存独立内容后可删除原文件。`library.create` 从 Asset 字节新建 created 资源,created/detached 不混同。`library.refresh` 仅显式触发,拥有态拒绝从原文件刷新,旧文档哈希必须显式再次插入才更新。无监听、定时扫描或自动同步。
  - `SourceKind.library` 与 `SourceIdentity.library` 接入 Asset,Workspace 按库 ID+哈希复用,内存 Station 仍不持久化;`.cut v3` 接受 library URI+哈希。挂载层显式拒绝把 `library://` 当普通宿主目录,必须经 Catalog 读取。Shell Asset ABI 增加 `library_kind/library_id` 并升 host_api=5,面板显示外部引用/库内拥有徽标、重新载入/独立化/插入操作,revision 使归属变化及时可见。
  - 实证:资源库单元测试覆盖独立化 ID 不变、删除原文件后恢复、显式刷新、created 与损坏拒绝。`tools/verify_assets.py` 覆盖导入去重、detach 后删除原文件、库内创建、重启恢复、拥有态禁止刷新、篡改内容与损坏目录,输出 `CUTRANS_LIBRARY_OK reference=1 detach=1 id_preserved=1 restore=1 create=1 tamper_rejected=1 corrupt_catalog=1`。`--assets-demo` 在真实桌面完成 `library://` 插入和 GPU 提交。PNG 原始字节与重编码导出字节不要求相同,测试分别对账。
  - 最终 `build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建全部通过,安装态也输出 `CUTRANS_LIBRARY_OK reference=1 detach=1 id_preserved=1 restore=1 create=1 tamper_rejected=1 corrupt_catalog=1` 和 `CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。完整逻辑目录浏览、批量操作、统一插件装载、Agent 目录预览 API、音频与通用 Provider 尚未实现;内存 Station、持久资源库与渲染缓存仍分层,未提交/推送/发布。


- **VM 完整平铺资源目录投影与按需预览实装(2026-11-03)**:
  - 新增 `vne/library.zig`:只读 View 复制逻辑 label,保存稳定 id、reference/owned、external/created/detached、内容 SHA-256 与 revision,不借用 VM 内部字符串。当前与 Catalog 同为最多 32 项;这是完整平铺目录投影,不是层级文件夹树。
  - `runtime/resource_library.zig` 的 Catalog 增加独立 revision,append/refresh/detach/restore 成功后递增;首次恢复也会驱动投影。Asset Workspace revision 继续负责活动对象,两者不混用。`RuntimeContext.library_view` 在 Catalog 销毁前释放。
  - ABI 与 Runtime/Shell/VM Pack 的 `host_api` 升为 6。新增 `LibraryEntry/LibraryListReport` 与 `library_list/library_label`,只传目录元数据与名称,不为目录浏览读取全部素材。`vm_client.syncLibrary` 在注册、泵和外部导入后同步,校验 ABI、ID、归属/来历组合、label 长度与内容哈希;真实路径不进入目录 ABI。
  - 面板分为“资源库”与“内存对象”:目录显示全部库项与名称/归属/来历,Station 仍只显示活动 Asset 和租约。未加载项选择时才 `asset.open("library://<id>")`、同步 Asset 并生成 PNG 预览;缺失、原内容变化、库内内容篡改与不支持格式明确失败,不保留陈旧成功预览。未加载的引用项也可显式刷新或独立化;不监听、不自动同步、不批量预载。
  - 实证:真实 DLL 在 `library.create` 后、尚未 `asset.open library://2` 时,目录已有 `created.png`,归属 owned/created,原始哈希正确且 Asset 总数不增加;detach 后 provenance=detached。重启后 Station 为空而两个目录项及 label 保留,内容篡改时目录仍可列、加载仍拒绝。输出 `CUTRANS_LIBRARY_OK reference=1 detach=1 id_preserved=1 restore=1 create=1 catalog_unloaded=1 provenance=1 restart_catalog=1 tamper_rejected=1 corrupt_catalog=1`。
  - 真实 Shell 首次暴露 `openExternal` 未同步目录导致立即独立化失败,已修为导入完成即同步而非等待下一帧;`--assets-demo` 实测未加载 created 项在选择时生成新 Asset、预览、插入 `library://2` 和 GPU 提交,输出 `CUTRANS_LIBRARY_SELECT library=2 loaded_on_demand=1` 与 `CUTRANS_SHELL_ASSETS_OK ... catalog_unloaded=1`。播放探针声明的旧 ABI 5 已统一为 6。
  - 最终 `build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建全部通过,便携和安装态均覆盖目录生命周期,`CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。未截图、未注入真实键盘鼠标,GUI 视觉/手感仍未宣称验收。层级树、批量操作、统一插件装载、Agent 目录预览 API、音频与通用 Provider 尚未实现;本轮未提交、推送或发布。


- **真实资源库真源、虚拟文件夹树与右键治理实装(2026-11-03)**:
  - **用户再次明确两层不能混淆**:Windows 中真实存在、由 VM 管理的资源库目录,是 VM 虚拟文件资源管理器的唯一持久真源;VM 管理器只是投影与操作入口,不能在内存中另存一套目录真相。该结论不否认外部引用文件仍是引用态内容真源,也不把内存 Station 或渲染缓存混进资源库。独立化后,真实库目录同时持有完整内容。
  - `library/catalog.json` 升为 `cutrans-resource-library/2`,物理保存 folders/resources、共享单调 ID、parent_id 与 label;`library/content/<id>.bin` 仍按 ID 保存拥有态内容。虚拟树不镜像 Windows 子文件夹,移动/重命名只改真实 Catalog,不搬物理内容、不改 `library://<id>` 或工程引用。v1 Catalog 可读入根目录,后续写为 v2;外部真实路径仍只住 Session 授权目录。
  - `library.folder.create`、`library.rename`、`library.move` 已同时注册到 Runtime 与 Shell 转发。根目录 parent_id=0;同名标签允许但 ID 不混淆,文件夹 ID 不能作为 Asset 打开。移动拒绝自身/后代循环;恢复检查重复 ID、孤儿、非文件夹父节点和循环,非法 Catalog 明确失败,不静默重建。命令先成功写盘再增加 revision/同步投影。
  - ABI 与 Runtime/Shell/VM Pack 的 `host_api` 升为 7,`LibraryEntry` 新增 parent_id/node_kind,目录最多 32 文件夹+32 资源。`vne/library.zig` 同时投影两种节点,复制名称并验证层级;`library_label` 也能读取文件夹名,不因浏览目录加载素材字节。editor 模块显式依赖 vne,未修改第三方 zgui。
  - 面板显示可展开虚拟树,根目录可右键新建文件夹;节点右键可新建子文件夹、在下方编辑框重命名、选择目标文件夹移动。引用资源右键仍有“从原文件重新载入”和“保存为库内独立副本”;操作沿用共享命令,没有 Windows 目录镜像、文件监听、自动同步或后台刷新。文件夹选择不批量加载,资源选择才按需生成 PNG 预览。
  - 实证:真实 DLL 创建同名文件夹、嵌套父子关系、移动/重命名未加载资源后,Asset 数不增加,文档仍只有 `library://2` 而没有逻辑路径;重启后 Station 为空而树和 label 保留。父类型错误、循环、孤儿、非法逻辑名称、损坏 Catalog 均拒绝。输出 `CUTRANS_LIBRARY_OK ... folders=1 folder_ids=1 rename=1 move=1 cycle_rejected=1 orphan_rejected=1 ...`。真实 Shell 完成创建文件夹→移动未加载资源→重命名→按需加载/插入/GPU 提交,输出 `CUTRANS_SHELL_ASSETS_OK ... catalog_unloaded=1 folder_ops=1`。
  - 最终 `build test`、`diag-user`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback`、`verify-assets`、`verify-shell`、全新 `verify-installer` 与安装器重建全部通过;便携与安装态均覆盖层级恢复,`CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1`。未截图或注入真实鼠标键盘,右键菜单视觉、焦点与手感未宣称验收。文件夹删除、手动排序、批量操作、统一插件装载、Agent 目录预览 API、音频与通用 Provider 尚未实现;本轮未提交、推送或发布。


- **VM 生命周期与 UI 解耦(2026-11-03 用户定案,Habitat 调研)**:
  - 当前分发 Runtime 由启动进程内 DLL 直接持有,关闭入口会销毁运行实例;持久文档/Catalog 并未全部丢失,但 Station、活动设备、任务现场与“系统仍在运行”的连续感消失,也没有可重新附着的控制面。最终 VM 不应跟随任意一次 Shell/薄启动器调用寿命,而应跟随明确的 VM 宿主生命周期。
  - **目标拓扑**:`cutrans_vm.exe` 收敛为薄控制台,提供 start/status/stop/restart/attach;新增当前用户会话内的 `cutrans_vm_host.exe` 长生命周期宿主,拥有 Runtime、资源库、任务、授权、文档与设备;`cutrans_shell.exe` 只是可关闭、可重开的 UI 投影,经本地受控 IPC 附着。开发、便携、安装及隔离验证的数据根和实例身份仍严格分开,不能跨模式误附着。首版不做系统级 Windows Service,不要求管理员权限,不跨用户共享。
  - **关闭 Shell≠停止 VM**:关闭窗口只断开消费者,VM 会话和 Station 可在宿主内继续存在,重开按会话 ID+代际附着。**显式停止 VM**才执行停止新命令→完成或有界取消任务→刷写文档/History/资源目录/任务终态→释放设备与 Runtime→退出宿主;停止应幂等,失败保留诊断,不强杀整个系统并伪装成功。宿主崩溃后的启动先对账,未完成任务标记 interrupted,不盲目续跑或宣称正常终态。
  - **持久化边界不变**:VM 宿主存活时 Station 可自然跨 UI 重连存在,不要求把全部 RAM 持久化;显式停止后 Station、GPU surface 与渲染缓存释放,下次按需重建。长期保留的是文档、资源目录、授权、必要 History、任务承诺与可恢复水位,不是所有内存对象。长期运行不等于永不退出,更不等于后台无约束生产。
  - 现有直接 DLL Runtime 继续用于无头诊断、回放和能力测试;分发态经 Host 承载,不把直接 ABI 硬拉成跨进程协议,IPC 另做版本化会话/命令/投影协议与身份校验。手动验收后续需增加“关 Shell 不关 VM→重开附着”和“显式停 VM→正常恢复”两条,不能仅测文档重启。
  - Habitat 依据:`C:\deepseek直播\tools\win\start-wsl.ps1` 用 keepalive 与独立核心服务维持系统;`C:\deepseek直播\docs\ops\runbook.md` 明确停止 HLS 只停像素生产,Agent/QQ/MC 状态继续;`C:\deepseek直播\docs\ops\shutdown.md` 规定停止决策/出口/适配器/合成→保存→有条件退出 WSL,停不干净不强关并伪装成功;`C:\deepseek直播\docs\design\plugin-and-long-running.md` 强调取消、超时、幂等、水位恢复、局部重启与健康分层。此次在该仓库未找到独立控制台 EXE 源码或二进制,不宣称已读到 EXE 实现。
  - 本记录是架构方向与施工约束,不是 Host/IPC 已实装;当前资源库、UI 和无头 Runtime 工作仍按已有验收证据描述。


- **Habitat 控制台资料补查与前条认知修正(2026-11-03)**:
  - 前条只查了 `C:\deepseek直播`,未覆盖 `C:\deepseek直播-public`;“未找到独立控制台 EXE 源码或二进制”仅限前次检索范围,不能当作整个 Habitat 项目的事实。现已在 public 项目读到 `HabitatConsole.cs`、WinForms 客户端、生命周期模块和 ADR,资料是实际实现而非纯设想。
  - `C:\deepseek直播-public\tools\win\HabitatConsole.cs` 是薄 C# 入口:从 exeDir/注册表解析 client.ps1 和 InstallRoot,启动隐藏 PowerShell 并等待退出,不承载 AgentLoop、插件、推流或长期业务状态。`client.ps1` 提供 WinForms 的启动、停止、刷新、异常恢复和设置中心;状态定时读取,owner token 仅本次内存使用且不回显/不保存。FormClosed 只停止刷新计时器,**关闭控制台窗口不会停止 Habitat**,必须显式点击停止。
  - `lifecycle.psm1` 固定 WSL 命令白名单,启动按 WSL/keepalive→boot→核心服务→健康检查→ready,停止按 stopping→优雅停服务→stopped;public 当前实现**不执行全局 `wsl --shutdown`**,不影响其他 WSL 工作。安装实例按 InstallRoot 使用独立用户/端口/data/config,运行中不重复 boot/拉起 supervisor;停止失败不得写入 stopped。`verify-lifecycle.ps1` 覆盖 WSL 未启动、启停、停止失败不伪报、恢复授权与禁止全局关机;WinForms 只有语法验收,没有自动视觉/输入验收。
  - `docs/adr/ADR-021-windows-lifecycle-recovery.md` 与 `docs/distribution/forms.md` 还明确:Windows 仅保留 HabitatSetup/HabitatConsole 两个 EXE,控制台不是业务宿主,启动不自动开 HLS/RTMP;开发/便携/安装互不覆盖,卸载保留 data/config。旧开发文档中的“有条件退出 WSL”与 public 当前“停止 Habitat 不关整个 WSL”是不同版本/范围,应借鉴**实例有界、明确停机、真实状态和不影响他人**,而非照抄全局关机命令。
  - 对 Cutrans 的校正:薄控制台可以像 HabitatConsole 一样只是入口,独立 VM Host 才是生命周期所有者;关闭控制台/Shell 默认只断开,显式停止才结束 VM;start/status/stop/recovery 必须读真实状态并避免重复启动,不能用进程 PID 冒充就绪。控制台源码已读到,但其 GUI 视觉/手感仍未由本轮验证。
