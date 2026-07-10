const std = @import("std");

const GlobalState = @import("../../config/state.zig").GlobalState;
const PcClientState = @import("../../config/state.zig").PcClientState;

const currentTimestamp = @import("../../config/util.zig").currentTimestamp;
const PcDataInfo = @import("common_request.zig").PcDataInfo;
const HandlerRegistry = @import("../../config/config.zig").HandlerRegistry;

/// Context passed to each PC command handler.
pub const PcCommandContext = struct {
    io: std.Io,
    state: *GlobalState,
    writer: *std.Io.Writer,
    pc_server: *PcServer,
    pc_id: []const u8,
    client_state: *PcClientState,
    first: *bool,
    registered_addr: *?[]u8,
    cmd_target: []const u8,
};

pub const CommandRegistry = HandlerRegistry([]const u8, PcCommandContext);

/// PC 控制端 TCP 服务。
///
/// 每个连接由单个 Io.concurrent 任务处理。
/// 命令读取、处理、响应全部同步完成。
/// 硬件广播通过 GlobalState.broadcastToA 直接写入 PC socket。
allocator: std.mem.Allocator,
state: *GlobalState,
io: std.Io,
host: []const u8,
port: u16,
command_registry: CommandRegistry,

pub const PcServer = @This();

pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: std.Io, host: []const u8, port: u16) PcServer {
    var self: PcServer = .{
        .allocator = allocator,
        .state = state,
        .io = io,
        .host = host,
        .port = port,
        .command_registry = CommandRegistry.init(allocator),
    };

    // ── 注册内置命令 handlers ──
    self.command_registry.register("Register", registerHandler) catch {};
    self.command_registry.register("RequestControl", requestControlHandler) catch {};
    self.command_registry.register("ReleaseControl", releaseControlHandler) catch {};
    self.command_registry.register("Heartbeat", heartbeatHandler) catch {};
    self.command_registry.setDefault(forwardHandler);

    return self;
}

///注册COMMAND
pub fn registerCommand(self: *PcServer, cmd: []const u8, handler: CommandRegistry.Handler) !void {
    try self.command_registry.register(cmd, handler);
}

