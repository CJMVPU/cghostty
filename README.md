# cghostty

基于 [Ghostty](https://github.com/ghostty-org/ghostty) 独立维护的原生 macOS 终端

**macOS 27+ · Apple Silicon · SwiftUI · Metal 4**

[下载安装](https://github.com/CJMVPU/cghostty/releases) · [开发指南](HACKING.md) · [架构说明](ARCHITECTURE.md)

## 功能

- **窗口**：多窗口、原生标签页、分屏、窗口恢复、快速终端
- **交互**：终端搜索、命令面板、自定义快捷键、shell 集成、AppleScript
- **显示**：主题、透明背景、平滑光标、Metal 渲染
- **设置**：独立深色窗口、分类搜索、输入校验、内部存储、旧配置迁移与恢复默认设置

## 默认设置

| 项目 | 默认值 |
| --- | --- |
| 字体 | 内置 LXGW WenKai Mono Medium |
| 字号 | 16 pt |
| 新窗口 | 157 列 × 43 行 |
| 平滑光标 | 开启 |

- 内置 Nerd Font 符号，Emoji 优先使用系统 Apple Color Emoji
- 粗体、斜体和粗斜体遵循 `font-synthetic-style` 合成规则
- 用户配置优先；屏幕空间不足时约束实际尺寸

## 安装

1. 从 [Releases](https://github.com/CJMVPU/cghostty/releases) 下载 `cghostty-<版本>-macos-arm64.zip`
2. 解压，将 `cghostty.app` 拖入“应用程序”并启动

- **更新**：应用内“检查更新”打开 Releases，手动下载并替换
- **签名**：默认打包使用 ad-hoc 签名，具体签名及公证状态以发布说明为准
- **平台**：仅支持 macOS 27+、Apple Silicon

## 配置

### 入口

应用菜单 **Settings…** 或 **⌘,** 打开独立的深色设置窗口。重复打开会回到同一个窗口，分类和窗口位置会被记住。

- 日常设置全部在 UI 内完成，无需维护独立配置文件
- 设置页不显示右侧滚动条，仍支持鼠标滚轮和触控板滚动
- 界面使用内置 **LXGW WenKai Mono · 16 pt · 加厚开启 · 强度 255**，不受终端字体设置影响
- 设置名称、说明、按钮和提示统一使用英文；支持英文名称及原始设置关键字搜索，搜索框聚焦时不显示高亮边框
- 类型和枚举选项来自核心定义；少量固定选项与名称在同一行使用按钮选择，不显示逐项默认提示；底部保留 **Restore Defaults**
- 窗口宽高、字号、透明度等数值，以及颜色和间距等短值输入框与名称同行，说明和错误提示显示在下方
- 字体使用可输入名称查找的下拉框，支持按顺序添加或移除后备字体，并保留已配置但未安装的字体
- 主字体下拉框顶部预设为 `default:LXGW WenKai Mono:medium:thickened`；选择时使用内置 Medium 字体、开启加厚并设强度为 255，保留后备字体。预设仅在这些参数匹配时显示为当前值
- 保存前校验所有修改和完整设置，错误显示在字段下方；保存失败保留草稿
- 设置由应用内部存储，包含上次成功设置；写入使用原子替换，并拒绝覆盖其他应用实例已保存的修改
- 首次启动会导入旧 `config.ghostty` 及其引用配置的内容，核对导入前后的有效值；成功后不再读取这些旧配置文件。旧文件原样保留，主题、图片等外部资源仍需存在
- 未安装系统字体也可以显示设置界面，使用与终端相同的嵌入字体数据
- 命令面板保留内置操作，不再提供 `command-palette-entry` 自定义条目配置
- 终端调色板由主题提供；个人配置和命令行不再支持 `palette` 手动覆盖

### 分类

设置按八类组织；`config-file` 和 `config-default-files` 不出现在 UI 中，配置存储由应用管理：

1. General
2. Appearance
3. Windows
4. Quick Terminal
5. Input
6. Terminal
7. Security
8. Advanced

### 修改与生效

在设置窗口修改后点击 **Save**，重启应用后生效。当前终端使用启动时的设置；自动热重载尚未接入。下方键值示例用于说明设置含义：

```ini
# 自定义字号；内置默认值为 16
font-size = 18

# 关闭平滑光标
cursor-effect = false
```

光标动画保留原有开关，并提供两种方案，默认使用 `responsive`：

```ini
cursor-effect = true
cursor-effect-mode = responsive
```

| `cursor-effect-mode` | 主体移动 | 尾迹 | 膨胀恢复 |
| --- | --- | --- | --- |
| `responsive`（默认） | 单次按距离使用 24～160ms；连续移动逐渐加速 | 固定 40ms，原有不透明尾迹 | 80ms |
| `instant` | 立即落在真实位置 | 40ms 内淡出，最高 35% 不透明度 | 80ms |

两种方案都保留最大 12% 膨胀和原有光标形状过渡。`instant` 的尾迹按时间保留，不限制跨屏连接的长度，也不会因频繁折返清除旧轨迹；只记录实际提交的显示位置。恢复时间指膨胀保持阶段结束后的收拢时间，不是从最后一次按键起计的总时长。`cursor-effect = false` 对两种方案均有效；保存配置后重启应用生效。

`responsive` 自动优化连续操作，无需额外配置：目标更新间隔不超过 120ms 时，约 300ms 内逐渐提高追赶倍率，最高 2.5 倍，主体移动时长最低仍为 24ms。长跳的时长在充分加速后可缩短到约 64ms；尾迹及膨胀参数保持各方案的设置。横纵方向分别处理转向，例如 Vim 在长短行间上下移动时，横向折返不会清掉仍然正确的纵向速度。停止输入后保留最后一段的速度衔接和到达时间，平滑减速到位；下一次独立跳转恢复正常时长。普通重绘不会触发加速，`instant` 不使用此机制。

终端历史滚动和支持区域滚动指令的 TUI 默认启用平滑滚动：

```ini
smooth-scroll = true
```

触控板跟随像素位移，沿用系统惯性；普通滚轮使用约 100ms 的连续过渡。连续输入或反向滚动从上一帧显示的位置继续。Neovim 开启鼠标支持（`set mouse=a`）后，其明确的区域滚动指令也会获得过渡，区域外的状态栏和分屏保持原位。整屏重画、重叠的复杂滚动区域、超过一屏的跳转，以及覆盖文字上层的 Kitty 图片会使用普通刷新；系统“减少动态效果”也会关闭滚动过渡。设置 `smooth-scroll = false` 可关闭。

动画帧复用 GPU 内容纹理，不重新排版文字；每个可见终端最多按需缓存三张内容纹理，隐藏窗口时释放。同步输出（mode 2026）保留完整帧边界，并按脏行采集、合并快照；稳定视口不再因进入或退出同步而强制整屏复制和重建。尺寸、屏幕和整个视口变化仍按需完整更新。

- **生效时机**：退出并重新启动应用
- **运行期间**：新窗口、标签页和分屏沿用启动配置
- **默认字体**：`font-family` 未指定时使用应用 Resources 中的 LXGW WenKai Mono Medium；粗体与斜体由渲染器合成
- **模板注释**：无需全部启用；示例值不等于默认值

### 固定窗口尺寸

普通终端窗口按启动配置固定内容区域尺寸，默认 `window-width = 157` 列、`window-height = 43` 行。
修改配置后重启应用生效；新窗口、恢复窗口和拖出分屏创建的窗口使用同一启动尺寸，历史窗口尺寸不会覆盖配置。
任一维度设为 `0` 时使用固定的 800×600 点内容区域。

窗口可以移动、最小化和关闭，不支持手动缩放、最大化、全屏或系统平铺；`maximize`、`fullscreen` 仅保留配置兼容，不再生效。
分屏创建、关闭、移动、比例调整和字号快捷键保留，但不改变外部窗口尺寸。
跨屏时仍更新渲染像素尺寸，显示区域不足时将窗口约束到屏幕范围。
Quick Terminal 使用启动时的 `quick-terminal-size`，不恢复过去手动调整的尺寸。

### 窗口级 Metal 合成器

每个窗口使用一个 CAMetalLayer、一个 CAMetalDisplayLink 和一个呈现线程。
分屏绘制到各自的缓存纹理，再通过同一条 Metal 4 队列合成为一个 drawable；没有变化的分屏复用缓存。
这是唯一的呈现路径，不保留旧后端或自动回退。

IO 唤醒登记待更新，窗口帧回调统一读取各分屏状态，每帧每分屏最多更新一次。
输入法、鼠标、无障碍、搜索栏和滚动条仍由原生视图负责。每分屏的辅助线程暂时保留，
负责消息、动画定时器和滚动历史压缩；光标和平滑滚动仍在分屏渲染器内绘制。

```ini
render-frame-latency = 1
```

该配置只接受 `1` 或 `2`，重启后生效；它表示帧调度偏好，并非按键到屏幕的延迟保证。
动画按预计显示时刻取样，实际上屏反馈写入 render-trace；空闲暂停，刷新率由系统决定。
缩略图按需绘制到独立的共享 Metal 纹理并读回像素，不使用 IOSurface，也不占用窗口 drawable。

`render-presentation` 和 `window-vsync` 已删除，旧配置中的这两项需要移除。
验证与当前边界见[唯一窗口合成器验证](docs/validation/2026-09-27-compositor-only.md)。

### 校验与恢复

| 情况 | 行为 |
| --- | --- |
| 输入非法值 | 字段提示错误、禁用保存，保留草稿和现有设置 |
| 保存成功 | 原子保存到应用内部，重启后生效 |
| 内部设置损坏但可解析 | 整份回退到上次成功设置，错误值可在 UI 修正 |
| 没有可用恢复数据 | 使用内置默认值并提示错误，保留原数据 |
| 另一个应用实例已保存修改 | 拒绝覆盖，提示重新读取 |
| 选择 **Restore Default Settings…** | 确认后备份内部设置、恢复内置默认值，重启生效 |

关闭窗口或退出应用时，未保存的修改会触发保存／放弃／继续编辑提示。

### 配置优先级

- 覆盖顺序：内置默认值 → 主题及迁入的旧设置 → UI 保存的修改 → 显式启动参数
- 列表在 UI 中每行一个值；编辑后整体替换该设置的旧列表，其他设置保持原样
- 单项“默认”恢复核心默认值；主题提供的继承值继续遵循主题规则
- 自定义主题目录：`~/Library/Application Support/com.cjmvpu.cghostty/themes/`

### 命令行

`+edit-config` 现在只提示打开原生设置窗口，不再创建配置文件或启动外部编辑器。

```sh
CGHOSTTY="/Applications/cghostty.app/Contents/MacOS/cghostty"

# 导出精简的中英文模板，不读取或改写当前用户配置。
"$CGHOSTTY" +show-config --template --no-pager > config-template.ghostty

# 查看默认配置与英文说明。
"$CGHOSTTY" +show-config --default --docs --no-pager

# 校验应用内部保存的设置（未迁移时兼容旧配置）。
"$CGHOSTTY" +validate-config

# 校验指定文件。
"$CGHOSTTY" +validate-config --config-file="/absolute/path/config.ghostty"
```

### Claude Code 顶部进度条

Claude Code 根据终端名称和版本决定是否发送进度指令。在设置窗口搜索并开启以下选项：

```ini
claude-compatibility = true
```

保存并重启应用后，直接运行 `claude`。默认关闭，需要 Shell 集成；原生进度条需要 `progress-style = true`（默认值）。兼容标识仅由 Claude 及其子进程继承，外层 shell 和应用版本保持原样。详情见 [Claude Code 兼容说明](docs/claude-code.md)。

## 构建

**环境**：macOS 27+、Apple Silicon、Xcode 27+、Python 3、Homebrew

在仓库根目录执行：

```sh
brew install nushell
xcodebuild -downloadComponent MetalToolchain

cghostty_zig_bin="$(bash scripts/install-zig.sh)"
export PATH="$cghostty_zig_bin:$PATH"

nu macos/build.nu --configuration ReleaseLocal
```

- **Zig**：由仓库安装脚本下载锁定版本并校验
- **产物**：`macos/build/ReleaseLocal/cghostty.app`
- **测试与检查**：[HACKING.md](HACKING.md)
- **打包与签名**：[PACKAGING.md](PACKAGING.md)

## 项目结构

| 目录 | 职责 |
| --- | --- |
| `macos/` | SwiftUI 界面、Observation 状态、AppKit 系统交互及原生测试 |
| `src/` | Zig 终端核心、配置、IO、搜索、字体与渲染 |
| `include/` | 内部 GhosttyKit C 桥接 |
| `pkg/` | 第三方依赖与构建适配 |
| `scripts/` | 工具链安装与项目检查 |

[核心架构](ARCHITECTURE.md) · [原生 UI 架构](UI_ARCHITECTURE.md) · [支持范围](SCOPE.md)

## 许可

- **应用**：[MIT](LICENSE)，保留 Ghostty 上游版权声明
- **默认字体**：[LXGW WenKai Mono](https://github.com/lxgw/LxgwWenKai)，采用 SIL OFL 1.1；许可及版权说明随应用提供
- **其他依赖**：遵循各自许可，见 [pkg/README.md](pkg/README.md)
