# 2026-11-10 自定义窗口 chrome 与安全关闭

> 后续已同步到官方 NanoUI v0.14，改用官方 `chrome.zig`（`decorations=true` + `title_bar=.hidden`，保留原生 resize/Snap/阴影）；本页的 borderless `WS_POPUP` + `border_resize` 方案已不再使用。最新记录见 [NanoUI v0.14 sync](2026-11-10-nanoui-v014-sync.md)。

本片把窗口从“原生边框 + 最大化”推进到“无边框自绘 chrome”，并先修了一个独立的安全语义：**任何关闭路径都不能绕过安全退出**。NanoUI 的 borderless resize 仍是本地 vendored 补丁，不是已合并上游特性。

## 安全关闭语义

- `desktop.State.shouldClose` 现在按 `closeAction(phase)` 分派：
  - `.inactive` → `beginExit()`，返回 `false`；窗口保持打开，进入退出界面；
  - `.confirm` / `.waiting` / `.cancelling` / `.ready` / `.stopping` → `false`；
  - `.failed` / `.stopped` → `true`，允许真正销毁窗口。
- Alt+F4、任务栏“关闭窗口”、未来的自绘 X 都经过 `WM_CLOSE`/`shouldClose`；普通关闭不再只是 detach Shell。
- `State.requestClose()` 给自绘 X 使用同一套 `closeAction`；退出进行中按钮 disabled，失败/停止后才真正关闭。
- 单测 `closing starts safe exit unless it already finished or failed` 覆盖所有 phase。

## NanoUI borderless resize 本地补丁

- 新增 `third_party/nanoui/src/windows/border_resize.zig`：
  - 只对 `WS_POPUP + WS_THICKFRAME`（`decorations=false` + `setResizable(true)`）生效；
  - 在 `WM_NCHITTEST` 中按 6dp（至少 5px）边缘返回 `HTLEFT`/`HTTOPRIGHT` 等；
  - 最大化/最小化状态不进入 resize；
  - 不改装饰窗口的原生行为。
- `src/windows/window.zig` 的 WndProc 调用该 helper；`win32.zig` 增加 `WM_NCHITTEST`/`HT*` 常量。
- `tests_window.zig` 用隐藏窗口 + `SendMessageW(WM_NCHITTEST, ...)` 覆盖四边、四角、内部、`setResizable(false)`；没有真实拖拽。
- `VENDOR.json.local_patches`、`VENDOR.md` 已记录该补丁；`dependencies.lock.json` 由 `python tools/dependency_audit.py --record` 更新为 `dac7ef...` / 806 files，复核通过。
- 这是 **Cutrans 本地补丁 / 上游 PR 候选**，不是已合并上游；`absorbed_pull_requests` 仍不是贡献统计。

## Cutrans 自绘 chrome

- 桌面窗口改为 `decorations=false`、`title_bar=.hidden`；保留单顶层窗口和任务栏项。
- 新增 38px 自绘标题栏：
  - 空白区域 `window_drag` 拖动；
  - 最小化 → `Window.minimize()`；
  - 最大化/还原 → `Window.zoom()`；
  - 安全退出 → `State.requestClose()`，退出进行中禁用；
  - F11 仍走同一 `zoom()`。
- 窗口创建后 `setResizable(true)`；通过本地补丁的边缘 hit-test 恢复缩放。默认仍 `setFullScreen(true)`（Windows 最大化的语义，不是无边框全屏）。
- 首页说明改为“自定义标题栏最小化/最大化；F11 最大化/还原”。
- 桌面 fixture 断言标题栏 `最大化/还原` 与 `安全退出` 存在；退出 fixture 改为点击自绘“安全退出”，不再只点首页入口。

## 实际验证

- `tools/dev.ps1 build test-nanoui`：退出 0，`developer-81669e1c13f0`；隐藏 window 测试通过。
- NanoUI `zig build lines`：`377 files, all within 600 lines`。
- `tools/dev.ps1 build portable`：退出 0。
- `tools/dev.ps1 build test`：最终退出 0，`developer-70647601a155`。
- `tools/dev.ps1 build verify-local-sources`：退出 0，`developer-1cdadba2de77`；`CUTRANS_DROP_IMPORT_OK register_file=1 managed_root_refused=1`。
- `tools/dev.ps1 build verify-safe-exit`：退出 0，`developer-fb194cdaf890`；`stranded=1 control=1 save_retry=1 draft=1 restart=1`。
- `tools/dev.ps1 build verify-payload`：退出 0，`developer-8badcb4a2cef`。
- `tools/dev.ps1 verify-repository`：退出 0，`developer-5ebacc57c378/`，`selected=1089 required=1093 markdown=82 local_links=258 retained_sdk_binaries=0`。

## 上游分支与重复实现

- 本地 `scratch/nanoui-upstream`（官方 `justrach/nanoui` main `7b32272`）切了 `feature/windows-borderless-resize`，提交 `5d8fce7`，含 `border_resize.zig`、`win32` 常量、WndProc 调用和隐藏窗口测试；未 push、未开 PR。
- 该分支的 `zig build lines` 通过（902 files）；`zig build test` 有 1 个既有环境失败 `WS_EX_TOPMOST`（590 pass / 21 skip / 1 fail），与本补丁无关。
- **发现官方 v0.14 已有 `src/windows/chrome.zig`**：用 `decorations=true` + `title_bar=.hidden` + `WM_NCCALCSIZE`/`WM_NCHITTEST`，保留原生 resize、Snap Layouts、系统菜单、DWM 阴影和圆角。它比本地的 `WS_POPUP` borderless 方案更完整；因此本地的 borderless PR **不应提交上游**，只作为兼容性实验/备选。
- 下一步应优先 backport `chrome.zig` 到 0.12 vendor，或整体同步 0.14；本页的本地补丁是过渡实现，不是最终窗口架构。

## 未覆盖与保留边界

- 没有真实鼠标拖动窗口、真实边缘 resize、Snap Layouts、Alt+Space 系统菜单或真实标题栏视觉验收；`WM_NCHITTEST` 测试只证明消息答案，不证明系统拖拽手感。
- 没有真实点击自绘 X/最小化观察窗口动画；headless Tester 只验证布局和状态机。
- 无边框窗口失去了原生 Snap/系统菜单/部分辅助功能；阴影/圆角也未做，视觉仍需用户验收。
- 真实 GUI 测试期间最小化会暂停 NanoUI 呈现帧；Job/Host/草稿不受影响，但依赖帧报告的测试会等不到。
- 未安装、未发布；Cutrans 工作树未提交/未推送，上游分支只有本地 commit `5d8fce7`，PR 未创建/未合并。

## 同步账本提醒

- `absorbed_pull_requests` 是“同步时确认已吸收的 PR 记录”，不是某个人的 merged PR 数；版本快照也不等于 PR 计数。
- 当前 vendor 仍是 fork `00e5813` / 0.12 基线，官方 main 已到 0.14；本地 borderless 补丁没有假装已上游吸收。