pub fn start(self: *PcServer) !void {
    const addr = try std.Io.net.IpAddress.parseIp4(self.host, self.port);
    var server = try addr.listen(self.io, .{});
    defer server.deinit(self.io);

    std.log.info("PC server listening on {s}:{d}", .{ self.host, self.port });

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

fn handlePcClient(pc_server: *PcServer, stream: std.Io.net.Stream) void {
    handlePcClientInner(pc_server, stream) catch |err| {
        std.log.err("PC client disconnected ({})", .{err});
    };
}

fn handlePcClientInner(pc_server: *PcServer, stream: std.Io.net.Stream) !void {
    const allocator = pc_server.allocator;
    const io = pc_server.io;
    const state = pc_server.state;

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

    var first = true;
    var target_addr: ?[]u8 = null;

    defer {
        if (target_addr) |addr| {
            // 先 removeAClient 再 free addr：removeAClient 内部使用 addr 做 hashmap 查找
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
        var pc_data_info = try PcDataInfo.init(reader, allocator);
        defer pc_data_info.deinit();

        var ctx = PcCommandContext{
            .io = io,
            .state = state,
            .writer = writer,
            .pc_server = pc_server,
            .pc_id = pc_id,
            .client_state = client_state,
            .first = &first,
            .registered_addr = &target_addr,
            .cmd_target = pc_data_info.target_addr,
        };

        const response = try pc_server.command_registry.dispatch(
            &ctx,

            pc_data_info.raw,
            allocator,
        );
        if (response) |json| {
            defer allocator.free(json);
            try writer.writeAll(json);
            try writer.flush();
        }
        // null: handled but no response needed (forward success)
    }
}

// ── Registry Handlers ──

fn registerHandler(ctx: *PcCommandContext, _: []const u8, _: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
    if (!ctx.first.*) return error.DuplicateRegister;
    ctx.first.* = false;

    try ctx.state.addAClient(ctx.io, ctx.cmd_target, ctx.pc_id, ctx.client_state);

    ctx.registered_addr.* = try allocator.dupe(u8, ctx.cmd_target);
    std.log.info("PC {s} registered to {s}", .{ ctx.pc_id, ctx.registered_addr.*.? });

    const json = try ctx.pc_server.buildJsonRegisterOk();
    return json;
}

fn requestControlHandler(ctx: *PcCommandContext, _: []const u8, _: []const u8, _: std.mem.Allocator) anyerror!?[]u8 {
    if (ctx.first.*) return error.NotRegistered;

    const granted = try ctx.state.requestControl(ctx.io, ctx.cmd_target, ctx.pc_id);
    if (granted) {
        const json = try ctx.pc_server.buildControlGranted();
        return json;
    }

    const owner = try ctx.state.getOwner(ctx.io, ctx.cmd_target);
    const json = try ctx.pc_server.buildControlDenied(owner);
    return json;
}

fn releaseControlHandler(ctx: *PcCommandContext, _: []const u8, _: []const u8, _: std.mem.Allocator) anyerror!?[]u8 {
    if (ctx.first.*) return error.NotRegistered;
    ctx.state.releaseControl(ctx.io, ctx.cmd_target);
    const json = try ctx.pc_server.buildControlReleased();
    return json;
}

fn heartbeatHandler(ctx: *PcCommandContext, _: []const u8, _: []const u8, _: std.mem.Allocator) anyerror!?[]u8 {
    if (ctx.first.*) return error.NotRegistered;
    const ok = try ctx.state.heartbeat(ctx.io, ctx.cmd_target, ctx.pc_id);
    if (ok) {
        const json = try ctx.pc_server.buildHeartbeatOk();
        return json;
    }
    const json = try ctx.pc_server.buildHeartbeatDenied();
    return json;
}

fn forwardHandler(ctx: *PcCommandContext, _: []const u8, data: []const u8, _: std.mem.Allocator) anyerror!?[]u8 {
    if (ctx.first.*) return error.NotRegistered;
    const addr = ctx.registered_addr.* orelse return error.NotRegistered;

    ctx.state.sendToC(ctx.io, addr, ctx.pc_id, data) catch |err| {
        return switch (err) {
            error.NoControlOwner => blk: {
                const j = try ctx.pc_server.buildNoOwnerError();
                break :blk j;
            },
            error.NotControlOwner => blk: {
                const j = try ctx.pc_server.buildNotOwnerError();
                break :blk j;
            },
            error.ControlLeaseExpired => blk: {
                const j = try ctx.pc_server.buildLeaseExpiredError();
                break :blk j;
            },
            else => return err,
        };
    };
    return null; // forward success = no response to PC
}

// ── JSON 响应构建 ──

fn buildJsonRegisterOk(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(
        pc_server.allocator,
        "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"Register\"}},\"timestamp\":{d}}}\n",
        .{ts},
    );
}

fn buildControlGranted(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"ControlGranted\"}},\"timestamp\":{d}}}\n", .{ts});
}

fn buildControlDenied(pc_server: *PcServer, owner: ?[]const u8) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    if (owner) |o| {
        return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":1,\"msg\":\"busy\",\"body\":{{\"clazz\":\"ControlDenied\",\"owner\":\"{s}\"}},\"timestamp\":{d}}}\n", .{ o, ts });
    }
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":1,\"msg\":\"busy\",\"body\":{{\"clazz\":\"ControlDenied\"}},\"timestamp\":{d}}}\n", .{ts});
}

fn buildControlReleased(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"ControlReleased\"}},\"timestamp\":{d}}}\n", .{ts});
}

fn buildHeartbeatOk(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"Heartbeat\"}},\"timestamp\":{d}}}\n", .{ts});
}

fn buildHeartbeatDenied(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":1,\"msg\":\"not_owner\",\"body\":{{\"clazz\":\"HeartbeatDenied\"}},\"timestamp\":{d}}}\n", .{ts});
}

fn buildNoOwnerError(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":1,\"msg\":\"no_control_owner\",\"body\":{{\"clazz\":\"Error\"}},\"timestamp\":{d}}}\n", .{ts});
}

fn buildNotOwnerError(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":1,\"msg\":\"not_owner\",\"body\":{{\"clazz\":\"Error\"}},\"timestamp\":{d}}}\n", .{ts});
}

fn buildLeaseExpiredError(pc_server: *PcServer) ![]u8 {
    const ts = currentTimestamp(pc_server.io);
    return std.fmt.allocPrint(pc_server.allocator, "{{\"code\":1,\"msg\":\"lease_expired\",\"body\":{{\"clazz\":\"Error\"}},\"timestamp\":{d}}}\n", .{ts});
}
