# cghostty 0.3.0

新增 Claude Code 兼容模式，修复 tmux 控制模式的内存生命周期问题，并同步终端和字体缓存优化。
构建号为 20。

## Claude Code 兼容模式

- Settings（⌘,）配置模板新增“Claude 兼容模式”，设置 `claude-compatibility = true` 后重启应用即可启用，默认关闭。
- 集成 shell 在启动 `claude` 时设置兼容的终端名称与版本，让已验证版本的 Claude Code 能发送顶部任务进度报告；外层 shell 保留 cghostty 的身份。
- 无需修改 shell 配置文件；依赖 shell 集成和已开启的 `progress-style`。详细适用范围见 [Claude Code 说明](docs/claude-code.md)。
- 打开旧配置模板时，先备份再补充缺少的选项说明，保留现有设置和注释，重复打开不会重复追加。

## 修复与优化

- 修复 `tmux -CC` 的窗口列表事件引用已释放内存的问题，并避免日志格式化读取完整窗口结构。
- 批量处理 DEC 特殊图形及英国字符集文本，减少逐字符处理开销。
- 将 glyph 和 codepoint 字体缓存键紧凑存储为 64 位，降低缓存查找开销。

现有配置保持有效，Claude 兼容模式需要手动开启。支持 macOS 27+，仅提供 Apple Silicon（arm64）版本。
