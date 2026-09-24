# cghostty 开发

仅支持 macOS 27+、Apple Silicon，使用 Xcode 27+ 与 MSL 4.1。工具安装和首次构建见 README。

## 构建与验证

```sh
# 默认同时更新 Zig 核心和 Swift 应用
nu macos/build.nu
# 仅更新内部框架与资源
python3 scripts/build.py core
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
python3 scripts/build.py test -Dtest-filter=config
python3 scripts/build.py test -Dtest-filter=Command
python3 scripts/build.py test -Dtest-filter=terminal.
python3 scripts/build.py test -Dtest-filter=input -Dtest-filter=os. -Dtest-filter=termio -Dtest-filter=pty
# 验证构建入口拒绝其他平台、Intel Mac 和被移除的独立产物
python3 scripts/check-scope.py
# 只检查原生业务层与内部 C 桥接边界（范围检查也会运行）
python3 scripts/check-bridge.py
# 对实际发布包增加身份、arm64、资源、签名检查
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
```

原生测试共享 `NSApp`、窗口与系统剪贴板，测试计划采用串行执行；桌面测试同样使用单一交互会话。

`--action test` 默认将应用、测试 runner 和 DerivedData 放到 `$TMPDIR/cghostty-tests-<checkout-hash>`，避免运行时读取文稿目录中的构建资源。`--build-dir /absolute/path` 可覆盖产物目录；测试配置及工作目录也使用非受保护路径。源码仍可留在文稿目录。Xcode 直接运行使用用户主目录作为工作目录；日常使用请运行安装到“应用程序”的发行版。终端命令主动读取文稿中的项目仍受 macOS 权限管理，若不希望授权，请将项目放在 `~/Developer` 等非受保护目录。

原生核心输出为 `zig-out/lib/libghostty-internal.a`。Xcode 直接链接该静态库，通过 `include/module.modulemap` 导入 `GhosttyKit`；不再生成或消费 XCFramework。头文件直接来自 `include/`，无需再复制进包装产物。原生测试与应用使用同一个内部 C 模块。

`zig build` 也可作为根入口，会调用同一个 `macos/build.nu`。日常应用开发直接使用 Nushell 脚本。核心安装步骤记录版本、优化模式、Zig／SDK、源码输入及归档摘要。`--skip-core` 会核对这些记录，缺少记录或任一项不匹配时拒绝复用；切换 Debug / ReleaseLocal 或修改核心后重新构建完整应用。仅修改 Swift 或 README／AGENTS 说明不影响核心复用；嵌入的 Markdown、字体、着色器等构建输入仍参与校验。

Zig 改动使用 `zig fmt`；Swift 使用 `swiftlint lint --strict --fix`。完整核心测试为 `python3 scripts/build.py test`，通常优先运行相关模块过滤测试。终端压缩等子目录的测试约定继续适用。CI 的普通运行覆盖整个 `terminal.` 模块，发行标签运行完整核心测试。

## 构建缓存与磁盘占用

`.zig-cache` 是可重新生成的编译缓存。源码、编译模式和测试过滤条件变化会生成不同的缓存产物，长期开发可能累积几十 GiB。它不是应用安装体积，也不是终端滚动历史。`zig-pkg` 是下载的依赖源码；`zig-out`、`macos/build` 和 `artifacts` 分别包含核心安装产物、应用/测试构建及发行包。

日常核心构建与测试使用 `python3 scripts/build.py core/test`，原生应用继续使用 `nu macos/build.nu`。两者与手动缓存清理共用仓库根目录的 `.cghostty-build.lock`，锁覆盖清理及整个构建过程；同时启动会排队，进程退出后由系统释放锁，锁文件本身不删除。

统一入口先核对固定 Zig 版本，以及实际库目录中的 `std/std.zig` 和 `compiler/build_runner.zig`，避免残缺工具链在编译中途才失败。可单独运行 `python3 scripts/check-toolchain.py`；修复方式为 `bash scripts/install-zig.sh`，再把输出的目录加入 `PATH`。原生 `clean` 不要求 Zig。

