# 2026-11-12 评审交接：审计复核、威胁模型校正与接续顺序

## 状态

- 本记录来自一次只读评审会话（云端会话 + 挂载文件夹的 Linux VM，**无法运行 `tools/dev.ps1` 或任何 Windows 构建**）。没有改代码、没有构建、没有提交；本文件本身也尚未提交。
- 评审对象：`MEMORY.md`、[现役状态](current.md)、[审计检查点](2026-11-12-audit-checkpoint.md)、[架构评审](2026-11-12-architecture-review.md)、使命／身份／阶段／分发各章，以及下文引用的源码行。
- 用户独立复核了其中三点并同意，包括第 1、3 两项修正。以下“用户提出”与“Claude 建议”分开标注；未经用户明确确认的不算定案。

## 一、对审计检查点的修正（已核码）

1. **审计 #9 表述过重**：`apps/library/work_model.zig:240`、`:249` 在自身 commit／discard 后确实更新 `base_revision`。真实缺口是：收到 `stale_version`（`:154` 映射为 `"StaleWorkRevision"`）后没有任何重读快照／重同步路径，页面停在拒绝状态。
2. **两份“下一步”清单冲突**：审计检查点第 1 步含 `hasPending`/`abandonPending`，它们已在 `560868f9` 实现；`current.md` 末尾的“下一步建议”是另一套顺序。两者都由下文第四节取代。
3. **`current.md:141` 残留已撤回的说法**（两个锁测试因 `SHARING_VIOLATION` panic 稳定失败），`:143` 已更正为“测试本身通过，只在构建运行器路径失败”。
4. **`docs/architecture/runtime.md` 自相矛盾**：`:17` 写 ABI11，`:97` 仍写 ABI10；`:72` 写“自动断线重连尚未实现”，但 Host 重连 v1 已于 2026-11-11 落地。

## 二、威胁模型校正（用户提出，采纳）

审计把 P0 #1–#3 标为安全问题，但没有写威胁模型。校正为：**同用户完整性／正确性问题 + 一个持久性“砖化”，不是提权**。项目已声明自身不是沙箱；同用户进程本来就能直接改写 `session/runtime.lock` 或 `library/catalog.json`，无认证管道几乎不增加攻击面。真实危害是：

- 授权决定搭在通用 RPC 字段上（`shell/client.zig:496` 把 `allow_migration` 放进 `id`，`bootstrap/main.zig:863` 以 `request.rpc.?.id != 0` 判定）——任何把 `id` 置非零的代码路径都会触发迁移，并持久写锁，之后正常启动撞 `ShellLockMismatch`。
- `.command_result`（`host/shell_rpc.zig:370-375`）直通 Runtime，不查 epoch、expected stamp、managed／runtime_only——善意客户端（CLI、未来 agent）也能绕过受管语义造成静默覆盖。

唯一跨用户边界的角度（已核码，未实测）：`ports/host_control.zig:97` 服务端使用 `FILE_FLAG_FIRST_PIPE_INSTANCE`、`PIPE_REJECT_REMOTE_CLIENTS`、默认 DACL（其他用户无写权限，Host 也不会加入别人的管道）；但客户端 `CreateFileW`（`:121`）不核验服务端身份，管道名是可预测的 `sha256(data_dir)`。多用户机器上，另一用户可在 Host 启动前抢注同名管道冒充 Host。归入“多用户／提权部署未验收”清单，不是 P0。

## 三、两项新增发现（用户提出，已核码）

1. **文档模型是格式死路，不是容量问题**：`vne/documents.zig:91` 为 `nodes: [8]Node`，单一 `output_id`，fps 写在文档里，没有时间维度；`Op`（`:10`）只有 testsrc／gain／invert／over／image／resize。有合成运算（`over`／两项 aggregate），但没有“合成单元”（可复用、有作用域的 comp，即宪法“一 comp 一流”）。History 每条按值保存完整 `before`／`after` Document（`runtime/history_journal.zig:78-80`），所以放开 `[8]` 需要改快照所有权，不是改数组长度。11-12 起 v3 强制单一 `output=`，进一步固化单输出。
2. **“一切皆插件”零实现**（不只是“D 未开始”）：`runtime/capabilities.zig` 是手写静态声明表，仅与 adapter_ids 对账，是校验表不是装载器；不存在按依赖 DAG 装载的机制；运行时唯一可装载物是整个 Runtime DLL Pack，不是插件组合。另：`Op` 含 `image`，但声明表没有 `node.image`（是否有意未确认）。

## 四、战略判断与接续顺序

