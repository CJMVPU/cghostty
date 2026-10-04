# 2026-10-04 架构、终端核心与删减审查跟进

## 来源与边界

- 初始 `HEAD`、`main`、`origin/main` 与 `v0.5.4^{commit}` 均为 `6cd8cb252248a0c9dd2721fb6b2775e074c935e3`，工作区干净。
- 工作分支为 `audit-core-followups`；`main` 保留。版本/build 保持 **0.5.4/44**，没有 bump、tag、push、发布、安装、issue 或 PR。
- 环境：Apple M5 Pro / arm64，macOS 27.0.1，Xcode 27.0 (27A266a)，仓库固定 Zig 0.16.0。
- 源码工作可以并行；所有构建、测试和基准均串行。没有操作桌面 UI、尝试 UI 自动化或更改系统设置。
- 系统阴影是此前已经接受的产品选择，本次不重新调整。

## 独立本地提交

沿用审查时的编号。

| 编号 | 提交 | 结果 |
| --- | --- | --- |
| 1 | `8d7d416c5` | 分屏导航、zoom、tree replacement 和 undo restore 直接登记焦点 intent，复用现有取消/附件完成状态机 |
| 2 | `191fef321` | surface 回调同步复制显示投影，异步不持有 C config；app 回调仍克隆完整配置 |
| 3 | `82427ec08` | insert/deleteLines 共用方向明确的 `shiftLines`，净删 144 行，保留滚动日志和 tracked pin 扩容顺序 |
| 4 | `54b9224b1` | active/viewport 向前搜索以 prepend 加入先前页，保持跨页字节及 metadata 时间顺序 |
| 5 | `eb647c5f4` | ISO protected ECH 的宽字边界拆分保留受保护宽字、grapheme 和上一行 spacer |
| 6 | `e51a3fbbe` | 大 PTY 输入使用一个 owned buffer/request，复用 libxev partial write/FIFO；统一完成及 teardown 清理 |
| 7 | `86d10b1bc` | 搜索编码 scratch 保留容量，成功、反向编码和 OOM 返回均清空长度，cell map 仍独立拥有 |
| 8 | `6ef80abf8` | 新增逐循环 resident/cold reflow 测量及可复现 runner，未实施 lazy reflow |
| 9 | `000ab97cb` | 删除无人调用的 Zig SplitTree 与导入/导出，删 2,486 行；保留 Swift 原生 SplitTree |
| 10 | `3c89129d4` | 删除旧 editor 辅助及无调用 XDG config/cache/terminal-exec 接口；保留 SSH state 路径并校正生成手册 |

聚合验证另有一个测试夹具提交 `60090a1c8`：在既有 AX 缓存测试输出 `ready` 前完成 DSR 往返，等待初始 resize 已被 IO mailbox 消费；产品 AX 实现和缓存断言均未改动。

最终 scope 检查发现投影的 borrowed initializer 被放在 UI 文件，违反既有 C ABI 边界。`59e8b2078` 将它移到 `Ghostty.ConfigSnapshot.swift`，从 SurfaceView 移除 GhosttyKit import，未改变解码或显示行为。

## 正确性与所有权证据

- 焦点：原实现的七个参数案例实际失败。修复后覆盖较新的 surface 选择、文本编辑及跨 owner 移动，均通过。
- 搜索：旧实现不能命中跨 page soft-wrap，并错误排列 multi-page active 结果；两项实际红测转绿。三页 UTF-8 坐标、node/serial/chunks 与每次分配失败路径也通过。
- 擦除：三个 VT SPA/EPA 回归中，旧实现的 tail/grapheme 和前行 spacer 案例实际失败；修复后通过。没有改变现有 ECH pending-wrap 语义。
- surface 投影：旧回调使 clone counter 增加 1，实际负测失败；新回调增加 0。测试在主队列发布前 reload/free 源配置，检查中文字体字符串、颜色、透明度、blur、shadow、主题、scrollbar、OSC 11 缓存以及 app/其他 surface 隔离。app callback 仍增加 1，并保留 bindings 所有权。
- 行移位：入口保留 revision/区域边界/Kitty dirty/cursor restore 的顺序；移动、跨页容量扩展、清除及 metadata reset 分支保持原逻辑。既有密集 hyperlink、scroll journal、tracked pin 与 Kitty margin 回归通过。
- PTY：真实 raw PTY 覆盖 64 KiB partial write、写后原输入被改写、dense CRLF、bracketed paste 后按键 FIFO、退出拒收、pending teardown 和所有分配失败。completion error 检查使用真实 callback 共用的资源释放入口，错误原样返回。
- XDG：`state`/`dir` 实现与删除前逐字一致；独立测试环境覆盖指定 state、显式 home 的原优先级，以及 HOME fallback/空变量/subdir。SSH DiskCache 继续调用 state。

