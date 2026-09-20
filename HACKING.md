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
# 指定一个尚不存在的结果包路径，便于在 Xcode 中查看测试结果
nu macos/build.nu --action test --result-bundle macos/build/TestResults.xcresult
# 与 CI 一致的格式与版本检查
zig fmt --check build.zig build.zig.zon src pkg
swiftlint lint --strict --no-cache
python3 scripts/check-versions.py
python3 scripts/check-swift6.py
# 工作流校验（brew install actionlint）
actionlint
# 核心回归测试
zig build test -Dtest-filter=config
zig build test -Dtest-filter=Command
zig build test -Dtest-filter=Terminal
zig build test -Dtest-filter=input -Dtest-filter=os. -Dtest-filter=termio -Dtest-filter=pty
# 验证构建入口拒绝其他平台、Intel Mac 和被移除的独立产物
python3 scripts/check-scope.py
# 对实际发布包增加身份、arm64、资源、签名检查
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
```

`zig build` 也可作为根入口，会调用同一个 `macos/build.nu`。日常应用开发直接使用 Nushell 脚本。`--skip-core` 只适用于版本和优化模式均匹配的已有核心；切换 Debug / ReleaseLocal 时重新构建完整应用。

Zig 改动使用 `zig fmt`；Swift 使用 `swiftlint lint --strict --fix`。完整核心测试为 `zig build test`，通常优先运行相关过滤测试。终端压缩、快照等子目录的测试约定继续适用。

Zig 安装版本和 Apple Silicon 归档 SHA-256 集中在 `scripts/zig-toolchain.json`；安装脚本和 CI 读取同一份记录。更新工具链时同步 `build.zig.zon` 的 `minimum_zig_version`。`scripts/check-versions.py` 检查两者一致，并检查 simdutf 内置源码、libpng 配置头和 libintl 生成头与各自包清单的版本一致。当前 C/C++ 依赖和生成说明见 `pkg/README.md`。

原生界面直接使用 macOS 27 基线可用的 API，不再保留旧系统 Backport 或 Ventura 标签栏资源。`SelectionTextField` 仅负责搜索模型的字符串选区与 SwiftUI `TextSelection` 之间的绑定转换。

## Swift 6 并发约定

所有原生 target 的 Debug、Release、ReleaseLocal 均使用 Swift 6 语言模式、完整并发检查和 Swift warnings-as-errors。主应用和单元测试默认隔离到 MainActor，启用 Approachable Concurrency；Dock 插件与 XCTest UI 测试保留非隔离默认值，UI 测试的界面入口显式标记 MainActor。CI 的 `scripts/check-swift6.py` 读取 Xcode 项目检查这些构建约束。迁移原则参考 [Swift 官方并发迁移指南](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/)。

- UI 状态、窗口恢复、定时器和 UI 析构留在 MainActor；析构使用 `isolated deinit`，不假定任意线程释放对象都安全。
- 颜色转换、图标编码和输入枚举等纯值操作显式 `nonisolated`。图标更新仍由独立 actor 串行执行，未移到 UI 线程。
- 核心的 `wakeup_cb` 是明确非隔离的 Sendable C 回调，只负责把 tick 排入主队列。其他 UI 回调遵守核心主线程调用约定。通知权限等系统后台回调必须主动切回主线程。
- `MainActor.assumeIsolated` 只用于已注册在主运行循环/主队列的同步回调，以及 AppKit 的同步加载、Cocoa scripting 入口。少量 `nonisolated(unsafe)` 局部引用用于传递尚无隔离标注的 Objective-C 参数/返回值；作用域只覆盖同步调用，配合运行时主线程断言，不声明这些系统对象可以任意跨线程共享。
- 拖放提供器通过 `Mutex` 保护异步加载结果，再完成 AppKit 要求的同步返回。终端详情通过 Zip 同时订阅标题和路径，保留两个独立的超时回退。
- Swift Testing 的参数化数据必须能安全传递；依赖 UI 隔离的泛型类型在测试函数内部构建，保持原有案例覆盖。

## 内部名称

Xcode scheme 和 Swift 模块仍为 `Ghostty`，C 桥接模块为 `GhosttyKit`。这些名称不是独立发布产品。不要仅为拼写一致重命名终端协议、TERM、转义序列或所有 C 符号。新增用户界面、资源路径、配置、发布链接使用 cghostty 身份。

## 手动运行验证

使用应用的绝对路径启动，避免命中另外安装的 Ghostty。验证终端可执行命令、UTF-8 输出、分屏、标签页和配置重载。AppleScript 必须继续受 `macos-applescript` 设置保护。

独立测试配置在 Debug 下可通过 `CGHOSTTY_CONFIG_PATH` 指定；ReleaseLocal 使用 `--config-default-files=false --config-file=/absolute/path/test.ghostty` 启动可执行文件。Release 不读取这个 Debug 专用环境变量，不要把个人 shell 的标题更新误判为隔离故障。

## 构建服务

内部 XCFramework 只封装一个 arm64 静态库和桥接头文件，没有 Universal 目标选择、独立 pkg-config 安装或静态库 dSYM 分支。版本直接来自 `build.zig.zon` 或显式 `--version`，不依赖 Git 探测。归档规范化与 libSystem 符号处理仍是当前 Zig/Xcode 链接所需步骤。

`zig build update-translations` 直接从共享命令面板提取 gettext 模板，合并现有译文并移除 obsolete 条目；不再生成 GTK/Python 中间模板。译者署名保留，删除的界面译文可从 Git 历史查询。

Metal 编译通过 `xcrun --toolchain Metal` 调用安装的工具链。缺失时先执行 `xcodebuild -downloadComponent MetalToolchain`。无需 Linux 容器、Nix、Flatpak、Snap、独立 CMake SDK 或网站数据生成环境。

## 渲染与光标回归

`zig build test -Dtest-filter=renderer -Dtest-filter=config` 覆盖光标距离分档、曲线单调性、中断时两个端点连续、尾端收拢和配置迁移提示。
Metal 4 每个在途帧独占可复用的命令缓冲区、分配器、参数表与 residency set，GPU 完成后才允许重用。
开启 `MTL_DEBUG_LAYER=1` 运行应用可检查 Metal API；交互验收需覆盖单步、快速输入、连续导航、斜向移动、中文宽字符、选区、失焦和缩放。
CI 使用 GitHub `xcode-27` arm64 预览镜像，并在运行测试前验证系统为 macOS 27+。
CI 在构建前检查 Zig 格式、严格 SwiftLint、版本记录和工作流语法。`.github/actionlint.yaml` 补充校验器尚未内置的 `xcode-27` 官方预览标签，不改变 runner 的选择方式。日志与指定的 `.xcresult` 结果包以 `cghostty-ci-diagnostics` 产物保存 14 天，失败时也尝试上传；打包 ZIP 和校验文件仍使用独立的 `cghostty-macos-arm64` 产物。Action 均锁定提交 SHA，缓存键包含 SDK 构建号和工具链记录。
