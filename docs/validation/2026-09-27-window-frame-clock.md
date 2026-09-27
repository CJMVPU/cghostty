# 窗口帧时钟合并更新

在检查点 `86a8a8ba7` 的每窗口合成器上继续实现。
配置仍为 `render-presentation = window-compositor`；默认仍使用 IOSurface。

## 更新路径

原型之前：PTY/输入/消息唤醒分屏线程后，立即读取终端并重建 cell；窗口回调只绘制与合成。
现在：分屏线程处理消息并累计待更新请求，唤醒窗口；窗口的 CAMetalDisplayLink 回调
每次遍历可见分屏时至多调用一次 updateFrame，然后绘制缓存纹理、合成 drawable。
单纯布局或光标平滑移动仍可直接复用已有 cell 数据。

同一帧内到达的多次请求合并。读取终端时仍使用原有 lockDemand/unlockDemand，
保持持续 PTY 输出下的锁交接机制。更新期间新到达的唤醒在下一次分屏事件循环中登记，
继续请求下一帧，不会被当前更新清除。更新失败时保留请求，并报告需要下一帧重试。
隐藏期间停止重建；恢复可见性重新登记更新，读取最新终端状态。

## 并发与定时器

新增 update_mutex 将原先仅分屏线程使用的字体、配置、搜索高亮、临时 arena
和终端渲染快照与窗口线程串行化。锁顺序是窗口成员锁 → update_mutex →
终端锁 / draw_mutex。消息处理、光标/动画回调与窗口更新都遵守此顺序。
窗口启动前和分屏线程退出后不允许窗口更新；关闭路径也通过同一锁等待更新结束。
窗口与核心对象仍由原有会话/分屏成员关系保活。

更新完成后通过独立 frame_ready 通知，让分屏事件循环重新判断光标闪烁和 Kitty
动画截止时间。这条通知只刷新定时器，不制造新的脏内容请求。
窗口已在显示回调内时，updateFrame 不再次唤醒 display link，避免空闲自循环。
Kitty 的未来截止时间不再让窗口连续刷新；到期由原有定时器登记一次内容更新。

这是更新和绘制时钟的统一，**尚未删除每分屏辅助线程**。这些线程仍处理邮箱、定时器
和历史压缩。光标与平滑滚动也仍在分屏渲染器内绘制，没有拆到最终窗口合成 shader。

## 可观测性

新增 trace 事件 `compositor_update`：

- a：本次合并的分屏 worker 更新请求数（已经过 xev 唤醒合并，不等于 PTY read 次数或按键数）。
- b：窗口帧的进程内唯一序号，可关联 metal_tick/metal_callback。
- c：该次 updateFrame 的墙钟时间，单位 ns；包含等待终端锁的时间。

汇总器输出更新次数、请求数、每次合并量、更新墙钟时间，以及同一个分屏同一个窗口帧的
重复更新数。不同分屏共用帧序号是正常情况；汇总时按分屏分别检查重复。
这些计数用于验证调度，不证明按键到实际发光的延迟下降。

## 验证

新原生测试暂停窗口帧时钟，连续发送 200 轮真实 PTY 输入，并逐轮等待对应终端输出。
期间分屏绘制计数保持不变。恢复窗口时钟后，检查更新合并、重新空闲、隐藏期间继续输出
及恢复可见；关闭并释放会话后读取完整 trace，验证无重复更新、无记录丢失、每次更新
都关联到真实窗口帧。

另一个参数化测试分别启用光标闪烁与有限循环的双帧 Kitty 动画，在不再输入内容的情况下
等待后续绘制；失去焦点或图片动画结束后必须重新空闲。原有窗口移动、缓存、色彩、主线程
阻塞时后台提交、快照和会话释放测试保留。

暂停帧时钟是可控的合并压力条件，不是正常 120 Hz 刷新下的性能测试。
仍需对持续多分屏高输出、滚动和真实交互测量 CPU、GPU、内存及能耗，才能决定切换默认后端。

最终验证结果：

- 原生完整回归：359 个测试、48 个 suite 全部通过。
- 最终窗口合成器定向回归：4 个测试全部通过，参数化覆盖三个混合模式和两类动画。
  暂停期间同时修改字号、开始/结束搜索；动画检查最终合成像素先变化再恢复，避免仅凭启动阶段的重复提交通过。
- Zig 定向回归：109/109 测试通过，72/72 构建步骤成功；覆盖配置、FrameScheduler、FrameTiming、
  Presentation、ScrollScene、CursorMotion、RenderSession、Trace 和 RenderHold。
- render-trace 汇总器：6/6 通过；SwiftLint strict、Zig 格式、Git 差异空白和 scope 检查通过。
- 非测试版 ReleaseLocal 应用构建成功；arm64 架构、资源和签名检查通过。
  产物为 `macos/build/ReleaseLocal/cghostty.app`，未替换已安装版本。

[最终原始 trace](2026-09-27-window-frame-clock.csv)和[结果数据](2026-09-27-window-frame-clock.json)
记录了带字号/搜索变化的最后一轮：总计 508 次 worker 请求合并成 6 次窗口帧更新，
其中暂停期间累计的 498 次请求在一次更新中消费；同帧重复更新为 0，trace 丢失为 0，
全部更新均关联到实际窗口帧序号。200 轮输入产生的 worker 请求数并非严格一对一。

复现命令：

```sh
nu macos/build.nu --configuration ReleaseLocal --action test
nu macos/build.nu --configuration ReleaseLocal --skip-core --action test --only-testing GhosttyTests/WindowCompositorTests
python3 scripts/build.py test -Dtest-filter='config window compositor' -Dtest-filter='config metal display' -Dtest-filter=FrameScheduler -Dtest-filter=FrameTiming -Dtest-filter=Presentation -Dtest-filter=ScrollScene -Dtest-filter=CursorMotion -Dtest-filter=RenderSession -Dtest-filter=Trace -Dtest-filter=RenderHold --summary all
python3 -m unittest discover -s scripts/tests -p test_render_trace.py
```