- 使命自述的 Hurd 陷阱／gcc 模式：Zig 重写约五周，基础设施很扎实，但创作能力仍是静态 PNG、六个效果。共识原则：**先修阻断真实会话的问题，再做能力；不在 D 之前继续叠硬化层**。Claude 上一版顺序（先 P0、测试可信度、阶段 0）违背了这一原则，已被用户纠正。
- 用户给出的顺序：容量与回收 → D 注册表 → 两个小 P0 → vne 测试根。
- Claude 建议的两处调整（**用户已于 2026-11-12 后续会话明确确认**，两项均采纳）：
  - vne 测试根提前到 D 之前：`vne/root.zig` 只有 `pub const` 导入、没有 `test` 块，测试不被发现；架构评审把效果 schema 放进 `vne`，先做 D 会让新测试落在不执行的区域。改动约一行，但要预期“从未运行过的测试”启用后失败，并确认发现的测试数上升。
  - D 以 v4 格式决策开始：现有 `Node` 是按 op 分字段（`value`／`asset_path`／两项 aggregate），在其上建注册表会把死路固化进参数 schema 与输入输出元数。

合并后的建议顺序：

1. **容量与回收（窄版）**：容量错误显式化 + “无引用才可删除”。`runtime/resource_library.zig:140-142` 的 `items[32]`／`folders[32]` 没有任何 remove 函数；外部来源 `[8]`（`runtime/external_sources.zig:132`）、授权槽 `[8]`（`vne/mounts.zig:16`）同理。删除前必须检查的引用：History 中的 before／after 文档、排队／归档 Job 固定的 hash、`library/versions/` 留存、与 `doc.open`／`asset_open_external`／导出快照共用的授权槽。
2. **vne 测试根**（见上）。
3. **v4 格式 ADR（无代码）**：作用域化的 comp ID、多输出、时间维度、不整份复制文档的快照模型、v1–v3 迁移规则。
4. **D 声明注册表**，建立在 v4 上。
5. **两项小修**（可插到任何更早位置）：`allow_migration` 移入 payload（客户端与 Host 两侧都要改，不完全是一行）；`.command_result` 依 `vne/commands.zig` 拒绝 managed／runtime_only。

其它小修候选：`asset.export` 目标白名单（`runtime/assets.zig:396-401`；防止 `session://library/catalog.json` 把 catalog 建成目录导致应用永久起不来）；`work_model` 收到 `stale_version` 后重读快照。

## 五、记忆／文档刷新（2026-11-12 后续会话已执行）

> 已执行：`current.md:141` 加更正标注；`current.md` 第 9 行 ABI10→ABI11；`current.md` 边界段写入第三节两项发现；进度快照“下一步”改为第四节顺序（唯一一份）并记 Git 状态；审计检查点加页首修正说明、#9 改写、P0 改标并补威胁模型、“下一步顺序”标为已取代；`runtime.md` 版本号改为指向 `vne/*.zig` 与 `current.md`、重连说明更新，并顺带更正 `:120` 已过时的“资源内嵌未完成”。仅文档改动，未构建；本会话无法运行 `tools/dev.ps1`，`verify-repository` 由用户运行。

- `current.md:141` 标注被 `:143` 取代。
- 审计检查点 #9 改写为第一节第 1 条的准确表述；其“下一步顺序”标注已被本记录取代，`current.md` 末尾“下一步建议”同步改为第四节顺序（只保留一份）。
- 审计检查点 P0 #1–#3 改标为同用户完整性，补威胁模型说明，管道抢注归入多用户未验收项。
- `runtime.md:97` ABI10→11、`:72` 重连说明更新；更好的做法是按架构评审阶段 0 改为链接 `current.md`，不复制会漂移的版本号。
- 把第三节两项发现写入 `current.md` 的边界／问题段。

## 六、环境与 Git

- （后续会话）第四节第 1 步已开始编码但未编译，见[容量与回收（窄版）](2026-11-12-capacity-reclaim.md)；该会话同样无法运行 `tools/dev.ps1`，用户改用本机 Windows Claude Code 本地会话继续。

- （后续会话复核）`master` 与 `origin/master` 同为 `22cc8907`，4 个提交已推送；当时未提交的只有本页、`MEMORY.md` 与 `docs/README.md` 的索引行。
- 审计检查点记录时 `master` 领先 `origin/master` 4 个提交（本会话未复核，`.git/logs/HEAD` 最后一条为 `docs: checkpoint the audit findings and slice progress`）。2026-11-11 事故的教训是尽快推送。
- 验证入口：`tools/dev.ps1 build <step>`；日志在 `scratch/verification/developer-<case>/run.log`，同目录 `result.json` 有退出码。“退出 0”不能单独当全绿证据（见审计 #17）。
- 未验证：上述所有判断均为读码 + 记忆对账，没有构建、运行或攻击演示。