开始构建前检查 `.zig-cache`；超过 8 GiB 且没有 Zig/Xcode 构建活动时清空编译缓存，下次核心构建会重新编译。依赖下载、应用、测试结果和发行包均保留。8 GiB 是构建前清理阈值，不是运行中的硬配额。直接运行原始 `zig build test` 不参与项目锁或自动维护；请优先使用统一入口。进程检查仍保守防护未通过入口启动的构建，但不能为不使用锁的外部命令提供原子互斥保证。

```sh
python3 scripts/build-cache.py                 # 只查看大小
python3 scripts/build-cache.py --trim          # 超过 8 GiB 时清理
python3 scripts/build-cache.py --trim --max-gib 4
python3 scripts/build-cache.py --clear         # 不论大小清空编译缓存
```

不要在清理期间另行启动构建。脚本发现构建进程、无法读取进程列表、缓存是符号链接或包含 Git 跟踪文件时不会删除。执行环境禁止读取进程列表时，在正常终端运行维护命令。

应用构建默认复用 `macos/build`，原生测试默认复用 `$TMPDIR/cghostty-tests-<checkout-hash>`。日常验证沿用这些固定目录，不要为每次修改另建 `*-build` 或 `*-v2` 目录。只有需要同时保留修改前后两个版本作比较时才指定不同的 `--build-dir`，比较结束后删除这些独立构建目录。

未指定结果包或自定义构建目录时，原生测试把结果存入测试构建目录的 `ManagedTestResults`。构建入口在项目锁内提取摘要，并保留最近 1 次成功、2 次失败的结果包，结果包总量不超过 512 MiB；超大结果也可能删除，但保留最近 20 份小型 JSON 摘要。中断后的不完整结果视为失败。清理只识别此入口生成的命名，不跟随符号链接。

显式指定的 `--result-bundle` 和自定义 `--build-dir` 由调用者管理，不参与自动保留策略。指定的结果包路径必须尚不存在，Xcode 不会覆盖旧结果包。重复验证应在确认上一轮测试已结束、摘要已记录后，清理上一轮结果包及导出附件，再复用同一路径。旧的 `DerivedData/Logs/Test` 结果不自动迁移或删除；导出的截图也需要单独管理。

`scripts/build-cache.py` 只管理当前仓库的 `.zig-cache`，不会自动清理自定义构建目录、`.xcresult`、截图或 `/private/tmp/cghostty-*`。临时目录中的产物也需要在任务结束时清理；不能假定系统会及时回收它们。清理必须先核对具体路径，保留工具、源码备份和仍在使用的文件，不能直接通配删除所有同名前缀内容。

清理后同时检查目录大小和卷的实际可用空间。打开文件的进程（包括共享项目目录的虚拟机）可能继续占用已经删除的缓存；此时目录变小并不等于磁盘空间已释放。用 `lsof +L1` 查明持有者，待相关任务结束、进程关闭文件后再核实空闲空间，不要自动终止应用或虚拟机。

CI 只缓存 `zig-pkg`，键由工具链和依赖清单决定；不再缓存 `.zig-cache` 或整个全局 Zig 编译缓存，也不按提交 SHA 新建缓存。不使用旧键的回退恢复，以免重新带入已经删除的依赖。GitHub 中已有的旧缓存不受这次本地清理影响；本改动停止继续创建这种大缓存。

## 工具链与依赖

Zig 安装版本和 Apple Silicon 归档 SHA-256 集中在 `scripts/zig-toolchain.json`；安装脚本和 CI 读取同一份记录。更新工具链时同步 `build.zig.zon` 的 `minimum_zig_version`。`scripts/check-versions.py` 检查两者一致，并检查 simdutf 内置源码与其包清单的版本一致。

C/C++ 依赖版本表直接从 `pkg/*/build.zig.zon` 生成，见 `pkg/README.md`。更新依赖及生成文件后运行 `python3 scripts/check-versions.py --update-docs`，再运行默认检查。检查同时核对版本与源码归档 URL；默认模式只读，表格过期时给出更新命令。Wuffs 按源码提交快照记录，维护状态和生成说明保留为人工维护的正文。

链接与路径识别使用 PCRE2，渲染高亮和点击定位共用 UTF-8 匹配及资源预算。修改匹配行为时运行 `(cd pkg/pcre2 && zig build test)`，并定向测试 `url regex`、`StringMap`、`renderCellMap`；tmux 控制消息由字节字段解析器处理，对应 `tmux` 过滤测试。封装和升级说明见 `pkg/pcre2/README.md`。

