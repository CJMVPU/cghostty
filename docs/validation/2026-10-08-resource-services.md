# 2026-10-08 资源所有权与共享释放服务

## 范围

从干净的本地 `main` / `8815d4add` 开始，按用户授权继续架构整理，每项验证后独立提交。版本保持 0.5.5 / build 45，使用固定 Zig 0.16.0 和 macOS arm64 构建入口，构建及测试串行执行。本轮没有推送、tag、发布包或安装替换。

原有普通粘贴接收政策和上一轮文件来源通道保持原语义。资源计量只覆盖选定的 CPU atlas/节点缓冲、缓存条目/容量、当前 renderer 帧槽 atlas 纹理和自有 Metal 队列数。它不代表全进程内存、完整 GPU 驱动占用或图像解码的总峰值。

## 独立提交

| 提交 | 结果 |
| --- | --- |
| `a035e5e8b` | PNG 解码缓冲直接接管，取消解码后的整图 RGBA 再分配与复制；保留单次分配上限及错误清理。 |
| `adb48ee8a` | atlas 字节数先拓宽到 usize，再做检验乘法；倍增也检验，无法表示的增长在改变状态前返回 OutOfMemory。 |
| `9fcdac9de` | 共享 grid 分配稳定生命周期 ID；内部 C/Swift 桥接返回可后台读取的资源快照，Metal allocatedSize 在创建时记录。 |
| `d7572c28a` | 普通窗口绘制借用窗口队列；renderer 的独立队列只在首次快照时创建并复用。 |
| `66e5c2fba` | font grid 变小时，空闲帧槽也替换过大的 atlas 纹理；先完整上传新纹理，成功后才释放旧纹理。 |
| `c6cb0438d` | 每个 app font set 共享一个惰性、有界 CF 释放服务；client 等自己的已接受批次完成，饱和/启动失败在本地释放。 |
| `0308481c4` | CoreText 字体属性缓存按 grid 生命周期 ID 失效，避免地址复用被误认成同一 grid。 |
| `7b24c83dc` | 新增明确启用的隐藏 surface 探针，测试专用参数经过隔离的 Xcode/test plan 传递，记录资源、Mach 线程和 PTY echo 样本。 |

## 已复现的负测

- PNG：decoder 返回后禁止继续分配；旧实现申请 RGBA 复制缓冲，返回 OutOfMemory。新实现保留 decoder 原指针，1 MiB fixture 无解码后分配，真实 Wuffs 的逐次 OOM 清理也通过。不能由此给出整个进程 RSS 的下降量。
- atlas 尺寸：32768 × 32768 BGRA 的旧 u32 乘法崩溃；拒绝大分配的 allocator 在新实现观察到正确的 4 GiB 请求。超过 usize 表示能力的尺寸在触达 allocator 前拒绝，旧数据、节点和 revision 保持。
- 私有队列：隐藏与普通窗口 pane 原本都持有一条队列，原生断言实际失败。改动后它们为 0；首次快照变为 1，第二次仍为 1，其余 pane 不受影响。
- 缩小 atlas：旧逻辑不尝试创建较小纹理，因而在注入替换失败时错误返回成功。新实现先替换该空闲槽，其他槽等各自空闲再替换，像素和版本正确，失败仍保留旧槽。
- 同址 grid：两份有效 grid 在固定地址交换生命周期后，旧缓存继续返回旧属性字典。改用稳定 ID 后重建属性，旧对象持有至合法释放。

## 共享 CF 释放的合同

旧实现每个 shaper 都有一条 CFReleaseThread，即便未绘制也立即启动。正常 stop 可在尚有消息时停止 loop；异常 drain 分支丢弃消息而不释放 refs/数组。

新服务由 SharedGridSet 持有，所有该 app 的 shaper 使用独立 client。首次提交才启动一个 utility worker，64 个消息槽以 MPSC mutex/condition 协调，CFRelease 和数组 free 在队列锁外执行。队列满或 thread spawn 失败时，producer 本地释放，不等待容量或 IPC 通知。

client 在接受消息前记录 pending；worker 释放 CF 对象和原 allocator 的 refs 数组后才完成该 client 的批次。shaper 先 flush 最后一个 frame 并等待自己的批次，再销毁可被引用的缓冲与 allocator context。其他 client 无待处理数据时可以立即关闭；app font set 最后销毁服务并 join。测试覆盖真实 CF 引用计数、stack-backed FailingAllocator 生命周期、满队列、本地 fallback 和启动失败。

IO/read/gather/render 调度没有合并；这次仅合并了释放服务。活跃 app 的服务可在客户端关闭后等待下一次工作，app 销毁时退出。隐藏、从未绘制的 app 不启动该 worker。

## 当前资源与线程测量

原始结构化结果见 [资源 JSON](2026-10-08-resource-services.json)。

| 条件 | 唯一 CPU grid | CPU atlas/节点字节 | 自有 atlas GPU 字节 | 自有私有队列 | 具名工作线程 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 两个窗口 pane 的采样点 | 1 | 1,312,256 | 5,374,464，12 个纹理 | 2 → 0 | 本表不统计 |
| 8 个隐藏 surface，共享 CF 前 | 1 | 1,312,256 | 0 | 0 | 40，含 8 个 cf_release |
| 8 个隐藏 surface，共享 CF 后 | 1 | 1,312,256 | 0 | 0 | 32，cf_release 为 0 |
| 16 个隐藏 surface，共享 CF 后 | 1 | 1,312,256 | 0 | 0 | 64，cf_release 为 0 |

