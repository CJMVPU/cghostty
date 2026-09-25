# 上游修复、缓存优化与 Claude 兼容（2026-09-25）

基线提交：`cfcfa1964`（0.2.9）。应用版本保持 0.2.9，未修改发布说明、创建提交或安装到 Applications。

## 改动与来源

- [tmux #14262](https://github.com/ghostty-org/ghostty/pull/14262)：`receivedListWindows` 先同步 viewer 持有的窗口，再返回该持有切片；窗口事件格式化只打印数量。包含原补丁的 action 回滚修正和切片生命周期回归测试。
- [8215dd9](https://github.com/ghostty-org/ghostty/commit/8215dd9ee3af89665532736824afc24889b94cab)：DEC Special Graphics 和 British 字符集批量写入；Unicode 与 single shift 保留逐字符处理。包含批量／逐字符结果一致、样式替换、single shift 和 REP 测试。
- [b5dbe15](https://github.com/ghostty-org/ghostty/commit/b5dbe15813c069bedee43afef04a9bec23353a6d)：glyph 缓存键直接存储为 packed u64，避免每次查询重新打包。
- [4c1099c](https://github.com/ghostty-org/ghostty/commit/4c1099ce9654f8d2cb20ac9792978d3979c1ce53)：CodepointKey 同样采用 packed u64 和直接整数比较；保留未指定 presentation 与显式 text 的区别。与前一个补丁的共享上下文手动合并，算法保持上游实现。
- README 和 [Claude Code 兼容说明](../claude-code.md)：记录 Claude Code 2.1.282 的终端名称／版本检测，以及仅为 Claude 及其子进程设置兼容环境的命令与可选 shell 函数。未改变应用默认身份、用户 dotfiles 或终端进度协议。

## 验证

- 核心定向测试：**213/213 通过，72/72 构建步骤成功**。过滤范围为 `tmux`、`printSlice`、`font.SharedGrid` 和 `accessibility`，包含 cghostty 自有终端内容变化检测。
- **ReleaseLocal 应用构建成功**，包含重新构建的 ReleaseFast 核心。沙箱内首次 Swift 构建被宏插件运行限制阻断，随后以同一构建目录、`--skip-core` 在沙箱外完成。
- 文档 shell 函数经过 zsh、Bash 两种 shell 验证，各覆盖 cghostty、Ghostty、未设置终端标识三种环境：共 **6/6** 场景通过。验证带空格参数、空参数、退出码传递，以及外层环境不被修改。使用临时替身程序，未运行真实 Claude 请求。
- macOS arm64 源码范围、原生配置桥接、版本一致性、变更 Zig 文件格式和 `git diff --check` 通过。
- ReleaseLocal 产物检查通过：应用身份、arm64 架构、资源和签名均符合项目范围。

核心日志：`/private/tmp/cghostty-upstream-core.log`；应用构建日志：`/private/tmp/cghostty-upstream-native.log`。

本轮未做完整核心／原生测试套件、真实 `tmux -CC` 桌面会话、真实 Claude 任务的蓝条验收或性能 A/B。上游性能数字不代表 cghostty 本机实测收益。构建产物位于 `macos/build/ReleaseLocal/cghostty.app`，用户已安装的应用未替换。

## 复现

先将仓库 `.tools/zig-aarch64-macos-0.16.0` 和 Nushell 加入 PATH：

```sh
python3 scripts/build.py test -Dtest-filter=tmux -Dtest-filter=printSlice -Dtest-filter=font.SharedGrid -Dtest-filter=accessibility --summary all
nu macos/build.nu --configuration ReleaseLocal
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
python3 scripts/check-versions.py
zig fmt --check src/font/SharedGrid.zig src/terminal/Terminal.zig src/terminal/tmux/viewer.zig
git diff --check
```