原生界面直接使用 macOS 27 基线可用的 API，不再保留旧系统 Backport 或 Ventura 标签栏资源。`SelectionTextField` 仅负责搜索模型的字符串选区与 SwiftUI `TextSelection` 之间的绑定转换。

## Swift 6 并发约定

所有原生 target 的 Debug、Release、ReleaseLocal 均使用 Swift 6 语言模式、完整并发检查和 Swift warnings-as-errors。主应用和单元测试默认隔离到 MainActor，启用 Approachable Concurrency；XCTest UI 测试保留非隔离默认值，UI 测试的界面入口显式标记 MainActor。CI 的 `scripts/check-swift6.py` 读取 Xcode 项目检查这些构建约束。迁移原则参考 [Swift 官方并发迁移指南](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/)。

- UI 状态、窗口恢复、定时器和 UI 析构留在 MainActor；析构使用 `isolated deinit`，不假定任意线程释放对象都安全。
- 颜色转换和输入枚举等纯值操作显式 `nonisolated`。
- 核心的 `wakeup_cb` 是明确非隔离的 Sendable C 回调，只负责把 tick 排入主队列。其他 UI 回调遵守核心主线程调用约定。通知权限等系统后台回调必须主动切回主线程。
- `MainActor.assumeIsolated` 只用于已注册在主运行循环/主队列的同步回调，以及 AppKit 的同步加载、Cocoa scripting 入口。少量 `nonisolated(unsafe)` 局部引用用于传递尚无隔离标注的 Objective-C 参数/返回值；作用域只覆盖同步调用，配合运行时主线程断言，不声明这些系统对象可以任意跨线程共享。
- 拖放提供器通过 `Mutex` 保护异步加载结果，再完成 AppKit 要求的同步返回。终端详情通过 Observation 同时观察标题和路径，以一秒为失败截止时间，元数据就绪后立即继续。快捷指令缩略图直接生成最长边 256 像素的 PNG，在实体中保存编码结果供重复展示复用。
- Swift Testing 的参数化数据必须能安全传递；依赖 UI 隔离的泛型类型在测试函数内部构建，保持原有案例覆盖。

## 内部名称

Xcode scheme 和 Swift 模块仍为 `Ghostty`，C 桥接模块为 `GhosttyKit`。这些名称不是独立发布产品。不要仅为拼写一致重命名终端协议、TERM、转义序列或所有 C 符号。新增用户界面、资源路径、配置、发布链接使用 cghostty 身份。

## 手动运行验证

使用应用的绝对路径启动，避免命中另外安装的 Ghostty。验证终端可执行命令、UTF-8 输出、分屏、标签页，以及修改配置后重启应用生效。AppleScript 必须继续受 `macos-applescript` 设置保护。

独立测试配置在 Debug 下可通过 `CGHOSTTY_CONFIG_PATH` 指定；ReleaseLocal 使用 `--config-default-files=false --config-file=/absolute/path/test.ghostty` 启动可执行文件。Release 不读取这个 Debug 专用环境变量，不要把个人 shell 的标题更新误判为隔离故障。

## 构建服务

内部核心只构建 arm64 静态库，由 Xcode 直接链接，没有 XCFramework 包装、Universal 目标选择、独立 pkg-config 安装或静态库 dSYM 分支。版本直接来自 `build.zig.zon` 或显式 `--version`，不依赖 Git 探测。归档规范化与 libSystem 符号处理仍是当前 Zig/Xcode 链接所需步骤。

命令面板使用 `macos/Sources/Ghostty/CommandPalette.xcstrings`，支持英文、简体中文、繁体中文和日文，随 macOS 应用语言选择译文。新增内置命令时同步标题、说明和三套译文，运行 `python3 scripts/check-localizations.py` 检查覆盖。自定义命令文本及动作标识不参与翻译。原有译者署名见 `docs/TRANSLATORS.md`；其他语言可从 Git 历史查询。构建无需 gettext。

