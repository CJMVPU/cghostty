# 验证记录

最新改动见 [2026-09-23 核心精简与原生异步修复](docs/validation/2026-09-23-maintenance.md)，此前记录见 [续传跟踪移除](docs/validation/2026-09-23-stream-cleanup.md) 和 [核心收敛与内嵌字体](docs/validation/2026-09-23-core-cleanup.md)。

历史记录保留当时的实现和验证边界，不代表当前功能或资源布局：

- [截至 0.2.1 的验证历史](docs/validation/history-through-0.2.1.md)
- [第一轮优化与外置字体方案（已被内嵌方案替代）](docs/validation/optimization-validation-2026-09-23.md)
- [Inspector 移除与依赖清理](docs/validation/inspector-removal-2026-09-23.md)

历史 `/tmp` 路径仅用于标识当时的运行，构建副本、结果包和截图已清理，不承诺文件仍存在。后续临时产物遵循 [开发说明](HACKING.md#构建缓存与磁盘占用)，复用目录并在汇总后清理。
