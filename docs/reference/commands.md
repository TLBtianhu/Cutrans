# 启动与命令参考

公开EXE的启动动作、VM领域命令和版本化API是三种不同入口。以下参数以当前源码为准，旧Release不保证一致；不要把领域命令名直接追加到公开EXE当成已实现的子命令。

## 公开入口

| 动作／参数 | 语义 |
| --- | --- |
| 无动作／`desktop` | 启动或复用Host，再附着desktop |
| `context` | 只读输出解析后的运行context |
| `start`／`status`／`stop`／`restart` | Host生命周期；stop先保存，失败保留实例 |
| `jobs` | 从Host读取作业页 |
| `attach` | 低级Shell附着 |
| `library` | 开发诊断NanoUI候选Shell |
| `activate-runtime --runtime=<绝对目录>` | Host停止后验证候选并提交Runtime选择 |
| `--runtime=<绝对目录>／builtin` | 显式选择动态Runtime Pack，或在统一入口中选择内置静态Runtime并允许身份迁移 |
| `--mode=development\|portable\|installed` | 必须与context声明形态一致 |
| `--purpose=verification\|diagnostic\|replay` | 非normal用途必须显式独立data |
| `--data=<绝对路径>` | 显式实例数据，仍受产品／形态／用途及路径边界检查 |
| `--open <绝对路径>` | 由Host授权打开，不让路径穿过文档命令 |
| `--shell-dir=<绝对目录>` | 显式候选Shell，成功后才提交选择 |
| `--diag`／`--headless` | 独立诊断Runtime，不能成为现有Host第二写者 |
| `--replay=<VNE URI>` | 在全新Session区分命令／语义输入日志回放 |
| `--record-input=<可写VNE URI>` | 显式语义录制 |
| `--playback=N` | 桌面／GPU就绪后播放有限静态序列，1～600帧 |
| `--assets-demo` | 合成素材验证路径，不是普通用户打开动作 |

统一 `cutrans.exe` 默认使用内置静态 Runtime。显式绝对目录仍选择经过完整校验的动态 Runtime Pack；已有不同 Runtime 身份必须显式迁移，`--runtime=builtin` 只由统一入口接受。

`cutrans_diag.exe --inspect`只读；写入诊断使用`--verify-data-dir=<独立绝对路径>`。正常便携启动见[使用指南](../guides/getting-started.md)。模式、用途、频道及默认路径由[环境隔离](../environment-isolation.md)统一定义。

## 环境退出

NanoUI 首页的“退出虚拟环境…”与窗口关闭不同：窗口关闭只离开 Shell，显式退出先停止新业务，再选择等待已有任务或协作取消，最后保存并停止 Host。退出中可以返回环境；保存失败会保留原因，修复后重试，不能显示已安全退出。草稿会持久保护，但不会替用户提交工作 revision。

内部 `prepare_stop`、`cancel_jobs`、`resume_work` 是 Host 控制协议动作，不是追加到公开 EXE 的同名子命令。`--exit-demo` 仅用于隔离的隐藏 NanoUI 验证，不是普通启动方式。

## VM领域命令

这些名称由Runtime中央注册表消费，Shell／CLI应用和API客户端按对应契约调用。GUI帧内accepted可以只表示入队；导出accepted＋task_id表示声明已受理，仍须查询最终结果。

| 范围 | 命令 |
| --- | --- |
| 文档 | `doc.open`、`doc.read`、`doc.write`、`doc.save` |
| 编辑 | `editor.gain.set`、`editor.invert.add`、`editor.over.add`、`editor.over.opacity.set`、`editor.image.open`、`editor.resize.add`、`editor.asset.insert` |
| History | `history.undo`、`history.redo` |
| 导出与作业 | `editor.export.png`、`task.cancel`、`task.retry`、`task.list` |
| 播放 | `playback.start`、`playback.status`、`playback.stop` |
| 严格素材 | `asset.open`、`asset.preview`、`asset.export`、`asset.release`、`asset.list` |
| 当前已登记资源 | `asset.ensure <id> <sha256>`、`resource.acquire <id> <sha256>` |
| 上次来源观察 | `asset.check <handle>` |
| 旧授权确认 | `source.list`、`source.reauthorize`，详见[身份规则](../source-identity.md) |
| 资源目录 | `library.refresh`、`library.detach`、`library.create`、`library.folder.create`、`library.rename`、`library.move`、`library.list` |

