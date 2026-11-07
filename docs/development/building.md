# 构建与验证

本页仅适用于GitHub源码，不适用于已解压的便携目录。运行产品不需要开发工具；开发入口位于源码的[tools/dev.ps1](../../tools/dev.ps1)。

## 固定环境与恢复

需要 Windows x64、Python 3 和网络连接。克隆后先恢复固定版本的完整工具链与第三方二进制：

```powershell
git clone -c core.longpaths=true https://github.com/TLBtianhu/Cutrans.git
cd Cutrans
.\tools\dev.ps1 bootstrap
```

`tools/bootstrap.py` 只使用 Python 标准库，按固定 URL 与 SHA-256 校验并恢复：

- Zig `0.17.0`：官方 `zig-x86_64-windows-0.17.0.zip`，编译器与 `lib/` 从同一校验过的压缩包恢复到 `tools/zig/`，整套工具链不进入源码仓库。
- wgpu-native `v29.0.1.1`：官方 `wgpu-windows-x86_64-msvc-release.zip`，安装到 `third_party/wgpu/lib/`。
- zig-gamedev system_sdk 固定提交中的 `dxguid.lib`。
- NanoUI 所需的 `http-zig` 固定提交：校验归档 SHA-256 和 Zig 规范包哈希后恢复本地源码缓存，避免首次构建依赖 Git 远端发现。
- 可选的 Inno Setup `7.1.1` x64：仅在构建安装器时通过 `--installer-tool` 恢复，以官方 `/PORTABLE=1` 模式放进 `tools/InnoSetup/`，不创建编译器的注册表关联或卸载项。

完整 Zig 工具链与这些 exe/dll/lib/pdb 均被 `.gitignore` 排除，不进入源码快照。Zig 的校验过的下载缓存位于 `zig-pkg/bootstrap/`，无需重复下载。需要代理时可显式执行：

```powershell
.\tools\dev.ps1 bootstrap --proxy http://127.0.0.1:7897
.\tools\dev.ps1 bootstrap --installer-tool --proxy http://127.0.0.1:7897
```

已存在且哈希一致的文件会复用；哈希不同的文件默认拒绝覆盖，确认后可用 `--force` 替换。用户运行便携版或安装版都不需要安装 Zig、Python 或 Inno。

默认 Windows x64 构建固定为 `x86_64_v2`，避免开发机指令集意外进入分发物；开发者可用 `-Dcpu=native` 做本机构建，但不能用它替代分发基线验收。尚未在只支持更早指令集的 CPU 上实机验证。

NanoUI `0.12.0`（fork `00e5813`）的固定源码副本位于 `third_party/nanoui/`，来源提交、许可证和补丁策略见其中的 `VENDOR.md`。它是 Cutrans 独立维护的物理副本，不与 OTTO 共用工作区，也不依赖本机 `C:\src` 路径。独立资源管理器切片已经落地，现有分发 GUI 仍是 zgui/wgpu，NanoUI 已作为可选 Shell 进入便携版与安装版；接入时关闭 WebView2。通用改进经完整测试后少量、分批反哺上游，不为每次小编辑频繁提交 PR。

依赖源码基线由 `dependencies.lock.json` 固定。`python tools/dependency_audit.py` 验证有效源码树；来源提交缺失的旧 vendor 明确标为旧快照，不伪造上游身份。更新必须同时审查官方→fork→Cutrans 的差异，再显式更新锁。

纯语义验证可独立于桌面与OS Port配置：在源码根使用`tools/dev.ps1 build test-core -Dcore-only=true`。非Windows主机默认只配置语义目标，完整产品仍只承诺Windows验收。

## 构建与验证目标

以下在源码根运行；`tools/dev.ps1`以pythonw启动隐藏runner，保留日志及退出码。最小完整构建：

```powershell
.\tools\dev.ps1 build test-core test install portable --summary all -j1
```

| 用途 | build后的目标 |
| --- | --- |
| 纯语义／模型 | `test-core -Dcore-only=true`、`test` |
| NanoUI源码／前端编译 | `test-nanoui`、`test-nanoui-library` |
| 分发组装 | `install`、`portable`、`runtime-pack`、`shell-pack`、`nanoui-library-pack`、`library-probe` |
| 文档／作业实际产物 | `verify-edit-commit`、`verify-workspace`、`verify-workspace-rpc`、`verify-jobs`、`verify-jobs-async` |
| 资源实际产物 | `verify-assets`、`verify-resource-versions`、`verify-source-identity`、`verify-resource-operations`、`verify-resident-resources`、`verify-resource-registration` |
| Host／协议／回放 | `verify-host`、`verify-host-transport`、`verify-runtime`、`verify-replay`、`verify-input`、`verify-playback` |
| 自动化／环境 | `verify-automation`、`verify-isolation`、`diag-user` |
| Shell／GUI集成，单独安排 | `verify-shell`、`verify-attach`、`verify-nanoui-library`、`verify-nanoui-portable` |
| 安装器 | `installer`、`verify-installer-artifact`；完整登记测试另见下文 |

