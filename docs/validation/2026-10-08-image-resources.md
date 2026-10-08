# 2026-10-08 图片加载与提交资源计量

## 范围

从本地 `1b4cb4fac` 开始，继续用户授权的资源所有权检查。每项实现验证后独立提交；最终实现源码为 `0e799a8ec`。版本保持 0.5.5 / build 45，固定 Zig 0.16.0、macOS 27 arm64，构建及测试串行执行。

本轮补齐选定资源的诊断，不设置新的全局硬预算，不改变普通粘贴接收、图片协议限额或回收策略。当前 GPU 所有权、CPU 引用和提交足迹具有不同统计口径，不能相加当成 RSS 或 GPU 唯一分配总量。

## 独立提交

| 提交 | 改动 |
| --- | --- |
| `1e2221e38` | 扩充 renderer 的 Zig/C/Swift 快照，计量当前 Kitty 图片、背景、滚动纹理和待上传像素；替换与延迟卸载状态在真正释放前仍计入。 |
| `f4067a273` | 增加无分配头的 PeakAllocator，记录图片完成阶段的同时存活字节峰值；图片存储快照区分预留与实际像素，聚合所有已初始化屏幕。 |
| `e550351ec` | 从每次提交后的 Metal residency set 读取 footprint，普通 GPU 完成或同步快照退休后扣除，原子记录同时提交的足迹峰值。 |
| `0e799a8ec` | 背景文件读取、PNG/JPEG 解码也计量阶段峰值，加载线程在 draw_mutex 外用原子最大值发布诊断。 |

## 统计合同

| 计量 | 包含 | 边界 |
| --- | --- | --- |
| `RendererResources.gpuAllocatedBytes` | 当前帧槽的字体 atlas | 保留上一轮语义，不是所有 GPU 资源。 |
| `gpuImageAllocatedBytes` / `gpuBackgroundAllocatedBytes` / `gpuScrollAllocatedBytes` | 当前 renderer 图片状态、背景和滚动池持有的纹理；Metal allocatedSize 包含资源 padding | 不包含已脱离这些所有者、仍被提交引用的旧资源，或已交给外部调用者的快照纹理。 |
| renderer/capture 的 pending CPU 字节 | 各状态引用的 RGBA 像素长度 | 同步输出缓存、待接收 frame 和 renderer 可共享像素；不能按状态相加当唯一分配。 |
| `ImageResources.storageReservedBytes` | 已初始化主/备用屏的协议存储预留，含根图与动画帧 | pending payload 也有预留，预留不表示已分配像素。 |
| `storagePixelBytes` / `pendingReservedBytes` | 实际根图/动画像素与未到达 payload 的预留，分别计量 | 不包括 placement、hashmap、动画元数据或 allocator overhead。 |
| `loadingBytes` / `loadingCapacity` | 当前分块传输已接收数据长度与 backing buffer 容量 | 不是整个接收过程的重分配峰值。 |
| `completionPeakBytes` | 一次 complete() 中输入容量、解压输出、PNG 像素、heap scratch 与最终所有权转移的最大同时存活请求字节数；成功/失败都记录 | 排除之前的分块/文件接收、栈和 child allocator overhead；每个 storage 保存自身生命周期内的最大值，跨屏取最大值。不是累计分配或新额度。 |
| `cpuBackgroundLoadPeakBytes` | 背景加载方法内文件读取、解码输出和 heap scratch 的最大同时存活请求字节数 | PNG/JPEG 原限额保持；renderer 生命周期内保留最大值，移除图片不会清零。 |
| `gpuSubmittedResidencyBytes` / `gpuSubmittedResidencyPeakBytes` | 尚未退休提交的 residency set footprint，以及同时存活 footprint 之和的历史峰值 | SDK allocatedSize 是最后 commit 的 footprint，可能包含 set 内部分配。帧槽/不同 pane 可引用同一资源，也包含借用窗口资源；不是唯一分配，也不能加到所有者字节数中。 |

快照接口不为资源统计分配新的缓冲。renderer 快照持有 draw_mutex 和 grid 共享锁；terminal 图片快照单独持有 terminal mutex。两次查询不是跨 CPU/GPU 的同一原子快照，调用方保留 surface 并在后台读取。

PeakAllocator 只转发 child 的原始分配布局，成功 alloc/resize/remap 更新 live/peak，失败请求不增加统计，free 扣除 live。complete() 的已有输入容量作为初始 live；存活输出仍能交还同一个 child allocator，wrapper 自身可以结束。测试覆盖成功扩缩容/remap、失败扩容/分配、外部所有权转移，以及真实 Wuffs 的逐次 OOM 清理。

Metal 侧每个提交读取一次 footprint，不增加每个 texture/buffer binding 的诊断数组。普通完成先移除命令引用，再扣除足迹、释放帧槽；同步快照在等待 GPU 完成后的调用线程执行相同退休过程。资源查询不提交新的 GPU 工作；draw_mutex 仍可等待正在运行的显式快照。

