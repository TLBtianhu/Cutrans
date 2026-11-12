# 2026-11-12 参照系：FilmCraft／EffectCraft 现状与对齐方案

## 状态

- 只做了调研与讨论，没有改代码、没有构建。依据是 2026-11-12 当天读取的 FilmCraft 与 EffectCraft 官方 README、`docs/architecture.md`，以及 GitHub API 返回的仓库元数据。**没有读两者的源码**，下文的类型名和函数名都来自它们的文档，未经源码核对。
- 本页更新 [17-discussion-history-01.md](17-discussion-history-01.md) 第 15 行 2026-10-09 的旧调研条目（该条已追加勘误指向本页，原文保留）。
- 下文“用户决定”与“Claude 建议”分开标注；未经用户确认的不算定案。

## 用户决定（2026-11-12）

- 以 FilmCraft／EffectCraft 的最新版本为**参照系**进行学习，在其基础上做 Cutrans 理念的解耦与对齐，“像 Linux 对照 Unix 一样”，不再是没有参考。
- 用户认为它们用 Rust，用 Zig 重写难度不大。Claude 对此有保留，见下文第三节。具体采用哪条路线**尚未定案**。

## 一、现状（2026-11-12）

| | FilmCraft（Premiere 克隆） | EffectCraft（AE 克隆） |
|---|---|---|
| 仓库 | `storytold/filmcraft` | `storytold/effectcraft` |
| 星／fork | 18,118／7,384 | 8,677／4,575 |
| 创建／最近推送 | 2026-09-30／2026-11-12 | 2026-10-01／2026-11-12 |
| 开放 issue | 2,149 | 1,136 |
| 自评 | 功能覆盖约 86%（2026-10-10 测），真实生产就绪约 56% | 功能约 91%，真实生产就绪约 45% |
| 许可 | README 写 MIT OR Apache-2.0；GitHub API 识别为 Apache-2.0。ArtCraft 名称和标志是商标，fork 须去除 | 同左 |

两者的共同结构：

- **分层**：Cargo workspace 分 L0–L6 层。`cargo xtask layers` 读取 `cargo metadata`，检查完整依赖图：只允许向下依赖，同层边要进白名单，egui／winit 等 UI 与 OS 库只允许在 L5–L6。另有 `cargo xtask wasm` 对下层做类型检查；全工作区 `unsafe_code = "forbid"`，platform 层的 FFI 例外。
- **无头引擎**：egui UI、CLI、JSON-lines 控制通道（TCP）、MCP server（stdio，可无头或桥接到运行中的 App）**按同一命令 id 分派**。FilmCraft 有 650 多条引擎命令。`CommandSpec{ id, label, menu, shortcut, params(给 agent 的文本说明), enabled(&Session)->Result<(),String>, run, journal }`。agent 还能按自动化 id 点击 UI、截图。
- **时间**：整数 `Tick(i64)`，`TICKS_PER_SECOND = 254_016_000_000`，是广播帧率（含 ×1001 NTSC）与常用采样率的公倍数。时间码只用于显示；参数在命令边界统一换算成 tick。
- **撤销**：快照式。编辑时 clone 一份 `Arc<Project>` 再修改，失败则不变。靠结构共享让快照便宜：EffectCraft 中 comp 本身也是 `Arc`，只复制被改的 comp，撤销／重做等于指针交换，支持分支历史；`Project::same_content` 判空编辑，不记步。
- **效果定义是数据**：FilmCraft 的 `project::effect::effect_defs()` 给出参数 schema，面板和 agent 文档由它生成。EffectCraft 有 306–308 个效果的注册表，参数存在属性树里，用路径寻址（如 `effects/#1/blurriness` 或 `@uid`）。
- **渲染**：CPU 实现作为参照答案，wgpu GPU 路径与之对比测试。FilmCraft 是 `render::render_sequence` 加 `render::plan::plan_frame` 加 `gpu::GpuCompositor`；EffectCraft 是 `Renderer::comp_frame(comp, t)`，每帧从下往上遍历图层的拉取模型，文档里**没有显式依赖图**。缓存方面：FilmCraft 有按字节预算的 LRU 帧缓存和 GOP 缓存；EffectCraft 的图层缓存以“求值后输入的哈希”为键，另有 LZ4 磁盘缓存。
- **编解码**：H.264／HEVC／ProRes／VP9／AAC／Opus 及 MP4／MKV 容器为自研纯 Rust；FFmpeg 只作为测试参照答案（oracle）。
- **工程文件**：`.fcproj`／`.ecproj` 是结构体序列化成的版本化 JSON，原子保存，有 schema 迁移，并约每秒写一次崩溃恢复 journal。
- **插件**：FilmCraft 不托管第三方插件。EffectCraft 已有 WASM 插件 ABI v1／v2 和外部 helper 进程——旧条目“无插件”已过时。

## 二、与 Cutrans 的对照（Claude 分析，待用户裁定）

可以对齐的地方——它们已替 Cutrans 验证过方向：

