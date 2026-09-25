# 光标位置、宽度与形状的连续过渡（2026-09-26）

## 范围

修复中文宽字符、光标样式切换和字体／窗口尺寸变化时的动画中断。按用户要求，暂不处理“内容滚动但光标屏幕位置不变”，没有新增按键驱动动画或滚动反馈。

版本保持 0.3.0（构建号 20），本轮不修改发布版本、不安装或发布应用。

## 实现

- `SmoothCursor` 只在首次初始化时直接落到目标。普通位置、宽度和 block／bar／underline 变化均保留运动状态与已提交的拖尾路径。
- 尺寸与形状采用独立的 100ms 插值，从当前插值结果继续过渡。连续重定向不累加原有 12% 的放大效果，移动时长仍使用已有距离曲线。
- 同一目标上的形状变化不会重启位置移动计时；只有尺寸变化、位置不变时，也会保持绘制调度直到过渡结束。
- 方块光标的文字变色权重随形状过渡，避免方块／细光标切换瞬间切换文字颜色处理。Metal 与 CPU 的同名 uniform 均由 u32 改为 f32，存储大小和对齐不变。
- 配置更新和窗口尺寸更新不再无条件清空光标运动。下一个实际光标字形提供新布局下的目标，从保留的屏幕像素位置继续移动。
- 禁用效果、系统减少动态效果、失焦／不可见、无效几何与 GPU 失败等已有状态处理保持有效；重绘时暂时隐藏光标仍保留运动。

## 验证

- 核心定向测试：**93/93 通过，72/72 构建步骤成功**。过滤范围为 `SmoothCursor`、`CursorMotion`、`CursorTrail`、`FrameScheduler`。
- 新增回归覆盖 30／60／120／240Hz 下的一格／两格、方块／竖线／下划线、字体几何变化、连续中途改向、同一时刻仅改变形状、结束阶段重新变形、最终精确收敛与拖尾清理。
- **ReleaseLocal 应用构建成功**；应用版本、macOS arm64 范围、资源和签名检查通过。
- 桌面 Metal 回归最终 **4 个场景通过**：字符缓存／颜色／闪烁、VSync 开启的移动与拖尾、VSync 关闭的移动与拖尾、中文宽字符与光标形状交替。前三项在整组运行中通过；新增场景修正测试重绘时序后单独通过。
- 新增 UI 测试首先确认中文落点的静止光标确实为两格宽，再检查多帧连续轨迹与最终精确恢复为单格。初版只在启动时绘制一次中文，实际截图仍为单格而失败；修改为每次同步重绘中文和光标后通过，宽度与连接断言未放宽。
- SwiftLint、修改的 Zig 文件格式和 `git diff --check` 通过。

## 复现

使用仓库固定 Zig 0.16.0 和 Nushell，在可写 Zig 缓存下运行：

```sh
python3 scripts/build.py test -Dtest-filter=SmoothCursor -Dtest-filter=CursorMotion -Dtest-filter=CursorTrail -Dtest-filter=FrameScheduler --summary all
nu macos/build.nu --configuration ReleaseLocal
nu macos/build.nu --configuration ReleaseLocal --action test --skip-core --ui-tests --only-testing GhosttyUITests/GhosttyCursorMotionUITests
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
python3 scripts/check-versions.py --app macos/build/ReleaseLocal/cghostty.app
```

日志位于 `/private/tmp/cghostty-cursor-continuity-core.log`、`/private/tmp/cghostty-cursor-continuity-build.log`、`/private/tmp/cghostty-cursor-continuity-ui.log` 和新增场景重跑的 `/private/tmp/cghostty-cursor-continuity-wide-ui.log`。

首轮核心测试因沙箱禁止 Metal 编译器写入模块缓存而中止，随后在允许该编译器访问缓存的环境中通过相同测试。

本轮 UI 验证使用独立临时配置和 PTY 程序发送中文与 DECSCUSR 指令，没有修改用户的 Neovim 配置，也未对用户的插件组合进行实测。构建产物位于 `macos/build/ReleaseLocal/cghostty.app`，已安装的应用未替换。
