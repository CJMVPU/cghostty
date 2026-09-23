> 历史验证记录：描述当时实现，当前状态见 [验证入口](../../VALIDATION.md)。外置文楷方案已由内嵌方案替代。

# 精简与原生资源迁移验证（2026-09-23）

本轮根据仓库审计及确认的范围实施；目标仍为 macOS 27+ / Apple Silicon。

## 已落地

- 修复渲染更新中读取鼠标共享状态的位置，链接匹配改用锁内取得的快照。
- 显式收集 renderer 的链接、行、单元格测试；CI 加入 font、Session、terminal.search 测试。
- 移除未接入渲染的 Glyph APC 协议、glossary、专用 OpenType glyf 解析与栅格化实现；不再回复支持，未知 APC 被消费并忽略。Kitty 图形协议保留。新增分段 Glyph 请求不回复、不泄漏为屏幕文本的回归测试。
- 删除未引用的 ErrorList、KeymapNoop、lib/c_abi 文件。
- 终端字体统一使用 CoreText，移除可选 FreeType / HarfBuzz / noshape 后端及 HarfBuzz、独立 stb 接入。
- 保留 Inspector 调试面板。它使用 Dear ImGui 的独立字体图集流程，因此仍保留其 FreeType 依赖；终端正文不再使用 FreeType。
- 移除主题、颜色和快捷键列表的交互界面及 vaxis、zf 依赖；保留纯文本列表，`--plain` 作为兼容参数。
- 保留主题文件、配置字段和深浅色主题选择。更改用户配置后仍需重启应用。
- 命令面板从 gettext 迁移到原生 String Catalog，移除 PO、libintl、msgfmt 构建步骤及 gettext 安装要求。动作标识与自定义命令文本保持原样。
- 语言范围为英文、中文（简体和繁体）、日文。172 个英文源字符串各有完整的三套译文，共 516 条翻译。保留继承的译者署名，补齐原先缺失的日文。此范围是命令面板，其他原生界面没有在本轮全面翻译。
- 文楷 Medium 从可执行文件迁到 `Contents/Resources/cghostty/fonts/LXGWWenKaiMono-Medium.ttf`，CoreText 按 URL 读取具体文件，保留合成粗体、斜体和 OFL 许可。
- 更新构建说明、依赖说明及范围检查，检查字体哈希、译文范围和已移除的构建选项。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| 核心回归：renderer、config、Command、Terminal、input、os、termio、pty、StringMap、tmux、font、Session、search、APC、Unicode、snapshot | 2,072 通过、1 跳过；86/86 构建步骤成功 |
| 原生应用单元测试 | 313 项、37 组通过；包括三套译文、缺失键英文回退、自定义命令文本与标识保留 |
| ReleaseLocal 原生应用 | 构建成功，版本保持 0.2.1 |
| 发布包范围检查 | arm64、macOS 27、独立身份、资源和签名通过 |
| 字体 | Resources 中的文件 SHA-256 与锁定的 Medium 文件一致；字体数据不再嵌入可执行文件 |
| 本地化 | en / zh-Hans / zh-Hant / ja 各生成 172 条 CommandPalette.strings；不含旧 gettext locale 目录 |
| CLI | version、themes、带路径的浅色主题列表、colors、默认 keybinds 及 docs 输出成功，均为无终端控制序列的文本 |
| 配置文件主题 | `theme = 3024 Day` 与 `theme = light:3024 Day,dark:3024 Night` 验证通过 |
| 质量检查 | Zig 格式、SwiftLint（215 文件零违规）、Swift 6 配置、actionlint、版本记录、本地化覆盖、2 项 Python 脚本测试和 diff 空白检查通过 |

核心测试产生了 macOS XPC 连接诊断；进程退出码为 0，测试汇总无失败。
原生测试最初在执行沙箱内因工具缓存写入权限失败，随后通过正常本地 Xcode 执行完成上述测试。

ReleaseLocal 可执行文件为 17,725,104 字节，外置字体为 25,445,000 字节。
字体仍随应用分发；不能把可执行文件的缩小等同于安装包减少同等大小。
未进行完整手动视觉验收，也未修改版本、提交、安装、打标签或发布。

## 本轮未扩展处理

Inspector 的替代实现、snapshot 子系统裁剪、reload_config 命名调整、私有 API 复查、AppleScript 公共逻辑、图标资源、缓存策略及历史验证文档归档未纳入本轮实现。
