# C2c2 通用只读文件登记与App交付（2026-11-07）

用户批准上一轮提出的顺序：先完成“本地只读来源→通用资源登记→统一引用交付→消费App接受或拒绝”，随后再处理工作正文与固定版本分离、独立来源App。本记录是本片实际实施和验收，不能据此宣称完整文件资源管理器已经完成。

## 实际行为

- 复用原本即可容纳完整字节的Catalog、版本存储与Station，没有另建TXT／未知格式专用存储。新增`registerFile`／`registerFrozenFile`、纯读取`readFile`、`ensureFile`及`resource.acquire id sha256`。TXT、PNG、未知格式、空文件和恰好16MiB文件均可登记；是否支持解码由消费方决定。单文件预算仍16MiB，Station仍16项／64MiB，资源及文件夹原型限额不变。
- Resource API显式升v2，Host ABI仍10，结构布局与RPC 26～28不变；v1请求／响应明确拒绝。`register_file=3`的target为0、head为全零，probe不授权、不写目录、不增Station。submit先查询回执，再核CAS与重新打开的候选身份／hash／长度，成功返回实际分配或复用的非零ID。相同token丢回复重试不重复登记；新token、同已验证来源与hash复用原ID，来源漂移不会静默改head。回执仅当前Runtime incarnation有效。
- 登记默认只读reference，不自动复制媒体或创建持久版本。失败保护Catalog、发号与原文件；前置成功发布而尚未被目录引用的只读grant可能保留，作为可重试依赖记录，不擅自回收。重复资源也检查mount仍为持久、只读且locator匹配，撤销／改写权限／错路径不会被早返回掩盖；合法纯metadata复用不需IO。
- 新外部来源口岸使用同一打开句柄的最终路径、真实身份与字节；guard在读取正文前检查。排除当前data、resource、实际Runtime模块目录及通过有效context识别的产品根，按路径组件及真实路径识别目录联接别名，不把Python宿主EXE或整个仓库父级当兜底产品根。新入口为拒绝硬链绕入而暂拒所有多硬链接文件。无效context或无法确定所需路径时明确失败，不退回cwd／home。
- 新通用读取检查已验证来源、持久只读mount、locator、真实身份及同样的来源边界，不更新授权last_hash。owned内容仍读取既有版本；lease归零仍释放，没有LRU。旧PNG的relocate／adopt验证、严格固定版本、旧授权及旧作品政策保留；没有悄悄放宽为通用类型切换。
- `shell.library_client`支持登记、未知结果保留原请求及重试，结算保留原候选内容hash，不用之后的目录head替代。`shell.resource_delivery`从已知成功结果形成Ref，以ID＋hash调用权威acquire、同步精确handle、取完整字节并核SHA后再交消费callback；命令Job字段不当handle。消费拒绝保留登记ID、内容与原文档，可以独立重试交付；执行结果与投影失败分别表达。

以上是新入口的受控IO契约。既有外部URI／旧mount兼容通路仍存在，尚非VM全局IO中介；原生同进程模块仍受信任，不能据此宣称已有OS强制沙箱。完整GUI拖放、跨进程App调度、通用目录provider、可变owned正文、异步刷新、新代际采用与细粒度导出事务尚未实现。

## 实际验收

总证据：`scratch/verification/c2c2-acceptance-9bb8f609223d/`，最终`acceptance-summary.json`及`sealed-summary.json`。新验证脚本`tools/verify_resource_registration.py`，可由`zig build verify-resource-registration`运行。

