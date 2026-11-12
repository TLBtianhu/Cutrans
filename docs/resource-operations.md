# 资源重新定位与采用（C2b）

资源库是素材声明的真源，Station是当前活动对象，文档与Job持有指定内容版本。改变外部文件位置或库的当前版本，不应重写已有作品或活动对象。

当前Resource API v4由ABI10的ShellApi getter、Runtime导出和Host RPC 26～32提供（v1最初在ABI9引入，v2增加通用登记，v3增加工作正文，v4增加本机只读浏览）。`shell/library_client.zig`保存完整候选、未确认请求与目录投影，并支持普通文件登记；完整候选恢复向导仍未接入，没有自动同步、版本列表或垃圾回收。

## 两种明确意图

- `relocate`：给引用型库项重新选择文件，SHA-256必须与原head相同；稳定ID、拥有方式与内容版本不变。
- `adopt`：给引用型库项明确采用所选文件的内容；稳定ID不变，只改变库head和来源绑定。新插入使用新版本，已有文档、History、Job仍使用原hash。owned资源拒绝这两种操作。

候选须是绝对路径的普通PNG，当前编码预算16MiB、解码RGBA预算64MiB。头部预算检查先于真实解码；文件身份和字节从同一稳定打开句柄读取。Windows读取期间阻止普通写入／删除打开；这不承诺抵抗已有可写内存映射。

## 版本与重试

资源stamp由当前Runtime随机epoch与库revision组成，独立于文档版本。成功实际库变更前进一次，包括旧rename／move／refresh／detach／import／create／folder操作；普通无操作不前进。目录恢复视作一次独立发布，即使声明相同也推进revision，并使Station归属投影失效。失败、ID或revision耗尽不发布；恢复旧目录不能倒退同Runtime发号高水位。Runtime重建更换epoch，不跨进程保存回执。

`snapshot`先查询长度，再携原stamp读取一份目录JSON，含folders、resources、名称、hash和来源URI；不包含物理宿主路径或授权观察日志。短buffer不写正文，版本变化拒绝读。客户端完整解析到临时owned投影后才换入。

`probe`返回无状态proof，绑定库stamp、目标ID、模式、原head、候选hash、规范路径hash、长度与真实文件身份。probe不写授权、版本、观察记录或Station。proof只是前置条件，不是插件权限凭证；`submit`重新读取同一路径，并核对完整proof后才可能提交。

提交带独立client身份与连续sequence。VM先查询回执，再检查当前版本和候选文件；原候选已经删除或后续head已变化，仍可重放原已知结果。同token不同参数拒绝；最近64回执之外的旧token过期后拒绝重做，持久客户端高水位保证已被环形覆盖的sequence不会再次执行。客户端预算4096，执行前预留回执存储。文档与资源共享发号／回执机制，业务版本、授权与操作策略仍各自独立。

非零传输结果表示未知，Shell保留原proof、路径、token和sequence，只重试原请求。已知结果与随后投影刷新失败分别记录；旧epoch或回执过期不能证明旧操作从未执行，需核对现状，再由新的明确意图发起请求。未知请求不自动换token、改stamp或重选路径。

## 持久化和失败

采用先写`library/versions/<id>/<sha>.bin`不可变字节，再持久化新授权绑定，最后原子提交库catalog。旧grant不会因为同路径上的新物理文件而被改写；新文件采用新绑定，冷恢复允许同路径多个历史绑定。旧v1授权仍遵循独立显式确认规则。

版本或授权失败不发布库head；catalog失败会回退内存head和revision。前面已经持久化的不可变版本或未引用授权可能留下，作为可重试依赖保留，不宣称多个文件之间具备原子事务。当前授权仍有8项预算，不能按当前head自动回收旧授权。

新create／detach也使用不可变版本，失败不删除或覆盖已有content文件；owned读优先使用该hash的version，只有缺失才兼容旧`library/content/<id>.bin`，坏版本不得靠旧文件掩盖。

实际验证使用`tools/verify_resource_operations.py`对分发DLL和真实隔离Host执行丢回复、候选替换、锁定持久文件、旧版本消费者与冷恢复等负例。测试数据与失败证据保留在认领的verification根；本片不进行真实GUI／IME、系统登记、安装、卸载或发布验收。

## 已加载资源与来源核对（C2c1）

`asset.ensure <id> <64位SHA-256>`取得已登记资源的精确当前head。命中已有完整Station字节时直接返回同对象，不回源、不递增lease或资产revision；未命中才严格读取并建立一次Station根引用。预期head已经变化则拒绝，不能选择同ID的任意旧版本。重复请求不积累远端租约；lease归零仍释放，本片没有实现LRU。

