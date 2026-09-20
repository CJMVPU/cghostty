# cghostty

cghostty 是基于 [Ghostty](https://github.com/ghostty-org/ghostty) 独立维护的个人终端应用，交付范围为 **macOS 27+ / Apple Silicon（arm64）**。

保留 Swift 6 / AppKit / SwiftUI 原生界面、Zig 终端核心、Metal 4 命令体系与 MSL 4.1 渲染、CoreText 字体、PTY 子进程、shell 集成、主题、分屏、标签页、快速终端和 AppleScript。所有原生构建配置启用完整并发检查与 Swift warnings-as-errors。Linux、Windows、BSD、iOS、WASM、Intel Mac、独立终端库 SDK 及其示例不属于本项目。

## 本地构建

需要运行 macOS 27+ 的 Apple Silicon Mac、Xcode 27+（含 Metal Toolchain）、Zig **0.16.0**、Nushell 和 gettext。当前工程包含 Icon Composer 图标；本分支使用 Xcode 27 验证，CI 使用 GitHub 的 `xcode-27` arm64 预览 runner，并检查其操作系统至少为 macOS 27。

```sh
brew install nushell gettext swiftlint
zig_bin="$(bash scripts/install-zig.sh)"
export PATH="$zig_bin:$(brew --prefix gettext)/bin:$PATH"
xcodebuild -downloadComponent MetalToolchain
nu macos/build.nu
open macos/build/Debug/cghostty.app
```

发布模式和本地安装包：

```sh
nu macos/build.nu --configuration ReleaseLocal
bash macos/package.sh
```

应用输出到 `macos/build/ReleaseLocal/cghostty.app`，ZIP 和 SHA-256 校验文件输出到 `artifacts/`。构建默认采用本地 ad-hoc 签名；Developer ID 签名及公证见 [PACKAGING.md](PACKAGING.md)。

## 原生平滑光标

默认启用 `cursor-effect = smooth`，通过原生 MSL 绘制双端伸缩光标。
单次移动沿用原 smooth cursor 的距离分档和曲线：前端 24–180ms，后端延迟 20/40/60ms。
连续移动从当前显示的两个端点接续，按本次输入步长计时并消耗剩余尾端延迟，避免按住方向键时拖尾不断拉长；停止后结束动画刷新。系统开启“减少动态效果”时停用动画。

```ini
cursor-effect = smooth
cursor-style = block
cursor-style-blink = true
cursor-opacity = 1
shell-integration-features = no-cursor
window-vsync = true
```

设为 `cursor-effect = none` 可关闭效果。支持不透明的方块、细线和下划线光标。Vim insert 模式保留细线形状并继续动画，细线按字符格宽度计时。尺寸变化时重置动画；失焦、隐藏、空心或锁形光标使用正常光标。
旧 `custom-shader`、`custom-shader-animation` 配置需删除；不再加载 GLSL 或外部 MSL 文件。
本轮不含 CRT。动画使用真实字形与单元格颜色，不从最终画面猜测并恢复背景。

## 独立身份

- 应用及命令行：`cghostty.app` / `cghostty`。
- 正式应用 ID：`com.cjmvpu.cghostty`；调试版：`com.cjmvpu.cghostty.debug`。
- 正式版默认配置：`~/Library/Application Support/com.cjmvpu.cghostty/config.ghostty`；调试版使用 `.debug` 目录。
- 也支持 `$XDG_CONFIG_HOME/cghostty/config.ghostty`（默认 `~/.config/cghostty/config.ghostty`）及对应目录下的兼容文件名 `config`。正式版和调试版共享显式 XDG 配置。
- 版本从 `build.zig.zon` 管理；发布时可通过 `--version 0.1.1` 显式指定。构建不再从 Git 分支或标签推导版本。
- “检查更新”打开本仓库 Releases；无上游自动更新和 Sentry 上报。

`TERM=xterm-ghostty`、终端协议、shell 集成的内部函数名和 `ghostty_*` C 接口保持兼容。`GhosttyKit.xcframework` 是 Swift 应用所需的内部静态桥接产物，仅含 macOS arm64，不作为独立 SDK 发布。公共依赖仍引用其现有上游归档与哈希；独立身份不意味着迁移所有第三方源码托管。

## 项目结构

| 目录 | 用途 |
| --- | --- |
| `macos/` | 原生应用、窗口与系统集成、Swift 测试、构建及打包脚本 |
| `src/terminal/` | 转义序列、屏幕、滚动历史、选择、图片协议、终端状态 |
| `src/termio/` | PTY、shell 子进程、输入输出、shell 集成 |
| `src/renderer/`、`src/font/` | Metal 绘制与 CoreText 字体处理 |
| `src/apprt/embedded.zig`、`include/ghostty.h` | Zig 与 Swift 的内部桥接 |
| `src/build/`、`pkg/` | 应用构建辅助代码与第三方依赖适配 |
| `src/config/`、`src/cli/` | 配置解析、快捷键、应用内命令行功能 |
| `test/`、`macos/Tests/` | 保留的终端行为与原生应用测试 |
| `.github/workflows/macos.yml` | Apple Silicon 构建、测试、打包及本仓库草稿发布 |

开发验证见 [HACKING.md](HACKING.md)，裁剪边界及保留项见 [SCOPE.md](SCOPE.md)。本轮验证结果见 [VALIDATION.md](VALIDATION.md)。本项目保留上游版权与 [MIT 许可](LICENSE)。