## 实测样本

结构化原始数据见 [图片资源 JSON](2026-10-08-image-resources.json)。这些是确定 fixture 下的采样或阶段峰值，不是大分屏压力基准。

- 16×16 RGBA 分块传输：首块 payload 512 字节，loading capacity 为 896；完成后存储像素/预留均为 1,024，loading capacity 为 0，完成阶段峰值 2,688 字节。
- 随后传入 1 像素 PNG：两个图片合计存储像素 1,028 字节，completion peak 为 44,995 字节，包含解码器临时分配。不能把四字节像素当作完整解码开销。
- 备用屏再接收四字节图片：screen count 为 2，合计像素/预留 1,032，跨屏 completion peak 仍为 44,995。
- 2×2 背景图片：加载峰值 44,823 字节（约 43.8 KiB），当前 GPU 背景纹理 allocatedSize 为 128。损坏的替换保留旧图，文件修复后可重试；移除后当前背景纹理字节为 0，加载峰值保留。
- 两个可见 pane 的样本：每个持有一个滚动纹理；提交峰值包含借用窗口资源、帧槽资源和 residency 内部 footprint，不能把两个 pane 的峰值相加宣称物理显存峰值。暂停窗口更新并执行同步快照后，当前提交足迹为 0，峰值保留。

测试最初把 ESC 协议字节通过 sendText 送给 cat，资源断言失败：sendText 按普通粘贴语义过滤 ESC。fixture 改成由子进程读取测试文件并输出协议，输入只发送文件路径；产品过滤行为保持。所有 readiness 等待均基于子进程标记、完成 revision 或资源退休状态，有截止时间，不用固定启动等待。

## 验证

- 每项目标核心：图片状态 83/83；完成峰值/存储 169/169；提交/退出 87/87；背景/分配 93/93。套件重叠，不相加。
- 每项目标原生：图片/滚动 35/35；完成峰值/屏幕 20/20；提交/生命周期 43/43；背景 16/16。套件重叠，不相加。
- 最终 Debug 核心全套：3779 passed / 3784 total，5 skipped，0 failed，72/72 构建步骤成功；最终 ReleaseFast：185/185，通过实际 `-Dtest-optimize=ReleaseFast` 编译。
- 最终完整 GhosttyTests：509 passed / 511 total，2 skipped，0 failed，80 个 suite。跳过的是已有 benchmark 和未显式启用的隐藏 surface 探针。
- 独立 GhosttyUITests/GhosttySurfaceLifecycleUITests：2/2 通过，关闭分屏/关闭标签后撤销都恢复原 shell 会话。未运行其余 UI suites，不能称 UI 全套通过。
- 两个 target 同一次 xcresult：511 passed / 513 total，2 skipped，0 failed。managed 验证器确认 GhosttyTests 实际执行 509 项、指定 UI suite 实际执行 2 项；源码为 `0e799a8ec`，archive 来源检查通过。最终复跑再次记录了本页图片、背景与 pane 样本。
- scope/typed bridge、全仓 Zig fmt、Swiftlint strict、版本检查通过；Python 构建脚本未修改。

## GhosttyUITests

GhosttyTests 在测试进程内直接调用应用对象和内部 C/Zig 桥接，其中包括真实 PTY、AppKit 窗口和 Metal 集成测试。GhosttyUITests 是独立 XCTest UI target，通过 XCUIApplication 启动完整应用并模拟用户操作，检查 AX 窗口/标签/分屏或截图像素。

例如 GhosttySurfaceLifecycleUITests 关闭标签或分屏后撤销，使用 shell 变量验证恢复的是原来的 PTY 会话；光标/滚动 UI suites 还采样截图。默认 native test 用 `-skip-testing GhosttyUITests`，只有 `--ui-tests` 显式启用。运行 UI suite 会操作真实桌面应用，它使用临时配置/独立 defaults suite，并由测试恢复粘贴板。

最终原生/UI 复跑命令（archive 已由本轮 native build 更新）：

```sh
python3 scripts/build.py native --action test --skip-core --ui-tests \
  --only-testing GhosttyTests,GhosttyUITests/GhosttySurfaceLifecycleUITests
```

临时日志、xcresult 与摘要位于 `/private/tmp/cghostty-round7-*.log` 和 managed test result 目录，依已有保留/清理策略维护；长期证据是本页计数、统计合同及原始 JSON。本轮只本地提交，没有推送、tag、发布包或安装替换。

## 后续

可以据此扩展可见大分屏与反复大图替换的峰值探针，再分析哪些额外副本、缓存保留和异步退休需要优化。完成阶段峰值尚未覆盖早期分块接收、动画合成、全部 font/CPU 缓存、command allocator 内部占用和外部快照持有。唯一资源身份和跨所有者去重仍需单独设计，当前诊断不足以推出一个安全的全局硬额度。
