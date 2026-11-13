# Cutrans 统一 NanoUI 前端

## 当前结构

```text
cutrans.exe                 唯一入口：一个进程 = 一个环境实例（Runtime、作业线程、生命周期）+ App
cutrans_bootstrap.exe       无界面：Runtime Pack 诊断、无头打开与回放
cutrans_vm_runtime.dll      动态 Runtime Pack（也供 ctypes 验证）；默认使用链接进 cutrans.exe 的静态 Runtime
```

主桌面不再使用 zgui、GLFW、wgpu-native、ImGui 或 CUI。Runtime 也不依赖这些库；图像编解码继续使用 stb，窗口和 UI 呈现统一由 NanoUI 负责。

## 统一桌面

`apps/desktop/nanoui.zig` 是主前端入口，`nanoui_model.zig` 持有 App 本地状态，`nanoui_view.zig` 组合页面：

- **首页**：当前文档投影与真实工作流入口，不放未接线按钮；
- **编辑器**：`.cut` 文档、DAG 单帧预览、History、PNG 导入和导出；
- **资源库**：复用 `apps/library/nanoui_model.zig` 与 `nanoui_view.zig`，可预览并插入文档；
- **CLI**：经同一命令注册表执行命令，区分 `accepted` 与最终结果；
- **任务**：经环境的 `Control.jobsRead` 读取 JobRecord 分页，支持取消和以原输入重试。

页面状态只是 VM 的投影。`consoles/gui/vm_client.zig` 负责文档、History、播放、Catalog 和 Station 镜像；App 不恢复第二份业务真源，也不直接修改 VM 数据。

## 环境与安全退出

`cutrans.exe` 在同一进程内创建 Runtime 并启动作业驱动线程，再把进程内的 `ShellApi` 函数表和一张 `vne.environment_control.Control` 表交给 App（`bootstrap/main.zig` 的 `runEnvironment`、`bootstrap/instance.zig`）。没有 Host、RPC、重连或“结果未知”：进程内调用要么返回已知结果，要么在执行前被拒绝。

窗口关闭与“退出虚拟环境…”调用同一个 `Control`：`prepareStop` 关闭 Runtime 的业务受理，`cancelJobs` 协作取消，`resumeWork` 撤销退出，`stopEnvironment` 冲刷作业终态、保存文档并记录正常停止，同时提交本次 App 选择。`library` 动作用同一种实例打开独立资源库界面。载荷来自 `payload/desktop`、`payload/nanoui-library`，缺失时使用 exe 内嵌副本。

## 输入与呈现

`consoles/gui/nanoui_input.zig` 把 NanoUI 输入事件转换为 VM 语义事件：指针、按钮、按键、UTF-8 文本、焦点和文本上下文。它不注入 OS 输入，不处理 IME 组合状态的全部细节；真实键盘、焦点和 IME 手感仍需单独验收。

`apps/editor/nanoui.zig` 用既有 `render.Preview` 求值，把 RGBA 转换为 NanoUI 所需的预乘 BGRA。预览 key 包含文档指纹与求值代际，不伪造缓存体系。

NanoUI 的 `on_present` 回调只在成功 GPU swap-chain present 后触发。`apps/desktop/nanoui_model.zig` 用它发送带文档指纹的 `FrameReport`；GDI 输出不冒充 GPU submitted。离屏 D3D 验证也区分 GPU 渲染证据与真实窗口视觉。

## 所有权

- 桌面模型原地分配、初始化并销毁，不能搬移含自指针的上下文。
- `render.Preview` 持有预览帧和 Source 访问策略，像素转换缓冲按代际替换。
- 文档、History、Job、Catalog 与授权的真源留在 Runtime；App 只保存投影；进程内提交被拒绝时直接丢弃该请求并换用新的客户端身份。
- 任务页经 `Control.jobsRead` 读取环境的真实作业页，控制台不维护第二份任务历史。
- NanoUI `Options.kv=false`，不启用隐式持久 KV；旧 `imgui.ini` 不再参与产品状态。

## 验证

- `test-nanoui-desktop`：统一桌面及输入、像素转换和任务投影编译/模型测试。
- `verify-static-runtime`、`verify-payload`、`verify-preview`、`verify-single-exe`：单进程桌面与资源库的隐藏场景、预览、载荷与单 exe 分发。
- `verify-safe-exit`：等待／取消导出、退出中拒绝新业务、撤销、异常结束、单写者锁、草稿保护与保存失败重试。
- NanoUI Tester 与 D3D readback 验证离屏渲染；不截图、不注入真实键鼠。

这些检查不替代真实窗口视觉、IME、安装升级卸载或发布验收。
