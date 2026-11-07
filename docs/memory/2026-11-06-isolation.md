# 开发、分发与本机安装测试隔离审计（2026-11-06～07）

用户要求检查并修复开发、分发和本机安装试验隔离，保留真实数据及证据，以真实产物和故障注入验收，不能把源码测试或同资产重装当成升级事务。本文记录本次实现；此前安装成功与清理记录仍是历史，不用于证明此版安装包已完整通过。

## 实际发现与修复

1. **上下文重复且会回退。** bootstrap 与 runtime 各自解析默认根，开发依赖 cwd，安装缺资源时可能回退历史 home/appdata。现由 `vne/product.zig` 集中身份、版本、AppId、ProgID、扩展名与服务默认策略，构建生成各形态的 `cutrans-context.json`；`vne/environment.zig` 在加载前解析物理根、形态与频道。显式 mode 必须匹配产物，缺声明、错身份或未配置服务直接失败。
2. **用途、形态、频道混为一谈。** 新 purpose 独立于 form/channel，实例标记记录四项身份。诊断、验证、回放必须显式独立数据，不能采用非空无标记目录或正常实例。旧正常数据仅可在对应默认位置识别 Cutrans 持久格式，不改旧标记；其它无标记旧目录保留待核实迁移。当前频道共用安装 AppId，未提供并行安装登记。
3. **构建输出承载测试数据。** 新验证根改到已认领的 `scratch/verification/<case>-<uuid>`，默认保留。build prefix 只定位产物，不授予删除权。GUI、CLI、Host、Shell、诊断均拒绝把任何用途的数据写入已声明构建根，复制出的便携版也不能指回该根。单独 `portable --prefix` 会安装构建声明。程序根内部仅允许专用 `data/` 树，不允许写入任一可选 Pack。
4. **运行时和 Shell 验证顺序过晚。** 资源完整性、ABI 和符号准备通过后才创建数据标记；GUI/library 在启动 Host 前完整验证 Shell；restart 在停止当前 Host 前验证候选。失败不创建数据或提交选择，已损坏的选择锁保留。
5. **诊断修改作品和 Pack。** 移除向包内示例保存的行为，强制独立 `--verify-data-dir`，Pack 验证在数据创建前完成。外部文档只读打开，往验证 Session 保存副本；验证后回到固定合成场景，不覆盖原件。新增只读 `--inspect`；CLI `context` 与之对账。
6. **隐式 cwd 状态与 DLL 依赖搜索。** 禁用 ImGui 默认 `imgui.ini`；产品子进程指定程序 cwd。LibraryPort 使用绝对路径及 `LoadLibraryExW` 的所选目录和 System32 搜索选项，系统库另有只允许 basename 的入口。真实 DLL 夹具验证拒绝从 cwd/PATH 找缺失的依赖。
7. **开发诊断资源布局不完整。** 实测定位为 bin 缺少自身 context 对应的 VM 清单，不归因于环境。构建现在生成 development/portable/installed 各自清单，context 均参与哈希；默认 install 一并装配 Runtime、desktop 和 NanoUI Pack。三个诊断动作使用独占案例下的空 data 子目录，避免把验证所有权标记混作应用身份。
8. **安装诊断可能触及日常数据。** 安装前后均使用专属临时目录，拒绝外来 `VerifyDataDir`。真实提取布局使用 installed context 与匹配 VM 清单，先诊断再复制和登记。
9. **升级和卸载不能证明安全。** 不再把相同资产重装称为变更资产升级。后者在复制前拒绝；同资产重装核对登记归属，正常保存／停止 owned Host 并确认进程退出后才能继续。控制器缺失、路径不明或进程无法定位不视为已停止。显式 Runtime 激活完整校验、创建和握手后才提交锁，失败保留旧选择并可重试；这不是文件与登记的整体事务。
10. **旧卸载器与同名快捷方式归属风险。** 卸载须仍拥有当前根的登记和打开命令；同名异根快捷方式阻止安装，旧库快捷方式只处理同根项。登记和快捷方式修改前备份，备份写入失败即停止。卸载保存或备份失败中止；安装后失败返回9并留下阶段，未宣称 post-install 自动回滚。自动旧目录迁移关闭。
11. **验证清理权限过宽。** 清理 helper 要求精确项目验证根与产品所有权标记，检查所有父级及子项 reparse，拒绝越界和链接，即使调用者要求 ignore_errors 也不能吞边界错误。历史验证根不再自动递归删除。注册测试默认拒绝，显式启用还需独立 OS SID 证明，缺失或空生产 SID 不能通过。
12. **GUI 验收证据错位。** 实测桌面首帧成功，播放 fixture 却等待独立 Host 的 stderr；Shell 只按 generation 去重还隐藏了相同静态内容的 t 变化。现在仅在真实 backend submitted 且 FrameReport RPC 成功后，按 generation 或 t 变化记日志；fixture 精确核对 Shell 的末帧 t=3，不以镜像或 Host 累计计数冒充提交。

运行归属、入口映射及执行规则详见 [环境隔离说明](../environment-isolation.md)。直接 C ABI Config 仍是受信任调用方契约；未实现不可信插件的身份或系统沙箱，不能据本轮公开 EXE 检查宣称它已经具备。

## 本机只读盘点与处置

