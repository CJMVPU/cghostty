## 0.1.4 方向光标与 Vim 连续搜索（2026-09-20）

- 追加回归覆盖新目标在旧目标后方、但仍在当前显示位置前方的情况：按实际显示位置判断领跑方向，计时仍采用本次逻辑输入距离。
- 从两个矩形端点的包络改为四角动画；按移动方向分配前后响应，横向、竖向与四个斜向均有对应的领跑角。前沿沿垂直移动方向展开后恢复，轴向最大约 15%；记录并限制既有展开量，避免持续输入时叠加膨胀。快速反向使用实际角点的凸轮廓，避免交叉四边形。
- Vim 搜索的 PTY 记录：100 次 `n`，每次均发送 DECTCEM 隐藏与显示光标。隐藏帧现在只停止绘制/刷新请求，保留运动状态；后端使用始终较慢的响应时间，不再因连续输入消耗完延迟而与前端合并。
- 光标专项 **10/10**；最终渲染器/配置回归 **296/296**。覆盖每 8/16/33ms 连续移动或循环搜索 500 次、八方向的前后关系、展开上限与恢复、打断位置连续、Vim 模式切换、1–4 像素细边保护，以及随机快速反向的凸轮廓。日志：`/private/tmp/cghostty-directional-cursor-tests.log`。
- 最终 ReleaseLocal 构建通过，版本 **0.1.4（4）**，编译无 warning/error；原生 MSL 4.1、macOS/arm64 范围、资源和签名检查通过。日志：`/private/tmp/cghostty-directional-build-final.log`、`/private/tmp/cghostty-directional-scope.log`。
- 独立 Bundle ID 的测试副本通过应用 CLI 指定临时 Vim 文件，以 16ms 定时输入路径完成 **1,200 次搜索跳转**；运行中截图观察到绿色光标拉伸，插入模式连续输入后仍显示细线光标。开启 `MTL_DEBUG_LAYER=1`，stderr 未报告 Metal 校验错误。计数：`/private/tmp/cghostty-directional-vim-search-result.txt`；日志：`/private/tmp/cghostty-directional-runtime-stdio.log`。
- 桌面观察是运行中截图和 Vim 定时输入；未将其宣称为物理键盘长按、所有帧的像素分析或所有 Vim/Neovim 配置的穷举验证。初次后台启动的副本没有终端窗口，界面读取超时；明确指定测试命令后可正常访问，采样未发现主线程阻塞。
- 本地 ZIP 完整性与 SHA-256 检查通过，使用 ad-hoc 签名、未做 Apple 公证。正式附件及远程 CI 状态以 v0.1.4 Release 为准；下面的 0.1.3 记录仍属于之前版本。

## 0.1.3 发布前生命周期复验（2026-09-20）

- 首次标签 CI 的原生测试在 `commandsFollowSurfaceOwnershipAfterMovingBetweenWindows` 附近发生 malloc 内存损坏，main 的同一提交测试通过。停止发布并检查释放路径：Swift `Surface` 只有 C 句柄，未持有所属 `App`；当临时控制器先释放 App、Surface 仍存活时，核心 `App.deinit` 会先清理其 Surface，之后 Swift 句柄再释放会访问失效对象。
- `Surface` 明确持有创建它的 `App`，同步及延迟到主线程的释放都保证 App 活到 `ghostty_surface_free` 之后。新增行为测试证明撤销外部 App 引用后终端仍保有核心，销毁终端后两者都能释放，不形成循环引用。
- 修正后的完整原生测试 **243 项通过、1 项跳过、0 项失败**；桌面交互 **2/2**、标签几何 **5/5** 通过，三份结果均无运行时警告。结果包：`/private/tmp/cghostty-013-native-lifetime.xcresult`、`/private/tmp/cghostty-013-ui-lifetime.xcresult`、`/private/tmp/cghostty-013-geometry-lifetime.xcresult`。
- 同一进程连续重复执行 PresentationStateTests **20 轮、260 次执行全部通过**，无跳过、失败或运行时警告。结果包：`/private/tmp/cghostty-013-lifetime-repeat.xcresult`；摘要：`/private/tmp/cghostty-013-lifetime-repeat-summary.json`。
- 最终 ReleaseLocal 重编译、macOS/arm64 资源及签名检查、ZIP 完整性检查通过。日志：`/private/tmp/cghostty-013-release-lifetime.log`、`/private/tmp/cghostty-013-scope-lifetime.log`；本地最终 ZIP SHA-256：`6ea0f73898da116c233d2a3f53628dadb5faf29ac45185383fabc727df22703e`。
- 下节为首次本地验证记录，测试数量、发行包校验值以本节最终复验及公开 Release 的校验文件为准。未将一次远程崩溃当作环境波动直接重试跳过。

## 0.1.3 原生标签栏布局重构与发布前验证（2026-09-20）

