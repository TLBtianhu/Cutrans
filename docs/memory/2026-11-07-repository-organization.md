# 仓库、README与源码交付整理（2026-11-07）

用户要求整理项目目录、README和适合上传GitHub的源码。此次区分当前Git树、本机生成内容及旧Git历史，不把目录名称当清理依据，也不借普通整理改写或推送历史。

## 实际整理

- 根README从422行缩到约60行，定位／当前能力／未完成边界／最短构建／文档入口分开；技术内容迁入`docs/guides/`、`development/`、`architecture/`、`reference/`和`history/`。`docs/README.md`统一导航，7份跨项目讨论及旧笔记迁入`docs/research/`并标历史，不作为当前接口说明。现役资源／身份／隔离专题原路径保留。
- 新增`AGENTS.md`、`CONTRIBUTING.md`、第一方文本行尾规则及仓库归属说明。公开源码和便携用户入口分开：根README服务源码，便携包使用`packaging/README-portable.md`投影为根README，不打包整套开发记忆以形成验收hash循环或无效离线链接。
- 补齐`build.zig.zon.paths`遗漏的三个资源验证脚本及新开发／审计入口。新`tools/repository_audit.py`检查清单存在性、必要源码／本地依赖覆盖、生成物／本机二进制混入、构建输入及第一方Markdown文件链接；支持无Git的解包源码，`verify-repository`目标在core-only模式也可用。两份已锁定SDK `libX11.so`精确保留，没有依赖版本升级；SDK仅一字符Git属性保真补丁及对应新锁另记如下，不宣称仓库完全无二进制。
- 新`tools/dev.ps1`通过pythonw＋`tools/dev.py`进入统一隐藏进程工具；参数以UTF-8 JSON/base64传递，不经过cmd字符串拼接。bootstrap／build／verify-repository日志与退出码保留到认领的`scratch/verification/developer-*/`，Zig后代共享预先隐藏的控制台。显式GUI验证仍可能开窗口，不混同于隐藏控制台验收。
- 桌面UI编译改为声明JSON→缓存输出LazyPath→命名`desktop_cui`嵌入，不再每build写回源码树；两个编译器都要求显式`--output`。`desktop.cui`与`startup.ccb`旧生成文件已按精确白名单归档并从索引移除，新输出与原文件SHA完全一致，构建后源码两位置仍不存在。
- 已跟踪的旧Python `.pyc`仅移出索引，本机文件保留；空且无引用的`src/`经父级无链接及空目录检查后非递归删除。`imgui.ini`及真实会话／凭据／作品／全部验收案例未删除。第一方历史记忆的一处个人home引用按既有隐私例外脱敏；vendor两处同样式均为合成中文路径测试，未改动。

## 盘点和保留内容

初始HEAD为`08cd40f5`、工作树干净。只读证据`scratch/verification/repository-inventory-8dea551f3463/inventory.json`：当前3916个tracked文件约69.90MiB，其中vendor约64.90MiB；完整Zig、构建缓存和scratch均未被当前Git树跟踪。当前本机逻辑大小约`.zig-cache/`66.95GiB、`scratch/`5.26GiB、`tools/`412MiB、`zig-out/`353MiB、`zig-pkg/`243MiB；逻辑大小不等同实际去重磁盘占用，遍历跳过了链接。

尤其保留5处历史混放目录：`zig-out/verification/{portable-data,runtime-data,real-user-install}/`及`zig-out/refactor prefix/verification/{portable-data,runtime-data}/`。它们有旧文档／History／任务或原安装备份／验收记录；没有因为在输出根内而清空，也没有猜测恢复其它产品的注册配置。新生成产物可重建，不代表整个既有输出目录可直接删。

Git历史仍有旧工具链、大型本机库和早期记忆敏感语境；当前去跟踪与脱敏不能撤销旧提交内容。只读统计.git约172MiB、reachable blob原始总量约522MiB（非clone压缩体积）。本轮不rewrite、force-push或发布远端；提供无Git历史源码快照作为可审查交付，后续历史净化需另定范围。

## 实际验证与边界

总证据`scratch/verification/repository-acceptance-aa8407b2213c/`，含路径白名单、生成文件归档及hash、初次失败和最终日志。

- 真实`tools/dev.ps1 build test-core test install portable library-probe verify-repository verify-automation --summary all -j1`最终184/184步骤成功、4/4本次执行Zig测试通过，其余有效缓存；10项仓库负例和6项隐藏控制台测试本次实际执行通过。没有把多轮重复测试相加。
- 静态审计覆盖3930个选定文件、66份第一方Markdown及4个本地依赖包；最终JSON为准。10负例检查漏工具／依赖、失效声明、二进制／缓存、断链、危险路径、不可交付空目录，以及依赖路径、格式串和分发文档投影的正反例。首次实仓误报依赖相对路径、运行PATH格式串和历史概念／投影链接，已按实际上下文修正；真实缺失链接另修正，没有通配豁免整个目录。
- 最终同份产物4项实际验证全通过：Runtime Pack／激活、真实Host、12组环境隔离及14组通用资源登记／交付。`sealed-final-summary.json`逐文件核对产物前后hash未变；未启动真实GUI或安装器。五个依赖有效源树保持原锁，SDK的单字符属性补丁按审查记录新hash，没有依赖版本升级。
- 归档的两份生成文件与缓存／安装投影新文件SHA一致，旧Python缓存本机仍在，源码没有重新出现`.cui/.ccb`。源码快照单独执行解包审计、依赖hash及核心构建，实际结果和ZIP哈希以`source-snapshot-accepted-report.json`为准；此检查不等于从网络恢复所有依赖后的全新OS安装验收。

首次Git索引快照解包真实发现根`.zon.paths`仍列NanoUI的`apps/`与`site/`空目录树，Git不记录空目录，源码包里不存在；移除这两项无文件声明并补第10项守卫测试，vendor及其锁无需改变。失败ZIP及报告保留，未据本机完整构建成功称快照通过。初次隐私替换脚本因home路径没有尾分隔符而在任何写入前断言失败，修正匹配范围后成功。所有修改仅在项目源码和认领证据目录，未清缓存、未改变系统注册或既有体验安装。真实GUI／IME、完整安装升级卸载、旧历史净化和远端更新不在本轮通过范围。

第二次解包进一步定位SDK hash不符：176份非UTF8、无NUL的头文件／资源文件仅有Git导出阶段LF→CRLF变化，2634文件无增删／路径case差异，原工作树与索引正文逐字节一致。独立强制autocrlf检出也复现，证明不是解压或编译器失败。SDK的`.gitattributes`原`!text`回到unspecified而受全局配置影响；只改为`-text`，其余属性不变，不改176正文。SDK有效hash按这一份元数据补丁更新为`fe8b0ae4c9f1ca718889b25a7073fbbd8510d3d0a45a641f786220f53f80feee`，文件数仍2634，provenance明确本地补丁且不伪造新上游版本。强制autocrlf=true的独立检出修复前仅SDK依赖失败、修复后6项全通过，源索引hash前后不变；证据`checkout-{before,after}-longpaths.json`及`scratch/verification/repository-sdk-diff-23ca961ec62a/`。深路径探测曾明确报Git Filename too long，改用仅该命令的`core.longpaths=true`验证，并在克隆示例使用仓库局部选项；未修改系统或全局Git设置。源码ZIP导出同时显式禁用本次换行转换以保证交付字节确定。