- 真实体验安装为完整单根，4 份 Pack 清单覆盖的48个应用文件均按大小和 SHA-256 验证通过。
- 一个当前用户卸载登记、一个同根开始菜单入口，`.cut`／ProgID 同根，无 UserChoice 覆盖。
- 未发现相关 PATH、App Paths、Run、URL 协议、服务或计划任务；已知更新/cache/download 候选不存在。没有扫描其它产品的私有数据或声称穷尽全机缓存。
- 捕获初始、阶段复核及最终均没有 Cutrans 活动进程；真实安装根及父链无联接或符号链接。
- 原有 `zig-out/verification/real-user-install` 的8份日志／注册备份、其它验证目录、真实安装与数据、相邻退役项目全部保留。未读取真实作品、授权或凭据内容。
- **原有内容删除白名单为空；实际删除原有安装、用户数据、注册项和快捷方式均为0。** 没有运行旧卸载器，没有恢复其它产品配置。没有要改的系统项，因此没有把只读盘点快照称为已执行的恢复备份。
- 测试中只替换或删除新认领案例中的合成夹具：故意缺文件／坏清单／坏锁／坏 Catalog、DLL 依赖和 managed 快照，以及两个新建 junction 的链接本身。需恢复的文件均恢复；链接用精确非递归 `os.rmdir` 移除，目标哨兵保留。案例根和日志默认保留。
- 最终真实安装的4清单、48应用文件及卸载项／快捷方式目标参数cwd／关联与初始一致。初始未逐字节哈希的卸载器等文件不作字节不变承诺。

机器专属证据在忽略的 `scratch/isolation-audit/`：`local-install-inventory.json/.md`、`cleanup-plan.json`、`local-install-final.json`、`local-install-final-comparison.json/.md`。个人路径、账号与注册导出不提交公开仓库。

## 本轮最终验证

最终代码执行：

```text
zig build install portable installer library-probe test test-core --summary all
Build Summary: 155/155 steps succeeded; 1126/1126 tests passed
```

这是构建器报告的执行项数，不能解释为1126条互不重叠的产品场景。NanoUI upstream 单元测试在前一基线轮已通过，本隔离切片主要执行下面的分发集成检查。

| 验证 | 实际结果 |
| --- | --- |
| `verify_isolation.py` | 12组：污染home/appdata/Cutrans/上游profile变量、cwd与.env不改变解析；GUI/CLI同根；默认与显式staging禁写；所有可选Pack及installed兄弟包禁写；junction指入程序包拒绝；原件与Pack不变；身份冲突、缺声明、禁用服务、坏锁、独占OS锁、候选激活失败／重试；DLL依赖只选7、不选cwd/PATH的99；清理拒绝junction且保留目标 |
| `verify_runtime.py` | 独立DLL、无wgpu、真实保存恢复；缺文件／ABI／创建／握手失败不改旧锁；人工installed布局重定位；绝对原件不变、Session副本v3；篡改Runtime失败不创建data |
| input / playback / replay / assets | 真实分发Runtime；语义输入、4帧、确定性回放、素材／持久库恢复与损坏负例全部通过 |
| `verify_host.py` | 幂等、单实例、第二写者拒绝、保存失败degraded、修复后重试、异常终止恢复、Pack未写均通过 |
| `verify_shell.py`、`verify_attach.py` | 真实桌面启动、末帧t=3真实提交、素材动作、四次附着及Host继续存活；空cwd无ini、既有ini字节和mtime不变；关键ini检查等待6秒越过默认保存周期；不截图或注入系统输入 |
| NanoUI development / portable | 真实Host附着、前端动作、失败不提交Shell选择、D3D11 readback和动态纹理均通过，Pack与原staging不变 |
| 三形态诊断动作 | development / portable固定独立数据；Runtime诊断为development，均通过且不污染日常根 |
| 全新带空格prefix | 只执行portable目标即产生构建声明；默认启动和显式向该prefix写data均拒绝，未创建data |
| 注册测试入口负例 | 默认禁用、缺失／格式错误生产SID拒绝，未启动系统注册测试 |
| 实际安装器 | 两次对最终同一字节文件做真实提取预检及非法VerifyDataDir拒绝；约定退出7，目标安装目录未生成，登记和快捷方式快照相同 |

12组详细命令、错误名和文件哈希：`scratch/verification/isolation-4c7144800bac/report.json` 与 `commands.jsonl`。Runtime激活的合成 Session 在成功候选、故意缺文件失败和回原候选后，除预期的选择锁外哈希不变。

最终安装器 SHA-256：

```text
535deb9d09d4f7ea08510276a7fd09f6d5db346a6a0774231d671e702d0e1c6c
```

同一字节副本及日志保留在 `scratch/verification/preflight-artifact-333e0ab68876/`：安装器、`SHA256SUMS`、`evidence.json` 和最终源码／集成日志。该副本再次以 `--installer <副本> --artifact-check --expected-sha256 <上述哈希>` 通过。原最终安装器预检报告在 `scratch/verification/windows-installer-af13af5b9add/artifact-acceptance.json`。后续改变程序、README、context、频道或其它打包输入都可能改变产物，不能沿用本次哈希。

## 未解决与禁止冒认

- 本机没有已证明可用的独立交互用户或 Windows VM。平台管理账号不被冒用，未创建账号、读取凭据或启用系统功能；改变 HOME 不构成完整隔离。
- 此版**完整安装、同资产重装保留、真实卸载保存失败与重试、登记清理／回滚均未执行系统验收**。安装器7仅是预检故意停止，不能报安装成功。
- **变更程序资产升级事务未实现并验收，目前拒绝。** 安装后失败可留下失败状态和需修复的登记，不能宣称无损自动回滚或已经可发布。
- GUI日志、真实GPU提交及离屏readback不等于视觉、IME、焦点和用户操作手感通过。
- 没有发布，也没有把新包覆盖现有体验安装。未来发布必须先完成所需系统验收，再发布经过验收的同一份字节并复核哈希，不能验收后重建。