- `NativeTitlebarTabLayout` 统一持有定位原生标签附件的 8 条约束；调整窗口尺寸时复用，在附件转移、关闭、脱离窗口或工具栏临时零尺寸时解除，并恢复 AppKit 原有 autoresizing 行为。帧变化在主队列合并处理，不使用轮询或固定等待。
- 标签排序直接使用 `NSWindowTabGroup.insertWindow`，删除先拆组再重建的分支和临时 workaround，保留选中标签及焦点。原生标签行按添加按钮的实际尺寸稳定高度；独立窗口的分屏缩放按钮由工具栏布局，避免硬编码顶部间距造成标题和按钮错位。
- 首次扩展几何验证发现标签高度反馈变化和缩放按钮对齐问题；修正实现后，保留原有 1 像素容差重新验证通过，没有通过放宽断言掩盖问题。包含普通窗口、全屏、跨窗口拖动、三窗口合并，以及连续三轮左右排序后的会话状态。
- 最终完整原生测试 **242 项通过、1 项跳过、0 项失败**，参数化展开后 361 次执行通过；跳过的是现有 Benchmarks 示例。桌面交互 **2/2**、标签栏几何 **5/5** 通过；三份结果包的 `runtimeWarnings` 均为空，之前移动标签出现的 7 条布局警告没有重现。
- 结果包：`/private/tmp/cghostty-013-native.xcresult`、`/private/tmp/cghostty-013-ui.xcresult`、`/private/tmp/cghostty-013-geometry.xcresult`；对应 `-summary.json` 保存精确测试数量。仍不将这些流程等同于所有输入法和系统恢复场景的穷举验收。
- 最终严格 SwiftLint 检查 **178 个文件、0 个问题**；Zig 格式、依赖版本记录、Swift 6、源码范围、actionlint 和 diff 空白检查通过。核心和 IO 的清理验证见下节，本次布局改动没有改变 Zig 核心行为。
- 从新的目录完整构建 ReleaseLocal **成功，构建日志无 warning/error**。最终应用版本 `0.1.3`、构建号 `3`，最低 macOS `27.0`、主程序仅 arm64，资源和 ad-hoc 签名检查通过；本地 ZIP 完整性校验通过。
- 本地应用：`/private/tmp/cghostty-013-release/ReleaseLocal/cghostty.app`；本地验证包：`/private/tmp/cghostty-013-package/cghostty-0.1.3-macos-arm64.zip`。日志：`/private/tmp/cghostty-013-release.log`、`/private/tmp/cghostty-013-scope.log`、`/private/tmp/cghostty-013-swiftlint.log`。本地 ZIP SHA-256 为 `ffda01dcebd0ba67f06bc65589a9d7135749a8c0f1f5d040734a7315b449c8cf`；远程 CI 会重新构建，正式下载请以 Release 附带的校验文件为准。
- 版本记录、打包示例和发行说明同步为 0.1.3。发行继续使用 ad-hoc 签名，没有配置 Developer ID 或 Apple 公证；本次没有替换 `/Applications` 中的已安装应用。

## 无调用代码、IO、窗口命令与图标设施清理（2026-09-20）

- 删除无调用的 Swift 视图包装、调试视图树打印、字符串截断和旧图标辅助代码。终端 IO 直接使用 `Exec` 与其线程数据，删除只有 `exec` 一个分支的 backend 联合类型、转发方法及空的配置更新调用。
- 配置诊断统一读取；XDG 和 Application Support 的新旧文件选择共用一份实现。保留新文件优先、旧文件后备、两者不存在时返回新路径，以及延迟解析旧路径的语义。新增配置错误在有效重载后清空的行为测试。
- 内部窗口、标签、分屏、命令面板和全屏命令复用现有 Surface 所有权查找，直接调用控制器方法，删除 19 个通知名称及字典参数。保留焦点要求、配置继承、关闭确认和快速终端差异；关闭普通窗口不再广播给快速终端。
- 新增核心调用到所属控制器、脱离窗口的分屏操作、跨窗口移动后归属三个行为测试。测试夹具不使用宿主应用的全局撤销栈，避免临时核心结束后仍被撤销记录持有 Surface；排空主队列后再释放临时 App。
- 整套备用/自定义图标设施已移除：Swift 实现、Dock 插件目标和嵌入/签名步骤、五个配置字段、专属颜色列表 C 桥接、图层合成、专属测试，以及 36 个资源文件（5,592,453 字节）。没有新增长期维护的“旧图标不存在”检查。固定图标使用用户确认的暗银纹理、圆角与右上光照版本；文档图标引用同步到实际生成的 `cghostty.icns`。
- 核心相关验证 **1,361 项通过、1 项跳过**；最后的 IO 错误分支简化后，Command/termio 定向验证 **133/133 通过**。日志：`/private/tmp/cghostty-cleanup3-core-final.log`、`/private/tmp/cghostty-cleanup3-io-final.log`。
- 完整原生测试 **240 项通过、1 项跳过、0 项失败**；参数化展开后通过 359 次执行，运行时警告为 0。结果：`/private/tmp/cghostty-cleanup3-native-v4.xcresult`；摘要：`/private/tmp/cghostty-cleanup3-native-v4-summary.json`。
- 桌面测试 **2/2 通过、0 项跳过**：分屏、搜索、命令面板后的输入、标签切换/移动/关闭，以及独立窗口创建/关闭后保留原会话。结果：`/private/tmp/cghostty-cleanup3-ui.xcresult`。新增的标签移动流程记录 **7 条 AppKit 标签栏约束警告**，涉及原生标签栏临时零尺寸；功能断言通过。本轮未修改该布局实现，不能将桌面结果描述为零警告，也未据此宣称全部全屏、输入法与恢复场景均经过验收。
- 使用新的临时构建目录执行完整 ReleaseLocal 构建，随后对最终源码执行增量确认。最终构建日志无编译警告或错误，严格 SwiftLint 检查改动的 18 个 Swift 文件无问题。macOS/arm64、实际应用资源及签名检查通过；一次性检查产物的插件目录和 Info.plist，确认 Dock 插件不再嵌入。Swift 6 检查覆盖剩余 3 个 target 的 9 个配置，Xcode 工程无悬空对象引用。日志：`/private/tmp/cghostty-cleanup3-release-final.log`、`/private/tmp/cghostty-cleanup3-scope-final.log`。
- 验证应用：`/private/tmp/cghostty-cleanup3-release/ReleaseLocal/cghostty.app`；本地验证包：`/private/tmp/cghostty-cleanup3-package/cghostty-0.1.2-macos-arm64.zip`。沿用当前源码版本号和 ad-hoc 签名，本轮不代表新版本发布或已安装应用更新。

