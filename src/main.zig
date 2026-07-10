const std = @import("std");
const Io = std.Io;

const GlobalState = @import("config").state.GlobalState;
const PcServer = @import("pc_server").pc_server.PcServer;
const HwServer = @import("hw_server").hw_server.HwServer;
const JsonLineParser = @import("parser").json_parser.JsonLineParser;
const ByteParser = @import("parser").byte_parser.ByteParser;
const cfg = @import("config");
const ConfigType = cfg.ConfigType;
const config: ConfigType = .{};

pub fn main(init: std.process.Init) !void {
    _ = init;
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = debug_allocator.allocator();

    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.log.err("Debug allocator deinit error", .{});
        }
    }

    // ── Global state ──
    var state = GlobalState.init(allocator);
    defer state.deinit();

    // ── Single Io backend for the entire application ──
    var backend = Io.Threaded.init(allocator, .{});
    const io = backend.io();

    std.log.info("Zig Forward starting — PC:{d}  HW:{d}", .{ config.pc.port, config.hw.port });

    // ── PC server ──
    var pc_server = PcServer([]const u8, JsonLineParser([]const u8))
        .init(allocator, &state, io, config);
    defer pc_server.deinit();

    for (config.commands) |cmd| {
        pc_server.registerCommand(cmd.name, cmd.handler) catch {};
    }

    // ── HW server ──
    var hw_server = HwServer(u8, ByteParser()).init(allocator, &state, io, config.hw.host, config.hw.port);
    defer hw_server.deinit();

    // 并发运行两个 server，async 返回 Future，await 阻塞直到完成
    var pc_future = Io.async(io, runPcServer, .{&pc_server});
    var hw_future = Io.async(io, runHwServer, .{&hw_server});

    // 阻塞等待（两个 server 都是死循环，相当于永远等待）
    pc_future.await(io);
    hw_future.await(io);
}

/// 并发运行 PC server（由 Io.async 调度）
fn runPcServer(pc_server: *PcServer([]const u8, JsonLineParser([]const u8))) void {
    pc_server.start() catch |err| {
        std.log.err("PC server exited: {}", .{err});
    };
}

/// 并发运行 HW server（由 Io.async 调度）
fn runHwServer(hw_server: *HwServer(u8, ByteParser())) void {
    hw_server.start() catch |err| {
        std.log.err("HW server exited: {}", .{err});
    };
}

test {
    _ = cfg.util;
    _ = cfg.state;
    _ = cfg.handler_registry;
}