默认文楷 Medium 使用 `@embedFile` 编入核心，由 CoreText 直接从内存加载，不依赖应用 Resources 中的 TTF 文件。字体测试校验嵌入数据的 SHA-256，并覆盖中文、合成粗体与斜体。OFL 许可仍随应用分发。终端字体统一使用 CoreText。Inspector 及 Dear ImGui、FreeType、libpng、独立 zlib 依赖已移除；常规日志和自动化测试保留。PNG 解码使用 Wuffs，Kitty 压缩图片解压使用 Zig 标准库。

Inspector 菜单、命令面板入口和默认 `super+alt+i` 绑定已移除。旧配置里的 `inspector:toggle/show/hide` 动作会报无效动作，应删除对应绑定；其他快捷键和配置继续生效。

`+list-themes`、`+list-colors`、`+list-keybinds` 只输出文本，`--plain` 保留兼容。主题名称、主题文件加载及配置中的 `theme = ...` 不变；不再提供终端交互预览或自动写入主题配置。

Metal 编译通过 `xcrun --toolchain Metal` 调用安装的工具链。缺失时先执行 `xcodebuild -downloadComponent MetalToolchain`。无需 Linux 容器、Nix、Flatpak、Snap、独立 CMake SDK 或网站数据生成环境。

## Surface 渲染会话回归

`zig build test -Dtest-filter=Session -Dtest-filter=renderer -Dtest-filter=termio`
验证线程创建失败、启动后停止/join、重复停止、禁止重复启动，以及未启动时
队列中配置、搜索结果和连续字体切换引用的回收。`RenderSession` 拥有稳定地址，
将资源创建、线程启动、停止和最终释放分开；Surface 负责先停止搜索/IO 生产者，
再停止渲染，之后才释放终端和共享状态。`IOSession` 同样拥有固定地址和明确的
未初始化、就绪、运行、停止阶段；进程环境、解析器、消息队列和 IO 线程由它统一释放。

原生 `renderSessionReleasesAfterQueuedFontAndDisplayChanges` 验证连续字体、尺寸、
可见性与焦点切换后立即释放。桌面 `GhosttyCursorMotionUITests` 和
`GhosttySurfaceLifecycleUITests` 分别验证实际绘制与标签/分屏撤销后的会话连续性。

## Surface 搜索会话回归

`zig build test -Dtest-filter=SearchSession -Dtest-filter=terminal.search`
检查搜索会话初始化、分配失败回收、查询字节与结果快照的所有权，以及既有搜索算法。
`SearchSession` 独立管理搜索线程，`Surface` 只协调开始、清空、结束和导航；
工作线程先停止并 join，再释放终端和结果队列所依赖的对象。

原生 `activeSearchReleasesWithSurfaceAfterReplacingLongQueries` 检查长查询替换、
清空重启和活动搜索随最终 Surface 释放。桌面
`GhosttyObservationUITests/testSearchCountsNavigateClearRestartAndClose` 检查结果计数、
前后导航、无结果、清空后重启及关闭搜索所在分屏后继续输入。

## 渲染与光标回归

`zig build test -Dtest-filter=FrameScheduler` 验证独立帧调度策略：空闲停帧、
光标与 Kitty 动画竞争、绝对截止时间、过期帧、持续输入不推迟已有唤醒、
同期限更新优先和隐藏取消。计时器、DisplayLink
启停及锁仍由原渲染对象管理，不由策略模块创建。

`zig build test -Dtest-filter=renderer -Dtest-filter=config -Dtest-filter=Metrics -Dtest-filter="full height cursor sprites"`
覆盖八方向逐帧尺寸边界、整体等比例放大 12%、单格持续输入、快速改向、
隐藏/显示、Vim 形状切换及默认 3 像素笔画。`CursorMotion` 集中失效与活动状态；
`SmoothCursor` 维护主体、已提交绘制帧的位置历史和形变包络。
长距离从静止逐渐加速，单格输入保持快速响应，主体最长 220ms。
尾部使用最近 40–60ms 的历史位置，最多保留 32 个记录；不设像素长度上限。
检查 30/60/120/240Hz 下八方向、三种光标的连续帧轨迹接回上一帧主体，
以及快速转向、绘制中断、未提交采样不记入历史、恢复后收拢和形状切换清空。
连续输入覆盖 8、16、33、60、100ms 间隔；每段检查整个时间序列，
而非只检查重定向时的位置连续或某一帧前沿更宽。

