## 0.1.8 版本与更新说明（2026-09-21，待用户提交）

- 项目版本从 0.1.7 提升至 **0.1.8**；三个应用构建配置的版本同步为 0.1.8，构建号提升至 **8**。测试目标的独立版本号保持原值。
- 更新说明位于根目录 `RELEASE_NOTES.md`，可直接用于 GitHub Release，并能随正常 Git 提交纳入版本控制；旧 `artifacts/` 目录的说明与安装包保留历史状态。
- 本轮只更新版本元数据和说明，未重新构建应用或安装包，未提交、创建标签、推送或发布。已有本地试用应用仍为 0.1.7；功能验证沿用下方本轮优化记录，不描述为新一轮测试。

## 光标与渲染器效率优化（2026-09-21，未发布）

- 按用户要求保持主体上限 **220ms**、尾部 40–60ms、主体放大 12% 与默认 3 像素笔画。每个轮换帧槽独立记录文字/背景版本和文字数量，两项同步都成功后才提交版本；纯动画帧复用已有数据，尺寸/资源变化失效，版本回绕清空各槽状态。
- 垂直同步实际运行时停止光标专用 8ms 定时器，Kitty 更新截止时间独立保留；无垂直同步时继续由定时器绘制。显示器变更后重新评估调度。基线另外发现常亮光标被闪烁定时器重绘；现在只在闪烁相位会改变可见形状时运行该定时器，取消与重新启用的交接保留唤醒。
- GPU 执行和显示提交共用健康状态判断，同步/异步显示提交失败均使光标历史失效；保留原来的单次帧槽释放路径。尾部按路径长度渐细，压缩近直线中间点，保留上一帧和反转点；32 点累计局部误差低于 0.032px，尾长仍无像素上限。
- 使用有界 Hermite 初始速度承接重定向，保持到达期限；同方向在边界允许时保持速度连续，强反向丢弃旧方向惯性，侧向偏移不超过四分之一个单元格宽度。不是所有反转都无条件保持速度连续；首次长跳仍渐进起步，单格首次响应保留旧缓出曲线。
- renderer 核心回归 **113/113 通过，89/89 构建步骤**，日志 `/private/tmp/cghostty-render-opt-core-v2.log`。新增每帧槽版本与部分上传失败、垂直同步接管/后备与 Kitty 截止时间、同步/异步显示失败、尾部压缩/渐细、同向速度、反向与侧向约束、实际闪烁需求的测试；既有跨帧连通、持续输入和状态切换通过。
- 优化前后相同 ReleaseLocal/ReleaseFast 性能测试各 **2/2 通过**。每场景预热 1 秒、观测 6 秒，覆盖静止、持续输入、长跳、动图并行及新增分屏。结果 `/private/tmp/cghostty-perf-before-final.xcresult` 与 `/private/tmp/cghostty-perf-after.xcresult`，对比 `/private/tmp/cghostty-render-performance-comparison.json`；可复现方法和完整结论见 `RENDERER_PERFORMANCE.md`。
- 垂直同步长跳复制量 **144.01 → 21.84MB（减少 84.8%）**，光标定时器唤醒 **730 → 0**，绘制次数 **732 → 732**；静止常亮场景绘制 **10 → 0**。持续输入复制量减少 29.4%，分屏减少 59.0%。CPU/GPU 平均耗时并非全部下降，明确保留持续输入等场景的退化样本，不宣称普遍提速或量化能耗收益。CPU 列为包含帧槽等待的墙钟耗时，GPU 列为 Metal 执行时间，不包含最终显示延迟。可选记录不保存终端文字或按键内容，正常启动关闭。
- 真实 Metal 光标回归的垂直同步开启/关闭两项通过，结果 `/private/tmp/cghostty-render-opt-ui.xcresult`；该轮新增缓存颜色测试失败，录像确认画面正确，是测试按固定 device RGB 阈值识别截图主色导致。改为 sRGB 主色通道比较后，单独专项 **1/1 通过**，结果 `/private/tmp/cghostty-render-opt-cache-v2.xcresult`，包含文字/背景红蓝切换与常亮→闪烁→常亮。保留原来的主体尺寸与尾部连通断言，未为该测试改动产品颜色。
- 完整原生测试 **277 通过、1 项既有基准跳过、0 失败**，结果 `/private/tmp/cghostty-render-opt-native.xcresult`。最终性能、光标、缓存专项与原生摘要中的运行时警告均为空。首轮性能测试修正了 ReleaseLocal 测试模块导入、配置隔离与分屏查询；测试动作使用 `CGHOSTTY_TESTING`，普通发布构建不启用。
- 最终 ReleaseFast 核心及 ReleaseLocal 应用构建成功，日志 `/private/tmp/cghostty-render-opt-release.log` 无 `warning:` / `error:` 诊断；Zig 格式、严格 SwiftLint、Swift 6、依赖版本、原生配置桥、diff 与应用范围检查通过。应用范围/架构/资源/签名记录 `/private/tmp/cghostty-render-opt-release-scope.log`。
- 试用应用 `macos/build/ReleaseLocal/cghostty.app`，版本仍为 **0.1.7**。本轮未提交、打新标签、发布或替换已安装应用。真实物理 Vim 长按、外接显示器切换及长期能耗仍需实际环境验收；没有把受控 PTY 和调度策略测试描述为这些场景的硬件实测。

## 长距离起步加速与绘制历史尾部（2026-09-21，未发布）

- 主体仍使用 24–220ms 的距离自适应时长。长距离从静止开始时渐进加速再减速，单格输入保留快速响应；运动中的连续重定向不反复重播慢起步。以 1000 像素、220ms、理想 60Hz 采样为例，首帧位移从约 210.49 降至 16.35 像素。此为曲线计算及核心回归结果，不是显示器逐帧测速。
- 尾部改为最近 40–60ms 的已提交绘制位置历史，最多保存 32 个点，并始终接回上一提交帧的主体位置。转弯按历史折线连接，过期端点插值收拢，不设像素长度上限；先前独立追赶模型的约 106.80 像素峰值不再适用。完整主体、12% 放大、轻微椭圆化和默认 3 物理像素笔画保留。
- 仅采样或提交前失败不写入历史；GPU 报告帧失败后清空历史。这里的记录时机是 Metal 命令提交，不宣称系统合成器一定显示每一提交帧。长时间无绘制后恢复仍连接上一位置，保持阶段覆盖实际提交到达帧后的尾部收拢。
- 最终 renderer 回归 **105/105 通过，89/89 构建步骤**，日志 `/private/tmp/cghostty-history-core-verified.log`。覆盖 30/60/120/240Hz、八方向、三种形状的前后帧连接；500 次快速重定向与 1/8/16/33/100ms 间隔；500ms 绘制中断、纯采样不记历史、提交失败失效、形状切换清理和停止恢复。首轮测试中的向量类型及错误的内部记录数量假设已修正。
- 真实 Metal 桌面回归 **2/2 通过，0 失败，运行时警告为空**，结果 `/private/tmp/cghostty-history-ui.xcresult`，摘要 `/private/tmp/cghostty-history-ui-summary.json`，截图 `/private/tmp/cghostty-history-ui-attachments/`。垂直同步开启/关闭分别验证单格和长距离横竖斜向、三种形状、每 32ms 连续转弯、完整主体、尾部像素连通、最小化恢复及停止恢复；抽检转弯截图确认折线路径连续。逐刷新帧的时间连续性由核心序列回归验证，桌面测试使用受控 PTY，并非实际 Vim 物理长按或高速摄像验收。最终额外增加的 GPU 失败失效钩子通过核心回归及应用重建，未为该失败分支重复整套桌面测试。

- ReleaseFast 核心与 ReleaseLocal 应用重建成功，日志 `/private/tmp/cghostty-history-release.log` 无 `warning:` / `error:` 诊断；应用架构、资源、签名及范围检查通过，日志 `/private/tmp/cghostty-history-release-scope.log`。Zig 格式、严格 SwiftLint、Swift 6、依赖版本、配置桥与 diff 检查通过。
- 可试用应用为 `macos/build/ReleaseLocal/cghostty.app`，实际版本 0.1.7。本轮保留本地修改，没有提升版本、提交、打标签、发布或替换已安装应用；已有发布包不包含本轮改动。

## 长距离动画延长至 220ms（2026-09-21，未发布）

- 主体时长范围从 24–180ms 调整为 24–220ms。尾部额外追赶时间随主体时长从 40ms 平滑增至 60ms，长距离尾部总时长为 280ms；只将主体延长而固定 40ms 跟随差会缩短峰值偏移，因此同步增加长距离跟随差。停止恢复的保持时间同步覆盖尾部到达。
- 从静止单次移动 1000 像素时，新峰值中心偏移为约 106.80 像素，约在 82.33ms 出现；原值约为 88.96 像素。横向、竖向、斜向及方块/细线/下划线使用相同规则，尾部仍无固定长度上限。保留 12% 主体形变、轻微椭圆化及默认 3 物理像素笔画。
- 渲染定向回归 **102/102 通过，89/89 构建步骤**，日志 `/private/tmp/cghostty-220ms-core-final.log`。更新八方向与三种形状的峰值断言；新增长距离起步原位置可见、逐毫秒保持活动及尾部追赶期间持续绘制的回归。首轮新增测试的浮点字面量类型错误已修正，再次编译与测试通过。
- 保留原缓出曲线，按理想 60Hz 采样，1000 像素移动在第一个 16.67ms 样本的主体位移由约 253 降至 210 像素。此结果说明起步速度降低，但不能据此确认用户所见的起步消失已经修复；终端显式隐藏光标仍按原协议执行，未强制显示。
- Metal 桌面回归 **2/2 通过，0 失败，无运行时警告**，结果 `/private/tmp/cghostty-220ms-ui.xcresult`，摘要为同名前缀的 `-summary.json`，截图位于 `-attachments/`。两组分别覆盖垂直同步开启/关闭、窗口留白、三种光标的单格与长距离横竖斜向移动、主体完整性、尾部像素连通、最小化恢复与停止精确恢复。真实绘制回归使用受控 PTY，不等同于用户所述环境的起步闪失复现；本轮未重复全套原生测试。
- ReleaseFast 核心及 ReleaseLocal 应用重建成功，日志 `/private/tmp/cghostty-220ms-release.log` 无 `warning:` / `error:` 诊断；应用架构、资源、签名和范围检查通过，日志 `/private/tmp/cghostty-220ms-release-scope.log`。Zig 格式、严格 SwiftLint、Swift 6、依赖版本、配置桥和 diff 检查通过。
- 试用应用位于 `macos/build/ReleaseLocal/cghostty.app`，实际 CLI 版本为 0.1.7。该应用包含本轮本地修改，未提交、修改版本标签、发布或替换已安装应用。

## 移除尾部长度上限（2026-09-21，未发布）

- 按用户要求删除尾部的单元格宽度上限与光标自身尺寸上限。横向、竖向、斜向和三种光标均直接采用主体/尾部缓动进度之差，保留尾部额外 40ms 的追赶时长、主体等比例放大 12%、轻微椭圆化及默认 3 物理像素笔画。连续重定向保留当前主体和尾部位置。
- 长距离单次移动使用主体 180ms、尾部 220ms 的时长。从静止移动 1000 像素，峰值偏移约为 88.96 像素，发生在约 66.11ms；该数值是中心间距，不是外露尾长，也不是新的固定上限。绘制继续覆盖主体与尾部之间的整段连接区域，不依赖两者始终重叠来保持连接。
- 渲染定向回归 **101/101 通过，89/89 构建步骤**，日志 `/private/tmp/cghostty-free-tail-core.log`。新增八方向、三种形状的等长移动峰值与方向一致性断言；持续长跳和反向重定向验证位置连续、有限、保留在移动区域内，停止后完全收拢。既有主体尺寸、持续输入、隐藏重绘和帧调度回归通过。
- Metal 桌面回归 **2/2 通过，0 失败，无运行时警告**，结果 `/private/tmp/cghostty-free-tail-ui.xcresult`，摘要为同名前缀的 `-summary.json`，截图位于 `-attachments/`。垂直同步开启/关闭分别验证三种光标的长距离横向、竖向和斜向跳转，每段必须拍到超过旧上限的尾部；逐帧验证主体完整、所有绿色像素为一个四邻接连通区域，避免仅通过包围盒掩盖断尾。保留单格重复输入、最小化恢复、停止精确恢复及系统提示遮挡识别。
- 抽检的方块尾部截图整体尺寸为横向 93×46、竖向 21×102、斜向 52×85 像素；这些是不同时间点的主体与尾部整体包围盒，不是峰值中心偏移。测试使用受控 PTY，不宣称实际 Vim 物理长按或 GPU 性能验收。本轮未重复原生全套测试，既有 277 项通过记录仍属于前一轮。
- ReleaseFast 核心及 ReleaseLocal 应用重建成功，日志 `/private/tmp/cghostty-free-tail-release.log` 无 `warning:` / `error:` 诊断；应用架构、资源、签名和项目范围检查通过，记录 `/private/tmp/cghostty-free-tail-release-scope.log`。严格 SwiftLint、Zig 格式、Swift 6、依赖版本、配置桥与 diff 检查通过，README 最长行仍为 64 显示列。
- 试用应用仍位于 `macos/build/ReleaseLocal/cghostty.app`，版本 0.1.6 / 构建号 6。改动保留本地，未提交、打标签、发布或替换已安装应用；旧 0.1.6 ZIP 的 SHA-256 已核对未变，不包含本轮修改。

