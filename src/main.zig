const std = @import("std");
const Io = std.Io;
pub const model = @import("model/root.zig");
pub const config = @import("config/root.zig");

const GlobalState = config.state.GlobalState;
const PcServer = model.pc.pc_server.PcServer;
const HardwareServer = model.hardware.hardware_server.HardwareServer;

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

    const pc_port: u16 = 9000;
    const hw_port: u16 = 9001;

    std.log.info("Zig Forward starting — PC:{d}  Hardware:{d}", .{ pc_port, hw_port });

    // ── PC server thread ──
    const pc_thread = try std.Thread.spawn(.{}, struct {
        fn run(alloc: std.mem.Allocator, st: *GlobalState, i: Io, host: []const u8, port: u16) void {
            var server = PcServer.init(alloc, st, i, host, port);
            server.start() catch |err| {
                std.log.err("PC server exited: {}", .{err});
            };
        }
    }.run, .{ allocator, &state, io, "0.0.0.0", pc_port });

    // ── Hardware server thread ──
    const hw_thread = try std.Thread.spawn(.{}, struct {
        fn run(alloc: std.mem.Allocator, st: *GlobalState, i: Io, host: []const u8, port: u16) void {
            var server = HardwareServer.init(alloc, st, i, host, port);
            server.start() catch |err| {
                std.log.err("Hardware server exited: {}", .{err});
            };
        }
    }.run, .{ allocator, &state, io, "0.0.0.0", hw_port });

    pc_thread.join();
    hw_thread.join();
}

test {
    _ = config.util;
    _ = config.custom_codec;
    _ = config.state;
    _ = config.handler_registry;
    _ = config.frame_decoder;
    _ = model.pc.common_request;
    _ = model.pc.pc_server;
    _ = model.hardware.hardware_server;
    _ = model.hardware.common_response;
}
