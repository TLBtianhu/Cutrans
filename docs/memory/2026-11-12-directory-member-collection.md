# 2026-11-12 目录成员显式收纳

## 背景

本机文件页此前只能把选中的单个文件登记到资源库根，目录成员与来源目录之间没有显式层级关系。目录整体收纳、工程目录独立化、递归和流式超大目录仍不在本片范围。

## 改动

- `apps/files/nanoui.zig`：
  - 登记回调增加可选的文件夹标签参数；
  - 新增“收录到同名文件夹”：以当前浏览目录的 basename 作为文件夹名（空名回退“本机目录”）；
  - 保留原有“收录到资源库”（登记到根）。
- `apps/desktop/nanoui_model.zig` 的 `registerLocal`：
  1. 先用既有 Resource API 登记文件，得到资源 id；
  2. 在根文件夹中按标签查找现有文件夹，没有则调用既有 `library.folder.create`；
  3. 调用既有 `library.move` 把资源放进该文件夹。
- 收纳只改 Catalog 的 `parent_id` 关系；资源身份、内容哈希、来源授权和字节不变。没有新增 ABI、RPC、命令或 Catalog 格式。
- 隐藏 GUI 验证扩展：点击“收录到同名文件夹”后断言根下存在以源目录命名的文件夹，且 `a.txt` 资源的 `parent_id` 指向它；输出 `CUTRANS_LOCAL_FOLDER_OK`，`CUTRANS_LOCAL_FILES_OK` 增加 `folder=1`。

## 验证

- `build test`：退出 0，`developer-118145594305/`。
- `test-nanoui-desktop`：退出 0，`developer-ae8b73268866/`；首次因 `setStatus` 的 comptime 格式串写成运行时条件而失败，改为分支后通过。
- `verify-local-sources`：退出 0，`developer-593019ce8e31/`；证据 `local-sources-f511496e014d/`。
  - 标记：`CUTRANS_LOCAL_FOLDER_OK folder=1 member=1 label=local source`、`CUTRANS_LOCAL_FILES_OK ... folder=1 ...`、`CUTRANS_LOCAL_SOURCES_VERIFY_OK dll=1 host=1 ui=1 no_implicit_registration=1`。
- 没有改测试夹具之外的用户文件；`verify-local-sources` 前后便携产物哈希一致。

## 附带修复

上一次失败的 `verify-unknown-result` 在切换数据根后遗留了一个 verification 用途的 Host，锁住 `zig-out/portable/cutrans.exe`，导致后续 portable 构建 `AccessDenied`。已用 `stop --mode=portable --purpose=verification --data=...` 正常停止，并把脚本的 `finally` 改为停止当前 `active_data` 根，避免再次遗留进程。

## 边界

- 文件夹按 **标签** 在根下复用，不记录源目录绝对路径；两个同名但不同路径的目录会共用一个逻辑文件夹。成员各自的 external grant 仍保存真实来源路径。
- 只收纳当前选中的单个文件；不是目录整体收纳，也不递归、不流式扫描。
- 文件夹已存在时不会校验它是否来自同一源目录；需要区分时目前只能改名或移动。
- 真实 GUI/IME、安装升级卸载未验收。
