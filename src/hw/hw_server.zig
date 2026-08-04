const std = @import("std");
const Io = std.Io;
const net = Io.net;

const GlobalState = @import("app_config").state.GlobalState;
const TcpConn = @import("transport").tcp.TcpConn;
const HandlerRegistry = @import("app_config").handler_registry.HandlerRegistry;
const Parser = @import("parser").Parser;
const Factory = @import("parser").Factory;

/// 硬件服务器（非泛型）。
///
/// `parser_factory` 在构造时注入，决定 HW 端用哪种协议解析器。
/// 与 PcServer 对称，新增协议只需提供新的 Factory。
pub const HwServer = struct {
    const Self = @This();
    pub const Handler = HandlerRegistry.Handler;

    allocator: std.mem.Allocator,
    state: *GlobalState,
    io: Io,
    host: []const u8,
    port: u16,
    registry: HandlerRegistry,
    parser_factory: Factory,
    listener: ?net.Server = null,
    handler_group: std.Io.Group = .init,

    pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: Io, host: []const u8, port: u16, parser_factory: Factory) Self {
        return .{
            .allocator = allocator,
            .state = state,
            .io = io,
            .host = host,
            .port = port,
            .registry = HandlerRegistry.init(allocator),
            .parser_factory = parser_factory,
        };
    }

    pub fn deinit(self: *Self) void {
        self.handler_group.cancel(self.io);
        self.registry.deinit();
        if (self.listener) |*s| {
            s.deinit(self.io);
            self.listener = null;
        }
    }

    pub fn start(self: *Self) !void {
        const addr = try net.IpAddress.parseIp4(self.host, self.port);
        self.listener = try addr.listen(self.io, .{});
        errdefer {
            if (self.listener) |*s| {
                s.deinit(self.io);
                self.listener = null;
            }
        }

        std.log.info("HW server listening on {s}:{d}", .{ self.host, self.port });

        while (true) {
            const stream = self.listener.?.accept(self.io) catch |err| switch (err) {
                error.Canceled => break,
                else => {
                    std.log.err("HW server accept failed: {}", .{err});
                    return err;
                },
            };
            std.log.info("HW device connected", .{});

            self.handler_group.concurrent(self.io, struct {
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

    pub fn registerCommand(self: *Self, id: anytype, handler: Handler) !void {
        try self.registry.register(id, handler);
    }

    pub fn setDefault(self: *Self, handler: Handler) void {
        self.registry.default_handler = handler;
    }

    fn handleHwInner(self: *Self, stream: net.Stream) !void {
        const allocator = self.allocator;
        const io = self.io;
        const state = self.state;

        const ip = stream.socket.address.ip4;
        const hw_id = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{
            ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3], ip.port,
        });
        defer allocator.free(hw_id);

        const conn = try allocator.create(TcpConn);
        conn.* = .{
            .stream = stream,
            .io = io,
            .allocator = allocator,
            .write_mutex = .init,
            .id = hw_id,
        };
        conn.initClient();
        conn.initCSender();

        try state.setCSender(io, hw_id, &conn.c_sender);
        std.log.info("HW {s} connected and registered", .{hw_id});

        defer {
            state.removeGroup(io, hw_id);
            if (!conn.stream_closed) {
                stream.close(io);
            }
            allocator.destroy(conn);
        }

        var parser = try self.parser_factory(allocator);
        defer {
            parser.deinit();
            allocator.destroy(parser);
        }

        var reader_buf: [4096]u8 = undefined;
        var reader_io = stream.reader(io, &reader_buf);
        const reader = &reader_io.interface;

        while (true) {
            const fv = try parser.parse(reader, allocator) orelse break;

            const result = try self.registry.dispatch(fv.id, fv.payload, allocator);
            if (result) |json| {
                defer allocator.free(json);
                try state.broadcastToA(io, hw_id, json);
            }
        }
    }
};