| 它们 | Cutrans 对应物 | 用法 |
|---|---|---|
| 无头引擎，所有前端只是客户端 | 宪法“VM 持有、Shell 投影” | 方向一致 |
| 单一命令注册表，带 `enabled()` 和参数文档 | `vne/commands.zig` | 借鉴：给命令补可用性判断和 agent 参数文档 |
| 效果定义是数据，面板与文档由它生成 | 待办的 D 声明注册表 | 作为 D 的蓝本 |
| `Arc` 结构共享快照 | 宪法“撤销史是快照栈”；现状 `history.zig` 的 `replace_document` 按值存两份完整文档 | 解决 v4 的快照所有权问题 |
| 用完整依赖图检查分层 | `verify-architecture` 只扫直接 `@import` | 升级为完整模块图 |
| CPU 参照答案 + GPU 对比测试 | 尚无真实渲染管线 | 将来照搬这套测试方法 |

需要用户决策：时间基准。它们用 LCM tick（每秒 2540 亿）；宪法是“帧号统一、取消秒”（2048 × 30 = 61440，见 [17-discussion-history-08.md](17-discussion-history-08.md)）。建议放进 v4 模型 ADR 对比。

Cutrans 应保持的差异：

1. **数据模型**：它们照搬 AE／PR 的图层栈（Comp／Layer／PropGroup，每帧遍历）；Cutrans 押注声明式 comp 图（SSA、一 comp 一流、按依赖失效）。
2. **AI 的参与方式**：它们是 AI 经 MCP 调命令或按 id 点 UI，工程 JSON 只是存档。Cutrans 的设想是人与 AI 共写同一份可读声明，每一步都能 diff、能撤销。这是它们没覆盖的位置。

两面镜子：

- 它们没有独立常驻的 Host 进程，靠进程内引擎加桥接也实现了“多入口同一语义”。这说明 Cutrans 的 Host／Shell 进程分离不是这个目标的必要条件，印证“分发与进程层先冻结、不加码”。
- 它们先内置效果、后做插件，与[架构评审](2026-11-12-architecture-review.md)“注册表在先、动态装载在后”一致。

## 三、对“用 Zig 重写”的保留意见（Claude 建议）

- **规模**：两个仓库各约 40 MB，650 多条命令，还有自研编解码与容器；这是几千 fork 的社区加 AI 流水线的产物。整体翻译远非“难度不大”，而且会加重用户已经说过的“看不懂 AI 产出”的断档。
- **Linux 的先例**：Linux 没有移植 Unix 代码，而是实现了 POSIX 接口，并借用 GNU 的现成工具。对应到这里：它们的功能清单（如 `docs/target-app-parity.md`）与接口设计是 Cutrans 的“POSIX”，拿来对照；成熟零件（编解码）是“GNU 工具”，可经 C ABI 复用——写一层 Rust `extern "C"` 薄壳，编成静态库，经 Port 接入 Zig。复用须保留许可证与 NOTICE，并去除 ArtCraft 商标。

建议的学习路线：

1. 精读文档，不写代码：FilmCraft 的 `project` 模型（`Project`／`Sequence`／`Track`／`TrackItem`／`EffectInstance`）、`engine/commands.rs`、`effect_defs()`，EffectCraft 的属性树路径寻址与插件 ABI。产出“对齐／借鉴／拒绝”表，追加到本页。
2. 把结论喂给 v4 模型 ADR：时间基准、效果定义作为数据、结构共享快照、参数路径寻址。
3. 进入真实媒体阶段时，再评估经 C ABI 复用它们的编解码器，对比 FFmpeg。

## 四、本会话同时悬置的两项（待用户确认）

- **v4 先定内存模型，`.cut` 语法后置**（用户提出理念，Claude 补充）：把接续顺序第 3 步“v4 格式 ADR”改为“v4 内存模型 ADR”。先定结构体，并守住可序列化纪律：引用一律存 id、不藏运行时状态、不依赖内存布局。开发期用 Zig 标准库的 `std.zon`（`parse.fromSlice`／`stringify.serialize`，已确认存在于本地 Zig 0.17）读写结构体，`.cut` 语法等结构稳定后再定。这修改的是用户已确认的顺序，**尚未获用户确认**。宪法 [04-declarations.md](04-declarations.md) 已有“树＝内存态，.cut＝硬盘态（parser 后置）”的原则，现状实现走反了：格式先冻结到 v3，内存结构仍是原型。
- **“三种生法”是否已被推翻**：用户在 2026-11-12 表示“无中生有、一变一、多合一”的定义早已推翻。但现役记忆、根目录退役档案和代码中都**没有推翻记录**：`04-declarations.md` 第 6 行仍为现行宪法，`vne/documents.zig` 的 `Birth` 仍据此实装。可能只停留在对话中未落盘，或在 [2026-11-11 事故](2026-11-11-incident-recovery.md)中丢失。**待用户复述新结论后**，再按“保留原文加勘误”追加，并评估代码影响。
