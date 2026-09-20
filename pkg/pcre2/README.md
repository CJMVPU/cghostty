# PCRE2

包清单锁定源码版本、官方发布归档和 Zig 内容哈希。构建直接使用上游 `build.zig`，仅将 `pcre2-8` 链接进应用内部桥接库；JIT 关闭，不引入可执行内存或 JIT 签名要求。

`main.zig` 只封装当前链接识别所需的编译、释放和完整匹配字节范围。使用 UTF-8、Unicode 属性、行锚点与默认非捕获分组；空匹配无法对应终端单元格，因此搜索统一排除空匹配。

每次搜索独立创建匹配数据及上下文，渲染与点击定位共用以下预算：

- 匹配工作上限：100,000。
- 匹配深度上限：1,000。
- 堆内存上限：8 MiB。

这些是引擎工作计数和内存限制，不是墙钟超时；达到预算时停止本次链接扫描。模式对象可供不同搜索使用，可变上下文不在调用间共享。

链接规则位于 `src/config/url.zig`，显式包含 Unicode 字母、全部标记、数字与连接标点。升级时检查 Unicode 数据变化、UTF-8 字节偏移、路径标点边界、空匹配和资源限制错误。PCRE2 10.48 使用 Unicode 17 数据。

从仓库根目录运行：

```sh
(cd pkg/pcre2 && zig build test)
zig build test -Dtest-filter='url regex' -Dtest-filter=StringMap -Dtest-filter=renderCellMap -Dtest-filter=tmux
python3 scripts/check-versions.py
```

来源：[PCRE2](https://github.com/PCRE2Project/pcre2)、[支持周期](https://github.com/PCRE2Project/pcre2/blob/main/SUPPORT-LIFECYCLE.md)、[许可证](https://github.com/PCRE2Project/pcre2/blob/pcre2-10.48/LICENCE.md)。
