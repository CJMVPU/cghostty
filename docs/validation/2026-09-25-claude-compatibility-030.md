# Claude 兼容开关与 0.3.0 验证（2026-09-25）

应用版本：0.3.0；构建号：20。基于此前同日完成的上游修复与优化，见 [先前验证记录](2026-09-25-upstream-compatibility.md)。

## 实现

- 新增 `claude-compatibility`，默认 `false`，配置模板提供中英文名称、默认值、`true` 示例与使用条件。
- 配置经 IOSession 传入 Exec，仅在开启时向子进程设置 `CGHOSTTY_CLAUDE_COMPATIBILITY=1`，关闭时清除继承的同名标志。
- shell 集成包装 `claude`，仅给 Claude 及其子进程使用 `TERM_PROGRAM=ghostty`、`TERM_PROGRAM_VERSION=1.2.0`；外层 shell 保留 cghostty 的身份。实现覆盖 zsh、Bash、fish、Nushell、Elvish，运行验证范围见下文。
- 旧配置模板通过 Settings 打开时，只追加缺少的配置项说明。原内容字节、顺序与启用的设置不变；写入前备份，原子替换，重复打开不追加。
- `build.zig.zon`、三个 Xcode 应用配置与发布说明同步至 0.3.0／20。

## 验证结果

- 核心定向测试 **282/282 通过，72/72 构建步骤成功**。过滤器：`config`、`termio.Exec`、`shell_integration`。覆盖模板示例解析、旧模板增补与备份、重复打开、开关默认值、环境隔离与分配失败清理。这组测试在递增版本前的 0.2.9 元数据下运行。
- shell 运行测试 **8 项通过、2 项跳过**：zsh、Bash、Nushell 验证开关及参数／空参数／退出码传递；zsh、Bash 验证已有函数优先。fish 因本机未安装而跳过；Elvish 未做运行验证。使用临时 Claude 替身，不发送真实请求。
- 0.3.0 ReleaseLocal 原生测试 **1 个参数化测试、2 个场景通过**：`SurfaceBridgeTests.claudeCompatibilityConfigReachesPTY(enabled:)`，从临时配置文件经原生 surface 启动实际 PTY，分别验证开关关闭／开启，并确认外层 `TERM_PROGRAM=cghostty`。
- 0.3.0 ReleaseLocal 应用构建成功，包含新建的 ReleaseFast 核心。版本一致性、macOS arm64 范围、资源及签名检查通过。
- 构建产物执行 `+show-config --default` 确认：`claude-compatibility = false`、`shell-integration = detect`、`progress-style = true`。
- Xcode 工程 plist、Swift 6 配置、修改的 Swift 测试文件 lint（无缓存模式）、修改的 Zig 文件格式和 `git diff --check` 通过。

首轮原生测试用不带参数签名的名称筛选，选中了 0 项；改用下面的完整签名后实际运行 2 个场景。0 项结果不计作验证通过。

## 复现命令

将仓库固定的 Zig 0.16.0 与 Nushell 加入 PATH，并设置可写的 Zig 缓存：

```sh
python3 scripts/build.py test -Dtest-filter=config -Dtest-filter=termio.Exec -Dtest-filter=shell_integration --summary all
python3 -m unittest discover -s scripts/tests -p test_claude_compatibility.py -v
nu macos/build.nu --configuration ReleaseLocal
nu macos/build.nu --configuration ReleaseLocal --action test --skip-core --only-testing 'GhosttyTests/SurfaceBridgeTests/claudeCompatibilityConfigReachesPTY(enabled:)'
python3 scripts/check-versions.py --app macos/build/ReleaseLocal/cghostty.app
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
```

日志：`/private/tmp/cghostty-030-core.log`、`/private/tmp/cghostty-030-native.log`、`/private/tmp/cghostty-030-pty.log`。

应用产物：`macos/build/ReleaseLocal/cghostty.app`。尚未替换已安装应用，也未制作发行包、提交、打标签或发布。未运行完整测试套件，未进行真实 Claude 任务的顶部蓝条验收；使用方式与限制见 [Claude Code 说明](../claude-code.md)。
