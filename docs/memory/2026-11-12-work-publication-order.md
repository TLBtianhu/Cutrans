# 2026-11-12 工作正文发布顺序与草稿基线

## 决定

- **正文与草稿按「revision/token + 内容哈希」命名**。发布发生在 Catalog 提交之前，所以提交失败必然留下未引用正文；如果名字只带 revision，重试复用同一 revision 且字节不同时会撞上那个孤儿，返回 `WorkContentMismatch`，而且此后同一 id 的创建/草稿永远失败。
- **旧名只读兼容**：`<revision>.bin` 仍可被读，新发布只生成新名，不迁移、不改写旧数据根。
- **`save_draft` 的 `base_revision` 必须等于当前工作头**。此前保存接受 `base < head`，而提交要求两者相等，于是落后客户端会反复写出一份提交时必然被拒的草稿，且每次保存都刷新同一份不可提交状态。

## 改动

- `runtime/work_files.zig`：`filename` 改为 `{revision:0>20}-{sha256}.bin`；新增 `legacyFilename` 与 `readNamed`，`readFrom` 先读新名、`FileNotFound` 时回退旧名；`publish` 使用新名，`PathAlreadyExists` 分支改为读新名核对。
- `runtime/resource_library.zig`：`saveWorkDraft` 的基线判据改为 `base_revision != item.work_revision` 即 `StaleWorkRevision`；`commitWorkDraft` 的判据不变，两端现在一致。
- 三个新测试（放在 `library` 测试区**前面**，避免被已知会打印诊断栈的 detach 锁测试截断）：Catalog 提交失败后同一 id/revision 以不同字节重试成功、草稿 token 失败后重试成功、落后 base 的草稿保存被拒且正确 base 仍可提交。
- `runtime/work_files.zig` 两个新测试：同一 revision 两个不同字节的正文都能按 digest 读回；旧 `<revision>.bin` 仍可读且 digest 不符仍拒绝。
- `docs/resource-operations.md`：更新正文/草稿的路径与基线规则。

## 验证

- `verify-work-documents`：退出 0，`CUTRANS_WORK_DOCUMENTS_VERIFY_OK fixed_job=1 draft_commit=1 ring=1 cold_receipt=1 host_lost_reply=1 host_restart=1`（`developer-55b6032eaaef/`）。
- `resource_library` 测试二进制单独运行：**All 143 tests passed**，退出 0；新增三个测试为 36/38 号，均 `OK`。
- `build test`（隐藏入口）：退出 0（`developer-6230dc80ded0/`），但见下方"已知问题"——该退出码不能单独作为全绿证据。
- `verify-architecture`：退出 0，`CUTRANS_ARCHITECTURE_OK layers=6 shell_runtime_leak=0`。
- `verify-repository`：退出 0，`CUTRANS_REPOSITORY_AUDIT_OK selected=770 required=774 markdown=101`。

## 未验证

- 旧数据根的真实迁移只由单元测试覆盖（手工写入 `<revision>.bin` 后读回）；没有用上一版本产品生成的数据根做端到端升级验证。
- GUI 客户端落后时的表现：现在保存会立即返回过期版本，客户端没有"重新读取快照并采用新 base"的重同步逻辑（`apps/library/work_model.zig` 从不更新 `base_revision`），所以真实操作中落后的资源库页面会停在拒绝状态，需要重开资源。这是下一片。
- 没有注入真实的掉电/磁盘满；发布顺序仍是"正文 → Catalog"，未引用正文会被保留而不是回收。

## 已知问题（修正上一片的结论）

上一片记录把 `resource_library` 的 detach 锁测试记为"稳定失败"。单独运行该测试二进制后确认：**测试本身通过**（143/143，退出 0），过程中 `std.Io` 对一个未映射的 Win32 状态码（`0xC0000043`）打印诊断栈并返回 `error.Unexpected`，测试用自己的 `else |_| {}` 正常吞掉。

失败只出现在 `zig build test` 的构建运行器路径：同一批二进制被标记 `failed command`，且该失败在未改动的 HEAD 上同样复现。根因未定（与 Zig 0.17 构建运行器在 Windows 隐藏控制台下的行为有关，本仓库此前已记录过同类"间歇 loader／Unexpected"现象）。因此：

- 不能把 `build test` 的 `failed command` 直接读成断言失败；
- 也不能把它的退出 0 读成全绿（断言型失败会让退出变 1，运行器型失败不会）。

这条需要单独排查，暂不混入本片。
