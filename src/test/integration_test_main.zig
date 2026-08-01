const std = @import("std");
const Io = std.Io;
const net = Io.net;
const c = std.c;

const custom_codec = @import("config").custom_codec;

/// Integration test — connects to an ALREADY RUNNING server.
/// Fails fast (within 5s) if the server isn't running.
///
/// Protocol:
///   PC server (port 9000) — binary frames via custom_codec
///   HW server (port 9001) — JSON lines via JsonLineParser
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var backend = Io.Threaded.init(alloc, .{});
    const io = backend.io();

    var pc_host: []const u8 = "127.0.0.1";
    var pc_port: u16 = 9000;
    var hw_host: []const u8 = "127.0.0.1";
    var hw_port: u16 = 9001;
    {
        var args = std.process.Args.iterate(init.minimal.args);
        defer args.deinit();
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--pc-port")) {
                pc_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10);
            } else if (std.mem.eql(u8, arg, "--hw-port")) {
                hw_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10);
            } else if (std.mem.eql(u8, arg, "--pc-host")) {
                pc_host = args.next() orelse return error.MissingArg;
            } else if (std.mem.eql(u8, arg, "--hw-host")) {
                hw_host = args.next() orelse return error.MissingArg;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                std.debug.print("Usage: integ_test [options]\n  --pc-host <host>   PC server host (default: 127.0.0.1)\n  --pc-port <port>   PC server port (default: 9000)\n  --hw-host <host>   HW server host (default: 127.0.0.1)\n  --hw-port <port>   HW server port (default: 9001)\n  --help, -h         Show this help\n", .{});
                return;
            } else {
                std.debug.print("Unknown argument: {s}\n", .{arg});
                return error.UnknownArg;
            }
        }
    }

    std.debug.print("\n=== Zig Forward Integration Test ===\n", .{});
    std.debug.print("  Connecting to PC:{s}:{d}  HW:{s}:{d} ...\n", .{ pc_host, pc_port, hw_host, hw_port });

    // ── Connect HW devices (they're auto-registered on connect) ──
    var hw1 = try connectWithTimeout(hw_host, hw_port, io, 5000);
    errdefer hw1.close(io);
    const hw1_addr = try socketAddrStr(&hw1, alloc);
    std.debug.print("  \u{2713} HW1 connected: {s}\n", .{hw1_addr});

    var hw2 = try connectWithTimeout(hw_host, hw_port, io, 5000);
    errdefer hw2.close(io);
    const hw2_addr = try socketAddrStr(&hw2, alloc);
    std.debug.print("  \u{2713} HW2 connected: {s}\n", .{hw2_addr});

    Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

    // ── Connect PC clients ──
    var pc1 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc1.close(io);
    var pc2 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc2.close(io);
    var pc3 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc3.close(io);
    var pc4 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc4.close(io);
    std.debug.print("  \u{2713} PC1\u{2013}PC4 connected\n", .{});

    Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

    // ═══════════════════════════════════════════════════
    // TEST 1: PC1 + PC2 → HW1 Register (binary protocol)
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 1: PC1, PC2 register to HW1 ──\n", .{});
    try registerPcBinary(&pc1, hw1_addr, alloc, 1);
    try registerPcBinary(&pc2, hw1_addr, alloc, 2);
    std.debug.print("  \u{2713} PASS\n", .{});

    // ═══════════════════════════════════════════════════
    // TEST 2: PC3 + PC4 → HW2 Register (binary protocol)
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 2: PC3, PC4 register to HW2 ──\n", .{});
    try registerPcBinary(&pc3, hw2_addr, alloc, 3);
    try registerPcBinary(&pc4, hw2_addr, alloc, 4);
    std.debug.print("  \u{2713} PASS\n", .{});

    // ═══════════════════════════════════════════════════
    // TEST 3: HW1 sends JSON → PC1, PC2 receive broadcast
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 3: HW1 sends → PC1, PC2 receive broadcast ──\n", .{});
    {
        const hw_json = try std.fmt.allocPrint(alloc, "{{\"cmd\":\"box\",\"addr\":\"{s}\"}}\n", .{hw1_addr});
        defer alloc.free(hw_json);

        try hw1.writeAllRaw(hw_json);
        Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

        const r1 = try pc1.readLineRaw(alloc);
        defer alloc.free(r1);
        try expectContains(r1, "\"from\":\"hw\"");
        std.debug.print("  \u{2713} PC1 received HW1 broadcast\n", .{});

        const r2 = try pc2.readLineRaw(alloc);
        defer alloc.free(r2);
        try expectContains(r2, "\"from\":\"hw\"");
        std.debug.print("  \u{2713} PC2 received HW1 broadcast\n", .{});
    }

    // ═══════════════════════════════════════════════════
    // TEST 4: HW2 sends JSON → PC3, PC4 receive broadcast (group isolation)
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 4: HW2 sends → PC3, PC4 receive broadcast ──\n", .{});
    {
        const hw_json = try std.fmt.allocPrint(alloc, "{{\"cmd\":\"box\",\"addr\":\"{s}\"}}\n", .{hw2_addr});
        defer alloc.free(hw_json);

        try hw2.writeAllRaw(hw_json);
        Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

        const r3 = try pc3.readLineRaw(alloc);
        defer alloc.free(r3);
        try expectContains(r3, "\"from\":\"hw\"");
        std.debug.print("  \u{2713} PC3 received HW2 broadcast\n", .{});

        const r4 = try pc4.readLineRaw(alloc);
        defer alloc.free(r4);
        try expectContains(r4, "\"from\":\"hw\"");
        std.debug.print("  \u{2713} PC4 received HW2 broadcast\n", .{});
    }

    // ═══════════════════════════════════════════════════
    // TEST 5: PC1 forwards command (binary) → verify no crash
    // ═══════════════════════════════════════════════════
    std.debug.print("\n── Test 5: PC1 forward (no-crash check) ──\n", .{});
    {
        // Send a binary frame to trigger forwarding + dispatch
        const frame = try custom_codec.encode(alloc, 0x01, hw1_addr);
        defer alloc.free(frame);
        try pc1.writeAllRaw(frame);
        // Read the response (now has trailing newline)
        const resp = try pc1.readLineRaw(alloc);
        defer alloc.free(resp);
        try expectContains(resp, "boxStatus ok");
        std.debug.print("  \u{2713} PC1 forward response: {s}\n", .{resp});
    }

    // ── Cleanup ──
    pc1.close(io);
    pc2.close(io);
    pc3.close(io);
    pc4.close(io);
    hw1.close(io);
    hw2.close(io);

    std.debug.print("\n=== \u{2713} ALL 5 TESTS PASSED ===\n", .{});
    std.debug.print("  (connected to server on PC:{s}:{d} / HW:{s}:{d})\n", .{ pc_host, pc_port, hw_host, hw_port });
}

