# 2026-11-12 审计结论与进度检查点

本次会话做了三件事：一次全仓审计（只读）、切片 A（保存原子性）、切片 B（工作正文发布顺序）。本记录同时充当检查点：**审计发现只有在这里才落盘**，此前的架构评审记录（`2026-11-12-architecture-review.md`）只覆盖结构债，不含下面的授权面与运行时缺陷。

## 当前 Git 状态

- `master` 已提交本会话全部内容：`0bc7ba51` 保存原子性与 v3 显式输出、`fb124808` 其后的记忆更新、`714ebafd` 工作正文发布顺序与草稿基线，以及本文件所在的记忆检查点提交。
- 工作区干净。未推送：`master` 领先 `origin/master` 4 个提交。

## 已修（本次会话）

| 缺陷 | 位置 | 记录 |
| --- | --- | --- |
| `.cut` 交付物用截断式 `writeFile` 写、journal 先落盘 | `vne/documents.zig` 的 `save`/`saveExternal`、`runtime/document_commands.zig` | `2026-11-12-atomic-save-and-v3-output.md` |
| History journal 不持久化 `dirty`/`legacy`，恢复即声称已保存 | `runtime/history_journal.zig` | 同上 |
| v3 省略 `output=` 时退化成"最后节点即输出"，行对齐截断被接受 | `vne/documents.zig` 的 `parse` | 同上 |
| Catalog 提交失败留下的未引用正文永久阻塞同一 revision 的重试 | `runtime/work_files.zig` 命名 | `2026-11-12-work-publication-order.md` |
| `save_draft` 接受 `base < head`，`commit` 却要求相等 → 永远提交不了的草稿 | `runtime/resource_library.zig` 的 `saveWorkDraft` | 同上 |

## 未修：P0（会导致用户数据被静默改写或越权）

1. **迁移许可来自传输层字段**：`shell/client.zig:496` 把 `allow_migration` 塞进 RPC 通用 `id` 字段，`bootstrap/main.zig:863` 读 `request.rpc.?.id != 0` 当授权，`bootstrap/activation.zig:286-293` 据此**持久**改写 `session/runtime.lock`。任意同用户进程可伪造一次 `shell_commit` + `id=1` + 任意 identity，之后正常 GUI 启动在 `bootstrap/main.zig:926` 撞 `ShellLockMismatch`；若伪造成内置 sibling id 反而被当成"内置切换"静默放行。
2. **本机 RPC 无对端认证**：`ports/host_control.zig:97` 用默认 DACL、管道名由 `sha256(data_dir)` 生成（`vne/host_protocol.zig:21`），请求头无 token。配合 3 可替换当前文档、取消全部作业、写任意已授权路径。
3. **`.command_result` 绕过受管语义**：`host/shell_rpc.zig:370-375` 直接转 `runtime/native_api.zig` 的 `cutrans_vm_command_result`，不查 epoch、不查 expected stamp、不查 `managed`/`runtime_only`。`vne/commands.zig` 的 `forwarded` 至今无人调用，"单一真源"只覆盖了分类。

## 未修：P1

4. **校验字节 ≠ 装载字节**：`bootstrap/activation.zig:205` 校验后 `:222` 才 `Library.open`，`ports/library.zig:17` 带 `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`（同目录兄弟 DLL 优先于 System32）；manifest 的 SHA 自证，无签名。
5. **内嵌 payload 缓存根来自 `TEMP`/`TMP`**（`bootstrap/main.zig:167-170`），落在可预测的 `%TEMP%\cutrans-embedded-payload\<blob>/<flavor>`（`bootstrap/payload_embed.zig:77`），`pruneStaleCache`（`:51-63`）会递归删除该根下非当前 blob 的目录，无 reparse point/owner 检查。该目录被当作 `resource_dir` 使用，与 `vne/paths.zig` 声称的"只读资源"边界冲突。
6. **旧 `import` 通道绕过来源边界**：`runtime/external_sources.zig:238-281` 不走 `source_boundary.check`、不查 hardlink/final path（新口岸 `:102-123` 三者都查），可把 VM 私有文件登记成 owned 资源再导出；`:646-659` 的测试正把这个绕过当预期行为。
7. **`asset.export` 目标可为 data 根下任意 `session://` 相对路径**（`runtime/assets.zig:396-401`）：`session://library/catalog.json` 会把 catalog 建成目录，下次启动 `Runtime.create` 失败，应用永久起不来，只能手删。
8. **容量与回收**：外部来源 `[8]`（`runtime/external_sources.zig:132`）、授权槽 `[8]`（`vne/mounts.zig:16`）、库资源/文件夹各 `[32]`（`runtime/resource_library.zig:140,142`），**都没有删除入口**。录满后永久不能新增，删文件也不释放。授权槽还被 `doc.open`、`asset_open_external`、导出快照共用。
9. **GUI 客户端落后不会重同步**：`apps/library/work_model.zig` 从不更新 `base_revision`；切片 B 之后，落后的保存会立即返回过期版本，页面停在拒绝状态，需要重开资源。

