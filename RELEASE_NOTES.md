# cghostty 0.2.0

本次更新统一配置文件入口与生效规则，加入中英文配置模板、成功快照和恢复默认设置，
同时清理当前 macOS 产品不再使用的配置及兼容逻辑。

## 默认字体与窗口

- 内置 Sarasa Term SC Nerd（Unhinted Regular，Sarasa 1.0.27 / Nerd Fonts 3.3.0），无需额外安装，保留中英文等宽与终端图标。
- 保留 Nerd Font 图标与系统 Emoji 回退；随应用附带字体 OFL 许可。
- 默认字号改为 16 pt，新窗口初始尺寸改为 111 列 × 33 行。
  用户已有配置仍优先；恢复窗口及屏幕尺寸限制保持原有行为。

## 配置编辑

- 应用菜单 **Settings…**（⌘,）直接打开用户配置文件：
  `~/Library/Application Support/com.cjmvpu.cghostty/config.ghostty`。
- 首次主动打开时生成八类配置模板：常规、外观、窗口与分屏、快捷终端、
  输入与快捷键、终端行为、通知与安全、高级。
- 模板覆盖 171 个可编辑字段，每项包含中英文名称、当前版本默认值和有效示例，
  并按字段提供可选值、单位、范围或继承说明。默认值及示例均为注释，
  取消需要修改的示例行前的 `#` 才启用设置，避免模板覆盖主题。
- 现有配置首次加入模板前自动备份，保留原有内容、重复项顺序和符号链接。
  已有模板不重复追加；启动时不会主动创建或改写用户文件。

## 生效与恢复

- 配置修改统一在退出并重新启动应用后生效。新窗口、标签页和分屏沿用启动配置。
  删除手动重载菜单、默认快捷键、命令面板入口及 `reload_config` 用户动作。
- 启动检查主文件是否变化；与成功快照和当前构建一致时复用保存内容重建配置。
- 完整校验成功后更新快照。错误配置整份回退到上一次通过校验的主文件；
  没有有效快照时使用内置默认值。错误窗口显示诊断并可打开文件修正，原文件保留。
- 新增 **Restore Default Settings…**。确认后备份当前文件、恢复当前版本的注释模板，
  并重置成功快照；重启生效，当前终端继续运行。快照写入失败时恢复原文件。
- 成功快照只保存主配置内容。外部配置引用和主题资源仍在启动时重新校验，
  不作为资源文件备份。系统深浅色切换继续使用已加载配置。

## 旧配置整理

- 默认配置入口收敛到 Application Support 中的 `config.ghostty`。
  XDG 目录及旧的无扩展名 `config` 文件不再自动加载。
  升级前应备份并按原加载顺序整理这些文件；显式 `config-file` 引用仍有效。
- 光标动画统一为 `cursor-effect = true`／`false`，默认开启。
  旧的 `smooth`／`none` 值需要分别改为 `true`／`false`。
- 删除旧名称及旧枚举值的兼容映射；例如 `background-blur-radius`、
  `scrollback-limit` 应改用 `background-blur`、`scrollback-limit-bytes`。
  配置中显式绑定 `reload_config` 的行应删除。
- 删除无消费路径的 GTK／Linux 配置：`window-subtitle`、`window-show-tab-bar`、
  `window-titlebar-background`、`window-titlebar-foreground`、`app-notifications`、
  `quit-after-last-window-closed-delay`、`quick-terminal-keyboard-interactivity`、`async-backend`。
- 删除 `freetype-load-flags`；可选 FreeType 后端继续使用原有固定默认参数。
  模板不包含仅用于启动参数的 `config-default-files`，也不包含没有可用用户解析器的内部 `link` 规则列表。
  `link-url`、`link-osc8` 等实际链接设置保留。

支持 macOS 27+，仅提供 Apple Silicon（arm64）版本。
