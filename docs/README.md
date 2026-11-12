# 文档导航

先按用途选择入口。现役状态、设计目标、研究建议和历史验收分别维护；旧记录不能替代当前源码或同一产物的验证。

## 使用与开发

| 文档 | 用途 |
| --- | --- |
| [开始使用](guides/getting-started.md) | 便携启动、Host控制、诊断与安装边界 |
| [构建与验证](development/building.md) | 固定依赖、隐藏自动化、目标分组和产物验收 |
| [仓库目录与归属](development/repository-layout.md) | 源码、生成物、运行数据及历史证据的位置 |
| [命令参考](reference/commands.md) | 公开EXE动作、领域命令、VNE及录制回放 |
| [Runtime架构](architecture/runtime.md) | 声明、应用、Host、资源、作业、帧与ABI |
| [环境隔离](environment-isolation.md) | 数据归属、运行context、安装与清理规则 |
| [资源操作](resource-operations.md) | CAS、重新定位／采用、驻留及通用登记 |
| [来源身份](source-identity.md) | Win32真实身份及旧授权的显式确认 |
| [UI规范](ui-style.md) | 共享配色、材质及验收范围 |

## 现役记忆与证据

- [项目记忆](../MEMORY.md)：宪法、主题索引和最新实施记录。
- [现役状态](memory/current.md)：当前实现、原型限额和未完成范围。
- [参照系：FilmCraft／EffectCraft](memory/2026-11-12-artcraft-reference.md)：两者现状、架构要点、与 Cutrans 的对齐和差异以及学习路线（调研，未实施）。
- [容量与回收（窄版）](memory/2026-11-12-capacity-reclaim.md)：`library.remove`、授权自动释放、容量错误显式化；已在本机编译并验证（DLL 命令入口与单元测试），Host/Shell 端到端与 GUI 按钮未覆盖。
- [审计结论与进度检查点](memory/2026-11-12-audit-checkpoint.md)：全仓审计的 P0/P1/P2 清单、已修/未修、复现命令与接续顺序。
- [评审交接与接续顺序](memory/2026-11-12-review-handoff.md)：审计复核修正、威胁模型校正、文档模型与插件两项新发现，以及商定的接续顺序。
- [工作正文发布顺序与草稿基线](memory/2026-11-12-work-publication-order.md)：内容寻址正文、旧名兼容、`base_revision` 判据对齐，以及构建运行器失败的归因修正。
- [保存原子性与 v3 显式输出](memory/2026-11-12-atomic-save-and-v3-output.md)：`.cut` 原子替换、journal 还原保存标志、v3 必须显式 `output=`，以及测试基础设施暴露的三个问题。
- [目录成员显式收纳](memory/2026-11-12-directory-member-collection.md)：本机文件收录到同名逻辑文件夹、成员关系与隐藏 GUI 验证。
- [架构评审与收敛方案（建议，未实施）](memory/2026-11-12-architecture-review.md)：清晰度标准、结构债与分阶段收敛路线。
- [未决请求：停止等待与跨 Shell 标记](memory/2026-11-12-pending-wait-stop.md)：`wrong_epoch` 清空、跨 Shell 提示、不重放和不重复提交。
- [命令清单单一真源](memory/2026-11-12-command-manifest.md)：Shell／Runtime 命令分类集中维护。
- [ABI 接线审计与构建残留清理](memory/2026-11-12-abi-and-staging-audit.md)：编译期强制点、旧 UI 残留清理。
- [统一 NanoUI 前端与旧 UI 清理](memory/2026-11-08-nanoui-unification.md)：主桌面迁移、依赖移除、输入与 Present 回执及实际验证边界。
- [2026-11-08进度与问题清单](memory/2026-11-08-progress.md)：A／B／C阶段定位、遗留问题、下一切片及验收边界。
- [连续创作计划与A／B／C实施](memory/2026-11-07-architecture-plan.md)：用户决定、建议及各片验收。
- [通用登记与App交付](memory/2026-11-07-resource-registration.md)：C2c2实际DLL／Host验证和未覆盖项。
- [工程基线与上游](memory/2026-11-06-foundation.md)、[隔离实施](memory/2026-11-06-isolation.md)、[隐藏自动化](memory/2026-11-07-quiet-automation.md)。
- [历史日志标记](history/verification.md)：旧README输出示例，只供查阅。

实施记录引用的 `scratch/verification/` 是本机认领的证据目录，不要求存在于GitHub或便携包中。没有对应证据时不能声称本地复验通过。

## 研究与旧讨论

[研究文档导航](research/README.md)保留跨项目交接、NanoUI旧版本经验及来源／Station讨论，不作为现役规格。实际依赖以[源码锁](../dependencies.lock.json)及[NanoUI来源记录](../third_party/nanoui/VENDOR.md)为准；其它项目的验收和权限不构成Cutrans事实。

## 旧README内容迁移

| 原内容 | 维护位置 |
| --- | --- |
| 下载、Host与NanoUI启动 | [开始使用](guides/getting-started.md) |
| bootstrap、构建、验证、安装预检 | [构建与验证](development/building.md) |
| 分发／数据／安装规则 | [环境隔离](environment-isolation.md)，指南保留操作入口 |
| VM／Host／Shell／资源／FrameSink／ABI | [Runtime架构](architecture/runtime.md)，细则链接现有专题 |
| 启动参数、命令与录制回放 | [命令参考](reference/commands.md) |
| 旧验收长日志 | [历史日志标记](history/verification.md) |