## 搜索分配基线

同一 resident 三页 fixture，预热一次，重复 100 次 clear + append/prepend + UTF-8 命中校验。计数只覆盖搜索 window 的 allocator，包含每页 cell map；不包含页面解码或 fixture 构建。

| 状态 | 额外分配次数 | 累计分配字节 |
| --- | ---: | ---: |
| 复用前 | 600 | 82,500 |
| 复用后 | 300 | 40,800 |

剩余 300 次属于每个 metadata 独立拥有的坐标映射，不能声称整个搜索零分配。另一既有 1,000 matches / 100 consumers probe 仍为 0 额外分配。

## PTY 前后测量

真实 raw PTY；固定 payload 在计时外生成。每个规模的 fast、每读取 4 KiB 暂停 1 ms 的 slow，以及消费者暂停 50 ticks 的 paused 均串行运行；每组预热一次、重复三次。全部检查字节顺序和最终队列清空，两个阶段内部 Exec/probe SHA 均保持稳定。

| 输入 | 旧请求数 | 新请求数 | 旧完成后保留字节 | 新完成后保留字节 | 新输入排队分配字节 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 MiB | 16,384 | 1 | 6,376,692 | 588 | 1,049,164 |
| 8 MiB | 131,072 | 1 | 49,997,580 | 588 | 8,389,196 |
| 32 MiB | 524,288 | 1 | 169,649,496 | 588 | 33,555,020 |

这些字节来自 write allocator 计数器，排除预生成输入和 loop 自身，**不是进程 RSS**。旧 JSON 的 `pool_allocated_bytes` 与新 JSON 的 `write_allocated_bytes` 都记录同一计数器的累计分配；新名称包括 owned payload，更准确。

32 MiB fast 的三样本中位数：enqueue 13.385 → 2.297 ms，drain 8,708.930 → 1,434.723 ms；slow drain 20,457.253 → 14,830.961 ms。三样本可验证请求/内存放大和明显差异，不支持精确速度比或 UI 延迟结论。paused 仅测 headless loop tick，没有测控制消息响应或渲染帧。

**总待写字节硬上限尚未实现。** 本次消除了 64B request 放大与完成后的大池保留。连续多个大输入仍可积累 owned payload；生产者背压、拒收/排队政策需要后续单独设计。

原始逐次资源结果：[baseline](2026-10-04-core-audit-pty-baseline.json)、[after](2026-10-04-core-audit-pty-after.json)。复现：

```sh
python3 scripts/benchmark-pty-write.py baseline --out /tmp/pty-baseline
python3 scripts/benchmark-pty-write.py after --out /tmp/pty-after
```

`baseline` / `after` 是记录标签，不会自动切换实现。旧 probe 测量时未提交，已从后续提交精确重建并保存为 [`pty-write-baseline.zig`](../../scripts/benchmark-fixtures/pty-write-baseline.zig)；SHA-256 `c6b39ae533df750c5394fad94f48c773fac31e65178e0a876da509f45cfeffbc` 与原记录一致。该 fixture 只供旧实现复现，不参与生产编译。

要比较两个阶段，在独立 checkout 中串行运行，避免改动当前分支：

