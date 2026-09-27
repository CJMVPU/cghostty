# Metal 显示时序与快照兼容性复查

> 历史验证记录：文中的后端选择与回退已移除。当前实现见[唯一窗口合成器验证](2026-09-27-compositor-only.md)。

继续验证 [第一阶段](2026-09-27-metal-display-link.md)。本轮使用 ReleaseLocal，
核心为 ReleaseFast；原生测试仍启用 testability 和 coverage，不等同于无插桩发布包。
运行环境报告 macOS 27.0（26A428）、屏幕最高 120Hz、2× backing scale。

后续状态：已进入[窗口合成器实验原型](2026-09-27-window-compositor.md)。下文保留本轮时序调查时的结论；
原型验证不以单分屏延迟优于 IOSurface 为前提，默认后端仍未切换。

## 约 41ms 间隔的位置

新增 `metal_callback` 和 `metal_state` 事件，分别记录回调的 Core Animation media time
及暂停状态、实际读回的 preferredFrameLatency。所有分段时差使用同一 media clock，
不把 trace 写入时刻或主线程处理显示回调的时刻当作屏幕呈现时间。

第一轮 ReleaseLocal 结果如下，单位 ms；每组执行 220 次输入更新，然后换窗恢复。
“内容”关闭光标效果，“动画”开启光标效果。两个负载仍然都包含文字输出。

| 配置 | 有效显示样本 | 回调到提交 median | 回调到截止 median | 截止到预计显示 median | 提交到显示 median |
| --- | ---: | ---: | ---: | ---: | ---: |
| latency 1，内容 | 215 | 0.3354 | 8.2331 | 33.3332 | 41.2318 |
| latency 1，动画 | 237 | 0.3505 | 8.2258 | 33.3332 | 41.2150 |
| latency 2，内容 | 217 | 0.3407 | 8.2257 | 33.3332 | 41.2197 |
| latency 2，动画 | 216 | 0.3369 | 8.2287 | 33.3332 | 41.2261 |

实际读回的 latency 分别为 1、2，配置已经到达系统对象。内容负载记录约 225 次恢复，
动画负载只有 4～6 次恢复，两者都出现约 41ms。第一轮各组丢失 11、1、5、2 条 trace，
仅统计存在的配对记录，不能把缺失记录当成成功帧。第二轮重复了全部六组终端配置，
包括两组 IOSurface。完整分布、p95/p99、样本数及丢失记录见
[ReleaseLocal 数据](2026-09-27-metal-display-link-release.json)。

另加只清屏的独立参考程序：使用主线程 CAMetalDisplayLink 和普通 MTLCommandQueue，
不经过终端、libxev、现有帧槽或 Metal 4 资源管理。每组提交 240 帧，剔除前 20 帧，
再剔除 presentedTime 为 0 的样本。它是隔离变量的对照，不是生产渲染实现。

| latency | 帧率设置 | 有效样本 | 提交到显示 median | 截止到预计显示 median |
| --- | --- | ---: | ---: | ---: |
| 1 | 系统默认 | 219 | 41.4800 | 33.3333 |
| 1 | 请求屏幕最高 120Hz | 220 | 41.4765 | 33.3333 |
| 2 | 系统默认 | 219 | 41.4784 | 33.3333 |
| 2 | 请求屏幕最高 120Hz | 220 | 41.4800 | 33.3333 |

对照的回调到提交中位数约 0.09ms。请求最高帧率、减少应用工作、更换队列 API 及运行循环，
均未消除该环境下的约 41ms 间隔。因此，目前证据不支持“终端编码耗时、libxev 桥接或每帧暂停
造成了这段主要延迟”的判断。约 33.33ms 已包含在系统给出的截止与预计显示时刻之差中；
系统内部为何选择这个窗口，尚未确定，不能把它推广为所有 macOS/显示器的固定延迟。

Apple 的 [preferredFrameLatency 文档](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency?changes=_2_8)
也说明，实际延迟可能因系统需要而增加，包括 macOS 窗口模式。它不承诺设置 1 就会有一帧端到端延迟。

这仍不是物理按键到屏幕测量，也没有与 IOSurface 取得相同的呈现终点。
默认后端维持 IOSurface，暂不推进每窗口合成器；刷新率范围也不因这组数据强制锁到 120Hz。

## 发现并修复的预览问题

将现有 Kitty 图片与同步输出测试扩展到两种后端后，Metal 分支先出现可复现失败：
GPU 完成，但 `NSView.cacheDisplay` 得到的缩略图缺少应有的两处红色图片。
保留原断言，没有跳过或改成只检查 PNG 非空。

为 Metal 分支增加按需离屏快照：

- 仅预览请求时分配独立 IOSurface 目标，复用渲染内容、图片、字体和合成管线。
- 在 draw mutex 下使用可用帧槽，等待该次离屏 GPU 工作完成后归还帧槽。
- 不获取或长期保留 drawable，不改变正常呈现序号、完成版本及光标提交历史。
- 不恢复逐帧主线程中转，也不把 framebufferOnly 关闭；普通帧不增加截图拷贝。
- Swift 桥接接收拥有独立生命周期的 IOSurface，再生成有界缩略图。

离屏绘制是同步按需操作，可能等待之前的 GPU 工作；不应把它当作每帧截图或视频采集接口。
回归连续取四次缩略图，每次核对两处 Kitty 图片，随后发送输入并确认继续出帧。

## 复现

最终代码验证：ReleaseLocal 原生回归 355 个测试、47 个 suite 通过；Zig 定向回归
94/94 通过、72/72 构建步骤成功；trace 汇总器 5/5 通过；Swiftlint 与差异检查通过。
本地 ReleaseLocal 应用构建成功，应用 scope 检查通过，包括 arm64、资源、签名与配置桥接。
产物为 `macos/build/ReleaseLocal/cghostty.app`，未替换已安装应用或发布版本。
原生回归包含上述两种后端的四次图片快照与继续绘制断言，没有已知失败豁免。

```sh
nu macos/build.nu --configuration ReleaseLocal --action test --only-testing GhosttyTests/MetalDisplayLinkTests
nu macos/build.nu --configuration ReleaseLocal --skip-core --action test --only-testing GhosttyTests/SurfaceBridgeTests
```

测试打印终端 CSV 与只清屏 JSON 的目录；两者均可使用同一脚本汇总：

```sh
python3 scripts/summarize-render-trace.py /absolute/path/to/test-output
```
