const std = @import("std");
const Io = std.Io;

const cfg = @import("config");
// 暴露 config 模块（config/root.zig）给集成测试：测试通过 `@import("app").config.*` 访问它。
pub const config = cfg;
const ConfigType = cfg.ConfigType;
// 全局配置实例（编译期默认常量）。
const app_config: ConfigType = .{};

const GlobalState = cfg.state.GlobalState;
const PcServer = @import("pc_server").pc_server.PcServer;
const HwServer = @import("hw_server").hw_server.HwServer;
const ByteParser = @import("parser").byte_parser.ByteParser;
const JsonLineParser = @import("parser").json_parser.JsonLineParser;

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
    var runtime_config = app_config;
    {
        var args_iter = std.process.Args.iterate(init.minimal.args);
        defer args_iter.deinit();
        _ = args_iter.next(); // skip program name
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--pc-port")) {
                runtime_config.pc.port = try std.fmt.parseInt(u16, args_iter.next() orelse return error.MissingArg, 10);
            } else if (std.mem.eql(u8, arg, "--hw-port")) {
                runtime_config.hw.port = try std.fmt.parseInt(u16, args_iter.next() orelse return error.MissingArg, 10);
            } else if (std.mem.eql(u8, arg, "--pc-host")) {
                runtime_config.pc.host = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
            } else if (std.mem.eql(u8, arg, "--hw-host")) {
                runtime_config.hw.host = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printHelp();
                return;
            } else {
                std.log.warn("Unknown argument: {s}", .{arg});
            }
        }
    }

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
        pc_server.registerCommand(cmd.id, cmd.handler) catch {};
    }

    // ── HW server ──
    var hw_server = HwServer([]const u8, JsonLineParser([]const u8)).init(allocator, &state, io, runtime_config.hw.host, runtime_config.hw.port);
    defer hw_server.deinit();

    for (runtime_config.hw_commands) |cmd| {
        hw_server.registerCommand(cmd.name, cmd.handler) catch {};
    }
    if (runtime_config.hw_default_handler) |h| {
        hw_server.setDefault(h);
    }

    // 并发运行两个 server，async 返回 Future，await 阻塞直到完成
    var pc_future = Io.async(io, runPcServer, .{&pc_server});
    var hw_future = Io.async(io, runHwServer, .{&hw_server});

    // 阻塞等待（两个 server 都是死循环，相当于永远等待）
    pc_future.await(io);
    hw_future.await(io);
}

/// Print help message and exit.
fn printHelp() void {
    std.debug.print(
        "Zig Forward — TCP message broker\n" ++
            "\n" ++
            "USAGE: zig_forward [OPTIONS]\n" ++
            "\n" ++
            "OPTIONS:\n" ++
            "  --pc-port <PORT>    PC server port (default: 9000)\n" ++
            "  --hw-port <PORT>    HW server port (default: 9001)\n" ++
            "  --pc-host <HOST>    PC server bind address (default: 0.0.0.0)\n" ++
            "  --hw-host <HOST>    HW server bind address (default: 0.0.0.0)\n" ++
            "  --help, -h          Show this help message\n",
        .{},
    );
}

/// 并发运行 PC server（由 Io.async 调度）
fn runPcServer(pc_server: *PcServer(u8, ByteParser())) void {
    pc_server.start() catch |err| {
        std.log.err("PC server exited: {}", .{err});
    };
}

/// 并发运行 HW server（由 Io.async 调度）
fn runHwServer(hw_server: *HwServer([]const u8, JsonLineParser([]const u8))) void {
    hw_server.start() catch |err| {
        std.log.err("HW server exited: {}", .{err});
    };
}

test {
    _ = cfg.util;
    _ = cfg.state;
    _ = cfg.handler_registry;
}
