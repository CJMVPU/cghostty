# cghostty

## 基于 Ghostty 独立维护的原生终端
## 仅支持 macOS 27+ 与 Apple Silicon

## 功能

- 窗口
  - 多窗口、标签页、分屏
  - 窗口恢复、快速终端
- 交互
  - 搜索、命令面板、自定义快捷键
  - Shell 集成、AppleScript
- 显示
  - Metal 4 渲染
  - 主题、透明背景
  - 平滑光标、平滑滚动
- 设置
  - 独立深色界面
  - 分类搜索、输入校验
  - 主题预览、快捷键录入

## 安装

1. 打开[下载页面][r]
2. 下载 macOS arm64 压缩包
3. 解压，将应用拖入“应用程序”

更新时下载新版并替换应用, 签名与公证状态以发布说明为准

## 设置

按 `⌘,` 或选择 `Settings…`
日常设置无需维护独立配置文件

### 默认值

- 字体：LXGW WenKai Mono
  - 样式：Medium
  - 字号：16 pt
- 窗口：157 列 × 43 行
- 平滑光标与平滑滚动：开启

### 编辑与保存

- 字体、主题可搜索选择
- 颜色支持预览与取色
- 快捷键、环境变量按行编辑
- 复杂语法使用 `Advanced`
- 非法值会提示错误并阻止保存
- 保存失败时保留草稿
- `Restore Defaults` 恢复默认

点击 `Save` 后重启应用生效, 首次启动会迁入旧设置，保留原文件

### 界面与窗口

- 设置界面固定使用内置字体
  - LXGW WenKai Mono
  - 16 pt，加厚强度 255
- 设置名称、说明与按钮使用英文
- 终端窗口（含快速终端）关闭系统外侧阴影，避免台前调度恢复时出现透明矩形暗框
  - 保留透明按钮行、自绘边框和按钮效果；不影响其他应用或辅助窗口
  - 旧 `macos-window-shadow` 设置仍可读取，但不能重新开启终端窗口阴影
- 普通窗口尺寸由启动设置决定
  - 不支持手动缩放、最大化或全屏
  - 分屏可调整，外部尺寸保持固定
  - 空间不足时约束到屏幕范围

## 构建

环境要求：

- macOS 27+、Apple Silicon
- Xcode 27+、Python 3
- Homebrew

在仓库根目录执行：

```sh
brew install nushell
xcodebuild \
  -downloadComponent \
  MetalToolchain

zig_bin=$(
  bash scripts/install-zig.sh
)
export PATH="$zig_bin:$PATH"

nu macos/build.nu \
  --configuration ReleaseLocal
```

产物位于 `macos/build/` 下的`ReleaseLocal/cghostty.app`

## 开发文档

- [开发与测试](HACKING.md)
- [打包与签名](PACKAGING.md)
- [核心架构](ARCHITECTURE.md)
- [界面架构][ui]
- [支持范围](SCOPE.md)
- [Claude Code 兼容][cc]

### 目录

- `macos/`：原生界面与测试
- `src/`：终端核心与渲染
- `include/`：内部 C 桥接
- `pkg/`：第三方依赖
- `scripts/`：构建与检查工具

## 许可

- 应用：[MIT](LICENSE)
  - 保留 Ghostty 上游版权声明
- 默认字体：[SIL OFL 1.1][ofl]
- 第三方依赖遵循[各自许可][dep]

[r]: /CJMVPU/cghostty/releases
[ui]: UI_ARCHITECTURE.md
[cc]: docs/claude-code.md
[ofl]: src/font/res/OFL.txt
[dep]: pkg/README.md
