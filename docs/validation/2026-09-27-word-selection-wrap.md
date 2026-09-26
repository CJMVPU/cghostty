# 选词与反向换行修复（2026-09-27）

## 来源与适配

根据提供的上游补丁移植逻辑与回归用例：

- [aa9ed7d：硬换行处停止选词](https://github.com/ghostty-org/ghostty/commit/aa9ed7d.patch)
- [69bf1ac8：宽字符选词](https://github.com/ghostty-org/ghostty/commit/69bf1ac8.patch)
- [2fe073a5：反向换行光标跳动](https://github.com/ghostty-org/ghostty/commit/2fe073a5.patch)

当前 Screen 实现已拆分，因此选词修复放入 `src/terminal/screen/selection.zig`，
回归用例放入 `src/terminal/tests/Screen/selection.zig`。光标修复保留在
`Terminal.cursorLeft`，对应测试放入 `tests/Terminal/operations.zig`。

补丁下载内容的 From 提交标识分别为 `c4f15c884a71387c837c9d6ae027f9f8ea8a8970`、
`a3e80a685ed672873aefe8bb07b8516ec3a4175a`、
`d4f45bee3fe5b7ad14f3aed41463578f109f91c7`；以上保留请求 URL 与返回标识，
便于追溯。此次采用内容适配，没有直接 cherry-pick。

## 行为

- `spacer_tail` 解析到左侧实际字；`spacer_head` 解析到下一行开头的宽字符。
- 向前跨行前检查离开的行是否软换行，避免从最后一列开始选词时越过硬换行。
- 清除待换行状态耗尽左移次数时立即返回，避免继续执行滚动边界处理。
- 默认边界增加 `，。；：！？、（）【】「」『』《》〈〉“”‘’` 及全角空格。
  自定义配置仍完全替换默认集合；不引入中文语义分词。

## 验证

先只加入上游回归用例，在旧实现上运行 `selectWord` 和 `cursorLeft` 过滤器：
91 项中 87 项通过、4 项失败，分别复现硬换行越界、软换行末尾越界、宽字符
选词不完整，以及恢复光标后 y 从预期 0 错误跳到 2。

应用修复后，增加中文、组合字符、全部新增标点、自定义边界及 CUB 默认计数、
退格入口的用例，使用固定 Zig 0.16.0 工具链运行：

```sh
python3 scripts/build.py test -Dtest-filter=selectWord -Dtest-filter=cursorLeft -Dtest-filter=SelectionWordChars -Dtest-filter=selectionString --summary all
```

结果：72/72 构建步骤成功，110/110 测试通过。测试遍历词中每个单元格，
检查选区端点及实际复制文本，覆盖正常宽字符尾格、软换行头占位格、硬换行、
单列屏幕、空格、混合字符和自定义宽字符分隔符。

Zig 格式、版本一致性及 Git 差异检查通过。版本保持 0.3.8／构建 28。
本轮验证范围为核心定向回归；未重新构建原生应用、执行真实鼠标双击 UI 测试
或生成发行包。