CPU 字节按 grid ID 去重，是 atlas data.len 加 skyline 数组容量；不包含 CoreText/font-face 分配和 hashmap header/padding。GPU occupied bytes 来自 MTLResource.allocatedSize，仅统计 renderer 当前帧槽的 atlas，不含快照、缓存 target、scroll textures、图片或在途退休资源。两 pane 的槽在该时点没有全部达到同一上传进度，不是最大暖态或长期峰值。

线程数以 io/io-reader/io-gather/renderer/cf_release 五个名称求和。进程总线程数受框架 worker 波动影响，不能将 ready-before 的差当成产品线程数。8/16 个隐藏 surface 关闭后，这些具名线程均消失。8 个隐藏 surface 的具名线程下降 20%；不是整体 CPU 或内存下降 20%。

PTY echo 的 12 个样本中位数，8 surface 共享前约 6.111 ms、共享后约 6.175 ms；16 surface 约 6.189 ms。这包括 5 ms 的语义轮询，shell 明确 stty -echo 后由 cat 回显。仅是就绪/回归样本，不能声称输入加速、p95 或按键到显示延迟改善。

复现探针，普通测试默认不启用：

```sh
python3 scripts/build.py native --action test --resource-probe-surfaces 8 \
  --only-testing GhosttyTests/RendererResourceProbeTests
python3 scripts/build.py native --action test --resource-probe-surfaces 16 \
  --only-testing GhosttyTests/RendererResourceProbeTests
```

参数限 1...32，0 禁用；非 test action 或超范围在构建前拒绝。测试计划只传递这个明确的 setting，保留原 env -i 隔离。Mach 采样保留 thread rights，使用 THREAD_EXTENDED_INFO 读取名称，避免线程退出时读取悬空 pthread 指针；所有 port rights 和 VM 数组按生命周期释放。

## 验证

- 最终 ReleaseFast：150/150 通过，涵盖 shaping、CF service、grid/atlas、PNG、文件来源和 shader 退出。
- 目标 Debug：PNG/限制 84/84；atlas 上传与 grid 99/99；共享 service/shaping/set 112/112；生命周期字体缓存 116/116。套件有重叠，不相加。
- 桌面可交互时，共享 CF 服务后的原生目标：43/43 通过，含资源探针、SurfaceBridge、WindowCompositor、SurfaceLifecycle。最终缓存修复后的 16 surface 探针：1/1 通过。
- Swift 纯合同：8 个测试、3 个 suite 通过，未测试 AppKit/Metal 集成。
- Python：60/60 通过；实际 CLI 拒绝非 test action 与 33 surface。
- scope/typed bridge、Zig fmt、Swiftlint strict、版本、Swift 6 配置和本地化通过。
- 最终 Debug 核心全套：3772 passed / 3777 total，5 skipped，0 failed；72/72 构建步骤成功，源码修订 `7b24c83dc`。

完整原生套件在锁屏时未通过：xcresult 为 487 passed / 21 failed / 2 skipped / 510 total。对应 36 个 issue，不能把 issue 数当失败测试数。失败集中在 SurfaceBridge 5 项和 WindowCompositor 16 项显示用例；PTY 文本已就绪、surface 健康，但 native geometry 的 visible=false、clock paused=true、submitted=0。会话读取确认 screenLocked=1, onConsole=1。需要解锁且显示器活跃后复跑，当前不记录原生全套通过。

此前单个函数选择没有运行测试，以及外部环境变量被 env -i 清除而跳过探针，均被测试验证器拒绝。记录只包含实际执行的成功探针。锁屏完整结果与源码负测保留在 /private/tmp/cghostty-round6-*.log，临时日志/xcresult 依既有清理策略维护。

## 后续架构边界

- 延迟 reflow：现有 PageList 的 pin、节点/serial、scroll journal 与页宽有整体合同；搜索在尺寸变化前就重置 flattened results，避免读取重排后释放的节点。仅延后历史页转换会引入同一全局 cols 下的多种 page width/generation，现有尺寸检测不足以通知搜索/选区。应先设计消费者坐标/代际接口，再验证 resident/cold、OOM、历史搜索和宽字/grapheme，不能把跳过页转换作为实现。以前的 reflow JSON 是历史基线，本轮没有重新测量或更改该路径。
- 全局资源预算：选定资源快照不覆盖解码 scratch、图片储存/待上传/在途纹理、CoreText 缓存、command allocator、frame target 与 history。下一步可在各拥有者边界扩充计量并采样峰值，再定义逐出或拒收政策；既有 image-storage-limit 仍只是它原本的范围。
- 更多线程合并：本轮释放服务的每 client barrier 与饱和回退可复用为范例。读/解析/写入合并会改变 parser 锁竞争和控制消息响应，需要单独测阻塞子进程、大输出及 resize/stop 延迟；当前没有据此进行合并。