## 稳定主体与短尾部跟随（2026-09-21，未发布）

- 主体保持等比例放大 12% 与轻微椭圆化，默认细线仍为 3 个物理像素。增加独立尾部偏移，跟随时长比主体多 40ms；尾部偏移同时受 0.75 个单元格宽度及按原生光标尺寸归一化后的 0.75 距离限制。长距离搜索跳转不会无限拉长，细线横移也不会留下整格宽的尾带。
- 重定向承接当前主体位置、尾部偏移和形变量；持续输入不重新收缩再放大。形变保持阶段至少覆盖尾部追上所需时间，随后平滑恢复原生尺寸。Metal 将完整主体与渐细尾部取覆盖并集，尾部只能增加覆盖，不能削掉主体；保留上一轮屏幕坐标直接投影修复。
- 核心 renderer/config/Metrics/光标字形定向回归 **315/315 通过，89/89 构建步骤**，日志 `/private/tmp/cghostty-body-tail-core.log`。新增主体到达后尾部继续收拢、快速长距离跳转及改向时尾部连续且有界的测试；既有八方向、三种形状、持续输入、隐藏重绘、状态切换和帧调度回归同时通过。
- 完整原生回归 **277 通过、1 项既有基准跳过、0 失败**，运行时警告为空。结果 `/private/tmp/cghostty-body-tail-native.xcresult`，摘要 `/private/tmp/cghostty-body-tail-native-summary.json`。
- 桌面首轮失败帧明确显示 macOS 蓝色大写锁定提示覆盖光标，并非主体被尾部压窄。测试新增遮挡识别，仍要求每段至少 8 张未遮挡的可见帧满足完整主体及整体尺寸上限；没有放宽主体几何断言，也没有修改用户的大写锁定状态。首轮结果 `/private/tmp/cghostty-body-tail-ui.xcresult`，失败截图位于同名前缀的 `-attachments/`。
- 最终 Metal 桌面回归 **2/2 通过，0 失败，无运行时警告**：垂直同步开启＋较大留白、垂直同步关闭＋零留白。每组检查横向、竖向、斜向、反向、最小化恢复，以及细线/下划线横竖移动与停止恢复；快速单格重复输入必须实际拍到尾部。结果 `/private/tmp/cghostty-body-tail-ui-v2.xcresult`，摘要为同名前缀的 `-summary.json`，截图位于 `-attachments/`。静止方块为 19×42 像素，抽检横向含尾部帧为 26×46，斜向为 24×53；断言还在包围盒内部验证完整主体，不能仅靠尾部长宽通过。
- 以上桌面测试使用受控 PTY 的位置、形状与隐藏/显示序列；不等同于实际 Vim 物理长按、所有输入法/显示器组合或 GPU 性能测试。
- 已重建 ReleaseFast 核心与 ReleaseLocal 应用，日志 `/private/tmp/cghostty-body-tail-release.log` 无 `warning:` / `error:` 诊断；应用的 arm64、资源、签名与项目范围检查通过，记录 `/private/tmp/cghostty-body-tail-release-scope.log`。严格 SwiftLint、Zig 格式、Swift 6、依赖版本、配置桥及 diff 检查通过。README 保持短行，最长 64 显示列。
- 试用应用：`macos/build/ReleaseLocal/cghostty.app`。版本仍为 0.1.6 / 构建号 6；本轮未提交、打标签、发布或替换已安装应用。既有 0.1.6 ZIP 已核对 SHA-256 未变，不包含本轮试用改动。

## 整体光标形变与屏幕坐标修正（2026-09-21，未发布）

- 用单一中心位移替换四角独立追赶，移除前后沿差速与凸包处理。方块、细线和下划线均等比例放大至 **112%**，保持长宽比例；Metal 使用四次超椭圆柔化轮廓，不沿移动方向拉伸。默认笔画厚度由 1 改为 **3 个物理像素**，现有厚度调整配置仍可覆盖。
- 位置与形变包络分开管理。展开约 24ms；新位置延长保持阶段，覆盖最长 120ms 的短输入间隔，且至少保持到位置到达；停止后用 100ms 收回。连续输入不重新播放展开阶段，收回中再次移动从当前形变量接续。形状/尺寸切换、隐藏/显示和 Reduce Motion 保留既有生命周期约定。
- 新增逐帧回归覆盖八方向、三种光标、放大上限、比例不变、精确恢复、8/16/33/60/100ms 单格持续输入、快速改向、Vim 式隐藏重绘及中断收回。实际字体栅格回归验证默认细线宽度 3 像素和显式 1 像素覆盖。核心 renderer/config/Metrics/光标字形定向回归 **313/313 通过，89/89 构建步骤**：`/private/tmp/cghostty-uniform-motion-core-final.log`。
- 真实 Metal 测试首轮发现尺寸不符：19×42 静止光标移动后仅为 21×44，上侧轮廓被裁切。根因是动画使用包含留白的屏幕坐标，顶点又应用带留白的网格投影，覆盖区域与包围三角形错位。改为屏幕像素直接映射裁剪坐标。相同场景修复后为 21×46，符合 12% 几何放大及像素抗锯齿误差，原生细线确认宽度 3 像素。修复后的首组完整桌面回归 **2/2 通过**：`/private/tmp/cghostty-uniform-motion-ui-v2.xcresult`；截图保存在 `/private/tmp/cghostty-uniform-motion-ui-v2-attachments/`。首轮失败是实际渲染错误，未放宽尺寸断言来绕过。
- 顶点投影修正后，最终完整原生复验 **277 通过、1 项现有基准跳过、0 失败**：`/private/tmp/cghostty-uniform-motion-native-final.xcresult`；摘要 `/private/tmp/cghostty-uniform-motion-native-final-summary.json`。
- 最终 Metal 桌面回归 **2/2 通过**：分别使用垂直同步开启＋较大留白、垂直同步关闭＋零留白。每组覆盖左右上下、斜向、最小化恢复、细线与下划线的横/竖移动及停止后精确恢复；每段采集 12 帧，对每张可见帧验证尺寸范围，而非任意一张符合即通过。结果 `/private/tmp/cghostty-uniform-motion-ui-final.xcresult`；摘要 `/private/tmp/cghostty-uniform-motion-ui-final-summary.json`。最终原生和桌面结果均无运行时警告。
- 实际 UI 使用受控 PTY；不将这些结果描述为所有 Vim 物理按键、输入法、显示器组合或 GPU 性能验收。首次核心构建受 Metal 模块缓存的沙盒权限限制，使用获准的本地构建权限重跑通过，未绕过测试失败。
- 最终 ReleaseFast 核心与 ReleaseLocal 应用重建成功，日志 `/private/tmp/cghostty-uniform-motion-release.log` 无 `warning:` / `error:` 诊断；应用范围、arm64、资源与签名检查通过：`/private/tmp/cghostty-uniform-motion-release-scope.log`。严格 SwiftLint、Zig 格式、Swift 6、依赖版本、配置桥及 diff 检查通过。
- 可试用应用位于 `macos/build/ReleaseLocal/cghostty.app`，未替换 `/Applications` 中的应用。本轮保留版本 0.1.6 / 构建号 6，改动未提交、未打新标签、未发布；既有 `v0.1.6` 与 ZIP 仍对应上一版代码，ZIP 的 SHA-256 已核对未变。

## 0.1.6 本地安装包（2026-09-21，未发布）

- README 按功能、安装、配置、构建与开发重新编写，采用短句与短行；最长行按中文双宽计算为 64 列，本地文档链接均有效。
- 项目版本提升至 **0.1.6**，三个应用构建配置的构建号均为 **6**。完整重建 ReleaseFast Zig 核心和 ReleaseLocal 原生应用成功；日志 `/private/tmp/cghostty-0.1.6-release-build.log` 无 `warning:` / `error:` 诊断。
- 应用位于 `macos/build/ReleaseLocal/cghostty.app`。平台范围、生成配置桥、126 个原生文件的桥接边界、应用资源、arm64 架构和完整签名检查通过：`/private/tmp/cghostty-0.1.6-release-scope.log`。修改的 Zig / Swift 文件格式、Swift 6、依赖版本与 diff 检查通过。
- 安装包 `artifacts/cghostty-0.1.6-macos-arm64.zip`，**12,667,823 字节**；同名 `.sha256` 校验通过。SHA-256：`501e799421dadb629c4e062b891ea70ef664effcb5f51191eec95f07cd24e247`。
- ZIP 完整性检查通过。解压后再次验证签名、arm64、最低 macOS 27.0、应用版本 0.1.6、构建号 6 和 CLI `+version`；解压后主程序与构建产物的 SHA-256 相同。验证记录：`/private/tmp/cghostty-0.1.6-package-verification.json`。
- 包含下方光标连续变形、帧调度、SearchSession 和 RenderSession 改动。功能回归沿用本次版本修改前同一工作树的最终结果：Zig **128/128**、原生 **277 通过 / 1 跳过**、Metal 光标与关闭撤销桌面回归 **4/4**；本轮版本与文档修改后重新构建发行版并校验包，未重复全部功能测试。
- 使用 ad-hoc 签名，未进行 Developer ID 公证。安装包及校验文件保存在被 Git 忽略的 `artifacts/`，不提交二进制；源码提交与本地附注标签 `v0.1.6` 对应。未推送、创建 GitHub Release 或替换已安装应用。

## Surface 渲染会话拆分（2026-09-21，未发布）

- 新增 `src/surface/RenderSession.zig`，集中持有渲染器、渲染线程管理器、OS 线程、共享渲染状态和互斥锁。会话采用稳定堆地址，资源创建完成后才交给 Surface；线程启动与资源创建分开，启动失败保持 ready，停止/join 可重复调用，已停止会话禁止重启。
- Surface 只协调跨子系统依赖：先停止搜索和 IO 生产者，再停止/join 渲染线程，最后释放终端与渲染会话。构造失败路径补齐渲染启动后 IO 创建失败、两个线程启动后的后续失败回滚；IO 清理使用 Surface 中的稳定字段，避免释放线程运行前的旧副本；初始字体引用在创建失败时回收。
- 渲染线程释放未消费消息中的配置、搜索高亮 arena 和旧字体引用；先销毁渲染器，再回收排队的旧字体引用，最后由 Surface 释放当前字体。渲染器析构同时回收线程尚未启动时已经解码的背景图片，覆盖未进入 threadExit 的清理路径。
- 最终 Zig 定向回归 **128/128 通过，89/89 构建步骤**，覆盖 RenderSession、renderer 和 SearchSession：`/private/tmp/cghostty-render-session-core-final-v2.log`。新增回归注入线程创建失败，使用真实线程与事件循环验证停止/join、重复停止及重复启动拒绝；未启动队列回收测试同时验证配置、搜索快照与连续字体切换，确认只保留 Surface 当前字体引用。测试分配器未报告泄漏。日志含系统 hiservices 连接提示，退出码为 0。
- 重建最终 Debug 核心和原生应用后，完整原生回归 **277 通过、1 项现有基准测试跳过、0 失败**。新增测试连续三轮创建会话、改变字体/尺寸/可见性/焦点后立即释放，验证视图和最后一个 handle 均释放。结果：`/private/tmp/cghostty-render-session-native-final.xcresult`；摘要：`/private/tmp/cghostty-render-session-native-summary.json`。
- 最终桌面回归 **4/4 通过**：实际 Metal 光标前沿扩宽、细线恢复、最小化恢复及垂直同步开关 **2/2**（`/private/tmp/cghostty-render-session-motion-ui-final.xcresult`）；关闭标签和分屏后撤销，保留原 shell 会话并恢复输入焦点 **2/2**（`/private/tmp/cghostty-render-session-lifecycle-ui.xcresult`）。本轮原生与两组桌面结果摘要的运行时警告列表均为空，不将此结果视为此前搜索 UI 的 QoS 警告已被定位或修复。
- Zig 格式、严格 SwiftLint、Swift 6、依赖版本、平台范围、生成配置桥、126 个原生文件的桥接边界和 diff 检查通过。架构与维护文档已同步。最新调试应用：`/private/tmp/cghostty-render-session-build/Debug/cghostty.app`。
- IO 启停、输入协调与有效配置仍由 Surface 管理。本轮未穷举真实 OS 资源耗尽、Metal/GPU 分配失败或物理按键长按 Vim 的验收，也未测量 GPU 性能。版本仍为 **0.1.5**；保留前序光标及搜索修改，未提交、推送、发布或覆盖旧发布包，既有 0.1.5 ZIP 不包含这些后续修改。

