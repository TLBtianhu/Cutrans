# 2026-11-10 安装器入口与瘦身

安装器已从旧的多文件布局切到统一 `cutrans.exe`：快捷方式、文件关联和卸载停止入口都指向它，安装包只带 exe、licenses 和 README，不再复制 `cutrans-context.json` 或 `vm-pack.json`。旧的 runtime/shell/payload 目录不再复制；检测到旧版多目录布局时明确拒绝自动升级。

## 改动

- `packaging/windows/installer.iss`：
  - `UninstallDisplayIcon`、开始菜单快捷方式、`.cut` 打开命令和 `ShortcutOwned` 均指向 `{app}\app\cutrans.exe`；
  - `StopOwnedHost` 与 runtime 激活使用 `cutrans.exe`；
  - preflight 诊断改为 `cutrans.exe --diag --mode=installed --data=<temp>`；
  - `[Files]` 只复制 `cutrans.exe`、`licenses`、`README.md`；
  - 安装器当前 4,837,808 字节。
- `cutrans.exe` 内嵌 installed context；安装布局不需要外部 `app/cutrans-context.json`，preflight 也验证了这一点。
- 旧布局策略：检测到 `runtime-envs`/`shells`/`payload` 或 `app/cutrans_vm.exe` 时记录 `CUTRANS_UPGRADE_LEGACY_LAYOUT rejected=1 migration=manual`，明确拒绝自动升级，要求先备份并卸载旧版；不做隐式迁移。

## 验证

- `build installer`：退出 0，`developer-0fbd0d898f75/`。
- `verify-installer-artifact`：退出 0，`developer-c15ca7350023/`；
  `CUTRANS_INSTALLER_ARTIFACT_OK preflight=1 override_rejected=1 registration_untouched=1 sha256=12cb20a4...`。
  - preflight 用统一 `cutrans.exe --diag` 通过；
  - 临时展开内容只有 `app/cutrans.exe`、`licenses/*`、`README.md`，没有 context 或 vm-pack；
  - 覆盖诊断数据根被拒绝；
  - 未注册、未复制应用文件、未写系统登记。
- 手工安装布局（仅 `app/cutrans.exe`，无 context、vm-pack）里 `cutrans.exe --diag --mode=installed` 和 start/shell/stop 均通过。

## 边界

- 真实安装、覆盖更新、卸载、快捷方式实际创建和 `.cut` 关联仍未验收；按仓库规则安装验收需要独立 OS 用户/VM 证明，未运行。
- 旧版多目录布局明确拒绝自动升级，未做数据迁移、旧 runtime/shell/payload 清理或回滚验收。
- 安装器未签名；管理员模式、真实下载分发、自动更新和回滚未做。
- `test-nanoui` 连续四次全绿，但此前一次的 `WS_EX_TOPMOST` 失败未定位，与本片无直接关系。
- 未提交、未推送、未发布。