# 本地交付验证

日期：2026-09-20。环境：Apple Silicon macOS 27.0（26A428）、Zig 0.16.0、Xcode 27、Nushell 0.115.1、SwiftLint 0.65.1。

本轮将交付基线提高为 macOS 27+、arm64、Metal 4 命令 API 与 MSL 4.1。此记录替代此前 macOS 13 部署目标的验证记录。

## 0.1.2 发布与文稿权限排查（2026-09-20）

- 系统 TCC 日志确认：此前 Debug 应用从文稿目录下的构建产物运行时出现 DocumentsFolder 查询；已安装应用的请求来自用户终端命令 `ls` / `nvim`。用户确认正式版是在进入项目或执行命令后提示。没有修改系统权限、TCC 数据库或要求完全磁盘访问。
- `macos/build.nu --action test` 默认将应用、runner、DerivedData 放到带 checkout 标识的系统临时目录；可通过 `--build-dir` 覆盖。Xcode 启动目录改为用户主目录；UI 测试使用临时工作目录，测试计划使用空配置，涉及真实 Surface 的原生测试使用不加载个人启动文件的 shell。
- 新环境下首次原生测试暴露核心销毁期间唤醒回调强持有已销毁对象的崩溃。将排队 tick 改为弱持有 App，增加 `queuedWakeupDoesNotRetainApp` 验证排队回调不延长其寿命；之后完整测试通过。
- 最终原生测试 **249 项通过、1 项跳过、0 项失败**，参数化展开后 368 次执行通过，运行时警告为空：`/private/tmp/cghostty-012-native-final.xcresult`。
- 最终桌面测试 **2/2 项通过**，无运行时警告：`/private/tmp/cghostty-012-ui.xcresult`。覆盖标签切换、标题、分屏、搜索、命令面板及焦点恢复。
- 13:50 起至验证结束的 TCC 日志没有新的 `SystemPolicyDocumentsFolder` 记录：`/private/tmp/cghostty-012-tcc-final.log`。这证明本轮隔离测试没有触发该访问；不代表用户命令访问文稿文件可绕过系统权限。
- 首次远程 CI 在空依赖缓存下暴露 PCRE2 懒加载问题：封装尚未生成库就被根构建读取。改为显式必需依赖，保留上层按需加载；全新全局/本地缓存下绑定测试 3/3 通过，与 CI 相同的根构建命令也正常报告已删除选项无效，不再发生 artifact panic。日志：`/private/tmp/cghostty-012-pcre2-cold.log`、`/private/tmp/cghostty-012-root-cold.log`。
- 第二次远程测试进程崩溃在 Xcode `HarnessEventHandler.testCaseEnded` / `Test.id.getter`，并非断言失败；测试计划改为串行，避免共享 NSApp、窗口和系统剪贴板的用例并发执行。本地完整复验仍为 249 通过、1 跳过、0 失败，运行时警告为空：`/private/tmp/cghostty-012-native-serial.xcresult`。CI 另输出 xcresult JSON 摘要，保留失败诊断。
- 核心回归 **1,364 项通过、1 项跳过**，85/85 构建步骤通过；PCRE2 绑定 **3/3 项通过**。日志：`/private/tmp/cghostty-012-core-summary.log`、`/private/tmp/cghostty-012-pcre2.log`。
- SwiftLint 严格检查 188 文件、0 问题；Zig 格式、依赖版本记录、Swift 6 配置、actionlint 和 diff 空白检查通过。
- 图标使用 imagegen 为现有角色添加银色边框，规范为 1024 像素源画布，重新导出 1024/512/64 像素 macOS 图标并同步 Dock 插件。实际导出目视确认边框完整。
- ReleaseLocal 构建成功。发行包沿用 ad-hoc 签名，不代表 Developer ID 签名或 Apple 公证；未修改已安装应用。源码位置及项目目录不自动搬迁。

## SwiftUI / Observation / AppKit 职责收拢（2026-09-20）

- 共享 UI 状态统一到 Observation：应用、配置、终端窗口、Surface、搜索、标题栏、玻璃背景、安全输入和配置错误。SwiftUI 使用类型化环境及局部 State；当前 `macos/Sources` 不再使用 ObservableObject、Published、ObservedObject、StateObject 或 EnvironmentObject。
- 新增 `TerminalWindowState`、`Ghostty.SurfaceState` 和 `Ghostty.SearchState`，终端显示状态与 AppKit 对象分离。原生 SurfaceView 保持稳定身份并持有核心 Surface；窗口结构变更仍经过控制器同步所有权，不复制核心句柄或建立双向兼容状态。
- 删除 TerminalViewModel 协议、OSSurfaceView 中间类、SplitTree 通用 publisher 工具和旧状态订阅链。关于、配置错误和剪贴板确认窗口改为程序化 AppKit 窗口托管 SwiftUI，删除三个空壳 XIB 和未使用的 SettingsView 占位页面；保留实际承担原生窗口/菜单初始化的 XIB。
- 剪贴板请求继续使用明确的原生事件、身份核对和取消流程，避免 Observation 合并中间显示状态时丢失一次性完成语义。观察任务使用弱引用，并在切换目标或关闭时取消；短搜索仍保留原有防抖。
- 桌面验证定位并修复了原先依赖 SwiftUI 引用延长窗口控制器寿命的隐含持有关系：已加载的普通终端控制器由原生层持有，关闭时释放；快捷终端仍由 AppDelegate 持有。新增存活至关闭、关闭后释放的测试。
- 原生测试迁移前基线为 **236 项通过、1 项跳过、0 项失败**，结果包 `/private/tmp/cghostty-ui-baseline.xcresult`。
- 架构和维护约定写入 `UI_ARCHITECTURE.md`、`HACKING.md`。桌面测试改为构建脚本显式选择，不再因为缺少 Xcode IDE 环境变量而静默执行零项测试。测试期间遇到系统弹窗和输入法干扰，用户处理弹窗后继续验证；固定 shell 命令改为粘贴并恢复原剪贴板，避免输入法转换。

