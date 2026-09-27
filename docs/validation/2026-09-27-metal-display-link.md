# CAMetalDisplayLink 第一阶段验证（2026-09-27）

本轮实现可选的每分屏 CAMetalLayer + CAMetalDisplayLink 后端，默认仍为
IOSurface。配置在应用启动时读取，设置 `render-presentation = metal-display-link`
后重启生效；`render-frame-latency = 1` 或 `2` 用于实验。

本文保留第一轮 Debug 结果；后续 ReleaseLocal 对照及缩略图兼容性修复见
[时序与快照复查](2026-09-27-metal-display-link-followup.md)。

## 实现范围

- 每个渲染线程运行 NSRunLoop，并把现有 libxev kqueue 和最近计时器截止时间
  接入 CFRunLoop。没有固定间隔轮询，也没有新增第二个调度线程。
- 只在 display link 回调中使用系统提供的 drawable。Metal 4 队列依次执行
  waitForDrawable、commit、signalDrawable、present，无逐帧主线程 IOSurface 中转。
- GPU 完成后归还纹理引用；呈现回调单独保留一个可脱离渲染器的状态，避免关闭后访问
  已释放的 trace。空闲暂停 link，输出、动画或可见性变化按既有调度规则恢复。
- 保留动画目标的实际更新时间，将预计呈现时间转换到动画的 awake clock 后取样。
- 窗口外部尺寸已固定，但分屏、字号、换屏、视图换窗仍可能改变 drawable 尺寸。
  drawableSize 随渲染像素尺寸更新，不删除这些路径。
- `presentsWithTransaction` 保持关闭。原生视图、输入、无障碍及现有离屏合成继续保留。
  刷新率范围暂使用系统默认值。

本轮没有合并窗口内各分屏的图层/线程，也没有把全部 cell rebuild 移入显示回调。
这两步仍以第一阶段的稳定性及延迟结果为前提。

## 验证

- macOS Debug 原生回归：354 个测试、47 个 suite 通过。
- 新增参数化测试分别运行 IOSurface、Metal latency 1、Metal latency 2；每组输入
  220 个标记，等待 PTY 内容和 GPU 完成版本推进，随后隐藏、换窗、改变视图尺寸并恢复。
  单独运行三组通过，随后完整回归再次通过。
- Zig 定向回归：87/87 通过，72/72 构建步骤成功。涵盖 NSRunLoop 的计时器及跨线程唤醒、
  动画时钟转换、CursorMotion、呈现逻辑、配置合法值及模板生成。
- trace 汇总器 4/4 测试通过，包括跨 surface 序号隔离及无有效显示时间的 drawable。
- Swiftlint、scope 和配置桥接检查通过。

本轮的窗口测试不是完整的桌面视觉验收：尚未覆盖所有透明度、背景/Kitty 图片、
搜索叠层、截图/拖动预览、混合 DPI 屏幕组合及长时间压力场景。

## 第一轮显示时间记录

这是同一台 Mac 上的 Debug 构建，开启 trace，使用程序注入的 PTY 输入，关闭光标效果及闪烁。
三个配置顺序执行。220 次输入更新不是 220 次物理按键到屏幕测量，GPU 完成版本也不是
某次输入已显示的证明。原始汇总见 [JSON](2026-09-27-metal-display-link.json)。

| 配置 | 有效显示时间样本 | 提交到显示 median | p95 | p99 | 丢失 trace 记录 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Metal latency 1 | 218 | 41.1677 ms | 41.3440 ms | 41.4392 ms | 0 |
| Metal latency 2 | 218 | 41.1880 ms | 41.2958 ms | 41.4850 ms | 1 |

提交到显示用 `drawable.presentedTime - present() 调用前的 CACurrentMediaTime()` 计算，
两者都属于 Core Animation media clock。`displayed` 事件到达时刻不是呈现时刻。
汇总按 renderer 的本地提交序号配对；0 时间被排除，缺失记录不补值。
latency 2 丢失一条诊断记录，表中只报告现存配对样本。

IOSurface 组完成 220 帧 GPU 工作，记录 217 次异步图层赋值，主队列等待中位数为
0.0546 ms。图层赋值与 drawable 的呈现时间终点不同，不能用这两个数比较后端延迟。
Metal 两组的预测显示时刻与 reported presentedTime 的误差中位数约 0.0022 ms；
这只是系统时间报告的一致性，不是物理扫描输出的测量精度。

当前结果没有证明 latency 1 比 latency 2 更快，也没有证明新后端优于 IOSurface。
因此保留实验开关和默认旧路径，不以此次 Debug 数据推进每窗口合成器。

## 后续测量条件

使用相同 ReleaseLocal 构建、窗口内容、显示器/刷新设置及负载，预热后分别采集
IOSurface、Metal 1、Metal 2 的至少 200 个有效输入到可见画面样本。
三组需要相同的外部测量终点，例如高速摄像与可识别输入/画面标记；不能混用 GPU 完成、
CALayer 赋值和 presentedTime。记录 median、p95、p99，并分别观察空闲唤醒和持续动画。
还需检查当前约 41 ms 提交到显示间隔在不同构建、显示设置及连续运行场景下是否复现。

trace 仅记录计数与时序，不含终端文本或输入。启用方式：

```ini
render-trace = true
render-trace-directory = /private/tmp/cghostty-render-trace
```

退出测试进程以刷新尾部记录，再执行：

```sh
python3 scripts/summarize-render-trace.py /private/tmp/cghostty-render-trace
```
