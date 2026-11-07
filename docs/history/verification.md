# 历史验证输出

本页保存从旧README迁出的日志标记，避免将历史安装或旧字段当成当前能力。它不是本轮测试执行清单，也不保证当前产物逐行复现。现役结论应附实际产物hash、命令、退出码与对应证据目录。

```text
CUTRANS_PACK capabilities=7 files=4 native=1
CUTRANS_DIAG_OK mode=portable evaluations=4 nodes=3 png=182x138 capabilities=7/7 audit=ok pack=ok tasks=4 recovered=1 history=6
CUTRANS_RUNTIME_OK abi=windows-x64 capabilities=7 files=10 mode=portable fingerprint=<由文档决定>
CUTRANS_RUNTIME_VERIFY_OK portable=1 absolute_open=1 tamper_rejected=1 wgpu_free=1
CUTRANS_RUNTIME_LOCK_OK migrate=1 reject_drift=1 rollback=1
CUTRANS_INPUT_REPLAY_OK kind=1 events=5 time_ns=5000000
CUTRANS_INPUT_NEGATIVE_OK time_travel=1
CUTRANS_INPUT_ACTION_OK insert=1 undo=1 redo=1 suppressed=1
CUTRANS_INPUT_BRIDGE_OK events=50 replay=1 version=3 os_injection=0
CUTRANS_PLAYBACK_OK frames=4 offers=4 underflow=0 restart_stop=1 os_injection=0
CUTRANS_REPLAY_VERIFY_OK instances=2 state=identical png=identical
CUTRANS_FRAME_PRESENT_OK generation=1 content=<文档指纹> feedback=submitted
CUTRANS_SHELL_START_OK dynamic_vm=1 editor_open=1 frame_submit=1 visual_acceptance=not_run
CUTRANS_SHELL_PLAYBACK_OK t=3 frame_submit=1 visual_acceptance=not_run
CUTRANS_SHELL_LOCK_OK runtime=1 shell=1 host_path=0
CUTRANS_INSTALLED_INPUT_RECORD_OK events=50 replay=1
CUTRANS_INSTALLED_PLAYBACK_OK frames=4 offers=4 underflow=0
CUTRANS_EXTERNAL_REFERENCE_OK direct=1 restart=1 version=1 missing=1 corrupt_catalog=1
CUTRANS_LIBRARY_OK reference=1 detach=1 id_preserved=1 restore=1 create=1 tamper_rejected=1 corrupt_catalog=1
CUTRANS_ASSET_SOURCE_OK external=1 snapshot=1 export=1 restart=1 missing=1 mismatch=1
CUTRANS_ASSET_WORKSPACE_OK open=1 reuse=1 export=1 restore=1 tamper_rejected=1 insert=1 history=1 source_restart=1
CUTRANS_SHELL_ASSETS_VERIFY_OK selected=1 preview=1 inserted=1 visual_acceptance=not_run
CUTRANS_INSTALLED_ASSETS_OK snapshot=1 tamper_rejected=1
CUTRANS_INSTALLED_ASSET_SHELL_OK selected=1 preview=1 inserted=1 visual_acceptance=not_run
CUTRANS_INSTALL_VERIFY_OK preflight=1 install=1 open=2 update=1 uninstall=1 association_guard=1
```

旧NanoUI／D3D验证说明：

界面支持虚拟目录树、原生 PNG 导入、完整预览、显式刷新、独立化、移动、新建文件夹和中文重命名；长名称中间省略，Catalog 保存完整值。`verify-nanoui-library` 用真实 Host 和 NanoUI Tester 验证这些动作、失败不改锁和 900×700 重排；`verify-nanoui-portable` 在隔离便携副本中核对默认数据解析与 Pack 纯净。旧 `verify-installer-headless` 的真实安装态记录属于历史；该目标当前默认拒绝系统注册，也不再表示已运行 NanoUI 安装探针。历史 D3D11 离屏 readback 为 `CUTRANS_NANOUI_D3D_OK size=900x700 mean=0.0085 nonblank=1`，动态纹理标记为 `CUTRANS_NANOUI_DYNAMIC_OK bgra=1 stride=1 uv=1`。这不是零拷贝 GPU 互操作或完整媒体管线；删除/批量操作、正式媒体帧接线和完整桌面迁移仍未实现，离屏验收也不替代真实窗口视觉与手感验收。

源码测试、便携产物、安装器提取预检和独立OS用户／VM中的完整安装验收分别成立。最新状态从[现役记忆](../memory/current.md)进入，[环境隔离](../environment-isolation.md)说明当前登记测试门禁。