- 最终原生测试 **248 项通过、1 项跳过、0 项失败**；参数化展开后通过 367 次执行，`runtimeWarnings` 为空。相比基线新增 12 项有效测试，覆盖属性级观察、稳定 Surface/核心身份、控制器释放、原生窗口存活与关闭、标题切换、辅助窗口、剪贴板取消及搜索防抖。结果包：`/private/tmp/cghostty-ui-native-complete.xcresult`；摘要：`/private/tmp/cghostty-ui-native-complete-summary.json`。
- 移除临时诊断后的最终桌面验收 **2/2 项通过、0 项跳过**，运行时警告为空：实际 OSC 标题更新、分屏、搜索编辑与关闭、命令面板关闭后的输入，以及两个标签之间往返切换保留会话标题。结果包：`/private/tmp/cghostty-ui-desktop-complete.xcresult`；摘要：`/private/tmp/cghostty-ui-desktop-complete-summary.json`。这是特定流程的验收，未遍历全部输入法、全屏或系统恢复场景。
- 从空生成目录完整构建 ReleaseLocal 成功；范围检查确认 macOS/arm64、应用资源和 ad-hoc 签名有效。一次性核对包内三个已删除辅助 nib 均不存在，六个现用菜单/终端 nib 齐全；应用和 dSYM 的 arm64 UUID 一致。日志：`/private/tmp/cghostty-ui-release-complete.log`、`/private/tmp/cghostty-ui-app-check.log`。此前两条 Dear ImGui dSYM 警告没有重现；干净构建另有 DockTilePlugin 不依赖 AppIntents.framework 因而跳过元数据提取的 Xcode 提示。
- 严格 SwiftLint 检查 **188 个文件、0 个问题**，版本记录、Swift 6 配置、源码范围和 diff 空白检查通过。最终产物为 `macos/build/ReleaseLocal/cghostty.app`；本轮未修改已安装应用、未生成发行 ZIP、未推送远程或发布新版本。

## Dear ImGui dSYM 符号警告修复（2026-09-20）

- 根因：`pkg/dcimgui/ext.cpp` 与 `pkg/macos/text/ext.c` 均生成 `ext.o`，合并到内部静态库后形成同名成员。两个 ImGui 构造包装符号实际存在，但 `dsymutil` 通过归档成员名读取调试信息时定位到不含这些符号的对象。
- 将 ImGui 扩展更名为 `dcimgui_ext.cpp`，同步构建路径和注释。C++ 文件与更名前逐字节一致，没有改变接口、初始化行为或调试信息生成选项。
- Debug 内部框架 **194/194 步骤成功**；Debug 与 ReleaseLocal 原生应用均重新构建成功，两个完整构建日志均无 `warning:` 或 `error:`。日志：`/private/tmp/cghostty-imgui-dsym-debug.log`、`/private/tmp/cghostty-imgui-dsym-release.log`。
- 两种配置的静态库各有一个 `ext.o` 和一个 `dcimgui_ext.o`。`dwarfdump` 确认两个 ImGui 包装函数均具有有效代码地址、正确源码路径和行号；ReleaseLocal 的 `dsymutil --dump-debug-map` 无诊断输出。调试信息记录：`/private/tmp/cghostty-imgui-dsym-debug-dwarf.txt`、`/private/tmp/cghostty-imgui-dsym-release-dwarf.txt`。
- ReleaseLocal 的 arm64、资源和签名检查通过；Zig 格式、版本记录和 diff 空白检查通过。本次仅更名构建输入，未新增长期检查或重跑功能单元测试，未对外发布。下方旧记录中的两条 dSYM 警告为修复前历史结果。

## PCRE2 替换与 tmux 协议解析（2026-09-20）

- 先在 `/private/tmp/cghostty-regex-probe/` 中链接原 Oniguruma 6.9.10 与 PCRE2 10.48 做对照。现有 **90 个** URL/路径输入及 **5,010 个** Unicode、边界和确定性组合输入，逐次匹配的 UTF-8 字节范围全部一致；正式规则与已验证规则逐字节一致。
- 将无限长度美元数字后向断言与相邻的单词边界限制合并为固定长度字符排除；显式保留 Unicode 字母、全部标记、数字与连接标点集合，覆盖中文、组合音标、间距标记和包围标记。PCRE2 自身 Unicode 数据由旧库的 16 升为 17，对照范围不构成所有 Unicode 码点语义完全一致的保证。
- 链接渲染与点击定位统一使用 PCRE2；每次搜索独立上下文，限制匹配工作 100,000、深度 1,000、堆内存 8 MiB，排除无法映射到终端单元格的空匹配。复用上游 Zig 0.16 构建，静态链接 8 位库，关闭 JIT。
- tmux 的 8 处正则解析改为字段、前缀和十进制数字解析；保留数据/名称空格、CRLF 与空布局标志，非法或溢出 ID 被拒绝并可继续解析下一条消息。删除旧 RegexError 分支以及 tmux 对正则开关的依赖。
- 删除 `pkg/oniguruma` 的 **11 个文件**、全局初始化、构建依赖、系统库选项与功能门控。新 PCRE2 构建/封装/清单共 **145 行**，对照程序只留在临时目录，应用没有旧引擎回退。更新依赖版本表，并将 PCRE2 封装、StringMap 和 tmux 测试纳入 CI。
- 最终相关核心回归 **744/744 项通过**，85/85 构建步骤成功；PCRE2 封装 **3/3 项通过**。测试覆盖 Unicode 链接选区、多次匹配、空匹配、预算耗尽、非法 UTF-8、非法偏移和 tmux 畸形消息恢复。核心测试的沙盒日志包含系统 XPC 警告，测试命令退出码为 0。日志：`/private/tmp/cghostty-pcre2-regression-final.log`。
- Debug 内部框架 **194/194 构建步骤成功**；原生测试 **236 项通过、1 项跳过、0 项失败**，运行时警告为空。结果包：`/private/tmp/cghostty-pcre2-native-tests.xcresult`；摘要：`/private/tmp/cghostty-pcre2-native-summary.json`。
- ReleaseLocal 应用构建成功，arm64、资源及签名检查通过。一次性符号审计确认最终内部静态库和应用包含 PCRE2 编译/匹配符号，无 Oniguruma 符号。日志：`/private/tmp/cghostty-pcre2-release.log`、`/private/tmp/cghostty-pcre2-app-check.log`。构建仍有此前的两条 Dear ImGui dSYM 符号警告。
- Zig 格式、版本记录、Swift 6 配置、actionlint 和 diff 空白检查通过；依赖记录故障注入再次通过，包括 PCRE2 版本/归档地址不匹配拒绝。本轮未运行远程 CI、完整 Zig 全量测试或真实 tmux/鼠标交互验收，未发布新版本。

