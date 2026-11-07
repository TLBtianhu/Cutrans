# 自动化隐藏控制台（2026-11-07）

用户指出测试频繁弹出命令行窗口，要求避免。此偏好持续适用：自动构建、CLI、PowerShell查询和后台辅助进程默认隐藏控制台，保存日志与退出码；GUI验证单独安排。架构C切片没有被此工具修复提前视为完成。

## 实施

- 新增`tools/automation_process.py`，集中提供`run`、`Popen`、`call`、`check_output`及`run_console_tree`。命令是唯一位置参数，其余启动选项按关键字传入；保留cwd、env、输入输出、超时与错误语义。
- 普通自动化子进程使用`CREATE_NO_WINDOW`，不把`SW_HIDE`施加到真实GUI窗口。现有Python验证、bootstrap与构建动作的直接spawn全部迁入此入口，安装验证也复用它。
- 固定Zig 0.17的公开Build Run没有隐藏控制台选项，内部Maker启动子进程默认不设`create_no_window`。仅隐藏顶层Zig仍可能让后代另开窗口。自动化构建因此使用`CREATE_NEW_CONSOLE`＋`STARTF_USESHOWWINDOW/SW_HIDE`，让编译器、配置器、生成器和测试程序继承同一预先隐藏的控制台；工具链源码没有修改。
- 最外层由`pythonw.exe`经`Start-Process -WindowStyle Hidden`进入日志runner；日志独占新建，保留实际退出码。该约束必须由自动化调用者遵守，不能声称绕过入口的外部启动器也受控。
- 实测发现多层隐藏Python调用在stdio全默认时会丢重定向日志：Python不会自动设置`STARTF_USESTDHANDLES`。helper现显式继承有效的0/1/2描述符，缺失描述符使用DEVNULL；已有capture／input／显式stdio继续由stdlib处理，`check_output`保留其自动PIPE。
- 增加`verify-automation`目标、共享helper构建输入与源码包清单。原生产品ProcessPort本来已用`CREATE_NO_WINDOW`，没有改变产品GUI子系统或启动语义。

## 实际验证

总日志目录：`scratch/verification/quiet-process-3adaca4445c2/`，包含施工失败与最终复验；不删除真实安装、会话或证据，没有执行安装／卸载／系统登记。

- 6项`test_automation_process.py`通过：Python启动策略静态检查、普通子进程无控制台、未经改动的孙进程继承隐藏构建控制台、stdin／cwd／env／stderr／非零退出码、Popen／check_output／call，以及多层默认stdio日志继承。用GetConsoleWindow／IsWindowVisible／GetConsoleProcessList读取真实Win32状态，未截图或注入键鼠。
- 最终`core-recheck.log`：`zig build test-core verify-automation -Dcore-only=true --summary all -j4`，19/19步骤、19/19本轮执行的Zig测试通过，其余核心测试复用缓存；6项Python测试另计。控制台状态证据在`scratch/verification/quiet-process-691dcdf89f07/console-state.json`，普通child的HWND为0，隐藏parent与raw grandchild同HWND且均不可见，嵌套stdout／stderr及退出17保留。
- `bootstrap-tests-sealed.log`：4项bootstrap恢复／失败保护测试通过，使用临时伪造归档，没有改动真实工具链。
- `host-sealed.log`与`isolation-sealed.log`记录最终实际产物的Host生命周期、PowerShell进程查询与12组环境／故障隔离验证；`installer-contract-sealed.log`仅为安装脚本静态契约检查，不作为安装包验收。
- `sealed-summary.json`核对以上最终日志退出码与SHA-256，测试后Cutrans进程为0。

本轮复验曾在`runtime/documents.zig`编译时出现stdlib `compress/lzma/test.zig`读取`Unexpected`，完整失败日志保留于`verification-build-final.log`。该文件与固定归档均为空，未据此认定损坏或改写。原命令的未知命令`test`输出来自明确的命令注册表负例，并非额外失败。独立缓存定向运行文档测试19/19通过（`documents-core-probe.log`），随后同一共享缓存的核心构建也通过；文件读取失败暂未复现，根因仍未确定，不笼统归因于环境或宣称已修复。

本轮没有打开GUI测试窗口，隐藏控制台状态与产物功能回归不构成视觉／IME验收。