## Surface 搜索会话拆分（2026-09-20，未发布）

- 新增 `src/surface/SearchSession.zig`，集中搜索线程的稳定地址、创建、查询更新、结果导航、回调转发、停止/join 与释放。`Surface.zig` 净减少 169 行搜索相关实现，只保留可选会话及 UI 命令协调；终端搜索算法与匹配语义未修改。创建成功后才发布会话，创建失败不会在 Surface 留下已释放的工作线程状态。
- 结果回调使用固定 mailbox 依赖，不再读取整个 Surface。高亮先复制为独立 arena，再交给 renderer；复制失败本地回收，入队后的唤醒失败不再误释放已经转交的数据。工作线程 deinit 统一释放未消费查询，覆盖正常停止、未启动和早期错误；原来的停止分支丢弃长查询消息而未释放其缓冲区。
- 新增 2 项 Zig 回归，逐个注入分配失败，验证未启动状态回收、长查询复制及待处理消息释放、多份高亮快照独立和部分复制失败回收。搜索会话及既有 `terminal.search` 回归 **150/150 通过，89/89 构建步骤**：`/private/tmp/cghostty-search-session-core-v2.log`。日志含系统 hiservices 服务连接提示，构建退出码为 0，不将该提示称为断言失败。
- 已重新构建 Debug Zig 核心。新增原生活动搜索释放回归，连续三轮替换长查询、清空并重启，再释放视图和最后一个 handle，验证对象释放且不崩溃。完整原生回归 **276 通过、1 项现有基准测试跳过、0 失败**：`/private/tmp/cghostty-search-session-native-v2.xcresult`，摘要 `/private/tmp/cghostty-search-session-native-summary.json`，运行时警告列表为空。
- 新增桌面搜索回归 **1/1 通过**：结果计数、回车开始选中、前后导航、无结果、两轮清空重启，以及关闭带搜索的分屏后在另一分屏输入。结果 `/private/tmp/cghostty-search-session-ui-v2.xcresult`，摘要 `/private/tmp/cghostty-search-session-ui-summary.json`。既有标签会话/焦点与分屏搜索/命令面板回归 **2/2 通过**，记录在首轮 `/private/tmp/cghostty-search-session-ui.xcresult`；首轮新增测试错误假设搜索自动选中、并读取 label 而非 value，实际 UI 为 `-/3`，修正测试后通过，产品搜索语义未为测试改变。
- 最终桌面回归有 **1 条运行时 QoS 优先级等待警告**，出现在 XCTest 合成 Edit/Select All 菜单事件期间；没有断言失败，应用标准输出未记录同样警告。已检查测试活动、详情与导出诊断，未取得可归因的完整等待栈，保留诊断 `/private/tmp/cghostty-search-session-ui-diagnostics/`，不宣称已经证明与产品无关或完成性能验收。
- 严格 SwiftLint、Zig 格式、Swift 6、依赖版本、平台范围、生成配置桥和 diff 检查通过。调试应用位于 `/private/tmp/cghostty-search-session-build/Debug/cghostty.app`。架构与维护文档已同步搜索会话的生命周期及测试入口。
- 这只是 Surface 子系统化的搜索阶段；渲染/IO 启停、输入协调和配置仍由 Surface 管理。本轮保留上一轮光标修改，版本仍为 **0.1.5**，未提交、推送、发布或覆盖已有发布包。

## 光标前沿扩宽、连续变形与帧调度（2026-09-20，未发布）

- 修复前沿先到达后提前收窄的问题：位置与展开分别维护；前沿展开保持到后沿追上，再用临界阻尼响应收回。斜向展开改为两轴向外，避免法线投影把领跑角推向内部。轴向展开目标约为原边长的 15%，细线光标保留原生厚度。
- 连续重定向继承当前角点、展开量及展开速度，不再每个输入重播宽度脉冲。新增四轴、8/16/33/60ms 输入间隔的连续性测试；既有八方向、薄线、快速反向、凸轮廓和隐藏/显示回归继续通过。停止后回到精确的原生矩形。仅保证展开速度接续，不将原来的位置插值描述为速度连续。
- 新增 `CursorMotion` 集中几何生命周期、跨线程失效与活动状态。Vim 式 DECTCEM 隐藏保留运动，窗口隐藏/失焦、配置或形状/尺寸变化按原契约重置。`FrameScheduler.Timer` 保留较早的待执行截止时间，避免持续终端更新反复推迟绘制；隐藏取消动画计时器，返回前先更新可见状态；DisplayLink 绘制后同步调度状态。
- 最终核心 renderer 回归 **124/124 通过，89/89 构建步骤**：`/private/tmp/cghostty-motion-core-final.log`。完整原生回归 **275 通过、1 项现有基准测试跳过、0 失败**：`/private/tmp/cghostty-motion-native.xcresult`，摘要 `/private/tmp/cghostty-motion-native-summary.json`。
- 新增真实 Metal 像素桌面回归 **2/2 通过**，分别启用和关闭垂直同步，验证右移/下移的前沿比后沿更宽、最小化后恢复，以及细线模式停止后恢复原生尺寸。受控 PTY 每 32ms 移动并周期性隐藏/显示光标；开启 `MTL_DEBUG_LAYER=1`。结果 `/private/tmp/cghostty-motion-ui-v3.xcresult`，摘要 `/private/tmp/cghostty-motion-ui-summary.json`，截图 `/private/tmp/cghostty-motion-captures-final/`。两份最终摘要的运行时警告列表均为空。
- 桌面测量首次将原生绿色全屏按钮纳入掩码，改为只截取终端内容；第二次发现竖向单行移动的测试错误要求长度增长 50%，修正为实际位移及前沿横向宽度断言，额外要求前沿超过静止宽度。最终两种绘制路径均通过，不把早期失败轮次当作通过证据。
- Zig 格式、严格 SwiftLint、Swift 6、依赖版本、平台范围、生成配置桥、126 个原生文件的桥接边界及 diff 检查通过。测试构建有 AppIntents 元数据提取提示；原生日志包含系统 autoShortcut 服务连接失败及故意无效配置测试输出，不宣称整份日志没有 warning/error。
- 已重新构建 Debug 核心与原生应用；本轮没有更新版本、发布或覆盖既有 0.1.5 ZIP。以上验证不代表实际 Vim 物理按键长按、所有输入法/显示器组合或 GPU 性能测量已经完成。

## 0.1.5 本地构建与发布包（2026-09-20，交由用户发布）

- 项目版本提升至 **0.1.5**，三个应用构建配置的构建号均提升至 **5**。完整重建 ReleaseFast Zig 核心及 ReleaseLocal 原生应用成功；日志 `/private/tmp/cghostty-0.1.5-release-build.log` 无 warning/error。应用路径 `macos/build/ReleaseLocal/cghostty.app`。
- 实际应用的 CFBundleShortVersionString、CGhosttyVersion 及 CLI `+version` 均为 0.1.5，CFBundleVersion 为 5，最低 macOS 27.0。平台范围、arm64、原生配置桥、应用资源及完整签名检查通过；日志 `/private/tmp/cghostty-0.1.5-release-scope.log`。
- 发布 ZIP：`artifacts/cghostty-0.1.5-macos-arm64.zip`，**12,665,550 字节**；SHA-256 为 `fa3e075d65ecde7ffc922bb0ff29b41a12c27d77df43dda41fc51bac74a41fb0`，同名 `.sha256` 校验通过。ZIP 内容完整性通过；解压后重新检查签名、arm64 和实际可执行文件版本全部通过。记录 `/private/tmp/cghostty-0.1.5-package-verification.json`。
- 更新说明：`artifacts/cghostty-0.1.5-release-notes.md`。采用 ad-hoc 签名，未使用 Developer ID、未提交 Apple 公证。未替换已安装应用；按用户要求由用户在 GitHub 操作发布，本轮没有提交、推送、创建标签或 Release。当前包包含本地未提交架构改动，发布标签须与包含这些改动的源码提交对应。
- 本次执行完整发布构建及包校验；功能测试结果沿用下方各轮记录，不将打包检查描述为新一轮全部功能验收。

## 自动生成原生配置桥（2026-09-20，未发布）

- 新增 `src/configgen.zig`，通过 Zig `Key` / `Config` 反射及 `c_get.CValue` 生成 `Ghostty.ConfigSchema.swift`。维护列表只选择原生消费的 53 个键，不重复维护字段类型；实际 C getter 与生成器使用同一存储类型函数。Swift `Key<Value>.read` 强制接收变量的类型，构造器限制在生成文件内。
- `ConfigSnapshot` 与 `WindowConfig` 的全部配置读取迁入生成入口，删除手写字符串读取；原生默认值、显示枚举转换、字符串/列表复制及配置应用作用域保持原路径。可选数值仍写入标量存储，以返回 false 表示缺失；可选字符串仍可返回 true 并写入空指针，不混淆两种约定。
- 修复 `abnormal-command-exit-runtime` 以 `UInt32?` 接收 C 整数的布局错误，改用 `CUnsignedInt`；原来写入整数不会正确更新 Swift Optional 的存在标记，可能忽略自定义值。新增参数化测试覆盖 **0、1、250、2500、UInt32.max**，并验证重载为零。核心新增缺失可选数值不改输出、空字符串指针成功返回、不支持类型不改输出的语义测试。
- `zig build update-config-bridge` 更新生成文件；`zig build check-config-bridge` 逐字节校验。正常核心构建、核心测试、原生 `--skip-core` 构建和范围/CI 检查接入校验。使用临时副本将整数键改成 Bool 后，校验明确失败并提示重新生成；记录 `/private/tmp/cghostty-configgen-negative.log`。桥接检查只允许生成文件调用 `ghostty_config_get`，且类型化读取只允许快照解码器使用。
- 核心配置回归 **258/258 通过、89/89 构建步骤**，日志 `/private/tmp/cghostty-configgen-core-tests-v2.log`。Debug 核心已重建用于本轮原生与桌面测试，日志 `/private/tmp/cghostty-configgen-core-build.log`。
- 完整原生测试 **275 通过、1 项现有基准测试跳过、0 失败**，结果 `/private/tmp/cghostty-configgen-native.xcresult`，摘要 `/private/tmp/cghostty-configgen-native-summary.json`。桌面配置重载与外观测试 **2/2 通过**，结果 `/private/tmp/cghostty-configgen-ui-v2.xcresult`，摘要 `/private/tmp/cghostty-configgen-ui-summary.json`。两份摘要运行时警告均为空。
- 桌面首轮模拟重载快捷键未触发更新；最终用实际 Reload Configuration 菜单触发并等待标题/像素状态，保留新快捷键创建窗口的独立断言。该结果证明菜单重载、既有/新窗口配置和深浅色转换，不宣称验收了重载快捷键在所有键盘布局下的行为。
- 5 个 Swift 文件严格 lint、Zig 格式、Swift 6、依赖版本、平台范围、126 个原生文件的桥接边界与 diff 检查通过。生成的是原生使用字段的类型化读取入口，不是完整 C 头文件、配置解析器、显示枚举或全部核心配置的自动生成。
- 版本仍为 **0.1.4**；本轮改动留在本地，未提交、推送、发布或替换已安装应用。

## SurfaceView 生命周期与移动、撤销恢复（2026-09-20，未发布）

