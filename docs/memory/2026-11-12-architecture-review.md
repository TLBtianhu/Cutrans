# 2026-11-12 架构评审与收敛方案（建议，未实施）

## 状态

用户询问“要让架构更清晰彻底要做什么”。本记录是评审与方案，**不是已批准的实施决定**，也没有代码改动。方向若确认，建议从阶段 0 + 命令 manifest 与 `verify-contract` 开始。

## “清晰”的可验收定义

1. 单一真源：命令、能力、状态、持久 schema、文档每个事实只定义一次。
2. 依赖单向且可检查：层间依赖、环、绕行由工具失败，而不是靠自觉。
3. 数据有主：每份持久数据有 owner、版本、迁移、事务和恢复语义。
4. 重复接线由 manifest 生成或校验：ABI、RPC、命令、文档不靠人肉同步。
5. 状态机显式：生命周期、未知结果、错误类型是表，不是散落字符串。
6. 测试分层：单元、契约、真实进程、封存产物、安装各自可跑。
7. 构建可复现：工具链、缓存、环境自包含。

## 当前结构债

| 问题 | 现状 |
| --- | --- |
| Runtime 偏单体 | `runtime/` 731 KB；`resource_library` 105 KB、`native_api` 90 KB、`document_commands` 74 KB、`external_sources` 60 KB、`assets` 59 KB |
| 命令多处手写 | 38 条命令；分类已集中到 `vne/commands.zig`，但 runtime handler 配对、Shell 注册和文档表仍各有一份 |
| ABI 接线人工 | `ShellApi` 约 25 个函数字段、34 个 RPC kind；加一个功能要改 5–6 处 |
| 持久格式各自为政 | Catalog v4、grant、task/history journal、work receipt、pending marker 各有自己的版本与迁移方式 |
| 错误分类分散 | `abi.Status`、`command.Code`、`workspace.Status`、resource status、状态栏文本并存 |
| 测试偏重 | 32 个 `verify_*`、约 9,800 行；每个脚本自己起 Host；证据 15.4 GB |
| 构建入口偏大 | `build.zig` 51 KB、58 个 step；`.zon` 路径清单手写；本地缓存 48.7 GB，Zig 全局缓存 1.55 GB 在仓库外 |
| 文档漂移 | `runtime.md` 仍写 ABI10、自动重连“尚未实现” |

## 分阶段方案

### 阶段 0：写死契约（1–2 天）

- 新增 `docs/architecture/contracts.md`：层依赖表、数据归属、协议/版本规则、错误分类、生命周期状态机、新功能检查单。
- 为未定问题写 ADR：插件/效果模型、持久回执 vs 显式 unknown、Catalog schema owner、媒体管线。
- `runtime.md` 改成“投影 + 链接”，不复制会漂移的 ABI/状态数字。

### 阶段 1：单一真源 + 生成/校验（1–2 周）

1. 命令 manifest v2：entry 包含名字、args schema、owner、managed、stale_allowed、是否建节点、是否公开；生成 Runtime 注册骨架、Shell 转发表、命令文档和覆盖测试。
2. 能力/效果 manifest：进入 `vne`，Pack 清单和文档由它生成。
3. ABI 表驱动：ShellApi 字段附 RPC kind/方向/载荷约束；`@typeInfo` 完整性测试；ABI 版本检查单自动核对。
4. 状态/错误表：一个规范 enum + 映射表，测试覆盖每个状态。
5. 文档生成：命令/能力/状态表由代码生成；README 仍手写。

验收：`verify-contract` 在任何一处漂移时失败。

### 阶段 2：域边界变成接口（2–4 周）

- 拆 runtime 为 documents/history、library/catalog/versions、station/assets、sources/grants、jobs/export、playback/render、storage 域；每域显式接口，`document_commands` 只编排。
- 效果/节点注册表：`vne` 声明 schema + runtime handler 注册；新增效果不改 `native_api`/`document_commands`。
- 架构守卫升级为完整 import 图（别名、相对导入、重导出、环、兼容 shim、文件预算）。
- 按 owner 拆文件，不做纯行数拆。

### 阶段 3：数据与生命周期（2–3 周）

- 统一 `storage`：原子写/读/校验；持久文件声明 `{format, version, owner, migrator}`；启动迁移或失败关闭。
- 明确事务边界（文档 + History + Catalog head）并补提交后失败/写一半崩溃测试。
- 未知结果/回执策略表：按域定义 idempotency key、receipt 生命周期、是否跨 Runtime。
- 归属与删除规则可执行。

### 阶段 4：测试与构建（1–2 周）

- 共享 Host/Shell session 与封存产物模式；测试分 tier。
- 契约测试由 manifest 生成；统一故障注入（丢回复、杀进程、慢 IO）。
- `verify-devenv`：清空 PATH/APPDATA/TEMP 仍可构建；Python/uv、Zig 全局缓存全部仓库内；同 commit 同产物哈希可复现。
- 缓存/证据报告与预算。

### 阶段 5：产品硬化（持续）

真实媒体、时间轴、安装升级卸载与真实 GUI/IME 验收、不可信插件沙箱。沙箱必须排在效果注册表和声明 schema 之后。

## 优先级与工作量

- 阶段 0–1：约 1–2 周，立刻减少漂移。
- 阶段 2：约 2–4 周，是“彻底”的大头。
- 阶段 3–4：约 3–5 周。
- 单人全职约 6–9 周做到“结构清晰可执行”，产品能力另算。

## 不建议做的事

- 不为“彻底”换语言或重写 UI 栈。
- 不在效果注册表/声明 schema 之前做动态插件加载。
- 不过度抽象 ABI/status；表和生成即可。
- 不按行数拆文件；按 owner 和事务边界拆。
- 没有持久回执时不声称跨重启 exactly-once。

## 建议下一步

先做阶段 0 + 命令 manifest v2 + `verify-contract`：不改行为，只把命令、状态、文档和 ABI 的漂移变成构建失败；然后再拆 `resource_library` 与 `document_commands`。等待用户确认。
