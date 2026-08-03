const std = @import("std");

const GlobalState = @import("app_config").state.GlobalState;
const PcClientState = @import("app_config").state.PcClientState;

const HandlerRegistry = @import("app_config").handler_registry.HandlerRegistry;
const Config = @import("app_config").ConfigType;

pub fn PcServer(comptime IdType: type, comptime Parser: type) type {
    return struct {
        pub const Handler = HandlerRegistry(IdType).Handler;

        allocator: std.mem.Allocator,
        state: *GlobalState,
        io: std.Io,
        config: Config,
        registry: HandlerRegistry(IdType),
        /// 监听 socket，start() 时创建，stop() 时关闭
        listener: ?std.Io.net.Server = null,
        /// 标记已请求停止，防止 stop() 先于 start() 执行时遗漏
        _stopped: bool = false,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: std.Io, config: Config) Self {
            return .{
                .allocator = allocator,
                .state = state,
                .io = io,
                .config = config,
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

        pub fn registerCommand(self: *Self, cmd: IdType, handler: Handler) !void {
            try self.registry.register(cmd, handler);
        }

        pub fn dispatch(self: *Self, cmd: IdType, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
            return self.registry.dispatch(cmd, data, allocator);
        }

        pub fn start(self: *Self) !void {
            const addr = try std.Io.net.IpAddress.parseIp4(self.config.pc.host, self.config.pc.port);
            self.listener = try addr.listen(self.io, .{});
            errdefer self.stop();

            // 如果在创建 listener 之前 stop() 已被调用，立即关闭
            if (self._stopped) {
                self.stop();
                return;
            }

            std.log.info("PC server listening on {s}:{d}", .{ self.config.pc.host, self.config.pc.port });

            while (!self._stopped) {
                const stream = self.listener.?.accept(self.io) catch |err| {
                    if (self._stopped) break; // 被 stop() 关闭，正常退出
                    std.log.err("PC server accept failed: {}", .{err});
                    return err;
                };
                std.log.info("PC client connected ip ={f}", .{stream.socket.address});

                _ = std.Io.concurrent(self.io, struct {
                    fn run(s: *Self, st: std.Io.net.Stream) void {
                        s.handlePcClientInner(st) catch |err| {
                            std.log.warn("PC client disconnected ({})", .{err});
                        };
                    }
                }.run, .{ self, stream }) catch |err| {
                    stream.close(self.io);
                    std.log.err("spawn PC handler: {}", .{err});
                    continue;
                };
            }
        }

        fn handlePcClientInner(self: *Self, stream: std.Io.net.Stream) !void {
            const allocator = self.allocator;
            const io = self.io;
            const state = self.state;

            const pc_id = try std.fmt.allocPrint(allocator, "{}", .{stream.socket.address});
            defer allocator.free(pc_id);

            const client_state = try allocator.create(PcClientState);
            client_state.* = .{
                .stream = stream,
                .io = io,
                .allocator = allocator,
                .write_mutex = .init,
                .pc_id = pc_id,
            };
            client_state.initClient();

            var target_addrs: std.StringHashMap(void) = .init(allocator);

            defer {
                var it = target_addrs.keyIterator();
                while (it.next()) |addr| {
                    state.removeAClient(io, addr.*, pc_id) catch std.log.warn("failed to remove client {s} from {s}", .{ pc_id, addr.* });
                    allocator.free(addr.*);
                }
                target_addrs.deinit();
                if (!client_state.stream_closed) {
                    stream.close(io);
                }
                allocator.destroy(client_state);
            }

            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader_io = stream.reader(io, &read_buf);
            var writer_io = stream.writer(io, &write_buf);
            const reader = &reader_io.interface;
            const writer = &writer_io.interface;

            var parser = Parser.init(allocator);
            defer parser.deinit();

            while (true) {
                var frame = try parser.parse(reader, allocator) orelse break;
                defer frame.deinit();

                // 注册每个目标地址，并转发给硬件设备
                for (frame.addrs) |addr| {
                    const gop = try target_addrs.getOrPut(addr);
                    if (!gop.found_existing) {
                        gop.key_ptr.* = try allocator.dupe(u8, addr);
                        // 通过 AClient 接口注册到 Group.a_clients
                        try state.addAClient(io, addr, pc_id, &client_state.client);
                    }

                    state.sendToC(io, addr, frame.data) catch |err| {
                        std.log.warn("forward to HW failed: {}", .{err});
                    };
                }

                const response = try self.dispatch(
                    frame.id,
                    frame.data,
                    allocator,
                );
                if (response) |data| {
                    defer allocator.free(data);
                    try writer.writeAll(data);
                    try writer.writeByte('\n');
                    try writer.flush();
                }
            }
        }
    };
}