## CI 环境记录与依赖版本文档（2026-09-20）

- CI 新增环境报告，记录实际工具版本、SDK 构建号及选定的 runner 元数据；报告进入 Actions 摘要和既有诊断产物，工具安装失败时也尝试采集。
- C/C++ 依赖表由包清单生成，默认检查拒绝文档漂移；新增源码归档 URL 与包版本一致性、ImGui 与 Dear Bindings 版本匹配校验，保留既有生成头检查。Wuffs 记录提交快照，维护状态保留在文档正文。
- 临时副本故障注入通过：7 个依赖的包版本与归档 URL 不一致均被拒绝；ImGui 包版本、绑定目标版本、绑定发布标签与文件名不一致均被拒绝；表格过期、标记缺失及重复均被拒绝。默认检查不写文件，更新仅修改表格、保留人工正文，重复生成逐字节一致，Zig 安装脚本的版本/校验和输出不受文档漂移影响。
- 本机环境报告成功采集全部 14 项命令输出，保存于 `/private/tmp/cghostty-ci-environment.md`。空 PATH 模拟安装失败时仍输出完整报告，全部缺失工具标记为 `Unavailable`，未选中的环境变量不会被导出。SDK 查询在沙盒中附带 Xcode 缓存/文件监听警告，命令仍返回成功及实际版本。
- 版本检查、actionlint、Swift 6 配置检查、macOS/arm64 范围检查和 diff 空白检查通过。本轮仅修改 CI、脚本和维护文档，未重新构建应用、未运行远程 CI、未发布新版本。

## macOS 实现、键码表与彩蛋设施精简（2026-09-20）

- 删除无调用的 `locales_map`、`initGlobalDomain`、`staticLocale` 及专属 gettext 声明/导入；保留域绑定、翻译查询、语言规范化。全部 PO/POT 文件与本轮开始时逐字节相同；最终包内 34 个 `.mo` 的翻译内容逐一与当前 PO 编译结果一致。
- 收拢自有 Zig 代码中的固定 macOS 分支，包括系统工具、输入编码、配置、PTY、进程/线程、Metal 和终端页内存管理。保留构建入口的非 macOS/非 arm64 拒绝检查、配置条件中的系统信息、第三方通用实现及实际使用的字体后端。
- 删除单成员渲染器/运行时枚举和配置传递；直接使用 Metal，保留 CLI 无窗口运行时与原生应用 embedded runtime 的产物区分。Inspector 使用 Metal 初始化状态，保留初始化、重新初始化和关闭流程。内部 C 头文件保持逐字节一致。
- 键码原始表从六列收缩为 USB / macOS / DOM 三列，全部 **243 条**有效记录的值与顺序逐项一致。新增原生键码唯一性测试，保证核心测试也会实例化完整映射表。
- 删除 `+boo` 命令、帧数据模块、C 帧生成器和 235 个原始帧文件。移除 v2/v3 图标草稿、未引用的 `Prompt.svg` 及应用资源目录中未分配的旧 `cghostty.svg`；保留 v4 图标与设计源文件。旧 SVG 引发的 Xcode 资源警告已消除。
- 清理新增的无效平台回退和遗留导入后，当前工作区相对本轮起点删除 **251 个文件**；其中被删除的图标/帧资源共 **6,778,834 字节**。此数字是源码资源体积，不代表压缩后的应用或 Git 历史缩减量。
- 扩大 Zig 定向回归（OS、Command、config、renderer、input、termio、PTY、PageList、page、mem）：**1,162 项通过、1 项跳过**，83/83 构建步骤成功。最终键码/终端构建选项专项回归：**75/75 项通过**。日志：`/private/tmp/cghostty-cleanup2-core-tests.log`、`/private/tmp/cghostty-cleanup2-keycodes-tests.log`。
- Debug 内部框架构建成功；Swift 原生测试 **236 项通过、1 项跳过、0 项失败**，`runtimeWarnings` 为空。结果包：`/private/tmp/cghostty-cleanup2-native-tests.xcresult`；摘要：`/private/tmp/cghostty-cleanup2-native-summary.json`。
- 保留的可选手册和性能工具构建 **106/106 步骤通过**。日志：`/private/tmp/cghostty-cleanup2-maintenance-build.log`。
- ReleaseLocal 应用构建成功；应用身份、arm64、资源、签名检查通过，`+boo` 不出现在帮助中且调用返回无效命令。新旧应用 `+show-config --default` 与 `+list-keybinds --plain` 输出逐字节一致。日志：`/private/tmp/cghostty-cleanup2-release-final.log`、`/private/tmp/cghostty-cleanup2-app-check.log`。
- CI 增加 input / OS / termio / PTY 回归；范围检查保留 macOS/arm64、应用资源、签名以及图标素材和单成员后端文件的范围约束。彩蛋源码、资源和构建引用的删除由本次构建与测试验证，不再保留彩蛋专用的路径断言、帮助输出断言或命令拒绝检查。Zig 格式、修改 Swift 文件的严格 lint、版本记录、Swift 6 配置、actionlint 和 diff 空白检查通过。
- 构建中仍有此前就存在的两条 Dear ImGui dSYM 符号警告（`_ImFontConfig_ImFontConfig`、`_ImGuiStyle_ImGuiStyle`），不影响本轮构建及单元测试通过。本轮未运行完整 Zig 全量测试或手工 GUI/IME/Vim 验收；未更改线上 0.1.1 Release、标签或远程分支。

