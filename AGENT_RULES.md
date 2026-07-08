# Zig Forward — Agent 约束规则

## 编辑规则

1. **永远不要用 `write_file` 重写整个文件。** 只用 `edit_file` 做精准替换。
3. 在使用zig语言编程时，不确定 API 时先查标准库代码（在 `/opt/homebrew/Cellar/zig-dev/*/lib/zig/` 下），不要编造。
4. 不要删除用户文件。用户没让你删的，别碰。
5. 改动前先 `read_file` 确认当前内容。
6. 部署/集成相关的改动（如 build.zig）必须单独知会用户。
7. 不要主动提交代码，我让你提交的时候你才可以提交。

