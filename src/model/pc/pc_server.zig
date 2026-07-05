const std = @import("std");
const Io = std.Io;
const net = Io.net;

const GlobalState = @import("../../config/state.zig").GlobalState;
const PcClientState = @import("../../config/state.zig").PcClientState;

const readLine = @import("../../config/util.zig").readLine;
const currentTimestamp = @import("../../config/util.zig").currentTimestamp;
const parseCommand = @import("common_request.zig").parseCommand;

/// PC 控制端 TCP 服务。
///
/// 每个连接由单个 Io.concurrent 任务处理。
/// 命令读取、处理、响应全部同步完成。
/// 硬件广播通过 GlobalState.broadcastToA 直接写入 PC socket。
allocator: std.mem.Allocator,
state: *GlobalState,
io: Io,
host: []const u8,
port: u16,

pub const PcServer = @This();

pub fn init(allocator: std.mem.Allocator, state: *GlobalState, io: Io, host: []const u8, port: u16) PcServer {
    return .{
        .allocator = allocator,
        .state = state,
        .io = io,
        .host = host,
        .port = port,
    };
}

pub fn start(self: *PcServer) !void {
    const addr = try net.IpAddress.parseIp4(self.host, self.port);
    var server = try addr.listen(self.io, .{});
    defer server.deinit(self.io);

    std.log.info("PC server listening on {s}:{d}", .{ self.host, self.port });

    while (true) {
        const stream = try server.accept(self.io);
        const peer_id = try std.fmt.allocPrint(self.allocator, "{}", .{stream.socket.address});
        std.log.info("PC client {s} connected", .{peer_id});

        _ = Io.concurrent(self.io, handlePcClient, .{ self, stream, peer_id }) catch |err| {
            self.allocator.free(peer_id);
            stream.close(self.io);
            std.log.err("spawn PC handler: {}", .{err});
            continue;
        };
    }
}

fn handlePcClient(pc_server: *PcServer, stream: net.Stream, pc_id: []const u8) void {
    defer pc_server.allocator.free(pc_id);

    handlePcClientInner(pc_server, stream, pc_id) catch |err| {
        std.log.info("PC {s} disconnected ({s})", .{ pc_id, @errorName(err) });
    };
}

fn handlePcClientInner(pc_server: *PcServer, stream: net.Stream, pc_id: []const u8) !void {
    const allocator = pc_server.allocator;
    const io = pc_server.io;
    const state = pc_server.state;

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
        const owned = try readLine(reader, allocator);
        defer allocator.free(owned);

        const cmd = try parseCommand(owned, allocator);
        defer {
            if (cmd == .register) allocator.free(cmd.register.target_addr);
            if (cmd == .forward) allocator.free(cmd.forward.target_addr);
        }

        switch (cmd) {
            .register => |reg| {
                if (!first) return error.DuplicateRegister;
                first = false;

                try state.addAClient(io, reg.target_addr, pc_id, client_state);

                target_addr = try allocator.dupe(u8, reg.target_addr);
                std.log.info("PC {s} registered to {s}", .{ pc_id, target_addr.? });

                const json = try buildJsonRegisterOk(allocator, io);
                defer allocator.free(json);
                try writer.writeAll(json);
                try writer.flush();
            },

            .forward => {
                if (first) return error.NotRegistered;
                const addr = target_addr orelse return error.NotRegistered;
                try state.sendToC(io, addr, owned);
            },
        }
    }
}

// ── JSON 响应构建 ──

fn buildJsonRegisterOk(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const ts = currentTimestamp(io);
    return std.fmt.allocPrint(
        allocator,
        "{{\"code\":0,\"msg\":\"ok\",\"body\":{{\"clazz\":\"Register\"}},\"timestamp\":{d}}}\n",
        .{ts},
    );
}
