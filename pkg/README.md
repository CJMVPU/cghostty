# C/C++ 依赖维护

本项目的构建适配器位于各包的 `build.zig`。源码 URL 和 Zig 内容哈希锁定在对应的 `build.zig.zon`，以下版本于 2026-09-20 核实并更新。

| 包 | 源码版本 | 上游 |
| --- | --- | --- |
| FreeType | 2.14.3 | https://freetype.org/ |
| libpng | 1.6.58 | https://github.com/pnggroup/libpng |
| zlib | 1.3.2 | https://github.com/madler/zlib |
| Oniguruma | 6.9.10 | https://github.com/kkos/oniguruma |
| HarfBuzz | 14.4.0 | https://github.com/harfbuzz/harfbuzz |
| GNU gettext / libintl | 1.0 | https://www.gnu.org/software/gettext/ |
| Highway | 1.4.0 | https://github.com/google/highway |
| simdutf | 9.2.0 | https://github.com/simdutf/simdutf |
| Dear ImGui / Dear Bindings | 1.92.9b-docking / 0.21 | https://github.com/dearimgui/dear_bindings |

`dcimgui` 的包版本用 `1.92.9+b` 表示上游 hotfix，以符合 Zig 的 SemVer 语法；ImGui 源码和生成绑定必须使用同一个 `1.92.9b-docking` 版本。`ImGui_OpenPopup` 现在返回 bool，调用方显式丢弃无需使用的返回值。

Oniguruma 6.9.10 是原上游的最终版本，上游已归档。本次保留现有正则引擎及调用接口；引擎替换需要单独验证正则语法和匹配行为。

Wuffs 保留原有提交快照，内含 `0.4.0-alpha.10+3966.20260623` 的生成 C 源码；图片测试素材依赖也保持原来的内容哈希。

## 生成文件

- `libpng/pnglibconf.h` 直接来自 libpng 1.6.58 的 `scripts/pnglibconf.h.prebuilt`，保持现有构建脚本的 SIMD 开关。
- `simdutf/vendor/simdutf.h` 与 `simdutf.cpp` 直接取自 [v9.2.0 官方 singleheader.zip](https://github.com/simdutf/simdutf/releases/download/v9.2.0/singleheader.zip)，未手工修改。归档 SHA-256：`c291c8a698e638ba40e0eae4c6da97a6caa6b96a7abaabfcf2b4b4fe1a85aa43`。
- `libintl` 的配置和生成头针对 macOS 27 / arm64，重新生成步骤见 [libintl/README.md](libintl/README.md)。

更新后运行 `python3 scripts/check-versions.py`。除了默认构建，还应验证 `coretext_freetype`、`coretext_harfbuzz` 可选字体后端的 font 测试；它们使用 HarfBuzz，默认 CoreText 后端不使用。

## License

**This license only applies to the contents of the `pkg` folder within
the Ghostty project. This license does not apply to the rest of the
Ghostty project.**

Copyright © 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the “Software”), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
