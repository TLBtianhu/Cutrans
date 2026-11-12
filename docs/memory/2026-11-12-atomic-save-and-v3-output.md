# 2026-11-12 保存原子性与 v3 显式输出

## 决定

- **交付物落盘必须原子**：`.cut` 是用户作品，不是可重建缓存；任何失败都不得留下截断前缀。
- **恢复标记不许撒谎**：History journal 记录 `dirty`/`legacy`，恢复时按记录还原，不再无条件声称"已保存"。
- **保存成功后补写确认标记**：目标是写前日志（pending）→ 原子写目标 → 补写确认；确认写失败只降级提示，不把已经durable 的保存报成失败。
- **canonical v3 必须显式 `output=`**：行对齐截断恰好会删掉末尾 `output=` 行，旧解析器会退化成"最后一个节点即输出"，得到一个语法合法但交付内容不同的文档。

## 改动

- 原子写原语从 `runtime/storage.zig` 提到 `vne/atomic_write.zig`（实现不变），供声明层与持久层共用；`runtime/root.zig` 的 `storage` 改为 re-export，6 个 runtime 文件的 import 改到 `@import("vne").atomic_write`。放在 `vne` 是因为 `vne` 不能依赖 `runtime`，否则声明层只能复制一份实现。
- `vne/documents.zig`：`save` / `saveExternal` 改用原子替换（此前是全仓唯一一处截断式持久写）；`parse` 对 `version >= 3` 要求显式 `output=`，否则 `error.MissingOutput`；v1/v2 的隐式输出迁移路径不变；新增测试覆盖完整、截断与 legacy 三种输入。
- `runtime/history_journal.zig`：journal 头新增 `dirty=` 与 `legacy=`；`load` 还原这两个标志而不是无条件 `dirty = false`；旧 journal 缺字段时保持原行为（升级不报警）；新增测试。
- `runtime/document_commands.zig`：`doc.save` 的写入顺序改为 journal(pending) → 原子目标 → 确认标记；`changes_flags` 为真时才补写确认。
- `build.zig`：新增 `verify-write-order` 步骤；把 `vne/documents.zig` 显式加为测试根（理由见下方"新发现 1"）。
- `tools/verify_write_order.py`：4 项真机断言（见验证）。
- `build.zig.zon`：收录新脚本。

## 验证

- `verify-write-order`：退出 0，`CUTRANS_WRITE_ORDER_OK checks=4`，最终 `developer-5b8e33bdb0d2/`（首次通过 `developer-94210791ed26/`）。断言：
  - canonical v3（带 `output=`）经真实 portable `cutrans.exe --headless --open` 被接受；
  - 行对齐截断（删掉末尾 `output=`）被拒绝，进程退出非 0；
  - `start` → `stop` 后 journal 记录 `dirty=0`，且 journal 内嵌的规范化文本与 `documents/session.cut` 字节完全一致；
  - `documents/` 目录只剩 `history.txt` 与 `session.cut`，原子替换不留 staging 兄弟文件。
- `build test`（隐藏入口）：退出 0。真实完整跑（非缓存）时日志含 23 个 `failed command`，全部来自下面"新发现 2"的两个既有锁测试；**在未改动的 HEAD 上同样 23 个、同样两个测试**（对照 `scratch/baseline2.txt`）。BOM 修正后的最后一次增量跑为 7 个 `failed command`，失败集合仍只有 `RAM detach lock failures…`（`developer-21ae574309d1/`；首次 `developer-29825300d63a/`、缓存复跑 `developer-e2ff6ab7ba3b/`）。
- 新增的 `vne/documents.zig` 测试根：22/22 通过（含本片新测试）；`.zig-cache` 内该测试二进制实测 "All 22 tests passed"。
- `verify-architecture`：退出 0，`CUTRANS_ARCHITECTURE_OK layers=6 shell_runtime_leak=0`。
- `verify-repository`：退出 0，`CUTRANS_REPOSITORY_AUDIT_OK selected=769 required=773`。

## 未验证

- 没有注入真实掉电或磁盘满；原子性由 `createFileAtomic + sync + replace` 的语义，以及"写一半的 `.cut` 被拒"间接证明，不是故障注入证据。
- `external://` 目标：journal 只记录内存标志，不记录宿主路径（遵守"宿主路径不进声明/快照"的既有边界），所以外部交付物与内存一致性的判定依赖 `dirty` 标志，没有独立复核外部文件字节。
- 未做真实 GUI/IME、安装升级卸载与发布验收。

## 新发现（本片暴露，未修复）

1. **vne 模块根的测试从不执行**。`test_support.addModule(b, test_step, vne)` 以 `vne/root.zig` 为根，实测发现 0 个测试（`zig test vne/root.zig --test-filter ...` 输出 "All 0 tests passed"；同一过滤条件在 `zig test vne/documents.zig` 命中 1 个）。Zig 只为可达声明收集测试，纯 re-export 根不触发分析。其余 `vne` 文件（abi/commands/uri/mounts/runtime_pack/runtime_lock/environment…）是否因此从未运行，需要逐文件确认；本片只把 `vne/documents.zig` 补成显式根。
2. **两个既有锁测试在当前机器上稳定失败**：`imaging/image.zig` 的 "exclusive Windows target lock preserves old bytes…" 与 `runtime/resource_library.zig` 的 "RAM detach lock failures…"。根因是 `NtSetInformationFile(rename)` 对 share=0 占用的目标返回 `STATUS_SHARING_VIOLATION`，Zig std 在 `dirRenameWindowsInner` 里对未映射状态码 `unexpectedStatus` 直接 panic，测试拿不到可捕获的 error。HEAD 上同样复现（21 次 panic / 23 个失败二进制），与本片改动无关。
3. **退出码不足以代表测试全绿**：上述 panic 型失败不改变 `zig build test` 的退出码（HEAD 与本片均退出 0）；只有断言型失败才会让退出码变 1（用临时探针验证过）。因此"build test 退出 0"不能单独作为测试通过的证据，需要同时检查日志里的 `failed command`。

## 边界

- 本片不改变 journal 与目标的写入先后（目标变原子后，"先 journal 后目标"才是正确的写前日志顺序：中途崩溃时 journal 恢复新声明并标记未保存，不会让旧声明覆盖已写出的新内容）。
- 没有改 `.cut` 的其它语法，也没有让 v1/v2 也要求显式输出。
- 未处理 `createWork`/`saveWorkDraft` 的发布顺序问题（`external_sources`/`work_files` 的 `next_id`、draft token 回滚），那是下一片。
