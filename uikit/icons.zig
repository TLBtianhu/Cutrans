//! icons.zig — 图标常量:Remix Icon 字形(私有区码位,合并进主字体)
//!
//! 来历:PCL 的图标是矢量 Path 字符串(WPF 几何),我们走图标字体路线——
//! 图标=字符,随字号缩放、随 textColored 染色,洞孔/曲线由字体光栅器正确处理。
//! 字体资产:launcher/assets/fonts/RemixIcons.ttf(19 字形子集,3.8KB),
//! 运行期 merge_mode 并入主字体(ImGui 图标字体标准做法)。
//! 码位表见 scratch/fonts/pick_icons.py(从 remixicon.css 提取)。

/// 启动(三角,实心)
pub const play = "\u{F00A}";
/// 启动·空心(PCL 同款:描边三角)
pub const play_line = "\u{F00B}";
/// 插件(拼图)
pub const puzzle = "\u{F451}";
/// 设置(齿轮)
pub const settings = "\u{F0E6}";
/// 关于(信息)
pub const info = "\u{EE59}";
/// 最小化(减号)
pub const subtract = "\u{F1AF}";
/// 关闭(叉)
pub const close = "\u{EB99}";
/// 用户(头像占位)
pub const user = "\u{F255}";
/// 已装(安装)
pub const install = "\u{EE68}";
/// 仓库(地球)
pub const global = "\u{EDCF}";
/// 模态包(盒子)
pub const box = "\u{F2F5}";
/// 预设(调色板)
pub const palette = "\u{EFC5}";
/// 制式(显示器)
pub const vidicon = "\u{F288}";
/// 设备(CPU)
pub const cpu = "\u{EBF0}";
/// 缓存(数据库)
pub const database = "\u{EC16}";
/// 鸣谢(爱心)
pub const heart = "\u{EE0F}";
/// 许可证(文档)
pub const article = "\u{EA7E}";
/// 搜索(放大镜)
pub const search = "\u{F0D1}";
/// 工程(文件夹)
pub const folder = "\u{ED52}";
/// 新建(文件+)
pub const file_add = "\u{ECC9}";
