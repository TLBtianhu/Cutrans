# 字体资产

## NotoSansSC.ttf(编译期内嵌进 exe,`@embedFile`)

- **来源**:Noto Sans SC(Google Fonts,`fonts.gstatic.com` v41 直链),原版 10.5MB/30890 字形存档于 `scratch/fonts/NotoSansSC-full.ttf`
- **许可证**:SIL OFL 1.1(见 `OFL.txt`)——允许内嵌/子集化/再分发;**微软雅黑不可再分发**,严禁打包进任何发布物
- **子集化**(7544 字符,2.2MB):GB2312 全字符集 + ASCII + 项目 UI 用到的图形符号(◉◆▣ 等)

## RemixIcons.ttf(图标字体,运行期 merge_mode 并入主字体)

- **来源**:Remix Icon v4.9.1(remixicon.com),许可证 Remix Icon License 1.0(见 `RemixIcons-LICENSE.txt`,免费可商用)
- **子集**:19 字形/3.8KB,PUA 私有区码位(U+EA7E..F451),选码脚本=`scratch/fonts/pick_icons.py`(从 remixicon.css 按名提取),原版存档 `scratch/fonts/remixicon.ttf`
- **常量表**:`launcher/uikit/icons.zig`(语义名→字形)
- **PCL 对照**:PCL 图标=WPF 矢量 Path 字符串;我们走图标字体——图标=字符,随字号缩放/染色,洞孔曲线由光栅器正确处理,搭字体内嵌管线零新代码
- **注意**:若改离线合并(fontTools.merge)需先 `scale_upem` 对齐 1000(Remix 原生 1200),且 merge 对异构表有断言——所以选了运行期合并

## 渲染栈

stb_truetype(ImGui 自带,CPU 光栅化→GPU 图谱纹理,1.92 按需生长),全程不碰 DirectWrite/GDI。

## 再生成(改字符集/图标时)

```bash
uv run --with fonttools python -m fontTools.subset scratch/fonts/NotoSansSC-full.ttf \
  --text-file=charset.txt --output-file=NotoSansSC.ttf \
  --name-IDs=0,1,2,4,13,14 --name-legacy --name-languages='*' --layout-features=''
# 图标改选:编辑 scratch/fonts/pick_icons.py 的名字表 → 跑一遍拿码位 →
python -m fontTools.subset scratch/fonts/remixicon.ttf --unicodes="U+XXXX,…" --output-file=RemixIcons.ttf
```

