# 工程基线、上游对齐与界面材质重构（2026-11-06）

用户授权开始重构，并指定两张参考图标中的深靛蓝、冰蓝到紫色、少量暖金与轻微金属反光方向。此次实现范围为工程基线、NanoUI 对齐和当前两套 UI 的共享材质；Host 自主调度、资源历史版本与真实视频音频仍是后续切片。

## 实现

- 构建拆出测试与 Pack helper，显式传递依赖 target/optimize；保留 Windows x86_64_v2 分发基线。
- 增加不配置桌面、C codec 或 OS Port 的 native `test-core`。非 Windows/core-only 的默认 install 明确拒绝，避免空构建冒充产品支持；Linux/macOS 尚未实机验证。
- 缓存目录组装 Pack，清单使用生成 LazyPath，并登记脚本/能力/schema 输入；输出前缀不再作为源输入。验证输出根支持带空格前缀。
- 源包白名单覆盖源码、资产、脚本和审计资料，排除工具链、恢复二进制及嵌套依赖缓存。
- Zig 0.17.0 compiler/lib 来自同一个固定 SHA-256 归档；从 Git 跟踪移出但保留本机文件。bootstrap 同时验证并恢复 http-zig 归档、规范包哈希与本地源码缓存。
- NanoUI 升至 fork `00e5813` / 0.12.0。官方→fork 32项、fork→Cutrans 8个文件的差异在 VENDOR.json；保留动态纹理、stride、公开 renderer 与关闭隐式 KV，吸收 #71/#72/#75/#76。
- dependencies.lock.json 固定有效源码树，未知的旧上游提交明确为空，以现役快照与树哈希约束，未伪造来源。审计检查 bootstrap 与 NanoUI 的 http-zig 声明一致。
- 两套 UI 共用 palette；暗色基础控件、任务栏、卡片和资源库使用低对比渐变及细高光。常态文案移除内部实现术语，图标参考未被复制为资产。
- 记忆按主题和段落归档，入口由约667KB缩为约5KB；非个人历史保留，移除个人画像并替换公网部署地址。既有 Git 历史未改写。
- 安装验收使用跨进程互斥；清理仅限验证子目录，拒绝重定向/越界，不清理便携 staging 的用户 data。

## 本轮实际验证

- `test-core -Dcore-only=true`：70/70通过；按源包白名单构造的独立副本再次70/70通过。
- `test test-nanoui test-nanoui-library`：1415通过、11平台跳过、0失败（1426总项）；NanoUI本身321通过/11跳过。
- 带空格 `--prefix` 的 portable 构建通过；Runtime/Shell/NanoUI清单由缓存生成。
- 同一前缀下 diag-user、verify-runtime、verify-replay、verify-input、verify-playback、verify-assets、verify-nanoui-library、verify-nanoui-portable均通过。
- 真实 NanoUI D3D readback：900×700 mean=0.0318，非空；动态BGRA/stride/UV mean=0.0447，通过真实Host附着与失败不提交选择检查。
- verify-host：幂等、单实例、保存失败/degraded、异常恢复均通过。沙箱CIM查询受限后仅对隔离测试实例补跑；曾与打包暂存写入碰撞，改为打包结束后单独验收，未放宽哈希断言。
- 安装器在带空格前缀构建通过，静态中文向导/单入口契约通过；互斥实验确认第二探针在任何注册表操作前被拒绝。
- bootstrap四项回归通过：复用、漂移前拒写、路径逃逸拒绝、规范HTTP包哈希不符拒绝。完整真实归档19505项校验通过，现有工具链0项被覆盖。
- 独立源码包约3900文件/68.8MiB，不含工具链、恢复二进制或缓存。依赖审计通过；恢复固定 native 与 HTTP 依赖后，使用经校验的外部工具链完成完整 portable 构建。
- Python AST、记忆入口链接与公开内容脱敏检查通过；暂存diff空白检查通过，收尾提交哈希见Git历史。

## 验收范围

没有截图、真实键鼠自动化、真实窗口视觉/IME手感验收；没有改动保留的真实安装、数据或注册表，没有运行会升级/卸载该真实安装的安装全链，没有创建Release或发布产物。本轮安装证据是编译、静态契约与隔离Runtime/便携验收，不能冒充新一轮真实安装/升级/卸载验收。
