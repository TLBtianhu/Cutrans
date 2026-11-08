# 2026-11-08 工作正文、草稿与固定版本分离

## 范围与基线

用户要求开始下一切片。本轮先把已经验收的 NanoUI 统一改造提交为 `48fa8d27 refactor: unify application UI on NanoUI`，再把 FileHub 的 NanoUI 维护文档提交为 `9ac734d docs: add NanoUI synchronization guide`，然后实现 Cutrans 的工作正文闭环。两次提交均只在本机，没有推送、安装或发布。

本轮实现：

- Resource API 从 v2 升为 v3，主 Shell ABI 保持 10；原登记、重新定位和采用请求继续使用 RPC26～28，新工作快照／提交使用 RPC29～30。
- VM 持有工作正文、草稿、revision、冲突检查与成功回执，Shell 不直接写正文文件。
- 普通 owned 工作头与 Document／History／Job 固定采用版本分离；工作头前进不改旧作品输入。
- NanoUI 资源库新增原生文字创建、编辑、自动草稿、显式提交和关闭保护；图片预览路径保留。

## 持久化与协议

### 工作头和草稿

- `create` 建立 owned 资源及工作 revision 1。
- `save_draft` 只持久化草稿，不推进工作 revision；过期 base 仍可保护输入。
- `commit` 核对 draft token 和当前 base 后推进一次工作 revision；清除的是对应草稿元数据，不复用 token。
- `discard` 只接受明确的现有 token；提交失败、Catalog 失败和版本冲突都保留草稿。

正文发布到 `library/work/<id>/<revision>.bin`，草稿发布到 `library/drafts/<id>/<token>.bin`。完整字节写入并同步后才原子提交 Catalog v3。资源头、草稿元数据和成功回执在同一个 Catalog 写入中生效；未引用候选保留，不能按名称或时间猜作垃圾。

旧 Catalog v1／v2 可读，owned 旧项按工作 revision 1 兼容读取既有留存版本；新写入使用 v3。引用资源没有工作 revision，不能直接编辑，仍须显式独立化。

### 请求与恢复

- `work_snapshot` 优先返回草稿，否则返回当前工作正文；两次读取必须具有相同工作 revision、base、draft token 和 hash。
- `create`、`save_draft`、`commit`、`discard` 都携带独立 client＋sequence 和请求摘要。
- 成功回执与 Catalog 一起持久化，容量 64；达到上限明确拒绝，不静默淘汰。
- 重放先查原成功回执，再检查当前状态；跨 Runtime 重放不重复创建或提交。
- 失败与拒绝只使用当前 Runtime 的有界请求簿，不宣称所有错误均跨重启持久恢复。
- Shell 的未决请求队列不自动跨重启重放；重新打开先恢复已确认草稿，不盲目提交。

### 编辑会话

`apps/library/text_editor.zig` 与 `text_history.zig` 借鉴 FileHub 的输入预检、完整快照撤销和组合输入事务，但持久化改走 Cutrans Resource API，没有修改 NanoUI vendor。

`work_model.zig` 同时只发一个待确认请求，后续输入留在 UI。自动保存只产生草稿，Ctrl+S／“保存正文”才提交。导航和窗口关闭检查未确认输入；不能确认时保留窗口。文本限 1 MiB、有效 UTF-8、无 NUL，Runtime 通用工作字节上限仍为 16 MiB。

## 实际验证

所有命令均经项目隐藏自动化入口执行并保留日志和退出码。以下最终命令均退出 0：

| 验证 | 结果与证据 |
| --- | --- |
| `build test-core test install portable` | 完整构建、语义测试、安装前缀和便携组装通过；`scratch/verification/developer-9ad3808807a8/` |
| `build test-nanoui-desktop` | 统一桌面测试通过；`developer-f2f0964802e5/` |
| `build verify-work-documents` | 真实 DLL／Host 的旧导出固定输入、草稿提交、冷恢复、丢回复和重启回执通过；`developer-cfb3fed39a77/` |
| `build verify-resource-registration` | 通用登记 14 组通过；`developer-44ebe7016b36/` |
| `build verify-shell` | 主桌面真实 Host／Shell 回归通过；`developer-680118f569c9/` |
| `build verify-nanoui-library` | 原生无头场景通过，含多行输入、草稿、提交和关闭保护；`developer-b09c6c9df1d2/` |
| `build verify-attach` | 多次 Shell 附着、Host 存活和重连恢复通过；`developer-227b5416b6da/` |
| `build verify-nanoui-portable` | 便携副本默认解析、隔离数据根和 Pack 纯净通过；`developer-87da4af7180a/` |
| `build verify-runtime verify-isolation` | Runtime 恢复及环境／故障隔离通过；`developer-c91dc968bd89/` |
| `build verify-jobs-async` | 异步作业 9 组通过，inconclusive=0；`developer-c5d08fe915d2/` |
| `verify-repository` | 源码包、本地输入和 Markdown 链接审计通过；最终 `developer-9821939b5421/`，selected=1059、required=1063、Markdown=71、local_links=209 |
| 格式／依赖 | Zig fmt、Python 语法、`git diff --check` 和 `tools/dependency_audit.py` 通过；最终格式化后 `test verify-work-documents` 再次通过，见 `developer-04f60128da71/` |

正文专项报告：`scratch/verification/work-documents-70fb8937d035/work-documents.json`。报告验证旧 Job 输出 COLOR_A，当前工作头为 COLOR_B；Host 丢回复重放和重启后回执均通过。后续格式化复验也通过。

真实窗口视觉、中文输入法候选窗、系统剪贴板、焦点与操作手感未验收。没有执行完整安装、变更资产升级、卸载或发布。

## 施工中修正的问题

- 新测试辅助函数命名遮蔽首先由编译器发现，已修正。
- 冷恢复后合法下一请求曾被内存请求簿误判为乱序；现用持久成功序号高水位初始化，并保留 client 上限。
- 文本切回 PNG 时曾把旧编辑器误当成新资源打开成功；现只在确认不支持文本后安全关闭旧编辑器，再走图片预览。
- Python Host 夹具最初把版本写入 `struct_size`、把版本字段写零，Runtime 正确拒绝；已修夹具并加入 Zig／Host 双方有效向量。没有把这个夹具错误当成产品协议修复。
- 新验证脚本首次未纳入源码包，`verify-repository` 以两项失败拦下；已在 `build.zig.zon` 登记并复核。
- 首轮测试日志仍出现项目已记录的间歇性 Sharing Violation，后续同源码完整测试通过；根因没有据此宣布解决，也未隐藏失败日志。

## 未完成与下一片

- 共享异步求值、完整 FrameLease、有预算驻留缓存、异步限定刷新和自动重连仍未完成。
- 通用目录／云来源、跨进程 App 调度、完整本机文件薄 App、恢复向导、通用跨文件事务和垃圾回收未完成。
- 普通工作正文与固定版本已分离，但不代表专业应用可直接编辑任意外部原件；默认只读引用和显式独立化政策不变。
- 旧命令受管理收口、完整持久错误回执、未决 Shell 请求恢复、保留策略及总内存预算继续后续。
- 下一片优先接本机文件与资源库薄 App 入口，再继续共享异步求值和缓存生命周期；具体计划不是本轮已完成能力。