- 新增 `SurfaceLifecycle`，集中创建、最终释放与窗口事件监听。暂时离开窗口时移除本地事件监听并清除焦点/可见状态；重新附着时刷新窗口、显示器、缩放与可见状态。移动、关闭后的撤销继续使用同一核心会话，不在 SwiftUI 重建时重新启动 shell。
- 核心 userdata 改为句柄持有的 `SurfaceCallbackContext`，弱引用视图与句柄；主线程和延迟主线程释放均保持 App 与上下文存活直到 core free 完成。最终视图释放先取消搜索、剪贴板确认、观察与计时器，再清除回调视图并释放生命周期。迟到回调可安全忽略，失去视图的剪贴板确认会拒绝完成。原生 Metal 创建仍单独收到真实 NSView。
- `SurfaceRepresentable` 显式拆除滚动容器并取消观察；旧容器只有在视图仍属于自己的 document view 时才能布局、滚动或拆除，防止移动后的旧通知修改新窗口尺寸或移除新窗口视图。创建时的原生显示配置改从所属 App 读取。
- 新增 **5 项原生测试**：跨窗口附着保留核心身份并拆除监听；旧容器不能回写尺寸或移除已迁移视图；视图已释放但句柄仍存活时的迟到关闭/标题/剪贴板回调；重复释放与禁止重新附着；创建配置按 App 隔离。
- 最终完整原生回归 **274 项通过、1 项现有基准测试跳过、0 失败**，运行时警告为空。包含撤销焦点修复的最终结果 `/private/tmp/cghostty-lifecycle-native-final.xcresult`，摘要 `/private/tmp/cghostty-lifecycle-native-final-summary.json`。
- 新增 **2 项桌面撤销测试**，通过原 shell 的变量确认恢复的是原会话，并立即输入确认焦点。首次分屏测试发现关闭时未记录原焦点，恢复树后输入丢失；补充关闭操作的 `moveFocusFrom` 后，标签与分屏 **2/2 通过**。结果 `/private/tmp/cghostty-lifecycle-undo-ui-v2.xcresult`，摘要 `/private/tmp/cghostty-lifecycle-undo-ui-summary.json`，运行时警告为空。测试没有通过额外点击掩盖焦点恢复问题。
- 既有标签布局、全屏、跨窗口移动、合并和分屏缩放 **5/5 通过**，结果 `/private/tmp/cghostty-lifecycle-tabs.xcresult`；搜索、命令面板、标签会话与焦点 **2/2 通过**，结果 `/private/tmp/cghostty-lifecycle-observation.xcresult`。对应摘要文件为同名前缀的 `-summary.json`。
- 分屏拖出新窗口的位置与尺寸 **1/1 通过**，结果 `/private/tmp/cghostty-lifecycle-drag.xcresult`，摘要 `/private/tmp/cghostty-lifecycle-drag-summary.json`。四组桌面回归合计 **10/10 通过**，运行时警告均为空。
- 严格 SwiftLint、Swift 6、依赖版本、平台范围、126 个原生文件的桥接边界与 diff 检查通过。架构与维护文档同步创建、附着、最终释放及回调上下文契约。应用退出后的磁盘恢复仍按原设计创建新会话，未声称恢复旧进程。
- 本轮修改原生代码，使用上一轮已重建的 Debug 核心；未把这轮原生回归描述为新的 Zig 或光标性能测试。版本仍为 **0.1.4**，代码留在本地，未提交、推送、发布或替换已安装应用。

## SurfaceFault 与 IO 失败生命周期（2026-09-20，未发布）

- 新增 `SurfaceFault`：PTY 不可用、输入文件失败、其他 IO 失败三类，保留实际 Zig 错误码。IO 线程通过既有 app mailbox 传递值，不再分配展示字符串或直接改写终端画面。内部 C action 追加枚举值；原生适配器同步复制错误码，跨线程消息不含借用资源。
- Surface 记录故障并请求原生展示；界面未接收时，在 renderer-state 锁内写入终端文本兜底，解锁后请求绘制。原生 SurfaceState 接收尚未附着窗口的错误，SurfaceFaultView 显示原因、错误码和关闭按钮。后来的子进程退出不自动关闭已有故障；IO 已停止时不再提示存在运行中的命令。只读模式原有关闭确认仍保留。
- 超限输入文件测试暴露异常清理缺陷：后端已启动并注册进程/计时器回调后返回失败，旧事件循环继续访问已退出栈中的 completion，实际发生 `EXC_BAD_ACCESS`。修复为丢弃旧循环，使用仅处理消息释放与停止信号的循环；部分启动失败同时执行 backend shutdown 和 ThreadData deinit，避免旧回调和资源泄漏。
- 最终核心定向回归 **84/84 通过**，**85/85 构建步骤**：错误分类、稳定 C 错误码、C 枚举匹配、清空旧画面/隐藏光标/可见文本兜底，以及命令启动回归。日志 `/private/tmp/cghostty-fault-core-final.log`。更新后的 Debug 核心已重建并用于原生与桌面测试。
- 新增 **3 项原生测试**（输入失败包含缺失、超过 10 MiB 两组）：诊断字符串复制及跨线程使用；真实 IO 故障抵达未附着原生视图，原生接收后不污染终端内容；故障后连续 200 次输入超过消息队列容量仍可清理，配置消息正常释放；交付前关闭可释放视图和 App。完整原生回归 **269 通过、1 项现有基准测试跳过、0 失败**，运行时警告为空。结果 `/private/tmp/cghostty-fault-native-final.xcresult`，摘要 `/private/tmp/cghostty-fault-native-summary.json`。
- 新增桌面回归 **2/2 通过**：缺失文件显示明确错误且按钮可关闭；通过菜单重载修正配置后，新窗口正常启动，原错误保留，并能单独关闭失败窗口。测试使用独立配置和默认值域。恢复用例最终通过实际菜单标题定位重载，并先置前被新窗口遮挡的旧窗口再点击关闭，不使用固定延时。结果 `/private/tmp/cghostty-fault-ui-final.xcresult`，摘要 `/private/tmp/cghostty-fault-ui-summary.json`，运行时警告为空。
- SwiftLint 严格检查、Zig 格式、Swift 6、版本记录、平台范围、125 个原生文件的桥接边界和 diff 检查通过；架构文档同步错误交付和异常释放契约。同步 Surface 创建失败与普通进程退出仍沿用原路径，不宣称统一了所有错误类型。
- 改动留在本地；版本仍为 **0.1.4**，本轮未提交、推送、发布或替换已安装应用。

## 窗口注册表与应用级窗口状态收尾（2026-09-20，未发布）

- `WindowRegistry` 增加普通窗口弱注册、按 App 过滤的 AppKit 顺序列表、弱 last-main 与独立层叠位置。保留未选中标签窗口；普通窗口强引用保活仍由 `openControllers` 负责，快速终端仍独立持有，不引入 App 与控制器的循环引用。
- `TerminalController` 删除静态窗口列表、最近主窗口和层叠位置；加载时注册、关闭时注销。已关闭但被撤销或待执行任务持有的控制器不再成为默认父窗口；延迟 focus/cascade 对已关闭窗口无效。最后一个窗口关闭会清空位置状态，其他 App 的 key window 和面板不能污染该状态。
- AppDelegate、系统服务、AppleScript、App Intent、命令面板统一使用所属 App 的注册表；核心“关闭全部窗口”回调从传入核心 App 找到对应原生 App。窗口模板也读取其所属 App 配置。
- 新增 **6 项原生测试**：列表/父窗口按 App 隔离；关闭仍被持有的最近主窗口；固定位置、外来窗口和关闭后排布保护；外来 key window 不改变位置；核心 close-all 仅关闭发起 App；窗口关闭后控制器和 App 释放。初版测试使用空分屏树触发现有自动关闭规则，改为真实隔离 shell 后通过。
- 最终完整原生回归 **266 项通过、1 项现有基准测试跳过、0 失败**，运行时警告为空。结果 `/private/tmp/cghostty-window-registry-native-final.xcresult`，摘要 `/private/tmp/cghostty-window-registry-native-summary.json`。
- 新增实际桌面测试 **2/2 通过**：连续窗口按 30pt 错位、关闭最近窗口后继续排布；关闭最近窗口后新标签加入剩余窗口。独立配置/默认值域，等待实际窗口数量与位置，不增加固定延时。结果 `/private/tmp/cghostty-window-registry-ui.xcresult`，摘要 `/private/tmp/cghostty-window-registry-ui-summary.json`，运行时警告为空。
- 既有标签栏、分屏缩放、全屏、跨窗口移动和合并回归 **5/5 通过**。结果 `/private/tmp/cghostty-window-registry-tabs.xcresult`，摘要 `/private/tmp/cghostty-window-registry-tabs-summary.json`，运行时警告为空。
- 本轮 10 个改动 Swift 文件的严格 lint、124 个原生文件的桥接边界检查、Swift 6、版本记录、平台范围与 diff 检查通过。文档同步窗口状态归属。本轮未修改 Zig，沿用已验证的 Debug 核心；版本仍为 **0.1.4**，本轮改动未提交、推送或发布。

## 原生配置句柄与完整界面快照（2026-09-20，未发布）

- 新增 `Ghostty.ConfigHandle`，集中拥有配置分配、按原顺序加载文件/CLI/递归文件、finalize、clone、诊断和释放。`Ghostty.Config` 以一个 State 同时发布句柄与快照；删除原始指针替换入口和含混的 `clone(config:)` 采用语义。快捷键查询继续使用同代核心句柄。
- 新增不可变、Sendable 的 `Ghostty.ConfigSnapshot`：覆盖原 Config 的 **47 个原生配置读取项**，加已有 **6 个窗口字段**及加载/诊断状态。字符串、命令面板项、颜色和尺寸均为自有 Swift 值；旧快照不持有句柄。Config 保留的原生属性仅转发快照，不再逐次调用 C getter。
- App、普通窗口、快速终端、Surface、玻璃背景的 DerivedConfig 显式接收快照。全局应用配置现在先发布到 App，再发送同步通知，避免同步监听者读取旧 App 配置；局部 Surface 配置仍独立，隔离测试扩展至背景透明度和窗口主题。
- 快照初始化覆盖未加载配置时，测试暴露系统目录颜色不能直接调用 `getHue` 的异常；`NSColor.darken` 先转换到 sRGB，再取颜色分量。未加载快照及原有 unfinalized 配置回归最终均通过。测试中同步通知的载荷先提取为 Sendable 的 Config 引用后再进入 MainActor，符合 Swift 6 检查。
- 新增 **6 项原生配置快照测试**：跨线程/重载/释放后的字符串、命令与诊断存活；旧句柄及时释放；clone 独立句柄与快捷键；未加载默认值；整代替换仅通知一次；App 发布先于同步通知。玻璃背景测试改为真实配置，不再覆盖 facade 属性制造另一份状态。
- 完整原生回归 **260 项通过、1 项现有基准测试跳过、0 失败**；运行时警告为空。结果 `/private/tmp/cghostty-snapshot-native-v4.xcresult`，摘要 `/private/tmp/cghostty-snapshot-native-summary.json`。
- 新增桌面配置回归 **2/2 通过**：重载更新现有窗口标题、新快捷键打开的新窗口继承配置，以及实际原生窗口从深色切换到浅色。使用状态/像素谓词等待结果，不增加固定延时。测试使用独立临时配置和默认值域，不修改用户系统外观；结果 `/private/tmp/cghostty-snapshot-ui.xcresult`，摘要 `/private/tmp/cghostty-snapshot-ui-summary.json`，运行时警告为空。
- 桥接检查增加配置约束：C 配置值查询仅允许快照解码器，分配/克隆/加载/释放仅允许 ConfigHandle。**124 个原生文件**边界检查、SwiftLint 严格检查、Swift 6、版本记录、平台范围和 diff 空白检查通过。
- 本轮未改 Zig 配置解析规则或渲染器；核心沿用上一轮已验证产物，本轮不重复宣称新的核心测试结果。自动生成配置桥仍为后续工作。改动保持本地，版本仍为 **0.1.4**，未提交、推送或发布。

## 原生桥接集中收尾（2026-09-20，未发布）

