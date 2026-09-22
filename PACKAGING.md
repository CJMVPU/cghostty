# cghostty 打包与发布

仅生成 macOS Apple Silicon 应用和 ZIP。项目版本为 `build.zig.zon` 的 `.version`；发布标签使用 `v<语义版本>`，例如 `v0.1.9`。本地发布构建示例：

```sh
nu macos/build.nu --configuration ReleaseLocal --version 0.1.9
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
bash macos/package.sh
```

打包脚本验证应用版本／构建号与仓库记录一致、Bundle ID、主程序 arm64 架构和完整签名，然后输出 `artifacts/cghostty-0.1.9-macos-arm64.zip` 及 `.sha256`。`CFBundleShortVersionString` 保留 macOS 要求的三段数字，完整语义版本保存在 `CGhosttyVersion`，并用于“关于”、`+version` 和 ZIP 名称，例如 `cghostty-0.1.9-dev-macos-arm64.zip`。

默认包使用 ad-hoc 签名，适合本机构建验证。面向其他用户分发时，先在自己的钥匙串配置 Developer ID 证书与 notarytool profile，再使用：

```sh
export CGHOSTTY_SIGN_IDENTITY='Developer ID Application: YOUR NAME (YOUR TEAM ID)'
export CGHOSTTY_NOTARY_PROFILE='YOUR_KEYCHAIN_PROFILE'
bash macos/package.sh
```

脚本签署应用、校验签名、提交公证、等待结果、装订票据并重新打包。证书、Team ID 和公证凭据不写入源码。

`.github/workflows/macos.yml` 在 PR 和手动运行时执行测试与打包；推送 `v*` 标签时以标签版本构建，并在**当前仓库**创建草稿 Release。CI 默认没有 Developer ID / 公证凭据，草稿读取当前提交的 `RELEASE_NOTES.md`，并追加 ad-hoc 签名说明；发布前校验标签、源码版本和更新说明标题一致。核验后由仓库所有者发布草稿；工作流不会自动公开 Release。

应用内“检查更新”打开本仓库 Releases 页面。已删除上游 Sparkle feed、公钥、自动下载更新逻辑及 Sentry 崩溃上传。不会向 Ghostty 上游发布仓库推送产物。

应用最低系统版本为 macOS 27，包内所有可执行产物仅含 arm64。打包前使用 `scripts/check-scope.py --app` 检查系统版本、原生光标配置和已移除的 GLSL 入口。

提升版本时，先修改 `build.zig.zon` 的 `.version` 和 `RELEASE_NOTES.md`，再运行：

```sh
python3 scripts/check-versions.py --sync-app-version --build-number 10
python3 scripts/check-versions.py
```

`--build-number` 使用递增的应用构建号；省略时保留现有构建号。同步只更新 Debug、Release、ReleaseLocal 应用配置，测试目标保持独立。正式打包要求完整版本与仓库一致；试验性的 `--version` 覆盖可用于本地构建，但不能把与仓库版本不符的应用作为正式包输出。
