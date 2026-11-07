//! 跨应用共享资产的字节入口(路径只在资产模块内部出现)

pub const noto_sans_sc = @embedFile("fonts/NotoSansSC.ttf");
pub const remix_icons = @embedFile("fonts/RemixIcons.ttf");
pub const zh_cn = @embedFile("locales/zh-CN.json");
pub const minimal_cut = @embedFile("examples/minimal.cut");
pub const replay_log = @embedFile("examples/replay.cvr");
pub const input_replay_log = @embedFile("examples/input.cvr");
