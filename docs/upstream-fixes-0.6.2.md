# 0.6.2 上游修复移植记录

核对日期：2026-11-10。范围为上次上游检查列出的近期修复及相关依赖；基线为 cghostty 0.6.1 (`486883a82`)。保持 macOS 27+ arm64、Zig 0.16、原生窗口与 Metal 4 架构。

## 逐项处理

| 上游提交 | 内容 | 处理 |
| --- | --- | --- |
| [59044f5c5e](https://github.com/ghostty-org/ghostty/commit/59044f5c5ee5764b69cc8153d307507cb1f400f5) | terminal: retry dirty rows after failed render updates (#15127) | 移植并按本地结构适配 |
| [0aa22921ca](https://github.com/ghostty-org/ghostty/commit/0aa22921cad37022529a56e064df24a009f01500) | terminal: fix dangling pins on column growth resize, faster C enum validation (#15134) | 移植并按本地结构适配 |
| [e0e57281d7](https://github.com/ghostty-org/ghostty/commit/e0e57281d737f3ffc5252503d73dff0125c51841) | terminal: fix scrollback not pulled down when growing rows and shrinking cols (#15141) | 移植并按本地结构适配 |
| [77f85cd67c](https://github.com/ghostty-org/ghostty/commit/77f85cd67c4c434acc714bb1d1248107a3782a68) | terminal: print uses the right margin after wrapping (#15030) | 移植并按本地结构适配 |
| [ebd449995d](https://github.com/ghostty-org/ghostty/commit/ebd449995d321e90d6c73be3decb15558512b2ed) | shell-integration: don't let directory names inject escape sequences (#14859) | 移植并按本地结构适配 |
| [46e9dc9a92](https://github.com/ghostty-org/ghostty/commit/46e9dc9a927b2e7e7cba79e6902c176127dbdf2c) | config: prevent panic on truncated UTF-8 (#14879) | 移植并按本地结构适配 |
| [b840b2457c](https://github.com/ghostty-org/ghostty/commit/b840b2457cc0f5ee63cb324b3af9bb8e753e512c) | cli: fix Unicode escape validation (#14876) | 移植并按本地结构适配 |
| [53e55147bb](https://github.com/ghostty-org/ghostty/commit/53e55147bbbb0157672dac0228aa7744e881f1fa) | terminal: keep triple-click selection over blank lines (#15113) | 移植并按本地结构适配 |
| [76329e5ad9](https://github.com/ghostty-org/ghostty/commit/76329e5ad9731a74587bc6536ea308d33ad09149) | terminal: clear cursor pin garbage flag after resize (#15085) | 移植并按本地结构适配 |
| [9781c0afc8](https://github.com/ghostty-org/ghostty/commit/9781c0afc8225510e33127466f0815eb51086d7d) | formatter: restore a pending wrap at the right margin (#14918) | 移植并按本地结构适配 |
| [1c2ea72225](https://github.com/ghostty-org/ghostty/commit/1c2ea72225e4c4f64dee4411f52035ecf23f336b) | terminal: keep cursor style and hyperlink valid after scrollClear prunes (#14857) | 移植并按本地结构适配 |
| [9438bd3e54](https://github.com/ghostty-org/ghostty/commit/9438bd3e54931b1aceefc6037dc0674f4b844bf6) | terminal: mark pins on erased history rows as garbage (#14838) | 移植并按本地结构适配 |
| [bcfe577545](https://github.com/ghostty-org/ghostty/commit/bcfe5775454aebe2103e4dde906177b54fe61a94) | terminal/kitty: remove placements in erased history (#14832) | 移植并按本地结构适配 |
| [c412a31994](https://github.com/ghostty-org/ghostty/commit/c412a31994e55e05c58c5c540dd2adf4b71f7f96) | terminal/kitty: only target virtual placements from placeholders (#15086) | 移植并按本地结构适配 |
| [97f422fa24](https://github.com/ghostty-org/ghostty/commit/97f422fa2464c4770d1d4919d39cfb33da571b79) | terminal/kitty: find the newest numbered image by transmission (#15094) | 移植并按本地结构适配 |
| [1fa19fa3e9](https://github.com/ghostty-org/ghostty/commit/1fa19fa3e9f73e49bd231de4995a1ecfecda7afd) | terminal/kitty: evict the oldest image by transmission (#15103) | 移植并按本地结构适配 |
| [a7e8e4d15b](https://github.com/ghostty-org/ghostty/commit/a7e8e4d15bd0f12ad2a1123bf157b338e526c23e) | datastruct: prevent overflow in circular buffer arithmetic (#14987) | 移植并按本地结构适配 |
| [f040f0ab0e](https://github.com/ghostty-org/ghostty/commit/f040f0ab0ee30d77794b98d87e27fc9105ee6ab9) | datastruct: fix clearing circular buffers with zero capacity (#14958) | 移植并按本地结构适配 |
| [e2593c1496](https://github.com/ghostty-org/ghostty/commit/e2593c1496cbf9f34f13e53d2d83b80283c8f24f) | config: ignore repeated space in direct commands (#14950) | 移植并按本地结构适配 |
| [cf0ab14aed](https://github.com/ghostty-org/ghostty/commit/cf0ab14aed55315a53de668bc1bbcf4a13ce0ddd) | config: reject empty prefixed commands (#14921) | 移植并按本地结构适配 |
| [0b8b9984ee](https://github.com/ghostty-org/ghostty/commit/0b8b9984ee560456194262d190aa850224edb1f4) | config: fix formatting of long environment values (#14908) | 本地已经直接向 writer 输出长值，且已有超过 256 字节的回归。 |
| [fef7af4e19](https://github.com/ghostty-org/ghostty/commit/fef7af4e19f6d8b0361c49e6190b81f3a64a999b) | os: reserve space for executable path terminator (#15058) | 移植并按本地结构适配 |
| [042b16b614](https://github.com/ghostty-org/ghostty/commit/042b16b6146ada29877dfeeea9f286889e4adeb1) | termio: don't require RFC 1123 hostnames in OSC 7 (#14971) | 移植并按本地结构适配 |
| [87b65966df](https://github.com/ghostty-org/ghostty/commit/87b65966dfadc42dacd8d55b99ebc430e6a52455) | termio: send the config change color scheme report directly (#14834) | 移植并按本地结构适配 |
| [c7f68a7f48](https://github.com/ghostty-org/ghostty/commit/c7f68a7f48c6a5b357689eb8c2328bc2dab5d8ed) | macOS: fix tab bar frame on macOS 27 when it first appears. (#15029) | 本地 NativeTitlebarTabLayout 先更新约束，再选择性读取新建按钮尺寸，无提前退出。 |
| [0d1d5e884b](https://github.com/ghostty-org/ghostty/commit/0d1d5e884b88a711f1ccf47387ab41e8fa28a755) | macos: allow quitting with a clipboard confirmation open (#15040) | 移植并按本地结构适配 |
| [0fe113a353](https://github.com/ghostty-org/ghostty/commit/0fe113a35370667d8c4d6970ee5c1704825dce6b) | macos: fix flash of neighbor tab when moving titlebar tabs (#14847) | 本地直接 insertWindow 重排现有 tabGroup，不先 removeWindow。 |
| [18f09635d9](https://github.com/ghostty-org/ghostty/commit/18f09635d9e2e27df1d332f49a82d27cdcc03a48) | macos: clear split zoom indicator when tree is not split (#14703) | 移植并按本地结构适配 |
| [2c76f29972](https://github.com/ghostty-org/ghostty/commit/2c76f29972dad21d3f2cc0efde2517a6fa8fed56) | cli: explicitly install terminfo to ~/.terminfo on ssh remote host (#15061) | 移植并按本地结构适配 |
| [8265e74cd3](https://github.com/ghostty-org/ghostty/commit/8265e74cd3945c56d59aba3917ff01af33ba3e78) | cli: run the ssh terminfo install under sh (#15112) | 移植并按本地结构适配 |
| [44893148d0](https://github.com/ghostty-org/ghostty/commit/44893148d009bd372f5f7e8d2edbd0340fc82b65) | cli: show SSH authentication messages during terminfo setup (#14916) | 移植并按本地结构适配 |
| [37b71016bf](https://github.com/ghostty-org/ghostty/commit/37b71016bffab818bcda8be60efe808882c7b947) | set TERM for +ssh without clobbering the user's SetEnv (#14854) | 移植并按本地结构适配 |
| [0f10e6698e](https://github.com/ghostty-org/ghostty/commit/0f10e6698eed3505c780400929d1966b45db111a) | simd: decode the valid prefix again when simdutf reports an error | 移植并按本地结构适配 |
| [582f769ddf](https://github.com/ghostty-org/ghostty/commit/582f769ddf6e6bfbe8ad5839de14702490eb59a6) | terminal: speed up UTF-8 error case in SIMD decoding (#15162) | 移植并按本地结构适配 |
| [1450c11b6e](https://github.com/ghostty-org/ghostty/commit/1450c11b6eca1490fdcb9140d02089010d97717e) | terminal: keep the pruned page's memory when grow prunes by lines (#15173) | 移植并按本地结构适配 |
| [0af5c9e55c](https://github.com/ghostty-org/ghostty/commit/0af5c9e55c5b790de15aa7c7fcd90472b41c53cd) | terminal: cap the rows computed by Capacity.adjust (#14856) | 移植核心及回归；本地已移除的 snapshot SDK 不引入 |
| [bf14ea1fbd](https://github.com/ghostty-org/ghostty/commit/bf14ea1fbda2d069112003b80ec3b9186b7688f6) | terminal/tmux: reject zero-sized and oversized panes in layouts (#14858) | 移植核心及回归；本地已移除的 snapshot SDK 不引入 |

## 适配说明

- 核心回归放入现有拆分测试目录；保留此前 CJK 编辑和 PTY 边界回归。
- 宽字符换行保留本地字素搬移实现；搬移源列使用换行前边界，后续输出使用换行后的右边距。
- 清屏复用页面替换时的光标样式/超链接恢复逻辑；历史擦除先移除图片位置，再移动并作废引用。
- 图片新增稳定 transmission 序号；动画更新仍使用 generation 刷新纹理，不改变传输年龄。
- I/O 配置更新显式传入线程数据，直接写颜色报告，避免向自己负责读取的邮箱发送阻塞消息。
- 按行限制回收页面时仅对马上复用的池内存使用 retain；缩小容量、显式裁剪和销毁仍 reclaim。
- 本地 SplitTree 不再负责 Codable，移植初始化状态约束和原生窗口状态更新，无需恢复已删除的序列化接口。
- SSH 文档保留 cghostty 命令名，应用与安装过程均不改用户配置。

## 不适用的上游改动

- GTK、Windows/AVX-512、FreeBSD、独立 libghostty-vt C ABI/SDK、发行基础设施及翻译不属于本项目交付范围。
- 混合宽度 printSliceMixed 是上游新增性能路径；其后续跨页样式修复只针对该新路径。当前没有该路径，因此不把二者当作已有缺陷移植。
- style u128、批量样式/ASCII 输出及新的页面容量策略属于成组性能重构；没有作为独立正确性修复引入。
- `20ba6462d7` 仅为 GTK 使用的 SplitTree.goto 增加调用契约断言，上游明确说明不是现有缺陷修复，不引入。
- 上表三项已由本地实现解决，保留本地实现及现有回归。

## 验证

- Debug 全量核心测试：3,823 通过，5 跳过（后补的容量和 tmux 修复另行验证）。
- 最终容量、tmux、零尺寸及 CJK 编辑 Debug 回归：333/333 通过。
- macOS 原生测试：525 通过，0 失败，2 跳过。
- Python 脚本套件对最终 ReleaseLocal 二进制执行：66/66 通过，无跳过；其中 SSH 覆盖 5 组环境/安装组合。
- Shell 测试实际执行 bash/zsh 的目录报告代码，覆盖中文、反斜杠、ESC/BEL 路径。
- SwiftLint 严格检查、版本同步、范围检查、Swift 6 并发设置、本地化与 diff 检查通过。
- 尝试额外 ReleaseSafe 全量测试时，现有 fullReset tracked-pins 测试依赖 Debug 专用接口，编译中止；不计为通过。未削弱该检查，交付依据是 Debug 全量及最终增量测试。

此次不进行真实 SSH 远端连接；SSH 验证使用本地替身进程。
独立 MLX 修复文件在工作开始时 SHA-256 为 `de8d32a69701660f35ff921b3db9c361bf0743ecda4adf78aa85ce4b4fe3269b`，本次不修改它。

## 本机安装验证

- ReleaseLocal 0.6.2（build 52）已替换 `/Applications/cghostty.app`；签名、arm64 和版本检查通过。
- 已安装二进制与构建产物 SHA-256 一致：`a6c1957b7bfe246876124d2c44da0bc4a9c258ccfedc68fbcd4f0deadc826e38`。
- 旧版保存在 `artifacts/backups/cghostty-0.6.1-before-0.6.2.app`。
- 设置文件与独立 MLX 修复文件在替换前后 SHA-256 均未改变。
- 已安装应用真实窗口调用实际 `mlx_lm.cli_ui.corridor_input`：首字、全部、中英文混合、中间删除、90 个中文长行回删、删除后重输和 Ctrl+U 共 7/7 提交值通过。
- 8 组 VT 宽字符擦除、覆盖、删除的终端内容与参考行一致；字体缩小及恢复后内容保持正确。未模拟输入法尚未提交的拼音候选状态。
- 本地证据保存在 `artifacts/upstream-fixes-0.6.2/`，不纳入 Git。
