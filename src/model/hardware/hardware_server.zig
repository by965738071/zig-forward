const std = @import("std");
const Io = std.Io;
const net = Io.net;

const GlobalState = @import("../../config/state.zig").GlobalState;
const PcClientState = @import("../../config/state.zig").PcClientState;
const custom_codec = @import("../../config/custom_codec.zig");
const common_response = @import("common_response.zig");
const currentTimestamp = @import("../../config/util.zig").currentTimestamp;
const hexEncode = @import("../../config/util.zig").hexEncode;

/// 硬件设备 TCP 服务。
///
/// 每个连接由单个 Io.concurrent 任务处理。
/// 从硬件读取二进制协议包，解析为结构化 JSON，再广播给所有注册的 PC 客户端。
/// PC 端发送的命令通过 GlobalState.sendToC 直接写入硬件 socket。
allocator: std.mem.Allocator,
state: *GlobalState,
io: Io,
host: []const u8,
port: u16,

pub const HardwareServer = @This();

pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: Io, host: []const u8, port: u16) HardwareServer {
    return .{
        .allocator = allocator,
        .state = state,
        .io = io,
        .host = host,
        .port = port,
    };
}

pub fn start(self: *HardwareServer) !void {
    const addr = try net.IpAddress.parseIp4(self.host, self.port);
    var server = try addr.listen(self.io, .{});
    defer server.deinit(self.io);

    std.log.info("Hardware server listening on {s}:{d}", .{ self.host, self.port });

    while (true) {
        const stream = try server.accept(self.io);
        const hw_id = try std.fmt.allocPrint(self.allocator, "{}", .{stream.socket.address});
        std.log.info("Hardware device {s} connected", .{hw_id});

        _ = Io.concurrent(self.io, handleHardware, .{ self, stream, hw_id }) catch |err| {
            self.allocator.free(hw_id);
            stream.close(self.io);
            std.log.err("spawn hardware handler: {}", .{err});
            continue;
        };
    }
}

fn handleHardware(hw_server: *HardwareServer, stream: net.Stream, hw_id: []const u8) void {
    defer hw_server.allocator.free(hw_id);

    handleHardwareInner(hw_server, stream, hw_id) catch |err| {
        std.log.info("Hardware {s} disconnected ({s})", .{ hw_id, @errorName(err) });
    };
}

fn handleHardwareInner(hw_server: *HardwareServer, stream: net.Stream, hw_id: []const u8) !void {
    const allocator = hw_server.allocator;
    const io = hw_server.io;
    const state = hw_server.state;

    // ── 1. 创建并注册硬件状态 ──
    const hw_state = try allocator.create(PcClientState);
    hw_state.* = .{
        .stream = stream,
        .io = io,
        .allocator = allocator,
        .write_mutex = .init,
        .pc_id = hw_id,
    };

    try state.setCSender(io, hw_id, hw_state);
    std.log.info("Hardware {s} connected and registered", .{hw_id});

    // ── 2. 清理 ──
    defer {
        // 使用栈缓冲区避免 defer 中堆分配
        var close_buf: [256]u8 = undefined;
        const close_json = std.fmt.bufPrint(&close_buf, "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"HardwareClosed\"}},\"timestamp\":{d}}}\n", .{currentTimestamp(io)}) catch null;
        if (close_json) |j| {
            state.broadcastToA(io, hw_id, j) catch {};
        }

        state.removeGroup(io, hw_id);

        stream.close(io);
        allocator.destroy(hw_state);
    }

    // ── 3. 读取循环 ──
    // reader 内部缓冲区与 readVec 目标缓冲区必须分离，避免 @memcpy 重叠
    var reader_buf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader_io = stream.reader(io, &reader_buf);
    const reader = &reader_io.interface;
    var decoder = custom_codec.Decoder.init(allocator);
    defer decoder.deinit();

    outer: while (true) {
        var read_iov: [1][]u8 = .{read_buf[0..]};
        const n = try reader.readVec(&read_iov);
        if (n == 0) {
            std.log.info("Hardware {s} EOF", .{hw_id});
            return;
        }

        try decoder.feed(read_buf[0..n]);

        while (true) {
            const packet = try decoder.decode() orelse break;
            defer allocator.free(packet);

            std.log.info("Hardware {s} packet: type=0x{X:0>2} len={d}", .{
                hw_id,
                if (packet.len > 2) packet[2] else 0,
                packet.len,
            });

            // 尝试结构化解析，失败则回退到 hex JSON
            // 两个路径都失败时跳到外层循环重新读取（避免执行下方 defer）
            const json = parseResponseJson(allocator, io, packet) catch blk: {
                const fallback = buildFallbackJson(allocator, io, packet) catch {
                    std.log.warn("failed to build any JSON for hardware packet, dropping", .{});
                    continue :outer;
                };
                break :blk fallback;
            };
            defer allocator.free(json);

            try state.broadcastToA(io, hw_id, json);
        }
    }
}

// ── JSON 构建辅助 ──

/// 将二进制包解析为结构化响应并包装为 JSON。
fn parseResponseJson(allocator: std.mem.Allocator, io: Io, packet: []const u8) ![]u8 {
    var dyn_resp = try common_response.parseResponse(packet, allocator);
    defer dyn_resp.deinit(allocator);

    const ts = currentTimestamp(io);

    switch (dyn_resp) {
        .closed => {
            return std.fmt.allocPrint(
                allocator,
                "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"HardwareClosed\"}},\"timestamp\":{d}}}\n",
                .{ts},
            );
        },
        .generic => |*g| {
            return std.fmt.allocPrint(
                allocator,
                "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"HardwareResponse\",\"type\":{d},\"board\":{d},\"hex\":\"{s}\",\"length\":{d}}},\"timestamp\":{d}}}\n",
                .{ g.packet_type, g.board_id, g.hex, g.raw_bytes.len, ts },
            );
        },
    }
}

/// 回退方案：hex 编码 JSON（当 parseResponse 失败时使用）。
fn buildFallbackJson(allocator: std.mem.Allocator, io: Io, packet: []const u8) ![]u8 {
    const hex = try hexEncode(allocator, packet);
    defer allocator.free(hex);
    const ts = currentTimestamp(io);
    return std.fmt.allocPrint(
        allocator,
        "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"HardwareResponse\",\"hex\":\"{s}\"}},\"timestamp\":{d}}}\n",
        .{ hex, ts },
    );
}
