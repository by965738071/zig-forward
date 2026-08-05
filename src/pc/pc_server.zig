const std = @import("std");

const GlobalState = @import("app_config").state.GlobalState;
const TcpConn = @import("transport").tcp.TcpConn;
const config_mod = @import("app_config").config;
const Frame = @import("parser").Frame;
const Id = @import("parser").Id;
const Parser = @import("parser").Parser;
const Factory = @import("parser").Factory;

const HandlerRegistry = @import("app_config").handler_registry.HandlerRegistry;
const Config = @import("app_config").ConfigType;

/// 向 writer 写入一行（追加 `\n` 并 flush）。
fn writeLine(writer: *std.Io.Writer, msg: []const u8) !void {
    try writer.writeAll(msg);
    try writer.writeByte('\n');
    try writer.flush();
}

/// PC 服务器（非泛型）。
///
/// `parser_factory` 在构造时注入，决定 PC 端用哪种协议解析器。
/// 运行时可切换 factory（例如按配置选择二进制/文本协议），无需重新编译。
pub const PcServer = struct {
    pub const Handler = HandlerRegistry.Handler;

    allocator: std.mem.Allocator,
    state: *GlobalState,
    io: std.Io,
    config: Config,
    registry: HandlerRegistry,
    parser_factory: Factory,
    listener: ?std.Io.net.Server = null,
    handler_group: std.Io.Group = .init,

    pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: std.Io, config: Config, parser_factory: Factory) PcServer {
        return .{
            .allocator = allocator,
            .state = state,
            .io = io,
            .config = config,
            .registry = HandlerRegistry.init(allocator),
            .parser_factory = parser_factory,
        };
    }

    pub fn deinit(self: *PcServer) void {
        self.handler_group.cancel(self.io);
        self.registry.deinit();
        if (self.listener) |*s| {
            s.deinit(self.io);
            self.listener = null;
        }
    }

    pub fn registerCommand(self: *PcServer, id: Id, handler: Handler) !void {
        try self.registry.register(id, handler);
    }

    pub fn dispatch(self: *PcServer, id: Id, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.registry.dispatch(id, data, allocator);
    }

    pub fn start(self: *PcServer) !void {
        const addr = try std.Io.net.IpAddress.parseIp4(self.config.pc.host, self.config.pc.port);
        self.listener = try addr.listen(self.io, .{});
        errdefer {
            if (self.listener) |*s| {
                s.deinit(self.io);
                self.listener = null;
            }
        }

        std.log.info("PC server listening on {s}:{d}", .{ self.config.pc.host, self.config.pc.port });

        while (true) {
            const stream = try self.listener.?.accept(self.io);
            std.log.info("PC client connected ip ={f}", .{stream.socket.address});

            self.handler_group.concurrent(self.io, struct {
                fn run(s: *PcServer, st: std.Io.net.Stream) void {
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

    fn handlePcClientInner(self: *PcServer, stream: std.Io.net.Stream) !void {
        const allocator = self.allocator;
        const io = self.io;
        const state = self.state;

        const pc_id = try std.fmt.allocPrint(allocator, "{}", .{stream.socket.address});
        defer allocator.free(pc_id);

        const conn = try allocator.create(TcpConn);
        conn.* = .{
            .stream = stream,
            .io = io,
            .allocator = allocator,
            .write_mutex = .init,
            .id = pc_id,
        };
        conn.initClient();

        var target_addrs: std.StringHashMap(void) = .init(allocator);

        defer {
            var it = target_addrs.keyIterator();
            while (it.next()) |addr| {
                state.removeAClient(io, addr.*, pc_id) catch std.log.warn("failed to remove client {s} from {s}", .{ pc_id, addr.* });
                allocator.free(addr.*);
            }
            target_addrs.deinit();
            if (!conn.stream_closed) {
                stream.close(io);
            }
            allocator.destroy(conn);
        }

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader_io = stream.reader(io, &read_buf);
        var writer_io = stream.writer(io, &write_buf);
        const reader = &reader_io.interface;
        const writer = &writer_io.interface;

        // 通过工厂创建 parser 实例（运行时协议选择）
        var parser = try self.parser_factory(allocator);
        defer {
            parser.deinit();
            allocator.destroy(parser);
        }

        while (true) {
            const fv = try parser.parse(reader, allocator) orelse break;

            // ── 控制权命令拦截（0x10-0x13，仅对 int id 生效）──
            if (try self.handleControlCmd(fv, writer)) |handled| {
                if (handled) continue;
            }

            // 从 payload 提取 addrs（\0 分隔），这是业务语义，放在 server 层而非 parser。
            var addrs_list = std.ArrayList([]const u8).empty;
            defer {
                for (addrs_list.items) |a| allocator.free(a);
                addrs_list.deinit(allocator);
            }
            {
                const payload = fv.payload;
                var offset: usize = 0;
                while (offset < payload.len and payload[offset] != 0) {
                    const end = std.mem.findScalar(u8, payload[offset..], 0) orelse payload.len;
                    try addrs_list.append(allocator, try allocator.dupe(u8, payload[offset..end]));
                    offset = end + 1;
                }
            }

            // 注册每个目标地址，并转发原始帧给硬件设备
            for (addrs_list.items) |addr| {
                const gop = try target_addrs.getOrPut(addr);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try allocator.dupe(u8, addr);
                    try state.addAClient(io, addr, pc_id, &conn.client);
                }

                state.sendToC(io, addr, fv.raw) catch |err| {
                    std.log.warn("forward to HW failed: {}", .{err});
                };
            }

            const response = try self.dispatch(fv.id, fv.raw, allocator);
            if (response) |data| {
                defer allocator.free(data);
                try writer.writeAll(data);
                try writer.writeByte('\n');
                try writer.flush();
            }
        }
    }

    /// 处理控制权命令。返回 `null` 表示非控制权命令（交回 dispatch），
    /// 返回 `true` 表示已处理并回复，返回 `false` 表示是控制权命令但处理失败已回复错误。
    fn handleControlCmd(self: *PcServer, fv: Frame, writer: anytype) !?bool {
        const io = self.io;
        const state = self.state;
        const allocator = self.allocator;

        const cmd: u8 = switch (fv.id) {
            .int => |n| if (n <= std.math.maxInt(u8)) @intCast(n) else return null,
            .str => return null, // 字符串 id 协议不走控制权二进制码
        };

        if (cmd != config_mod.CMD_REQUEST_CONTROL and
            cmd != config_mod.CMD_RELEASE_CONTROL and
            cmd != config_mod.CMD_HEARTBEAT and
            cmd != config_mod.CMD_GET_STATUS)
        {
            return null;
        }

        const payload = fv.payload;
        var addr: []const u8 = payload;
        var req_pc_id: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, payload, 0)) |sep| {
            addr = payload[0..sep];
            if (sep + 1 < payload.len) req_pc_id = payload[sep + 1 ..];
        }

        switch (cmd) {
            config_mod.CMD_REQUEST_CONTROL => {
                const ctrl_pc_id = req_pc_id orelse {
                    try writeLine(writer, "error: missing pc_id");
                    return false;
                };
                const granted = state.requestControl(io, addr, ctrl_pc_id) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) catch return false;
                    defer allocator.free(msg);
                    try writeLine(writer, msg);
                    return false;
                };
                try writeLine(writer, if (granted) "RequestControl:granted" else "RequestControl:denied");
                return true;
            },
            config_mod.CMD_RELEASE_CONTROL => {
                state.releaseControl(io, addr) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) catch return false;
                    defer allocator.free(msg);
                    try writeLine(writer, msg);
                    return false;
                };
                try writeLine(writer, "ReleaseControl:ok");
                return true;
            },
            config_mod.CMD_HEARTBEAT => {
                const ctrl_pc_id = req_pc_id orelse {
                    try writeLine(writer, "error: missing pc_id");
                    return false;
                };
                const renewed = state.heartbeat(io, addr, ctrl_pc_id) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) catch return false;
                    defer allocator.free(msg);
                    try writeLine(writer, msg);
                    return false;
                };
                try writeLine(writer, if (renewed) "Heartbeat:renewed" else "Heartbeat:not_owner");
                return true;
            },
            config_mod.CMD_GET_STATUS => {
                const owner = state.getOwner(io, addr) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) catch return false;
                    defer allocator.free(msg);
                    try writeLine(writer, msg);
                    return false;
                };
                if (owner) |o| {
                    const msg = std.fmt.allocPrint(allocator, "GetStatus:owner={s}", .{o}) catch return false;
                    defer allocator.free(msg);
                    try writeLine(writer, msg);
                } else {
                    try writeLine(writer, "GetStatus:no_owner");
                }
                return true;
            },
            else => unreachable,
        }
    }
};
