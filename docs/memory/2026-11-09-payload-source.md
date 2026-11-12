# 2026-11-09 PayloadSource 与内置 NanoUI 载荷

## 目标

在同 EXE 多角色和静态 Runtime 之后，解除统一入口对旧 Shell EXE 的强制依赖。统一 NanoUI 代码已经在 `cutrans.exe` 中，磁盘载荷应只承担资源、版本与身份，不再伪装成需要执行的旧 Shell。

本轮建立外置 PayloadSource，不同时宣称已完成资源内嵌或最终单文件发行。

## 结构

- `vne/payload.zig` 选择并验证载荷，分为 `builtin` 与 `legacy_shell`。
- `runtime_pack.Manifest` 复用现有字段、大小与 SHA-256 文件校验。新格式为 `cutrans-payload/1`，`entry=builtin`，不要求可执行入口文件。
- 桌面载荷位于 `payload/desktop/`，独立资源库位于 `payload/nanoui-library/`。两者分别有 `payload.json`。
- 资源清单复用旧 Pack 的启动清单、示例、命令和许可证输入，并补齐已内嵌字体对应的 OFL／Remix 许可证；字体字节仍按现有编译期资源使用，不重复外置。
- `bootstrap/main.zig` 在统一入口中使用 Payload 作为静态 Runtime 的只读资源根和 Shell 资源根，Shell 身份仍通过原 handshake／commit 协议提交。
- `tools/build_shell_pack.py` 仅在显式 `entry=builtin` 时生成 Payload 格式；原 Shell Pack 格式和入口校验保持不变。
- `payload-pack` 同时生成两个载荷目录，便携与安装布局保留原 Runtime／Shell Pack 作为回退，安装器公开快捷方式尚未切换。

## 回退与失败规则

- 默认入口必须找到有效 `payload.json`，不能因同目录存在旧 Pack 而隐式回退。
- 只有显式 `--shell-dir=<目录>` 才允许选择旧 `shell-pack.json`。旧入口仍按原方式使用旧 Pack。
- Payload 存在但损坏时直接拒绝，不能改选旧 Pack。
- 内置载荷继续沿用 `desktop-shell`／`nanoui-library` 身份；锁记录的是对应 `payload.json` 的内容哈希，不是 EXE 哈希或发布签名。
- 旧 Shell Pack 被显式选择时仍验证其中列出的所有文件，但统一 NanoUI 不执行其中的旧 EXE。
- 主 Host／Shell ABI 保持 10，Resource API 保持 v4；App 仍只见已建立的环境与业务接口。

## 尚未完成

- 资源目录尚未内嵌进 EXE，也没有受管发布、发布签名或升级事务。
- 默认便携包仍同时携带旧 EXE、Runtime DLL 和旧 Pack 供回退。
- 本轮没有切换安装器入口，没有安装升级卸载验收。
- 完整环境内安全退出仍未实现。

## 验证

- `build test install portable` 通过，证据 `developer-4177d47e53da/`。
- `verify-payload` 通过，证据 `developer-aace30ede1a2/` 与 `payload-48ae12815b8b/`。隔离副本移除旧 EXE、Runtime、旧 Shell Pack 及重复根资源后，统一桌面与资源库均完成真实 Host／NanoUI 场景；显式旧 Pack 保留原清单身份并成功提交。缺失默认 Payload 返回 `PayloadNotFound`，损坏资源返回 `RuntimeFileSizeMismatch`，均没有隐式回退或创建数据。
- 最终标记 `CUTRANS_PAYLOAD_VERIFY_OK legacy_exe=0 legacy_pack=0 builtin=1 explicit_fallback=1 no_implicit_fallback=1 pack_pure=1`，证据记录 `passed=true`，原产物与 stripped 副本哈希均未改变。
- 本轮验证使用隐藏 NanoUI Tester，不创建可见窗口、不模拟真实键鼠，不代替真实 GUI／IME 或安装验收。
- 最终完整回归 `developer-6ab7b80ff6c4/` 退出0：`build test install portable test-nanoui-desktop verify-same-file verify-static-runtime verify-host verify-local-sources verify-work-documents verify-resource-registration verify-nanoui-library verify-nanoui-portable verify-runtime verify-isolation verify-jobs-async`。同 EXE 与 Payload、静态 Runtime、旧动态 Host、资源／正文／本机文件、独立库与便携 Pack、Runtime 隔离及9组异步作业均通过，`inconclusive=0`。
- Zig 格式复查通过，证据 `format-87d6dcce3915.log`；格式化后的 `build test` 也通过，证据 `developer-3985303df4e9/`。最终 `verify-repository` 退出0，证据 `developer-1c29e69f7daf/`：selected=1081、required=1085、Markdown=77、local_links=237，新增 Python 脚本语法检查通过。
- 没有安装、升级、卸载、发布、提交或推送。