- 固定菜单命令、新建窗口/标签、分屏和焦点/缩放、字体大小、复制粘贴、只读、搜索、重置和 Inspector 统一经过现有 `Ghostty.Surface`。新增内部固定命令、字体和滚动入口，直接调用 Zig 类型化绑定动作；用户 keybinding、AppleScript、App Intent 和配置命令面板保留动态入口。
- 键盘、鼠标、压力、预编辑、焦点、可见性、尺寸、缩放、显示器和主题状态均经资源桥接。键盘/鼠标消费 Bool 保留；键码不经枚举转换丢弃未知值，提交文本保留合成键码 0。文本读取在桥接中复制并成对释放，Quick Look 字体引用也在桥接内管理。SurfaceView 改为接收 App，删除旧裸 App 初始化及裸 Surface 属性。
- `Ghostty.App` 保持资源创建/释放、tick、配置和 Surface 创建职责；反向 C 回调集中到 `Ghostty.App+Callbacks.swift`。请求载荷同步复制，异步唤醒保持弱持有。`Surface.ClipboardReadRequest` 在调用核心前清空请求指针，重复完成/拒绝无效；窗口销毁仍由确认请求显式取消。
- Helpers 中剪贴板/颜色/快速终端尺寸转换及 Inspector、鼠标样式、标签目标和渲染健康通知也迁入桥接。业务、界面、Helpers、AppDelegate 不再导入 GhosttyKit。新增 `scripts/check-bridge.py` 并接入平台范围检查：**124 个原生文件通过**；内部 Ghostty 适配文件和 `App/main.swift` 启动入口为明确边界。
- 全量原生测试：**254 项通过、1 项基准测试跳过、0 失败**，`runtimeWarnings` 为空。结果：`/private/tmp/cghostty-bridge-native-final.xcresult`；摘要：`/private/tmp/cghostty-bridge-native-summary.json`。新增 5 项测试覆盖未知键码/中文提交载荷、复制文本跨核心变更与释放、预编辑与连续重复键经 PTY、无效字体增量/固定命令，以及真实 OSC 52 剪贴板请求在视图销毁时取消并释放资源。
- 初次专项输入测试依赖 `NSApp.currentEvent`，无事件时 AppKit 按既有契约忽略提交；修正测试为通过实际桥接入口提交合成键码 0 后，全量通过。此项验证桥接和 PTY，不等同于所有系统输入法的人工验收。
- 核心嵌入接口与绑定回归：**158/158**，**85/85 构建步骤**，日志 `/private/tmp/cghostty-bridge-core.log`。
- 真实桌面：窗口/标签/搜索/分屏/命令面板及焦点 **2/2**；标签栏布局、分屏缩放、全屏及跨窗口标签流程 **5/5**，均无运行时警告。结果：`/private/tmp/cghostty-bridge-ui.xcresult`、`/private/tmp/cghostty-bridge-tabs.xcresult`。最后 Helpers 适配文件抽取后重新编译并运行标签套件通过。
- SwiftLint 严格检查、Zig 格式、Swift 6 配置、依赖版本、平台范围和 diff 空白检查通过。结构和维护约定同步至 `ARCHITECTURE.md`、`UI_ARCHITECTURE.md`、`HACKING.md`。
- 代码留在本地工作区，版本仍为 **0.1.4**；本轮未提交、推送或发布，也未替换已安装应用。没有将桥接回归描述为新的光标动画性能或所有 Vim/输入法场景验收。

## 架构边界第一轮（2026-09-20，未发布）

- 新增 `ARCHITECTURE.md`，记录 App / Surface / 窗口的强弱引用、主线程 / IO / 渲染线程边界和释放顺序；更新原生 UI 与开发约定。
- `WindowRegistry` 由各 App 持有，使用弱键/弱值索引；分屏树变更同步归属。移除静态 Surface 索引和归属查询中的 AppKit 窗口扫描，保留普通窗口 `openControllers` 的强引用存活机制，以及快速终端的独立持有。原生命令、App Intent、AppleScript、命令面板和剪贴板确认均查询创建该 Surface 的 App 索引。
- 归属专项 **15/15** 通过，增加跨 App 隔离、目标先注册而源稍后注销、树恢复和释放检查。既有窗口保活、脱离 AppKit 后命令路由、跨窗口迁移与旧 owner 失效测试仍通过。结果：`/private/tmp/cghostty-registry-debug.xcresult`。
- 在现有 `Ghostty.Surface` 增加搜索、结束搜索、结果导航及退出状态接口；搜索使用三个内部 C 入口，直接调用现有 Zig 强类型动作。清空查询、关闭搜索和双向导航覆盖中文、换行、内含零字节；查询内存在同步调用内复制到搜索消息。专项套件 **16/16** 通过（参数化搜索包含三组输入）：`/private/tmp/cghostty-bridge.xcresult`。用户 keybinding 字符串和尚未迁移的其他原生命令继续保留。
- 配置快照试点为 `Ghostty.Config.window` 的六项值：横/纵位置、步进缩放、鼠标跟随焦点、最大化、标题字体。不可变值拥有复制后的字符串；重载/释放原句柄后旧快照仍有效。每个有效配置对象独立生成快照，局部 Surface 配置不会覆盖 App 快照。C 句柄仍由现有 Config 管理，Zig DerivedConfig 和线程消息保持原有所有权。
- 完整原生回归 **249 项通过、1 项现有 Benchmarks 示例跳过、0 失败**，`runtimeWarnings` 为空：`/private/tmp/cghostty-config-native-v3.xcresult`。初次 ReleaseLocal 测试因未启用 enable-testing 而停止，改为匹配 Debug 核心后通过；新局部配置测试首次未等待主队列应用通知，修正为等待实际队列交付后通过，没有增加固定延时。
- `FrameScheduler.zig` 仅提取现有纯调度策略，保留只绘制/更新后绘制、8ms 最小间隔、Kitty 绝对截止时间与可见性。新增空闲停帧、持续光标不饿死图片动画、过期截止时间和可见性回归。计时器、DisplayLink、时钟与锁仍由原对象管理。核心定向回归 **300/300**，构建步骤 **85/85**：`/private/tmp/cghostty-architecture-core.log`。
- 最终核心已重建并用于桌面测试。分屏/搜索/面板/标签会话 **2/2**、标签布局/全屏/跨窗口拖动/合并 **5/5**、分屏拖出 **1/1** 通过；补齐上一项按钮与隐藏搜索菜单的桥接后，搜索交互复验 **1/1** 通过。四份结果的 `runtimeWarnings` 均为空。结果：`/private/tmp/cghostty-architecture-ui.xcresult`、`/private/tmp/cghostty-architecture-tabs.xcresult`、`/private/tmp/cghostty-architecture-drag.xcresult`、`/private/tmp/cghostty-architecture-search-final.xcresult`。
- 严格 SwiftLint **180 个文件、0 问题**；最后两个搜索调用点再次检查通过。Zig 格式、Swift 6、版本记录、平台范围和 diff 空白检查通过。测试输出有系统 linkd 服务连接日志，未将其宣称为全系统零日志。
- 本轮是本地边界改造，不是完整配置桥生成、通用 MotionEngine、Surface 大拆分或新的发行版；版本号仍为 0.1.4，未替换已安装应用、未推送或发布。未把桌面特定流程等同于所有输入法、全部快速终端/多显示器恢复场景验收，也未声称性能提升。

## 0.1.4 方向光标与 Vim 连续搜索（2026-09-20）

- 追加回归覆盖新目标在旧目标后方、但仍在当前显示位置前方的情况：按实际显示位置判断领跑方向，计时仍采用本次逻辑输入距离。
- 从两个矩形端点的包络改为四角动画；按移动方向分配前后响应，横向、竖向与四个斜向均有对应的领跑角。前沿沿垂直移动方向展开后恢复，轴向最大约 15%；记录并限制既有展开量，避免持续输入时叠加膨胀。快速反向使用实际角点的凸轮廓，避免交叉四边形。
- Vim 搜索的 PTY 记录：100 次 `n`，每次均发送 DECTCEM 隐藏与显示光标。隐藏帧现在只停止绘制/刷新请求，保留运动状态；后端使用始终较慢的响应时间，不再因连续输入消耗完延迟而与前端合并。
- 光标专项 **10/10**；最终渲染器/配置回归 **296/296**。覆盖每 8/16/33ms 连续移动或循环搜索 500 次、八方向的前后关系、展开上限与恢复、打断位置连续、Vim 模式切换、1–4 像素细边保护，以及随机快速反向的凸轮廓。日志：`/private/tmp/cghostty-directional-cursor-tests.log`。
- 最终 ReleaseLocal 构建通过，版本 **0.1.4（4）**，编译无 warning/error；原生 MSL 4.1、macOS/arm64 范围、资源和签名检查通过。日志：`/private/tmp/cghostty-directional-build-final.log`、`/private/tmp/cghostty-directional-scope.log`。
- 独立 Bundle ID 的测试副本通过应用 CLI 指定临时 Vim 文件，以 16ms 定时输入路径完成 **1,200 次搜索跳转**；运行中截图观察到绿色光标拉伸，插入模式连续输入后仍显示细线光标。开启 `MTL_DEBUG_LAYER=1`，stderr 未报告 Metal 校验错误。计数：`/private/tmp/cghostty-directional-vim-search-result.txt`；日志：`/private/tmp/cghostty-directional-runtime-stdio.log`。
- 桌面观察是运行中截图和 Vim 定时输入；未将其宣称为物理键盘长按、所有帧的像素分析或所有 Vim/Neovim 配置的穷举验证。初次后台启动的副本没有终端窗口，界面读取超时；明确指定测试命令后可正常访问，采样未发现主线程阻塞。
- 本地 ZIP 完整性与 SHA-256 检查通过，使用 ad-hoc 签名、未做 Apple 公证。正式附件及远程 CI 状态以 v0.1.4 Release 为准；下面的 0.1.3 记录仍属于之前版本。

## 0.1.3 发布前生命周期复验（2026-09-20）

- 首次标签 CI 的原生测试在 `commandsFollowSurfaceOwnershipAfterMovingBetweenWindows` 附近发生 malloc 内存损坏，main 的同一提交测试通过。停止发布并检查释放路径：Swift `Surface` 只有 C 句柄，未持有所属 `App`；当临时控制器先释放 App、Surface 仍存活时，核心 `App.deinit` 会先清理其 Surface，之后 Swift 句柄再释放会访问失效对象。
- `Surface` 明确持有创建它的 `App`，同步及延迟到主线程的释放都保证 App 活到 `ghostty_surface_free` 之后。新增行为测试证明撤销外部 App 引用后终端仍保有核心，销毁终端后两者都能释放，不形成循环引用。
- 修正后的完整原生测试 **243 项通过、1 项跳过、0 项失败**；桌面交互 **2/2**、标签几何 **5/5** 通过，三份结果均无运行时警告。结果包：`/private/tmp/cghostty-013-native-lifetime.xcresult`、`/private/tmp/cghostty-013-ui-lifetime.xcresult`、`/private/tmp/cghostty-013-geometry-lifetime.xcresult`。
- 同一进程连续重复执行 PresentationStateTests **20 轮、260 次执行全部通过**，无跳过、失败或运行时警告。结果包：`/private/tmp/cghostty-013-lifetime-repeat.xcresult`；摘要：`/private/tmp/cghostty-013-lifetime-repeat-summary.json`。
- 最终 ReleaseLocal 重编译、macOS/arm64 资源及签名检查、ZIP 完整性检查通过。日志：`/private/tmp/cghostty-013-release-lifetime.log`、`/private/tmp/cghostty-013-scope-lifetime.log`；本地最终 ZIP SHA-256：`6ea0f73898da116c233d2a3f53628dadb5faf29ac45185383fabc727df22703e`。
- 下节为首次本地验证记录，测试数量、发行包校验值以本节最终复验及公开 Release 的校验文件为准。未将一次远程崩溃当作环境波动直接重试跳过。

## 0.1.3 原生标签栏布局重构与发布前验证（2026-09-20）

- `NativeTitlebarTabLayout` 统一持有定位原生标签附件的 8 条约束；调整窗口尺寸时复用，在附件转移、关闭、脱离窗口或工具栏临时零尺寸时解除，并恢复 AppKit 原有 autoresizing 行为。帧变化在主队列合并处理，不使用轮询或固定等待。
- 标签排序直接使用 `NSWindowTabGroup.insertWindow`，删除先拆组再重建的分支和临时 workaround，保留选中标签及焦点。原生标签行按添加按钮的实际尺寸稳定高度；独立窗口的分屏缩放按钮由工具栏布局，避免硬编码顶部间距造成标题和按钮错位。
- 首次扩展几何验证发现标签高度反馈变化和缩放按钮对齐问题；修正实现后，保留原有 1 像素容差重新验证通过，没有通过放宽断言掩盖问题。包含普通窗口、全屏、跨窗口拖动、三窗口合并，以及连续三轮左右排序后的会话状态。
- 最终完整原生测试 **242 项通过、1 项跳过、0 项失败**，参数化展开后 361 次执行通过；跳过的是现有 Benchmarks 示例。桌面交互 **2/2**、标签栏几何 **5/5** 通过；三份结果包的 `runtimeWarnings` 均为空，之前移动标签出现的 7 条布局警告没有重现。
- 结果包：`/private/tmp/cghostty-013-native.xcresult`、`/private/tmp/cghostty-013-ui.xcresult`、`/private/tmp/cghostty-013-geometry.xcresult`；对应 `-summary.json` 保存精确测试数量。仍不将这些流程等同于所有输入法和系统恢复场景的穷举验收。
- 最终严格 SwiftLint 检查 **178 个文件、0 个问题**；Zig 格式、依赖版本记录、Swift 6、源码范围、actionlint 和 diff 空白检查通过。核心和 IO 的清理验证见下节，本次布局改动没有改变 Zig 核心行为。
- 从新的目录完整构建 ReleaseLocal **成功，构建日志无 warning/error**。最终应用版本 `0.1.3`、构建号 `3`，最低 macOS `27.0`、主程序仅 arm64，资源和 ad-hoc 签名检查通过；本地 ZIP 完整性校验通过。
- 本地应用：`/private/tmp/cghostty-013-release/ReleaseLocal/cghostty.app`；本地验证包：`/private/tmp/cghostty-013-package/cghostty-0.1.3-macos-arm64.zip`。日志：`/private/tmp/cghostty-013-release.log`、`/private/tmp/cghostty-013-scope.log`、`/private/tmp/cghostty-013-swiftlint.log`。本地 ZIP SHA-256 为 `ffda01dcebd0ba67f06bc65589a9d7135749a8c0f1f5d040734a7315b449c8cf`；远程 CI 会重新构建，正式下载请以 Release 附带的校验文件为准。
- 版本记录、打包示例和发行说明同步为 0.1.3。发行继续使用 ad-hoc 签名，没有配置 Developer ID 或 Apple 公证；本次没有替换 `/Applications` 中的已安装应用。