`nu macos/build.nu --action test --ui-tests --only-testing GhosttyUITests/GhosttyCursorMotionUITests`
使用 16pt 字体和单格 PTY 移动，分别启用和关闭垂直同步。
两组分别使用较大留白和零留白，防止屏幕坐标重复投影裁切光标。
检查左右上下、斜向及最小化恢复后的连续帧。
逐帧查找完整主体并验证内部实心区域，防止尾部的包围盒掩盖主体压窄；
同时检查快速重复输入时实际出现尾部。
长距离横向、竖向、斜向跳转逐帧检查像素连通，尾部不得与主体脱离；
三种光标均须拍到超过旧长度上限的尾部。
增加每 32ms 转向的连续跳转，检查历史轨迹转弯处的真实 Metal 连通性。
跨帧连接由核心的连续提交序列验证；桌面截图不是逐显示帧录像。
细线和下划线均验证原生 3 像素、移动时放大和停止后精确恢复。
它不替代实际 Vim 物理按键、输入法及不同显示器的手动验收。

同向重定向检查速度接续、到达期限与无过冲；强反向取消旧方向惯性，
转弯侧向偏移限制在四分之一个单元格宽度以内。
尾部渐细按路径长度计算，直线中间点压缩后仍保留上一帧位置和转折。
帧缓存回归检查每个轮换槽独立更新、上传失败不提交版本和资源重建失效；
桌面像素回归交替修改文字/背景颜色，并检查闪烁与常亮切换。

### 渲染性能对比

使用相同的 ReleaseLocal 配置运行优化前后负载：

```sh
nu macos/build.nu --configuration ReleaseLocal --action test --ui-tests \
  --only-testing GhosttyUITests/GhosttyRendererPerformanceUITests \
  --result-bundle /private/tmp/renderer-perf.xcresult
xcrun xcresulttool export attachments \
  --path /private/tmp/renderer-perf.xcresult \
  --output-path /private/tmp/renderer-perf-attachments
python3 scripts/summarize-render-trace.py /private/tmp/renderer-perf-attachments
```

测试依次运行静止、持续输入、长跳、Kitty 动图并行和随后新增分屏。
每场景预热 1 秒、观测 6 秒；等待窗口标题与窗格就绪后才计时。
测试动作启用 `CGHOSTTY_TESTING`，隔离配置和偏好；普通发布构建不启用。
记录 draw 路径墙钟耗时（包含等待帧槽，不是进程 CPU 使用率）、
Metal GPU 执行时间、帧间隔、复制字节、尾部段数和动画定时器唤醒。
诊断开销也在结果中，单次 GPU/CPU 波动不能用于承诺耗电或全面提速。
`CGHOSTTY_RENDER_TRACE` 指定已有绝对目录可单独启用记录，正常运行关闭。
报告见 `RENDERER_PERFORMANCE.md`。

Metal 4 每个在途帧独占可复用的命令缓冲区、分配器、参数表与 residency set，GPU 完成后才允许重用。
开启 `MTL_DEBUG_LAYER=1` 运行应用可检查 Metal API；交互验收需覆盖单步、快速输入、连续导航、斜向移动、中文宽字符、选区、失焦和缩放。
CI 使用 GitHub `xcode-27` arm64 预览镜像，并在运行测试前验证系统为 macOS 27+。
`scripts/metal-capabilities.swift` 单独报告运行时设备的 Metal 4 能力与编译器创建结果。
两项真实 GPU 帧/图片测试在没有支持 Metal 4 的设备时明确跳过；设备声明支持而初始化失败时仍失败。
其余原生测试照常执行。CI 摘要列出失败断言和跳过项；跳过 GPU 测试不代表渲染验证通过，
发布前应在具备 Metal 4 的 Apple Silicon Mac 上完成原生回归。

CI 在构建前检查 Zig 格式、严格 SwiftLint、版本记录和工作流语法。`.github/actionlint.yaml` 补充校验器尚未内置的 `xcode-27` 官方预览标签，不改变 runner 的选择方式。日志与指定的 `.xcresult` 结果包以 `cghostty-ci-diagnostics` 产物保存 14 天，失败时也尝试上传；打包 ZIP 和校验文件仍使用独立的 `cghostty-macos-arm64` 产物。Action 均锁定提交 SHA，缓存键包含 SDK 构建号和工具链记录。

