# 2026-10-08 生命周期、输入背压与原生异步整理

## 范围与当前状态

本轮从干净的本地 `main` / `fb469fd2a`（0.5.5 / build 45）开始。用户授权深入检查模块与架构、实施修复，并要求每项独立完成后提交 Git。版本保持 0.5.5 / build 45；本记录对应本地源码、构建及测试，未推送、打 tag、打发布包或替换已安装应用。

所有构建及测试使用固定 Zig 0.16.0，通过 `scripts/build.py` 串行执行。原生构建先更新核心，后续 `--skip-core` 调用核对核心来源。没有运行独立的 GhosttyUITests UI 自动化套件；原生单元/集成测试包含真实窗口、Metal、PTY 和子进程。

## 独立本地提交

| 提交 | 行为及边界 |
| --- | --- |
| `1379d0599` | Renderer.threadExit 在释放资源前清除 display_realized，正常关闭也释放 shader library/pipelines。生产修复为一行。 |
| `c5edf8717` | reader/writer 使用独立 sticky fault 信号，首个错误只消费一次，失败通知不等待满的 app mailbox；正常 EOF 不报错。 |
| `c66ea45eb` | 搜索 worker 的所有退出路径通知 owner；清空陈旧结果、停止并回收 session，后续查询可创建新 session。 |
| `5b3760adf` | 终端 resize 先更新 PTY，核心失败时回滚 PTY；缓存尺寸只在成功后提交。OOM 最多重试两次，其他故障立即上报。 |
| `b3b90356d` | reflow 使用最多 8 项的 hyperlink 映射缓存，目标页/容量变化时重置；缓存命中仍增加正确引用计数。 |
| `5dbfcfe6b` | 原生设置恢复复用已做过的 light/dark 解析，CLI 与原生共用纯恢复选择函数。 |
| `2b82e5b39` | IO mailbox 每批最多 32 条消息或 256 KiB 写负载，允许一个完整的大输入跨过字节阈值；有后续消息时主动重新通知。 |
| `dc0f1c4cc` | 普通窗口绘制遇到占满的帧槽立即让出；已提交的部分 GPU 工作按真实完成事件回收。显式快照仍允许等待。 |
| `fb79d3bdd` | 缩略图的 GPU 等待与 PNG 编码移出主 actor；相同请求合并，旧 revision 或已取消的结果不写入缓存。 |
| `cf09436e7` | shader 退出回归覆盖正常 display_realized=true、全部 pipeline owner 与重复退出，检查引用数恢复且不双重释放。 |
| `0122b40e5` | split 生命周期更新先建一次成员集合，焦点检查及退出成员取消复用集合，消除重复线性扫描。 |
| `8d75aeda3` | CI 覆盖 main/codex 分支 push，并增加 ReleaseFast 关键合同测试。 |
| `7da593709` | 配置文件输入使用一个 64 KiB 数据块，写完后再读取；后续普通输入保持完整接收、所有权和 FIFO。优化 CI 同时加入来源通道回归。 |
| `cef27d66a` | 原生 Surface 到真实子进程的 240 KiB 文件输入回归，逐字节核对前后配置字符串与后续键盘输入。 |
| `20e600f39` | 故障注入使用合法只写描述符触发读取失败，退出时仍由同一拥有者关闭，修正 Debug 夹具清理。 |

## 所有权及错误合同

### 渲染与快照

用户指出的 shader 泄漏路径在当前代码中成立：正常退出时 display_realized 仍为 true，而 shader 释放受 !display_realized 条件保护。threadExit 现在在 draw_mutex 内先清除标志。回归使用保留的 Objective-C 对象作为 library 与每种 pipeline 的 owner，调用实际生产 deinit 方法；测试确认只剩独立控制引用并可重复退出。这验证所有权释放合同，不代表对真实 Metal 管线进行了长期内存增长测量。

