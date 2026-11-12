# 2026-11-12 容量与回收（窄版）

> **2026-11-12 本机验证后更新**：标题原为“已写代码，**尚未编译、尚未验证**”。本机 Windows 会话已编译并验证本片，代码零修改通过，结果见文末“验证（本机 Windows，2026-11-12）”。下面“状态”一节保留编写时的原文。

## 状态

- 本片由云端会话（挂载文件夹的 Linux VM）编写。该环境**没有 PowerShell、不能启动 Windows 进程、没有 Zig 且网络拒绝下载**，因此没有运行 `tools/dev.ps1`、没有编译、没有跑任何测试。下面所有改动都是**未经编译的源码**，不能视为已实现能力。
- 工作区未提交；`master` 与 `origin/master` 同为 `22cc8907`。未提交内容包括本片代码、[评审交接](2026-11-12-review-handoff.md)（未跟踪）及第五节记忆刷新。
- 用户随后改用本机 Windows 上的 Claude Code 本地会话继续，由该会话负责编译、验证、修错并补写本页“验证”一节。提交和推送前须征得用户同意。

## 用户决定（2026-11-12，本会话 AskUserQuestion 确认）

1. 评审交接第四节两处调整均确认：vne 测试根提到 D 之前（第 2 步）；D 以 v4 格式 ADR（无代码）开始。
2. 终态归档作业（failed/cancelled/interrupted）**不阻止**删除；之后对其重试会明确报 `ResourceNotFound`。
3. 删除只改 Catalog，已留存版本、owned 内容、工作正文与草稿文件**留在磁盘上作孤儿**，本片不做物理删除；ID 单调不复用，孤儿不会撞名。
4. 删除最后一个引用条目时**自动释放**其持久来源授权与来源记录（不另设 `source.remove`）。
5. 本片只暴露命令／CLI，GUI 删除按钮留到下一片。

## 改动（未编译）

- `runtime/resource_library.zig`
  - 文件级 `Holder { document, history, export_job, station }`、`uriHolder(ctx, uri)`（无 IO：当前文档、History 全部条目含 redo 分支的 `replace_document` before／after、`ctx.exports` 排队作业、`active_export`、`pending_finalize`、Station 对象按 `source.uri`）、`holderOf(ctx, id)`（另按 Station 的 `identity.library` 匹配）。
  - `Catalog.remove(ctx, id) !Removal`：文件夹走 `removeFolder`（有子文件夹或子资源即 `ResourceFolderNotEmpty`）；资源有未提交草稿即 `ResourceHasDraft`，有活引用即 `ResourceInUse`，不存在即 `ResourceNotFound`。成功时数组前移、`dropReceipts(id)` 按时间顺序压缩回执环（`next=0`），保存失败整体回滚；提交成功后若为 reference 条目，`releaseSourceIfUnused` 在没有其它 reference 条目和活引用时调用 `external_sources.forget`，失败只打印 `CUTRANS_SOURCE_RELEASE_DEFERRED`，留下无用授权。
  - **回执清理是必要的**：`restore` 对 `work_receipts` 中 `resource_id` 找不到的条目返回 `InvalidResourceLibrary`，不清理就会让下次启动整个资源库起不来；客户端高水位 `work_clients` 保留，被删回执对应的序号仍不会重复执行。
  - `dispatch` 新增 `library.remove <id>`：拒绝时打印 `CUTRANS_LIBRARY_REMOVE_REFUSED id= error= holder=`，返回 `invalid_state`；成功打印 `CUTRANS_LIBRARY_REMOVE id= released_grant=`。`library.folder.create`、`library.create` 的 `ResourceLibraryFull` 改为 `queue_full`。
  - 四个新测试（文件末尾）：各类持有者拒绝且不改 revision、删除后槽位可用且 ID 不复用、留存字节仍在、冷恢复一致；工作资源删除清回执且冷恢复成功、高水位保留；只删空文件夹并持久化；填满 8 个授权槽→文档直接引用时不释放→最后引用删除即释放、槽位复用、授权 ID 单调、冷恢复后旧授权不可解析。
