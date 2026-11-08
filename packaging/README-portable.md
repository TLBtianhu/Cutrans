# Cutrans 便携原型

这是Windows x64便携产物，解压后运行，不需要Zig、Python或安装器。当前以静态PNG创作、资源引用与后台导出任务为主，完整视频音频及独立文件浏览应用尚未完成。

在解压目录中先只读检查，再启动：

```powershell
.\cutrans_diag.exe --inspect
.\cutrans_vm.exe --mode=portable
```

日常数据默认保存在本目录的`data/`，包括文档、历史、资源与任务。关闭桌面窗口后Host可继续执行任务；升级或移走程序文件时保留数据，删除程序目录前先确认数据归属。

主桌面统一使用 NanoUI，包含首页、编辑器、资源库、CLI和任务视图；`nanoui-library/`仍提供可选的独立资源库诊断入口。所有界面共享同一VM协议，真实窗口／输入法验收尚未完成。

需要运行会写入测试结果的诊断时，使用全新独立目录：

```powershell
$diagnosticData = Join-Path ([IO.Path]::GetTempPath()) ("Cutrans-diagnostic-" + [Guid]::NewGuid().ToString("N"))
.\cutrans_diag.exe "--verify-data-dir=$diagnosticData"
```

这里的文件是运行产物。源码构建和完整技术说明见[项目主页](https://github.com/TLBtianhu/Cutrans)，以所下载版本的说明为准。项目许可证位于[licenses/Cutrans.txt](licenses/Cutrans.txt)，第三方许可证随各Pack保留。
