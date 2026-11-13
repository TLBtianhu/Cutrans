# 开始使用 Cutrans

当前是Windows x64的早期原型。源码、便携分发物和已登记安装是不同形态；本指南不把旧Release或安装器预检当作当前产物的完整验收。

## 便携版本

旧试验Release已撤下，当前尚无新的公开运行分发版本。本节适用于自行构建或后续发布的便携产物；公开下载将位于 [GitHub Releases](https://github.com/TLBtianhu/Cutrans/releases)，具体能力以对应版本说明为准。便携包先解压到用户选择的位置，再只读检查声明并启动 VM：

```powershell
.\cutrans_diag.exe --inspect
.\cutrans.exe --mode=portable
```

需要执行会创建文档、History 和导出的诊断时，必须指定独立且全新的验证目录；下例在临时目录中创建唯一数据根，结果保留供检查：

```powershell
$diagnosticData = Join-Path ([IO.Path]::GetTempPath()) ("Cutrans-diagnostic-" + [Guid]::NewGuid().ToString("N"))
.\cutrans_diag.exe "--verify-data-dir=$diagnosticData"
```

便携版包含运行所需的 NanoUI 原生组件、stb 图像编解码和第三方许可证，不依赖源码目录，不写注册表。日常文档、History、任务账本和导出默认写在程序旁的 `data/`；诊断目录不得与它重叠。`--open` 诊断只读原件，并在验证 Session 中保存副本。升级应用文件时应保留日常 `data/`。

源码提供 `Cutrans-Setup-0.1.0-windows-x64.exe` 的构建流程；历史早期便携 Release 不包含安装器，不能用当前源码说明推断其能力。安装版的声明形态为 `installed`，用户数据位于安装根的 `data/`，默认卸载保留。文件关联只在 `.cut` 未被其他应用占用时创建。变更程序资产的覆盖升级与旧数据迁移目前关闭。

`zig-out/portable/`是可重建staging，不是日常数据位置。`run-portable`拒绝直接日常启动staging；先复制到用户选择的位置，或依验证规则显式指定独立用途和数据根。便携分发物不包含源码构建脚本，构建命令仅用于GitHub源码目录。

## 一个进程就是一个环境

每次运行 `cutrans.exe` 都是一个完整的环境实例：同一进程持有文档、资源、作业和桌面界面，没有后台 Host。一个数据目录同时只能有一个实例；再次启动会提示环境已在运行。

关闭窗口与首页的“退出虚拟环境…”是同一个安全退出：先停止受理新业务，有导出未完成时可以选择等待或协作取消，然后保存并记录正常停止。保存失败时窗口保持打开、可以重试；只在失败后才允许“仅关闭窗口”，下次启动会按异常结束恢复。导出只在环境运行期间执行，关闭环境前请等待或取消。

```powershell
.\cutrans.exe status --mode=portable   # 只读：最后一次记录的状态、启动序号与是否异常结束
```

## 统一 NanoUI 桌面与可选资源库

默认桌面包含首页、编辑器、资源库、本机文件、CLI 和任务视图。`cutrans.exe library` 用同一种环境实例打开独立资源库界面，主要用于开发诊断；它不是第二个产品，日常只有一个 `Cutrans` 入口。两个界面的资源均来自 `cutrans.exe` 旁的 `payload/`，缺失时使用 exe 内嵌的副本。

需要无窗口调试或自动验证时，用 `exec` 在真实环境里逐行执行 JSON 调用（格式见[命令参考](../reference/commands.md)）：

```powershell
'{"call": "command", "name": "doc.read"}' | Set-Content -Encoding utf8 $env:TEMP\cutrans-calls.jsonl
.\cutrans.exe exec --mode=portable "--script=$env:TEMP\cutrans-calls.jsonl"
```

高级诊断可用 `--shell-dir=<绝对路径>` 选择候选界面载荷；它只在本次正常停止时提交选择。

当前界面提供文档编辑、PNG预览与导出、逻辑资源树、原生PNG导入、来源核对、独立化、移动、新建文件夹、中文重命名、CLI和任务分页。通用登记底层可以管理TXT／未知格式／空文件，不表示现有GUI能预览或编辑它们；完整来源浏览App、目录provider、可变正文、真实音视频仍未实现。见[资源契约](../resource-operations.md)。

## 运行数据与安装边界

用途normal／verification／diagnostic／replay、形态development／portable／installed与频道development／preview／stable分别声明。context决定实例和路径，不从cwd、HOME或项目.env猜测；`--mode`必须匹配。完整规则见[环境隔离](../environment-isolation.md)。

- 当前用户安装，默认`{localappdata}\Programs\Cutrans`，不需要管理员权限；简体中文向导只选一个安装根。
- 根内固定为app与data（旧版多目录布局 runtime-envs／shells 不自动迁移）。只有一个Cutrans开始菜单入口，文件关联不覆盖其它应用。
- 仅程序资产逐文件一致的幂等重装开放；变更资产升级、旧双根迁移、完整回滚和自动更新关闭，默认卸载保留data。
- 自定义根必须真实、合法且可写；频道共用AppId／ProgID，preview／stable不能据此并存系统登记。
- 安装／卸载先备份登记和快捷方式，核对所有权；本安装的 Cutrans 仍在运行时会中止并提示先在应用内安全退出（安装器不替用户结束进程），备份失败也会中止，旧卸载器不能清理其它安装。
- 当前安装包未签名；完整系统安装、失败卸载与重试仍需独立Windows用户或虚拟机验收。预检返回7不是安装成功。

已有体验实例和真实数据不用于制造测试故障。安装预检与隔离测试入口见[开发文档](../development/building.md)；来源丢失、旧授权确认与固定作品版本分别见[来源身份](../source-identity.md)和[资源操作](../resource-operations.md)。
