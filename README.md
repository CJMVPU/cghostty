# cghostty

基于 [Ghostty](https://github.com/ghostty-org/ghostty) 独立维护的原生 macOS 终端

**macOS 27+ · Apple Silicon · SwiftUI · Metal 4**

[下载安装](https://github.com/CJMVPU/cghostty/releases) · [开发指南](HACKING.md) · [架构说明](ARCHITECTURE.md)

## 功能

- **窗口**：多窗口、原生标签页、分屏、窗口恢复、快速终端
- **交互**：终端搜索、命令面板、自定义快捷键、shell 集成、AppleScript
- **显示**：主题、透明背景、平滑光标、Metal 渲染
- **配置**：中英文配置模板、启动校验、成功快照、恢复默认设置

## 默认设置

| 项目 | 默认值 |
| --- | --- |
| 字体 | 内置 LXGW WenKai Mono Medium |
| 字号 | 16 pt |
| 新窗口 | 133 列 × 33 行 |
| 平滑光标 | 开启 |

- 内置 Nerd Font 符号，Emoji 优先使用系统 Apple Color Emoji
- 粗体、斜体和粗斜体遵循 `font-synthetic-style` 合成规则
- 用户配置优先；窗口恢复和屏幕空间可能影响实际尺寸

## 安装

1. 从 [Releases](https://github.com/CJMVPU/cghostty/releases) 下载 `cghostty-<版本>-macos-arm64.zip`
2. 解压，将 `cghostty.app` 拖入“应用程序”并启动

- **更新**：应用内“检查更新”打开 Releases，手动下载并替换
- **签名**：默认打包使用 ad-hoc 签名，具体签名及公证状态以发布说明为准
- **平台**：仅支持 macOS 27+、Apple Silicon

## 配置

### 入口

应用菜单 **Settings…** 或 **⌘,** 打开配置文件：

```text
~/Library/Application Support/com.cjmvpu.cghostty/config.ghostty
```

- 文件缺失或为空时，使用内置默认值
- 主动打开配置时，生成带中英文名称、默认值和示例的模板
- 现有配置首次加入模板前自动备份，保留原有内容
- 模板开头分为中文、英文两段；每项只保留名称、默认值和示例，枚举可选值并入默认行
- `keybind` 的完整默认列表放在末尾附录
- 命令面板保留内置操作，不再提供 `command-palette-entry` 自定义条目配置
- 终端调色板由主题提供；个人配置和命令行不再支持 `palette` 手动覆盖
- 已有配置按原有规则保留，只补充缺少的配置项；可先导出新模板对照整理，避免重置有效设置

### 分类

模板包含 **176 个可编辑配置项**，按八类组织：

1. 常规
2. 外观
3. 窗口与分屏
4. 快捷终端
5. 输入与快捷键
6. 终端行为
7. 通知与安全
8. 高级

### 修改与生效

只取消需要修改的示例行前的 `#`，填写数值后保存：

```ini
# 自定义字号；内置默认值为 16
font-size = 18

# 关闭平滑光标
cursor-effect = false
```

光标动画保留原有开关，并提供三种方案，默认使用 `classic`：

```ini
cursor-effect = true
cursor-effect-mode = classic
```

| `cursor-effect-mode` | 主体移动 | 尾迹 | 膨胀恢复 |
| --- | --- | --- | --- |
| `classic`（默认） | 单次按距离使用 24～200ms；连续移动逐渐加速 | 40～60ms，原有不透明尾迹 | 100ms |
| `responsive` | 单次按距离使用 24～160ms；连续移动逐渐加速 | 固定 40ms，原有不透明尾迹 | 80ms |
| `instant` | 立即落在真实位置 | 40ms 内淡出，最高 35% 不透明度 | 80ms |

三种方案都保留最大 12% 膨胀和原有光标形状过渡。`instant` 的尾迹按时间保留，不限制跨屏连接的长度，也不会因频繁折返清除旧轨迹；只记录实际提交的显示位置。恢复时间指膨胀保持阶段结束后的收拢时间，不是从最后一次按键起计的总时长。`cursor-effect = false` 对三种方案均有效；保存配置后重启应用生效。

`classic` 和 `responsive` 自动优化连续操作，无需额外配置：目标更新间隔不超过 120ms 时，约 300ms 内逐渐提高追赶倍率，最高 2.5 倍，主体移动时长最低仍为 24ms。长跳的时长在充分加速后分别可缩短到约 80ms 和 64ms；尾迹及膨胀参数保持各方案的设置。横纵方向分别处理转向，例如 Vim 在长短行间上下移动时，横向折返不会清掉仍然正确的纵向速度。停止输入后保留最后一段的速度衔接和到达时间，平滑减速到位；下一次独立跳转恢复正常时长。普通重绘不会触发加速，`instant` 不使用此机制。

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

### 校验与恢复

| 情况 | 行为 |
| --- | --- |
| 新配置有效 | 启动时应用并保存成功快照 |
| 新配置有误 | 显示错误窗口，整份回退到上次成功配置 |
| 没有可用快照 | 使用内置默认值，保留错误文件 |
| 选择 **Restore Default Settings…** | 确认后备份当前配置、恢复默认模板，重启生效 |

成功快照只保存主文件；引用的配置和主题资源仍需有效

### 配置优先级

- 普通单值：后写的有效值覆盖前值；`#` 注释中的默认值和示例不参与加载
- 覆盖顺序：内置默认值 → 主题 → 主配置 → 启动参数 → `config-file` 引用文件
- 字体列表、调色板、快捷键等按各自的追加／替换规则处理，详见配置注释
- 自定义主题目录：`~/Library/Application Support/com.cjmvpu.cghostty/themes/`

### 命令行

```sh
CGHOSTTY="/Applications/cghostty.app/Contents/MacOS/cghostty"

# 导出精简的中英文模板，不读取或改写当前用户配置。
"$CGHOSTTY" +show-config --template --no-pager > config-template.ghostty

# 查看默认配置与英文说明。
"$CGHOSTTY" +show-config --default --docs --no-pager

# 校验用户配置。
"$CGHOSTTY" +validate-config

# 校验指定文件。
"$CGHOSTTY" +validate-config --config-file="/absolute/path/config.ghostty"
```

### Claude Code 顶部进度条

Claude Code 根据终端名称和版本决定是否发送进度指令。0.3.0 起，在配置文件中开启：

```ini
claude-compatibility = true
```

保存并重启应用后，直接运行 `claude`。默认关闭，需要 Shell 集成；原生进度条需要 `progress-style = true`（默认值）。打开 Settings 时，旧模板会备份并追加缺少的选项说明，保留已有设置。兼容标识仅由 Claude 及其子进程继承，外层 shell 和应用版本保持原样。详情见 [Claude Code 兼容说明](docs/claude-code.md)。

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
