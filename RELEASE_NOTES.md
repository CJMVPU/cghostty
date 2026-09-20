# cghostty 0.1.1

支持 **macOS 27 及以上版本、Apple Silicon（arm64）**。

## 更新内容

- 完成 Swift 6 语言模式迁移，所有原生构建配置启用完整并发检查和 Swift 警告即错误；明确 UI、核心回调、拖放和 App Intents 的并发边界。
- 更新 FreeType、libpng、zlib、Oniguruma、HarfBuzz、gettext/libintl、Highway、simdutf，以及 Dear ImGui / Dear Bindings，同步生成配置和依赖版本记录。
- 清理旧 macOS 兼容层与过期编译分支，完善工具链、版本、Swift 6 和 CI 检查。
- 使用 Metal 4 / MSL 4.1，保留原生 smooth 光标效果；修复 Vim 细线光标及连续移动时的拖尾累积问题。
- 更新应用图标，统一源码、应用和发行包版本为 0.1.1。

## 安装与校验

下载 `cghostty-0.1.1-macos-arm64.zip`，解压后将 `cghostty.app` 放入“应用程序”。

同目录下载 `.sha256` 校验文件后，可执行：

```sh
shasum -a 256 -c cghostty-0.1.1-macos-arm64.zip.sha256
```

此发行包使用 **ad-hoc 签名**，未配置 Developer ID 签名或 Apple 公证。首次打开可能受到 macOS Gatekeeper 限制；确认来源后，可在系统设置的“隐私与安全性”中允许打开。

## 验证记录

- Swift 6 原生单元测试：236 项通过、1 项跳过、0 项失败；参数化展开后 355 次执行通过。
- C/C++ 更新后的默认 Zig 定向回归：1,645 项通过；另外验证了 FreeType 和 HarfBuzz 字体后端。
- ReleaseLocal 构建与独立运行检查通过，覆盖中文输入、核心后台标题更新、AppleScript、标签和分屏。
- 完整历史和验证边界见仓库中的 `VALIDATION.md`。上述功能测试对应本次打包前已提交的代码基线；0.1.1 发布仅调整版本和打包流程。
