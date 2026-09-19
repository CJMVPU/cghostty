# 本地交付验证

日期：2026-09-20。环境：Apple Silicon macOS 27.0（26A428）、Zig 0.16.0、Xcode 27、Nushell 0.115.1、SwiftLint 0.65.1。

本轮将交付基线提高为 macOS 27+、arm64、Metal 4 命令 API 与 MSL 4.1。此记录替代此前 macOS 13 部署目标的验证记录。

## 应用图标更新（2026-09-20）

- 采用圆润、立体的白色小幽灵：chevron 眨眼、薄荷绿吐舌微笑、挥手与小卷尾巴。最终原画及提示词保存在 `images/cghostty-icon-v4/`。
- 已同步 Icon Composer 文档和 Dock 插件使用的 AppIconImage。原方案文件保留，v2/v3 目录为历史设计稿。
- 验证 macOS 原生 1024px、512px、64px 图标导出；从实际构建的 `cghostty.icns` 解出图像检查新图标确实进入应用。
- ReleaseLocal 构建、应用范围/签名检查、ZIP 完整性和 SHA-256 检查通过。本轮仅更新图标资源，无运行时代码改动，未重复执行单元测试。

## Vim 光标修复追加验证（2026-09-20）

- 方块、细线和下划线光标均支持 smooth；细线按字符格宽度计时，非方块光标在文字之后绘制且不改写文字颜色。
- 连续移动按逻辑输入步长计时，尾端只消耗剩余延迟，避免重复等待与滞后距离造成的时长膨胀。单次移动的原时长和曲线保持不变，中断时两个端点位置连续。
- 定向 Zig 回归 **294 / 294** 通过；新增细线模式切换，以及每 8/16/33ms 连续移动 500 次的尾端进度与长度回归。
- ReleaseLocal 应用和原生 MSL 编译通过；应用范围、arm64、资源与签名检查通过。
- 使用独立 Bundle ID 的最新构建副本运行 macOS 自带 Vim 9.1，临时配置显式设置 normal 方块和 insert 细线。上下往返定时测试实际执行 1,726 步，观察未形成持续积累的多行长拖尾；insert 模式持续输入和返回 normal 模式通过界面检查。Metal API / GPU 校验未报告错误。
- 本轮只修改 Zig/MSL 及文档，未重新运行 Swift 单元测试；下方 234 项 Swift 结果属于上一轮 Metal 4 迁移验证。

## Metal 4 迁移验证

- Zig 渲染器与配置回归：**292 / 292** 通过。包含原光标时长与距离分档、曲线单调性、中断时两个端点的位置连续、尾端收拢、尺寸变化重置，以及旧 GLSL 配置的迁移诊断。
- Swift 单元测试：**234 项通过、0 项失败、1 项跳过**（xcresult 汇总；参数化用例有多次执行）。跳过项是原有默认禁用的手动基准。原生应用测试使用 Debug 配置。
- 原生 MSL 4.1 着色器编译、Debug 核心与 Swift 应用编译通过。
- macOS 27 上以 `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` 启动 ReleaseLocal 应用，确认 Metal API 与 GPU 校验启用。
- 最终 ReleaseLocal 独立进程正常读取迁移后的个人配置并启动 shell/display link；进程采样确认调用 `IOGPUMetal4CommandBuffer` / `MTL4CommandAllocator` 路径，主线程正常等待 AppKit 事件。
- 将最终 ReleaseLocal 复制为独立 Bundle ID 的验收副本（仅重新签名，编译 UUID 相同），避免同路径旧进程干扰；解锁后完成连续改向、中文/彩色文字、光标形状回退、字体缩放、分屏与拖动分屏大小的界面验收，对应进程未出现 Metal API/GPU 校验错误或 GPU 提交错误。
- 源码范围检查通过；Xcode 的应用、项目、测试与插件目标统一为 macOS 27，入口拒绝其他平台、Intel Mac 和已移除产物选项。
- 修改的 Swift 文件通过严格 SwiftLint，Zig 格式和 diff 空白检查通过。
- 本机 cghostty 配置迁移到 `cursor-effect = smooth`，删除两个旧 GLSL 配置项；迁移前备份为 `config.ghostty.pre-native-cursor-20260920`。原 Ghostty 配置与参考 GLSL 文件未改动。

- 最终 ReleaseLocal 完整构建、应用范围/架构/资源/签名检查、个人配置校验、ZIP 完整性与 SHA-256 校验通过。交付包约 20 MiB。

## 产物

- `macos/build/ReleaseLocal/cghostty.app`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip.sha256`

产物和本地构建缓存被 Git 忽略。ZIP SHA-256：`67ed2f8cbd0be778e13db5037d8720ef28a7a16d2c4860a8d0679c2fedb52698`。

## 验证边界

未运行完整 Zig 测试全集或 macOS UI 自动测试；本轮使用上述定向回归、运行检查与原生界面验收。界面检查使用独立身份的最终构建副本，避免同路径旧实例影响窗口定位；不将早先实例不明确的观察计入最终结果。未测量功耗、端到端输入延迟或实际帧率，不声称固定 120 Hz。

运动中断保证两个端点的位置连续，新一段继续使用原曲线；不保证中断时速度连续。特效目前仅为内置 smooth 光标，不加载外部 GLSL/MSL，不包含 CRT。系统 Reduce Motion 在渲染时关闭特效，但本轮未修改用户的系统辅助功能设置进行手工验收。

首次窗口建立 display link 曾暂时回退，随后成功建立 display link。发布构建的 ImGui 调试符号告警不影响构建结果。应用使用 ad-hoc 签名；没有执行 Developer ID 公证或对外发布。GitHub `xcode-27` 工作流已更新但未远程运行。未创建 PR、Issue 或 Git commit。
