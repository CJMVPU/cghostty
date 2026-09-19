# cghostty 开发

仅支持 macOS 27+、Apple Silicon，使用 Xcode 27+ 与 MSL 4.1。工具安装和首次构建见 README。

## 构建与验证

```sh
# 默认同时更新 Zig 核心和 Swift 应用
nu macos/build.nu
# 仅更新内部框架与资源
zig build -Demit-macos-app=false
# 核心已更新后单独编译 Swift
nu macos/build.nu --skip-core
# Swift 单元测试；自动跳过需要桌面交互的 UI 测试
nu macos/build.nu --action test
# 核心回归测试
zig build test -Dtest-filter=config
zig build test -Dtest-filter=Command
zig build test -Dtest-filter=Terminal
# 验证构建入口拒绝其他平台、Intel Mac 和被移除的独立产物
python3 scripts/check-scope.py
# 对实际发布包增加身份、arm64、资源、签名检查
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
```

`zig build` 也可作为根入口，会调用同一个 `macos/build.nu`。日常应用开发直接使用 Nushell 脚本。`--skip-core` 只适用于版本和优化模式均匹配的已有核心；切换 Debug / ReleaseLocal 时重新构建完整应用。

Zig 改动使用 `zig fmt`；Swift 使用 `swiftlint lint --strict --fix`。完整核心测试为 `zig build test`，通常优先运行相关过滤测试。终端压缩、快照等子目录的测试约定继续适用。

## 内部名称

Xcode scheme 和 Swift 模块仍为 `Ghostty`，C 桥接模块为 `GhosttyKit`。这些名称不是独立发布产品。不要仅为拼写一致重命名终端协议、TERM、转义序列或所有 C 符号。新增用户界面、资源路径、配置、发布链接使用 cghostty 身份。

## 手动运行验证

使用应用的绝对路径启动，避免命中另外安装的 Ghostty。验证终端可执行命令、UTF-8 输出、分屏、标签页和配置重载。AppleScript 必须继续受 `macos-applescript` 设置保护。

## 构建服务

Metal 编译通过 `xcrun --toolchain Metal` 调用安装的工具链。缺失时先执行 `xcodebuild -downloadComponent MetalToolchain`。无需 Linux 容器、Nix、Flatpak、Snap、独立 CMake SDK 或网站数据生成环境。

## 渲染与光标回归

`zig build test -Dtest-filter=renderer -Dtest-filter=config` 覆盖光标距离分档、曲线单调性、中断时两个端点连续、尾端收拢和配置迁移提示。
Metal 4 每个在途帧独占可复用的命令缓冲区、分配器、参数表与 residency set，GPU 完成后才允许重用。
开启 `MTL_DEBUG_LAYER=1` 运行应用可检查 Metal API；交互验收需覆盖单步、快速输入、连续导航、斜向移动、中文宽字符、选区、失焦和缩放。
CI 使用 GitHub `xcode-27` arm64 预览镜像，并在运行测试前验证系统为 macOS 27+。
