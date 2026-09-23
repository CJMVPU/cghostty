# C/C++ 依赖维护

本项目的构建适配器位于各包的 `build.zig`。源码 URL 和 Zig 内容哈希锁定在对应的 `build.zig.zon`。下表从这些构建清单生成，记录当前锁定的源码，不代表上游最新版本。

<!-- dependency-versions:start -->

| 包 | 锁定源码版本 | 源码记录 |
| --- | --- | --- |
| FreeType | 2.14.3 | [源码归档](https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz) |
| libpng | 1.6.58 | [源码归档](https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.58.tar.gz) |
| zlib | 1.3.2 | [源码归档](https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz) |
| PCRE2 | 10.48 | [源码归档](https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.gz) |
| HarfBuzz | 14.4.0 | [源码归档](https://github.com/harfbuzz/harfbuzz/releases/download/14.4.0/harfbuzz-14.4.0.tar.xz) |
| GNU gettext / libintl | 1.0 | [源码归档](https://ftp.gnu.org/pub/gnu/gettext/gettext-1.0.tar.gz) |
| Highway | 1.4.0 | [源码归档](https://github.com/google/highway/releases/download/1.4.0/highway-1.4.0.tar.gz) |
| simdutf | 9.2.0 | [内置源码](simdutf/vendor/simdutf.h) |
| Dear ImGui | 1.92.9b-docking | [源码归档](https://github.com/ocornut/imgui/archive/refs/tags/v1.92.9b-docking.tar.gz) |
| Dear Bindings | 0.21（ImGui 1.92.9b-docking） | [生成绑定](https://github.com/dearimgui/dear_bindings/releases/download/DearBindings_v0.21_ImGui_v1.92.9b-docking/DearBindings_v0.21_ImGui_v1.92.9b-docking.zip) |
| Wuffs | 提交 `7411f488fe2e2c205c3d3b3d28638b7356522930` | [源码快照](https://deps.files.ghostty.org/wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz) |

<!-- dependency-versions:end -->

修改依赖清单及对应生成文件后，运行 `python3 scripts/check-versions.py --update-docs` 更新此表；CI 的默认检查会拒绝版本表漂移。版本号继续以构建清单为准，不维护额外的版本数据库。

`dcimgui` 的包版本通过 SemVer build metadata 表示上游 hotfix（例如 `1.92.9+b` 对应 `1.92.9b-docking`）。检查脚本要求 ImGui 源码与生成绑定所针对的 ImGui 版本一致，并核对绑定的发布标签与归档文件名。

## 维护状态与生成文件

默认字体为内置 LXGW WenKai Mono 1.522 Medium，使用 `build.zig.zon` 锁定的官方归档及内容哈希；OFL 许可随应用分发。Medium 文件 SHA-256 为 `7a674f448b15a1b3df781c3498973d77f71d270788f7f921080c1344e9d739e1`，与用户提供的文件完全一致。粗体与斜体遵循运行时合成设置。Nerd Font 符号保留为图标后备；JetBrains Mono 仅用于字体后端测试。

版本一致性检查不判断上游维护活跃度，也不替代安全审计。

PCRE2 负责链接与路径识别，复用上游 Zig 构建，仅编译 8 位 UTF-8 静态库，关闭 JIT。渲染高亮与点击定位共用匹配预算；封装测试运行方式和升级要点见 [pcre2/README.md](pcre2/README.md)。tmux 控制消息直接按协议字段解析，不依赖正则库。

Wuffs 使用提交快照，包清单中的 `0.0.0` 是适配器占位版本，因此表中记录源码提交。图片测试素材依赖单独锁定在同一清单中。

- `libpng/pnglibconf.h` 来自所锁定 libpng 源码的 `scripts/pnglibconf.h.prebuilt`，保持现有构建脚本的 SIMD 开关。
- `simdutf/vendor/simdutf.h` 与 `simdutf.cpp` 取自对应版本的官方 `singleheader.zip`，未手工修改。当前归档 SHA-256：`c291c8a698e638ba40e0eae4c6da97a6caa6b96a7abaabfcf2b4b4fe1a85aa43`；更新源码时同步记录新归档校验和。
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