- 最终源码命令为`tools/zig/zig.exe build test-core test install portable library-probe --summary all -j1`。`build-final.log`179/179步骤成功、136/136本次执行测试通过，其余有效缓存。源内验证覆盖通用字节、重复与满表复用、授权门禁、失败保护、RAM独立化冷恢复、真实Win32联接与硬链、客户端丢回复及错误载荷拒绝；重复模块中的同一测试不累计成唯一测试数。
- 实际DLL／Host新报告`scratch/verification/resource-registration-28eb8362d075/report.json`14组通过：中文／空格路径、TXT／PNG／未知／空／精确16MiB、旧作品及排队Job不变、只读源拒输出、旧回执优先于新CAS、重复登记、内容与同hash换对象、catalog独占锁、登记后失联及冷恢复失联、真实配置资源根／实际DLL产品根／NTFS junction／hardlink、native v1拒绝11、wire v1拒绝3且不消费v2 sequence、真实Host丢回复和重启恢复。
- 符号链接创建实际返回Win32 1314（缺少创建所需权限），报告`symlink_coverage.covered=false`，没有跳过后伪称通过。真实junction及硬链接已执行；本轮未修改系统策略或权限来补这一覆盖。
- 同份产物封存18项headless命令全部通过：新登记、驻留资源、资源操作、来源身份、资源版本、assets、同步／异步jobs、Host transport、workspace及RPC、编辑提交、runtime、input、playback、replay、Host、环境隔离。portable／bin／runtime／shell／nanoui的74／30／11／21／13文件逐一hash前后相同；Runtime DLL SHA-256为`cd3d217c4ad8845b1e6f254f56da1c8da2f2956cd3b4049b70a0368e0fe9d8b3`。
- 隐藏自动化6项通过，Python验证脚本2项语法通过，6个固定依赖源树审计通过。结束Cutrans进程0；没有真实GUI／拖放／IME、安装升级卸载、系统注册或发布验收。源码通过不替代这些验收；发布仍须使用已验收的同一产物并核hash。

首次构建169/179步骤、2814/2819已执行测试通过，整体失败：硬链夹具错误选择Zig尚未实现的Windows `Dir.hardLink`，在5个模块中重复失败；改为真实`CreateHardLinkW`后通过。该轮另有`boot_services.zig`和`dwarf.zig` loader `Unexpected`。第二轮176/179步骤、755/755已执行测试通过，仍因`start.zig` loader `Unexpected`整体失败；同源码最终复验成功。编译器间歇读取异常根因仍未定位，没有修改工具链／清缓存／更改系统设置或统归环境；故意持锁用例的`SHARING_VIOLATION`诊断另行区别。

所有构建／测试由统一pythonw隐藏入口启动并保留退出码。所有变更及文件替换均限认领的合成验证根；原件、替换对象、链接、阻塞物及失败日志保留。本轮没有删除真实文件、修改既有安装／授权／凭据或运行旧卸载器。

## 上游核对与下一步

`upstream-snapshot.json`只读记录了远端及本地三层：6个实际源树与锁定hash一致，NanoUI官方v0.12.0标签仍指固定`d1330a8`，fork固定`00e5813`及本地补丁记录未漂移。但官方main已到`204793e4`（较基线39提交），fork otto-091到`332d2b96`（21提交，含拖放相关修复），两者包版本号仍0.12.0，不能凭版本号认定源码对齐。滚动布局／图标／字体及拖放差异可能与既有fork和本地修改重叠，需在真实GUI迁移前单独审查；本片没有升级依赖，亦未重下载上游归档核hash。可复查[官方比较](https://github.com/justrach/nanoui/compare/d1330a84fca9581cdcaff7fa71041b2cccf3066b...204793e4a0d3a836325e6b2fd13b38587569676f)与[fork比较](https://github.com/TLBtianhu/nanoui/compare/00e5813dc5f524ece9a8f4aa37878cb6be1d125e...332d2b961606c460775428820131415da0f50279)。

后续建议先把“可编辑工作正文”与“作品采用的固定版本”分账，落实保存／冲突／失败保护，再为本机文件与资源库接薄App入口；目录、云来源和新通用换源契约分片推进。当前限额、旧授权兼容和符号链接未覆盖项继续明确保留，不把计划当现役功能。
