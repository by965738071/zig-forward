const std = @import("std");
const Io = std.Io;
const net = Io.net;

const app = @import("app");
const custom_codec = app.config.custom_codec;
const utilReadLine = app.config.util.readLine;

/// Performance benchmark — connects to an ALREADY RUNNING server.
///
/// Prerequisites:
///   Run `zig build run` first (starts PC:9000 / HW:9001).
///
/// Topology:
///   HW1, HW2  → connect to 127.0.0.1:9001
///   PC1, PC2  → connect to 127.0.0.1:9000, register to HW1
///   PC3, PC4  → connect to 127.0.0.1:9000, register to HW2
///
/// Measurements (pipeline mode — send 1, read N responses, repeat):
///   A: Single-group broadcast throughput (HW1 → PC1+PC2, N=100/500/1000)
///   B: Two-group concurrent broadcast (HW1→PC1+PC2 + HW2→PC3+PC4, N=500)
///   C: Sustained throughput under continuous load (2s burst)
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var backend = Io.Threaded.init(alloc, .{});
    const io = backend.io();

    const pc_port: u16 = 9000;
    const hw_port: u16 = 9001;

    std.debug.print("\n═══ Zig Forward Benchmark ═══\n", .{});
    std.debug.print("  Server: PC:{d}  HW:{d}\n", .{ pc_port, hw_port });

    // ─────────────────────────────────────────────
    // Setup: connect 2 HW + 4 PC, register all
    // ─────────────────────────────────────────────
    var hw1 = try TcpClient.connect("127.0.0.1", hw_port, io);
    errdefer hw1.close(io);
    const ip1 = hw1.stream.socket.address.ip4;
    const hw1_addr = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}:{d}", .{ ip1.bytes[0], ip1.bytes[1], ip1.bytes[2], ip1.bytes[3], ip1.port });

    var hw2 = try TcpClient.connect("127.0.0.1", hw_port, io);
    errdefer hw2.close(io);
    const ip2 = hw2.stream.socket.address.ip4;
    const hw2_addr = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}:{d}", .{ ip2.bytes[0], ip2.bytes[1], ip2.bytes[2], ip2.bytes[3], ip2.port });
    const hw2_addr = try std.fmt.allocPrint(alloc, "{}", .{hw2.stream.socket.address});

    var pc1 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc1.close(io);
    var pc2 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc2.close(io);
    var pc3 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc3.close(io);
    var pc4 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc4.close(io);

    Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

    try registerPc(io, &pc1, hw1_addr, alloc, 1);
    try registerPc(io, &pc2, hw1_addr, alloc, 2);
    try registerPc(io, &pc3, hw2_addr, alloc, 3);
    try registerPc(io, &pc4, hw2_addr, alloc, 4);

    std.debug.print("  Setup: 2 HW + 4 PC registered\n", .{});

    // ═════════════════════════════════════════════
    // Test A: HW→PC broadcast throughput (1→2)
    // ═════════════════════════════════════════════
    std.debug.print("\n── Test A: Broadcast throughput (1 HW → 2 PC) ──\n", .{});

    // Create the broadcast packet once
    const bcast_packet = try custom_codec.encode(alloc, 0x1B, 0x01, &.{ 0xAA, 0xBB });
    defer alloc.free(bcast_packet);

    // Warmup
    _ = try pipelineBroadcast(io, alloc, &hw1, &.{ &pc1, &pc2 }, bcast_packet, 10);
    std.debug.print("  Warmup OK\n", .{});

    const batch_sizes = [_]usize{ 100, 500, 1000 };
    for (batch_sizes) |n| {
        const elapsed_ns = try pipelineBroadcast(io, alloc, &hw1, &.{ &pc1, &pc2 }, bcast_packet, n);
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const msgs_per_sec = @as(f64, @floatFromInt(n)) / (elapsed_ms / 1000.0);
        const deliveries = n * 2;
        const del_per_sec = @as(f64, @floatFromInt(deliveries)) / (elapsed_ms / 1000.0);

        std.debug.print("  N={d:>5}:  {d:8.1} ms  |  {d:9.1} broadcasts/s  |  {d:9.1} deliveries/s\n", .{
            n, elapsed_ms, msgs_per_sec, del_per_sec,
        });
    }

    // ═════════════════════════════════════════════
    // Test B: Two-group concurrent broadcast
    // ═════════════════════════════════════════════
    std.debug.print("\n── Test B: Two-group broadcast (HW1→PC1+PC2 + HW2→PC3+PC4) ──\n", .{});

    {
        const n: usize = 500;
        const start = Io.Clock.now(.real, io);

        // Interleave: send 1 from HW1 + HW2 each, then read all 4 responses
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try hw1.writeAll(io, bcast_packet);
            try hw2.writeAll(io, bcast_packet);

            const r1 = try pc1.readLine(io, alloc);
            alloc.free(r1);
            const r2 = try pc2.readLine(io, alloc);
            alloc.free(r2);
            const r3 = try pc3.readLine(io, alloc);
            alloc.free(r3);
            const r4 = try pc4.readLine(io, alloc);
            alloc.free(r4);
        }

        const end = Io.Clock.now(.real, io);
        const elapsed_ms = @as(f64, @floatFromInt(end.nanoseconds - start.nanoseconds)) / 1_000_000.0;
        const total_deliveries: f64 = 4.0 * @as(f64, @floatFromInt(n));
        const throughput = total_deliveries / (elapsed_ms / 1000.0);

        std.debug.print("  2 groups × {d} packets:  {d:8.1} ms  |  {d:9.1} deliveries/s\n", .{
            n, elapsed_ms, throughput,
        });
    }

    // ═════════════════════════════════════════════
    // Test C: Pipeline burst (1000 packets with pipelined reads)
    // ═════════════════════════════════════════════
    std.debug.print("\n── Test C: Pipeline burst (large batch) ──\n", .{});

    {
        const n: usize = 2000;
        const elapsed_ns = try pipelineBroadcast(io, alloc, &hw1, &.{ &pc1, &pc2 }, bcast_packet, n);
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const rate = @as(f64, @floatFromInt(n)) / (elapsed_ms / 1000.0);
        std.debug.print("  N={d:>5}:  {d:8.1} ms  |  {d:9.1} broadcasts/s  |  {d:9.1} deliveries/s\n", .{
            n, elapsed_ms, rate, rate * 2.0,
        });
    }

    // ── Cleanup ──
    pc1.close(io);
    pc2.close(io);
    pc3.close(io);
    pc4.close(io);
    hw1.close(io);
    hw2.close(io);

    std.debug.print("\n═══ Benchmark complete ═══\n", .{});
}