## 独立仓库旧代码与构建设施清理（2026-09-20）

- GitHub 仓库已由维护者解除 fork 关联；本轮读取 API 确认为 `fork: false`。本轮改动保留在本地工作区，没有修改线上 0.1.1 Release、标签或远程 main。
- 删除无调用的 Git 版本探测、单成员 XCFramework 目标枚举、转发型归档包装和空 `.gitmodules`。内部构建直接使用唯一 macOS arm64 目标，去掉静态库不可能产生的 dSYM、独立 pkg-config 字段和不再适用的跨平台空操作分支。保留当前 Zig/Xcode 必需的归档规范化、compiler-rt 和 libSystem 符号处理。
- 移除无调用的桌面环境探测、旧 macOS 版本查询及悬空的 OpenType 导出；简化桌面启动、pipe 和 URL 打开中的恒定平台分支。保留 `CGHOSTTY_MAC_LAUNCH_SOURCE` 行为以及 OSC 8 拒绝通用 opener 的策略，并将已有 hostname / opener 测试纳入 OS 模块测试入口。
- gettext 直接提取共享命令面板，移除 GTK/Python 中间模板和单输入二次合并，更新目录时清除 obsolete 条目。34 种语言共 5,440 条保留译文逐条一致，移除 2,404 条退役译文；包含模板的 PO/POT 源码从 1,252,074 字节减至 846,744 字节。译者署名保留。
- 翻译生成在独立临时副本中验证：最终流程 **71/71 步骤通过**，再次生成的 34 个目录及 POT 与工作区逐字节一致；全部目录通过 `msgfmt --check`。日志：`/private/tmp/cghostty-cleanup-i18n-final.log`、`/private/tmp/cghostty-cleanup-i18n-verify.log`。
- Zig 定向回归覆盖 OS、Command、config、renderer：**340/340 项通过，88/88 构建步骤通过**。日志：`/private/tmp/cghostty-cleanup-core-tests.log`。
- 重建 Debug 核心后，Swift 原生单元测试 **236 项通过、1 项跳过、0 项失败**，`runtimeWarnings` 为空。结果包：`/private/tmp/cghostty-cleanup-native-tests.xcresult`；日志：`/private/tmp/cghostty-cleanup-native-tests.log`。
- 最终 ReleaseLocal 完整重建成功，应用范围、arm64、资源、签名和 CLI 配置检查通过；包内 34 个 `.mo` 逐一解析后与当前 PO 编译结果相同。日志：`/private/tmp/cghostty-cleanup-release-final.log`、`/private/tmp/cghostty-cleanup-app-check.log`。
- Zig 全范围格式检查、版本检查、Swift 6 构建配置检查、actionlint 和 diff 空白检查通过。没有 Swift 源码修改；本轮未重复图形界面手工验收、未运行完整 Zig 测试全集或 XCTest UI 套件，未重新打包发行 ZIP。

## Swift 6 迁移（2026-09-20）

- 使用 Xcode 27 的 Apple Swift 6.4 编译器，将主应用、Dock 插件、单元测试、UI 测试的全部 **12 个构建配置**统一为 Swift 6 语言模式、完整并发检查与 Swift warnings-as-errors。主应用和单元测试默认 MainActor；UI 测试保留 XCTest 生命周期的非隔离声明，界面操作显式 MainActor。
- UI 定时器、通知/KVO、窗口加载和资源析构明确主线程归属；系统后台通知回调排入主队列。核心 `wakeup_cb` 明确为非隔离 Sendable 回调，后台唤醒后仍在主线程 tick。Cocoa scripting 的同步入口与返回值采用局部桥接和主线程运行时断言。
- App Intents 元数据改为不可变值；输入枚举、颜色与图标编码保持非隔离。终端详情用 Zip 同时订阅标题和路径，保留各自超时回退；拖放异步结果以 Mutex 保护。同步菜单测试移除无效 await 和旧字符串 selector；分屏参数化案例保留全部输入组合。
- 原生单元测试 **236 项通过、0 项失败、1 项跳过**；参数化展开后通过 **355 次执行**，结果包没有 runtime warnings。新增后台唤醒和后台图标编码两项回归。结果包：`macos/build/DerivedData/Logs/Test/Test-Ghostty-2026.09.20_08-21-08-+0800.xcresult`；成功日志：`/private/tmp/cghostty-swift6-test-compile.log`。UI 测试目标通过编译，本轮未执行 XCTest UI 测试套件。
- Debug 原生测试和 ReleaseLocal 完整构建通过，成功日志未发现 Swift 源码警告或错误。Xcode 仍有原有 ImGui 调试符号提示，以及不使用 AppIntents 的目标跳过元数据提取的提示；不将这些工具提示视作 Swift 源码诊断。Release 日志：`/private/tmp/cghostty-swift6-release.log`。
- 独立身份的 ReleaseLocal 副本完成真实运行检查：AppleScript 窗口/标签/终端对象引用、中文 shell 命令输入、键盘事件、鼠标位置/按钮/滚动事件、核心后台输出触发标题更新、新标签、分屏、关闭标签与释放分屏全部通过。使用独立命令行配置，测试副本已退出；Metal API Validation 启用，运行日志未出现隔离断言、崩溃或 Metal 错误。日志：`/private/tmp/cghostty-swift6-runtime-check.log` 和 `/private/tmp/cghostty-swift6-runtime3/app.log`。
- 严格 SwiftLint、版本检查、actionlint、diff 空白检查和应用范围/arm64/资源/签名检查通过。CI 新增 `scripts/check-swift6.py`；临时项目故障注入验证 Swift 5、minimal 并发检查、关闭 warnings-as-errors、取消默认 MainActor、关闭 Approachable Concurrency 均被拒绝。
- 最新本地应用为 `macos/build/ReleaseLocal/cghostty.app`。本轮未改 Zig/C 核心行为，未重复核心回归；下方 C 库记录中的核心测试属于此前验证。未远程运行 GitHub Actions，未重打历史 ZIP，未对外发布。

