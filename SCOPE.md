# 交付范围

唯一应用目标：macOS 27+、Apple Silicon arm64。构建入口对 Intel macOS、Linux、Windows、iOS、WASM 等目标明确报错。Xcode 工程及内部 XCFramework 不生成 Universal / x86_64 切片。

已移除的项目责任：

- GTK / GObject / Wayland / X11 应用运行时，Linux / Windows 系统适配、容器环境处理及相关平台测试。
- GLSL / Shadertoy 文件加载、glslang / SPIRV-Cross 转换依赖及其测试；以原生 MSL 平滑光标替代，暂不提供 CRT。
- OpenGL / WebGL / Canvas 渲染和字体后端，WASM 浏览器入口与分配器，iOS 视图桥接。
- 独立 libghostty-vt 的构建、C API 头文件和导出实现、WASM 库、示例、模糊测试包及独立 CMake / pkg-config SDK 安装入口。
- Flatpak、Snap、Nix 和 Linux 发行版打包；上游 Docker 构建、源代码发行包和网站数据生成流程。
- `+boo` 动画彩蛋、帧数据生成器及原始帧；v2/v3 图标草稿和未引用的图标素材。
- 运行时备用/自定义图标、图层合成与配色配置、Dock 图标插件；应用统一使用固定 cghostty 图标。
- 上游社区 issue/PR 模板、人员/赞助/机器人工作流、上游发布工作流、Sparkle 更新与 Sentry 上传。

保留的内容：

- Zig 终端核心及其测试；Swift 原生应用和测试；Metal 4 命令体系、MSL 4.1、CoreText、字体解析、Unicode、图片、主题及 shell 集成。
- 应用需要的 `include/ghostty.h` 和 `GhosttyKit.xcframework`，作为内部桥接而非对外库产品。
- 帮助、终端描述、命令补全、主题、gettext 资源以及可选手册/性能工具生成。这些直接用于应用或维护核心，不属于网站流程。
- `TERM=xterm-ghostty` 和必要的协议/接口名称；现有配置字段名及 `config.ghostty` 文件格式，配置目录使用 cghostty。
- 第三方依赖内的通用实现、协议中描述远端系统的内容、历史问题链接和版权归属。第三方源码能支持其他架构，并不意味着本项目会构建或交付这些目标。

独立发行目前采取 ZIP + SHA-256 + 草稿 Release；Developer ID、公证和公开发布需要使用本项目维护者自己的签名凭据与发布操作。
