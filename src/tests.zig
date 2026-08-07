const std = @import("std");

// ── 单元测试收集根（zig build test）─────────────────────
// 为什么需要这个文件？
//
// Zig 的测试收集规则：当 root 模块声明了 `pub fn main` 时，通过 main 函数
// 可达的依赖模块中的 `test` 块**不会被收集执行**（main 被视为程序入口）。
// 原 build.zig 使用 `exe.root_module`（即 src/main.zig，含 main）作为测试根，
// 导致 `zig build test` 实际运行 0 个测试——所有单元测试从未被执行过。
//
// 本文件是一个**无 main** 的独立测试根，通过相对路径 @import 直接引用所有
// 带测试的源码文件。测试收集器只能追踪到相对路径导入的文件中的测试块；
// 通过命名模块字段访问（如 `_ = app_config.util`）不会触发收集。
//
// 注意：parser/*.zig 均为纯 std 依赖，可用相对路径导入；
// src/test/integration_test.zig 依赖命名模块（app_config/pc_server/parser），
// 已在 build.zig 中单独作为测试模块注入命名依赖。
comptime {
    // src/parser/byte_parser.zig
    _ = @import("parser/byte_parser.zig");
    // src/parser/frame_reader.zig
    _ = @import("parser/frame_reader.zig");
    // src/parser/json_parser.zig
    _ = @import("parser/json_parser.zig");
}
