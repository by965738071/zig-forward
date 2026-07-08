const std = @import("std");
const Io = std.Io;
const net = Io.net;

const GlobalState = @import("../../config/state.zig").GlobalState;
const PcClientState = @import("../../config/state.zig").PcClientState;
const custom_codec = @import("../../config/custom_codec.zig");
const currentTimestamp = @import("../../config/util.zig").currentTimestamp;
const hexEncode = @import("../../config/util.zig").hexEncode;
const FrameDecoder = @import("../../config/frame_decoder.zig").FrameDecoder;
const DecoderFactory = @import("../../config/frame_decoder.zig").DecoderFactory;
const HandlerRegistry = @import("../../config/handler_registry.zig").HandlerRegistry;

/// Context passed to hardware packet handlers.
pub const HwPacketContext = struct {
    io: Io,
};

pub const PacketRegistry = HandlerRegistry(u8, HwPacketContext);

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
packet_registry: PacketRegistry,

/// 帧解码器工厂（默认为 EB90，可通过 `setDecoderFactory` 替换）
decoder_factory: DecoderFactory,

pub const HardwareServer = @This();

pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: Io, host: []const u8, port: u16) HardwareServer {
    var self: HardwareServer = .{
        .allocator = allocator,
        .state = state,
        .io = io,
        .host = host,
        .port = port,
        .packet_registry = PacketRegistry.init(allocator),
        .decoder_factory = custom_codec.decoder_factory,
    };

    // ── 注册内置默认 handler（hex fallback）──
    self.packet_registry.setDefault(defaultPacketHandler);

    return self;
}

/// 替换帧解码器工厂。
/// 默认使用 `custom_codec.decoder_factory`（EB90 二进制协议）。
pub fn setDecoderFactory(self: *HardwareServer, factory: DecoderFactory) void {
    self.decoder_factory = factory;
}

pub fn start(self: *HardwareServer) !void {
    const addr = try net.IpAddress.parseIp4(self.host, self.port);
    var server = try addr.listen(self.io, .{});
    defer server.deinit(self.io);

    std.log.info("Hardware server listening on {s}:{d}", .{ self.host, self.port });

    while (true) {
        const stream = try server.accept(self.io);
        const ip = stream.socket.address.ip4;
        const hw_id = try std.fmt.allocPrint(self.allocator, "{d}.{d}.{d}.{d}:{d}", .{
            ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3], ip.port,
        });
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
        std.log.err("Hardware {s} disconnected ({})", .{ hw_id, err });
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

    // ── 3. 创建帧解码器（通过工厂，默认为 EB90）──
    var decoder = try hw_server.decoder_factory.create(allocator);
    defer decoder.deinit(allocator);

    // ── 4. 读取循环 ──
    // reader 内部缓冲区与 readVec 目标缓冲区必须分离，避免 @memcpy 重叠
    var reader_buf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader_io = stream.reader(io, &reader_buf);
    const reader = &reader_io.interface;

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

            const packet_type = if (packet.len > 2) packet[2] else 0;
            std.log.info("Hardware {s} packet: type=0x{X:0>2} len={d}", .{
                hw_id,
                packet_type,
                packet.len,
            });

            // 通过 HandlerRegistry 分发：按 packet_type 匹配 handler
            var hw_ctx = HwPacketContext{ .io = io };
            const json = try hw_server.packet_registry.dispatch(
                &hw_ctx,
                packet_type,
                packet,
                allocator,
            ) orelse {
                std.log.warn("no handler for hardware packet type 0x{X:0>2}, dropping", .{packet_type});
                continue :outer;
            };
            defer allocator.free(json);

            try state.broadcastToA(io, hw_id, json);
        }
    }
}

// ── Registry Handler ──

/// Default handler: hex-encode the entire packet as a fallback.
/// Registered as the default for all unmatched packet types.
fn defaultPacketHandler(ctx: *HwPacketContext, _: u8, packet: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
    const hex = try hexEncode(allocator, packet);
    defer allocator.free(hex);
    const ts = currentTimestamp(ctx.io);
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"HardwareResponse\",\"hex\":\"{s}\"}},\"timestamp\":{d}}}\n",
        .{ hex, ts },
    );
    return json;
}
