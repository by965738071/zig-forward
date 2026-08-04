const std = @import("std");
const AClient = @import("tcp.zig").AClient;

/// WebSocket 客户端的 AClient 实现（仅 A 端，WS 不作为 C 端/HW 设备）。
///
/// 由 ws_server.Handler 创建并拥有，通过 `&state.client` 注册到 Group.a_clients。
pub const WsConn = struct {
    conn: *ws.Conn,
    allocator: std.mem.Allocator,
    pc_id: []const u8,
    client: AClient,

    pub fn init(self: *WsConn, conn: *ws.Conn, allocator: std.mem.Allocator, pc_id: []const u8) void {
        self.* = .{
            .conn = conn,
            .allocator = allocator,
            .pc_id = pc_id,
            .client = .{ .ptr = self, .vtable = &ws_vtable },
        };
    }

    fn wsSend(ptr: *anyopaque, io: std.Io, data: []const u8) !void {
        _ = io;
        const self: *WsConn = @ptrCast(@alignCast(ptr));
        try self.conn.writeText(data);
    }

    fn wsClose(ptr: *anyopaque, io: std.Io) void {
        _ = ptr;
        _ = io;
        // WS 连接生命周期由 websocket 库管理，无需额外操作
    }

    const ws_vtable = AClient.VTable{
        .send = wsSend,
        .close = wsClose,
    };
};

const ws = @import("websocket");
