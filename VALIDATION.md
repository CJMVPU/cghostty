# 本地交付验证

日期：2026-09-19。环境：Apple Silicon macOS、Zig 0.16.0、Xcode 27、Nushell 0.115.1、SwiftLint 0.65.1。

## 已通过

- Debug 核心框架与 Swift 应用编译。
- ReleaseFast 核心 + ReleaseLocal 原生应用编译。
- Zig 回归集：`config`、`Command`、`Terminal`、`crc32c`、`font`，共 **863 / 863** 通过。
- Swift 单元测试：**234 项通过、0 项失败、1 项跳过**。跳过项是原有默认禁用的手动基准；UI 自动测试不在此轮单元测试命令中。
- 修改过的 Swift 文件通过严格 SwiftLint；修改过的 Zig 文件通过格式检查；脚本语法和 diff 空白检查通过。
- `scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app`：Intel Mac、Linux、Windows、iOS、WASM 构建目标被明确拒绝；旧独立库、网站数据和 Universal 选项被拒绝。
- 实际应用 Bundle ID 为 `com.cjmvpu.cghostty`，主程序与 Dock 插件均仅含 `arm64`，无 Sparkle，shell 集成和 terminfo 资源存在，完整签名验证通过。
- 命令行默认配置不包含 GTK、Linux cgroup、X11 或自动更新字段；GTK 专用 IPC 命令不再暴露。
- 通过原生窗口实际执行命令，确认 `arch=arm64`、`TERM=xterm-ghostty`、`TERM_PROGRAM=cghostty`、资源来自 `cghostty.app/Contents/Resources/cghostty`。
- 中文及 Unicode 输出、右侧分屏、新标签页启动 shell、“关于”显示 `cghostty 0.1.0-dev`，均通过人工界面验收。
- ZIP 完整性检查和 SHA-256 校验通过。

## 产物

- `macos/build/ReleaseLocal/cghostty.app`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip.sha256`

ZIP SHA-256：

```
d85d6a1df7ed049cf20aa3df1dcc1a91aae328e51d777d8fd5b5085e6676b5d2
```

产物和本地构建缓存已被 Git 忽略。

## 验证边界

没有运行完整 Zig 测试全集、全部第三方包独立测试或 macOS UI 自动测试；上面列出的是实际执行的回归集和界面验收。发布构建生成调试符号时有两条 ImGui 符号告警，构建、签名、CLI 和运行检查均通过。

本地应用采用 ad-hoc 签名。Developer ID 签名、公证流程已提供脚本入口，但未配置真实证书执行。新 GitHub 工作流尚未推送或远程执行；没有发布 Release、创建 PR 或提交 Git commit。macOS 13+ 是部署目标，本轮运行验收在当前本机完成，不代表已在所有旧版 macOS 上验收。
