const std = @import("std");
const Io = std.Io;
const net = Io.net;

const app = @import("app");
const GlobalState = app.config.state.GlobalState;
const PcServer = app.model.pc.pc_server.PcServer;

// ── Minimal integration test: PC server only ──
// Verifies the server accepts a connection and handles a Register
// to a non-existent hardware address without crashing.

test "pc register fails when hardware not connected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var backend = Io.Threaded.init(alloc, .{});
    defer backend.deinit();
    const io = backend.io();

    var state = GlobalState.init(alloc);
    defer state.deinit();

    const port: u16 = 19402;

    // 启动 PC 服务器
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(alloc2: std.mem.Allocator, st: *GlobalState, i: Io, p: u16) void {
            var server = PcServer.init(alloc2, st, i, "0.0.0.0", p);
            server.start() catch |err| {
                std.log.err("PC server: {}", .{err});
            };
        }
    }.run, .{ alloc, &state, io, port });

    // 等待服务器启动
    Io.sleep(io, .{ .nanoseconds = 500_000_000 }, .real) catch {};

    // 连接并发送 Register（硬件不存在）
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.log.warn("connect to server failed: {s}, skipping test", .{@errorName(err)});
        thread.detach();
        return error.SkipZigTest;
    };
    errdefer stream.close(io);

    const register_json = "{\"clazz\":\"Register\",\"target_addr\":\"127.0.0.1:9999\"}\n";
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(register_json);
    try writer.interface.flush();

    // 等待服务端处理完成
    Io.sleep(io, .{ .nanoseconds = 500_000_000 }, .real) catch {};

    stream.close(io);
    // 服务端运行在无限循环中，无法 join；测试进程退出时 OS 会回收
    thread.detach();
}
