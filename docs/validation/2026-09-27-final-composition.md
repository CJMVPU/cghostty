# 最终合成、字形计时与前台显示时序

基线为 `ec9b14a88`（0.4.0 / 构建 30，与 `713952e8c` 内容一致）。本轮落实光标、滚动的最终合成，
补齐冷字形计时，并用独立前台应用比较两种显示时钟。窗口级合成器仍是唯一呈现路径。

## 绘制与资源所有权

内容变化时重绘不含光标的分屏内容缓存；每个窗口帧把内容缓存、滚动偏移、背景图片、
光标与上层 Kitty 图片直接画到窗口 drawable 的对应 viewport/scissor。
删除 Swift 分屏的输出纹理、采样视图及窗口复制 pipeline。
分屏内容的颜色空间由对应的 drawable 纹理视图保留，支持 native、linear、linear-corrected。

普通内容更新可复用一张内容纹理。滚动时保留当前和历史内容；滚动被再次打断时，
将上一帧的无光标内容与偏移冻结到第三张纹理，再以此继续动画。
这一步只在中断时发生，不再为每个滚动动画帧生成一张合成纹理。
纹理池上限为三张，按需分配；已经分配的纹理保留以复用，不宣称空闲后立即缩回一张。
三帧槽的上传缓冲和 GPU 图集仍保留，未改成共享 GPU 图集。

窗口清屏、各分屏绘制和最终屏障共用窗口的 Metal 4 队列。
帧槽持有参与会话直到 GPU 完成，纹理由核心提交保留；跨窗口交接继续通过 Surface gate
和 GPU 排空保护。异常发生在部分提交之后时，先排空该队列再回收窗口编码资源。
缩略图仍是按需共享 Metal 纹理读回，不使用 IOSurface。
测试用窗口读回复用上次采样的动画状态，不消费待更新请求、不推进显示修订号。

## 新增测量字段

- `glyph_lock`：一次更新内字形查询的累计锁获取时间、调用次数、真正未命中次数。
- `glyph_raster`：一次更新内未命中字形生成总耗时、数量。包含字体呈现选择、位图生成、
  图集写入／扩容和缓存提交；不是纯 CoreText 调用时间，不含前面的锁获取时间。
- `content_draw`：内容缓存重绘次数。
- `scroll_freeze`：滚动中断时历史画面冻结次数。

字形耗时按更新聚合写入 trace，避免每个字形新增一条日志；关闭 trace 时不做这些时钟采样。
汇总器继续报告丢弃记录数。冷中文字压力场景不代表日常缓存已热的使用负载。

## 前台探针与复现

```sh
python3 scripts/run-display-link-probe.py --output-directory /tmp/cghostty-display-probes --matrix --repeat 2
python3 scripts/summarize-display-link-probe.py /tmp/cghostty-display-probes
```

启动器构建临时 `.app` 并正常启动、激活；结束后自动清理临时应用。每组提交 240 帧，
舍弃前 20 帧，将 `presentedTime == 0` 单独计数，绝不记为零延迟。
探针只在应用激活且窗口获得焦点时提交，并为每个样本记录这两个状态。
锁屏、失去焦点或呈现回调不完整导致超时的运行标为失败；矩阵遇到失败立即停止。

探针仅清屏，使用普通 MTLCommandQueue，两个时钟走同一提交代码。
`metal` 从 CAMetalDisplayLink 获取 drawable 与预计显示时间；`view` 从 NSView.displayLink
回调中调用 nextDrawable，不虚构与前者等价的预计显示时间。
矩阵覆盖图层透明度、玻璃背景、drawable 数量与 preferredFrameLatency。
所得延迟是提交调用附近时间到 presentedTime 的差，不是物理输入到屏幕发光的延迟。

## 本机结果

环境：Apple M5 Pro，macOS 27.0（26A428），内置 ProMotion Retina 屏、2× 缩放。
完整前台矩阵每组执行两轮，第二轮反转顺序；每轮每组 219–220 个有效样本，
所有测量帧均记录 active/key 为 true。完整矩阵共 3517 个有效显示样本，
另有 3 个 presentedTime 为 0 的样本，保留在原始文件中但不进入延迟统计。

| 时钟与设置 | 第 1 轮提交到显示中位数 | 第 2 轮提交到显示中位数 |
| --- | ---: | ---: |
| Metal / 不透明 / 3 drawable / latency 1 | 41.49ms | 41.49ms |
| Metal / 透明 / 3 drawable / latency 1 | 41.47ms | 41.47ms |
| Metal / 透明＋玻璃 / 3 drawable / latency 1 | 41.46ms | 41.47ms |
| Metal / 不透明 / 2 drawable / latency 1 | 41.47ms | 41.48ms |
| Metal / 不透明 / 3 drawable / latency 2 | 41.47ms | 41.49ms |
| View / 不透明 / 3 drawable | 25.21ms | 25.40ms |
| View / 透明＋玻璃 / 3 drawable | 25.30ms | 25.32ms |
| View / 不透明 / 2 drawable | 23.73ms | 17.09ms |

