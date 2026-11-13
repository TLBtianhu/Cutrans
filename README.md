# Cutrans

声明式 VM 与多域创作工作台，使用 Zig 编写，当前处于早期原型阶段。

> An everything-is-a-plugin creative workstation for video editing and beyond.

文档、资源和任务由 VM 持有，桌面、CLI 与编辑 App 通过协议协作。长期方向是可替换应用组成的创作环境；当前可用闭环是单文档静态图像创作。

## 当前能力

- `.cut v3` 文本声明、图像 DAG、PNG 导入／预览／合成／导出；v3 必须显式声明 `output=`；持久 History、工作正文草稿与显式提交；受管理编辑带客户端序号、前置版本和回执，失败不发布半编辑。
- 单进程虚拟环境：每次运行 `cutrans.exe` 就是一个环境实例，同一进程持有 Runtime（内置静态，不需要 Runtime DLL）、后台导出线程和桌面／资源库 App；同一数据目录同时只允许一个实例。导出支持取消、归档查询和保留原输入的重试。
- 安全退出：窗口关闭与“退出虚拟环境…”走同一流程，先停止受理新业务，可等待或协作取消已有导出，再保存并记录正常停止；异常结束会在下次启动时报告。`cutrans.exe exec --script=<jsonl>` 可无窗口地在真实环境里逐行执行命令，用于调试与自动验证。
- 稳定资源 ID、逻辑文件夹、只读引用与显式独立化；已采用版本不随来源变化改写。本机文件可显式登记，也可收录到以来源目录命名的逻辑文件夹，成员关系写入 Catalog；资源身份、内容哈希和来源授权不变。库条目与空文件夹可用 `library.remove` 删除：仍被当前文档、History、未完成导出或已加载对象使用时拒绝；删除最后一个引用会释放其来源授权槽，已留存字节不物理删除。库或授权槽满时返回明确的容量错误。
- TXT、PNG、未知格式和空文件的通用只读登记及 App 交付，单文件上限 16MiB；登记不等于支持预览或编辑。
- 统一 NanoUI 桌面包含首页、编辑器、资源库、本机文件、CLI 与任务视图，共享同一环境；本机文件只读浏览一层，浏览不隐式创建资源、授权或留存。
- 便携包可收成单 exe（payload/context 内嵌）；安装器入口已切换到统一 `cutrans.exe` 并通过提取预检，但真实安装、变更资产升级和卸载仍未验收。

目录整体收纳、递归／流式超大目录、工程目录独立化、云来源、通用换源、真实视频／音频、完整时间轴、共享异步求值、完整 FrameLease 与不可信插件沙箱仍未实现。Windows x64 是当前唯一完整验证平台；真实 GUI／IME 及完整安装升级卸载尚未验收，当前源码产物没有发布为已验收正式版本。

当前事实和证据见[现役状态](docs/memory/current.md)；目标与历史决定从[项目记忆](MEMORY.md)进入。

## 从源码构建

以下仅适用于GitHub源码目录，不在便携包中执行。需要 Windows x64、Python 3（含 `pythonw.exe`；uv 托管的 3.12 也可）及首次恢复依赖所需的网络。工具链固定为 Zig 0.17.0，不要求安装全局 Zig。`tools/dev.ps1` 会在 PATH 之外尝试 `uv python find 3.12` 和 uv 的 `%APPDATA%\uv\python` 托管解释器，因此宿主的 PATH 快照过旧或 Python 未全局安装时仍可运行隐藏入口。

```powershell
git clone -c core.longpaths=true https://github.com/TLBtianhu/Cutrans.git
cd Cutrans
.\tools\dev.ps1 bootstrap
.\tools\dev.ps1 build test-core test install portable --summary all -j1
```

开发入口使用隐藏控制台并保留日志与退出码。详见[构建与验证](docs/development/building.md)。新产物在`zig-out/`暂存，复制到用户选择的位置后再日常运行；本机旧输出内仍有历史验证数据，清理须按[仓库布局](docs/development/repository-layout.md)核实，不能整目录删除。

当前以源码交付，旧试验发布已撤下。新的分发版本将在相应验收后发布到 [GitHub Releases](https://github.com/TLBtianhu/Cutrans/releases)。启动与数据位置见[使用指南](docs/guides/getting-started.md)；安装器源码或预检通过不代表完整安装通过。

## 阅读与目录

| 入口 | 内容 |
| --- | --- |
| [文档导航](docs/README.md) | 使用、开发、架构、协议和历史 |
| [Runtime 架构](docs/architecture/runtime.md) | 单进程环境、VM、App、资源、任务、帧与 ABI |
| [命令参考](docs/reference/commands.md) | 公开启动动作、VM 命令和 VNE URI |
| [环境隔离](docs/environment-isolation.md) | 开发、便携、安装、测试及发布边界 |
| [资源契约](docs/resource-operations.md) | 登记、采用、租约、来源核对和交付 |
| [界面规范](docs/ui-style.md) | 深靛蓝、冰蓝淡紫及克制金属高光 |

```text
apps/ consoles/ uikit/      应用、操作台和 NanoUI 呈现
runtime/ vne/ shell/        VM语义、共享词汇和 App 侧镜像
bootstrap/ ports/           启动与环境实例、OS口岸
assets/ config/ packaging/  资源、启动声明和分发脚本
tools/ build_support/      开发、构建和验收工具
third_party/ docs/          固定依赖源码与项目文档
```

Cutrans 采用 [MIT](LICENSE)。第三方、字体和示例保留各自许可证；示例来源与hash见[源码记录](assets/examples/SOURCES.md)，分发物携带相应许可证。
