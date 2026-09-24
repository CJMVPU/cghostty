# 原生刷新、图片、高亮和背景行上传验证（2026-09-24）

基线：`6e1442024`。版本保持 0.2.7（build 17）。本轮按 cghostty 的 macOS arm64 原生应用与内部 Metal 渲染结构实现四项改动。

## 实现范围

1. 原生滚动容器分别观察鼠标样式与外观；外观只在滚动条可见性或背景明暗变化时应用。滚动条跟踪区域位置不变时保留原对象。相同终端、相同像素尺寸的重复通知跳过设置尺寸的桥接调用，主线程只发布队列中最新的尺寸。字体单元尺寸回调独立刷新滚动比例与核心网格尺寸，即使窗口不触发布局；屏幕 backing 属性变化强制通知核心，已释放终端不接收排队发布。核心本来就会跳过相同尺寸的重设，本轮减少的是桥接和原生状态发布工作。
2. Kitty 图片上传表在没有待处理变化时跳过扫描；上传失败保持待处理状态。放置数据按三个独立帧槽缓存版本，快照接管递增版本，写入失败不能提交版本。虚拟占位符按内容、视口、字体单元尺寸和图片状态失效；普通放置主要跟踪视口与网格几何。准备放置时分配失败保留脏标记以便重试。
3. 搜索高亮以复制出的页面地址及 serial 建索引，再定位当前块覆盖的可见行；不在终端锁外解引用页面。先构建候选范围，逐行比较后只替换变化的行，保留选中匹配的优先级。无搜索帧不分配索引。原遍历方式保留用于结果对照回归；生产渲染入口使用新方式。
4. 背景单元沿用行重建边界记录版本，各可用帧槽仅复制自己缺失的背景行，连续行合并复制。前景保持原变长布局，使用独立版本。布局变化、首次使用和写入失败后重试走全量路径。不写入仍由 GPU 使用的帧槽，也不保留额外的背景像素影子副本。

## 确定性工作量

以下是固定输入下的处理量，不能直接换算成日常终端速度、CPU/GPU 占用或功耗改善比例。

| 场景 | 结果 |
| --- | --- |
| 240×80 背景，三个帧槽轮流消费，30 次单行更新；不计初始化 | 全量策略 2,304,000 字节；按行策略 83,520 字节；每次同步后缓冲区全部像素与当前内容一致 |
| 图片放置初始化后，30 个不变帧 | 放置缓冲区重写 0 字节；快照接管后各帧槽独立刷新 |
| 240×80 视口、160 个单行匹配、1 个选中匹配、1 个跨页匹配 | 原遍历 13,040 次块检查；新方式 163 次块查找、240 次实际覆盖行处理；结果相同 |
| 相同搜索高亮再次应用 | 重新标脏 0 行；跨页范围、首尾列、优先级及过期 serial 与原算法对照 |
| 同一像素尺寸通知 100 次 | 新增设置尺寸桥接调用 0 次；字体改变仍发布新网格尺寸 |
| 四次鼠标样式切换 | 指针正常更新，外观应用和尺寸请求计数不增加 |

图片的内容键复用现有保守文本变更代数，部分不影响图片的内容修改仍可能触发重建。全屏内容变化会使背景行上传接近全量；本轮没有改造前景字形缓冲布局。

## 验证与证据

- 核心首轮：86/86 通过，日志 `/private/tmp/cghostty-four-core1.log`。
- 最终核心扩大回归：200/200 通过，72/72 构建步骤成功；日志 `/private/tmp/cghostty-four-core3.log`。包括背景帧槽、Kitty、搜索、RenderState、同步输出、跨页高亮及分配失败清理。
- 原生回归：345 项，344 通过、1 项既有基准示例跳过、0 失败；结果包 Passed。包含真实 PTY 搜索、Kitty 图片像素及同步输出检查，以及新增原生生命周期回归。
- 原生结果：`/private/tmp/cghostty-four-native2.log`、`/private/tmp/cghostty-four-native2.xcresult`、`/private/tmp/cghostty-four-native-summary.json`。
- 平台范围与内部桥接检查通过：`/private/tmp/cghostty-four-scope.log`；130 个原生 UI/功能文件通过。
- 修改文件的 Zig 格式、三个 Swift 文件严格 lint 和差异空白检查通过。
- 版本、本地化（170 个命令、3 种语言、510 个译文）、Swift 6 严格并发配置检查通过。

复现命令（使用仓库指定 Zig 0.16.0 及 Nushell）：

```sh
python3 scripts/build.py test -Dtest-filter='renderer.cell' -Dtest-filter='background row upload' -Dtest-filter='kitty renderer' -Dtest-filter='kitty placement uploads' -Dtest-filter='CellUpload' -Dtest-filter='terminal.render' -Dtest-filter='render hold' -Dtest-filter='GUI synchronized' -Dtest-filter='search' --summary all
nu macos/build.nu --configuration ReleaseLocal --action test
python3 scripts/check-scope.py
python3 scripts/check-versions.py
python3 scripts/check-localizations.py
python3 scripts/check-swift6.py
```

缓冲区失败由内存替身注入，不代表在真实 Metal 设备上诱发内存耗尽。没有运行完整核心套件，也没有做人工跨屏缩放、长时间多窗口压力或端到端性能基准。本轮没有升版、提交、发布或替换已安装应用。

扩大回归的第一轮中，跨页用例发现初始空白视口实际位于单个页面，未覆盖预期边界；已改成基于真实页面身份滚动至跨页状态后再验证。前期失败不作为最终通过依据。