`asset.check <handle>`只观察指定已加载的库资源。来源一致、缺失、内容变化、文件身份变化、旧授权未确认、暂不可读和已被其它head取代分别记录。状态绑定被核对的来源，独立化／重新绑定后旧观察作废；逻辑改名或移动不改变来源观察的适用性。界面显示“上次核对”，不假装实时监听。

核对不会改catalog head、授权观察记录、Document、History、Job或原始RAM字节。未加载handle拒绝，不通过检查隐式加载。当前检查仍在同步owner执行，只是限定对象的观察入口，不是全局F5、异步刷新或自动新代际采用；原`library.refresh`保持显式更新素材声明的语义。

`library.detach`优先从当前head匹配的完整Station原始字节发布独立内容，原件失联不再阻断该路径。只有旧head驻留时不能拿它倒退当前资源；没有匹配时仍可走既有严格来源读取。不可变版本损坏仍会拒绝，不能用RAM静默覆盖修复。成功保留ID、显示名、父级和原来历；失败保持原归属及Station。

ABI10的Asset列表增加实际内容hash和来源观察状态，两套资源UI用公共helper精确选择head，并在新预览构建成功后替换旧预览。已有严格`asset.open`／`openVersion`／`source_read`不因RAM命中而跳过持久版本完整性检查。真实DLL／Host验证入口为`tools/verify_resident_resources.py`；真实GUI、完整恢复向导、通用文件／目录和强制沙箱仍是后续能力。可变owned工作正文见下文v3切片。

## 通用文件登记与App交付（C2c2）

Resource API v2保持原结构布局及RPC编号，拒绝v1请求／响应；Host ABI仍为10。新`register_file=3`使用`target_id=0`及全零`head_hash`，proof记录实际文件身份、字节hash、长度与候选路径。probe无授权／目录副作用；submit在回执和CAS检查后重新读取并核对候选，成功Outcome返回实际分配或复用的非零资源ID。相同token丢回复重试先返回原回执，不再次读取文件或创建资源。新意图重新probe；不能把旧请求换token后冒充原操作重试。

本片支持绝对路径普通文件，完整字节上限16MiB；TXT、PNG、未知格式和空文件均可登记，不自动成为图片。登记默认reference且只读，不默认复制媒体或留存版本；未驻留且原件失联时不能凭登记恢复内容。相同已验证来源及hash复用已有资源，来源内容漂移拒绝，不静默更新head。旧relocate／adopt仍保留PNG候选政策，未借此放宽为通用格式切换。

新来源口岸读取同一打开对象的字节、身份及最终路径；拒绝当前data／resource根及可识别Runtime／程序托管根、路径别名和多硬链接对象。冷恢复后的新通用读取仍核对已验证持久只读grant、mount locator及来源边界，不写授权last_hash。旧授权及旧作品保留兼容路径，不自动迁移；本规则不是强制约束不可信同进程代码的OS沙箱。

这也是入口级约束，旧外部URI与mount兼容读写路径尚未全部迁入新的口岸，不能称为VM全局IO中介。实际符号链接负例因Win32创建权限1314未覆盖；真实目录联接及硬链验证通过，完整证据见[C2c2实施记录](memory/2026-11-07-resource-registration.md)。

`resource.acquire <id> <sha256>`先核对当前head，再复用完整RAM或执行通用只读加载。成功为accepted，调用方从asset列表按ID＋hash取handle，不能把命令的Job输出当handle。`shell.resource_delivery`将资源Ref与借用字节交给消费callback；支持格式由App决定，回调拒绝保留资源身份与驻留内容，交付可单独重试。登记回执与交付结果各自呈现，不以交付失败删除已登记资源。完整GUI拖放、跨进程App调度和目录交付继续后续。


## 工作正文、草稿与固定版本（Resource API v3）

v3在原Resource API尾部增加`work_snapshot`与`work_submit`，主Shell ABI仍为10，原登记／重定位／采用请求布局及RPC编号不变。新增工作快照RPC29、工作提交RPC30；线格式显式编码结构版本、长度和正文，不跨进程传递指针。旧v1／v2 Resource API客户端须显式升级，不能按相同包版本猜测表长。

