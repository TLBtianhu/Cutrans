# 测试素材与依赖来源

## `pngtest.png`

- 来源：libpng 官方仓库 `pnggroup/libpng` 的 `pngtest.png`
- 下载地址：https://raw.githubusercontent.com/pnggroup/libpng/master/pngtest.png
- 尺寸：91×69，RGBA
- 字节数：8831
- SHA-256：`b7a468324556bf6924058acb0fb477320355da0d864728e614be83ffa6966148`
- 许可证：PNG Reference Library License version 2，见本目录 `libpng-LICENSE.txt`

## stb_image / stb_image_write

- 来源：`nothings/stb`
- `stb_image.h`：v2.30，来自上游 master
- `imstb_image_write.h`：v1.13，来自旧 vendored zgui 的 ImGui test engine；旧 UI 已移除，仅保留该独立 PNG 编码头文件
- 许可证：MIT 或 Public Domain，任选其一；见 `third_party/stb/LICENSE`

## `replay.cvr`

- 来源：本项目自生成的语义回放日志，不依赖外部素材。
- 内容：逻辑时间、文档命令、预期结果和 VNE 输出路径，用于跨实例确定性对账。
- SHA-256：`d75f36bcb8bc120afe69c4b7f9f41d7ab763fe66c29cd0a9069f461831aec157`

## `input.cvr`

- 来源：本项目自生成的语义输入回放日志，不包含真实鼠标、键盘或窗口系统事件。
- 内容：逻辑时间、指针位置、语义按键、文本和焦点事件，用于无头设备对账。
- SHA-256：`d9240f7b7698a5c30c2dbbd0d33e1ba17498d3965e4492f8dfcb5384f23a1702`