资源登记不是一个假设中的`register_file <path>`文本命令：Resource API v2使用snapshot → probe(register_file) → submit，并以连续请求身份及回执处理未知结果。旧relocate／adopt继续校验PNG。真实接口与容量、权限、重试、失败规则见[资源契约](../resource-operations.md)。

文档编辑及导出受理有独立版本化请求；不要把普通command入口等同为所有操作都有CAS／回执。重试必须保留原ID、proof、path和expected，不能刷新后偷偷重放新意图。

## .cut与VNE

最小声明示意：

```text
version=3
resolution=1920x1080
fps=30
nodes:
c0=testsrc{}
c1=gain{ in:c0,value:0.8 }
output=c1
```

实际图像节点同时记录来源与采用的SHA；v1／v2输入仍可迁移。规范格式、身份与内容指纹由Runtime解析器定义，不由UI另写一套。

`vne/uri.zig` 与 `vne/mounts.zig` 提供虚拟根和授权表：`pack` 只读，`session/cache/temp` 可写，`external` 需要实例内授权。`doc.open`/`doc.save` 只接受 VNE URI；绝对路径先经 Native 授权换成 `external://id`，不能直接穿过文档命令。`.cut` 使用 `version=3`，图片可引用 Pack、带 SHA-256 的 Session 快照、持久 external 授权或 `library://` 资源，v1/v2 可读并迁移，所有 Pack 的 `document_schema` 同步为 3。`library://` 必须经过资源目录，不是普通挂载路径；持久授权的真实路径只保存在 Session 授权目录，临时句柄不能作为文档 Source。授权句柄是实例内能力，不是跨系统路径或完整安全沙箱。

## 录制、回放与验证范围

`--replay=<VNE URI>` 在全新 Session 中自动区分版本化命令日志与语义输入日志。命令回放逐步校验结果并推进任务，对账文档指纹、History、Task 状态哈希、逻辑时间和导出 PNG；语义输入回放消费指针、按键、文本和焦点事件，不注入 OS 输入。`verify-replay` 在两个隔离数据根验证命令回放的一致结果，并拒绝结果不符、命令/输入时间倒退。

Shell 已将指针移动/按钮、语义按键、UTF-8 文本和焦点事件接入 VM，NanoUI 输入经 `consoles/gui/nanoui_input.zig` 桥接，不再依赖旧 GLFW→ImGui 栈。`runtime/input_actions.zig` 将 `Ctrl+I`、`Ctrl+Z`、`Ctrl+Y` 映射到共享的添加 invert、撤销与重做命令，文本输入状态下抑制全局动作；不支持的修饰组合不产生命令。

`--record-input=<可写 VNE URI>` 可显式开启实时录制，例如 `--record-input=session://input/live.cvr`。独立桌面 Shell 通过 `input_begin/input_end` RPC 在 Host 持有的同一 Runtime 中开始和结束录制，不依赖旧的进程内 GUI。`cutrans_input_replay=3` 保存事件上下文、逐动作结果、基线文档指纹以及最终文档指纹和 History 游标；v1/v2 保持纯设备回放。当前可判定录制要求默认文档、空 History/Task 和未消费输入，尚未序列化任意会话基线，也不支持指针控件命中回放。录制包含文本，不应用于密码等敏感输入；当前不覆盖滚轮与 IME 组合状态，不注入 OS 输入，跨 OS 实机回放仍未实现。

上述验证不注入真实OS输入。录制可能含文本，不用于密码或敏感输入；它不覆盖滚轮／IME组合、任意会话基线或指针控件完整命中回放。FrameSink的GPU submitted与实际屏幕呈现分账，详见[Runtime架构](../architecture/runtime.md)。
