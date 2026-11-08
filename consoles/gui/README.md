# Cutrans Shell 与统一 NanoUI 前端

## 当前结构

```text
cutrans_vm.exe              Bootstrap 与 Host 控制入口
cutrans_vm_host.exe         独立 Host，持有 Runtime 与作业驱动
cutrans_vm_runtime.dll      文档、资源、授权、History 与 Job 真源
cutrans_shell.exe           统一 NanoUI 桌面 Shell
cutrans_library_nanoui.exe  独立资源库诊断 Shell（可选）
```

主桌面不再使用 zgui、GLFW、wgpu-native、ImGui 或 CUI。Runtime 也不依赖这些库；图像编解码继续使用 stb，窗口和 UI 呈现统一由 NanoUI 负责。

## 统一桌面

`apps/desktop/nanoui.zig` 是主前端入口，`nanoui_model.zig` 持有 Shell 本地状态，`nanoui_view.zig` 组合页面：

- **首页**：当前文档投影与真实工作流入口，不放未接线按钮；
- **编辑器**：`.cut` 文档、DAG 单帧预览、History、PNG 导入和导出；
- **资源库**：复用 `apps/library/nanoui_model.zig` 与 `nanoui_view.zig`，可预览并插入文档；
- **CLI**：经同一命令注册表执行命令，区分 `accepted` 与最终结果；
- **任务**：读取 Host 的 JobRecord 分页，支持取消和以原输入重试。

页面状态只是 VM 的投影。`consoles/gui/vm_client.zig` 负责文档、History、播放、Catalog 和 Station 镜像；Shell 不恢复第二份业务真源，也不直接修改 VM 数据。

## Host 与附着

默认 `cutrans_vm.exe` 启动或复用 Host，再由 `cutrans_shell.exe` 附着。Shell 通过版本化本机 RPC 调用 Host，关闭 Shell 不销毁 Runtime，已接受的导出可以继续。`library` 命令仍可选择独立资源库诊断 Shell；日常产品入口只有一个。

`bootstrap.runAttached` 统一处理 Pack 校验、Shell 预检、RPC、外部文档授权和成功后的选择提交。失败不会提交新的 Shell 选择锁。开发、便携和安装形态分别解析 `vm-shell/`、`shell/`、`shells/desktop/`；独立资源库位于 `nanoui-library/` 或 `shells/nanoui-library/`。

## 输入与呈现

`consoles/gui/nanoui_input.zig` 把 NanoUI 输入事件转换为 VM 语义事件：指针、按钮、按键、UTF-8 文本、焦点和文本上下文。它不注入 OS 输入，不处理 IME 组合状态的全部细节；真实键盘、焦点和 IME 手感仍需单独验收。

`apps/editor/nanoui.zig` 用既有 `render.Preview` 求值，把 RGBA 转换为 NanoUI 所需的预乘 BGRA。预览 key 包含文档指纹与求值代际，不伪造缓存体系。

NanoUI 的 `on_present` 回调只在成功 GPU swap-chain present 后触发。`apps/desktop/nanoui_model.zig` 用它发送带文档指纹的 `FrameReport`；GDI 输出不冒充 GPU submitted。离屏 D3D 验证也区分 GPU 渲染证据与真实窗口视觉。

## 所有权

- 桌面模型原地分配、初始化并销毁，不能搬移含自指针的 `RuntimeContext`。
- `render.Preview` 持有预览帧和 Source 访问策略，像素转换缓冲按代际替换。
- 文档、History、Job、Catalog 与授权的真源留在 Runtime；Shell 只保存投影和未确认的原请求。
- `shell/client.zig` 的 `jobsRead` 返回真实 Host 作业页，控制台不维护第二份任务历史。
- NanoUI `Options.kv=false`，不启用隐式持久 KV；旧 `imgui.ini` 不再参与产品状态。

## 验证

- `test-nanoui-desktop`：统一桌面及输入、像素转换和任务投影编译/模型测试。
- `verify-shell`：真实 Host、文档打开、NanoUI 启动、播放提交、资源闭环和缺失 Pack 拒绝。
- `verify-attach`：重复附着、Host 存活、素材和播放回执、异常退出不提交 Shell 锁。
- `verify-nanoui-library` / `verify-nanoui-portable`：独立资源库及分发回归。
- NanoUI Tester 与 D3D readback 验证离屏渲染；不截图、不注入真实键鼠。

这些检查不替代真实窗口视觉、IME、安装升级卸载或发布验收。
