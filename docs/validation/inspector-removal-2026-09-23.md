> 历史验证记录：描述当时实现，当前状态见 [验证入口](../../VALIDATION.md)。外置文楷方案已由内嵌方案替代。

# Inspector 完整移除与验证（2026-09-23）

## 实现范围

- 删除 Zig Inspector 子系统、Swift 面板、InspectableSurface 包装层及专用 Metal 绘制流程。终端叶节点直接使用 SurfaceWrapper。
- 删除主菜单、右键菜单、命令面板入口、默认 ⌘⌥I 快捷键，以及 `inspector:toggle/show/hide` 配置动作。
- 删除 Inspector / RenderInspector / ExportTerminalIO 动作、C 类型与导出函数、Swift 桥接和可观察状态。
- 删除按键、鼠标和 PTY 数据的 Inspector 采集路径、线程通知及标志。PTY 数据继续通过原有批量解析路径处理。
- 删除 Inspector 专用的超链接/语义提示符诊断覆盖层及图片上传分支。正常链接、shell 集成、选择、搜索、窗口尺寸提示和 Kitty 图片渲染保留。
- 删除 Dear ImGui / Dear Bindings（dcimgui）、FreeType、libpng、独立 zlib 包和构建接入；同步清理版本检查和依赖说明。
- PNG 解码继续由 Wuffs 提供；Kitty 图片 zlib 解压继续使用 Zig 标准库。终端字体继续使用 CoreText。
- 保留常规 Zig / Swift 日志、通用终端解析接口和非 Inspector 自动化测试；增加旧 Inspector 动作必须被拒绝的回归测试。
- 从原生命令目录移除 Inspector 标题和说明，支持的语言不变，现为 170 个源字符串及 510 条译文。

## 配置兼容

用户配置只有包含 Inspector 动作的快捷键或自定义命令项需要删除；旧动作会明确报 InvalidAction。主题、字体和其他配置无需因本次移除而更改。

本地默认用户配置检查未发现活动的 Inspector 配置或额外配置文件引用；新构建的 `+validate-config` 验证该文件通过，没有修改个人配置。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| 核心回归（renderer、config、Command、Terminal、input、os、termio、pty、StringMap、tmux、font、Session、search、Kitty） | 1,881 通过、1 跳过；73/73 构建步骤成功，退出码 0 |
| 原生单元测试 | 313 项、37 组通过 |
| 现有桌面生命周期测试 | 2 项通过；关闭标签页/分屏后撤销，原 shell 会话仍保留 |
| ReleaseLocal 应用 | 构建通过，macOS arm64 目标、资源、身份和签名检查通过 |
| 符号检查 | 无 Inspector C 导出、ImGui/ImFont、FreeType 初始化或 libpng 创建读结构入口 |
| CLI | 动作列表和默认绑定不含 Inspector；旧 Inspector 绑定报告 InvalidAction |
| 本地化 | en、zh-Hans、zh-Hant、ja 资源各 170 条，均无 Inspector 条目 |
| 质量检查 | Zig 格式、SwiftLint（213 文件零违规）、Swift 6 配置、actionlint、版本记录、本地化覆盖、7 项 Python 测试与 diff 检查通过 |

最初核心测试因执行沙箱阻止 Metal 工具缓存写入而未完成；改用正常本地构建权限后通过上述回归。

ReleaseLocal 可执行文件从 17,725,104 字节降至 15,536,832 字节，减少 2,188,272 字节，约 12.3%。
删除已不被依赖清单引用的五份本地下载副本，释放约 111.8 MiB。
常规系统框架以及其他模块需要的 C/C++ 依赖继续保留。

版本保持 0.2.1；本次没有提交、安装、打标签或发布。