工作操作包括`create`、`save_draft`、`commit`和`discard`。`create`建立owned资源及工作revision 1；`save_draft`只保存草稿，不推进工作revision，也不替换正式Station输入；`commit`核对draft token和`base_revision`后推进一次工作revision并清除对应草稿元数据；`discard`只丢弃指定token。草稿token全局单调且不复用。`base_revision`在保存和提交两处都必须是当前工作revision：落后客户端的草稿保存直接返回过期版本，不会写入一份提交时必然被拒的草稿；冲突保留旧草稿而不覆盖。

正文分别发布到`library/work/<id>/<revision>-<sha256>.bin`和`library/drafts/<id>/<token>-<sha256>.bin`。文件名带内容哈希，因此"Catalog 提交失败留下的未引用正文"不会与同一 revision 的重试（字节不同）冲突；旧数据根的`<revision>.bin`只读兼容仍可打开，新发布不再生成该名字。完整字节写入并同步后才原子提交Catalog v4；目录、草稿元数据、成功回执与客户端高水位在同一Catalog提交生效。未引用候选不猜作垃圾自动删除，也不宣称文件与目录构成跨文件原子事务。当前正文和草稿单份上限16MiB，NanoUI文本编辑另限1MiB有效UTF-8且无NUL；其它二进制仍按素材处理。

`work_snapshot`优先返回已持久草稿，否则返回当前工作正文，携工作revision、编辑base、draft token、来源类型和双向hash。两次读取必须属于同一快照，否则拒绝拼接。`readVersion`与Document／History／Job继续按原hash读取已采用固定版本，工作头前进不会重写旧输入；未被采用且未留存的旧工作字节不承诺永久恢复。

成功工作回执与Catalog一起持久化，最近64条为环形覆盖，达到上限不再拒绝新工作；每个client的已确认高水位另行持久化，旧sequence按过期拒绝而不是重新执行。原client＋sequence先查回执再检查当前revision，跨Runtime重放不重复创建或提交；失败与拒绝回执只保留当前Runtime的既有有界请求簿语义，不宣称所有错误均跨重启恢复。Shell编辑队列仍不自动跨重启重放，重新打开先恢复已确认草稿，不盲目提交。

NanoUI资源库可新建工作正文，自动保存草稿，Ctrl+S／“保存正文”提交。编辑同时只发一个待确认请求，后续输入留在UI；旧快照不覆盖脏正文，导航和窗口关闭会阻止丢失未确认输入。输入预检、组合输入事务和有界撤销在项目适配层实现，未修改NanoUI vendor。真实中文输入法、系统剪贴板、可见窗口手感和完整安装验收仍需单独进行。

实际入口为`tools/verify_work_documents.py`（真实DLL／Host、旧导出、丢回复、冷恢复）和`tools/verify_nanoui_library.py`（真实前端草稿／提交／关闭保护）。普通工作文件与作品固定版本已分离，但共享异步求值、完整FrameLease、通用目录、完整恢复向导、跨文件通用事务和垃圾回收仍未完成。


## 本机文件只读浏览与显式登记（Resource API v4）

v4尾部增加`source_browse`和`source_read`，主Shell ABI仍为10。新增RPC31浏览当前目录一层，RPC32读取明确的普通文件；旧RPC25的固定版本Source读取不变。路径与游标采用无指针线格式，Runtime负责路径、来源边界、文件身份和完整字节检查。

`runtime/local_sources.zig`的目录结果只是临时观察，不是ResourceId、固定内容版本或永久授权。当前目录最多4096项、每页128项，目录优先并按名称排序；成员重解析点跳过，不递归建立资源。浏览不创建Catalog、授权、留存版本或Station lease。当前游标只服务本次排序结果，目录变化后不承诺定位同一对象，也不是稳定Catalog游标。

文件临时读取上限16MiB，文本预览限1MiB有效UTF-8且无NUL，UI最多显示前64KiB；PNG使用现有图片通路。未知格式可明确不支持预览但仍登记。预览不冒充固定版本，目录整体收纳和完整目录独立化未实现。

NanoUI“本机文件”页面支持目录选择、绝对路径、嵌套进入、返回、刷新、分页和临时预览。只有用户显式“收录到资源库”才走既有`register_file`，默认只读引用；登记成功但预览未建立时保留资源，不回滚登记。插入文档仍由既有资源库动作单独执行。

实际验证入口为`tools/verify_local_sources.py`，覆盖真实DLL／Host的浏览、读取、隔离根、冷恢复和原生无头页面，详见[本机文件实施记录](memory/2026-11-08-local-file-sources.md)。同步owner枚举、流式超大目录、目录成员持久收纳关系、工程目录完整性、统一预算和完整原生互通仍需后续切片。
