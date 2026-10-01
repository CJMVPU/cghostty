# 设置迁移后的 CI 回归修复

日期：2026-10-01。版本：0.4.5 / build 35。

## CI 报告的失败

本地复现了两项测试的三条断言失败：

- `FixedWindowSizeTests.editedConfigurationOnlyChangesSizeInNewApp`：重启后的宽、高仍为旧值。
- `WindowRegistryTests.opacityToggleStaysLocalAndUserConfigWaitsForRestart`：重启后的不透明度仍为 0.5。

原因是测试仍然修改迁移前的文本文件。应用首次迁移后只读取内部设置，修改旧文件不会改变下一次启动的配置。

`TemporaryConfig.saveAppSettings` 通过实际 `SettingsStore` 保存字段，三个重启配置测试共用这个入口。底层配置解析测试继续使用 `reload`，保留其原有含义。测试结束时清理独立的内部设置目录。

窗口尺寸、运行中实例隔离、不透明度切换和重启生效断言均保留，修复后通过。

## 完整检查发现的关联问题

### 路径比较导致背景图迁移失败

`Path.equal` 使用 `std.meta.eql`，对字符串切片比较地址。迁移前后独立分配的相同背景图路径被判为不同，迁移一致性检查拒绝保存，应用回退默认设置。

改为比较路径内容，并保留 required / optional 的区别。新增核心回归覆盖独立复制、不同内容及不同可选性；原生回归覆盖显式颜色和相对背景图路径迁移。原有背景图片替换失败、保留旧图和修复同一路径后重试的 GPU 测试通过。

### 选区图像测试的颜色转换与进程状态

实际 PNG 已显示红色选区，但 `NSBitmapImageRep.colorAt` 返回校准 RGB，转换到 sRGB 后，纯红像素的绿色分量在本机变为约 0.149，超过原判定阈值 0.1。

测试改用 `getPixel` 检查 PNG 中存储的 8 位 RGB 分量，阈值仍对应红色大于 0.6、绿色和蓝色小于 0.1。终端进程输出后保持运行，关闭光标动画，并等待目标选区实际出现在图像中，避免进程退出提示或无关帧干扰。修复后的实际 GPU 选区检查通过。

## 验证结果与边界

- 核心路径比较定向测试：71/71 通过，包含构建入口附带的测试。
- 原生设置迁移用例、CI 报告的两项测试、背景图重试和选区图像检查：通过。
- SwiftLint strict、Zig 格式和 Git 差异检查：通过。
- 最终完整原生套件：397 项测试、52 个套件全部通过，执行约 35.3 秒；动画合成的 6 种参数组合全部通过。
- 中途一轮曾有 7 条 GPU 动画等待超时，分布在动画合成、首帧暂停恢复和混合模式切换测试。现场记录 `visible=false`；首帧阶段还记录 `paused=true`、`paneDraws=0`。用户确认桌面已解锁且测试窗口可见后，再次完整运行通过。未延长超时，也未改变窗口可见性驱动合成器暂停的产品行为。
- 用户 CI 摘录中的合成器资源初始化日志不足以说明具体 Metal 资源为何失败；本地已经独立复现并修复上述三条配置断言，未以这些日志替代断言根因。

本地诊断日志：`/tmp/cghostty-native-settings-before.log`、`/tmp/cghostty-native-settings-after.log`、`/tmp/cghostty-native-settings-final.log`、`/tmp/cghostty-path-equality.log`；最终完整通过记录为 `/tmp/cghostty-native-settings-visible.log`。这些日志仅作本次本地证据，不属于发布产物。
