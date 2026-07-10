const std = @import("std");
const Io = std.Io;
const net = Io.net;

const GlobalState = @import("config").state.GlobalState;
const PcClientState = @import("config").state.PcClientState;
const HandlerRegistry = @import("config").handler_registry.HandlerRegistry;

/// 泛型硬件服务器，与 PcServer 对称。
///
/// **IdType** — 帧类型（如 u8、[]const u8）
/// **Parser** — 从硬件流读取帧的解析器，必须提供：
///   - `init(allocator) Self`
///   - `deinit(self) void`
///   - `parse(self, reader, allocator) !?Frame`
///     Frame 必须有 `id: IdType`、`data: []const u8`、`deinit(self) void`
pub fn HardwareServer(comptime IdType: type, comptime Parser: type) type {
    return struct {
        const Self = @This();
        pub const Handler = HandlerRegistry(IdType, Io).Handler;

        allocator: std.mem.Allocator,
        state: *GlobalState,
        io: Io,
        host: []const u8,
        port: u16,
        registry: HandlerRegistry(IdType, Io),

        pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: Io, host: []const u8, port: u16) Self {
            return .{
                .allocator = allocator,
                .state = state,
                .io = io,
                .host = host,
                .port = port,
                .registry = HandlerRegistry(IdType, Io).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.registry.deinit();
        }

        pub fn start(self: *Self) !void {
            const addr = try net.IpAddress.parseIp4(self.host, self.port);
            var server = try addr.listen(self.io, .{});
            defer server.deinit(self.io);

            std.log.info("Hardware server listening on {s}:{d}", .{ self.host, self.port });

            while (true) {
                const stream = try server.accept(self.io);
                std.log.info("Hardware device connected", .{});

                _ = Io.concurrent(self.io, handleHardware, .{ self, stream }) catch |err| {
                    stream.close(self.io);
                    std.log.err("spawn hardware handler: {}", .{err});
                    continue;
                };
            }
        }

        fn handleHardware(hw_server: *Self, stream: net.Stream) void {
            handleHardwareInner(hw_server, stream) catch |err| {
                std.log.err("Hardware device disconnected ({})", .{err});
            };
        }

        fn handleHardwareInner(hw_server: *Self, stream: net.Stream) !void {
            const allocator = hw_server.allocator;
            const io = hw_server.io;
            const state = hw_server.state;

            const ip = stream.socket.address.ip4;
            const hw_id = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{
                ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3], ip.port,
            });
            defer allocator.free(hw_id);

            // ── 1. 注册硬件连接 ──
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

            defer {
                state.removeGroup(io, hw_id);
                stream.close(io);
                allocator.destroy(hw_state);
            }

            // ── 2. Parser 驱动读取循环 ──
            var parser = Parser.init(allocator);
            defer parser.deinit();

            var reader_buf: [4096]u8 = undefined;
            var reader_io = stream.reader(io, &reader_buf);
            const reader = &reader_io.interface;

            while (true) {
                var frame = try parser.parse(reader, allocator) orelse break;
                defer frame.deinit();

                const result = try hw_server.registry.dispatch(
                    io,
                    frame.id,
                    frame.data,
                    allocator,
                );
                if (result) |json| {
                    defer allocator.free(json);
                    try state.broadcastToA(io, hw_id, json);
                }
            }
        }
    };
}
