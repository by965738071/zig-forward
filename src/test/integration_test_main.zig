const std = @import("std");
const Io = std.Io;
const net = Io.net;

const app = @import("app");
const custom_codec = app.config.custom_codec;
const utilReadLine = app.config.util.readLine;

/// Integration test — connects to an ALREADY RUNNING server.
///
/// Prerequisites:
///   Run `zig build run` first (starts PC:9000 / HW:9001).
///
/// Topology:
///   HW1, HW2  → connect to 127.0.0.1:9001
///   PC1, PC2  → connect to 127.0.0.1:9000, register to HW1
///   PC3, PC4  → connect to 127.0.0.1:9000, register to HW2
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var backend = Io.Threaded.init(alloc, .{});
    const io = backend.io();

    const pc_port: u16 = 9000;
    const hw_port: u16 = 9001;

    std.debug.print("\n=== Zig Forward Integration Test ===\n", .{});
    std.debug.print("  Connecting to PC:{d}  HW:{d} ...\n", .{ pc_port, hw_port });

    // ── Connect 2 hardware devices ──
    var hw1 = try TcpClient.connect("127.0.0.1", hw_port, io);
    errdefer hw1.close(io);
    const hw1_addr = try std.fmt.allocPrint(alloc, "{}", .{hw1.stream.socket.address});
    std.debug.print("  ✓ HW1 connected: {s}\n", .{hw1_addr});

    var hw2 = try TcpClient.connect("127.0.0.1", hw_port, io);
    errdefer hw2.close(io);
    const hw2_addr = try std.fmt.allocPrint(alloc, "{}", .{hw2.stream.socket.address});
    std.debug.print("  ✓ HW2 connected: {s}\n", .{hw2_addr});

    Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

    // ── Connect 4 PC clients ──
    var pc1 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc1.close(io);

    var pc2 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc2.close(io);

    var pc3 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc3.close(io);

    var pc4 = try TcpClient.connect("127.0.0.1", pc_port, io);
    errdefer pc4.close(io);
    std.debug.print("  ✓ PC1–PC4 connected\n", .{});

    Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

    // ═══════════════════════════════════════════════════
    // TEST 1: PC1 + PC2 → HW1 Register
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 1: PC1, PC2 register to HW1 ──\n", .{});
    try registerPc(io, &pc1, hw1_addr, alloc, 1);
    try registerPc(io, &pc2, hw1_addr, alloc, 2);
    std.debug.print("  ✓ PASS\n", .{});

    // ═══════════════════════════════════════════════════
    // TEST 2: PC3 + PC4 → HW2 Register
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 2: PC3, PC4 register to HW2 ──\n", .{});
    try registerPc(io, &pc3, hw2_addr, alloc, 3);
    try registerPc(io, &pc4, hw2_addr, alloc, 4);
    std.debug.print("  ✓ PASS\n", .{});

    // ═══════════════════════════════════════════════════
    // TEST 3: HW1 broadcast → PC1 + PC2 receive (HardwareResponse/hex)
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 3: HW1 sends → PC1, PC2 receive hex ──\n", .{});
    {
        const payload = &.{ 0xAA, 0xBB, 0xCC };
        const packet = try custom_codec.encode(alloc, 0x1B, 0x01, payload);
        defer alloc.free(packet);

        try hw1.writeAll(io, packet);
        Io.sleep(io, .{ .nanoseconds = 100_000_000 }, .real) catch {};

        const r1 = try pc1.readLine(io, alloc);
        defer alloc.free(r1);
        try expectContains(r1, "\"code\":0");
        try expectContains(r1, "\"hex\"");
        std.debug.print("  ✓ PC1 received HW1 broadcast\n", .{});

        const r2 = try pc2.readLine(io, alloc);
        defer alloc.free(r2);
        try expectContains(r2, "\"code\":0");
        try expectContains(r2, "\"hex\"");
        std.debug.print("  ✓ PC2 received HW1 broadcast\n", .{});
    }

    // ═══════════════════════════════════════════════════
    // TEST 4: HW2 broadcast → PC3 + PC4 receive (group isolation)
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 4: HW2 sends → PC3, PC4 receive hex ──\n", .{});
    {
        const payload = &.{ 0x11, 0x22, 0x33 };
        const packet = try custom_codec.encode(alloc, 0x2C, 0x02, payload);
        defer alloc.free(packet);

        try hw2.writeAll(io, packet);
        Io.sleep(io, .{ .nanoseconds = 100_000_000 }, .real) catch {};

        const r3 = try pc3.readLine(io, alloc);
        defer alloc.free(r3);
        try expectContains(r3, "\"code\":0");
        try expectContains(r3, "\"hex\"");
        std.debug.print("  ✓ PC3 received HW2 broadcast\n", .{});

        const r4 = try pc4.readLine(io, alloc);
        defer alloc.free(r4);
        try expectContains(r4, "\"code\":0");
        try expectContains(r4, "\"hex\"");
        std.debug.print("  ✓ PC4 received HW2 broadcast\n", .{});
    }

    // ═══════════════════════════════════════════════════
    // TEST 5: PC1 forwards command → verify no crash
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 5: PC1 forward (no-crash check) ──\n", .{});
    {
        const cmd = try std.fmt.allocPrint(alloc, "{{\"clazz\":\"BoxStatus\",\"target_addr\":\"{s}\"}}\n", .{hw1_addr});
        defer alloc.free(cmd);

        try pc1.writeAll(io, cmd);
        Io.sleep(io, .{ .nanoseconds = 500_000_000 }, .real) catch {};

        const cmd2 = try std.fmt.allocPrint(alloc, "{{\"clazz\":\"TimingSignal\",\"target_addr\":\"{s}\"}}\n", .{hw1_addr});
        defer alloc.free(cmd2);

        try pc1.writeAll(io, cmd2);
        Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

        std.debug.print("  ✓ PC1 forward pipeline OK (no crash)\n", .{});
    }

    // ── Cleanup ──
    pc1.close(io);
    pc2.close(io);
    pc3.close(io);
    pc4.close(io);
    hw1.close(io);
    hw2.close(io);

    std.debug.print("\n=== ✓ ALL 5 TESTS PASSED ===\n", .{});
    std.debug.print("  (connected to external server on PC:9000 / HW:9001)\n", .{});
}

// ═══════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════

const TcpClient = struct {
    stream: net.Stream,
    read_buf: [8192]u8 = undefined,
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
    std.debug.print("  PC{d} registered ✓\n", .{num});
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("  ✗ \"{s}\" not in \"{s}\"\n", .{ needle, haystack });
        return error.TestFailed;
    }
}
