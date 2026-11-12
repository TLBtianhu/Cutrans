# 2026-11-09 虚拟环境先验与 EnvironmentSession

## 用户澄清的职责模型

用户指出，单 EXE 不应理解为简单合并文件；更重要的是职责更清晰：**进入内部之后，一切都已经以“虚拟环境已经建立”为先验。**

因此启动期与运行期分开：

```text
环境尚未建立
  Cutrans.exe
    → 校验载荷
    → 选择／启动 Host
    → 建立 VM、Session、权限和服务
    → 确认环境可用
                │
                ▼
环境已经建立
  EnvironmentSession
    ├─ 桌面
    ├─ 本机文件
    ├─ 资源库
    ├─ 编辑器
    ├─ CLI
    └─ 任务与恢复
```

内部 App 不再各自决定 Runtime 在哪里、Host 是否启动或 Pack 如何寻找。环境失效仍由现有版本／epoch 和协议错误明确处理，不退回另一条物理路径偷偷启动新实例。

## 本轮实现

新增 `vne/environment_session.zig`，其中 `Session` 只有：

- 结构与版本；
- 当前 Runtime 的随机 epoch 身份。

没有资源目录、数据目录、Host 路径、可执行路径或用户敏感信息。Runtime epoch 标识当前运行代际，不是内容版本，也不是授权凭证。

`establish()` 使用已有能力建立启动屏障：

1. 公开 Shell API 必须仍为当前 ABI；
2. Host 附着和 Shell 身份校验已在调用前完成；
3. Workspace API 必须匹配；
4. 读取一致 Runtime 快照；
5. epoch 非零、revision 有效，才返回 Session。

没有增加 RPC、没有抬主 Shell ABI，也没有改变 Pack 或 Runtime DLL 布局。复用现有协议避免了为同一身份再造一套握手。

## App 接入

- 主桌面初始化时建立 Session，并在首页显示“环境已建立”及 epoch。
- 独立资源库诊断 Shell 也建立同一类型的 Session。
- 本机文件 App 初始化必须收到有效 Session；浏览与显式登记语义不变。
- 既有 Host／Shell、Resource API v4、正文草稿、任务和恢复行为不变。
- `ShellConfig` 当前仍携带物理资源／数据目录，属于尚未收口的过渡输入；本类型没有把旧输入一次性隐藏成另一套隐式环境。

## 实际验证

所有命令经项目隐藏自动化入口执行并保留日志和退出码，以下均退出 0：

| 验证 | 结果与日志 |
| --- | --- |
| `build test` | 类型、无效会话拒绝、现有 Runtime 与模型测试通过；`developer-00658bcc5132/` |
| `build test-core test install portable` | 完整构建、核心测试和分发组装通过；`developer-1a2bef96c737/` |
| `build test-nanoui-desktop` | 统一桌面测试通过；`developer-08299034b364/` |
| `build verify-shell` | 主桌面真实 Host 场景必须出现 `CUTRANS_ENVIRONMENT_SESSION_OK`，通过；`developer-fa484213d5bb/` |
| `build verify-nanoui-library` | 独立资源库建立 Session，并保留既有正文／图片验收；`developer-b1585f6ed049/` |
| `build verify-local-sources` | 本机文件 App 验证 Session，并完成浏览、登记、插入文档；`developer-bea80a432330/` |
| `build verify-work-documents verify-resource-registration` | 正文、固定版本、持久回执和通用登记回归通过；`developer-b68f1bb8854d/` |
| `build verify-attach` | 多次附着和 Host 恢复通过；`developer-92417786a450/` |
| `build verify-nanoui-portable` | 便携环境及 Pack 纯净通过；`developer-c189e4209382/` |
| `build verify-runtime verify-isolation` | Runtime 恢复和隔离负例通过；`developer-b3037f064f10/` |
| `build verify-jobs-async` | 异步作业 9 组通过，inconclusive=0；`developer-43b63ef5c2d2/` |
| `verify-repository` | 最终源码与文档链接审计通过；`developer-ec03c59ef2ac/`，selected=1067、required=1071、Markdown=74、local_links=224 |
| 格式与语法 | 新增 Zig 文件及修改文件通过 `zig fmt --check`；相关 Python 验收脚本通过 AST 解析 |

没有真实窗口视觉、IME、系统剪贴板、完整安装升级卸载或发布验收。现有诊断与测试入口仍不被当作正式发行入口。

## 未完成与下一步

本轮只建立环境身份和启动屏障，没有完成：

- 同一 EXE 的 Host／Shell 多角色启动；
- Runtime 静态链接与 DLL 退出正式发行；
- 内嵌 Pack、资产和签名校验；
- 环境内部完整安全退出状态机；
- 物理 `ShellConfig` 路径的最终收口；
- 不可信插件 OS 沙箱。

下一步应做同 EXE 多角色与 RuntimeProvider／PayloadSource 抽象，再完成环境内安全退出。保留现有 DLL／Pack 作为开发和回退路径，不把过渡路径误写成最终发行已经完成。

相关目标见[单一发行入口与安全退出](2026-11-08-single-exe-safe-exit.md)，当前业务入口见[本机文件切片](2026-11-08-local-file-sources.md)。
