# Cutrans 便携原型

这是Windows x64便携产物，解压后运行，不需要Zig、Python或安装器。当前以静态PNG创作、资源引用、本机文件只读浏览与后台导出任务为主，完整视频音频及完整目录管理尚未完成。

在解压目录中先只读检查，再启动：

```powershell
.\cutrans_diag.exe --inspect
.\cutrans.exe --mode=portable
```

`cutrans.exe` 当前承担控制器、Host 与 NanoUI 桌面角色，各角色仍是独立进程；其默认 Host 使用内置静态 Runtime，不依赖 Runtime DLL。现有 `cutrans_vm.exe` 等入口、`runtime/` 和 Pack 暂作兼容回退，`payload/` 中的资源与清单仍是当前必需载荷。已提供独立的安全退出入口；本便携原型尚不是只有一个文件的最终发行版，真实窗口体验与安装验收仍未完成。

日常数据默认保存在本目录的`data/`，包括文档、历史、资源与任务。关闭桌面窗口后Host可继续执行任务；升级或移走程序文件时保留数据，删除程序目录前先确认数据归属。

主桌面统一使用 NanoUI，包含首页、编辑器、资源库、本机文件、CLI和任务视图；本机文件只读浏览仅在显式收录时登记资源。`payload/nanoui-library/` 是统一资源库载荷，`nanoui-library/` 保留旧的独立资源库诊断入口。所有界面共享同一VM协议，真实窗口／输入法验收尚未完成。

需要运行会写入测试结果的诊断时，使用全新独立目录：

```powershell
$diagnosticData = Join-Path ([IO.Path]::GetTempPath()) ("Cutrans-diagnostic-" + [Guid]::NewGuid().ToString("N"))
.\cutrans_diag.exe "--verify-data-dir=$diagnosticData"
```

这里的文件是运行产物。源码构建和完整技术说明见[项目主页](https://github.com/TLBtianhu/Cutrans)，以所下载版本的说明为准。项目许可证位于[licenses/Cutrans.txt](licenses/Cutrans.txt)，第三方许可证随各Pack保留。
