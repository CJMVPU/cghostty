# libintl 生成配置

本包使用 GNU gettext 1.0 的 runtime，配置头在 Apple Silicon macOS 27 / Xcode 27 上生成。应用仍静态链接 runtime，翻译工具由本机构建环境提供。

升级时，从 `build.zig.zon` 指定的官方归档取得源码，在独立构建目录运行：

```sh
/path/to/gettext-1.0/gettext-runtime/intl/configure \
  --disable-shared --enable-static --disable-dependency-tracking
make -o Makefile -o config.status libintl.h libgnuintl.h
make -C gnulib-lib -o Makefile -o ../config.status string.h
```

`-o` 保留 configure 刚生成的 Makefile 与 config.status，避免 Zig 包缓存归一化时间戳导致不必要的 Autotools 再生成。

将生成的 `config.h`、`libintl.h`、`libgnuintl.h` 拷入本目录，`gnulib-lib/string.h` 拷入 `gnulib/string.h`。保留 `config.h` 尾部标注 `ADDED FOR GHOSTTY` 的 `<xlocale.h>` 兼容块，以便所有 gnulib 源文件可见 `locale_t` 和 LC_* 常量。

gettext 1.0 的 locale 实现使用 gnulib 的 `streq`。构建时必须同时包含生成的字符串头和上游 `gnulib-lib/string.c` 的非内联定义，否则 Debug 链接会出现未定义符号。不要只更新源码版本或配置中的版本字符串。

`scripts/check-versions.py` 会核对配置和两个公开头文件的版本。生成结果不可混用其他系统或架构的配置；修改后需要完成 Debug 测试和 ReleaseLocal 应用链接验证。
