# 2026-10-03 Mac 恢复显示与审查回归

## 工作区与构建来源

- 初始 `main` 为 `ffd97565f4a096d01f5acb2740d1ed5bd3f574a3`，工作区干净。原 `main` 保留不变。
- 工作分支：`fix/stage-manager-and-reviewed-regressions`。
- 运行环境：Apple Silicon / Apple M5 Pro，macOS 27.0.1，Xcode 27.0，Zig 0.16.0。
- 初始运行安装版来自 `/Applications/cghostty.app`，版本/build 为 0.5.1/41。仅版本号不能证明该二进制对应哪个源提交。
- 安装版可执行文件开始与结束 SHA256 均为 `98dee98e7eee69bbdeb1a03bb2cb68d475263e8fa11898a22b926cb1e02be182`。没有安装或替换该 app，没有 push、PR 或 issue。
- 已从 Library ID `libfile_6b62ccdbdc4c819189434dda78d9634d` 材料化 `cghostty-cloud-fixes.zip`，核验 SHA256 为 `4ff8dd09049b1c7c68708e7531dba3f9958593de05babe91fc9d5806cee34968`。bundle prerequisite 与初始 HEAD 一致，四个原始提交按原身份保留。

## Stage Manager 证据与修复边界

用户明确两项异常只在恢复动画中出现，窗口稳定后消失。已在这台 Mac 按 Library 当前传输流程实际下载并查看两张原图：`libfile_bc30cfbb2c608191a9efae3acfd2841e`、`libfile_9e52e6cafd8c8191af195641259c44b6`。

异常图的半透明长暗条贯穿透明按钮排空白区域，外轮廓包含该排；正常图该排透明。两图终端内容基本完整，不能证明缺块。按钮各自的小范围 shadowPath 无法独立解释整排长条。

CUA 观察到了安装版完整的稳定窗口，也在 Cmd+H 隐藏阶段观察到透明内容；隐藏阶段不当作恢复证据。用户点击恢复后连续取得的八张窗口截图已错过动画，不能用于证明动画正常或修复有效。未修改 Stage Manager 设置或取消用户阴影配置。

三项真实 AppKit/Metal 负回归在修复前实际失败：

1. 所有 pane 几何不可见时，worker 仍增加 submitted 并提交透明 clear 帧。
2. window worker 的 pane rect 先于核心尺寸更新时，核心拒绝 composition，但 worker 仍呈现缺失 pane 的帧。
3. hidden window `syncAppearance` 中间写入 `isOpaque=[true,false,false]`、背景 alpha `[1,0,0]`；部分透明配置则背景先写 0.001，再清零。

修复后保留最后完整呈现的帧：全遮挡时暂停；drawable 实际尺寸与目标不同则等待新 drawable；任一可见 pane 未组成帧时，退休本轮 GPU 写入而不 present，后续有效尺寸/可见性刷新继续工作。空 pane 集合仍允许清理窗口内容。hidden window 外观更新全程保持透明，普通窗口行为、用户 `hasShadow` 和 blur 路径保留。

修复后的 `WindowCompositorTests` 16 项、`HiddenWindowAlphaTests` 四参数组合与 `TerminalChromeTests` 均通过。它们验证上述机制，不等同于 WindowServer 的真实恢复动画验证。**尚需用户在新构建上进行 Stage Manager 后台→恢复动画对比；两项原始症状的系统动画改善仍未确认。**

## 独立本地提交