## C/C++ 依赖更新（2026-09-20）

- 更新 FreeType 2.14.3、libpng 1.6.58、zlib 1.3.2、Oniguruma 6.9.10、HarfBuzz 14.4.0、gettext/libintl 1.0、Highway 1.4.0、simdutf 9.2.0，以及 Dear ImGui 1.92.9b-docking / Dear Bindings 0.21。源码 URL、Zig 内容哈希、生成头文件和版本记录同步更新；来源与再生成方法见 `pkg/README.md`、`pkg/libintl/README.md`。
- simdutf 两个 vendor 文件直接取自官方 singleheader.zip；libpng 使用上游预生成配置。libintl 在 macOS 27 / arm64 重新配置，加入 gnulib 字符串头与 `string.c`，解决新版本 `streq` 的编译与 Debug 链接需求。Inspector 适配 `ImGui_OpenPopup` 的 bool 返回值。
- 默认 Zig 定向回归覆盖 renderer/config/Command/Terminal/font/simd/kitty/tmux/search：**1,645 / 1,645 项通过**，88 / 88 构建步骤成功。日志：`/private/tmp/cghostty-clibs-default-tests.log`。
- 可选 `coretext_freetype` 字体后端：**200 项通过、5 项跳过**；`coretext_harfbuzz`：**197 项通过、7 项跳过**。两者均 93 / 93 构建步骤成功。日志分别为 `/private/tmp/cghostty-clibs-freetype-tests.log` 和 `/private/tmp/cghostty-clibs-harfbuzz-tests.log`。
- 重建核心后，Swift 单元测试 **234 项通过、0 项失败、1 项跳过**；参数化展开后通过 355 次执行。结果包：`/private/tmp/cghostty-clibs-swift-tests.xcresult`。
- 临时 C 程序直接链接本轮 Debug 合并静态库，验证 zlib 压缩往返、libpng RGBA 编解码与截断输入拒绝、FreeType 字形光栅化、Oniguruma 中文匹配、gettext 中文目录查询、ImGui 绑定数据布局与上下文创建，全部通过。翻译测试显式设置 `LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8`。程序源码保存在 `/private/tmp/cghostty-clibs-smoke.c`。
- `check-versions.py` 新增 libpng 与 libintl 生成文件校验；临时副本故障注入确认 libpng 旧配置、libintl 旧配置和两个旧公开头均被拒绝。Zig 格式和 diff 空白检查通过。
- ReleaseLocal 完整构建及 `check-scope.py --app` 通过，更新后的应用位于 `macos/build/ReleaseLocal/cghostty.app`。日志：`/private/tmp/cghostty-clibs-release.log`。
- Wuffs 保留原有生成源码快照，未更换正则引擎；Oniguruma 原上游已归档，6.9.10 为其最终发布版本。本轮未重新生成历史 ZIP、未运行远程 CI 或界面交互验收、未对外发布。

## 兼容层、版本记录与 CI 整理（2026-09-20）

- 删除旧系统 Backport、Ventura 标签栏类和 XIB，以及 macOS 27 基线下恒定的系统版本/旧编译器分支。搜索框保留字符串选区与 `TextSelection` 的绑定转换，Glass 改用原生类型，现有标签切换修复继续保留。
- simdutf 包清单由 5.2.8 校正为内置源码的 9.0.0；未更换第三方源码。Zig 0.16.0 版本与归档 SHA-256 集中管理，安装脚本和 CI 读取同一记录。
- CI 加入 Zig 格式、严格 SwiftLint、版本记录和 actionlint 检查；Actions 固定提交 SHA，缓存键纳入 SDK 和工具链。失败时也尝试保存构建日志和 `.xcresult`，与发行包分开上传。
- Zig 核心重建通过；CI 合并过滤器命令覆盖 renderer/config/Command/Terminal，**760 / 760 项通过**，88 / 88 构建步骤成功。该次沙盒运行的标准错误包含系统 XPC 连接警告，命令退出码为 0。
- Swift 单元测试 **234 项通过、0 项失败、1 项跳过**；参数化展开后通过 355 次执行。首次沙盒构建受系统服务访问限制而失败，随后在沙盒外重跑通过；成功结果包为 `/private/tmp/cghostty-modernize-verified-tests.xcresult`。
- `zig fmt --check`、严格 SwiftLint、actionlint 1.7.12、脚本语法和 diff 空白检查通过。临时副本中的故障注入确认：Zig 版本不匹配、simdutf 记录不匹配、无效 SHA-256 均被拒绝；非测试动作使用 `--result-bundle` 也被拒绝。
- ReleaseLocal 完整构建及 `check-scope.py --app` 通过：arm64、身份、资源与签名均符合要求；实际应用资源中已无 Ventura nib，保留当前 Tahoe 标签栏 nib。
- 本轮更新了本地应用，未重新生成下方历史 ZIP；未远程运行 GitHub Actions，未进行界面交互验收或对外发布。

