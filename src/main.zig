const std = @import("std");
const Io = std.Io;

const cfg = @import("config");
// 暴露 config 模块（config/root.zig）给集成测试：测试通过 `@import("app").config.*` 访问它。
pub const config = cfg;

const GlobalState = cfg.state.GlobalState;
const PcServer = @import("pc_server").pc_server.PcServer;
const HwServer = @import("hw_server").hw_server.HwServer;
const ByteParser = @import("parser").byte_parser.ByteParser;
const JsonLineParser = @import("parser").json_parser.JsonLineParser;
const util = @import("util");

pub fn main(init: std.process.Init) !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = debug_allocator.allocator();

    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.log.err("Debug allocator deinit error", .{});
        }
    }

    // ── Parse CLI arguments ──
    const runtime_config = util.parseCliArgs(allocator, init.minimal.args) catch |err| {
        if (err == error.HelpRequested) return;
        return err;
    };

    // ── Global state ──
    var state = GlobalState.init(allocator);
    defer state.deinit();

    // ── Single Io backend for the entire application ──
    var backend = Io.Threaded.init(allocator, .{});
    const io = backend.io();

    std.log.info("Zig Forward starting — PC:{s}:{d}  HW:{s}:{d}", .{ runtime_config.pc.host, runtime_config.pc.port, runtime_config.hw.host, runtime_config.hw.port });

    // ── PC server ──
    var pc_server = PcServer(u8, ByteParser())
        .init(allocator, &state, io, runtime_config);
    defer pc_server.deinit();

    for (runtime_config.commands) |cmd| {
        try pc_server.registerCommand(cmd.id, cmd.handler);
    }

    // ── HW server ──
    var hw_server = HwServer([]const u8, JsonLineParser([]const u8)).init(allocator, &state, io, runtime_config.hw.host, runtime_config.hw.port);
    defer hw_server.deinit();

    for (runtime_config.hw_commands) |cmd| {
        try hw_server.registerCommand(cmd.name, cmd.handler);
    }
    if (runtime_config.hw_default_handler) |h| {
        hw_server.setDefault(h);
    }

    // 并发运行两个 server，async 返回 Future，await 阻塞直到完成
    var pc_future = Io.async(io, struct {
        fn run(pc: *PcServer(u8, ByteParser())) void {
            pc.start() catch |err| std.log.err("PC server exited: {}", .{err});
        }
    }.run, .{&pc_server});
    var hw_future = Io.async(io, struct {
        fn run(hw: *HwServer([]const u8, JsonLineParser([]const u8))) void {
            hw.start() catch |err| std.log.err("HW server exited: {}", .{err});
        }
    }.run, .{&hw_server});

    // 阻塞等待（两个 server 都是死循环，相当于永远等待）
    pc_future.await(io);
    hw_future.await(io);
}