// ═══════════════════════════════════════════════════════
// Pipeline broadcast: send 1 packet, read all PC responses, repeat N times
// ═══════════════════════════════════════════════════════

fn pipelineBroadcast(
    io: Io,
    allocator: std.mem.Allocator,
    hw: *TcpClient,
    pcs: []const *TcpClient,
    packet: []const u8,
    n: usize,
) !u64 {
    const start = Io.Clock.now(.real, io);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        try hw.writeAll(io, packet);
        for (pcs) |pc| {
            const line = try pc.readLine(io, allocator);
            allocator.free(line);
        }
    }

    const end = Io.Clock.now(.real, io);
    return @as(u64, @intCast(end.nanoseconds - start.nanoseconds));
}

// ═══════════════════════════════════════════════════════
// TcpClient
// ═══════════════════════════════════════════════════════

const TcpClient = struct {
    stream: net.Stream,
    read_buf: [65536]u8 = undefined,
    write_buf: [4096]u8 = undefined,

    fn connect(host: []const u8, port: u16, io: Io) !TcpClient {
        const addr = try net.IpAddress.parseIp4(host, port);
        return .{ .stream = try addr.connect(io, .{ .mode = .stream }) };
    }

    fn close(self: *TcpClient, io: Io) void {
        self.stream.close(io);
    }

    fn writeAll(self: *TcpClient, io: Io, data: []const u8) !void {
        var writer = self.stream.writer(io, &self.write_buf);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    fn readLine(self: *TcpClient, io: Io, allocator: std.mem.Allocator) ![]u8 {
        var reader = self.stream.reader(io, &self.read_buf);
        return try utilReadLine(&reader.interface, allocator);
    }
};

// ═══════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════

fn registerPc(io: Io, pc: *TcpClient, hw_addr: []const u8, allocator: std.mem.Allocator, num: usize) !void {
    const json = try std.fmt.allocPrint(allocator, "{{\"clazz\":\"Register\",\"target_addr\":\"{s}\"}}\n", .{hw_addr});
    defer allocator.free(json);

    try pc.writeAll(io, json);

    const resp = try pc.readLine(io, allocator);
    defer allocator.free(resp);

    if (std.mem.indexOf(u8, resp, "\"code\":0") == null) {
        std.debug.print("  ✗ PC{d} register failed: {s}\n", .{ num, resp });
        return error.RegisterFailed;
    }
    std.debug.print("  ✓ PC{d} registered\n", .{num});
}
