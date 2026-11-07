# 开始使用 Cutrans

当前是Windows x64的早期原型。源码、便携分发物和已登记安装是不同形态；本指南不把旧Release或安装器预检当作当前产物的完整验收。

## 便携版本

从 [GitHub Releases](https://github.com/TLBtianhu/Cutrans/releases) 获取分发物，具体能力以所下载版本的说明为准。下列命令适用于当前源码生成的产物，旧 Release 的参数可能不同。便携包先解压到用户选择的位置，再只读检查声明并启动 VM：

```powershell
.\cutrans_diag.exe --inspect
.\cutrans_vm.exe --mode=portable
```

需要执行会创建文档、History 和导出的诊断时，必须指定独立且全新的验证目录；下例在临时目录中创建唯一数据根，结果保留供检查：

```powershell
$diagnosticData = Join-Path ([IO.Path]::GetTempPath()) ("Cutrans-diagnostic-" + [Guid]::NewGuid().ToString("N"))
.\cutrans_diag.exe "--verify-data-dir=$diagnosticData"
```

便携版包含运行所需的 wgpu-native DLL 和第三方许可证，不依赖源码目录，不写注册表。日常文档、History、任务账本和导出默认写在程序旁的 `data/`；诊断目录不得与它重叠。`--open` 诊断只读原件，并在验证 Session 中保存副本。升级应用文件时应保留日常 `data/`。

源码提供 `Cutrans-Setup-0.1.0-windows-x64.exe` 的构建流程；历史早期便携 Release 不包含安装器，不能用当前源码说明推断其能力。安装版的声明形态为 `installed`，用户数据位于安装根的 `data/`，默认卸载保留。文件关联只在 `.cut` 未被其他应用占用时创建。变更程序资产的覆盖升级与旧数据迁移目前关闭。

`zig-out/portable/`是可重建staging，不是日常数据位置。`run-portable`拒绝直接日常启动staging；先复制到用户选择的位置，或依验证规则显式指定独立用途和数据根。便携分发物不包含源码构建脚本，构建命令仅用于GitHub源码目录。

## 窗口与后台Host

默认公开入口启动或复用Host，再附着desktop。关闭窗口只断开Shell，Host和已接受的导出可以继续。需要停止实例时显式执行stop：

```powershell
.\cutrans_vm.exe start --mode=portable
.\cutrans_vm.exe status --mode=portable
.\cutrans_vm.exe restart --mode=portable
.\cutrans_vm.exe stop --mode=portable
```

可用`.\cutrans_vm.exe jobs --mode=portable`查询Host作业。start幂等；stop先保存，保存失败进入degraded并保留Host供重试；restart先正常停止再启动。异常退出会在下次启动标记，不能以删锁或强杀代替正常停止。

## 可选NanoUI Shell

`cutrans_library_nanoui.exe` 是不经过旧 GUI DLL 的独立前端，经 `bootstrap.runAttached` 复用 Host 预检、RPC 和成功后的选择提交。`zig-out/nanoui-library/` 是独立 Shell Pack，包含入口 EXE、示例和许可证；便携版放在根内 `nanoui-library/`，安装版放在 `shells/nanoui-library/`。默认桌面仍是 desktop，只有显式选择并成功运行 NanoUI 后才更新 Shell 锁。旧桌面与新前端共用 `shell/mirror.zig` 的目录、Asset 和完整 PNG 投影。

NanoUI EXE 是内部 Shell 组件，不是第二个产品。日常只有一个 `Cutrans` 桌面入口，资源库由桌面内部的 VM App 打开；安装版也只创建一个开始菜单入口：

开发态候选前端的以下命令仅在源码根执行；先按[构建指南](../development/building.md)生成Pack：

```powershell
.\tools\dev.ps1 build nanoui-library-pack
.\zig-out\bin\cutrans_vm.exe library --mode=development
# 需要显式返回桌面时：
.\zig-out\bin\cutrans_vm.exe desktop --mode=development
.\zig-out\bin\cutrans_vm.exe stop --mode=development
```

`library --assets-demo` 会等待无头前端完成并返回真实退出码。日常默认启动和 `.cut` 打开则统一走 Host＋desktop，不要求用户理解内部 EXE 或填写 Pack 路径。

子目录 Shell 会从已验证的安装根或便携根解析同一个 `data/`，不会在自己的 Pack 内写数据。高级诊断仍可使用 `--shell-dir=<绝对路径>` 选择候选 Pack；它只在本次成功后迁移 Shell 锁。

当前界面提供逻辑树、原生PNG导入、完整预览、来源核对、独立化、移动、新建文件夹及中文重命名。通用登记底层可以管理TXT／未知格式／空文件，不表示现有GUI能预览或编辑它们；完整来源浏览App、目录provider、可变正文、真实音视频仍未实现。见[资源契约](../resource-operations.md)。

## 运行数据与安装边界

用途normal／verification／diagnostic／replay、形态development／portable／installed与频道development／preview／stable分别声明。context决定实例和路径，不从cwd、HOME或项目.env猜测；`--mode`必须匹配。完整规则见[环境隔离](../environment-isolation.md)。

- 当前用户安装，默认`{localappdata}\Programs\Cutrans`，不需要管理员权限；简体中文向导只选一个安装根。
- 根内固定为app、runtime-envs/default、shells/desktop、shells/nanoui-library及data。只有一个Cutrans开始菜单入口，文件关联不覆盖其它应用。
- 仅程序资产逐文件一致的幂等重装开放；变更资产升级、旧双根迁移、完整回滚和自动更新关闭，默认卸载保留data。
- 自定义根必须真实、合法且可写；频道共用AppId／ProgID，preview／stable不能据此并存系统登记。
- 安装／卸载先备份登记和快捷方式，核对所有权及相关进程；保存、停止或备份失败会中止，旧卸载器不能清理其它安装。
- 当前安装包未签名；完整系统安装、失败卸载与重试仍需独立Windows用户或虚拟机验收。预检返回7不是安装成功。

已有体验实例和真实数据不用于制造测试故障。安装预检与隔离测试入口见[开发文档](../development/building.md)；来源丢失、旧授权确认与固定作品版本分别见[来源身份](../source-identity.md)和[资源操作](../resource-operations.md)。
