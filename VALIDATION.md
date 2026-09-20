# 本地交付验证

日期：2026-09-20。环境：Apple Silicon macOS 27.0（26A428）、Zig 0.16.0、Xcode 27、Nushell 0.115.1、SwiftLint 0.65.1。

本轮将交付基线提高为 macOS 27+、arm64、Metal 4 命令 API 与 MSL 4.1。此记录替代此前 macOS 13 部署目标的验证记录。

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
- CI 增加 input / OS / termio / PTY 回归；范围检查防止删除的彩蛋设施、图标素材和单成员后端文件重新进入项目。Zig 格式、修改 Swift 文件的严格 lint、版本记录、Swift 6 配置、actionlint 和 diff 空白检查通过。
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
