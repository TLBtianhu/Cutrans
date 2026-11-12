# 2026-11-10 Shell 与 imaging 解耦

本片把 Shell 最后一个 `runtime` 直接依赖拆掉：图像编解码移到共享 `imaging` 模块，`vm_client` 不再导入 runtime。

## 改动

- `runtime/image.zig` 的 PNG 编解码移到 `imaging/image.zig`：
  - 共享 `Image`、`decode`、`load`、`preparePng`、`savePng`、`savePngExternal`；
  - 仍依赖 stb，由实际使用方链接。
- `runtime/image.zig` 变成薄 re-export shim；Runtime 继续通过它工作。
- `build.zig` 新增 `imaging` 模块：
  - `runtime`、static/dynamic Runtime、`vm_client` 和 image 测试都显式导入；
  - image 测试的 root 改为 `imaging/image.zig`。
- `vm_client`：
  - 改用 `@import("imaging")` 解码；
  - `sourceProvider` 改为 Shell 本地 `SourceProvider`/`Source`，不再引用 `runtime.render`；
  - build 不再声明 `runtime` 依赖。
- `tools/verify_architecture.py` 增加文件级规则：`consoles/gui/vm_client.zig` 不得导入 runtime/host/bootstrap。

当前 Shell GUI 依赖：

```text
apps/desktop, apps/editor, console -> vm_client.Context, vne, nanoui, imaging
vm_client                           -> vne, imaging, shell
```

`consoles/gui/launcher.zig` 仍可导入 bootstrap，因为它负责进程编排，不是 App 投影。

## 验证

- `build test`：退出 0，`developer-d7143bcbbd67/`。
- `verify-payload`：退出 0，`developer-58c5d2215692/`。
- `build verify-architecture`：退出 0，`developer-b1bb936bfbca/`。
- `verify-repository`：退出 0，`developer-26275c218efe/`，selected=755、required=759、markdown=91、local_links=289。

## 仍未解决

- Runtime 仍拥有 `runtime.image` shim，VM 的图片编解码仍走同一 stb 实现；这是共享实现，不是 Shell 绕过 ABI。
- `RuntimeContext` 内部仍含 Shell 视图字段，尚未拆成纯业务 Context。
- 没有真实 GUI/IME、视觉、安装验收；安装器未在 ABI 11 后重建。
- 未提交、未推送、未发布。
