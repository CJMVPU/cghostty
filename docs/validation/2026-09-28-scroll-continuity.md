# 离散滚动动画连续性修复（2026-09-28）

基于 `8fe6bb413`（0.4.1 / build 31）。用户报告鼠标滚轮和 nvim 内部滚动不够流畅。
保留 CAMetalDisplayLink、窗口合成、100ms 滚动时长及现有刷新率策略。

## 复现与修复

旧 ScrollMotion 在每次新滚动时从上次提交的偏移重启三次 ease-out，起点时间却取当前回调时间。
当上次提交的姿态属于未来呈现时刻时，再按新的未来时刻取样，相当于重复推进一段呈现提前量。
独立区域也会因统一冻结历史纹理而被一起重启动画。

- 两个新增回归在旧实现上失败：未来取样跳过大部分新位移、无关区域被重新定时。
- 动画起点与历史纹理偏移分离。冻结纹理只更新映射，不重启无关区域。
- 连续改目标的开始时间不早于上次取样的呈现时间；相同或回退的预测不会倒放运动。
- 使用带有速度衔接的 Hermite 曲线，同方向保留速度并限制切线以避免过冲。
  新目标反向跨过可见位置时清除反向速度；静止起步和终点的速度为零。
- 精细触控板仍直接跟随小数像素偏移；失效、尺寸变化和过大跳跃仍取消动画。

以一次 60px 位移、41.5ms 预计呈现提前量计算，首个姿态从旧公式的 47.99px（80.0%）
变为 22.42px（37.4%）。下一次输入在 8.333ms 后到来且再移动 60px 时，两个提交姿态
之间的前进量由 57.60px 变为约 8.04px。这是确定性模型结果，不是实测输入延迟或主观流畅度评分。
本次不宣称降低系统呈现延迟，手感仍需日常使用确认。

## 验证

- 渲染器和 ScrollState 定向核心回归：184/184 通过。
- 新增覆盖 60/120Hz、普通视口与 alternate screen、连续同向输入、反向目标、
  呈现提前量、重复/回退预测、独立区域以及停止后收敛。
- ReleaseLocal 真实滚动 UI：3/3 通过，0 跳过。包含鼠标历史滚动与 nvim 鼠标滚动、
  区域滚动时状态栏固定、同步输出边界，测试启用 Metal 验证层。
- WindowCompositorTests：10 个测试方法、23 个展开用例通过，0 跳过。
  包含三种混合模式下的滚动/光标最终合成、内容缓存、分屏移动和生命周期。
- Zig 格式、diff 空白和版本一致性检查通过。

本地日志与结果包：

- `/private/tmp/cghostty-scroll-before.log`：修复前两个回归失败。
- `/private/tmp/cghostty-scroll-core.log`：最终核心回归。
- `/private/tmp/cghostty-scroll-continuity-ui.xcresult`：滚动图形回归。
- `/private/tmp/cghostty-scroll-continuity-compositor.xcresult`：窗口合成回归。

## 光标与刷新率的补充检查

本节记录滚动修复完成时的光标状态。后续 0.4.2 将光标改为统一呈现时轴，见
[光标呈现时轴验证](2026-09-28-cursor-presentation.md)。

光标已有同方向速度衔接和同目标不重启逻辑，未修改其实现。使用当前 CursorMotion 的独立
模拟，在 60/120Hz、41.5ms 呈现提前量、每次前进 1/8/100 格、各连续 120 次输入时，
没有观察到同向姿态倒退。短距离的最短 24ms 动画在首个未来样本中已到达目标；
长距离的首个位置约前进 16.7%。这不覆盖任意改目标序列，不能解释为所有光标行为都已证明连续。
临时诊断程序保存在 `/private/tmp/cghostty-cursor-lead-check/`。

Apple 的 CAMetalDisplayLink preferredFrameRateRange 文档说明，默认偏好对应屏幕最高刷新率，
回调仍是 best effort，受系统策略、硬件与用户设置影响。因此没有以硬锁 120Hz 替代动画修复。
本次没有改变帧时钟、额外增加缓存或修改配置。

参考：https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframeraterange
