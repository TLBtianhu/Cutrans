# 仓库布局与文件归属

源码根保留按职责划分的模块，构建入口不依赖把所有文件塞进单一`src`目录。根README负责项目入口，技术细节由[文档导航](../README.md)按主题组织，现役摘要与历史决策由[项目记忆](../../MEMORY.md)索引。

| 路径 | 内容与归属 |
| --- | --- |
| `runtime/`、`vne/` | VM业务、声明与窄协议 |
| `host/`、`bootstrap/` | 进程生命周期、激活及入口 |
| `shell/`、`consoles/` | 客户端投影、GUI／CLI适配 |
| `apps/`、`uikit/`、`gpu/` | App实现、共享视觉与GPU适配 |
| `ports/` | 受控OS能力 |
| `assets/`、`config/` | 产品素材、示例与启动声明 |
| `build.zig`、`build.zig.zon`、`build_support/` | 构建图、源码包选择及构建辅助 |
| `tools/`中的脚本 | 恢复、构建与验证源码；`tools/dev.ps1`是Windows隐藏命令入口 |
| `packaging/` | 分发与安装定义 |
| `third_party/`、`dependencies.lock.json` | 固定依赖及来源、许可证、有效hash |
| `docs/guides/`、`docs/reference/` | 使用说明与命令参考 |
| `docs/architecture/`、`docs/development/` | 架构与开发说明 |
| `docs/research/`、`docs/history/`、`docs/memory/` | 研究材料、旧验收、决策及现役摘要 |

## 本机生成内容

以下路径通常不进入GitHub源码，也不进入Zig源码包。忽略只决定提交范围，不授权删除本机内容。

| 路径 | 用途及处理规则 |
| --- | --- |
| `tools/zig/`、`tools/InnoSetup/` | 固定版本工具链，可由bootstrap恢复 |
| `zig-pkg/` | 下载与依赖源码缓存 |
| `.zig-cache/` | 构建及测试缓存；清理前确认构建／测试已停止 |
| `zig-out/` | 当前分发产物与前缀；同时仍有历史验证数据，不能整目录清空 |
| `scratch/verification/` | 带归属标记的合成案例、失败日志和验收证据，默认保留 |
| `.cutrans-dev/` | 已声明的开发实例数据，不是构建缓存 |
| `imgui.ini` | 已忽略的旧布局残留，当前代码禁默认写入，本轮保留 |

尤其保留既有`zig-out/verification/portable-data/`、`runtime-data/`、`real-user-install/`及`zig-out/refactor prefix/verification/`中的历史内容。它们包含旧文档／任务或验收记录，不能按“位于构建目录”判垃圾。当前新的验证数据已转入`scratch/verification/`，新产物根禁写运行数据；历史混放没有被本轮整理悄悄删除或迁移。

正式便携／安装用户数据和用户工作区归属由运行context决定，详见[环境隔离说明](../environment-isolation.md)，不根据cwd、是否打包或目录名字猜测。

## GitHub与源码包

源码快照包含第一方实现、构建和验证脚本、文档、许可证及固定依赖的必要文件。完整Zig、本机exe／dll／lib／pdb、Python缓存、运行数据和验收目录不应提交；已锁定system_sdk的两份`.so`是保留的第三方SDK例外，不能宣称整个仓库完全没有二进制。

`tools/repository_audit.py`检查源码包清单、构建输入、相对依赖与文档链接；新增模块或工具时应同时维护包清单。Git忽略规则不影响已跟踪文件，发现缓存已被跟踪时须显式移除索引。

Windows检出时使用仓库局部`core.longpaths=true`处理SDK深路径，不修改系统长路径策略。SDK的`.gitattributes`保留Cutrans一项元数据补丁：`!text`改为`-text`，明确禁止Git对这些文件做换行转换。原因是其中176份非UTF8头文件／资源文件会受全局autocrlf影响，造成检出内容与锁不一致；未修改这些源码正文，补丁及新有效hash在依赖锁中记录。源码ZIP导出另显式关闭本次Git命令的autocrlf转换，避免机器全局配置改变交付字节。

用户随后明确授权重建公开历史：`master`已从验收源码树建立新根，旧试验标签与Release先备份后撤下。旧记录在本机私有bundle及`refs/private/`保留，不能把这些备份用`push --mirror`重新推回公开仓库。此操作只证明本仓库已审分支／标签不再引用旧历史，不能证明GitHub缓存或他人的副本已物理删除；用户指定的fork保持原样。实施与证据见[历史重置记录](../memory/2026-11-07-public-history-reset.md)。
