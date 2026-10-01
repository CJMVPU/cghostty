# 0.4.6 同行输入与版本验证

日期：2026-10-01。平台：macOS 27、Apple Silicon arm64、Debug。

## 修改范围

- 数值输入（窗口宽高、字号、透明度等）、间距、字符尺寸微调及撤销保留时长使用 160 pt 输入框，与配置名称同行。
- 前景色、背景色、光标与选区等颜色输入使用 220 pt 输入框，与配置名称同行。
- 名称和控件垂直居中，说明与错误提示显示在下方。命令、路径、其他长文本和多行设置保留完整输入宽度。
- 版本从 0.4.5 提升到 0.4.6，构建号从 35 提升到 36；同步 Debug、Release、ReleaseLocal 三个应用配置，测试目标版本独立保留。
- 更新 RELEASE_NOTES.md 与 README.md。

## 验证结果

- 现有 `GhosttySettingsUITests.testIndependentSettingsValidateSaveAndRestart` 通过：独立窗口、非法宽度阻止保存、保存有效宽度、重启回读、恢复 157 列及截图。
- 检查实际截图，确认 Window width 与 Window height 的名称和输入框同行，说明独立显示在下方，页面没有右侧滚动条。
- `check-versions.py` 通过，包含对实际 Debug 测试应用版本和构建号的核对。
- `plutil -lint`、Swift 6 配置检查、SwiftLint 与 Git 空白检查通过。
- 范围与桥接检查通过：141 个原生 UI/功能文件符合桥接约束。

## 验证边界

本次编译了 Debug 测试应用并运行上述定向 UI 回归，没有重复运行完整测试套件。未打包 ReleaseLocal 安装包、创建或移动 tag、推送或发布。
