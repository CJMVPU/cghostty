# cghostty

基于 [Ghostty] 独立维护的 macOS 终端。
仅支持 **macOS 27+ 和 Apple Silicon**。

## 功能

- Swift 原生界面，支持窗口、标签页、分屏和快速终端
- Zig 终端核心、Metal 4 渲染和 CoreText 字体
- 内置平滑光标，支持方块、细线和下划线
- 支持终端搜索、主题、shell 集成和 AppleScript
- 使用独立配置目录；检查更新时打开本仓库 Releases

## 安装

在 [Releases] 下载 `cghostty-<版本>-macos-arm64.zip`
解压后，将 `cghostty.app` 拖入“应用程序”

本地打包默认采用 ad-hoc 签名，未经 Apple 公证。
签名和公证方法见 [PACKAGING.md]。

## 配置

默认用户配置只有一个入口：

```text
~/Library/Application Support/com.cjmvpu.cghostty/config.ghostty
```

文件不存在或为空时使用内置默认值，启动不会自动生成文件。主动打开 Settings 或执行 `+edit-config` 时，生成带中英文说明、默认值和示例的八类配置模板；只需取消需要修改的示例行前的 `#` 并填写自己的值。菜单与配置编辑命令均使用同一路径。显式指定的 `--config-file` 和文件中的 `config-file` 引用仍然有效；主题资源的查找目录保持原样。

模板包含常规、外观、窗口与分屏、快捷终端、输入与快捷键、终端行为、通知与安全、高级八类，共 **171 个可编辑配置项**。默认值及枚举选项直接来自当前配置模型，全部以注释展示，不覆盖主题或用户设置。已存在的文件首次打开时，先备份到同目录的 `config.ghostty.before-guide-<标识>.bak`，再追加说明；保留原有内容、重复项顺序和符号链接。已有模板不会反复追加或改写。模板头标明生成版本，恢复默认时会生成当前版本的模板。

默认字体已经随应用内置：LXGW WenKai Mono 1.522（常规字形内置，粗体、斜体和粗斜体按 `font-synthetic-style` 合成），并附带 Nerd Font 符号，无需另外安装。`font-family` 留空时使用内置字体；模板中的 `Menlo` 是切换字体的示例，不是默认值。中文等缺失字符由 macOS 字体回退补齐，Emoji 优先使用系统 Apple Color Emoji。默认字号为 **16 pt**，新窗口初始网格为 **144 列 × 33 行**。已有字体、字号或窗口尺寸配置仍优先于默认值；恢复的窗口及屏幕可用尺寸也可能影响实际窗口大小。字体采用 [SIL OFL 1.1](https://github.com/lxgw/LxgwWenKai/blob/v1.522/OFL.txt)，完整版权声明与许可原样保存在应用的 `Contents/Resources/cghostty/licenses/LXGW-WenKai-OFL.txt`。

通过应用菜单的 **Settings…**（⌘,）打开配置文件。修改只在**退出并重新启动应用**后生效；打开新窗口、标签页或分屏不会重新读取用户配置，也不提供手动热重载入口。旧配置中显式绑定 `reload_config` 的行应删除，该用户动作已移除；内部深浅色条件切换继续复用启动配置。

启动时先检查主配置文件的大小、时间和文件身份。同一构建且文件未改变时，使用上次成功保存的文件内容重建配置；文件改变或应用构建变化时重新读取。新配置校验失败时，整份回退到上一次成功配置，并在配置错误窗口显示具体错误；没有可用快照时使用内置默认值。错误文件保留原样，便于修正。快照保存的是主文件，显式引用文件和主题资源仍在启动时重新校验，不是外部资源的完整备份。

应用菜单的 **Restore Default Settings…** 会先将当前文件备份到同目录的 `.config-state/before-reset-<标识>.ghostty`，再用只有注释的当前模板替换用户覆盖，并将成功快照更新为默认状态；重启后生效，当前终端继续运行。`.config-state/last-success.json` 是自动管理的恢复数据，不是另一个需要编辑的配置文件。

旧版 XDG 目录及无扩展名 `config` 文件不再自动读取。已有多文件配置应先备份，按原顺序（XDG `config` → XDG `config.ghostty` → Application Support `config` → Application Support `config.ghostty`）整理后再切换。重复项、清空操作及相对资源路径会影响结果，不能简单按字段去重；移动文件时需调整相对路径。使用新版本的 `+validate-config --config-file=<绝对路径>` 校验候选文件后，再替换目标文件。

平滑光标默认开启：

```ini
cursor-effect = true
window-vsync = true
```

基于 [MIT 许可](LICENSE)，保留上游版权声明

[Ghostty]: https://github.com/ghostty-org/ghostty
[Releases]: https://github.com/CJMVPU/cghostty/releases
[PACKAGING.md]: PACKAGING.md
[ARCHITECTURE.md]: ARCHITECTURE.md
[HACKING.md]: HACKING.md
[SCOPE.md]: SCOPE.md
[VALIDATION.md]: VALIDATION.md