```sh
git worktree add --detach /tmp/cghostty-pty-before 54b9224b1
git worktree add --detach /tmp/cghostty-pty-after e51a3fbbe
cp scripts/benchmark-fixtures/pty-write-baseline.zig \
  /tmp/cghostty-pty-before/src/termio/pty_write_probe.zig
git show e51a3fbbe:src/termio.zig > /tmp/cghostty-pty-before/src/termio.zig
export PATH="$PWD/.tools/zig-aarch64-macos-0.16.0:$PATH"
python3 scripts/benchmark-pty-write.py baseline \
  --repo /tmp/cghostty-pty-before --out /tmp/pty-before-rerun
python3 scripts/benchmark-pty-write.py after \
  --repo /tmp/cghostty-pty-after --out /tmp/pty-after-rerun
```

baseline Exec SHA-256 为 `588c18616eb033c1ce10c3ec15e03d08df121e746ece98d678cb01b2fc9aac4e`；after 的 Exec/probe SHA 均由 `e51a3fbbe` 精确匹配 JSON。原测量阶段另有未提交文件只记录 status，没有全树快照；这里精确复原**被测 Exec + fixture**，不宣称复原原整树或测试二进制。72 份临时 log 的 metric 已与 JSON 逐次核对一致。两个阶段保持相同 warmups/repeats/规模/模式；wrapper 墙钟包含编译，不作为性能指标。

## Reflow 基线

固定 seed `0xB3`、300,000 行、47,074,329 字节 corpus，含长短行、空行、style、wide 和 grapheme。所有进程读取同一已生成文件；120×80 → 60×80 → 120×80 为一个循环。每配置预热 3 次、重复 15 次，每进程 25 个循环，共 108 个串行进程、2,250 个记录循环。

cold 在**每个循环计时前**压缩历史，要求实际 compressed pages > 0；计时排除 corpus replay、压缩准备、打印及内存快照。RSS 为整个进程峰值，包含这些准备工作；page backing 字节估计与 RSS 分开记录。

| scrollback 预算 | 模式 | 首循环 p50 ms | 后续循环 p50 ms | 后续循环 p95 ms | 整进程峰值 RSS 中位数 MB |
| --- | --- | ---: | ---: | ---: | ---: |
| 5 MB | resident | 0.641 | 0.541 | 0.633 | 13.52 |
| 5 MB | cold | 1.474 | 1.349 | 1.534 | 14.75 |
| 50 MB | resident | 5.981 | 5.664 | 5.885 | 59.03 |
| 50 MB | cold | 15.257 | 15.214 | 15.808 | 75.40 |
| 200 MB | resident | 23.902 | 23.803 | 24.496 | 208.76 |
| 200 MB | cold | 62.351 | 62.137 | 63.457 | 267.45 |

MB 为十进制。实际初始 page raw backing 分别为 4,915,200 / 49,971,200 / 199,884,800 字节，不能把预算当实际历史占用。三个规模首循环分别从 4,685 / 48,245 / 193,181 行变为多一行，后续稳定；JSON 保留每循环的行数变化及首次/后续分位数。

以上是两次 resize 的直接循环墙钟，没有 IO mutex 等待、控制消息延迟或 UI frame 数据。cold 恢复成本已测出；是否采取 lazy reflow 仍需单独设计 pin/selection/search/width generation 的一致性，并测实际 IO 锁竞争。本轮仅建立基线。

逐循环、命令、SHA 和内存结果：[reflow JSON](2026-10-04-core-audit-reflow.json)。复现：

```sh
python3 scripts/benchmark-reflow.py --generate --corpus=/tmp/reflow.vt
python3 scripts/benchmark-reflow.py --corpus=/tmp/reflow.vt \
  --binary=zig-out/bin/ghostty-bench --output=/tmp/reflow-results
```

