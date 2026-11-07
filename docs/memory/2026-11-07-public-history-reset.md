# 公开历史重置与旧发布撤下（2026-11-07）

用户明确授权force-push，随后确认“备份后删除旧发布和标签”，又明确现有fork不用处理。此授权取代普通仓库整理不擅自改写历史的默认边界；不授权修改或联系fork所有者。

## 已完成的操作

- 固定原验收源码树`6f36c219ba4d495348986bae4992fe9c6874a655`；新无parent根提交`91b019ad`逐字节采用相同tree，不改应用代码、依赖或已验收产物。后续只做本记录和现役说明收尾，不能以其冒充新的GUI／安装验收。
- 核对远端仅一个公开分支及一个旧标签；fetch到本机私有命名空间并核对原OID，再创建allrefs bundle。完整bundle约131MiB，验证通过；旧Release元数据、8MB便携包及校验文件另存用户资料目录中的私有备份，下载包SHA与原校验文件一致。完整备份路径不写入公开源码，实际位置在本机证据的preparation.json中。Git LFS对象盘点为0。
- 使用逐ref精确`--force-with-lease`与`--atomic`，重置`master`并删除`v0.1.0`标签；远端变化时不会自动接受新预期值。随后按明确确认删除该旧Release及其下载入口，不将旧版本标签改指当前新代码，不发布新应用产物。
- 本地切到新master，源文件及索引树保持相同；旧本地分支转存`refs/private/`，私有bundle仍可恢复。普通分支命名空间只保留master，避免未来`push --all`把旧历史带回。没有清空本机对象库、reflog、缓存、运行数据或验收证据。
- 新公开提交作者使用已认证GitHub账号的noreply地址，不继承可能的个人邮箱；没有更改全局Git设置。网络Git直连曾明确报443连接失败，核实系统已有本地代理后，仅本次子进程显式使用它，不统称源码／环境故障。

## 验证与范围

证据根：`scratch/verification/history-reset-50fdee2ade9b/`；此前失败入口日志在仓库整理的验收根保留。原始根提交远端复核、lease／atomic结果、Release删除结果、备份校验均已留证。独立网络克隆最终核对另记verification.json，包括HEAD／父链、公开refs、源码守卫、依赖hash及核心构建；它不使用本地shared/reference对象库。

仓库API显示1个fork、0个PR。已只读确认fork仍是旧状态；用户明确要求不处理，故不修改、不删除、不联系。GitHub缓存、旧SHA链接、fork或其它已有副本不受本次force-push保证；公开分支／标签不可达旧历史不等同服务端物理擦除，参见[GitHub官方说明](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)。

当前树高置信扫描未见真实个人home、部署地址、画像年龄或已知凭据／私钥模式命中；仅余vendor合成测试／公开API示例。此结论不是对所有外部副本的审计，也不构成发现真实凭据泄露后的轮换操作。旧记录的历史Git SHA是文字出处，不会成为新历史的parent。

本次不涉及应用安装升级卸载、系统注册、账号、遥测或用户工作区；旧应用发布已撤下，新版本仍按原计划继续开发和验收。
