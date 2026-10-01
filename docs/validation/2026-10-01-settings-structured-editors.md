# 设置控件与显示整理验证

日期：2026-10-01。基于 0.4.6 / build 36 的设置界面改动；本次未提升版本或发布。

## 实现范围

- 移除应用菜单 Restore Default Settings 及专用处理代码，设置窗口保留 Restore Defaults。
- 设置目录隐藏无效的 Maximize / Fullscreen，核心继续接受旧配置兼容项。
- Appearance 增加 Font、Colors、Cursor、Advanced Typography 分组；高级字体项默认折叠，搜索直接显示命中项。
- 搜索支持多个关键词及选项名称，显示结果数量和分类；连续相同分类合并显示。
- 分类选中背景、同行下拉框及短输入，长说明移至可滚动帮助浮层；主页面和多行编辑器隐藏滚动条。
- 字体样式随字体家族提供候选，允许保留自定义样式；颜色提供语义选项、颜色预览和取色器；路径提供文件/目录选择。
- 主题可按名称筛选，支持单主题和明暗组合；预览由核心解析主题，只展示前景和背景，不更新运行中的终端。
- 时间、限制和快捷终端尺寸拆分为数值与单位/模式；无法无损拆分的组合时间保留 Advanced 值。
- 多选功能从 Zig packed boolean struct 自动导出，保持核心的选项定义和校验权威。
- 快捷键、环境变量、映射和其他重复值提供有序行编辑，保留 Advanced 原始编辑。大列表按批展开；新建空行不会意外序列化为清空命令。
- 快捷键录入支持常用字母、数字、导航键和修饰键，支持 Escape 取消；失去窗口焦点或应用切换时取消并提示。其他按键、复杂序列及自定义动作仍可手动编辑。
- 等号键的快捷键按核心 Binding.Parser 的分隔规则展示，动作中的等号保留。
- 底部合并重复 Reload / Discard Changes，显示修改数量；恢复原值正确清除修改状态；保存或恢复默认后的重启提示不会因重新打开窗口而消失。
- 启动配置错误窗口复用设置字体、深色背景和隐藏滚动条的文本视图。
- 仍由内部设置记录保存，使用已有核心校验、原子写入和重启生效机制。

## 检查结果

- Zig 定向 `settings catalog` 测试通过，退出码 0。
- 原生 `GhosttyTests/SettingsTests`：22 项通过，覆盖保存/恢复、迁移、非法值、字体预设、环境变量内等号、多选功能、组合时间保留、空草稿行、修改状态和重启提示。
- 最小窗口可用内容宽度 575 pt 下，检查限制、持续时间、模糊、颜色和字体样式控件的 AppKit 对齐边界。
- 录入失焦取消及 Shift 数字保留含义通过原生测试。
- 4 项设置 UI 测试分别通过：
  - `testChoiceButtonsAndFontPresetKeepFallbacksAfterRestart`：30.323 秒。
  - `testIndependentSettingsValidateSaveAndRestart`：23.110 秒。
  - `testStructuredEditorsSaveAndRestoreValues`：56.839 秒。
  - `testThemeSelectionAndShortcutRecording`：24.121 秒。
- 已查看实际截图：常规页、环境变量、多选开关、限制值、字体样式、颜色、主题预览、Appearance 分组和快捷键录入。
- SwiftLint strict、Zig 格式检查和 `git diff --check` 通过。
- 平台范围及原生桥接检查通过：146 个原生 UI/功能文件使用类型化桥接，保持 macOS arm64 范围。

测试期间修正了启动窗口未准备好即发送快捷键的测试时序，并等待 macOS 输入法提示气泡实际消失后继续。早期录入测试使用 Command Shift K，用户指出与 Notion 冲突；最终改用 Control Shift 9 并通过。录入不会接管其他应用已经占用的系统全局快捷键，也不声称能检测所有占用；失焦取消和提示有回归覆盖。

窄窗口检查使用 AppKit 的 alignment rect。普通标签的 frame 会在对齐边界外延伸 2 pt，不应将此视为控件溢出。

## 本机证据

- `/tmp/cghostty-settings-catalog-test.log`
- `/tmp/cghostty-settings-final-native.log`
- `/tmp/cghostty-settings-editors-ui.log`（前两项 UI 通过；新增第三项的初次失败保留）
- `/tmp/cghostty-settings-structured-ui.log`（结构化编辑最终通过）
- `/tmp/cghostty-settings-theme-shortcut-ui.log`（主题选择及录入最终通过）
- `/tmp/cghostty-settings-final-scope.log`

这是针对本次设置改动的验证，未重新运行完整 Zig / macOS 测试套件。Debug 测试构建不代表安装包或正式发布。
