# 渲染、搜索及原生调度六项优化验证（2026-09-24）

基线：`cc48fe91b`。以下构建、测试及性能测量在 0.2.6（build 16）元数据下完成，随后将版本元数据提升至 0.2.7（build 17）。环境：Apple M5 Pro、macOS 27.0（26A428）、Zig 0.16.0；原生测试使用 ReleaseLocal，性能对照使用 ReleaseFast。

## 完成的六项改动

1. **同步输出快照复用**：输入线程复用上一份 CPU 行数据和样式容器，渲染器交换完成的视口后归还旧容器。仍强制独立采集完整视口并保留实时终端的刷新标志，不借用终端页。CPU 图片缓存按图片代次复用像素；快照通过原子引用计数共享不可变 RGBA 数据。图片替换、缓存清理及 GPU 上传分别释放自己的所有权，GPU 资源不返回输入线程。每次采集后移除不在该视口中的缓存图片。
2. **Kitty 绘制缓冲区复用**：三个交换链帧分别持有图片实例缓冲区，容量不足时扩展；所有放置位置写入该帧的同一个缓冲区，绘制时使用不同字节偏移。保留原有位置排序和逐项绘制，避免改变透明混合顺序。只在交换链确认该帧不再被 GPU 使用后写入。
3. **搜索按变化刷新**：PTY 输出、视口操作、尺寸变化和可见性变化通知搜索会话；连续通知合并为一次刷新，保留原有 24 ms 的批处理间隔，但定时器只触发一次，不再周期性轮询。静态会话没有刷新定时器；不可见时保留待更新状态，重新可见后刷新。显式查询及导航继续立即处理。内容版本判断独立于渲染器脏标志。停止搜索时先解绑通知，再停止、等待并释放工作线程；没有搜索会话时，通知入口通过原子标记直接返回，不增加终端锁。
4. **主线程唤醒合并**：线程安全的待执行标记使突发唤醒只安排一次主线程任务。开始处理前释放标记，允许处理过程中到达的新消息安排下一次任务。核心在退出消息提前返回或动作失败后主动续约唤醒，避免合并后遗留队列消息。异步任务继续弱引用 App。
5. **UUID 弱索引**：WindowRegistry 在树成员更新时维护 UUID 到终端视图的弱映射，按 ID 查找不再扫描所有控制器和分屏树；所属控制器查询使用已维护的弱映射。关闭和跨窗口移动按对象身份清理，撤销恢复时重新登记。注册保持幂等，删除初始化阶段重复登记。
6. **Metal 缓冲区管理收敛**：连续写入与分段写入共用容量扩展和可写内存入口。扩容先成功分配新资源再替换旧资源；长度运算检查溢出，空缓冲区保留一个元素的最小容量。按本项目 Apple Silicon 专用范围使用 shared 存储，移除非统一内存选择及重复的 managed 同步分支。

复用会保留最近视口所需的容量和 CPU 图片副本，属于用有界常驻内存减少分配的取舍。待显示完整帧仍最多一份；CPU 图片缓存受最近采集视口限制，替换期间旧快照可继续持有旧代次，直至消费者释放。没有建立历史帧队列或全滚动历史缓存。

## 验证结果

- 最终扩大范围核心回归：189/189 通过，72/72 构建步骤成功；覆盖完整搜索模块、RenderState、同步输出和图片共享副本分配失败逐点注入。此前更窄的定向回归为 86/86 通过。
- 原生测试：44 个套件、340 项，339 通过、1 跳过、0 失败；结果包状态 Passed。跳过项为既有基准示例。
- 原生新增覆盖：1,000 个并发唤醒请求只获准安排一次待执行任务；处理开始后允许新的唤醒；App 弱引用销毁；UUID 在关闭、移动、撤销、重做中的一致性；真实 PTY 搜索增量输出及可见性恢复。
- 图片原生测试实际发送 Kitty 数据与两个放置位置，完成 Metal 渲染后读取缩略图像素，验证出现两个分开的红色色块，覆盖第二个位置的非零缓冲区偏移。
- 核心新增覆盖：视口行容量复用、同代图片使用相同像素地址、源页面重置后旧副本有效、图片替换和全部克隆分配失败点清理、隐藏变化保留、一次性刷新、没有渲染器脏标志时仍发现输出变化。
- 修改的 Swift 文件严格 lint（不使用缓存）零违规；Zig 格式、差异空白、平台范围、内部配置桥接、版本、本地化及 Swift 6 配置检查通过。
- ReleaseLocal 应用、内部桥接及 ReleaseFast 基准工具构建成功。