// ═══════════════════════════════════════════════════════
// TcpClient — raw I/O (avoids Io.Threaded EAGAIN panic)
// ═══════════════════════════════════════════════════════

const TcpClient = struct {
    stream: net.Stream,
    fd: c_int,

    fn close(self: *TcpClient, io: Io) void {
        self.stream.close(io);
    }

    fn writeAllRaw(self: *TcpClient, data: []const u8) !void {
        var pos: usize = 0;
        while (pos < data.len) {
            const ptr = @as([*]const u8, data.ptr) + pos;
            const n = c.write(self.fd, @ptrCast(ptr), data.len - pos);
            if (n == -1) {
                if (c.errno(n) == .AGAIN) return error.WouldBlock;
                return error.WriteFailed;
            }
            pos += @as(usize, @intCast(n));
        }
    }

    fn readLineRaw(self: *TcpClient, allocator: std.mem.Allocator) ![]u8 {
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;
        while (pos < buf.len) {
            const n = c.read(self.fd, @ptrCast(&buf[pos]), 1);
            if (n == -1) {
                if (c.errno(n) == .AGAIN) return error.WouldBlock;
                return error.ReadFailed;
            }
            if (n == 0) return error.EndOfStream;
            if (buf[pos] == '\n') return allocator.dupe(u8, buf[0..pos]);
            pos += 1;
        }
        return error.LineTooLong;
    }
};

fn connectWithTimeout(host: []const u8, port: u16, io: Io, timeout_ms: u32) !TcpClient {
    const addr = try net.IpAddress.parseIp4(host, port);
    const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.debug.print("Connection failed: {s}:{d} ({s})\n", .{ host, port, @errorName(err) });
        std.debug.print("  Run `zig build run` first to start the server.\n", .{});
        return err;
    };
    var tv = c.timeval{
        .sec = @as(c_long, @intCast(timeout_ms / 1000)),
        .usec = @as(c_int, @intCast((timeout_ms % 1000) * 1000)),
    };
    _ = c.setsockopt(stream.socket.handle, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    return TcpClient{ .stream = stream, .fd = stream.socket.handle };
}

/// Get the local address of a connected socket as "IP:port" string.
fn socketAddrStr(client: *TcpClient, allocator: std.mem.Allocator) ![]u8 {
    const ip = client.stream.socket.address.ip4;
    return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{ ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3], ip.port });
}

/// Register a PC client to a HW group using the binary protocol.
/// Sends a binary frame with the HW address as payload, then reads the response.
fn registerPcBinary(pc: *TcpClient, hw_addr: []const u8, allocator: std.mem.Allocator, num: usize) !void {
    // Create binary frame: type=0x01, payload=HW address
    const frame = try custom_codec.encode(allocator, 0x01, hw_addr);
    defer allocator.free(frame);

    try pc.writeAllRaw(frame);
    const resp = try pc.readLineRaw(allocator);
    defer allocator.free(resp);

    // The handler (handleBoxStatus) returns "boxStatus ok cmd=1"
    if (std.mem.indexOf(u8, resp, "boxStatus ok") == null) {
        std.debug.print("  \u{2717} PC{d} register failed: {s}\n", .{ num, resp });
        return error.RegisterFailed;
    }
    std.debug.print("  PC{d} registered \u{2713}\n", .{num});
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("  \u{2717} \"{s}\" not in \"{s}\"\n", .{ needle, haystack });
        return error.TestFailed;
    }
}