## 未修：P2 / 基础设施

10. 两段式"先问长度再读"不复核第二次长度（`host/shell_rpc.zig:212-225`、`:386-399`、`:180-210`），`readSource:251` 与 `jobs_main` 的 `jobsReply` 是正确写法。
11. `host/lifecycle.zig:14-21`：lifecycle 文件损坏或 mode 不符即拒绝启动，无 quarantine。
12. `.stopping` 单向、无超时、无归属（`host/lifecycle.zig:155-163`），Shell 在 prepare/stop 之间崩溃即卡死，只能 CLI `start` 收尾。
13. 单实例管道 + 串行 accept + 5s 超时 + 按声明长度预分配 17MB（`ports/host_control.zig:89-133`、`host/lifecycle.zig:200`），一个"连上不发"的本地进程可反复锁死 Host。
14. receipt 的 client 槽位在合法性校验之前占用且 4096 上限永不淘汰（`runtime/document_requests.zig:56-62`）。
15. PNG 解码前无像素预算（`imaging/image.zig:46`，stb 上限 `1<<24`/维）；`export_inputs` 有专门的 bomb 负例，说明预算只覆盖了导出路径，登记/预览路径未见。
16. **vne 层测试从不执行**：`addModule(test, vne)` 以 `vne/root.zig` 为根发现 0 个测试；本次只把 `vne/documents.zig` 补成显式根，其余 `vne/*.zig` 未确认。
17. **`build test` 的构建运行器失败**：约 20 个测试二进制被标记 `failed command`，但单独运行同一二进制 **143/143 通过、退出 0**；HEAD 同样复现。运行器型失败不改变退出码（断言型才变 1），所以"退出 0"不能单独当全绿证据。
18. 仓库体积：`.zig-cache` 51.95 GiB、`scratch` 15.42 GiB（1178 个验证目录、12.98 GiB）。证据"永不自动删除"是刻意设计，但没有预算。

## 下一步顺序（建议）

1. GUI 重同步 + `hasPending`/`abandonPending`（修"落后即卡死、关不掉窗口"）。
2. 容量与回收（`source.remove`/`library.remove`、槽位复用、容量错误显式化）。
3. `asset.export` 目标白名单 + 旧 `import` 通道收敛到 `readFileSnapshot`。
4. RPC 授权面：会话 token + 禁止从 wire 取授权决定 + `.command_result` 拒绝 managed/runtime_only。
5. 基础设施三项（vne 测试覆盖、build runner 失败、`.stopping` 自愈）单独排期。

## 复现命令

- 隐藏入口：`tools/dev.ps1 build <step>`（日志在 `scratch/verification/developer-<case>/run.log`，同目录 `result.json` 有退出码）。
- 本片验证：`build verify-work-documents`、`build verify-write-order`、`build verify-architecture`、`build verify-repository`。
- 直接 `zig build test` 需要把 uv CPython 目录前置到 `PATH`（构建步骤调用 `python`）；隐藏入口已自动处理。
- 判断测试真伪：对可疑二进制单独运行（不带 `--listen`）看逐条结果，不能只看 `build test` 的 `failed command` 或退出码。

## 未验证

真实 GUI/IME、安装升级卸载、真实媒体、掉电注入、跨 OS、多用户/提权部署下的管道 DACL 行为都没有验收。上面所有缺陷都是静态读码 + 真机命令验证得到的，没有做攻击演示。
