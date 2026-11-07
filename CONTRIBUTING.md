# 参与开发

先阅读 [README](README.md)、[文档导航](docs/README.md) 与 [现役状态](docs/memory/current.md)。历史提案和旧验收不代表当前功能。

- VM持有文档、资源、授权与任务的权威状态；Shell及App持有投影和交互状态。
- 改功能时保留明确的接受、执行、提交与失败语义；涉及持久化时覆盖真实文件失败，涉及ABI时同时更新Host、Shell与实际产物验证。
- 上游修改先区分官方、fork及Cutrans本地补丁，核对许可证和有效源码hash，再显式更新锁；包版本号相同不意味着源码相同。
- 运行数据、凭据、构建缓存及验收案例不提交。第三方许可证与来源记录随源保留；已锁定SDK的两份`.so`为明确保留项。
- 开发命令使用[构建指南](docs/development/building.md)中的隐藏入口。不要把源码测试通过当作真实GUI、安装升级卸载或发布通过。
- 提交前运行`tools/dev.ps1 verify-repository`和与改动相称的构建／产物验证，并在项目记忆中记录结果、限制及证据位置。

源码目录及本机生成内容的归属见[仓库布局](docs/development/repository-layout.md)。GitHub提交不包含`tools/zig/`、`zig-out/`、`.zig-cache/`、`zig-pkg/`或`scratch/`；它们在本机出现不等于已经上传。
