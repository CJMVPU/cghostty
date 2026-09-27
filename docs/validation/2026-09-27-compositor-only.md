# 唯一窗口合成器与无 IOSurface 截图

检查点 `c99f172b6` 已提交窗口帧时钟合并更新。本轮按用户确认移除旧实现，
窗口级合成器成为唯一呈现路径，不保留后端选择、旧实现或失败回退。

## 删除范围

- IOSurfaceLayer、主队列呈现队列和旧同步/异步图层 contents 提交。
- CVDisplayLink 封装、分屏显示器 ID 桥接、draw_now 唤醒和无 VSync 定时绘制路径。
- 每分屏 CAMetalDisplayLink、独立呈现 drawable、旧 NSRunLoop/libxev 桥接。
- render-presentation、window-vsync 配置、模板入口及旧后端对照测试。
- IOSurface 的 Swift 导入、Zig 封装与截图桥接；CoreVideo 封装及这两个框架的显式构建依赖。

历史验证报告和原始数据保留并标明历史状态；trace 汇总器仍可读取这些旧记录。
它们不是运行时后端。scope 检查防止已删除的文件、API 和配置入口被重新引入。
旧用户配置中的 render-presentation/window-vsync 应删除；不将它们作为兼容选择器或别名保留。

## 当前路径

每个窗口一个 CAMetalLayer、CAMetalDisplayLink、Metal 4 队列和呈现线程。
窗口回调先消费各分屏的待更新请求，再绘制缓存纹理并合成唯一 drawable。
只有窗口拥有 drawable 的等待、信号和 present 操作。核心只接受窗口提供的分屏目标纹理。
初始化失败会标记视图不健康并记录错误，不启用另一种呈现方式。

每分屏保留透明的结构性 CALayer 供 NSView 使用，不提交像素。
辅助线程仍处理消息、光标/Kitty 定时器与历史压缩；本轮不宣称已将所有线程合并。
窗口帧率由系统调度；render-frame-latency 仍接受 1 或 2，默认 1，重启生效。

## 截图路径

缩略图不依赖 IOSurface。核心按需创建独立的 shared MTLTexture，使用相同的分屏绘制逻辑
提交离屏画面，等 GPU 完成后返回持有的纹理对象。Swift 调用 getBytes 读回 BGRA 像素，
创建带 Display P3 色彩空间的 CGImage，然后将缩略图转换到 sRGB 并编码 PNG。

像素 Data 由 CGDataProvider 持有，图像不借用已释放的 Metal 内存；返回图像之后纹理可以释放。
截图不持有窗口 drawable、不增加显示修订号或发布光标显示历史。截图所需队列只用于离屏任务，
不是备用呈现后端。纹理资源由应用 residency set 管理；窗口 drawable 仍由 CAMetalLayer.residencySet 管理。

## 验证范围

- 三种混合模式和 1/2 帧延迟偏好下，共享帧时钟、最终合成颜色、缓存复用、分隔线移动和跨窗口移动。
- 缩略图的红/绿色彩及 alpha；半透明截图在终端会话销毁后仍可读取。
- 多次 Kitty 图片缩略图、之后继续绘制，以及同步输出边界。
- 光标闪烁、Kitty 动画的像素变化与恢复；200 轮 PTY 输出合并，穿插字号和搜索操作。
- 默认配置的原生生命周期、可见性、搜索、无障碍和其他现有回归。
- Zig 调度/缓存/会话/trace/同步输出定向测试；格式、严格 lint、scope 与本地应用构建。

实际输入到发光的延迟、多分屏长期能耗和外接显示器实机验收仍需另行测量。

## 结果

- 完整原生回归：358 个测试、47 个 suite 全部通过。
- 窗口参数化回归覆盖 3 种混合模式 × 2 种帧延迟偏好；缩略图色彩、透明度、关闭会话后的图像持有均通过。
- Zig 定向回归：99/99 通过，72/72 构建步骤成功。
- trace 汇总器：6/6 通过；SwiftLint strict（8 个改动文件）、Zig 格式与 Git 空白检查通过。
- 源码与构建配置检查未发现旧呈现 API、后端选择字段或 IOSurface/CoreVideo 显式依赖残留。
- 非测试版 ReleaseLocal 构建成功，arm64 架构、资源、签名和 scope 检查通过。
  `nm -u` 确认应用二进制没有导入 IOSurface 或 CVDisplayLink 符号。
  产物为 `macos/build/ReleaseLocal/cghostty.app`，未替换已安装版本。

PNG 色彩测试检查其声明的 sRGB 空间及解码后的通道值。避免通过 AppKit colorAt
再转换颜色时引入当前显示器的 device RGB profile；没有放宽原先的颜色阈值。

复现：

```sh
nu macos/build.nu --configuration ReleaseLocal --action test
python3 scripts/build.py test -Dtest-filter='config compositor' -Dtest-filter=FrameScheduler -Dtest-filter=FrameTiming -Dtest-filter=ScrollScene -Dtest-filter=CursorMotion -Dtest-filter=RenderSession -Dtest-filter=Trace -Dtest-filter=RenderHold --summary all
python3 scripts/check-scope.py --app macos/build/ReleaseLocal/cghostty.app
```

[本轮验证数据](2026-09-27-compositor-only.json)及[合并更新原始 trace](2026-09-27-compositor-only.csv)一并保存。