基准构建使用 `python3 scripts/build.py core -Demit-bench -Doptimize=ReleaseFast` 和仓库 Zig PATH。普通沙箱的 `/usr/bin/time -l` 读取 `kern.clockrate` 被拒绝，smoke 的基准本体完成但 time 返回 1；正式测量在已授权执行权限下完成，取得 RSS。未将该环境失败记作基准通过。

## 验证记录与保留边界

- 跨页搜索与环形 prepend：159/159；保护擦除已独立验证提交。
- datastruct、insert/deleteLines、journal/pins、Kitty margins、旧搜索资源 probe、TerminalResize：ReleaseFast 198/198。
- scratch/真实 PTY/XDG/cache/settings/TerminalResize：Debug 192/193，唯一 skip 为默认未启用的 opt-in PTY 压力 probe；压力 probe 的 72 个前后进程另行全部完成。
- surface/config/focus/presentation/undo/notification：native 84 passed，0 failed，0 skipped。
- ReleaseFast 核心、benchmark 与 Markdown/HTML/man 生成：136/136 steps 成功；输出已包含 settings.json 与 256 色说明。
- 第一次联合 native 运行停在 XCTest IDE 会话握手、未进入 tests，经只读 sample 确认后结束；最小 headless 重试成功。投影首次 green 构建发现缺显式 GhosttyKit import，补齐后上述 84 项通过。
- 全量核心 Debug：**3,695 passed / 3,700 total，5 skipped，0 failed**，72/72 build steps 成功。五项默认 skip 是两个只在非 Debug 运行的既有 optimization probe、未启用的 exhaustive LZ4 differential、既有禁用的 OSC invalid-base64 案例及本轮 opt-in PTY 压力 probe；压力 probe 已独立实际运行。
- 全量 native 两轮均仅既有 AX document reuse 测试失败：选择循环中途内容 epoch 改变，而文档文字相同。`textRevision` 1→22 包含选择产生的 Tracker revision，并不代表 21 次文本变更。完整 SurfaceBridgeTests 隔离复核为 **17 passed，0 failed，0 skipped**。
- 查明可行竞争路径：Surface 初始化先排入 resize；IO 线程启动子进程及独立 reader，reader 可以先读到 `ready`，IO 线程稍后处理 resize；即使网格未变，resize 也递增内容 epoch。现有日志未逐字段记录 ContentView，因此不能断言这是唯一原因。测试夹具以 CSI `5n` / ESC `[0n` 往返建立 FIFO 屏障，保留全部文档身份、capture count 与 reset 断言；夹具改动后 isolated **17/17**，全量 native **498 passed，0 failed，1 skipped**（499 项/76 suites；唯一 skip 为既有未启用的 Benchmarks/example）。
- Zig format、11 个修改 Swift 文件的 strict lint、Swift 6/concurrency/warnings-as-errors 的九配置检查及 diff whitespace 检查通过。
- 桥接边界修正后再次全量 native：**498 passed，0 failed，1 skipped**；153 个 UI/feature 文件通过 typed bridge 检查。
- 最终 ReleaseLocal 构建成功；`check-scope.py --app` 检查 arm64、最低 macOS 27、独立 bundle/CLI 身份、移除的 target/build flags、配置字段类型、shell integration/terminfo/font/license/localization 资源和 strict deep signature 均通过。
- 本地产物 `macos/build/ReleaseLocal/cghostty.app`，版本/build 为 **0.5.4/44**，没有安装或进行该产物的桌面 UI 验收。Mach-O SHA-256：`174b16630ba0a4864e84d52cc98450a7a069ed4e5524bc9b387aba777bf3cb74`。签名验证通过不代表公证或发布。

不删除或收窄终端协议兼容性、Unicode/grapheme/宽字行为、Kitty 图像、可访问性、原生 Swift SplitTree、SSH state 缓存、配置恢复或拥有型消息退出清理。UI 自动化和系统动画验收维持此前认证限制，本轮没有重新尝试。

临时完整日志位于 `/tmp/cghostty-audit-*`，大型 corpus 和临时日志不承诺长期保留；上述三个 JSON、两个 runner 与旧 PTY fixture 随分支保存。
