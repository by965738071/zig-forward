const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket = b.dependency("websocket", .{});

    // ── 传输层（依赖 Io + websocket，定义 AClient/CSender 接口及 TCP/WS 实现）──
    const transport_mod = b.addModule("transport", .{
        .root_source_file = b.path("src/transport/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = websocket.module("websocket") },
        },
    });

    const parser_mod = b.addModule("parser", .{
        .root_source_file = b.path("src/parser/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── 配置/状态层（依赖 transport 拿 AClient/CSender，依赖 parser 拿 Frame/Id）──
    const app_config_mod = b.addModule("app_config", .{
        .root_source_file = b.path("src/config/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "parser", .module = parser_mod },
        },
    });

    // ── 业务 handler 实现（依赖 app_config 拿类型签名）──
    const handlers_mod = b.addModule("handlers", .{
        .root_source_file = b.path("src/handlers/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_config", .module = app_config_mod },
        },
    });

    const pc_server_mod = b.addModule("pc_server", .{
        .root_source_file = b.path("src/pc/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_config", .module = app_config_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "parser", .module = parser_mod },
        },
    });

    const hw_server = b.addModule("hw_server", .{
        .root_source_file = b.path("src/hw/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_config", .module = app_config_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "parser", .module = parser_mod },
        },
    });

    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_config", .module = app_config_mod },
        },
    });

    const ws_server_mod = b.addModule("ws_server", .{
        .root_source_file = b.path("src/ws/ws_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_config", .module = app_config_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "websocket", .module = websocket.module("websocket") },
        },
    });

    // 应用组装模块（src/app.zig）：持有三个服务器，负责编排启动/停止。
    const app_mod = b.addModule("app", .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_config", .module = app_config_mod },
            .{ .name = "pc_server", .module = pc_server_mod },
            .{ .name = "hw_server", .module = hw_server },
            .{ .name = "parser", .module = parser_mod },
            .{ .name = "util", .module = util_mod },
            .{ .name = "ws_server", .module = ws_server_mod },
            .{ .name = "websocket", .module = websocket.module("websocket") },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "handlers", .module = handlers_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig_forward",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "app", .module = app_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // ── 单元测试（zig build test）──
    // 测试根使用独立模块 src/tests.zig（无 main），通过相对路径 @import 引用
    // 所有带测试的源码文件。Zig 的测试收集规则：若 root 模块声明了 `pub fn main`，
    // 通过 main 可达的依赖模块测试不会被收集；独立测试根可确保全部测试真正运行。
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // integration_test.zig 的单元测试依赖命名模块（app_config/pc_server/parser），
    // 无法通过相对路径收集，单独作为测试模块注入命名依赖。
    const integ_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app_config", .module = app_config_mod },
                .{ .name = "pc_server", .module = pc_server_mod },
                .{ .name = "parser", .module = parser_mod },
            },
        }),
    });
    const run_integ_unit_tests = b.addRunArtifact(integ_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integ_unit_tests.step);

    // ── Integration test executable (zig build integ) ──
    const integ_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/test/integration_test_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
            .{ .name = "app_config", .module = app_config_mod },
            .{ .name = "pc_server", .module = pc_server_mod },
            .{ .name = "hw_server", .module = hw_server },
            .{ .name = "parser", .module = parser_mod },
        },
    });

    const integ_exe = b.addExecutable(.{
        .name = "integ_test",
        .root_module = integ_exe_mod,
    });
    const integ_step = b.step("integ", "Run integration test (requires server)");
    const integ_cmd = b.addRunArtifact(integ_exe);
    integ_step.dependOn(&integ_cmd.step);

    // ── Benchmark executable (zig build bench) ──
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/test/benchmark_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("app", app_mod);
    bench_mod.addImport("app_config", app_config_mod);
    bench_mod.addImport("pc_server", pc_server_mod);
    bench_mod.addImport("hw_server", hw_server);
    bench_mod.addImport("parser", parser_mod);
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });
    const bench_step = b.step("bench", "Run benchmark");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
}
