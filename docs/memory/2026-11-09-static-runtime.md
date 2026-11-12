# 2026-11-09 静态 RuntimeProvider 与动态回退

## 本轮目标

在同 EXE 多角色之后，让统一 `cutrans.exe` 的 Host 默认使用内置静态 Runtime，不再要求外部 `cutrans_vm_runtime.dll`。保留动态 Runtime Pack 与旧入口作为开发、ABI 验证和回退路径，不把静态化扩张为一次性内嵌所有资源或合并进程。

## 实现结构

- `bootstrap/runtime_provider_static.zig` 是统一 EXE 的 Provider；`bootstrap/runtime_provider_dynamic.zig` 保持旧入口的动态行为。
- 两个 Provider 共享 `bootstrap/activation.zig` 的 `Activation`、ABI、选择锁、Shell 提交与停止底座，没有另写 VM 或恢复语义。
- `runtime/native_api.zig` 的既有实现同时生成原 Runtime DLL 与缓存内静态库；静态库只链接进 `cutrans.exe`，不新增发行文件。
- `runtime/static_api.zig` 声明同一窄 C ABI 的静态链接符号。Host 仍使用 `activation.Api`，Shell 的符号表由静态或动态 Provider 提供，主 Host／Shell ABI 保持 10，Resource API 保持 v4。
- 静态能力列表直接取自 `runtime.capabilities.declarations`，与动态 Pack 构建使用同一声明源；创建 Runtime 后仍逐项执行能力握手。

静态 Provider 的内置描述为 `cutrans-runtime-static/1`，`entry=builtin`，没有物理文件列表。锁中的 `manifest_sha256` 在这个分支是内置语义描述的 SHA-256，不冒充磁盘清单或 EXE 签名。

## 选择与迁移

- 统一入口默认使用静态 Runtime；显式 `--runtime=<绝对目录>` 仍经过完整动态 Pack 校验和动态加载。
- `--runtime=builtin` 显式选择静态 Runtime，并允许从锁定的另一种 Runtime 身份迁移。
- 不加显式选择时，既有不同 Runtime 身份仍拒绝启动，不能因实现切换而静默改写锁。
- 旧动态入口拒绝 `builtin`，不偷偷获得静态实现。
- 静态启动当前仍以桌面 Shell Pack 根作为只读运行时资源根；这保留了 `pack://`、启动清单和示例资源，不代表 Runtime DLL 仍被加载。

## 边界

- 默认便携包仍包含 `runtime/` 供动态回退，本轮没有删除原产物或正式发行载荷。
- Shell Pack、资源、字体和许可证仍需后续 `PayloadSource` 收口；当前不是最终单文件发行。
- 静态链接不提供不可信插件沙箱，也不改变 Windows 系统库依赖。
- 安装器公开入口尚未切换，没有安装、升级或卸载验收。
- 完整环境内安全退出、停止新业务受理和活动任务选择仍未实现。

## 验证

- `build test install portable` 已在 `developer-9d9f1b7daf35/` 退出0，证明静态库链接、动态入口与现有单元测试可编译运行。
- 首轮无 Runtime 目录诊断已成功保存并恢复，且准确暴露了显式动态路径曾被静态 Provider 忽略的问题；随后把本次 Provider 选择显式传入激活层，保留实际动态回退，不用日志标签冒充加载结果。
- `verify-static-runtime` 在独立声明的验证副本中移除 `runtime/`，实际静态 Host、桌面、资源库、保存恢复、动态回退、锁迁移与包纯净均通过。`developer-29d40d88ebee/` 退出0，静态诊断 `provider=static files=0`，显式动态诊断 `provider=dynamic files=10`；不同身份默认拒绝，`--runtime=builtin` 显式迁移成功，旧入口拒绝 `builtin`，显式缺失动态 Pack 没有回退或创建数据。最终标记 `CUTRANS_STATIC_RUNTIME_VERIFY_OK runtime_dir=0 host=1 shell=1 library=1 restore=1 dynamic_fallback=1 explicit_migration=1 pack_pure=1`，证据 `static-runtime-75ecc7c87bf2/`。
- 专项使用隐藏 NanoUI Tester，没有可见窗口、真实键鼠、截图、安装或发布。Zig 格式检查通过，证据 `format-f722c798283e.log`。
- 最终回归 `developer-cbdb9fa51df2/` 退出0：`build test install portable test-nanoui-desktop verify-same-file verify-host verify-local-sources verify-work-documents verify-resource-registration verify-nanoui-library verify-nanoui-portable verify-runtime verify-isolation verify-jobs-async`。同 EXE 静态角色、旧动态 Host、资源／正文／本机文件、独立库与便携 Pack、Runtime 恢复、12组隔离和9组异步作业均通过，异步 `inconclusive=0`。最终 `verify-repository` 退出0，证据 `developer-4d8c7b26bcfa/`：selected=1078、required=1082、Markdown=76、local_links=233；仓库审计同时解析新增 Python 脚本语法。没有提交或推送。
