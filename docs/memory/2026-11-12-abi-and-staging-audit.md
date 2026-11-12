# 2026-11-12 ABI 接线审计与构建残留清理

## ABI 接线审计

- `vne/abi.zig` 的 `ShellApi` 字段全部是非可选函数指针；`shell/client.zig` 的 `api()`、`runtime/native_api.zig` 的导出表和测试 mock 只要少一个字段，编译就会失败。
- `host/shell_rpc.zig` 的外层 `switch (request.kind)` 没有 `else`；新增 `protocol.Kind` 必须补分支，否则编译失败。
- 静态 Runtime 经 `runtime/static_api.zig` 的 extern 表链接，由 `verify-static-runtime` 覆盖；动态 Pack 由 `verify-runtime` 覆盖。
- 仍由人工保证的一步：新增 ShellApi 字段时，要同时增加 `protocol.Kind` 和 Shell 客户端转发；编译器不会强制字段与 Kind 一一对应。这是已知边界，本片没有为此引入生成器。

本项没有代码改动；结论是 ABI 的“表齐全”和“RPC 分支齐全”已由编译期强制，剩余风险集中在人工映射。

## 构建残留核对

- 审计 `zig-out/portable`：
  - 顶层 `wgpu_native.dll`（9,117,696 字节，2026-11-07）；
  - `shell/` 下 `cutrans_desktop.dll`（10,522,624 字节）、`wgpu_native.dll`（9,117,696 字节）；
  - `shell/licenses/` 下 glfw、imgui、system_sdk、wgpu-native、zglfw、zgui 六份旧许可证。
- 以上文件都不在 `vm-pack.json`、`shell/shell-pack.json`、`runtime/runtime-pack.json` 的 `files` 列表里，是旧 zgui/zglfw/wgpu UI 栈删除后的残留，不是当前构建产物。
- 安装器只复制 `cutrans.exe`、`licenses/`、`README.md`；`portable-single` 只有一个 exe。因此这些残留不进入安装包，但会污染直接压缩 portable 目录的发布方式。
- 已精确删除上述 9 个文件（约 19.8 MB）；保留 `nanoui-library/`、旧 `cutrans_vm.exe`/`cutrans_bootstrap.exe`/`cutrans_shell.exe`、`runtime/`、`shell/` 等有意回退项。
- 重新构建 portable 后这些文件没有再生；`verify-payload` 通过，真实 Host + 隐藏 Shell 的 payload、preview 与桌面场景标记齐全。

## 验证

- `verify-payload`：退出 0，`developer-bc4a78932151/`；`CUTRANS_PAYLOAD_VERIFY_OK legacy_exe=0 legacy_pack=0 builtin=1 explicit_fallback=1 embedded_fallback=1 single_exe=1 no_legacy_fallback=1 pack_pure=1`，并含 `CUTRANS_PREVIEW_OK`、`CUTRANS_NANOUI_DESKTOP_OK`。
- 同片前的 `build test`、`verify-architecture`、`verify-repository` 结果见[命令清单记录](2026-11-12-command-manifest.md)。
- 没有新增代码、安装或发布验收。

## 边界

- 清理只动 `zig-out/` 可重建产物，不进入 Git；`zig-out` 仍是构建输出，不是发行物。
- 根因是安装 step 不会清理旧文件；若以后直接压缩 portable 目录，应改用全新 staging，或先按清单核对。自动纯净化尚未实现。