| 提交 | 问题 |
| --- | --- |
| `d08af2ad1` | 云端：discard 异步重读最新 settings revision/UI |
| `9a02bde82` | 云端：关闭确认 allowed/cancelled/inFlight，忽略重复请求 |
| `00e4d6ec6` | 云端：4+3 合并标签 registry 关闭/undo/redo 回归 |
| `f13fa44f6` | 云端：整窗关闭审查目标身份快照 |
| `3b9b2b003` | 当前 Swift 编译器测试宏/多闭包兼容性 |
| `6709daabf` | 长 env 无损格式化、错误传播及保存重启 |
| `4a72562e1` | 外部 Shortcuts 枚举先检查权限，内部 ID 解析独立 |
| `7ce64832e` | 关闭队列/取消 surface 生产者后 join；拒收/遗留拥有型消息清理 |
| `0a4f59127` | 搜索跨 page 导航后刷新 viewport matches |
| `b6e1bb9a9` | 解析批次尾部发布 revision/变更通知，覆盖 DSR 解锁交接 |
| `48acf7c42` | compositor 可见性/尺寸交接保留完整帧 |
| `9cce4bd9e` | hidden window 外观更新保持透明 |
| `59ae426e9` | 继承依赖变化后保留显式设置选择 |
| `ad0526048` | 保存前验证 light 与 dark 分支 |
| `8b155daed` | 搜索 request/apply 分离，延迟 callback 绑定原身份 |
| `7bd257ad3` | 迁移采用实际读取的来源/内容/顺序快照 |
| `342ea417d` | 新窗/新标签 undo 先批准再消费整组历史 |
| `4d18582f8` | detach redo 传递原确认策略和位置 |
| `71fe6a5ba` | 整窗/批量 redo 关闭恢复的身份，不重算当前组范围 |
| `7f43b8f77` | undo 保留 titleOverride、isBackgroundOpaque、restorable |
| `20462f29d` | quit 审查批准阶段保留 Quick Terminal；脚本 close 保留可复用生命周期 |

两项 fixup 已合入所属问题提交，仅整理本任务分支。整理前后 code tree 均为 `8a52112b5184725f531aa5029335e2f5c22e017e`。

## 实际验证

所有 Zig/native 命令使用仓库内 Zig 0.16.0 的 PATH，走 `scripts/build.py` / `nu macos/build.nu` 管理入口。

- IO/queue shutdown targeted Mac Zig：83/83；拥有型消息、搜索/env supplemental：79/79。有界退出回归使用真实队列及 DSR 解析；没有声称在用户运行的桌面 app 上制造并复现主线程满队列死锁。
- `-Dtest-filter='Termio output completion' --summary all`：71/71，包含解析释放 mutex 时消费旧通知、尾部解析后重新通知的有界回归。
- `-Dtest-filter='source files' --summary all`：71/71，包含 source 字节所有权、clone/replay 保留与 theme 排除。
- 19 个原生 suite：**112 passed，0 failed，0 skipped**。覆盖真实 AppKit、Metal 4、PTY、settings、registry、关闭事务、undo/redo、detach、权限、Quick Terminal、搜索状态。
- 真实 UI：**8 passed，0 failed，0 skipped**。新窗/新标签取消 undo 与 redo 2 项，hidden chrome 2 项，window registry 2 项，settings 保存重启 1 项，隐藏 Quick Terminal quit 确认 1 项。配置/defaults 隔离，不操作用户安装版。
- UI 第一轮在任何 test 开始前被系统认证阻塞：`automationmode.writer` 要求 authentication，随后超时。没有改 TCC/DevToolsSecurity 或代填认证。后续重试及剩余 UI suite 实际成功，不把最初 bootstrap 失败当成代码失败或通过。
- 聚合 native 第一轮发现 `groupsByEvent=false` 直接 batch close 缺组引起 AppKit 异常，已在事务内明确 begin/end grouping，Merged/close/split 及最终聚合重测通过。
- 来源测试最初只失败 `/var` 与 `/private/var` 别名比较；改为双方 realpath 比较，同时保留精确内容、顺序、clone 和持久快照断言，最终通过。
- `scripts/check-native-contracts.py`：8/8 pure contracts；不包含 AppKit/Metal 集成。
- strict SwiftLint：36 个变更 Swift 文件 0 violation；`git diff --check` 通过。
- `scripts/check-scope.py`：152 typed bridge 文件、config bridge、macOS arm64 scope 均通过。
- `nu macos/build.nu --configuration ReleaseLocal`：**BUILD SUCCEEDED**。`codesign --verify --deep --strict` 通过。

本地生产构建来自 code HEAD `20462f29d2d52085ab93abadb5455cab3645c2c7`（本记录提交仅新增文档）。路径：`macos/build/ReleaseLocal/cghostty.app`。版本/build 保持 **0.5.1/41**，CLI 确认为 stable / ReleaseFast / Zig 0.16.0 / embedded / CoreText / kqueue。可执行文件 SHA256：`314f12ac091cf894fff5f4af12ae6a1f0f16ac9c29b86bae83321d6ee0e51333`。

本次日志为 `/tmp/cghostty-native-final.log`、`/tmp/cghostty-creation-ui-retry.log`、`/tmp/cghostty-ui-remaining.log`、`/tmp/cghostty-release-local-build.log`。受仓库临时产物维护策略影响，这些路径及 Xcode result bundles 不承诺长期保留。
