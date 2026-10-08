# 2026-10-08 App 与 renderer 消息调度

本轮从 `1f6ae3860`（0.5.7 / build 47）继续项目整体检查，落实上一轮架构记录中的事件循环预算项。实现提交为 `063e3f4d9` 和 `25a767647`。没有推送、创建标签或修改产品版本。

## 实现与边界

| 提交 | 原行为 | 本轮结果 |
| --- | --- | --- |
| `063e3f4d9` | renderer 持有 `update_mutex`，持续取控制消息直到队列为空；生产者可以在处理期间补充消息。消费失败后也可能留下已失去唤醒通知的消息。 | 每轮处理入口待办快照中的最多 32 条消息，剩余消息由消费者重新通知 Mach async。配置交接和消息所有权保持原处理合同；窗口更新锁与事件循环能在批次之间交还。 |
| `25a767647` | App 主线程同样持续取消息直到队列为空，同步原生回调可以继续补充消息。退出与错误路径的重新唤醒分别位于消息分支和 `tick`。 | 每个 native tick 处理入口待办快照中的最多 32 条消息；回调补充的消息留待下一 tick。统一在 drain 的退出路径检查待办并重新唤醒，保留 FIFO 与 quit 顺序屏障，空队列不新增唤醒。 |

renderer 的批次循环与单条消息处理分离，回归直接使用生产批次函数、实际 BlockingQueue 和 Mach async，不需要创建 GPU。App 回归使用生产 drain 循环和受控原生 action 消费者，覆盖同步发布与错误返回。

这些是消息数量与调度责任的合同，不是毫秒级耗时保证。单条配置更新、字体处理、原生 action 或搜索导航仍可能耗时；本轮没有测量真实 stop 延迟、CPU/GPU 功耗或性能提升比例。IO 的 32 条/256 KiB 预算和搜索的 32 条预算保持，普通粘贴接收方式保持。

## 旧实现负测

负测临时恢复旧取空循环，结束后自动恢复修复源码；没有改动断言。

- renderer：64 条消息一轮全部处理，断言期望 32、实际 64；初始仅 1 条但处理期间补充消息时，期望 1、实际 65；消费错误后缺少 continuation，剩余消息期望 0、实际 1。三个回归均捕获旧行为。
- App：64 条消息期望单 tick 处理 32、实际 64；原生 action 同步补充消息时，期望 1、实际 65。两个预算回归均捕获旧行为。quit 屏障及 action 失败后的 continuation 属于保留合同，也有正测覆盖。

## 验证

- renderer 与相关 IO/搜索核心回归：224/224，72/72 构建步骤成功。
- App、renderer、IO、搜索、稳定身份广播及配置交接合同：Debug 89/89；实际 `-Doptimize=ReleaseFast -Dtest-optimize=ReleaseFast` 89/89，均为 72/72 构建步骤成功。
- 最终解锁桌面后的完整原生单元测试：512 passed / 514 total，2 skipped，0 failed，80 个 suite。managed 验证器核对实际执行数量，复用核心归档的源码、版本和编译模式来源检查通过。
- 全仓 Zig fmt、286 个 Swift 文件的 SwiftLint strict、scope、153 个原生 UI/功能文件的 typed bridge 检查、版本一致性和 diff 检查通过。
- 独立 `GhosttyUITests` 未运行；没有本地发布打包或安装替换。

## 失败证据与环境限制

首次完整原生运行：511 passed / 514 total，1 failed，2 skipped。`selectionUpdatesReuseAccessibilityDocumentAndLineIndex()` 在相同文本下观察到 `textRevision` 从 1 变为 6、Cocoa 文本对象重建、capture 从 1 变为 2，共 109 条 issue，归为一个失败测试。完整测试失败发生在锁屏之前，不能归因于锁屏。

该项单独选择完整 Swift 测试标识后实际执行 1/1 通过；最终完整复跑也通过，源码与断言没有改变。根因未确认，不能宣称文档复用的间歇问题已修复。

第二次完整运行处于锁屏期间，IORegistry 明确记录 `CGSSessionScreenIsLocked=Yes`、锁屏时间为 2026-10-08 22:20:46 +08:00。结果为 504 passed / 514 total，8 failed，2 skipped；帧等待超时的诊断包含终端已有输出、窗口可见、healthy=true，但完成帧 revision=0。用户解锁后再运行，最终完整原生通过。两次失败均保留，不计入通过结果。

汇总数据见 [配套 JSON](2026-10-08-mailbox-scheduling.json)。临时日志为 `/private/tmp/cghostty-round9-*.log`，原生 summary 为同前缀 JSON；managed xcresult 沿用现有清理策略，不承诺长期保留。

## 下一步检查

设置后台解析仍是优先候选：当前 `ConfigHandle` 明确由 MainActor 创建、读取和释放，不能直接把现有 handle 放进 detached task。应先测 evaluate/prepareSave 主线程占用，再让后台解析拥有独立分配，只将不可变值与诊断发布到 UI，并用 draft revision 防止过时结果覆盖编辑。

同时继续检查单条控制消息的耗时及终端内容 epoch 的精度：`Terminal.resize` 当前在参数检查和同网格尺寸早退之前递增 accessibility revision，可能让仅像素尺寸变化重建文档。这个代码事实尚未证明是首次原生失败的原因；调整前需覆盖真正 reflow、失败后的部分状态变化及快照索引有效性。