工具安装后，`scripts/record-build-environment.py` 记录 macOS、架构、Xcode、SDK、Swift、Metal、Zig、Nushell、SwiftLint、actionlint 和 Python 的实际版本。报告写入 `macos/build/ci-logs/environment.md`，同时显示在 Actions 运行摘要中，并随诊断产物上传。工具安装失败时也尝试记录，缺失或失败的命令标记为 `Unavailable`；报告本身不替代构建检查。Homebrew 工具随安装时可用版本变化，环境记录用于定位差异，不代表整个构建环境已完全固定。仅记录选定的公开 runner 元数据，不导出完整环境变量。

本地可运行 `python3 scripts/record-build-environment.py` 查看相同格式的报告。

## UI 状态与原生交互

整体所有权与线程边界见 [ARCHITECTURE.md](ARCHITECTURE.md)，原生 UI 约定见
[UI_ARCHITECTURE.md](UI_ARCHITECTURE.md)。SwiftUI 内容读取
Observation 模型；窗口由 `TerminalWindowState` 保存共享显示状态，终端区域由
`Ghostty.SurfaceState` 保存显示状态。AppKit 控制器负责窗口、焦点、关闭与恢复，
原生 SurfaceView 负责输入，由 SurfaceLifecycle 持有核心句柄。UI 重建不能重建终端会话。
生命周期区分暂时脱离窗口和最终释放：移动、关闭后的撤销保留会话；脱离时撤销本地事件监听、焦点及可见状态，
附着时刷新显示器与可见状态，最终释放才取消视图任务和释放句柄。旧滚动容器只能操作仍属于自己的原生视图。
核心 userdata 指向句柄持有的 SurfaceCallbackContext，内部弱引用视图，迟到回调必须处理视图已释放的情况。
修改此路径需运行 `SurfaceLifecycleTests`、`GhosttySurfaceLifecycleUITests`，并回归 `GhosttyObservationUITests`
和 `GhosttyTitlebarTabsUITests`。撤销测试需要验证原 shell 状态与输入焦点，不能仅检查分屏或标签数量。
已加载终端窗口的控制器由原生层持有，关闭时释放；不能依赖 SwiftUI 对状态模型的引用延长控制器寿命。

状态观察使用可取消的 Observation 任务；搜索任务在查询替换、关闭和释放时取消。
剪贴板确认是有一次性完成语义的请求，通过原生操作入口递送，不从合并后的显示状态推断。
窗口、标签和分屏命令通过 `Ghostty.App.windowRegistry.owner(of:)` 找到当前归属，
再调用有明确参数类型的控制器方法；不广播内部窗口命令，不使用字符串字典传参。
普通窗口列表、最近主窗口和层叠位置也由该注册表按 App 隔离；列表保留 AppKit 标签顺序。
窗口加载时弱注册，关闭时立即注销，不以控制器销毁作为窗口关闭的判据。强引用保活仍独立。
原生业务层、Helpers、AppDelegate 和 SurfaceView 不导入 GhosttyKit，不直接使用 C 句柄或分配/释放 API。
固定菜单命令、分屏、字体、滚动、搜索、输入及显示状态统一经过 `Ghostty.Surface`；
只有用户配置驱动的动作保留 `perform(action:)` 字符串入口。键盘与鼠标按钮调用必须保留核心的消费结果。
文本读取返回已复制的 Swift 值，C 文本和字体所有权在桥接内处理。
`Ghostty.App` 管理 App 资源，`Ghostty.App+Callbacks.swift` 负责反向回调转换，
剪贴板的核心请求状态由一次性 `Surface.ClipboardReadRequest` 管理。
`scripts/check-bridge.py` 随范围检查执行，防止 UI 再引入 C ABI 依赖。
配置分为 `Ghostty.ConfigHandle`（分配/加载/克隆/诊断/释放）和 `Ghostty.ConfigSnapshot`
（47 项原生设置、六项窗口字段及加载/诊断状态的不可变副本）。`Ghostty.Config` 一次替换一整代
句柄与快照；现有属性只转发快照，不再读取 C。窗口与 Surface 的显示投影显式接收快照。
全局配置先发布到 App，再发送同步通知；Surface 回调保持局部作用域。
只读、渲染健康、按键序列和键表状态通过带类型参数的 SurfaceView 方法传递；
只读保持同步，其他显示状态保留原有主队列更新顺序，不再借助通知字典中转。
快照读取器集中处理普通值和字符串复制，显式区分未加载配置与读取失败时的默认值。
增加原生设置时，把转换放进快照解码并补齐热重载/所有权验证，不在 UI 或 Config facade 追加 C 查询。
将需要读取的配置加入 `src/configgen.zig` 的 `native_keys`，运行 `zig build update-config-bridge`。
`Ghostty.ConfigSchema.swift` 的 53 个键由 Zig 字段与 `c_get.CValue` 自动生成；不要手改生成文件或另写字符串键。
读取使用 `ConfigSchema.<key>.read(from:into:)`，接收变量的类型必须匹配；可选数值以读取结果判断缺失，
不能把 Swift Optional 当作 C 整数的存储。显示枚举、默认值和字符串复制仍在快照解码器维护。
`zig build check-config-bridge` 只校验，不改文件；核心构建/测试、`--skip-core` 原生构建和范围检查都会执行。
修改字段类型或桥接规则时，运行配置 Zig 定向测试、`ConfigSnapshotTests` 和 `GhosttyConfigSnapshotUITests`。
快捷键查询继续使用同代句柄，解析和配置优先级由 Zig 负责。
应用内部事件直接调用所属对象的类型化方法；共享状态使用 Observation。
NotificationCenter 只接收 AppKit 系统事件，订阅必须随原生宿主结束。无 Combine 订阅。
分屏移动、关闭和撤销规则集中在 `BaseTerminalController+Splits.swift`；跨窗口操作
使用当前 App 的同一个撤销管理器，并保持 Surface 和核心会话身份不变。

