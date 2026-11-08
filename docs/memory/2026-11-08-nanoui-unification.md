# 统一 NanoUI 前端与旧 UI 清理（2026-11-08）

用户要求整理项目，将旧 UI 库移除并迁移到当前 NanoUI，先统一架构。本记录区分实施、当次验证和未覆盖范围；旧桌面历史验收不自动成为新前端证据。

## 决定与实施

- 保留 VM、Host、RPC、文档、资源、授权和 Job 语义。主桌面统一为 NanoUI，包含首页、编辑器、资源库、CLI 和任务视图；`cutrans_library_nanoui.exe` 继续作为独立资源库诊断 Shell。
- 新主入口为 `apps/desktop/nanoui.zig`。`nanoui_model.zig` 原地持有 Shell 投影与本地状态，`nanoui_view.zig` 组合页面。编辑器复用原 Document 请求、Source 读取与 `render.Preview`，资源库复用现有 NanoUI 模型/视图，CLI 复用命令注册表，任务页读取真实 Host JobRecord。
- `consoles/gui/nanoui_input.zig` 将 NanoUI 输入转换为 VM 语义事件，不注入 OS 输入。编辑器把 RGBA 转换为 NanoUI 预乘 BGRA。
- NanoUI 新增 `on_present` 窄回调，只在成功 GPU swap-chain present 后触发，GDI 输出不冒充 submitted。回调补丁及测试列入 `third_party/nanoui/VENDOR.md` 与 `VENDOR.json`，本地补丁由 8 增至 11 个文件，有效源码锁已重新计算。
- `cutrans_shell.exe` 取代 `cutrans_desktop.dll` 成为主 Shell Pack 入口。zgui、zglfw、wgpu、system_sdk、旧 CUI、旧 ImGui 后端与相关构建/分发清单已移除；两份旧 SDK `.so` 同时从 Git 索引移除。
- PNG 编解码仍使用 stb。旧 zgui 目录中的 `imstb_image_write.h` 是独立编码头，已单独保留到 `third_party/stb/`，不恢复任何 ImGui 代码。
- `shell/client.zig` 新增真实 `jobsRead`，控制台不复制第二份任务真源。独立资源库可增加“插入到文档”回调，仍经受管理文档请求。

## 构建和静态验证

- `test-nanoui-desktop` 首次通过 6/6 steps，统一桌面及测试成功。
- 首轮完整构建曾为新任务投影测试的期望值笔误失败 1 项（`retry_of` 应为 8，不是 9）；修正后 `test-core test install portable` 为 166/166 steps、2/2 当次执行测试通过，其余有效缓存。
- `verify-repository` 最终通过：selected=1050、required=1054、Markdown=69、local_links=204、retained_sdk_binaries=0。
- 共享缓存曾引用不存在的 `options.zig`。独立缓存对照通过后，仅删除可重建的 `.zig-cache/h` 元数据，标准构建恢复；未清空全部缓存或历史证据。
- 多轮编译错误均按实际日志修复，包括缺失编码头、命名遮蔽、函数重名、回调类型、输入事件字段和测试期望值。未将失败笼统归因于环境。

## 实际 Host/Shell 验证边界

- `verify-shell` 最终 31/31 steps 通过：缺失 Pack 拒绝、文档打开、首个 GPU Present、完整播放至 t=3、编辑/撤销/重做、真实 PNG 导出、Pack/Session 快照、外部引用、独立化、目录操作、CLI、任务页及 D3D 离屏检查均通过。桌面 D3D 平均差异 0.0066，动态纹理 0.0447；未截图或注入真实键鼠。
- `verify-nanoui-library` 最终 53/53 steps 通过：独立资源库附着、预览、刷新、独立化、移动、重命名、窄窗口、D3D、Pack 纯净和成功/失败选择提交均通过。日志中的 `AssetPreviewFailed` 属于故意损坏 Pack 的负例，随后验证没有提交选择。
- `verify-attach` 最终 31/31 steps 通过：四次附着、Host 存活、素材、播放和停止/重启均通过。成功无窗口场景提交 `desktop-shell`，随后异常关闭不改变锁。首次失败来自旧断言未区分这两种语义，已修正。
- 播放曾停在 t=2，定位为 Windows NanoUI 不会仅因 `time_driven=.fast` 持续排帧，改为播放期间显式 `frameIn(0.016)` 后完整提交至 t=3。`app.open editor` 和首页导航也已按真实初始化路径补齐。
- `verify-nanoui-portable` 最终 31/31 steps 通过：便携副本默认解析、显式验证数据根、资源库与 Pack 纯净通过。
- `verify-runtime verify-isolation` 最终 61/61 steps 通过：独立 Runtime、保存恢复、迁移/回滚、篡改拒绝和 12 组环境/故障隔离通过，旧图形库不再成为依赖。
- `verify-jobs-async verify-resource-registration` 最终 32/32 steps 通过：异步作业 9 组、通用登记 14 组全部通过，inconclusive=0。
- 本轮证据分别位于 `scratch/verification/developer-fe4d361141cb/`、`developer-e453df371c33/`、`developer-7fd75b53f543/`、`developer-cc9b91ebc953/`、`developer-5e8a790e82aa/`、`developer-671fcadc3242/`、`developer-b482b459b9be/`、`developer-1ac9cbf1753e/` 和 `developer-2a0b4b22d246/`。首次 `verify-shell` 的 31 steps 与附着 31 steps 属不同目标，不累加为唯一测试数。最终依赖审计、格式检查和仓库审计通过，结束后无后台任务或 Cutrans 进程。

真实窗口视觉、IME、焦点与操作手感未验收。完整安装、变更资产升级、卸载、系统登记和发布未执行。以上结果只证明本次 NanoUI 迁移产物，不延伸为正式版本发布结论。
