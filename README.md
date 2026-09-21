# cghostty

基于 [Ghostty] 独立维护的 macOS 终端。
仅支持 **macOS 27+ 和 Apple Silicon**。

## 功能

- Swift 原生界面，支持窗口、标签页、分屏和快速终端
- Zig 终端核心、Metal 4 渲染和 CoreText 字体
- 内置平滑光标，支持方块、细线和下划线
- 支持终端搜索、主题、shell 集成和 AppleScript
- 使用独立配置目录；检查更新时打开本仓库 Releases

## 安装

在 [Releases] 下载 `cghostty-<版本>-macos-arm64.zip`
解压后，将 `cghostty.app` 拖入“应用程序”

本地打包默认采用 ad-hoc 签名，未经 Apple 公证。
签名和公证方法见 [PACKAGING.md]。

## 配置

平滑光标默认开启：

```ini
cursor-effect = smooth
window-vsync = true
```

`GhosttyKit.xcframework` 仅供应用内部桥接
保留 `TERM=xterm-ghostty` 及必要的协议兼容名称

架构见 [ARCHITECTURE.md]<br>
开发与测试见 [HACKING.md]<br>
交付范围见 [SCOPE.md]<br>
验证记录见 [VALIDATION.md<br>]
基于 [MIT 许可](LICENSE)，保留上游版权声明

[Ghostty]: https://github.com/ghostty-org/ghostty
[Releases]: https://github.com/CJMVPU/cghostty/releases
[PACKAGING.md]: PACKAGING.md
[ARCHITECTURE.md]: ARCHITECTURE.md
[HACKING.md]: HACKING.md
[SCOPE.md]: SCOPE.md
[VALIDATION.md]: VALIDATION.md