这组环境下所有 Metal 组合的 deadline 到 prediction 均为 33.33ms，中位显示间隔
均约 8.33ms。两轮 View / 2 drawable 的分布差异明显，不能只取 17.09ms 作为稳定收益；
其第一轮 nextDrawable 等待中位数 1.63ms，回调到显示中位数 25.48ms，第二轮分别为
0.059ms 和 17.22ms。三 drawable 的 View 两轮回调到显示分别为 25.42ms、25.57ms。
Metal 的 acquire 记录为 0 仅表示 drawable 已由回调提供，不是测得系统获取时间为 0。

不透明／透明模式同时设置窗口、图层标志和清屏 alpha（1／0.8）；玻璃变量是在
同一个透明配置中单独添加 NSGlassEffectView。这里只排除了这些受测组合能消除
41ms 的假设，不能断言已定位系统内部原因，也不能把清屏探针的差值当作完整终端收益。

早期直接启动探针的 8 组前台测量也观察到 Metal 约 41.5ms、View 约 24ms；
本页表格采用随后完成的正常 `.app` 两轮矩阵。中间锁屏或失焦导致的超时运行
不混入这些结果；最终复测在解锁后、无其他图形测试和构建同时运行时完成。

冷字形回归为每轮发送新汉字的受控 PTY 压力场景：

| 指标 | 单分屏 | 四分屏 |
| --- | ---: | ---: |
| 更新次数 | 76 | 327 |
| updateFrame 墙钟中位数 / p95 | 3.05 / 6.61ms | 0.047 / 1.51ms |
| 未命中字形数 | 5962 | 3377 |
| 字形生成总耗时 | 264.52ms | 139.80ms |
| 字形生成每次更新中位数 / p95 | 2.81 / 6.28ms | 0 / 1.45ms |
| 字形锁获取每次更新中位数 | 0.0112ms | 0.0031ms |
| trace 丢弃记录 | 0 | 0 |

单分屏字形生成占全部更新累计墙钟时间约 93%，支持“首次生成字形是该冷负载主要开销”的判断。
四分屏使用不同但有重叠的字流，共享 CPU 字体网格，不能按分屏数线性外推。
本轮只补齐计时，不引入启动预热或并行光栅化。

## 回归与构建

- 原生 ReleaseLocal：总计 362 项，361 通过、1 项既有 Benchmark 跳过、0 失败。
  参数化实例均执行；真实 Metal 4 GPU 上窗口合成器 9 项方法全部通过。
- 新增 2 种动画 × 3 种颜色模式回归：动画画面变化，邻接静止分屏逐像素不变；
  后续纯动画帧不增加内容重绘计数；滚动反向覆盖历史冻结。
  三种颜色模式的滚动 trace 均记录一次冻结。
- 光标／滚动回归日志各自丢弃记录数为 0、2、3、0、1、0；
  缓存未重绘断言来自实时窗口统计，不依赖可能丢弃的 trace 计数。
- 定向 Zig：176/176；脚本测试：40 通过，4 项因没有 fish 跳过。
- SwiftLint、Zig 格式、typed bridge、scope、版本一致性检查通过。
- 非测试 ReleaseLocal 0.4.0 / 构建 30 构建通过；未打包 ZIP 或发布。

最终补齐异常路径的命令缓冲收尾后，窗口合成器 9 项方法再次通过。
[完整回归及最后复验的原生摘要](2026-09-27-final-composition-tests.json)已归档；
完整回归的大型 xcresult 由仓库保留策略自动清理。最后复验结果位于
`$TMPDIR/cghostty-tests-b569378685f8/ManagedTestResults/run-1790508081018407000-b283cf0455c546a59fc66f199013851b.xcresult`。

归档：[渲染汇总](2026-09-27-final-composition.json)、
[压缩原始 trace](2026-09-27-final-composition-traces.json.gz)、
[前台时序汇总](2026-09-27-final-composition-display.json)、
[压缩原始呈现样本](2026-09-27-final-composition-display-raw.json.gz)。

## 范围与后续

正式应用继续使用 CAMetalDisplayLink。本轮没有恢复 IOSurface、窗口缩放或全屏，
没有加入中文预热线程、并行光栅化、分屏准备线程池或共享 GPU 图集。
显示时钟替换需要在完整终端中验证按需唤醒、可变刷新率动画、nextDrawable 等待及跨窗口行为；
共享 GPU 图集还需处理多窗口队列、扩容和资源寿命，不能仅依据单窗口顺序提交就假定安全。
外接 60Hz 显示器、高速摄像新旧呈现对照和长期能耗尚未测量。