## 无调用代码、IO、窗口命令与图标设施清理（2026-09-20）

- 删除无调用的 Swift 视图包装、调试视图树打印、字符串截断和旧图标辅助代码。终端 IO 直接使用 `Exec` 与其线程数据，删除只有 `exec` 一个分支的 backend 联合类型、转发方法及空的配置更新调用。
- 配置诊断统一读取；XDG 和 Application Support 的新旧文件选择共用一份实现。保留新文件优先、旧文件后备、两者不存在时返回新路径，以及延迟解析旧路径的语义。新增配置错误在有效重载后清空的行为测试。
- 内部窗口、标签、分屏、命令面板和全屏命令复用现有 Surface 所有权查找，直接调用控制器方法，删除 19 个通知名称及字典参数。保留焦点要求、配置继承、关闭确认和快速终端差异；关闭普通窗口不再广播给快速终端。
- 新增核心调用到所属控制器、脱离窗口的分屏操作、跨窗口移动后归属三个行为测试。测试夹具不使用宿主应用的全局撤销栈，避免临时核心结束后仍被撤销记录持有 Surface；排空主队列后再释放临时 App。
- 整套备用/自定义图标设施已移除：Swift 实现、Dock 插件目标和嵌入/签名步骤、五个配置字段、专属颜色列表 C 桥接、图层合成、专属测试，以及 36 个资源文件（5,592,453 字节）。没有新增长期维护的“旧图标不存在”检查。固定图标使用用户确认的暗银纹理、圆角与右上光照版本；文档图标引用同步到实际生成的 `cghostty.icns`。
- 核心相关验证 **1,361 项通过、1 项跳过**；最后的 IO 错误分支简化后，Command/termio 定向验证 **133/133 通过**。日志：`/private/tmp/cghostty-cleanup3-core-final.log`、`/private/tmp/cghostty-cleanup3-io-final.log`。
- 完整原生测试 **240 项通过、1 项跳过、0 项失败**；参数化展开后通过 359 次执行，运行时警告为 0。结果：`/private/tmp/cghostty-cleanup3-native-v4.xcresult`；摘要：`/private/tmp/cghostty-cleanup3-native-v4-summary.json`。
- 桌面测试 **2/2 通过、0 项跳过**：分屏、搜索、命令面板后的输入、标签切换/移动/关闭，以及独立窗口创建/关闭后保留原会话。结果：`/private/tmp/cghostty-cleanup3-ui.xcresult`。新增的标签移动流程记录 **7 条 AppKit 标签栏约束警告**，涉及原生标签栏临时零尺寸；功能断言通过。本轮未修改该布局实现，不能将桌面结果描述为零警告，也未据此宣称全部全屏、输入法与恢复场景均经过验收。
- 使用新的临时构建目录执行完整 ReleaseLocal 构建，随后对最终源码执行增量确认。最终构建日志无编译警告或错误，严格 SwiftLint 检查改动的 18 个 Swift 文件无问题。macOS/arm64、实际应用资源及签名检查通过；一次性检查产物的插件目录和 Info.plist，确认 Dock 插件不再嵌入。Swift 6 检查覆盖剩余 3 个 target 的 9 个配置，Xcode 工程无悬空对象引用。日志：`/private/tmp/cghostty-cleanup3-release-final.log`、`/private/tmp/cghostty-cleanup3-scope-final.log`。
- 验证应用：`/private/tmp/cghostty-cleanup3-release/ReleaseLocal/cghostty.app`；本地验证包：`/private/tmp/cghostty-cleanup3-package/cghostty-0.1.2-macos-arm64.zip`。沿用当前源码版本号和 ad-hoc 签名，本轮不代表新版本发布或已安装应用更新。

# 本地交付验证

日期：2026-09-20。环境：Apple Silicon macOS 27.0（26A428）、Zig 0.16.0、Xcode 27、Nushell 0.115.1、SwiftLint 0.65.1。

本轮将交付基线提高为 macOS 27+、arm64、Metal 4 命令 API 与 MSL 4.1。此记录替代此前 macOS 13 部署目标的验证记录。

## 0.1.2 发布与文稿权限排查（2026-09-20）

- 系统 TCC 日志确认：此前 Debug 应用从文稿目录下的构建产物运行时出现 DocumentsFolder 查询；已安装应用的请求来自用户终端命令 `ls` / `nvim`。用户确认正式版是在进入项目或执行命令后提示。没有修改系统权限、TCC 数据库或要求完全磁盘访问。
- `macos/build.nu --action test` 默认将应用、runner、DerivedData 放到带 checkout 标识的系统临时目录；可通过 `--build-dir` 覆盖。Xcode 启动目录改为用户主目录；UI 测试使用临时工作目录，测试计划使用空配置，涉及真实 Surface 的原生测试使用不加载个人启动文件的 shell。
- 新环境下首次原生测试暴露核心销毁期间唤醒回调强持有已销毁对象的崩溃。将排队 tick 改为弱持有 App，增加 `queuedWakeupDoesNotRetainApp` 验证排队回调不延长其寿命；之后完整测试通过。
- 最终原生测试 **249 项通过、1 项跳过、0 项失败**，参数化展开后 368 次执行通过，运行时警告为空：`/private/tmp/cghostty-012-native-final.xcresult`。
- 最终桌面测试 **2/2 项通过**，无运行时警告：`/private/tmp/cghostty-012-ui.xcresult`。覆盖标签切换、标题、分屏、搜索、命令面板及焦点恢复。
- 13:50 起至验证结束的 TCC 日志没有新的 `SystemPolicyDocumentsFolder` 记录：`/private/tmp/cghostty-012-tcc-final.log`。这证明本轮隔离测试没有触发该访问；不代表用户命令访问文稿文件可绕过系统权限。
- 首次远程 CI 在空依赖缓存下暴露 PCRE2 懒加载问题：封装尚未生成库就被根构建读取。改为显式必需依赖，保留上层按需加载；全新全局/本地缓存下绑定测试 3/3 通过，与 CI 相同的根构建命令也正常报告已删除选项无效，不再发生 artifact panic。日志：`/private/tmp/cghostty-012-pcre2-cold.log`、`/private/tmp/cghostty-012-root-cold.log`。
- 第二次远程测试进程崩溃在 Xcode `HarnessEventHandler.testCaseEnded` / `Test.id.getter`，并非断言失败；测试计划改为串行，避免共享 NSApp、窗口和系统剪贴板的用例并发执行。本地完整复验仍为 249 通过、1 跳过、0 失败，运行时警告为空：`/private/tmp/cghostty-012-native-serial.xcresult`。CI 另输出 xcresult JSON 摘要，保留失败诊断。
- 核心回归 **1,364 项通过、1 项跳过**，85/85 构建步骤通过；PCRE2 绑定 **3/3 项通过**。日志：`/private/tmp/cghostty-012-core-summary.log`、`/private/tmp/cghostty-012-pcre2.log`。
- SwiftLint 严格检查 188 文件、0 问题；Zig 格式、依赖版本记录、Swift 6 配置、actionlint 和 diff 空白检查通过。
- 图标使用 imagegen 为现有角色添加银色边框，规范为 1024 像素源画布，重新导出 1024/512/64 像素 macOS 图标并同步 Dock 插件。实际导出目视确认边框完整。
- ReleaseLocal 构建成功。发行包沿用 ad-hoc 签名，不代表 Developer ID 签名或 Apple 公证；未修改已安装应用。源码位置及项目目录不自动搬迁。

## SwiftUI / Observation / AppKit 职责收拢（2026-09-20）

- 共享 UI 状态统一到 Observation：应用、配置、终端窗口、Surface、搜索、标题栏、玻璃背景、安全输入和配置错误。SwiftUI 使用类型化环境及局部 State；当前 `macos/Sources` 不再使用 ObservableObject、Published、ObservedObject、StateObject 或 EnvironmentObject。
- 新增 `TerminalWindowState`、`Ghostty.SurfaceState` 和 `Ghostty.SearchState`，终端显示状态与 AppKit 对象分离。原生 SurfaceView 保持稳定身份并持有核心 Surface；窗口结构变更仍经过控制器同步所有权，不复制核心句柄或建立双向兼容状态。
- 删除 TerminalViewModel 协议、OSSurfaceView 中间类、SplitTree 通用 publisher 工具和旧状态订阅链。关于、配置错误和剪贴板确认窗口改为程序化 AppKit 窗口托管 SwiftUI，删除三个空壳 XIB 和未使用的 SettingsView 占位页面；保留实际承担原生窗口/菜单初始化的 XIB。
- 剪贴板请求继续使用明确的原生事件、身份核对和取消流程，避免 Observation 合并中间显示状态时丢失一次性完成语义。观察任务使用弱引用，并在切换目标或关闭时取消；短搜索仍保留原有防抖。
- 桌面验证定位并修复了原先依赖 SwiftUI 引用延长窗口控制器寿命的隐含持有关系：已加载的普通终端控制器由原生层持有，关闭时释放；快捷终端仍由 AppDelegate 持有。新增存活至关闭、关闭后释放的测试。
- 原生测试迁移前基线为 **236 项通过、1 项跳过、0 项失败**，结果包 `/private/tmp/cghostty-ui-baseline.xcresult`。
- 架构和维护约定写入 `UI_ARCHITECTURE.md`、`HACKING.md`。桌面测试改为构建脚本显式选择，不再因为缺少 Xcode IDE 环境变量而静默执行零项测试。测试期间遇到系统弹窗和输入法干扰，用户处理弹窗后继续验证；固定 shell 命令改为粘贴并恢复原剪贴板，避免输入法转换。

- 最终原生测试 **248 项通过、1 项跳过、0 项失败**；参数化展开后通过 367 次执行，`runtimeWarnings` 为空。相比基线新增 12 项有效测试，覆盖属性级观察、稳定 Surface/核心身份、控制器释放、原生窗口存活与关闭、标题切换、辅助窗口、剪贴板取消及搜索防抖。结果包：`/private/tmp/cghostty-ui-native-complete.xcresult`；摘要：`/private/tmp/cghostty-ui-native-complete-summary.json`。
- 移除临时诊断后的最终桌面验收 **2/2 项通过、0 项跳过**，运行时警告为空：实际 OSC 标题更新、分屏、搜索编辑与关闭、命令面板关闭后的输入，以及两个标签之间往返切换保留会话标题。结果包：`/private/tmp/cghostty-ui-desktop-complete.xcresult`；摘要：`/private/tmp/cghostty-ui-desktop-complete-summary.json`。这是特定流程的验收，未遍历全部输入法、全屏或系统恢复场景。
- 从空生成目录完整构建 ReleaseLocal 成功；范围检查确认 macOS/arm64、应用资源和 ad-hoc 签名有效。一次性核对包内三个已删除辅助 nib 均不存在，六个现用菜单/终端 nib 齐全；应用和 dSYM 的 arm64 UUID 一致。日志：`/private/tmp/cghostty-ui-release-complete.log`、`/private/tmp/cghostty-ui-app-check.log`。此前两条 Dear ImGui dSYM 警告没有重现；干净构建另有 DockTilePlugin 不依赖 AppIntents.framework 因而跳过元数据提取的 Xcode 提示。
- 严格 SwiftLint 检查 **188 个文件、0 个问题**，版本记录、Swift 6 配置、源码范围和 diff 空白检查通过。最终产物为 `macos/build/ReleaseLocal/cghostty.app`；本轮未修改已安装应用、未生成发行 ZIP、未推送远程或发布新版本。

## Dear ImGui dSYM 符号警告修复（2026-09-20）