本地证据：

- 核心定向日志：`/private/tmp/cghostty-six3-core4.log`
- 扩大范围日志：`/private/tmp/cghostty-six3-core-final.log`
- 原生结果包：`/private/tmp/cghostty-six3-native3.xcresult`
- 原生日志：`/private/tmp/cghostty-six3-native3.log`
- 性能原始数据：`/private/tmp/cghostty-six3-hold-bench-final.json`

开发过程中修正了新增搜索测试遗漏 blocked/feed 推进、Swift 断言宏嵌套及基准工具引用私有辅助函数的问题。只以上述最终通过的结果为验证依据。

## 局部性能对照

使用同一工具的 `hold-fresh` 与 `hold-reuse` 模式隔离分配策略：前者每次释放快照及其缓存，后者保留容量和图片代次缓存。两者都完整采集视口；这是分配策略对照，不是整个旧应用与新应用的端到端对照。

120×40 终端，每轮 2,000 次采集。先生成固定输入，再独立运行基准；两轮预热、五轮测量，每轮交替模式顺序，所有测量串行执行。计时不包含输入解析和负载校验。图片负载显式验证一张可见 256×256 RGBA 图片，共 262,144 字节；文本负载图片数为零。两模式捕获次数及文本校验值一致。

| 负载 | 每次新建：中位数 | 复用：中位数 | 此负载采集耗时降低 |
| --- | ---: | ---: | ---: |
| 带样式的中英文及 emoji 文本 | 9.799666 ms | 2.871458 ms | 70.70% |
| 相同文本及一张可见图片 | 16.066250 ms | 2.965458 ms | 81.54% |

文本五轮（新建 / 复用，ms）：11.356750 / 3.231750，9.831375 / 2.995041，9.799666 / 2.871458，9.620709 / 2.796042，9.726542 / 2.837833。

图片五轮（新建 / 复用，ms）：16.066250 / 3.009084，15.993166 / 2.943083，15.971750 / 2.965458，16.169209 / 3.024583，16.250917 / 2.926917。

这些数字不代表整机 CPU/GPU 占用、功耗或完整 TUI 帧率变化。没有为 UUID 查找、Metal 绘制或搜索调度宣称未经测量的百分比收益，也没有进行长时间、多窗口的人工压力验收。

## 复现

将项目固定的 Zig 0.16.0 和 Nushell 放入 PATH 后：

```sh
python3 scripts/build.py test -Dtest-filter='render hold' \
  -Dtest-filter='GUI synchronized' -Dtest-filter='kitty renderer' \
  -Dtest-filter=search -Dtest-filter=SearchSession \
  -Dtest-filter=terminal.render -Dtest-filter='synchronized and live' --summary all
nu macos/build.nu --configuration ReleaseLocal --action test
python3 scripts/build.py core -Demit-bench -Doptimize=ReleaseFast
```

固定输入生成：

```python
from pathlib import Path
import base64

text = ''.join(
    f'\x1b[38;5;{20+i%200}m{i:04d} 中文🙂 snapshot reusable render state '
    + 'x' * 60 + '\r\n' for i in range(80)
).encode()
Path('/private/tmp/cghostty-six3-text.bin').write_bytes(text)
encoded = base64.b64encode(bytes([255, 0, 0, 255]) * 256 * 256)
chunks = [encoded[i:i+4096] for i in range(0, len(encoded), 4096)]
image = b'\x1b[H'
for i, chunk in enumerate(chunks):
    header = b'a=T,f=32,s=256,v=256,i=1,q=2,c=8,r=4,' if i == 0 else b''
    image += b'\x1b_G' + header + b'm=' + str(int(i != len(chunks)-1)).encode() + b';' + chunk + b'\x1b\\'
Path('/private/tmp/cghostty-six3-image.bin').write_bytes(text + image)
```

然后分别执行以下命令，两轮预热后至少测量五轮；对图片负载替换数据文件名：

```sh
zig-out/bin/ghostty-bench +screen-clone --mode=hold-fresh \
  --data=/private/tmp/cghostty-six3-text.bin --terminal-cols=120 --terminal-rows=40
zig-out/bin/ghostty-bench +screen-clone --mode=hold-reuse \
  --data=/private/tmp/cghostty-six3-text.bin --terminal-cols=120 --terminal-rows=40
```

本轮没有运行完整核心测试套件。后续升版仅同步版本元数据和发布说明，并检查版本一致性与项目文件格式；未单独构建 0.2.7 发行包，没有打标签、发布或替换已安装应用。
