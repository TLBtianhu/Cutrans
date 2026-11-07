> 历史研究材料：保留当时的讨论与版本背景。当前实现见[现役状态](../memory/current.md)，本机路径只是历史引用。

# OTTO × Cutrans：Source、内存 Station 与 Snapshot 的纯粹边界

> 接收方：OTTO 项目开发智能体。
>
> 目的：在不把 OTTO 改写成另一套 VM、不把 Cutrans 暂存站做成第二个文件系统的前提下，澄清素材、内存工作区、预览和保存的职责。
>
> 依据：2026-11-02 对 `C:\src\otto-zig-lite` 当前主线的静态阅读，以及 Cutrans 的素材/源/投影/缓存记忆。本文没有运行外部项目，也没有把文档中的测试数字当成本次实测。建议落地前，先读取 OTTO 的 `AGENTS.md`、项目记忆和当前工作区状态；已经完成的事项不要重复建设。

## 一、最纯粹的模型

**Station 只存在于内存，不为 Station 设计持久层。**

```text
硬盘 Source
   │  显式 load
   ▼
内存 Station ── preview──▶ 只读 Projection
   │
   │  显式 export
   ▼
新的 Snapshot 文件夹（也是 Source）
```

只有四种东西：

- **Source**：硬盘上的文件、目录或快照，拥有自己的真源。
- **Station**：本次运行中的活动对象、引用和编辑状态，默认可丢弃。
- **Projection**：预览、波形、缩略图等只读派生物，有明确覆盖范围。
- **Snapshot**：用户显式导出的新 Source，不是 Station 的持久化形态。

这不是“硬盘与内存互相投影”，而是**两套对象各自拥有真源，通过显式动作交换内容**。硬盘引用和内存快照可以相关，但不应默认互为镜像。

## 二、不可混淆的规则

### 1. Station 可以没有持久化

传统软件中的中间帧、预览、临时合成、未命名草稿、解码缓冲和会话状态，都可以只活到本次运行结束。

因此：

- 加载意图只是下一次加载的入口，不是恢复承诺。
- 内存新创对象默认可丢弃，不自动产生快照。
- 需要长期保留的对象必须显式导出、保存或登记到另一个真源。
- 如果产品承诺“草稿可恢复”，才需要为那部分对象增加真实的快照与恢复语义，不能把加载引用当成恢复内容。

**纯引用模式只保存加载意图；独立快照和内生对象才有属于自己的持久内容。**

### 2. 整体导出文件夹就是新的 Source

可以把 Station 当前选定的对象、内容和关系整体导出为一个文件夹。它随后可以再次作为 Source 被显式加载。

文件夹快照应包含：

- 对象清单、素材 ID、类型、来源与格式版本；
- 实际内容，或能够完整再生的声明；
- 对象之间的引用、分组、注释与必要生成参数；
- 内容指纹和完整性校验。

“保存到可信的新文件夹”不等于“暂存站被持久化”。它意味着**生成了一个独立的新 Source**。

应区分：

- 整体导出 Station：生成自包含快照；
- 引用已有文件夹：只记录来源，没有保存 Station 的新内容；
- 直接复制文件夹：只是文件系统操作，未必包含内存中的新对象、修改与关系。

快照最好经临时目录生成、校验清单，再原子转正，避免留下半份“完整快照”。

### 3. 打开、预览、启动宿主不是一回事

- `open`：把对象纳入内存工作区，取得身份、句柄、权限与生命周期，不强制完整解码。
- `preview`：取得只读、有限用途的观察投影，例如首帧、缩略图、部分波形或时间窗。可以在管理器内或独立进程中执行，进程数不是本质。
- `open-with / launch-host`：把对象或授权交给外部宿主应用，不是 preview。

OTTO 的 `otto-thumb-host.exe` 是预览的故障隔离进程，不是启动编辑器；拖入 FL Studio / Melodyne 是宿主移交，也不是预览。

### 4. 身份、内容版本与投影代际分开

至少需要四种标识：

- **来源身份**：例如 NTFS 卷序列号与 File ID；
- **运行时素材句柄**：本次工作区内的对象引用，不天然需要持久化；
- **内容指纹**：某一代内容的哈希，用于版本对账和缓存；
- **投影代际与覆盖范围**：预览的版本、参数、已完成区间和是否完整。

复制、引用、改名、移动、换路径、改内容不是同一种事件。文件身份稳定不代表所有业务关系都能只靠它维持。

### 5. 哈希是版本证据，不是覆盖许可

设 `B` 为共同基线，`S` 为 Source 当前哈希，`M` 为 Station 当前哈希：

| 情况 | 建议语义 |
| --- | --- |
| `S == M` | 内容相同，无需同步，可复用字节缓存。 |
| `S == B && M != B` | 只有 Station 改了，不用 Source 覆盖 Station；可导出或另存。 |
| `M == B && S != B` | 只有 Source 改了，可显式接受新版本或创建新代际。 |
| `M != B && S != B` | 两边都改了，进入冲突、分叉或人工合并，不自动覆盖。 |

