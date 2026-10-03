# cghostty 0.5.2

修复恢复显示交接、线程退出、关闭撤销、权限与设置/搜索状态。构建号为 42。
支持 macOS 27+，仅提供 Apple Silicon（arm64）版本。

## 恢复显示与透明标题栏

- compositor 在窗口遮挡时保留最后完整帧；pane 与窗口尺寸更新不同步或收到旧尺寸 drawable 时，等待完整 composition 后再呈现，避免透明帧和缺失 pane。
- 隐藏标题栏的窗口在外观刷新全过程保持透明，避免先写入整窗不透明背景再清空。保留用户窗口阴影和 blur 配置。
- 以上候选机制已用真实 AppKit/Metal 负回归验证并修复；用户尚未在新构建上验证 Stage Manager 恢复动画，两项原始动画症状是否消失仍待实测。

## 退出、权限与关闭撤销

- 关闭队列并取消等待中的 surface 生产者后再 join 工作线程，避免 app/IO 满队列与 DSR 解析造成退出循环等待；清理拒收和遗留的拥有型消息。
- Shortcuts 外部终端枚举先检查请求权限，拒绝时不读取标题、cwd、PID、TTY 或 PNG；内部 ID 查找保持独立。
- 忽略重复关闭确认，整窗审查保留原始目标身份；批量与整窗 redo 关闭原先恢复的身份，保留后来加入或移动的标签。
- 新建窗口/标签的 undo 在确认后才消费历史，取消时保留整个分组与 redo 状态；detach redo 保留确认策略和位置。
- undo 保留自定义标题、背景不透明覆盖和可恢复状态，并修复显式 undo 分组缺失引起的 AppKit 崩溃。
- quit 审查阶段保留所有窗口和可复用 Quick Terminal；后续取消不会破坏内容或 registry。AppleScript close 保留 Quick Terminal 生命周期。

## 设置与搜索

- 长环境变量无损格式化，格式化错误阻止保存，避免继承变量被空列表覆盖。
- discard 异步重读最新设置 revision 和可见字段；继承依赖改变后保留用户显式选择。
- 保存前验证 light/dark 两个主题分支；迁移保存实际读取的来源内容和顺序，不依赖最终 config-file 列表。
- 搜索关闭请求与回调应用分离，延迟回调绑定原搜索身份；跨 page 导航后刷新 viewport matches。
- 在输出批次解析结束后发布 revision 与变更通知，避免 DSR 中途解锁时消费唯一通知而遗漏尾部更新。

## 验证记录

功能回归在升版前的 0.5.1 / build 41 元数据下完成：19 个原生 suite 共 112 个测试、8 个真实 UI 测试均通过，0 失败、0 跳过；目标 Mac Zig 回归、8 个纯原生契约、严格 SwiftLint、scope 和 Swift 6 检查通过。
完整证据与系统动画验证边界见 [Mac 恢复显示与审查回归](docs/validation/2026-10-03-native-recovery-review.md)。

0.5.2 / build 42 使用仓库版本同步与发布检查、本地 ReleaseLocal 构建和打包验证；标签触发的 CI 执行完整核心/原生测试与发布包检查，成功后创建草稿 Release，供仓库所有者核验。
