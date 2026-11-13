# 2026-11-09 同 EXE 控制器、Host 与 NanoUI 角色

> **2026-11-12 取代说明**：同 EXE 多进程角色（`--role=host/shell/library`）已随 Host 删除，见 [单进程统一](2026-11-12-single-process.md)。原文保留。

## 职责模型

本轮把“虚拟环境已经建立”的先验落实到进程入口，而不是把 Host、Shell 和任务都合并成一个进程：

```text
cutrans.exe
  ├─ 默认：控制器，校验并启动／复用环境
  ├─ --role=host：独立 Host，持有 Runtime 与业务真源
  ├─ --role=shell：通过启动屏障后进入 NanoUI 桌面
  └─ --role=library：通过同一屏障进入独立资源库
```

内部角色参数是封闭的 `host / shell / library` 集合，只在首参数分发；未知角色拒绝。`bootstrap.main` 的旧入口不执行内部分发，显式传入角色会拒绝，避免旧控制器被误当作角色入口。

## 实际改动

- `bootstrap/roles.zig` 定义角色解析与统一入口选择。只有当前可执行文件名为 `cutrans.exe` 时，子进程才切换到当前 EXE；其它现有入口保持原来的文件与 Pack 选择。
- `consoles/gui/launcher.zig` 统一分发控制器、Host、桌面和资源库。桌面与资源库直接调用已编译进该 EXE 的 NanoUI 模块，不执行 Pack 内的旧 Shell EXE。
- `consoles/gui/vm_launcher.zig` 保留旧控制器的薄入口，不让回退程序携带整套 UI，也不复制业务实现。
- `bootstrap/main.zig` 复用原有 Runtime Pack 校验、Host 数据根、单实例锁、Shell handshake／commit 和生命周期协议。内部角色只改变代码入口，不取消环境建立屏障。
- `build.zig` 将 `cutrans.exe` 加入开发安装和便携包；NanoUI、stb 与系统 D3D 库链接到该入口。
- `tools/process_identity.py` 与 `tools/verify_same_file.py` 检查真实 Windows 进程的可执行路径与角色，并验证环境 Session、Shell 选择提交、NanoUI 工作流及 Host 生命周期。新增 `verify-same-file` 构建目标。
- `tools/verify_host.py`、`tools/verify_attach.py` 与 `tools/verify_shell.py` 支持同一路径承担不同测试职责；Host 是否由验证助手管理不再由 EXE 文件名隐式判断。

NanoUI 依赖没有改为共享其它项目的工作区，也没有更新固定版本。主 Host／Shell ABI 仍为 10，Resource API 仍为 v4；本轮没有新增 RPC。

## 已确认的边界

- 同一 EXE 不等于同一进程。Host 与 Shell 保持独立，窗口／Shell 离开不销毁 Host。
- 当前仍动态加载 `cutrans_vm_runtime.dll`，仍需 Runtime／Shell Pack、资源与许可证。
- Pack 清单仍包含旧 Shell 文件，作为完整性和选择身份的一部分；统一角色不执行这些旧入口。尚未把 Pack 入口改成当前 EXE，也未收缩最终发行文件。
- `EnvironmentSession` 继续使用 Runtime epoch，不是授权凭证；App 内的 `ShellConfig` 物理路径仍是过渡输入。
- 安装器公开快捷方式仍指向旧入口，本轮没有切换、安装、升级或卸载验收。
- 完整环境内“安全退出”尚未实现。本轮使用既有 Host 停止底座，不代称已具备停止新业务受理、草稿确认、活动任务选择与完整退出 UI。
- 静态 Runtime、内嵌载荷、受管发布、发布签名、最终只有 `Cutrans.exe` 的发行形态均待后续。

## 验证记录

- `build test install portable` 通过，证据 `developer-4ce5cc4ccea8/`。
- 同 EXE 综合场景已在 `developer-9ce6488f7015/` 取得 `CUTRANS_SAME_FILE_VERIFY_OK`，包含真实 Host 路径、单实例、停止失败保护、异常恢复、桌面、资源库、Shell 选择提交与重启；证据目录 `same-file-4bf4709d44b7/`。
- 首轮综合验证暴露验证助手把同一路径的 Shell 当作应停止 Host 的控制器，导致提前停止；随后显式拆分测试职责，产品启动／停止语义未因此改变。
- 直接角色查询最初错误假定参数顺序与控制器派生完全相同；资源库日志已证明工作流成功。查询随后按已启动 PID 核对真实 EXE 路径和角色，避免参数排列影响身份判断。
- 最终专项使用 `--assets-demo` 的隐藏 NanoUI Tester 与 D3D readback，不把可见窗口、播放、视觉、IME 或操作手感作为本轮验收范围。`developer-d1af7602da4f/` 退出0，最终标记 `CUTRANS_SAME_FILE_VERIFY_OK controller=1 host=1 shell=1 library=1 lifecycle=1 hidden_ui=1 pack_pure=1`；场景证据为 `same-file-fd27114c609f/`，`passed=true`，没有清理错误。
- 最终完整回归 `developer-00a496206db5/` 退出0：`build test install portable test-nanoui-desktop verify-host verify-local-sources verify-work-documents verify-resource-registration verify-nanoui-library verify-nanoui-portable verify-runtime verify-isolation verify-jobs-async`。覆盖旧 Host 回退、桌面模型、正文固定输入与持久回执、普通资源登记、本机文件、独立资源库及便携 Pack、Runtime 恢复、12组隔离负例和9组异步作业；异步作业 `inconclusive=0`。
- 本轮没有执行会创建可见窗口的旧 `verify-shell`／`verify-attach` 播放场景；相关播放、真实窗口视觉和 IME 仍须单独验收。综合场景曾执行过旧附着流程，但交付专项不依赖它，也不要求它证明视觉体验。
- Zig 修改文件通过 `zig fmt --check`，证据 `format-6e4a3c6f9a64.log`。固定依赖哈希审计通过，NanoUI 仍为固定 fork `00e5813`，证据 `dependency-ed0d79195068.log`。最终 `verify-repository` 退出0，证据 `developer-2b0f732fc2e0/`：selected=1072、required=1076、Markdown=75、local_links=228；该审计也解析本轮 Python 脚本语法。

没有安装、升级、卸载、发布、提交或推送；没有修改 NanoUI 固定源码或依赖锁。
