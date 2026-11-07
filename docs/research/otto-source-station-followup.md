> 历史研究材料：保留当时的讨论与版本背景。当前实现见[现役状态](../memory/current.md)，本机路径只是历史引用。

# 对《OTTO × Cutrans》回复的复核与后续约定

> 本文是对 `docs/research/otto-source-station-reply.md` 的复核，接续 `docs/research/otto-source-station.md`。
>
> 目的：确认双方已收敛的模型，并补上“快照到底能恢复什么”这一关键语义，避免后续把目录恢复、内容恢复和实时 Source 混为一谈。
>
> 边界：本文只做架构与验收语义评审，没有重新运行 OTTO 测试。回复中提到的文档修正、分支进度和后续代码改动，以 OTTO 实际仓库为准。

## 一、共识已经成立，不再改主模型

双方同意：

- **Source 在硬盘，Station 只在内存，Projection 是只读派生物，Snapshot 是显式导出的新 Source。**
- OTTO 落盘的是 **Source 快照**，不是内存 Station 的持久化。
- Browse 的目录监听更新的是**只读投影**，不是在后台替换可编辑对象。
- OTTO 继续负责 Source 索引、快速预览与宿主移交；Cutrans 的内存 Station 独立存在，通过显式 `load/export` 协作。
- 不把 OTTO 改成通用编辑器或另一套 VM，不为 Station 另建持久层，不共享活动对象。
- 预览、宿主启动、拖出移交不共用动词或返回类型。

因此，下一步不再是扩展抽象概念，而是落实验收：**读取一致性、身份重连、恢复保证、峰值内存与基线 CPU。**

## 二、必须再区分两种 Snapshot

“Source 快照”并不自动等于“内容可以独立恢复”。

| 类型 | 典型内容 | 能恢复什么 | 不能承诺什么 |
| --- | --- | --- | --- |
| **Catalog Snapshot**（目录/元数据快照） | 样本索引、来源、注释、分组、目录关系、格式版本 | 目录视图、来源记录与用户元数据 | 原媒体丢失时，不保证还能恢复媒体内容 |
| **Content Snapshot**（内容快照） | 完整素材字节，或可以完整再生的声明与依赖 | 独立的内容对象，可作为新的 Source | 不能省略完整性、依赖与格式版本校验 |

OTTO 的 `library.otto` 属于 **Catalog Snapshot**：它能恢复目录与元数据，但不应被当成原媒体的完整备份。

Cutrans 讨论的整体导出文件夹属于 **Content Snapshot**：它保存完整素材，或保存足以完整再生的声明与依赖，目标是成为独立的新 Source。

`Library` 作为“只读真源”，准确含义应是**这份快照自己的真源**，不是实时 Source 的真源。滚动 `Index` 是观察视图，不应被当成跨应用共享的可编辑真源。

## 三、OTTO 的优先验收顺序

### P0：快照与读取一致性

1. `mtime` 随快照保存并在 load 恢复；无身份卷无法取得 mtime 时，不得把未知值当成新的可信身份。
2. 实时查询必须与 `Index` 的当前视图一致，不能出现“写入已更新，查询仍读旧快照”。
3. created 样本的目录与分组关系必须有明确的增量维护或重建策略。

这些项目应与 `feat/library-folders` 一起验收，不另开一套平行架构。

### P0：身份与关系重连

补一组针对性测试：

```text
rename → 重扫 → 重启 → 跨库导入
```

除了注释命中，还必须检查：

- `group_ids` 与 `group.sample_ids`；
- `folder_id` 与目录成员；
- `original_id` 的血缘关系；
- 无身份卷的 fallback 迁移与歧义处理。

目标是防止“注释保住了，分组或目录关系却丢了”。

### P1：峰值驻留与覆盖范围

- 长音频 PCM 与解码缓冲纳入预算，按**峰值**而非回落后的当前值判断。
- 评估 `waveform-only / bounded-playback / full-decode` 三档驻留策略。
- 保留 `truncated/has_more/pending_metadata/waveform_version` 的诚实表达，逐步统一为 `Coverage`，不把部分内容冒充完整对象。
- 渐进波形在声明帧数与实际帧数不符时必须重算，不能把错误总长下的前缀当成最终波形。

### P1：保持现有边界

- `unsupported/no_handler` 可以继续询问下一个 Provider；`failed/file_missing` 保留最具体的终止失败。
- `otto-thumb-host` 只承担预览故障隔离，不是宿主启动。
- 拖出到 FL Studio / Melodyne 是宿主移交，不是预览。
- `zig-audio` 是解码 Provider，不是素材真源；nanoui 是可选 UI 投影。
- 外部文件进入 Cutrans 必须经过 VNE 授权，不提供绕过授权的旁路。

## 四、Cutrans 的基线 CPU 建议

OTTO 提出的基线 CPU 风险同样适用于 Cutrans：当前 `build.zig` 使用 `standardTargetOptions(.{})`，默认可能继承构建机特性，不能把本机可运行误当作用户机器可运行。

建议后续分发修改：

- 默认 Windows x64 分发目标钉在 **`x86_64_v2`**；
- 开发机需要更高优化时，通过显式 `-Dcpu=native` 或明确目标特性选择，不污染默认分发基线；
- 在不支持 AVX512 的机器或等价 CPU 目标环境上做实际启动验证；
- 将“分发目标基线”与“本机开发优化”写成两个不同选项。

**目前这只是建议，尚未在 Cutrans 中实现或验证，不能宣称已经解决。**

## 五、可直接转交给 OTTO 开发智能体的话

> 同意，主模型到这里不再调整。Source / Station / Projection / Snapshot 分层保留，Browse 的监听只更新 Projection，不涉及 Station 真源替换。
>
> 请再明确两种快照：`library.otto` 是 **Catalog Snapshot**，恢复目录、来源与注释，不保证原媒体内容可独立恢复；Cutrans 的整体导出文件夹是 **Content Snapshot**，保存完整内容或完备的可再生声明。两种快照的恢复保证不要混用。
>
> `Library` 的只读真源应理解为“这份快照的真源”，不是实时 Source 的真源；`Index` 仍是观察视图。实时查询必须明确读取哪个版本。
>
> `feat/library-folders` 交付时优先验收：
>
> 1. `mtime` 随快照保存并在 load 恢复；未知值不能被提升为新的可信身份。
> 2. 实时查询与 `Index` 当前视图一致，不再出现写入已更新、查询仍读旧快照。
> 3. created 样本的目录与分组关系有明确增量维护或重建策略。
>
> 随后补 rename → 重扫 → 重启 → 跨库导入的关系重连测试，以及长音频 PCM 的峰值驻留预算。覆盖范围继续保留，不把部分内容冒充完整素材。
>
> Cutrans 会吸收 `x86_64_v2` 作为分发基线，并保留开发时显式 native 优化选择；实际修改和验证完成前不宣称已经解决。

## 六、最终判断

这次回复没有实质架构分歧。OTTO 不需要改造成 Cutrans 的内存 Station，Cutrans 也不需要把 OTTO 的目录快照当成共享内存真源。

下一阶段只需把四件事做实：

1. **Source 与快照的版本、身份和恢复保证可验证；**
2. **实时视图与查询读取一致；**
3. **部分投影有明确覆盖范围，不冒充完整内容；**
4. **分发物在基线 CPU 与真实用户环境中都能启动。**
