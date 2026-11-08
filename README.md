# Cutrans

声明式 VM 与多域创作工作台，使用 Zig 编写，当前处于早期原型阶段。

> An everything-is-a-plugin creative workstation for video editing and beyond.

文档、资源和任务由 VM 持有，桌面、CLI 与编辑 App 通过协议协作。长期方向是可替换应用组成的创作环境；当前可用闭环是单文档静态图像创作。

## 当前能力

- `.cut v3` 文本声明、图像 DAG、PNG 导入／预览／合成／导出，持久 History 与版本化文档请求。
- 独立 Runtime／Host；关闭 Shell 后导出继续，支持取消、归档查询和保留原输入的重试。
- 稳定资源 ID、逻辑文件夹、只读引用与显式独立化；已采用版本不随来源变化而改写。
- TXT、PNG、未知格式和空文件的通用只读登记及 App 交付，单文件上限16MiB；登记不等于支持预览或编辑。
- 统一 NanoUI 桌面包含首页、编辑器、资源库、CLI 与任务视图，并共享同一 Host；已加载完整内容可脱离原件使用。

完整文件浏览 App、云来源、可编辑工作正文、真实视频／音频、完整时间轴与不可信插件沙箱仍未实现。Windows x64 是当前产品验证平台；真实 GUI／IME及本轮完整安装升级卸载尚未验收，没有将当前源码产物发布为已验收正式版本。

当前事实和证据见[现役状态](docs/memory/current.md)；目标与历史决定从[项目记忆](MEMORY.md)进入。

## 从源码构建

以下仅适用于GitHub源码目录，不在便携包中执行。需要 Windows x64、Python 3（含 `pythonw.exe`）及首次恢复依赖所需的网络。工具链固定为 Zig 0.17.0，不要求安装全局 Zig。

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
| [Runtime 架构](docs/architecture/runtime.md) | VM／Host／Shell、资源、任务、帧与 ABI |
| [命令参考](docs/reference/commands.md) | 公开启动动作、VM 命令和 VNE URI |
| [环境隔离](docs/environment-isolation.md) | 开发、便携、安装、测试及发布边界 |
| [资源契约](docs/resource-operations.md) | 登记、采用、租约、来源核对和交付 |
| [界面规范](docs/ui-style.md) | 深靛蓝、冰蓝淡紫及克制金属高光 |

```text
apps/ consoles/ uikit/      应用、操作台和 NanoUI 呈现
runtime/ vne/ shell/        VM语义、协议和共享客户端
bootstrap/ host/ ports/     启动、独立Host和OS口岸
assets/ config/ packaging/  资源、启动声明和分发脚本
tools/ build_support/      开发、构建和验收工具
third_party/ docs/          固定依赖源码与项目文档
```

Cutrans 采用 [MIT](LICENSE)。第三方、字体和示例保留各自许可证；示例来源与hash见[源码记录](assets/examples/SOURCES.md)，分发物携带相应许可证。
