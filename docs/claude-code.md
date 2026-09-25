# Claude Code 兼容模式

## 配置开关（0.3.0 起）

通过 Settings（⌘,）打开配置文件，在“Claude 兼容模式”一节设置：

```ini
claude-compatibility = true
```

默认是 `false`。保存后退出并重新启动 cghostty，再直接输入 `claude` 或 `claude --resume`。无需手工修改 shell 配置。旧模板会在通过 Settings 打开时先备份，再追加缺少的选项说明；已有设置和注释保持原样。追加的示例是注释，不会自动开启功能。

设回 `false` 并重启应用即可关闭。旧终端进程中已经创建的函数不会因编辑文件而立即改变。

## 工作方式

cghostty 本身支持 ConEmu OSC `9;4` 进度报告。检查本机 Claude Code 2.1.282 时，其本地进度能力检测只接受部分终端名称，其中要求 `TERM_PROGRAM=ghostty` 且 `TERM_PROGRAM_VERSION >= 1.2.0`。cghostty 的独立名称和版本未通过该白名单。

开关启用后，shell 集成为 `claude` 添加启动包装，相当于：

```sh
env TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.2.0 claude
```

`1.2.0` 是通过能力检测的兼容值，不是应用的实际版本。Claude 及其启动的子进程继承该环境；外层 shell、其他独立启动的程序和 cghostty 的身份保持原样。参数与退出码正常传递，不修改 `TERM` 或用户 dotfiles。

## 适用范围

- 依赖集成的交互式 zsh、Bash、fish、Nushell 或 Elvish；默认 `shell-integration = detect`。禁用集成或使用不支持注入的启动方式时，请使用上面的单次启动命令。
- zsh、Bash、fish 中已有的 `claude` alias／函数优先，不会被覆盖。若用户之前安装过自己的包装，需要自行合并或移除它。关闭本配置也不会删除用户自己的包装。
- 通过绝对路径调用 Claude，或显式绕过 shell 函数，不会使用该包装。tmux、SSH、远程会话会改变环境或集成加载方式，需在相应会话单独确认。
- `progress-style = false` 会禁止显示进度条，即使 Claude 兼容模式已开启。
- 此兼容值用于已检查的 Claude 版本，后续版本的能力检测可能变化。

## 验证顶部蓝条

在 cghostty 的交互式 shell 中直接显示不定进度条：

```sh
printf '\033]9;4;3\007'
```

清除：

```sh
printf '\033]9;4;0\007'
```

随后启动 Claude，在真实任务处理中观察顶部蓝条。空闲或仅运行 `--version` 不会展示任务进度。直接指令测试只证明终端显示链路正常，不能替代真实 Claude 会话验收。

原生端会在最后一次进度报告后 15 秒清除状态，持续显示需要应用继续发送进度报告。
