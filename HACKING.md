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
# 真实桌面 UI 回归；需要可交互的 macOS 会话
nu macos/build.nu --action test --ui-tests --only-testing GhosttyUITests/GhosttyObservationUITests
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

`--action test` 默认将应用、测试 runner 和 DerivedData 放到 `$TMPDIR/cghostty-tests-<checkout-hash>`，避免运行时读取文稿目录中的构建资源。`--build-dir /absolute/path` 可覆盖产物目录；测试配置及工作目录也使用非受保护路径。源码仍可留在文稿目录。Xcode 直接运行使用用户主目录作为工作目录；日常使用请运行安装到“应用程序”的发行版。终端命令主动读取文稿中的项目仍受 macOS 权限管理，若不希望授权，请将项目放在 `~/Developer` 等非受保护目录。

`zig build` 也可作为根入口，会调用同一个 `macos/build.nu`。日常应用开发直接使用 Nushell 脚本。`--skip-core` 只适用于版本和优化模式均匹配的已有核心；切换 Debug / ReleaseLocal 时重新构建完整应用。

Zig 改动使用 `zig fmt`；Swift 使用 `swiftlint lint --strict --fix`。完整核心测试为 `zig build test`，通常优先运行相关过滤测试。终端压缩、快照等子目录的测试约定继续适用。

Zig 安装版本和 Apple Silicon 归档 SHA-256 集中在 `scripts/zig-toolchain.json`；安装脚本和 CI 读取同一份记录。更新工具链时同步 `build.zig.zon` 的 `minimum_zig_version`。`scripts/check-versions.py` 检查两者一致，并检查 simdutf 内置源码、libpng 配置头和 libintl 生成头与各自包清单的版本一致。

C/C++ 依赖版本表直接从 `pkg/*/build.zig.zon` 生成，见 `pkg/README.md`。更新依赖及生成文件后运行 `python3 scripts/check-versions.py --update-docs`，再运行默认检查。检查同时核对版本与源码归档 URL，以及 ImGui 与 Dear Bindings 的匹配关系；默认模式只读，表格过期时给出更新命令。Wuffs 按源码提交快照记录，维护状态和生成说明保留为人工维护的正文。

链接与路径识别使用 PCRE2，渲染高亮和点击定位共用 UTF-8 匹配及资源预算。修改匹配行为时运行 `(cd pkg/pcre2 && zig build test)`，并定向测试 `url regex`、`StringMap`、`renderCellMap`；tmux 控制消息由字节字段解析器处理，对应 `tmux` 过滤测试。封装和升级说明见 `pkg/pcre2/README.md`。

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

工具安装后，`scripts/record-build-environment.py` 记录 macOS、架构、Xcode、SDK、Swift、Metal、Zig、Nushell、gettext、SwiftLint、actionlint 和 Python 的实际版本。报告写入 `macos/build/ci-logs/environment.md`，同时显示在 Actions 运行摘要中，并随诊断产物上传。工具安装失败时也尝试记录，缺失或失败的命令标记为 `Unavailable`；报告本身不替代构建检查。Homebrew 工具随安装时可用版本变化，环境记录用于定位差异，不代表整个构建环境已完全固定。仅记录选定的公开 runner 元数据，不导出完整环境变量。

本地可运行 `python3 scripts/record-build-environment.py` 查看相同格式的报告。

## UI 状态与原生交互

结构和所有权约定见 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md)。SwiftUI 内容读取
Observation 模型；窗口由 `TerminalWindowState` 保存共享显示状态，终端区域由
`Ghostty.SurfaceState` 保存显示状态。AppKit 控制器负责窗口、焦点、关闭与恢复，
原生 SurfaceView 负责输入和持有核心句柄。UI 重建不能重建终端会话。
已加载终端窗口的控制器由原生层持有，关闭时释放；不能依赖 SwiftUI 对状态模型的引用延长控制器寿命。

状态观察使用可取消的 Observation 任务；搜索任务在查询替换、关闭和释放时取消。
剪贴板确认是有一次性完成语义的请求，通过原生操作入口递送，不从合并后的显示状态推断。
Combine 仅用于仍有必要的原生通知/控件事件。不要引入新旧状态互相同步的兼容层。

`--ui-tests` 显式包含桌面测试，`--only-testing` 接受 Xcode 的目标/套件/测试标识；
默认单元测试和 CI 仍不启动桌面交互测试。辅助窗口直接创建并托管 SwiftUI 内容；
主菜单、主终端窗口样式和快捷终端仍使用实际承担 AppKit 初始化的 XIB。
桌面测试要求解锁的交互会话及已处理的系统提示。测试命令使用粘贴避免输入法转换，
随后恢复原剪贴板内容；测试期间不要操作键盘鼠标。
