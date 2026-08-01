const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pc_server_mod = b.createModule(.{
        .root_source_file = b.path("src/model/pc/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const hw_server = b.createModule(.{
        .root_source_file = b.path("src/model/hw/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const util_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig_forward",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "config", .module = config_mod },
                .{ .name = "pc_server", .module = pc_server_mod },
                .{ .name = "hw_server", .module = hw_server },
                .{ .name = "parser", .module = parser_mod },
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

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // ── Single "app" module covering all src/ files ──
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "pc_server", .module = pc_server_mod },
            .{ .name = "hw_server", .module = hw_server },
            .{ .name = "parser", .module = parser_mod },
            .{ .name = "util", .module = util_mod },
        },
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // ── Integration test executable (zig build integ) ──
    // Requires the server to be running (start with `zig build run`).
    const integ_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/test/integration_test_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
            .{ .name = "config", .module = config_mod },
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
    bench_mod.addImport("config", config_mod);
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
