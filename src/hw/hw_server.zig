const std = @import("std");
const Io = std.Io;
const net = Io.net;

const GlobalState = @import("app_config").state.GlobalState;
const PcClientState = @import("app_config").state.PcClientState;
const HandlerRegistry = @import("app_config").handler_registry.HandlerRegistry;

/// 泛型硬件服务器，与 PcServer 对称。
///
/// **IdType** — 帧类型（如 u8、[]const u8）
/// **Parser** — 从硬件流读取帧的解析器，必须提供：
///   - `init(allocator) Self`
///   - `deinit(self) void`
///   - `parse(self, reader, allocator) !?Frame`
///     Frame 必须有 `id: IdType`、`data: []const u8`、`deinit(self) void`
pub fn HwServer(comptime IdType: type, comptime Parser: type) type {
    return struct {
        const Self = @This();
        pub const Handler = HandlerRegistry(IdType).Handler;

        allocator: std.mem.Allocator,
        state: *GlobalState,
        io: Io,
        host: []const u8,
        port: u16,
        registry: HandlerRegistry(IdType),
        /// 监听 socket，start() 时创建，stop() 时关闭
        listener: ?net.Server = null,
        /// 标记已请求停止，防止 stop() 先于 start() 执行时遗漏
        _stopped: bool = false,

        pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: Io, host: []const u8, port: u16) Self {
            return .{
                .allocator = allocator,
                .state = state,
                .io = io,
                .host = host,
                .port = port,
                .registry = HandlerRegistry(IdType).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.registry.deinit();
            if (self.listener) |*s| {
                s.deinit(self.io);
                self.listener = null;
            }
        }

        /// 关闭监听 socket，正在 accept() 的调用会返回错误，导致 start() 退出
        pub fn stop(self: *Self) void {
            self._stopped = true;
            if (self.listener) |*s| {
                s.deinit(self.io);
                self.listener = null;
            }
        }

        pub fn start(self: *Self) !void {
            const addr = try net.IpAddress.parseIp4(self.host, self.port);
            self.listener = try addr.listen(self.io, .{});
            errdefer self.stop();

            // 如果在创建 listener 之前 stop() 已被调用，立即关闭
            if (self._stopped) {
                self.stop();
                return;
            }

            std.log.info("HW server listening on {s}:{d}", .{ self.host, self.port });

            while (!self._stopped) {
                const stream = self.listener.?.accept(self.io) catch |err| {
                    if (self._stopped) break; // 被 stop() 关闭，正常退出
                    std.log.err("HW server accept failed: {}", .{err});
                    return err;
                };
                std.log.info("HW device connected", .{});

                _ = Io.concurrent(self.io, struct {
                    fn run(s: *Self, st: net.Stream) void {
                        s.handleHwInner(st) catch |err| {
                            std.log.warn("HW device disconnected ({})", .{err});
                        };
                    }
                }.run, .{ self, stream }) catch |err| {
                    stream.close(self.io);
                    std.log.err("spawn HW handler: {}", .{err});
                    continue;
                };
            }
        }

        pub fn registerCommand(self: *Self, cmd: IdType, handler: Handler) !void {
            try self.registry.register(cmd, handler);
        }

        pub fn setDefault(self: *Self, handler: Handler) void {
            self.registry.default_handler = handler;
        }

        fn handleHwInner(hw_server: *Self, stream: net.Stream) !void {
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
            hw_state.initClient();

            try state.setCSender(io, hw_id, hw_state);
            std.log.info("HW {s} connected and registered", .{hw_id});

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
                    frame.id,
                    frame.data,
                    allocator,
                );
                if (result) |json| {
                    defer allocator.free(json);
                    // broadcastToA 现在会通过 AClient 接口同时发送给 TCP 和 WS 客户端
                    try state.broadcastToA(io, hw_id, json);
                }
            }
        }
    };
}
