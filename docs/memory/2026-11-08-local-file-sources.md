# 2026-11-08 本机文件只读浏览与显式登记

## 本片范围

继工作正文切片后，用户要求继续推进。本轮借鉴 FileHub 当前“浏览不等于登记、成员显式收纳、目录与固定版本分离”的设计，完成 Cutrans 的第一个本机文件薄 App 入口。

本轮实现的是：

- 主桌面新增“本机文件”页面，与资源库、编辑器共享同一 Host。
- 从绝对路径或原生目录选择器打开目录，只读浏览当前一层。
- 有限排序、游标分页、嵌套进入、返回上级、刷新、文本／PNG 临时预览。
- 用户显式“收录到资源库”后，才复用现有普通文件登记、资源库选择和插入文档。
- 真实 DLL／Host／NanoUI 验收，不读取真实用户素材，不操作可见窗口或真实键鼠。

没有实现完整目录收纳、目录拖放、工程目录独立化、目录物理写入、流式超大目录、持续监听或自动同步。

## 边界与协议

### 浏览不是登记

`runtime/local_sources.zig` 只返回当前目录的临时投影：

- 目录最多 4096 个可接受成员，超出明确拒绝；每页最多 128 项。
- 目录优先、名称按 Windows 大小写不敏感规则排序，重复名称拒绝。
- 只处理普通文件和目录，成员重解析点跳过；不递归进入成员来建立资源。
- 路径、游标和条目是当前观察，不是 ResourceId、固定版本或永久授权。
- 目录发生后续变化时，游标不保证跨变化定位同一对象；需要重新浏览，不能冒充稳定 Catalog 游标。

浏览不创建 `library/catalog.json`、`session/external-sources.json`、留存版本或 Station lease。Shell 不直接枚举目录，Runtime 在同一受控执行栈完成路径解析、边界检查和枚举。

### 成员读取与登记

- `local_read` 使用既有 `external_sources.readFileSnapshot`，在同一稳定打开对象上读取真实路径、身份、字节和哈希，并执行托管根／路径边界检查。
- 单文件读取上限 16 MiB。文本临时预览限 1 MiB、有效 UTF-8、无 NUL，UI 最多显示前 64 KiB；PNG 由现有 NanoUI 图片通路显示。
- 临时预览不承诺固定内容版本，不保留整库缓存；未知格式明确报告不支持预览，仍可显式登记为普通只读资源。
- 显式登记继续使用 Resource API 的 `register_file` 与原有来源口岸，默认 reference，不复制或改写原件。
- 登记与预览、消费分账。登记成功但暂时无法建立预览时保留资源，不回滚成“未登记”；插入文档仍由用户另行选择。

### ABI 与传输

Resource API 从 v3 升为 v4，尾部新增 `source_browse` 与 `source_read`；工作正文 v3 接口保留。主 Shell ABI 仍为 10。

新增 RPC：

- `source_browse = 31`：版本、游标、页大小和绝对目录路径，返回有界 JSON 页面。
- `local_read = 32`：版本和绝对文件路径，返回有界完整字节。

新线格式不传输指针。旧 RPC25 的固定版本 Source 读取保持原名称与语义；本机临时文件读取使用 `local_read`，没有覆盖旧通道。

## NanoUI 页面

`apps/files/nanoui.zig` 持有当前页、选中项和临时预览的独立内存。打开、刷新或翻页失败保留旧页面；新页面解析成功后才替换。成员名称拒绝路径分隔、`..` 和 NUL，避免把观察项拼成越界路径。

页面提供：

- 原生目录选择器、绝对路径输入、返回上级、刷新、下一页；
- 选择文件进行临时预览，选择目录后显式打开；
- “收录到资源库”进入现有资源库流程；
- PNG 收录后仍使用既有“插入到文档”，不在浏览页暗中改变当前作品。

`--files-demo` 是仅用于隔离验收的内部入口，使用 `asset_workspace=2` 传递测试场景，不是新增日常公开 EXE。它不会把目录当成 `.cut` 打开。

## 实际验证

所有构建和验证均通过项目隐藏自动化入口，保留日志、输入输出和退出码。以下最终命令均退出 0：

| 验证 | 结果与日志 |
| --- | --- |
| `build test-core test install portable` | 完整构建、语义测试、安装前缀和便携组装通过；`developer-eaf3f49b62e2/` |
| `build verify-local-sources` | 真实 DLL、Host 和 NanoUI 页面全部通过；`developer-decc5ad05ecb/` |
| `build verify-work-documents verify-resource-registration` | 工作正文、固定输入、持久回执和通用登记回归通过；`developer-85c3ee56a72f/` |
| `build test-nanoui-desktop` | 统一桌面测试通过；`developer-393452ea5b18/` |
| `build verify-shell` | 主 Shell／Host 回归通过；`developer-8d8eee5bf860/` |
| `build verify-nanoui-library` | 原生资源库及既有正文编辑回归通过；`developer-5248a6a5f8fc/` |
| `build verify-attach` | 多次附着与 Host 恢复通过；`developer-162db2d4ca5f/` |
| `build verify-nanoui-portable` | 便携副本、默认路径与 Pack 纯净通过；`developer-3f6a1e77154b/` |
| `build verify-runtime verify-isolation` | Runtime 恢复和环境隔离通过；`developer-a14c4f3defac/` |
| `build verify-jobs-async` | 异步作业 9 组通过，inconclusive=0；`developer-812d6b112cbb/` |

本机文件专项最终证据：`scratch/verification/local-sources-7edbf021995f/local-sources.json`，其中包含：

- DLL 一层分页、文本／PNG／未知／空文件精确读取；
- 浏览和临时读取不产生 Catalog、授权、留存或资源记录；
- 托管根拒绝、显式单文件登记、原件不变和冷恢复；
- Host 浏览／读取、隔离数据根和重启；
- NanoUI 文本预览、嵌套进入、返回、翻页、刷新、文本与 PNG 显式登记、PNG 插入当前文档。

格式化、Python 语法和依赖审计通过。最终 `verify-repository` 通过，日志 `developer-34df828624ed/`，selected=1065、required=1069、Markdown=73、local_links=217、retained_sdk_binaries=0。真实 GUI／IME、可见目录选择器、系统剪贴板、完整安装升级卸载和发布仍未验收。

## 施工修正与保留边界

- 新临时读取通道最初与旧 `source_read` 重名，改为 `local_read`，旧 RPC25 未改变。
- Resource API 升 v4 后同步更新 Python 夹具及既有工作向量，旧版本测试仍用于拒绝不兼容客户端。
- 文本登记后曾让预览失败掩盖已登记结果；现分开呈现并保留资源。UI 验收同时登记文本与 PNG。
- 返回文件页时需要重建 Tester 帧，已修正；不是通过等待真实窗口来掩盖状态问题。
- 现有同步 owner 枚举和读取尚未变成异步 worker；大目录、目录整体收纳、完整目录独立化、统一内存预算、稳定变化中游标、原生 Shell 菜单和不可信插件沙箱仍需后续切片。

下一片可选择目录成员的显式收纳关系，或继续共享异步求值、FrameLease 与有预算驻留缓存；选择目录不等于这些能力已经完成。