## 应用图标更新（2026-09-20）

- 采用圆润、立体的白色小幽灵：chevron 眨眼、薄荷绿吐舌微笑、挥手与小卷尾巴。最终原画及提示词保存在 `images/cghostty-icon-v4/`。
- 已同步 Icon Composer 文档和 Dock 插件使用的 AppIconImage。原方案文件保留，v2/v3 目录为历史设计稿。
- 验证 macOS 原生 1024px、512px、64px 图标导出；从实际构建的 `cghostty.icns` 解出图像检查新图标确实进入应用。
- ReleaseLocal 构建、应用范围/签名检查、ZIP 完整性和 SHA-256 检查通过。本轮仅更新图标资源，无运行时代码改动，未重复执行单元测试。

## Vim 光标修复追加验证（2026-09-20）

- 方块、细线和下划线光标均支持 smooth；细线按字符格宽度计时，非方块光标在文字之后绘制且不改写文字颜色。
- 连续移动按逻辑输入步长计时，尾端只消耗剩余延迟，避免重复等待与滞后距离造成的时长膨胀。单次移动的原时长和曲线保持不变，中断时两个端点位置连续。
- 定向 Zig 回归 **294 / 294** 通过；新增细线模式切换，以及每 8/16/33ms 连续移动 500 次的尾端进度与长度回归。
- ReleaseLocal 应用和原生 MSL 编译通过；应用范围、arm64、资源与签名检查通过。
- 使用独立 Bundle ID 的最新构建副本运行 macOS 自带 Vim 9.1，临时配置显式设置 normal 方块和 insert 细线。上下往返定时测试实际执行 1,726 步，观察未形成持续积累的多行长拖尾；insert 模式持续输入和返回 normal 模式通过界面检查。Metal API / GPU 校验未报告错误。
- 本轮只修改 Zig/MSL 及文档，未重新运行 Swift 单元测试；下方 234 项 Swift 结果属于上一轮 Metal 4 迁移验证。

## Metal 4 迁移验证

- Zig 渲染器与配置回归：**292 / 292** 通过。包含原光标时长与距离分档、曲线单调性、中断时两个端点的位置连续、尾端收拢、尺寸变化重置，以及旧 GLSL 配置的迁移诊断。
- Swift 单元测试：**234 项通过、0 项失败、1 项跳过**（xcresult 汇总；参数化用例有多次执行）。跳过项是原有默认禁用的手动基准。原生应用测试使用 Debug 配置。
- 原生 MSL 4.1 着色器编译、Debug 核心与 Swift 应用编译通过。
- macOS 27 上以 `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` 启动 ReleaseLocal 应用，确认 Metal API 与 GPU 校验启用。
- 最终 ReleaseLocal 独立进程正常读取迁移后的个人配置并启动 shell/display link；进程采样确认调用 `IOGPUMetal4CommandBuffer` / `MTL4CommandAllocator` 路径，主线程正常等待 AppKit 事件。
- 将最终 ReleaseLocal 复制为独立 Bundle ID 的验收副本（仅重新签名，编译 UUID 相同），避免同路径旧进程干扰；解锁后完成连续改向、中文/彩色文字、光标形状回退、字体缩放、分屏与拖动分屏大小的界面验收，对应进程未出现 Metal API/GPU 校验错误或 GPU 提交错误。
- 源码范围检查通过；Xcode 的应用、项目、测试与插件目标统一为 macOS 27，入口拒绝其他平台、Intel Mac 和已移除产物选项。
- 修改的 Swift 文件通过严格 SwiftLint，Zig 格式和 diff 空白检查通过。
- 本机 cghostty 配置迁移到 `cursor-effect = smooth`，删除两个旧 GLSL 配置项；迁移前备份为 `config.ghostty.pre-native-cursor-20260920`。原 Ghostty 配置与参考 GLSL 文件未改动。

- 最终 ReleaseLocal 完整构建、应用范围/架构/资源/签名检查、个人配置校验、ZIP 完整性与 SHA-256 校验通过。交付包约 20 MiB。

## 产物

- `macos/build/ReleaseLocal/cghostty.app`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip.sha256`

产物和本地构建缓存被 Git 忽略。ZIP SHA-256：`67ed2f8cbd0be778e13db5037d8720ef28a7a16d2c4860a8d0679c2fedb52698`。

## 验证边界

未运行完整 Zig 测试全集或 macOS UI 自动测试；本轮使用上述定向回归、运行检查与原生界面验收。界面检查使用独立身份的最终构建副本，避免同路径旧实例影响窗口定位；不将早先实例不明确的观察计入最终结果。未测量功耗、端到端输入延迟或实际帧率，不声称固定 120 Hz。

运动中断保证两个端点的位置连续，新一段继续使用原曲线；不保证中断时速度连续。特效目前仅为内置 smooth 光标，不加载外部 GLSL/MSL，不包含 CRT。系统 Reduce Motion 在渲染时关闭特效，但本轮未修改用户的系统辅助功能设置进行手工验收。

首次窗口建立 display link 曾暂时回退，随后成功建立 display link。发布构建的 ImGui 调试符号告警不影响构建结果。应用使用 ad-hoc 签名；没有执行 Developer ID 公证或对外发布。GitHub `xcode-27` 工作流已更新但未远程运行。未创建 PR、Issue 或 Git commit。