同一个来源、同一个哈希可以复用引用；哈希变化默认产生新代际或新实例，不覆盖正在使用的对象。内容相同的不同对象可以共享字节缓存，但不能合并素材 ID、来源、注释和生命周期。

### 6. 缓存与同步共用指纹，不共用真源

缓存键至少包含：

```text
content_fingerprint
+ projection_kind
+ format/schema
+ projection_parameters
+ codec/provider_version
+ coverage
```

同步决定哪个版本成为真源；缓存只保存该版本的派生物。新内容使旧派生缓存失效，但不应连带删除素材 ID、注释、分组、引用和未提交的编辑声明。

### 7. 不需要通用的 `save`、`refresh` 或实时同步

建议保留这些有明确主语和方向的动作：

- `scan`：重新读取 Source 的目录或文件状态；
- `check`：比较版本，不修改内容；
- `load`：显式从 Source 加载到 Station；
- `export`：显式把 Station 内容导出为新 Snapshot；
- `sync`：一次有方向、有基线、有冲突策略的显式同步；
- `invalidate`：作废派生缓存，不改变真源；
- `release`：释放本次运行中的引用。

完整导出是默认形式。增量导出是后续可选扩展，需要共同基线、稳定 ID、幂等和断点恢复，不能成为默认前提。

严格解耦不代表假装 Source 永远不变，而是**只在打开、加载、导出和显式同步这些事务边界检查变化，不在后台替换活动对象**。

## 三、OTTO 当前实现应如何理解

### `Library` 与 `Index`

`C:\src\otto-zig-lite\zig\core\src\index.zig:3` 已明确：`Library` 是加载一次的不可变快照，`Index` 是在其上滚动的工作视图。

这证明 OTTO 不是简单的文件树复制，但也说明：`Library` 是目录快照，不是跨应用共享的活动内存真源；`Index` 是视图，不应被当成可编辑的共享对象表。

### 只读 Browse

`C:\src\otto-zig-lite\zig\app\src\browse.zig:1` 的目录浏览具有懒枚举、分页、内存预算、事件重扫、墓碑与身份跟踪。

它是**真实目录的只读、分页投影**，不是 Station，也不是第二个文件系统。只读、截断可见、内存不足明确拒绝，都是应保留的好边界。

### 渐进音频预览

`C:\src\otto-zig-lite\zig\app\src\audio\progressive.zig:9` 先交付已定稿的波形前缀，后台补齐，最终移交完整 PCM。

这是**部分覆盖的预览**，不是把部分内容冒充完整素材。总长未知时走完整解码、按真实帧数重算错误基线，正是“部分投影不能污染真源”的正面例子。

## 四、给 OTTO 的优先建议

### P0：厘清 `Sample.id` 与 `StableKey` 的关系

`Sample.id` 是业务对象 ID（`C:\src\otto-zig-lite\zig\core\src\model.zig:133`），扫描导入还存在路径派生 ID（`C:\src\otto-zig-lite\zig\app\README.md:108`）；注释则使用 `StableKey`（`C:\src\otto-zig-lite\zig\core\src\model.zig:75`）。

运行时 `renamed` 已保留 ID，但还应验证：

- 改名后重新扫描并重启；
- 跨库导入同一个文件；
- 新建库后重新关联旧分组；
- `original_id`、目录成员和 `group.sample_ids` 是否能正确重连。

重点不是断言已有 bug，而是防止“注释保住了，分组关系却丢了”。`original_id` 是血缘，不应默认成为共享身份。

### P0：优先处理无身份卷的 `mtime` 恢复风险

`FallbackKey` 使用 `path + size + mtime`，但 `C:\src\otto-zig-lite\zig\core\README.md:400` 明确说 `store.load` 尚未恢复 `mtime`。

应补充：

- 已知 L0 `mtime` 必须进入快照；
- FAT32、exFAT、网络盘上的重启、改名、修改内容后的注释重连测试；
- 无身份卷上的最近可信身份与迁移策略，不能默默丢弃注释。

### P0：统一 `Library` 与 `Index` 的读取语义

`Index` 会更新，而 `query.*` 仍有读取 `Library` 快照的路径；created 样本的目录与分组关系也不会自动完整维护，见 `C:\src\otto-zig-lite\zig\core\README.md:392`。

请明确二选一：

- 实时查询都走 `Index` 及其派生关系；
- 或明确声明 `Index` 只是临时收集器，重建前不承诺完整业务视图。

不要让写入更新一个视图、查询却读另一个年代的快照，却被外部理解为同一份当前真源。

### P1：把覆盖范围提炼成统一 `Coverage`

可以逐步统一：

```text
source identity
+ projection generation
+ covered ranges
+ complete / truncated
+ dirty / pending
```

保留 `truncated`、`has_more`、`pending_metadata`、`waveform_version` 等已有好机制，使目录分页、波形前缀、首帧、元数据待补都不会被误认为完整对象。

### P1：把 PCM 与解码缓冲纳入驻留预算

渐进预览最终会持有完整 PCM 并移交所有权，见 `C:\src\otto-zig-lite\zig\app\src\audio\progressive.zig:31`。

