const std = @import("std");
const Io = std.Io;
const net = Io.net;
const c = std.c;

const app = @import("app");
const byte_parser = @import("parser").byte_parser;

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
                std.debug.print("Usage: benchmark [options]\n  --pc-host <host>   PC server host (default: 127.0.0.1)\n  --pc-port <port>   PC server port (default: 9000)\n  --hw-host <host>   HW server host (default: 127.0.0.1)\n  --hw-port <port>   HW server port (default: 9001)\n  --help, -h         Show this help\n", .{});
                return;
            } else {
                std.debug.print("Unknown argument: {s}\n", .{arg});
                return error.UnknownArg;
            }
        }
    }

    std.debug.print("\n═══ Zig Forward Benchmark ═══\n", .{});
    std.debug.print("  Server: PC:{s}:{d}  HW:{s}:{d}\n", .{ pc_host, pc_port, hw_host, hw_port });

    // ── Connect HW devices (auto-registered on connect) ──
    var hw1 = try connectWithTimeout(hw_host, hw_port, io, 5000);
    errdefer hw1.close(io);
    const hw1_addr = try socketAddrStr(&hw1, alloc);

    var hw2 = try connectWithTimeout(hw_host, hw_port, io, 5000);
    errdefer hw2.close(io);
    const hw2_addr = try socketAddrStr(&hw2, alloc);

    // ── Connect PC clients ──
    var pc1 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc1.close(io);
    var pc2 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc2.close(io);
    var pc3 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc3.close(io);
    var pc4 = try connectWithTimeout(pc_host, pc_port, io, 5000);
    errdefer pc4.close(io);

    // Allow server to register all connections
    Io.sleep(io, .{ .nanoseconds = 200_000_000 }, .real) catch {};

    // ── Register PC clients (binary protocol) ──
    registerPcBinary(&pc1, hw1_addr, alloc, 1) catch |err| {
        std.debug.print("  \u{2717} Connection failed: server not responding (is it running?)\n", .{});
        std.debug.print("  Run `zig build run` first to start the server.\n", .{});
        return err;
    };
    try registerPcBinary(&pc2, hw1_addr, alloc, 2);
    try registerPcBinary(&pc3, hw2_addr, alloc, 3);
    try registerPcBinary(&pc4, hw2_addr, alloc, 4);

    std.debug.print("  Setup: 2 HW + 4 PC registered\n", .{});

    // ── Build JSON payload for HW → HW server ──
    // Use a non-"box" cmd to hit hwDefaultHandler (fast passthrough)
    const hw_json = try std.fmt.allocPrint(alloc, "{{\"cmd\":\"bench\",\"addr\":\"{s}\"}}\n", .{hw1_addr});
    defer alloc.free(hw_json);

    std.debug.print("\n── Test A: Broadcast throughput ──\n", .{});
    _ = try pipelineBroadcastRaw(&hw1, &.{ &pc1, &pc2 }, hw_json, alloc, 10);
    std.debug.print("  Warmup OK\n", .{});

    for ([_]usize{ 100, 500, 1000 }) |n| {
        const elapsed_ns = try pipelineBroadcastRaw(&hw1, &.{ &pc1, &pc2 }, hw_json, alloc, n);
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        std.debug.print("  N={d:>5}:  {d:8.1} ms  |  {d:9.1} broadcasts/s  |  {d:9.1} deliveries/s\n", .{ n, elapsed_ms, @as(f64, @floatFromInt(n)) / (elapsed_ms / 1000.0), @as(f64, @floatFromInt(n * 2)) / (elapsed_ms / 1000.0) });
    }

    std.debug.print("\n── Test B: Two-group broadcast ──\n", .{});
    {
        const n: usize = 500;
        // Build JSON for HW2 group
        const hw2_json = try std.fmt.allocPrint(alloc, "{{\"cmd\":\"bench\",\"addr\":\"{s}\"}}\n", .{hw2_addr});
        defer alloc.free(hw2_json);

        const start = nowNanos();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try hw1.writeAllRaw(hw_json);
            try hw2.writeAllRaw(hw2_json);
            alloc.free(try pc1.readLineRaw(alloc));
            alloc.free(try pc2.readLineRaw(alloc));
            alloc.free(try pc3.readLineRaw(alloc));
            alloc.free(try pc4.readLineRaw(alloc));
        }
        const end = nowNanos();
        const elapsed_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        std.debug.print("  2 groups \u{00d7} {d} packets:  {d:8.1} ms  |  {d:9.1} deliveries/s\n", .{ n, elapsed_ms, 4.0 * @as(f64, @floatFromInt(n)) / (elapsed_ms / 1000.0) });
    }

    std.debug.print("\n── Test C: Pipeline burst ──\n", .{});
    {
        const n: usize = 2000;
        const elapsed_ns = try pipelineBroadcastRaw(&hw1, &.{ &pc1, &pc2 }, hw_json, alloc, n);
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        std.debug.print("  N={d:>5}:  {d:8.1} ms  |  {d:9.1} broadcasts/s  |  {d:9.1} deliveries/s\n", .{ n, elapsed_ms, @as(f64, @floatFromInt(n)) / (elapsed_ms / 1000.0), @as(f64, @floatFromInt(n * 2)) / (elapsed_ms / 1000.0) });
    }

    pc1.close(io);
    pc2.close(io);
    pc3.close(io);
    pc4.close(io);
    hw1.close(io);
    hw2.close(io);
    std.debug.print("\n═══ Benchmark complete ═══\n", .{});
}

// ═══════════════════════════════════════════════════════
// TcpClient — raw I/O via c.read/c.write
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

fn nowNanos() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Pipeline: send N JSON lines from HW → server, read N responses from each PC.
fn pipelineBroadcastRaw(hw: *TcpClient, pcs: []const *TcpClient, json_line: []const u8, allocator: std.mem.Allocator, n: usize) !u64 {
    const start = nowNanos();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try hw.writeAllRaw(json_line);
        for (pcs) |pc| allocator.free(try pc.readLineRaw(allocator));
    }
    const end = nowNanos();
    return @as(u64, @intCast(end - start));
}

/// Register a PC client using the binary protocol.
fn registerPcBinary(pc: *TcpClient, hw_addr: []const u8, allocator: std.mem.Allocator, num: usize) !void {
    const frame = try byte_parser.encode(allocator, 0x01, hw_addr);
    defer allocator.free(frame);
    try pc.writeAllRaw(frame);
    const resp = try pc.readLineRaw(allocator);
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "boxStatus ok") == null) {
        std.debug.print("  \u{2717} PC{d} register failed: {s}\n", .{ num, resp });
        return error.RegisterFailed;
    }
    std.debug.print("  \u{2713} PC{d} registered\n", .{num});
}