帧槽不足不会改变帧索引，也不会在 GPU 尚未完成时释放资源。WindowCompositor 对部分提交使用 Metal shared-event listener 异步退休；后台退出仍等待在途 GPU 工作，未使用超时后直接释放的策略。缩略图请求将主 actor 上的身份/版本检查与后台 GPU 等待、ImageIO 编码分开；正常窗口绘制可继续让出帧槽。

### IO、搜索与 resize

首个 IO 故障通过原子信号保存，主线程既在 tick 中消费，也在自动关闭子进程前消费。故障关闭输入 mailbox，避免失败的 worker 留下阻塞发送者；输出解析在获得终端锁前后都检查故障。gather 的失败状态在 done 发布前写入，reader 可以处理此前的批次后再报告异常。

resize 的真实 PTY 测试注入 terminal tabstop OOM：PTY 返回旧尺寸，渲染器没有收到错误的新尺寸；重试随后成功。ioctl 本身失败也保留旧缓存。若一次终端分配失败已经造成 grid 与 Terminal 尺寸不一致，会显式报告 ResizeStateInconsistent。

搜索退出通知包括启动失败；旧 session 不再接收查询与导航，owner 回收它后下一次搜索可正常创建 worker。

### 配置文件来源与普通粘贴

用户明确选择：只有稳定文件/流式来源进入有界通道，普通粘贴保留现有接收语义。因此本轮没有对普通粘贴增加大小拒收、截断或磁盘暂存。

配置来源在启动子进程前打开并验证。常规文件超过既有 10 MiB 上限会预先失败；已打开的文件描述符由输入状态持有。文件数据最多保留一个 64 KiB 可复用块及其写请求，libxev 完成全部部分写入后才继续读取。已有数据先尝试有界读取，没有可读字节时才登记 xev 就绪事件；普通文件 EOF 不依赖 kqueue 再次发出读取事件。

普通键盘/粘贴输入在来源完成前保留原 owned/inline 缓冲，之后分批转交 libxev；配置来源、CRLF 转换、普通输入的先后顺序保持一致。raw 配置字符串借用由输入 arena 持有的稳定字节，生命周期跨过完整写回调。

流式来源或读取中增长的文件无法在开始前确定总长度。超过 10 MiB 时停止并向原生报告 InputFailed；此前已经写入的字节不能回滚，不会静默截断成成功。测试覆盖这一边界。配置中命名管道的打开行为仍遵循文件打开语义；对已打开但暂时没有数据的来源，读等待不会阻止事件循环处理 stop。

**64 KiB 是文件数据块的上限，不是进程内存或全部 PTY 待写字节的上限。** 来源元数据、raw 配置字符串、请求池以及已接受的普通粘贴另有内存。多个普通大粘贴仍可积累 owned payload，这是用户保留当前行为的结果。

## 可验证的工作量变化

- 相同 hyperlink 的 8 个 reflow cell：metadata dupe 尝试由 8 次降到 1 次，引用计数与清除测试仍通过。没有声称整段 reflow 延迟降低 8 倍。
- 正常原生设置启动：light/dark 解析由 5 次降到 2 次。回退 previous 时为 4 次；两份均无效后再解析 defaults，共 5 次。测试用实际 load counter 核对。
- split 成员扫描由对每个旧成员重复查找，改为一次建集合后查询；未给出端到端窗口性能百分比。
- 文件背压测试使用真实 raw PTY：暂停消费者后，file_bytes 保持 64 KiB、PTY 队列只有一个来源请求；resize ioctl 与独立 stop 事件仍可处理。
- 流式 EOF、1 MiB 文件与普通粘贴 FIFO、CRLF、32 条分批冲刷、读取/请求分配失败及 teardown 的 allocator 检查均通过。
- 原生集成测试让子进程实际捕获 240 KiB 文件，比较 `prefix + file + suffix + key` 的完整 Data；不是仅观察终端回显。

## 聚合验证