表中是可运行入口，不是本次执行清单。部分Shell／GUI目标可能启动真实窗口，不能当作默认headless检查。正常开发可运行build目标；封存验收时应直接针对同一份已构建产物运行对应验证脚本，避免每项验证重新构建。

依赖审计检查的是有效源树，不下载或自动升级。不能凭版本号或分支名判断源码已对齐。目录归属及源码快照规则见[仓库布局](repository-layout.md)；静态检查可运行`tools/dev.ps1 verify-repository`，它不代替编译、Pack校验或应用验收。

## 隐藏自动化的低层入口


Windows自动化构建和验证统一使用隐藏入口，防止CLI、PowerShell查询、编译器与测试程序弹出控制台。`tools/automation_process.py`保留子进程输入输出与退出码；普通调用使用`CREATE_NO_WINDOW`，Zig构建树使用一个预先隐藏的共享控制台，覆盖固定构建器直接启动的后代进程。真实GUI窗口仍可显示，GUI测试须单独安排。

```powershell
$quietPython = (Get-Command pythonw.exe).Source
$quietLog = "scratch/quiet-build-$([Guid]::NewGuid().ToString('N')).log"
$quietBuild = Start-Process -FilePath $quietPython -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
    '-B', 'tools/automation_process.py', '--console-tree', '--log', $quietLog, '--',
    'tools/zig/zig.exe', 'build', 'test-core', 'verify-automation', '-Dcore-only=true'
)
Get-Content -LiteralPath $quietLog
if ($quietBuild.ExitCode -ne 0) { throw "后台验证失败，退出码 $($quietBuild.ExitCode)" }
```

直接后台运行Python验证脚本时去掉`--console-tree`，并把`--`后的命令换为`python.exe -B tools/verify_host.py`等实际脚本。日志文件必须全新，已有证据不会被覆盖。外部启动方也必须采用隐藏入口；仅在内部脚本设置标志不能阻止其外层启动器先弹窗口。

`runtime-pack` 在 `zig-out/vm-runtime/` 生成独立 Runtime；`verify-runtime` 会真实动态装载它，验证保存/恢复、便携副本、绝对路径打开和篡改拒绝，不要求 wgpu 在场。`shell-pack` 在 `zig-out/vm-shell/` 生成桌面 Shell；`verify-shell` 验证缺失拒绝、真实 VM→Shell 启动与播放帧号投影，不截图或自动输入。`verify-replay` 在两个隔离数据根中比较命令回放的文档、History、Task 状态哈希、逻辑时间和 PNG，并验证语义输入回放与命令/输入时间倒退拒绝。`verify-input` 通过真实分发 Runtime DLL 录制 50 条语义事件，覆盖添加 invert、撤销、重做与文本上下文抑制；复制日志到全新数据根后校验相同文档指纹和 History 游标，不注入 OS 输入。`verify-playback` 用真实单调时钟验证四帧播放与停止/重启。`verify-assets` 经真实分发 Runtime DLL 验证素材租约复用、PNG 预览、独立快照导出/恢复和损坏内容拒绝；原外部文件删除后，已加载素材仍可预览。还验证临时 external 拒绝、持久原文件直接插入、显式快照插入、撤销/重做、PNG 导出、租约释放，以及重启后 Station 为空但 Source 文档仍可导出。内容变化不会覆盖旧文档版本，只有显式再次插入才更新；缺失文件、损坏快照、损坏授权目录和 Source 哈希不符均按对应错误拒绝。`verify-shell` 另通过显式 `--assets-demo` 走通真实桌面的素材选择、预览、库内独立化、插入和文档 GPU 提交，不模拟鼠标键盘。`verify-assets` 还覆盖库项去重、独立化后删除原文件、库内创建、重启恢复、拥有态禁止刷新、篡改内容与损坏目录。

`verify-host` 通过真实 `cutrans_vm.exe`、独立 Host 和本机消息管道验证幂等启动、单实例、旧入口双写者拒绝、保存失败后的 degraded 与重试、异常终止恢复，以及应用目录不被写入。`verify-attach` 进一步验证关闭 Shell 后 Host 继续存活、四次附着、素材与播放的真实提交计数、Shell 身份锁和重启恢复。

安装器构建和不注册系统的产物预检是额外的 Windows 步骤：