建议评估三档：

- `waveform-only`：只保留波形，播放时重新打开解码；
- `bounded-playback`：保留有界播放窗与 seek 能力；
- `full-decode`：为高频素材保留完整 PCM。

预算应把 PCM、解码缓冲和播放会话计入，而不只计算图片缓存。此项是规模化风险评估，不是断言当前小样本已有故障。

### P1：保持 Provider 与进程边界

保留以下成熟决策：

- `unsupported/no_handler` 继续询问下一个 Provider；
- `failed/file_missing` 保留最具体的终止失败；
- 常用格式自解码，专业格式由 Shell handler 补充；
- 第三方 handler 在独立 helper 中隔离；
- 预览、宿主启动、拖出移交不共用一个动词或返回类型。

## 五、Cutrans 应如何接入

不要直接移植 OTTO 的外壳，也不要让 OTTO 的对象直接成为 VM 的素材真源。Cutrans 可以先做一个最小的 **Asset Workspace**：

- `asset.open`：取得素材句柄与来源，不强制完整解码；
- `asset.preview`：取得带覆盖范围的只读投影；
- `asset.load`：显式从 Source 加载对象；
- `asset.export`：显式导出独立快照；
- `asset.release`：释放引用，区分缓存、活动对象和用户注释；
- `host.launch`：将来单独启动宿主，绝不复用 preview 命令。

`zig/core` 的身份模型、查询与缓存思路，`zig/ports` 的浏览、监听与预览 Provider，可以经适配复用。`zig-audio` 是解码 Provider，不是素材真源；nanoui 是可选 UI 投影，不是 VM 核心。

外部文件仍须经过 VNE 授权进入，不让宿主路径绕过 VM 的语义边界。

## 六、建议的验收矩阵

优先使用合成素材与隔离目录，不碰真实用户素材库：

- 改名 → 重扫 → 重启 → 分组与注释是否都在；
- 同 File ID 不同路径 → 是否正确识别同一来源；
- 跨卷复制 → 是否明确进入退化身份与迁移策略；
- 无身份卷修改 mtime 后重启 → 注释是否仍可恢复；
- 同来源同哈希再次加载 → 是否复用引用而非重复创建；
- 同来源不同哈希且本地已编辑 → 是否新代际/冲突，而不是静默覆盖；
- 导出目标已存在 → 是否默认新建或明确拒绝，不静默覆盖；
- 部分目录/部分波形 → 是否展示覆盖范围，不冒充完整对象；
- 内容换代 → 派生缓存失效，注释与引用仍保留；
- 长音频 → PCM 与解码缓冲是否纳入预算；
- Source 与 Station 未发生显式导出时 → 是否没有写入和隐式同步。

## 七、可直接交给 OTTO 开发智能体的话

> 先不要改代码。请结合 Cutrans 记忆，重新评估 OTTO 的边界，但注意这是新的认知校准，不要机械执行旧结论。
>
> 我们现在把模型收敛为：Source 在硬盘，Station 只在内存，Projection 是只读派生物，Snapshot 是显式导出的新 Source。Station 不设计持久层，加载与导出都是显式动作，不做实时镜像或隐式刷新。
>
> 请阅读 `zig/CHARTER.md`、`zig/core/src/index.zig`、`model.zig`、`zig/app/src/browse.zig` 和 `audio/progressive.zig`，然后：
>
> 1. 分别说明 `Library`、滚动 `Index`、只读 Browse、预览 Provider 属于哪一层，哪些只是 Source 的观察视图。
> 2. 验证 `Sample.id` 与 `StableKey` 在 rename、重扫、重启、跨库导入中的关系，尤其检查分组和目录关系是否完整。
> 3. 评估无身份卷的 `mtime` 未恢复所造成的注释失联风险，给出最小复现和迁移策略。
> 4. 明确 `Library` 与 `Index` 的实时读取语义，避免写入和查询读取不同年代的数据。
> 5. 保留只读 Browse、分页、截断可见与渐进波形，评估统一 `Coverage` 的最小表达。
> 6. 评估长音频 PCM 驻留成本，把 PCM 与解码缓冲纳入预算。
> 7. 保持 Provider 注册表、失败语义和 helper 隔离；不要让预览、宿主启动、拖出重新混为一谈。
>
> 请先给出**分层判断、风险排序和最小修改建议**，不要直接大重构，也不要把 OTTO 改成通用编辑器或另一套 VM。OTTO 继续负责 Source 索引、快速预览与宿主移交；Cutrans 的内存 Station 是独立的小工作区，通过显式 load/export 与 OTTO 协作。

## 八、文档一致性的小修正

根 `README.md` 的更新检查描述与 `zig/app/README.md` 当前实现说明存在口径差异：前者提到启动时自动检查，后者明确“只有用户点击才获取”。接收方应以当前代码为准，统一文档，避免把启动联网行为描述错。

另请同步清理根 `README.md` 更新段落末尾残留的重复/不完整句子，保持 Release 描述、代码行为与测试口径一致。