最终源码验证修订为 `20e600f39`。Debug 核心全套 **3765 passed / 3770 total，5 skipped，0 failed**，构建图 72/72 步成功。最终完整日志为 `/private/tmp/cghostty-oct08-final-core-after-fixture.log`。

| 检查 | 实际结果 |
| --- | --- |
| 前一轮全套 Debug 核心（最终 shader/source 回归加入前） | 3755 passed / 3760 total，5 skipped，0 failed |
| 最终文件通道 Debug 目标测试 | 93 passed / 94 total，1 skipped，0 failed |
| 最终 ReleaseFast 目标合同，含文件、流、普通 PTY、shader 所有权与增长/分配故障 | 99 passed / 100 total，1 skipped，0 failed |
| 原生全套（文件来源通道与最后的端到端案例加入前） | 506 passed，1 skipped，0 failed |
| 最终文件通道提交上的 SurfaceBridge / SurfaceLifecycle / SettingsRecovery / SettingsSource / SettingsEvaluation | 32 passed，0 skipped，0 failed |
| 原生输入端到端案例加入后的 SurfaceBridge | 18 passed，0 skipped，0 failed |
| Python scripts unittest | 59 passed |
| Swiftlint strict / Zig fmt --check | 通过 |
| scope / typed C bridge | 通过，153 个原生 UI/feature 文件 |
| 版本、Swift 6 配置、本地化 | 通过，0.5.5 / build 45，9 个 Swift 配置，168 条命令/504 个翻译 |
| workflow YAML 和 Bash run blocks | YAML 可解析，12 个脚本通过 bash -n；本机未安装 actionlint，未执行远端 CI |

第一次最终核心全套有 3764 项通过、5 项跳过，并因新增故障注入夹具重复关闭无效描述符而中止。`20e600f39` 用合法只写描述符替代这项注入，Debug 目标回归随后通过。该修正只改测试夹具，生产通道的描述符所有权未变；全套重新运行的结果记在上表。

原生全套跳过的是既有 Benchmarks.example；目标 PTY 测试中的一次跳过是未开启环境变量的 opt-in 压力探针。不同目标套件有重叠，以上数目不能相加当作独立测试总数。脚本 unittest 会输出测试用的失败摘要样例，最终 unittest 的 59 项为实际通过结果。

关键日志位于 `/private/tmp/cghostty-oct08-*.log`，本地原生 xcresult 由 ManagedTestResults 策略维护；这些路径仅标识本次运行，不承诺长期保留。没有将本地验证描述为发布或安装验收。

## 较大的后续架构机会

本轮已经收敛了跨线程错误传递、来源所有权与部分 GPU 完成后的退休边界。其余改变需要各自的测量和合同，不应把它们算成本轮已完成的收益。

1. **共享资源计量。** SharedGrid 的 codepoint/glyph cache、CPU atlas、GPU texture、解码中图像与已储存 Kitty 图像是不同拥有者。下一步应先建立明确的分类计量和多分屏峰值探针，再决定逐出政策；已有 image-storage-limit 的事务性计量不能代表全进程 GPU/解码峰值预算。
2. **延迟 reflow。** 当前 resize 仍处理已有历史，hyperlink 缓存只减少其中的 metadata 工作。延迟历史页转换还会涉及搜索、tracked pins、选区、scroll journal、压缩页与 Kitty 锚点。此前 resident/cold 探针可复用，必须先规定这些消费者看到旧/新坐标的规则。
3. **线程与调度合并。** 每个 surface 仍拥有独立 IO/render session，搜索额外创建 worker；窗口已有单独的 Metal compositor。合并线程应以大量隐藏标签页的线程数、唤醒次数和输入延迟为依据，并保留 stop/join、事件队列及 GPU 完成的所有权合同。仅减少线程数量不能作为正确性或流畅度的证据。
4. **普通输入硬预算。** 普通粘贴已被用户明确保留当前行为，不能宣称当前有全局硬上限。若以后改变接收策略，需要独立定义 producer backpressure、取消及有序重试语义。