- `runtime/external_sources.zig`：`Catalog.forget(ctx, id) !bool`，先保存授权文件再撤销内存 grant，保存失败两者都保留。
- `runtime/resource_requests.zig`、`runtime/native_api.zig` 的 `report`：`ResourceLibraryFull`、`ExternalGrantTableFull` → `abi.Status.queue_full`（复用既有状态码，无 ABI／Resource API 版本变化）。
- `vne/commands.zig` forwarded 清单与 `runtime/document_commands.zig` 注册表同时加入 `library.remove`（既有测试断言两者一致）。
- `shell/mirror.zig`（`registerExternal`）、`apps/library/nanoui_model.zig`（`command`）、`apps/library/work_model.zig`（`statusName`）：`queue_full` 显示为 `ResourceCapacityReached`。
- `README.md`、`docs/reference/commands.md` 已写入 `library.remove` 与容量错误说明；验证失败或语义调整时必须同步修改。

## 待执行的验证（本机 Windows 会话）

按序：`tools/dev.ps1 build test`、`build verify-architecture`、`build verify-work-documents`、`build verify-local-sources`、`tools/dev.ps1 verify-repository`。结果读 `scratch/verification/developer-<case>/run.log` 与 `result.json`；“退出 0”不能单独当全绿（审计 #17）。`build test` 若出现 `failed command: …test.exe`，须单独运行该二进制（不带 `--listen`）确认四个新测试逐条通过。

编写时已知的编译风险点：`uriHolder` 中对 `*const` 上下文可选字段的指针捕获（`if (ctx.active_export) |*job|`）、带标签联合与枚举字面量比较（`identity == .library`）、测试中 `defer { for … }` 与 `expectEqual` 类型推断。

## 未覆盖／留待后续

- `doc.open`、`asset_open_external`、导出快照使用的**非持久** grant（`native_api.zig` 的 `grantExternal`）在会话内从不撤销，8 个授权槽仍可能在一次会话中耗尽，重启后释放。
- 既有问题（发现但未修）：`Catalog.save` 按数组顺序写回执、`restore` 设 `work_receipt_next = count % len`，满环重启后淘汰的不一定是最旧回执；高水位保证不会重复执行，只影响 replayed／receipt_expired 的判定。
- rebind 留下的旧授权、失败发布留下的孤儿授权没有清理入口（用户选择只做自动释放）。
- 删除不扫描磁盘外保存的 `.cut` 文件；它们引用已删除的 `library://` 时会解析失败。
- GUI 删除按钮、被删文件夹仍被资源库页选中时的处理、孤儿字节的物理回收与预算均未做。
- 真实 GUI／IME、安装升级卸载未验收。

## 验证（本机 Windows，2026-11-12）

本片 Zig 代码**一次编译通过、零修改**；上面列出的三个编译风险点都没有触发。唯一的新增改动在 `tools/verify_assets.py`（见第 3 条）。

