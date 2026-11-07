# Cutrans 现役记忆入口

本文件是项目记忆的唯一入口。每条事实的权威位置可以分文件，历史记录与现役摘要分开维护。

## 先读什么

1. [现役状态与已知边界](docs/memory/current.md)：从这里判断当前实现，不能把历史通过记录当成本轮验收。
2. [界面配色与材质](docs/ui-style.md)：用户认可的深靛蓝、冰蓝与紫色、轻微金属反光方向。
3. 按任务阅读下方对应的宪法簇与实施历史。历史提案不自动视为现役实现。
4. 代码头注释和实现用于对账；git 历史用于查证当时状态。退役项目不作为现役事实来源。

## 持续约束

- 一切皆插件；声明唯一真源，一切皆投影；机制与策略分家。
- VM 持有文档、资源、授权与任务语义；Shell 只持有镜像和本地交互状态。
- 文档、内存 Station、持久资源库与可重建缓存分层。自动同步仅可由可选插件触发。
- 记录格式定长，不等于容量固定；每条命令只有一个语义入口，接受、就绪、完成、提交分别对账。
- 开发、便携、安装、临时验证互不混用数据；安装单根，升级和卸载保留用户数据。
- 不读取 VocalSet、VoiceLab 或相关私人项目；不采集屏幕、不控制真实键鼠。离屏 UI 测试不替代真实视觉与 IME 手感。
- 凭证和个人敏感信息不入库。公开记忆只留项目必要信息，不留个人画像或无关部署地址。
- 用户决定方向，讨论先行；获得实施指令后完成已授权工作。新决定及时记录。
- 自动构建、测试、CLI、PowerShell查询与后台辅助进程默认不弹命令行窗口，统一通过隐藏自动化入口启动并保留日志、输入输出和退出码；真实GUI验证单独安排，不用隐藏控制台替代GUI验收。（2026-11-07用户要求）

## 维护方式（2026-11-06 重构）

- 本轮按用户“开始重构”的指令，将原单文件按主题及段落迁入下方文件，保留非个人历史内容与取代顺序。
- 决策历史继续追加，修正用新条目说明；现役状态摘要允许依据已验证事实更新。
- 隐私脱敏是保留历史的例外，不再通过追加注释继续公开原始个人内容。
- 既有 Git 历史没有改写。当前文本脱敏不能撤回旧提交中的原始内容。
- 所有新实施记录必须写清实际验证与未验证范围，README 仅作对外投影。

## 主题与历史索引

- [〇、现状声明与检索纪律(2026-10-09 立)](docs/memory/00-reading.md)
- [使命宣言:剪辑软件界的 GNU(2026-10-09,用户口述种子)](docs/memory/01-mission.md)
- [一、身份宪法](docs/memory/02-identity.md)
- [二、流协议(细腰核心)](docs/memory/03-stream.md)
- [三、树(声明层)](docs/memory/04-declarations.md)
- [四、模态与制式](docs/memory/05-modalities.md)
- [五、参数世界](docs/memory/06-parameters.md)
- [六、素材与器具(源宪法)](docs/memory/07-sources.md)
- [七、依赖与装配](docs/memory/08-assembly.md)
- [八、物化点与存储经济学(L1/L2/L3)](docs/memory/09-storage.md)
- [九、压缩与格式法](docs/memory/10-formats.md)
- [十、时机与消费(调度立法闭环)](docs/memory/11-scheduling.md)
- [十一、触发与泵（分段 1）](docs/memory/12-pumps-01.md)
- [十一、触发与泵（分段 2）](docs/memory/12-pumps-02.md)
- [十二、音频域](docs/memory/13-audio.md)
- [十三、内存哲学](docs/memory/14-memory.md)
- [十四、Zig 地方法规(0.17 实况)](docs/memory/15-zig.md)
- [十五、工程现状台账(历史基线;现役状态见文末最新实施台账)](docs/memory/16-historical-baseline.md)
- [十六、哲学散记与参照系（分段 1）](docs/memory/17-discussion-history-01.md)
- [十六、哲学散记与参照系（分段 2）](docs/memory/17-discussion-history-02.md)
- [十六、哲学散记与参照系（分段 3）](docs/memory/17-discussion-history-03.md)
- [十六、哲学散记与参照系（分段 4）](docs/memory/17-discussion-history-04.md)
- [十六、哲学散记与参照系（分段 5）](docs/memory/17-discussion-history-05.md)
- [十六、哲学散记与参照系（分段 6）](docs/memory/17-discussion-history-06.md)
- [十六、哲学散记与参照系（分段 7）](docs/memory/17-discussion-history-07.md)
- [十六、哲学散记与参照系（分段 8）](docs/memory/17-discussion-history-08.md)
- [十六、哲学散记与参照系（分段 9）](docs/memory/17-discussion-history-09.md)
- [十七、现役索引与认知校准(2026-11-02)](docs/memory/18-calibration.md)
- [十八、分发四物、OS 依赖轴与新旧 VM 路线(2026-11-02 调研定案)](docs/memory/19-distribution.md)
- [十九、分阶段推进流程(2026-11-02 定)](docs/memory/20-phases.md)
- [二十、VM Runtime 与 VNE 实施台账(2026-11-02)（分段 1）](docs/memory/21-implementation-01.md)
- [二十、VM Runtime 与 VNE 实施台账(2026-11-02)（分段 2）](docs/memory/21-implementation-02.md)

## 最新实施记录

- [2026-11-07 自动化隐藏控制台与日志继承修复](docs/memory/2026-11-07-quiet-automation.md)
- [2026-11-07 连续创作会话架构优化计划与A1／A2／B1／B2／C1／C2a实施](docs/memory/2026-11-07-architecture-plan.md)
- [2026-11-06～07 开发、分发与本机安装测试隔离审计](docs/memory/2026-11-06-isolation.md)
- [2026-11-06 工程基线、上游与界面重构及验收](docs/memory/2026-11-06-foundation.md)

- [2026-11-07 C2b资源重新定位／采用核心、独立版本与回执及实际DLL／Host验收](docs/memory/2026-11-07-architecture-plan.md)：ABI9；GUI恢复入口尚待C2c接入，完整协议见[资源操作](docs/resource-operations.md)。

- [2026-11-07 FileHub方向补充与资源分层建议](docs/memory/2026-11-07-architecture-plan.md)：用户明确资源管理器偏向通用资源空间，下载器为独立应用；来源／驻留／消费版本的具体调整仍标为讨论建议。

- [2026-11-07 独立App、来源区域与VM资源入口](docs/memory/2026-11-07-architecture-plan.md)：用户明确本地／云来源与VM专属区、默认引用和显式独立化、拖入其它App的统一登记快捷路径、专属区直接编辑及显式出境复制；名称和具体隔离机制仍待细化。

- [2026-11-07 C2c1已加载资源优先、来源观察与完整RAM独立化实施及验收](docs/memory/2026-11-07-architecture-plan.md)：ABI10；当前PNG闭环，完整缓存、异步刷新与来源App继续后续。

- [2026-11-07 C2c2通用只读文件登记、App交付与实际DLL／Host验收](docs/memory/2026-11-07-resource-registration.md)：Resource API v2，179步骤／14组新验证／18项同产物回归；真实联接／硬链已测、符号链接未覆盖。另记录NanoUI官方／fork新提交，未盲目升级。

- [2026-11-07 仓库、README、生成物与GitHub源码交付整理](docs/memory/2026-11-07-repository-organization.md)：分类文档、隐藏开发入口、源码包守卫与缓存生成；保留旧输出内数据／证据，Git历史未改写或推送。