- 根因：`pkg/dcimgui/ext.cpp` 与 `pkg/macos/text/ext.c` 均生成 `ext.o`，合并到内部静态库后形成同名成员。两个 ImGui 构造包装符号实际存在，但 `dsymutil` 通过归档成员名读取调试信息时定位到不含这些符号的对象。
- 将 ImGui 扩展更名为 `dcimgui_ext.cpp`，同步构建路径和注释。C++ 文件与更名前逐字节一致，没有改变接口、初始化行为或调试信息生成选项。
- Debug 内部框架 **194/194 步骤成功**；Debug 与 ReleaseLocal 原生应用均重新构建成功，两个完整构建日志均无 `warning:` 或 `error:`。日志：`/private/tmp/cghostty-imgui-dsym-debug.log`、`/private/tmp/cghostty-imgui-dsym-release.log`。
- 两种配置的静态库各有一个 `ext.o` 和一个 `dcimgui_ext.o`。`dwarfdump` 确认两个 ImGui 包装函数均具有有效代码地址、正确源码路径和行号；ReleaseLocal 的 `dsymutil --dump-debug-map` 无诊断输出。调试信息记录：`/private/tmp/cghostty-imgui-dsym-debug-dwarf.txt`、`/private/tmp/cghostty-imgui-dsym-release-dwarf.txt`。
- ReleaseLocal 的 arm64、资源和签名检查通过；Zig 格式、版本记录和 diff 空白检查通过。本次仅更名构建输入，未新增长期检查或重跑功能单元测试，未对外发布。下方旧记录中的两条 dSYM 警告为修复前历史结果。

## PCRE2 替换与 tmux 协议解析（2026-09-20）

- 先在 `/private/tmp/cghostty-regex-probe/` 中链接原 Oniguruma 6.9.10 与 PCRE2 10.48 做对照。现有 **90 个** URL/路径输入及 **5,010 个** Unicode、边界和确定性组合输入，逐次匹配的 UTF-8 字节范围全部一致；正式规则与已验证规则逐字节一致。
- 将无限长度美元数字后向断言与相邻的单词边界限制合并为固定长度字符排除；显式保留 Unicode 字母、全部标记、数字与连接标点集合，覆盖中文、组合音标、间距标记和包围标记。PCRE2 自身 Unicode 数据由旧库的 16 升为 17，对照范围不构成所有 Unicode 码点语义完全一致的保证。
- 链接渲染与点击定位统一使用 PCRE2；每次搜索独立上下文，限制匹配工作 100,000、深度 1,000、堆内存 8 MiB，排除无法映射到终端单元格的空匹配。复用上游 Zig 0.16 构建，静态链接 8 位库，关闭 JIT。
- tmux 的 8 处正则解析改为字段、前缀和十进制数字解析；保留数据/名称空格、CRLF 与空布局标志，非法或溢出 ID 被拒绝并可继续解析下一条消息。删除旧 RegexError 分支以及 tmux 对正则开关的依赖。
- 删除 `pkg/oniguruma` 的 **11 个文件**、全局初始化、构建依赖、系统库选项与功能门控。新 PCRE2 构建/封装/清单共 **145 行**，对照程序只留在临时目录，应用没有旧引擎回退。更新依赖版本表，并将 PCRE2 封装、StringMap 和 tmux 测试纳入 CI。
- 最终相关核心回归 **744/744 项通过**，85/85 构建步骤成功；PCRE2 封装 **3/3 项通过**。测试覆盖 Unicode 链接选区、多次匹配、空匹配、预算耗尽、非法 UTF-8、非法偏移和 tmux 畸形消息恢复。核心测试的沙盒日志包含系统 XPC 警告，测试命令退出码为 0。日志：`/private/tmp/cghostty-pcre2-regression-final.log`。
- Debug 内部框架 **194/194 构建步骤成功**；原生测试 **236 项通过、1 项跳过、0 项失败**，运行时警告为空。结果包：`/private/tmp/cghostty-pcre2-native-tests.xcresult`；摘要：`/private/tmp/cghostty-pcre2-native-summary.json`。
- ReleaseLocal 应用构建成功，arm64、资源及签名检查通过。一次性符号审计确认最终内部静态库和应用包含 PCRE2 编译/匹配符号，无 Oniguruma 符号。日志：`/private/tmp/cghostty-pcre2-release.log`、`/private/tmp/cghostty-pcre2-app-check.log`。构建仍有此前的两条 Dear ImGui dSYM 符号警告。
- Zig 格式、版本记录、Swift 6 配置、actionlint 和 diff 空白检查通过；依赖记录故障注入再次通过，包括 PCRE2 版本/归档地址不匹配拒绝。本轮未运行远程 CI、完整 Zig 全量测试或真实 tmux/鼠标交互验收，未发布新版本。

## CI 环境记录与依赖版本文档（2026-09-20）

- CI 新增环境报告，记录实际工具版本、SDK 构建号及选定的 runner 元数据；报告进入 Actions 摘要和既有诊断产物，工具安装失败时也尝试采集。
- C/C++ 依赖表由包清单生成，默认检查拒绝文档漂移；新增源码归档 URL 与包版本一致性、ImGui 与 Dear Bindings 版本匹配校验，保留既有生成头检查。Wuffs 记录提交快照，维护状态保留在文档正文。
- 临时副本故障注入通过：7 个依赖的包版本与归档 URL 不一致均被拒绝；ImGui 包版本、绑定目标版本、绑定发布标签与文件名不一致均被拒绝；表格过期、标记缺失及重复均被拒绝。默认检查不写文件，更新仅修改表格、保留人工正文，重复生成逐字节一致，Zig 安装脚本的版本/校验和输出不受文档漂移影响。
- 本机环境报告成功采集全部 14 项命令输出，保存于 `/private/tmp/cghostty-ci-environment.md`。空 PATH 模拟安装失败时仍输出完整报告，全部缺失工具标记为 `Unavailable`，未选中的环境变量不会被导出。SDK 查询在沙盒中附带 Xcode 缓存/文件监听警告，命令仍返回成功及实际版本。
- 版本检查、actionlint、Swift 6 配置检查、macOS/arm64 范围检查和 diff 空白检查通过。本轮仅修改 CI、脚本和维护文档，未重新构建应用、未运行远程 CI、未发布新版本。

## macOS 实现、键码表与彩蛋设施精简（2026-09-20）

- 删除无调用的 `locales_map`、`initGlobalDomain`、`staticLocale` 及专属 gettext 声明/导入；保留域绑定、翻译查询、语言规范化。全部 PO/POT 文件与本轮开始时逐字节相同；最终包内 34 个 `.mo` 的翻译内容逐一与当前 PO 编译结果一致。
- 收拢自有 Zig 代码中的固定 macOS 分支，包括系统工具、输入编码、配置、PTY、进程/线程、Metal 和终端页内存管理。保留构建入口的非 macOS/非 arm64 拒绝检查、配置条件中的系统信息、第三方通用实现及实际使用的字体后端。
- 删除单成员渲染器/运行时枚举和配置传递；直接使用 Metal，保留 CLI 无窗口运行时与原生应用 embedded runtime 的产物区分。Inspector 使用 Metal 初始化状态，保留初始化、重新初始化和关闭流程。内部 C 头文件保持逐字节一致。
- 键码原始表从六列收缩为 USB / macOS / DOM 三列，全部 **243 条**有效记录的值与顺序逐项一致。新增原生键码唯一性测试，保证核心测试也会实例化完整映射表。
- 删除 `+boo` 命令、帧数据模块、C 帧生成器和 235 个原始帧文件。移除 v2/v3 图标草稿、未引用的 `Prompt.svg` 及应用资源目录中未分配的旧 `cghostty.svg`；保留 v4 图标与设计源文件。旧 SVG 引发的 Xcode 资源警告已消除。
- 清理新增的无效平台回退和遗留导入后，当前工作区相对本轮起点删除 **251 个文件**；其中被删除的图标/帧资源共 **6,778,834 字节**。此数字是源码资源体积，不代表压缩后的应用或 Git 历史缩减量。
- 扩大 Zig 定向回归（OS、Command、config、renderer、input、termio、PTY、PageList、page、mem）：**1,162 项通过、1 项跳过**，83/83 构建步骤成功。最终键码/终端构建选项专项回归：**75/75 项通过**。日志：`/private/tmp/cghostty-cleanup2-core-tests.log`、`/private/tmp/cghostty-cleanup2-keycodes-tests.log`。
- Debug 内部框架构建成功；Swift 原生测试 **236 项通过、1 项跳过、0 项失败**，`runtimeWarnings` 为空。结果包：`/private/tmp/cghostty-cleanup2-native-tests.xcresult`；摘要：`/private/tmp/cghostty-cleanup2-native-summary.json`。
- 保留的可选手册和性能工具构建 **106/106 步骤通过**。日志：`/private/tmp/cghostty-cleanup2-maintenance-build.log`。
- ReleaseLocal 应用构建成功；应用身份、arm64、资源、签名检查通过，`+boo` 不出现在帮助中且调用返回无效命令。新旧应用 `+show-config --default` 与 `+list-keybinds --plain` 输出逐字节一致。日志：`/private/tmp/cghostty-cleanup2-release-final.log`、`/private/tmp/cghostty-cleanup2-app-check.log`。
- CI 增加 input / OS / termio / PTY 回归；范围检查保留 macOS/arm64、应用资源、签名以及图标素材和单成员后端文件的范围约束。彩蛋源码、资源和构建引用的删除由本次构建与测试验证，不再保留彩蛋专用的路径断言、帮助输出断言或命令拒绝检查。Zig 格式、修改 Swift 文件的严格 lint、版本记录、Swift 6 配置、actionlint 和 diff 空白检查通过。
- 构建中仍有此前就存在的两条 Dear ImGui dSYM 符号警告（`_ImFontConfig_ImFontConfig`、`_ImGuiStyle_ImGuiStyle`），不影响本轮构建及单元测试通过。本轮未运行完整 Zig 全量测试或手工 GUI/IME/Vim 验收；未更改线上 0.1.1 Release、标签或远程分支。

## 独立仓库旧代码与构建设施清理（2026-09-20）

- GitHub 仓库已由维护者解除 fork 关联；本轮读取 API 确认为 `fork: false`。本轮改动保留在本地工作区，没有修改线上 0.1.1 Release、标签或远程 main。
- 删除无调用的 Git 版本探测、单成员 XCFramework 目标枚举、转发型归档包装和空 `.gitmodules`。内部构建直接使用唯一 macOS arm64 目标，去掉静态库不可能产生的 dSYM、独立 pkg-config 字段和不再适用的跨平台空操作分支。保留当前 Zig/Xcode 必需的归档规范化、compiler-rt 和 libSystem 符号处理。
- 移除无调用的桌面环境探测、旧 macOS 版本查询及悬空的 OpenType 导出；简化桌面启动、pipe 和 URL 打开中的恒定平台分支。保留 `CGHOSTTY_MAC_LAUNCH_SOURCE` 行为以及 OSC 8 拒绝通用 opener 的策略，并将已有 hostname / opener 测试纳入 OS 模块测试入口。
- gettext 直接提取共享命令面板，移除 GTK/Python 中间模板和单输入二次合并，更新目录时清除 obsolete 条目。34 种语言共 5,440 条保留译文逐条一致，移除 2,404 条退役译文；包含模板的 PO/POT 源码从 1,252,074 字节减至 846,744 字节。译者署名保留。
- 翻译生成在独立临时副本中验证：最终流程 **71/71 步骤通过**，再次生成的 34 个目录及 POT 与工作区逐字节一致；全部目录通过 `msgfmt --check`。日志：`/private/tmp/cghostty-cleanup-i18n-final.log`、`/private/tmp/cghostty-cleanup-i18n-verify.log`。
- Zig 定向回归覆盖 OS、Command、config、renderer：**340/340 项通过，88/88 构建步骤通过**。日志：`/private/tmp/cghostty-cleanup-core-tests.log`。
- 重建 Debug 核心后，Swift 原生单元测试 **236 项通过、1 项跳过、0 项失败**，`runtimeWarnings` 为空。结果包：`/private/tmp/cghostty-cleanup-native-tests.xcresult`；日志：`/private/tmp/cghostty-cleanup-native-tests.log`。
- 最终 ReleaseLocal 完整重建成功，应用范围、arm64、资源、签名和 CLI 配置检查通过；包内 34 个 `.mo` 逐一解析后与当前 PO 编译结果相同。日志：`/private/tmp/cghostty-cleanup-release-final.log`、`/private/tmp/cghostty-cleanup-app-check.log`。
- Zig 全范围格式检查、版本检查、Swift 6 构建配置检查、actionlint 和 diff 空白检查通过。没有 Swift 源码修改；本轮未重复图形界面手工验收、未运行完整 Zig 测试全集或 XCTest UI 套件，未重新打包发行 ZIP。

## Swift 6 迁移（2026-09-20）

