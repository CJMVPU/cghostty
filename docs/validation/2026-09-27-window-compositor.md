# 每窗口 Metal 合成器实验原型

> 历史验证记录：文中的后端选择与回退已移除。当前实现见[唯一窗口合成器验证](2026-09-27-compositor-only.md)。

配置 `render-presentation = window-compositor`，重启后生效。默认仍为 `iosurface`；
`metal-display-link` 保留为每分屏独立呈现的对照。未修改用户配置、安装应用或发布版本。

> 本文记录初始原型检查点 `86a8a8ba7`。后续已将 cell 更新接入窗口帧时钟，
> 见[合并更新验证](2026-09-27-window-frame-clock.md)。下文的“尚未统一更新”是检查点当时的状态。

## 已实现的边界

- 每个窗口一个 CAMetalLayer、CAMetalDisplayLink、后台 NSRunLoop 线程和 Metal 4 呈现队列。
- 每个分屏一个持久的离屏目标纹理。内容和动画需要变化时重画，单纯布局更新复用缓存。
- 同一回调按同一个预计显示时刻采样所有分屏，再将所有可见分屏合成为一个 drawable。
- 分屏编码和最终合成提交到同一队列，显式队列屏障排序纹理写入与读取；没有逐分屏 CPU 等待 GPU 完成的步骤。
- drawable 使用 `waitForDrawable → commit → signalDrawable → present()`，不使用指定时间的呈现方法。
- 窗口与原有单分屏 Metal 后端均接入 `CAMetalLayer.residencySet`；图层集合不由应用修改。
  设备在后端实例生命期内固定，销毁时解除队列关联。其他 GPU 资源仍使用独立常驻集合和完成回调保活。
- 原生 SurfaceView 保留输入、IME、无障碍、鼠标和结构性 CALayer，不再拥有呈现用的 Metal 图层或分屏帧时钟。
  窗口 Metal 视图不拦截点击，位于终端原生控件下面、已有玻璃效果上面。
  最终合成的参数表按飞行中的帧槽复用，只在 GPU 完成后改写。
- 外部窗口仍按启动配置固定尺寸；分隔线改变、显示缩放、可见性与跨窗口移动更新合成布局。
- 主线程仅提交成员与布局变化；普通帧的像素提交不经过主队列。

这是架构迁移的第一段。**每分屏的内容更新线程仍在运行，cell 重建仍由原有更新事件驱动。**
因此尚未实现“所有更新合并到每帧一次”，也不宣称总线程数已经不随分屏数增长。
光标和平滑滚动仍先在分屏渲染器中绘制，再合成其结果；尚未把这两类绘制完全拆到窗口最终合成阶段。
原有 ScrollScene 缓存继续复用，窗口新增的是完整分屏输出缓存。

## 生命周期与资源顺序

主线程维护弱视图引用及像素几何，窗口线程读取快照而不访问 NSView。
渲染器的唤醒对象只排入合并后的 run-loop 回调，不反向获取窗口成员锁。
窗口成员锁与每分屏 draw_mutex 的顺序固定，避免主线程、更新线程和窗口线程互相等待。

移走分屏时先等待旧窗口已提交的 GPU 工作完成，再注销旧唤醒对象。
核心同时等待该分屏的编码槽归还，确保共享的滚动纹理等资源不跨两个窗口队列并发写入。
新窗口分配自己的输出纹理；PTY、终端状态及会话对象不重建。
SwiftUI 暂时移走全部分屏时保留窗口合成器，真正关闭窗口时才停止线程和显示链接。

最终 drawable 的纹理只保留到 GPU 完成，不留在空闲缓存中。
呈现反馈回调只弱引用终端会话；保留一个图层不能把已经关闭的 PTY 和 trace 写入线程一起拖住。
Kitty 图片和缩略图继续复用独立、按需的离屏快照路径；快照在必要时等待先前分屏 GPU 工作，
不会获取窗口 drawable，也不在正常帧上增加截图拷贝。

## 显示反馈与空闲

