# Unicode 18、模式查找及同步输出适配验证（2026-09-24）

基线提交：`36ff5a852`。版本保持 0.2.6（build 16）。环境：macOS 27.0（26A428）、Apple Silicon arm64、Zig 0.16.0；原生测试使用 ReleaseLocal。

## 上游参考与本地方案

### Unicode 18

参考 [Ghostty 9cdbf798d904](https://github.com/ghostty-org/ghostty/commit/9cdbf798d904769d0b3514658f3684b24850487d)，将 uucode 固定到 `9d55524551411b493cca41ca06363625d90aff1e`，同时更新内容校验值。该依赖要求的 Zig 0.16 与本项目一致。

适配 BreakState 从枚举到 packed struct 的变化：初始化改用空结构，预计算使用依赖提供的 `table_len` 和 `fromTableIndex`。保留本地字素边界预计算、8 KiB 查找表及既有宽度逻辑。新增 Unicode 18 GB9c 回归，覆盖没有前导辅音时的 Indic linker，以及 GCB=Other 的 linker；结果和依赖状态机一致。

### 终端模式查找

参考 [Ghostty 01a8d3af223d](https://github.com/ghostty-org/ghostty/commit/01a8d3af223dbb5ba3ddbf0a8f3d7820e304880a)，引入编译期整数集合，用排序后的二分查找替换逐项匹配。保留本项目模式清单、默认值、禁用项及报告行为。

模式编号超过 15 位时直接返回未知，避免与 ANSI 标志位混淆。穷举全部 65,536 个输入和两个命名空间，对照原始条目扫描验证结果。这是算法与结构调整，本轮没有单独测量查找性能。

### 同步输出 mode 2026

参考 [Ghostty 56a3437a7f51](https://github.com/ghostty-org/ghostty/commit/56a3437a7f51796d7946584043229c2f15c70583) 的完整帧保留思路。上游涉及通用 TerminalStream 和独立 C API；cghostty 的 GUI 实际使用 `termio/stream_handler.zig`，因此在 GUI 输入与渲染器之间实现适配，没有恢复独立 SDK，也没有添加 GUI 不会调用的通用接口。

原先渲染器只观察 mode 2026 的最终状态。同一次 PTY 读取中若出现“结束上一帧、开始下一帧”，输入线程会持锁处理整段数据；渲染器可能始终只看见开启状态，错过已经完成的中间画面。

新方案在每次真正开始同步输出时保存此前完成的视口。渲染器可接收这份完整画面，随后暂停读取正在更新的终端，直到结束同步输出或触发既有超时恢复。

- 只保留一个待接收视口，后续完整帧替换旧帧；不复制整个滚动历史，也不建立无界帧队列。替换期间短暂同时持有新旧两份待接收数据，渲染器仍保留其当前帧。
- 文本、样式、Kitty 图片像素及位置由快照拥有。GPU 资源仅在渲染线程处理；图片代次相同时复用现有资源。
- OSC8 高亮坐标在输入线程持锁时计算，避免原终端页被替换后解引用旧页面。正则链接继续使用现有缓存。
- 独立采集完整视口，并保留下一次正常渲染所需的全量刷新标志，避免两个消费者互相消耗脏标志。
- 输出自动滚动的跟踪移到共享状态，冻结帧和正常帧使用相同判断，保留没有新输出时用户手动滚动的位置。
- 重复开启 mode 2026 不采集半帧，也不延长超时；保存/恢复模式走相同转换路径。取消的定时器回调直接退出，避免重置后续同步状态。
- 结束同步、尺寸变化、终端重置和超时后使用实时终端状态，并释放不再需要的待接收帧。

## 验证

- 最终核心定向测试：**165/165 通过，72/72 构建步骤成功**。
- 最终原生测试：**44 个套件、336 项测试，335 通过、1 跳过、0 失败**，结果包状态 Passed，ReleaseLocal 应用及内部桥接构建成功。
- macOS arm64 范围、版本一致性、本地化、Swift 6 配置、修改及新增 Zig 文件格式、差异空白检查通过。

新增回归覆盖：Unicode 18 linker、整数集合和全部模式编号、同一次输入中的同步输出结束/重新开始、重复开启与定时器消息次数、模式保存/恢复、快照与实时数据隔离、尺寸变化/重置/超时清理、分配失败后的正常重绘、终端页替换后的 OSC8 坐标、Kitty 图片替换与资源所有权、共享自动滚动状态。

核心测试环境没有原生应用，因此 GUI 序列测试通过受限解析适配器调用真实 GUI 同步输出处理函数；无关窗口/剪贴板回调不在该测试中实例化。完整 GUI 分发的编译由原生构建验证。原生测试计数包含既有套件，不代表新增了 336 项同步输出测试。

本地证据：

- 核心日志：`/private/tmp/cghostty-upstream-core5.log`
- 原生日志：`/private/tmp/cghostty-unicode18-hold-native3.log`
- 原生结果包：`/private/tmp/cghostty-unicode18-hold-native3.xcresult`

## 复现与边界

将项目固定的 Zig 0.16.0 和 Nushell 放入 PATH 后执行：

```sh
python3 scripts/build.py test \
  -Dtest-filter='render hold' -Dtest-filter='GUI synchronized' \
  -Dtest-filter='kitty renderer' -Dtest-filter='synchronized and live' \
  -Dtest-filter=unicode -Dtest-filter=grapheme \
  -Dtest-filter=modeFromInt -Dtest-filter=ComptimeIntSet --summary all
nu macos/build.nu --configuration ReleaseLocal --action test
python3 scripts/check-scope.py
python3 scripts/check-versions.py
python3 scripts/check-localizations.py
python3 scripts/check-swift6.py
```

同步输出方案优先保证完整帧和资源生命周期正确。每次真正开始同步输出会增加完整视口采集和可见 Kitty 图片 CPU 数据复制；内存范围受视口和可见图片约束，但本轮没有测量持续 TUI 输出的吞吐、CPU/GPU 占用或峰值内存，不能据此宣称整体性能提升。

没有运行完整核心测试套件，也没有完成真实 TUI 持续输出、动画图片和鼠标交互的人工视觉压力验收。本轮未升版、提交、打标签、发布或替换已安装应用。