- 使用 Xcode 27 的 Apple Swift 6.4 编译器，将主应用、Dock 插件、单元测试、UI 测试的全部 **12 个构建配置**统一为 Swift 6 语言模式、完整并发检查与 Swift warnings-as-errors。主应用和单元测试默认 MainActor；UI 测试保留 XCTest 生命周期的非隔离声明，界面操作显式 MainActor。
- UI 定时器、通知/KVO、窗口加载和资源析构明确主线程归属；系统后台通知回调排入主队列。核心 `wakeup_cb` 明确为非隔离 Sendable 回调，后台唤醒后仍在主线程 tick。Cocoa scripting 的同步入口与返回值采用局部桥接和主线程运行时断言。
- App Intents 元数据改为不可变值；输入枚举、颜色与图标编码保持非隔离。终端详情用 Zip 同时订阅标题和路径，保留各自超时回退；拖放异步结果以 Mutex 保护。同步菜单测试移除无效 await 和旧字符串 selector；分屏参数化案例保留全部输入组合。
- 原生单元测试 **236 项通过、0 项失败、1 项跳过**；参数化展开后通过 **355 次执行**，结果包没有 runtime warnings。新增后台唤醒和后台图标编码两项回归。结果包：`macos/build/DerivedData/Logs/Test/Test-Ghostty-2026.09.20_08-21-08-+0800.xcresult`；成功日志：`/private/tmp/cghostty-swift6-test-compile.log`。UI 测试目标通过编译，本轮未执行 XCTest UI 测试套件。
- Debug 原生测试和 ReleaseLocal 完整构建通过，成功日志未发现 Swift 源码警告或错误。Xcode 仍有原有 ImGui 调试符号提示，以及不使用 AppIntents 的目标跳过元数据提取的提示；不将这些工具提示视作 Swift 源码诊断。Release 日志：`/private/tmp/cghostty-swift6-release.log`。
- 独立身份的 ReleaseLocal 副本完成真实运行检查：AppleScript 窗口/标签/终端对象引用、中文 shell 命令输入、键盘事件、鼠标位置/按钮/滚动事件、核心后台输出触发标题更新、新标签、分屏、关闭标签与释放分屏全部通过。使用独立命令行配置，测试副本已退出；Metal API Validation 启用，运行日志未出现隔离断言、崩溃或 Metal 错误。日志：`/private/tmp/cghostty-swift6-runtime-check.log` 和 `/private/tmp/cghostty-swift6-runtime3/app.log`。
- 严格 SwiftLint、版本检查、actionlint、diff 空白检查和应用范围/arm64/资源/签名检查通过。CI 新增 `scripts/check-swift6.py`；临时项目故障注入验证 Swift 5、minimal 并发检查、关闭 warnings-as-errors、取消默认 MainActor、关闭 Approachable Concurrency 均被拒绝。
- 最新本地应用为 `macos/build/ReleaseLocal/cghostty.app`。本轮未改 Zig/C 核心行为，未重复核心回归；下方 C 库记录中的核心测试属于此前验证。未远程运行 GitHub Actions，未重打历史 ZIP，未对外发布。

## C/C++ 依赖更新（2026-09-20）

- 更新 FreeType 2.14.3、libpng 1.6.58、zlib 1.3.2、Oniguruma 6.9.10、HarfBuzz 14.4.0、gettext/libintl 1.0、Highway 1.4.0、simdutf 9.2.0，以及 Dear ImGui 1.92.9b-docking / Dear Bindings 0.21。源码 URL、Zig 内容哈希、生成头文件和版本记录同步更新；来源与再生成方法见 `pkg/README.md`、`pkg/libintl/README.md`。
- simdutf 两个 vendor 文件直接取自官方 singleheader.zip；libpng 使用上游预生成配置。libintl 在 macOS 27 / arm64 重新配置，加入 gnulib 字符串头与 `string.c`，解决新版本 `streq` 的编译与 Debug 链接需求。Inspector 适配 `ImGui_OpenPopup` 的 bool 返回值。
- 默认 Zig 定向回归覆盖 renderer/config/Command/Terminal/font/simd/kitty/tmux/search：**1,645 / 1,645 项通过**，88 / 88 构建步骤成功。日志：`/private/tmp/cghostty-clibs-default-tests.log`。
- 可选 `coretext_freetype` 字体后端：**200 项通过、5 项跳过**；`coretext_harfbuzz`：**197 项通过、7 项跳过**。两者均 93 / 93 构建步骤成功。日志分别为 `/private/tmp/cghostty-clibs-freetype-tests.log` 和 `/private/tmp/cghostty-clibs-harfbuzz-tests.log`。
- 重建核心后，Swift 单元测试 **234 项通过、0 项失败、1 项跳过**；参数化展开后通过 355 次执行。结果包：`/private/tmp/cghostty-clibs-swift-tests.xcresult`。
- 临时 C 程序直接链接本轮 Debug 合并静态库，验证 zlib 压缩往返、libpng RGBA 编解码与截断输入拒绝、FreeType 字形光栅化、Oniguruma 中文匹配、gettext 中文目录查询、ImGui 绑定数据布局与上下文创建，全部通过。翻译测试显式设置 `LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8`。程序源码保存在 `/private/tmp/cghostty-clibs-smoke.c`。
- `check-versions.py` 新增 libpng 与 libintl 生成文件校验；临时副本故障注入确认 libpng 旧配置、libintl 旧配置和两个旧公开头均被拒绝。Zig 格式和 diff 空白检查通过。
- ReleaseLocal 完整构建及 `check-scope.py --app` 通过，更新后的应用位于 `macos/build/ReleaseLocal/cghostty.app`。日志：`/private/tmp/cghostty-clibs-release.log`。
- Wuffs 保留原有生成源码快照，未更换正则引擎；Oniguruma 原上游已归档，6.9.10 为其最终发布版本。本轮未重新生成历史 ZIP、未运行远程 CI 或界面交互验收、未对外发布。

## 兼容层、版本记录与 CI 整理（2026-09-20）

- 删除旧系统 Backport、Ventura 标签栏类和 XIB，以及 macOS 27 基线下恒定的系统版本/旧编译器分支。搜索框保留字符串选区与 `TextSelection` 的绑定转换，Glass 改用原生类型，现有标签切换修复继续保留。
- simdutf 包清单由 5.2.8 校正为内置源码的 9.0.0；未更换第三方源码。Zig 0.16.0 版本与归档 SHA-256 集中管理，安装脚本和 CI 读取同一记录。
- CI 加入 Zig 格式、严格 SwiftLint、版本记录和 actionlint 检查；Actions 固定提交 SHA，缓存键纳入 SDK 和工具链。失败时也尝试保存构建日志和 `.xcresult`，与发行包分开上传。
- Zig 核心重建通过；CI 合并过滤器命令覆盖 renderer/config/Command/Terminal，**760 / 760 项通过**，88 / 88 构建步骤成功。该次沙盒运行的标准错误包含系统 XPC 连接警告，命令退出码为 0。
- Swift 单元测试 **234 项通过、0 项失败、1 项跳过**；参数化展开后通过 355 次执行。首次沙盒构建受系统服务访问限制而失败，随后在沙盒外重跑通过；成功结果包为 `/private/tmp/cghostty-modernize-verified-tests.xcresult`。
- `zig fmt --check`、严格 SwiftLint、actionlint 1.7.12、脚本语法和 diff 空白检查通过。临时副本中的故障注入确认：Zig 版本不匹配、simdutf 记录不匹配、无效 SHA-256 均被拒绝；非测试动作使用 `--result-bundle` 也被拒绝。
- ReleaseLocal 完整构建及 `check-scope.py --app` 通过：arm64、身份、资源与签名均符合要求；实际应用资源中已无 Ventura nib，保留当前 Tahoe 标签栏 nib。
- 本轮更新了本地应用，未重新生成下方历史 ZIP；未远程运行 GitHub Actions，未进行界面交互验收或对外发布。

## 应用图标更新（2026-09-20）

- 采用圆润、立体的白色小幽灵：chevron 眨眼、薄荷绿吐舌微笑、挥手与小卷尾巴。最终原画及提示词保存在 `images/cghostty-icon-v4/`。
- 已同步 Icon Composer 文档和 Dock 插件使用的 AppIconImage。原方案文件保留，v2/v3 目录为历史设计稿。
- 验证 macOS 原生 1024px、512px、64px 图标导出；从实际构建的 `cghostty.icns` 解出图像检查新图标确实进入应用。
- ReleaseLocal 构建、应用范围/签名检查、ZIP 完整性和 SHA-256 检查通过。本轮仅更新图标资源，无运行时代码改动，未重复执行单元测试。

## Vim 光标修复追加验证（2026-09-20）

- 方块、细线和下划线光标均支持 smooth；细线按字符格宽度计时，非方块光标在文字之后绘制且不改写文字颜色。
- 连续移动按逻辑输入步长计时，尾端只消耗剩余延迟，避免重复等待与滞后距离造成的时长膨胀。单次移动的原时长和曲线保持不变，中断时两个端点位置连续。
- 定向 Zig 回归 **294 / 294** 通过；新增细线模式切换，以及每 8/16/33ms 连续移动 500 次的尾端进度与长度回归。
- ReleaseLocal 应用和原生 MSL 编译通过；应用范围、arm64、资源与签名检查通过。
- 使用独立 Bundle ID 的最新构建副本运行 macOS 自带 Vim 9.1，临时配置显式设置 normal 方块和 insert 细线。上下往返定时测试实际执行 1,726 步，观察未形成持续积累的多行长拖尾；insert 模式持续输入和返回 normal 模式通过界面检查。Metal API / GPU 校验未报告错误。
- 本轮只修改 Zig/MSL 及文档，未重新运行 Swift 单元测试；下方 234 项 Swift 结果属于上一轮 Metal 4 迁移验证。

## Metal 4 迁移验证

- Zig 渲染器与配置回归：**292 / 292** 通过。包含原光标时长与距离分档、曲线单调性、中断时两个端点的位置连续、尾端收拢、尺寸变化重置，以及旧 GLSL 配置的迁移诊断。
- Swift 单元测试：**234 项通过、0 项失败、1 项跳过**（xcresult 汇总；参数化用例有多次执行）。跳过项是原有默认禁用的手动基准。原生应用测试使用 Debug 配置。
- 原生 MSL 4.1 着色器编译、Debug 核心与 Swift 应用编译通过。
- macOS 27 上以 `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` 启动 ReleaseLocal 应用，确认 Metal API 与 GPU 校验启用。
- 最终 ReleaseLocal 独立进程正常读取迁移后的个人配置并启动 shell/display link；进程采样确认调用 `IOGPUMetal4CommandBuffer` / `MTL4CommandAllocator` 路径，主线程正常等待 AppKit 事件。
- 将最终 ReleaseLocal 复制为独立 Bundle ID 的验收副本（仅重新签名，编译 UUID 相同），避免同路径旧进程干扰；解锁后完成连续改向、中文/彩色文字、光标形状回退、字体缩放、分屏与拖动分屏大小的界面验收，对应进程未出现 Metal API/GPU 校验错误或 GPU 提交错误。
- 源码范围检查通过；Xcode 的应用、项目、测试与插件目标统一为 macOS 27，入口拒绝其他平台、Intel Mac 和已移除产物选项。
- 修改的 Swift 文件通过严格 SwiftLint，Zig 格式和 diff 空白检查通过。
- 本机 cghostty 配置迁移到 `cursor-effect = smooth`，删除两个旧 GLSL 配置项；迁移前备份为 `config.ghostty.pre-native-cursor-20260920`。原 Ghostty 配置与参考 GLSL 文件未改动。

- 最终 ReleaseLocal 完整构建、应用范围/架构/资源/签名检查、个人配置校验、ZIP 完整性与 SHA-256 校验通过。交付包约 20 MiB。

## 产物

- `macos/build/ReleaseLocal/cghostty.app`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip`
- `artifacts/cghostty-0.1.0-dev-macos-arm64.zip.sha256`

产物和本地构建缓存被 Git 忽略。ZIP SHA-256：`67ed2f8cbd0be778e13db5037d8720ef28a7a16d2c4860a8d0679c2fedb52698`。

## 验证边界

未运行完整 Zig 测试全集或 macOS UI 自动测试；本轮使用上述定向回归、运行检查与原生界面验收。界面检查使用独立身份的最终构建副本，避免同路径旧实例影响窗口定位；不将早先实例不明确的观察计入最终结果。未测量功耗、端到端输入延迟或实际帧率，不声称固定 120 Hz。

运动中断保证两个端点的位置连续，新一段继续使用原曲线；不保证中断时速度连续。特效目前仅为内置 smooth 光标，不加载外部 GLSL/MSL，不包含 CRT。系统 Reduce Motion 在渲染时关闭特效，但本轮未修改用户的系统辅助功能设置进行手工验收。

首次窗口建立 display link 曾暂时回退，随后成功建立 display link。发布构建的 ImGui 调试符号告警不影响构建结果。应用使用 ad-hoc 签名；没有执行 Developer ID 公证或对外发布。GitHub `xcode-27` 工作流已更新但未远程运行。未创建 PR、Issue 或 Git commit。
