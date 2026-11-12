# 2026-11-10 内嵌 Payload 原型

本片把 `payload/desktop` 与 `payload/nanoui-library` 的 34 个文件打成一个确定性 blob，编进 `cutrans.exe`；外部 payload 缺失时从 exe 内物化到临时缓存，再用现有 PayloadSource 校验。外部 `payload/` 仍然优先，显式 `--shell-dir` 仍然权威。**portable run context 也内嵌**，所以只有 `cutrans.exe` 的目录也能启动。

## 构建

- `tools/build_payload_embed.py` 输入两个已生成的 payload 目录，输出：
  - `payload.bin`：`CTPE1` 魔数、32 位条目数、每条 `u16 path + u32 data`；
  - `payload_blob.zig`：`@embedFile("payload.bin")` 和 blob SHA-256。
- `build.zig` 用 `payload-embed` 输出目录，把 blob 模块挂到 `bootstrap_module` 与 `unified_bootstrap`；生成目录是构建图依赖，不读自身可执行文件。
- 当前 payload：桌面 20 文件 + 资源库 14 文件，合计约 130 KB；单个 `cutrans.exe` 可携带。
- `tools/build_context_embed.py` 把 **portable 和 installed** 两份 `cutrans-context.json` 编成 `context_blob`，挂到 `vne` 模块；外部 context 文件仍优先。
- `build portable-single` 只把统一 `cutrans.exe` 放到 `zig-out/single/`；当前大小 14,042,112 字节，目录内没有 payload/context/runtime 文件。start/桌面 headless/stop 和 installed 无 context 场景都通过。

## 运行时

- `bootstrap/payload_embed.zig` 解析 blob，按 `desktop/` 或 `nanoui-library/` 前缀物化到：
  `%TEMP%/cutrans-embedded-payload/<blob-id>/<flavor>/`
- 缓存命中不再只看 `payload.json`：逐文件比对 blob 内容，损坏/缺失会重建；写入先落到唯一 staging 目录，再 rename 到最终位置，并发启动只会有一个完整缓存胜出。超过 30 天的旧 blob 缓存目录会尽力清理。
- `bootstrap/main.zig` 的 `defaultShellDir`：
  - 外部 `payload/<flavor>/payload.json` 存在 → 用外部；
  - 不存在 → 物化内嵌副本并继续用 `payload_source.verifyCandidate`；
  - 显式 `--shell-dir` 缺失/损坏 → 仍然失败，不回退内嵌；
  - 外部 manifest 存在但损坏 → 仍然失败，不回退内嵌。
- 物化目录在系统临时目录，不写入未标记的验证 data 目录；payload 内容仍经 manifest 文件哈希校验。
- `vne/environment.zig` 在外部 context 缺失时按目录形状选择内嵌副本：`app` 用 installed context（product root 为父目录），其他 portable 形状用 portable context；`bin`（开发）和 `shells/*` 仍必须提供真实 context，缺失就拒绝。

## 验证

- `build verify-payload`：退出 0，`developer-03a647bbba14/`；输出
  `CUTRANS_PAYLOAD_VERIFY_OK ... embedded_fallback=1 single_exe=1 no_legacy_fallback=1 ...`。
  - 外部 payload 删除 → 内嵌副本完成桌面/资源库 headless 场景；
  - 只有一个 `cutrans.exe`（无 payload/context/shell/runtime 目录）→ 同一场景通过；
  - 显式缺失 Shell 目录与损坏 payload 仍拒绝；
  - 未回退旧 Shell Pack。
- `build test`：退出 0，`developer-253e6cac4927/`；包含缓存损坏重建、四线程并发物化，以及 portable/installed/development 三种 context 形状单测。
- `build portable`：退出 0。
- `build portable-single`：退出 0，`developer-4accf781f265/`；产物 `zig-out/single/cutrans.exe`，14,042,112 字节，目录内仅此文件。
- `build verify-single-exe`：退出 0，`developer-7c2d8634eb1d/`；
  `CUTRANS_SINGLE_EXE_VERIFY_OK files=1 start=1 shell=1 stop=1 cache_repaired=1 installed_context=1 external_payload=0 external_context=0`。
- `verify-local-sources`：见本轮最终记录。
- `verify-repository`：退出 0，`developer-c1e3726ffbb8/`，selected=745、required=749、markdown=85、local_links=270。

## 边界

- portable 与 installed context 都已内嵌；外部 `app/cutrans-context.json` 仍优先，但安装器已不再复制它。安装器只通过 preflight/artifact 检查，真实安装、更新、卸载、签名和发布未做。
- 内嵌副本写到 `%TEMP%`；旧于30天的目录会尽力清理，但没有通用的磁盘预算、配额或强制回收。
- 只用 headless/Tester 和真实 Host 进程验证；没有真实窗口、安装或发布验收。
- `test-nanoui` 连续四次全绿，但此前一次的 `WS_EX_TOPMOST` 失败未定位；与本片无直接关系。