快捷指令授权由 `Features/App Intents/IntentPermission.swift` 集中处理，遵守
`macos-shortcuts` 的 allow/deny/ask 策略。允许结果继续使用原有 UserDefaults 键和
`StoredPermission` 安全归档格式，以保留已有授权；拒绝不持久化。

不再接受 `show_gtk_inspector`、`toggle_tab_overview`、`toggle_window_decorations`
和 `prompt_window_title` 这四个旧动作。旧配置中的这些绑定会报告无效动作；
标题提示应使用 `prompt_surface_title` 或 `prompt_tab_title`。

`--ui-tests` 显式包含桌面测试，`--only-testing` 接受 Xcode 的目标/套件/测试标识；
默认单元测试和 CI 仍不启动桌面交互测试。辅助窗口直接创建并托管 SwiftUI 内容；
主菜单、主终端窗口样式和快捷终端均由 Swift 显式构造，保留 AppKit 响应链和动态快捷键。
窗口延迟加载有重入保护；没有窗口的基础控制器不会尝试加载 nib。
桌面测试要求解锁的交互会话及已处理的系统提示。测试命令使用粘贴避免输入法转换，
随后恢复原剪贴板内容；测试期间不要操作键盘鼠标。

## 应用图标

应用固定使用 `images/cghostty.icon` 中的 Icon Composer 图标；设计说明和导出图位于
`images/cghostty-icon-v4`，应用内静态展示使用 `AppIconImage.imageset`。
不再提供运行时图标切换、自定义图层配色或 Dock 图标插件。
旧配置中的 `macos-icon`、`macos-custom-icon`、`macos-icon-frame`、
`macos-icon-ghost-color`、`macos-icon-screen-color` 已不支持；仍保留这些字段的用户配置
会显示未知选项诊断，应删除相应行。

### IO 启动失败

IO 线程通过 `SurfaceFault` 值报告错误，不直接改写终端画面展示产品提示。
原生回调复制诊断后写入 SurfaceState；未附着窗口时也要接收。Surface 负责未接收时的文本兜底和绘制唤醒。
异常返回后不能重新运行持有旧栈上回调数据的事件循环；部分启动失败必须同时关闭后端和释放 ThreadData。
修改此路径时运行 `SurfaceFaultTests` 与 `GhosttySurfaceFaultUITests`，覆盖缺失/超限输入文件、失败后消息清理、关闭和配置修正后新建窗口。