```powershell
.\tools\dev.ps1 build installer
.\tools\dev.ps1 build verify-isolation
.\tools\dev.ps1 build verify-installer-artifact
```

安装器输出到 `zig-out/installer/`，这里仍是可重建的产物。`verify-isolation` 在完整便携副本中注入环境变量、工作目录、链接、锁文件和故障，保存命令及结果；它不操作产品系统登记。`verify-installer-artifact` 对实际安装包执行 `/PreflightOnly=1`，验证临时安装布局、诊断、参数拒绝和登记未变；安装器此模式按约定返回 **7**，表示在复制和登记之前主动退出，不能称为安装成功。

可以直接针对同一份已构建安装包运行，并在发布前再次核对SHA-256。以下保留验证脚本的实际参数；Agent／无人值守执行时按上节低层入口将Python命令置于隐藏runner内，且不能以build目标重建已封存安装包：

```powershell
$installer = (Resolve-Path .\zig-out\installer\Cutrans-Setup-0.1.0-windows-x64.exe).Path
$acceptedHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
python tools/verify_windows_installer.py --artifact-check --installer $installer --expected-sha256 $acceptedHash
if ($LASTEXITCODE -ne 0) { throw "安装包预检未通过" }
if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $acceptedHash) { throw "安装包在验收后发生变化" }
```

静态脚本契约检查为 `python tools/verify_windows_installer.py --check-contract`。默认 `verify-installer` 和兼容目标 `verify-installer-headless` 都会拒绝系统注册测试；`--skip-gui` 或修改 `HOME` 不提供隔离。只有在独立 Windows 用户或虚拟机内，提供真实身份凭证后，才可显式执行完整登记测试：

```powershell
python tools/verify_windows_installer.py --system-registration --isolation-proof C:/CutransTest/isolation-proof.json --installer C:/CutransTest/Cutrans-Setup-0.1.0-windows-x64.exe
```

凭证 JSON 必须包含 `format="cutrans-registration-isolation/1"`、`product="org.cutrans.Cutrans"`、`operator_approved=true`、`kind="separate-os-user"` 或 `"virtual-machine"`、真实 `isolated_user_sid` 与 `production_user_sid`。脚本核对当前 `whoami /user` 的 SID，要求与隔离 SID 一致且不同于生产 SID，并要求该账号没有已有产品登记或同名快捷方式。当前日常用户的安装实例必须保留，本轮没有以它执行完整注册测试。系统测试目前覆盖安装、正常 Host 创建/保存、同 payload 重装和卸载保留数据，不覆盖变更 payload 升级或 GUI 视觉验收；失败时保留现场，不自动运行旧卸载器。

## 目录、数据与发布

源码模块在apps、consoles、bootstrap、host、vne、runtime、shell、ports、uikit、gpu、assets和config；build_support／tools负责构建与验证，packaging负责安装器。third_party保存独立固定源码，不使用其它应用的本地工作区。

- `zig-out/`或显式prefix只放可重建产物；`.zig-cache/`是编译缓存，`zig-pkg/`是恢复／包缓存。
- 开发日常数据由context指向源码根`.cutrans-dev/`，`CUTRANS_BUILD_PREFIX`只选产物位置；运行数据不跟随构建输出。
- 验证使用源码根`scratch/verification/<case>-<随机ID>/`及所有权标记，保留成功和失败证据；无标记旧目录、真实作品／会话／凭据不自动清理。
- 便携staging测试后不得出现data且产物hash应不变；日常便携副本的data属于用户数据。
- 安装版是一个根内的app／runtime-envs／shells／data，不把“打包”当作路径或系统登记策略。
- 发布使用已验收的同一份产物，核对版本、目标、大小和SHA；重新构建必须重新验收。源码测试、提取预检和完整系统安装各自记录。
- 签名私钥、访问令牌等秘密置于源码、构建与分发目录之外；换验证公钥需明确旧客户端过渡。

完整路径、清理、安装／卸载失败策略由[环境隔离](../environment-isolation.md)维护；本页不另建一份产品策略。改变程序资产的安装升级与自动迁移／回滚目前关闭。

## 验证范围与证据

开发测试验证能力，用户环境验证从获取到启动的完整链路。失败分类须区分不支持、未就绪、缺失、损坏、执行失败和取消；原生ABI除布局外还应通过真实子进程、文件和设备验证。无头、离屏readback和GPU submitted回执都不能替代真实GUI、IME与操作手感。

具体版本的已通过项见[现役状态](../memory/current.md)及其实施记录；[历史日志标记](../history/verification.md)不能作为当前安装包验收。没有在独立用户／VM执行完整安装升级卸载，就不能将源码通过、便携通过或预检通过写成安装通过。
