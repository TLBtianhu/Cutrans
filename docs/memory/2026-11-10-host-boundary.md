# 2026-11-10 宿主边界：窗口与外部素材口岸

本片按 2026-11-09 用户关于“全屏/最小化/从 OS 文件资源管理器导入”的讨论落地一个可验收的宿主边界，而不是把 VM 做成一个假装不存在 Windows 的全屏程序。默认保留原生窗口边框；外部文件通过 Resource API 的 `register_file` 明确登记，不再走旧 `asset.open` 路径。

> 2026-11-10 后续的自定义 chrome 切片已把默认窗口改为无边框自绘标题栏；本页的“原生边框”描述只代表宿主边界那一版，最新实现见 [custom chrome](2026-11-10-custom-chrome.md)。

## 窗口

- 默认桌面仍使用原生 Windows 边框；启动后 `setFullScreen(true)`，在这版 NanoUI 的 Windows 实现中等于 `SW_MAXIMIZE`，不是无边框全屏。原生最小化/最大化/关闭仍在。
- F11 调用 `Window.zoom()` 在最大化与还原之间切换；不进入无边框、不隐藏任务栏、不创建第二个顶层窗口。
- 没有在普通窗口模式增加自绘最小化按钮。原因见讨论：原生最小化是 OS 窗口语义，测试者可以确定它不碰 VM；自绘按钮属于应用测试面。真正的无边框沉浸模式和自绘标题栏仍是独立窗口 chrome 切片，本片不做。
- 首页增加一行说明：“原生标题栏最小化；F11 最大化/还原；外部文件可直接拖入登记。”

## 外部素材口岸

- `apps/library/nanoui_model.zig` 的 `importExternal` 改为 Shell 侧 `library_client.Client`：
  - `refresh` → `probe(0, .register_file, path)` → `submit`；
  - 丢回复时只 `retry` 原候选，不生成新意图；
  - 成功后刷新 Catalog，选中新资源；预览失败仍保留登记结果；
  - 返回资源 ID，而不是旧 `asset.open` 的 handle。
- `apps/files` 的“收录到资源库”和桌面 `registerLocal` 都走这条路径；旧路径仍保留给 VM 内部 Pack 资源/旧命令，不作为外部导入入口。
- `apps/editor` 的“导入 PNG…”也改为 `register_file`：登记后刷新库投影，`ensureLibraryAsset` 取 handle，再插入当前文档；系统对话框改为任意文件。fixture 用 `CUTRANS_EDITOR_IMPORT_OK register_file=1` 覆盖这条路径。
- 外部素材边界由 Runtime `source_boundary` 执行：拒绝 data、resource、Runtime module 及 product root 内的文件；硬链/junction/源漂移仍按既有 `readFileSnapshot`/`readStablePath` 规则处理。UI 只显示失败，不会把 managed 路径变成文档身份。
- 支持 OS 文件拖放：
  - 桌面根视图放一个固定、位于内容后方的全窗口 drop zone；
  - 拖动经过时显示“释放以登记到 VM 资源库”提示；
  - 释放后逐个调用 `register_file`，成功后切到资源库并显示“已从本机登记”；
  - 多文件中途失败会保留已成功的登记并报告部分失败；
  - 资源库仍以现有的“引用/拥有” badge 和 `sourceStatusText` 展示来源状态。
- 资源库“从本机导入…”改用系统文件对话框，允许任意文件；PNG 继续有完整预览，其它文件登记后可显示“预览尚未建立”，登记结果不回滚。

## 测试修正

- Pack 内的 `pngtest.png` 是受管理证据，不是外部来源；桌面/资源库 fixture 先把它复制到 `%TEMP%`，再走 `register_file`，避免测试把 Pack 当成用户文件。
- `apps/files` 的本机文件 fixture 增加：
  - 从本机文件页登记；
  - OS drop 登记；
  - 从 VM data 目录拖入被拒绝且 Catalog 计数不变。
- 旧 `asset.open` 仍用于 fixture 内部的 Pack/快照素材和内部资源消费；这不代表外部导入仍走旧入口。

## 实际验证

- `tools/dev.ps1 build portable`：退出 0。
- `tools/dev.ps1 build test`：最终退出 0，`developer-1cae13653ec2/`。
- `tools/dev.ps1 build verify-local-sources`：最终退出 0，`developer-ba39d27891b2/`；输出 `CUTRANS_DROP_IMPORT_OK register_file=1 managed_root_refused=1` 和 `CUTRANS_LOCAL_SOURCES_VERIFY_OK ...`。
- 桌面资产 fixture 直接运行输出 `CUTRANS_EDITOR_IMPORT_OK register_file=1`、`CUTRANS_SHELL_ASSETS_OK ...` 与 `CUTRANS_NANOUI_DESKTOP_OK`。
- `tools/dev.ps1 build verify-payload`：最终退出 0，`developer-648320312da3/`；锁身份、同 id 拒绝、桌面→资源库兄弟切换、旧 Pack 回退和损坏拒绝均通过。
- `tools/dev.ps1 build verify-safe-exit`：退出 0，`developer-56113493bec6/`；`stranded=1 control=1 save_retry=1 draft=1 restart=1`。
- `tools/dev.ps1 verify-repository`：退出 0，`developer-0f828d2e5365/`，`selected=1087 required=1091 markdown=81 local_links=254 retained_sdk_binaries=0`。

## 未覆盖与保留边界

- 没有用真实鼠标从 Explorer 拖入真实窗口；测试用 NanoUI Tester 的 `drop` 模拟。系统对话框也未自动点击。
- 没有真实观察最大化窗口、F11 手感和原生最小化/恢复；`setFullScreen` 的 Windows 语义是最大化，不宣称无边框全屏。
- 没有做自绘标题栏、Snap Layouts 或沉浸模式控制条；这些需要单独窗口 chrome 切片。
- `register_file` 仍限制 16MiB、单文件；目录拖入、云盘/网络路径、symlink 和权限拒绝的真实体验未覆盖。
- 外部引用被原文件删除/变化时的 UI 状态仍沿用既有来源核对；本片没有新增自动重新绑定或复制策略。
- 未安装、未发布、未提交或推送。