初始窗口挂接期间，系统可能对已完成 GPU 工作的 drawable 回报 `presentedTime = 0`。
原型对此进行有限的缓存重试；内容或几何变化会重置重试预算。
完全透明或被覆盖的图层不能因为没有正的呈现时间而无限重试。CPU 错过提交截止时刻时，也会继续请求下一帧。
动画结束、没有新内容且重试完成后暂停链接。恢复依赖内容、布局或可见性事件，没有空闲轮询定时器。

窗口的 `metal_tick`、`metal_callback`、`present_submit`、`displayed` 使用进程内唯一帧序号。
每帧只由一个可见分屏的 trace 文件记录这些窗口事件，避免统计结果乘以分屏数；
分屏自身的 update/draw/GPU 事件仍各自记录。接收回调的时间不代替 drawable 的 presentedTime。
`presentedTime = 0` 仍从成功呈现样本中排除。

这些数据用于确认提交与系统呈现路径，**不等于物理按键到像素发光的延迟**。
本轮功能回归样本量也不用于推断延迟分布改善。

## 验证

原生回归覆盖：

1. 两个真实终端会话共用一个窗口合成器，SurfaceView 本身没有 CAMetalLayer。
2. 使用最终合成的同一套 Metal shader 做独立纹理读回，核对左右分屏内容与分隔线改变后的坐标。
   色彩按 Display P3 转回 sRGB 验证，分别覆盖 native、linear、linear-corrected。
3. 布局更新只合成缓存，不增加分屏重画次数；空闲后显示链接停止请求帧。
4. 主线程同步等待 GPU 完成事件期间，后台窗口线程仍能独立完成新画面。
5. 分屏跨窗口移动保留会话，临时空视图树不重建合成器，关闭一个窗口后另一个继续输出。
6. 三种后端均检查两个 Kitty 图片位置、连续四次缩略图以及之后继续绘制。
7. 旧单分屏 Metal 的空闲、重新挂接、延迟偏好测试继续运行。

验证命令：

```sh
nu macos/build.nu --configuration ReleaseLocal --action test
nu macos/build.nu --configuration ReleaseLocal --skip-core --action test --only-testing GhosttyTests/WindowCompositorTests
python3 scripts/build.py test -Dtest-filter='config window compositor' -Dtest-filter='config metal display' -Dtest-filter=FrameScheduler -Dtest-filter=FrameTiming -Dtest-filter=Presentation -Dtest-filter=ScrollScene -Dtest-filter=CursorMotion
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
```

最终验证结果：

- ReleaseLocal 原生 **357 个测试、48 个 suite 全部通过**；包括三种混合模式和关闭会话释放回归。
- Zig 定向回归 **91/91 通过，72/72 构建步骤成功**。
- render-trace 汇总器 **5/5 通过**。
- SwiftLint 严格检查、Zig 格式检查、差异空白检查、scope/原生桥接检查通过。
- 非测试版 ReleaseLocal 应用构建成功，arm64、资源、签名检查通过。
  产物：`macos/build/ReleaseLocal/cghostty.app`，未替换已安装版本。

[功能验证数据](2026-09-27-window-compositor.json)保存三个混合模式下窗口的提交、完成、
实际呈现和分屏重画计数；计数读取于窗口最终拆除之前，不能要求当时所有异步呈现回调均已到达。
关闭回归显式释放会话，并确认图层仍被持有时会话也能销毁、trace 的未满批次可以刷盘。
其[原始 trace](2026-09-27-window-compositor-close.csv)含 2 个正的 presentedTime 样本、
没有逐帧图层 contents 赋值，也没有记录丢失。这只是诊断路径的端到端功能证据，不是性能对照或 p95/p99 结论。

## 后续阶段

- 把 IO 更新合并到窗口帧时钟，做到每帧每分屏最多重建一次，并减少原有内容更新线程。
- 评估进一步拆分光标/滚动最终合成，减少动画期间的分屏输出重画。
- 对多分屏高输出、持续滚动、隐藏恢复及跨屏缩放进行 CPU、GPU、内存和能耗对照。
- 补足真实 AppKit/SwiftUI 操作验收，包括玻璃、搜索覆盖层、拖放、不同显示器及长期稳定性。

这些完成之前，窗口合成器保持显式开启的实验路径，不切换默认后端。