1. `build test`：前两次分别因 6 个、1 个测试根撞上 Zig 标准库间歇性 `unable to load "<std file>.zig": Unexpected` 而退出 1（`developer-b01416b5337f/`、`developer-f305a16df873/`；每次失败的文件都不同，HEAD 上同样出现，是既有的 loader 异常）。第三次 `developer-8adbccd2ec51/` 退出 0：0 个 loader 错误、0 个 `failed command`（51 个测试步骤命中缓存，1 个新跑 10/10）。
2. 测试二进制单独运行（不带 `--listen`、隐藏窗口）：第二次运行中被标为 `failed command` 的三个二进制分别为 112/112、178/178、114/114，退出 0。四个新测试在三个二进制里都逐条 `OK`：`removal frees a catalog slot…`、`removing a work resource drops its receipts…`、`only empty folders are removed…`、`the last reference releases its persistent grant…`。被标失败的原因仍是两个锁测试走构建运行器路径（`SHARING_VIOLATION` 跟踪是测试预期中的错误路径），与审计 #17 一致。
3. **真实 DLL 命令入口**（新增）：`tools/verify_assets.py` 的资源库冷恢复段增加 `library.remove` 断言：非空文件夹（`ResourceFolderNotEmpty`）、被已保存文档引用的资源（`ResourceInUse holder=document`）、未知 ID（`ResourceNotFound`）都返回 `invalid_state`(5)，且 catalog revision 不变；空文件夹删除成功；新建文件夹得到 ID 6，不复用 5；删除结果在重启后仍然保持。同一处修正了**既有验证漂移**：该脚本断言 catalog 格式为 `cutrans-resource-library/2`，但 `save` 自 Catalog v3/v4 起一直写 `/4`；脚本上一次运行是 2026-11-07，此后从未执行，所以漂移一直没被发现。现改为断言 `/4`、文件夹数 2。`verify-assets` `developer-e7b34f5c81f4/` 退出 0，输出 `CUTRANS_ASSET_SOURCE_OK`、`CUTRANS_EXTERNAL_REFERENCE_OK`、`CUTRANS_LIBRARY_OK … remove_refused=1 remove_empty_folder=1 remove_persisted=1`、`CUTRANS_ASSET_WORKSPACE_OK`。
4. `verify-architecture` `developer-ba291a60b074/`（`CUTRANS_ARCHITECTURE_OK layers=6 shell_runtime_leak=0`）、`verify-work-documents` `developer-896919a54275/`（`CUTRANS_WORK_DOCUMENTS_VERIFY_OK fixed_job=1 draft_commit=1 ring=1 cold_receipt=1 host_lost_reply=1 host_restart=1`）、`verify-local-sources` `developer-10588ff99516/`（`CUTRANS_LOCAL_SOURCES_VERIFY_OK dll=1 host=1 ui=1 no_implicit_registration=1`、`CUTRANS_LOCAL_FOLDER_OK`）均退出 0。
5. `tools/dev.ps1 verify-repository` `developer-9ebf09af52ab/` 退出 0；记忆补写后复跑 `developer-1b041f6a7626/` 仍退出 0。
6. **既有回归（不是本片引入）**：`verify-resource-registration` 在 `native_boundaries` 失败，`resource probe status=0, expected=4`（`tools/verify_resource_registration.py:335`）。也就是说，四个受管路径（数据根下的 `managed-source/managed.txt`、alternate runtime 副本里的 `pngtest.png`、`cutrans_vm_runtime.dll`、`cutrans_vm.exe`）中至少有一个的 `register_file` 探针被接受，而不是 `DENIED`；具体是哪一个没有定位。用于判断因果的做法：把本片代码 stash，在 HEAD `22cc8907` 上重跑同一验证（`developer-5bd1a6dd83ce/`，无 loader 错误），失败完全相同，随后恢复本片改动。该脚本上一次运行是 2026-11-08。本片对登记路径只做了容量错误到 `queue_full` 的映射，不可能把拒绝变成成功。这一项已作为新问题登记到 `current.md`，未修。

未覆盖：`library.remove` 尚未经过 Host RPC、Shell 或 CLI 端到端；没有覆盖授权释放的真实 DLL 场景（只有单元测试）；也没有覆盖容量满时 `queue_full` 在 UI 上显示为 `ResourceCapacityReached` 的真实场景。GUI 删除按钮、真实 GUI/IME、安装均未验收。

## 环境教训

云端会话挂载到用户电脑的是 Linux VM，不是 Windows：能读写仓库与读取验证日志，但不能运行 `tools/dev.ps1`。需要构建验证的切片应在本机 Windows 的 Claude Code 本地会话（桌面 App Code 标签选 Local，或 `claude` CLI）中进行；按 AGENTS.md，不用真实键鼠自动化代替。
