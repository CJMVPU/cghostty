# cghostty

基于 [Ghostty] 独立维护的 macOS 终端。
仅支持 **macOS 27+ 和 Apple Silicon（arm64）**。

## 功能

- Swift 原生界面，支持窗口、标签页、分屏和快速终端。
- Zig 终端核心、Metal 4 渲染和 CoreText 字体。
- 内置平滑光标，支持方块、细线和下划线。
- 支持终端搜索、主题、shell 集成和 AppleScript。
- 使用独立配置目录；检查更新时打开本仓库 Releases。

不提供 Intel Mac 或其他平台版本。
不包含自动更新、崩溃上传或外部着色器加载。

## 安装

在 [Releases] 下载 `cghostty-<版本>-macos-arm64.zip`。
解压后，将 `cghostty.app` 拖入“应用程序”。

本地打包默认采用 ad-hoc 签名，未经 Apple 公证。
签名和公证方法见 [PACKAGING.md]。

## 配置

正式版默认读取：

```text
~/Library/Application Support/com.cjmvpu.cghostty/config.ghostty
```

也支持 `~/.config/cghostty/config.ghostty`。
设置 `XDG_CONFIG_HOME` 时，使用其下的 `cghostty` 目录。
调试版的默认应用目录以 `.debug` 结尾。

平滑光标默认开启：

```ini
cursor-effect = smooth
window-vsync = true
```

移动时主体放大 12%，轮廓轻微椭圆化。
尾部随移动距离自然展开，主体不受拉扯。
连续移动保持形变，停止后恢复原形。
细线默认厚度为 3 像素，也应用相同的形变效果。
系统开启“减少动态效果”时停用动画。
设为 `cursor-effect = none` 可手动关闭。

## 构建

需要 Xcode 27+、Metal Toolchain 和 Zig 0.16.0。
在项目根目录执行：

```sh
brew install nushell gettext swiftlint
zig_bin="$(bash scripts/install-zig.sh)"
export PATH="$zig_bin:$(brew --prefix gettext)/bin:$PATH"
xcodebuild -downloadComponent MetalToolchain
nu macos/build.nu
open macos/build/Debug/cghostty.app
```

构建发行版并打包：

```sh
nu macos/build.nu --configuration ReleaseLocal
bash macos/package.sh
```

应用位于 `macos/build/ReleaseLocal/cghostty.app`。
ZIP 和 SHA-256 校验文件位于 `artifacts/`。
版本由 `build.zig.zon` 管理。

## 开发

- `macos/`：原生界面、系统集成和 Swift 测试。
- `src/terminal/`：终端协议与屏幕状态。
- `src/termio/`：PTY 与 shell 输入输出。
- `src/renderer/`：渲染、光标运动和帧调度。
- `src/surface/`：搜索与渲染会话的生命周期。
- `src/config/`：配置解析与快捷键。

`GhosttyKit.xcframework` 仅供应用内部桥接。
保留 `TERM=xterm-ghostty` 及必要的协议兼容名称。

架构见 [ARCHITECTURE.md]，开发与测试见 [HACKING.md]。
交付范围见 [SCOPE.md]，验证记录见 [VALIDATION.md]。

基于 [MIT 许可](LICENSE)，保留上游版权声明。

[Ghostty]: https://github.com/ghostty-org/ghostty
[Releases]: https://github.com/CJMVPU/cghostty/releases
[PACKAGING.md]: PACKAGING.md
[ARCHITECTURE.md]: ARCHITECTURE.md
[HACKING.md]: HACKING.md
[SCOPE.md]: SCOPE.md
[VALIDATION.md]: VALIDATION.md
