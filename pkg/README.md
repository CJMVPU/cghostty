# C/C++ 依赖维护

本项目的构建适配器位于各包的 `build.zig`。源码 URL 和 Zig 内容哈希锁定在对应的 `build.zig.zon`。下表从这些构建清单生成，记录当前锁定的源码，不代表上游最新版本。

<!-- dependency-versions:start -->

| 包 | 锁定源码版本 | 源码记录 |
| --- | --- | --- |
| PCRE2 | 10.48 | [源码归档](https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.gz) |
| Highway | 1.4.0 | [源码归档](https://github.com/google/highway/releases/download/1.4.0/highway-1.4.0.tar.gz) |
| simdutf | 9.2.0 | [内置源码](simdutf/vendor/simdutf.h) |
| Wuffs | 提交 `7411f488fe2e2c205c3d3b3d28638b7356522930` | [源码快照](https://deps.files.ghostty.org/wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz) |

<!-- dependency-versions:end -->

修改依赖清单及对应生成文件后，运行 `python3 scripts/check-versions.py --update-docs` 更新此表；CI 的默认检查会拒绝版本表漂移。版本号继续以构建清单为准，不维护额外的版本数据库。


## 维护状态与生成文件

默认字体作为 Resources 文件随应用分发，为 LXGW WenKai Mono 1.522 Medium，使用 `build.zig.zon` 锁定的官方归档及内容哈希；OFL 许可随应用分发。Medium 文件 SHA-256 为 `7a674f448b15a1b3df781c3498973d77f71d270788f7f921080c1344e9d739e1`，与用户提供的文件完全一致。粗体与斜体遵循运行时合成设置。Nerd Font 符号保留为图标后备；JetBrains Mono 仅用于字体测试。

版本一致性检查不判断上游维护活跃度，也不替代安全审计。

PCRE2 负责链接与路径识别，复用上游 Zig 构建，仅编译 8 位 UTF-8 静态库，关闭 JIT。渲染高亮与点击定位共用匹配预算；封装测试运行方式和升级要点见 [pcre2/README.md](pcre2/README.md)。tmux 控制消息直接按协议字段解析，不依赖正则库。

Wuffs 使用提交快照，包清单中的 `0.0.0` 是适配器占位版本，因此表中记录源码提交。图片测试素材依赖单独锁定在同一清单中。

- `simdutf/vendor/simdutf.h` 与 `simdutf.cpp` 取自对应版本的官方 `singleheader.zip`，未手工修改。当前归档 SHA-256：`c291c8a698e638ba40e0eae4c6da97a6caa6b96a7abaabfcf2b4b4fe1a85aa43`；更新源码时同步记录新归档校验和。

更新后运行 `python3 scripts/check-versions.py`。终端字体仅支持 CoreText，运行 font 测试验证字体加载、合成样式及整形。Inspector 及 Dear ImGui / Dear Bindings / FreeType / libpng / 独立 zlib 构建依赖已移除。PNG 与压缩图片能力分别由 Wuffs 和 Zig 标准库提供。

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
