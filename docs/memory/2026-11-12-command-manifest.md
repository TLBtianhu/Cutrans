# 2026-11-12 命令清单单一真源

## 改动

- 新增 `vne/commands.zig`，集中维护 Shell/Runtime 共享的命令分类：
  - `forwarded`：Shell 转发、Runtime 注册的 37 条命令；
  - `runtime_only`：仅 Runtime 内部使用的 `task.cancel_all`；
  - `managed`：必须走 workspace receipt 的 14 条命令；
  - `stale_allowed`：投影过期时仍可尝试的 8 条只读/维护命令；
  - `node_creating`：会追加 DAG 节点的 5 条命令。
- `vne/workspace.zig` 的 `manages` 与 `createsNode` 改为委托该清单。
- `consoles/gui/vm_client.zig` 的 `register` 与 `allowedWhileStale` 改为读取该清单，删除两处手写列表。
- `runtime/document_commands.zig` 增加测试：Runtime 命令注册表数量必须等于 `forwarded + runtime_only`，且每个名字都存在。
- `vne/commands.zig` 自带测试：`managed`/`stale_allowed`/`node_creating` 是 `forwarded` 的子集，各清单无重复，`forwarded` 与 `runtime_only` 不相交。

## 验证

- `build test`：退出 0，`developer-157a32a6e878/`；启动器修复后复跑 `developer-041de1a2672c/`。
- `verify-architecture`：退出 0，`developer-da057aca689d/`。
- `verify-repository`：退出 0，`developer-8ec0a7b1f52d/`。
- 行为与协议字节未变；没有真实 GUI/IME、安装或发布验收。

## 附带修复

`tools/dev.py` 现在为子进程 PATH 前置启动解释器所在目录。`build.zig`/`build_support` 的 `python` 步骤此前依赖宿主 PATH，在只有 `pythonw.exe` 的隐藏入口下会 `FileNotFound`；现在统一落到启动 dev.py 的同一解释器，不再受 DSH 进程旧环境或 PATH 死路径影响。

## 边界

- 命令 handler 与参数仍是 `document_commands` 中显式配对，参数是字符串，没有 schema 校验；声明 schema/检查器（D）仍未做。
- `docs/reference/commands.md` 仍是人工维护的第四份表，尚未由清单生成；`task.cancel_all` 仍作为内部命令不对外列出。
- 本片只消除清单漂移，不改变重试、回执或 Host 重启语义。
