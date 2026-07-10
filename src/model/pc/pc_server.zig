const std = @import("std");

const GlobalState = @import("config").state.GlobalState;
const PcClientState = @import("config").state.PcClientState;

const HandlerRegistry = @import("config").handler_registry.HandlerRegistry;
const Config = @import("config").ConfigType;

pub fn PcServer(comptime IdType: type, comptime Parser: type) type {
    return struct {
        pub const Handler = HandlerRegistry(IdType, void).Handler;

        allocator: std.mem.Allocator,
        state: *GlobalState,
        io: std.Io,
        config: Config,
        registry: HandlerRegistry(IdType, void),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: std.Io, config: Config) Self {
            return .{
                .allocator = allocator,
                .state = state,
                .io = io,
                .config = config,
                .registry = HandlerRegistry(IdType, void).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.registry.deinit();
        }

        pub fn registerCommand(self: *Self, cmd: IdType, handler: Handler) !void {
            try self.registry.register(cmd, handler);
        }

        pub fn dispatch(self: *Self, cmd: IdType, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
            return self.registry.dispatch({}, cmd, data, allocator);
        }

        pub fn start(self: *Self) !void {
            const addr = try std.Io.net.IpAddress.parseIp4(self.config.pc.host, self.config.pc.port);
            var server = try addr.listen(self.io, .{});
            defer server.deinit(self.io);

            std.log.info("PC server listening on {s}:{d}", .{ self.config.pc.host, self.config.pc.port });

            while (true) {
                const stream = try server.accept(self.io);
                std.log.info("PC client connected", .{});

                _ = std.Io.concurrent(self.io, handlePcClient, .{ self, stream }) catch |err| {
                    stream.close(self.io);
                    std.log.err("spawn PC handler: {}", .{err});
                    continue;
                };
            }
        }

        fn handlePcClient(self: *Self, stream: std.Io.net.Stream) void {
            handlePcClientInner(self, stream) catch |err| {
                std.log.err("PC client disconnected ({})", .{err});
            };
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

            var target_addr: ?[]u8 = null;

            defer {
                if (target_addr) |addr| {
                    state.removeAClient(io, addr, pc_id) catch std.log.warn("failed to remove client {s} from {s}", .{ pc_id, addr });
                    allocator.free(addr);
                }
                stream.close(io);
                allocator.destroy(client_state);
            }

            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader_io = stream.reader(io, &read_buf);
            var writer_io = stream.writer(io, &write_buf);
            const reader = &reader_io.interface;
            const writer = &writer_io.interface;

            while (true) {
                var frame = try Parser.parse(reader, allocator);
                defer frame.deinit();

                // frame.deinit() 会 free addr，所以 target_addr 需要自己的副本
                const new_addr = try allocator.dupe(u8, frame.addr);

                const addr_changed = if (target_addr) |old| blk: {
                    if (!std.mem.eql(u8, old, new_addr)) {
                        try state.removeAClient(io, old, pc_id);
                        allocator.free(old);
                        break :blk true;
                    }
                    allocator.free(old);
                    break :blk false;
                } else true;

                target_addr = new_addr;
                if (addr_changed) try state.addAClient(io, target_addr.?, pc_id, client_state);

                // 先转发给硬件设备，再执行本地 handler
                state.sendToC(io, target_addr.?, pc_id, frame.data) catch |err| {
                    std.log.warn("forward to hardware failed: {}", .{err});
                };

                const response = try self.dispatch(
                    frame.cmd,
                    frame.data,
                    allocator,
                );
                if (response) |data| {
                    defer allocator.free(data);
                    try writer.writeAll(data);
                    try writer.flush();
                }
            }
        }
    };
}
