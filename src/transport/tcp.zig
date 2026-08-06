const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// TCP 传输层状态，同时实现 AClient 和 CSender 接口。
///
/// 一个 TCP 连接既可以作为 A 端（PC 客户端），也可以作为 C 端（HW 设备），
/// 由上层决定调用 `initClient` / `initCSender` 中的哪一个（或都调用）。
pub const TcpConn = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    write_mutex: Io.Mutex = .init,
    id: []const u8,
    /// 是否已被 removeGroup 关闭，防止 double-close。
    stream_closed: bool = false,
    /// 嵌入的 AClient 接口（指针稳定，可传给 addAClient）
    client: AClient = undefined,
    /// 嵌入的 CSender 接口（指针稳定，可传给 setCSender）
    c_sender: CSender = undefined,

    /// 初始化嵌入的 AClient（传入 addAClient 时用 &self.client）
    pub fn initClient(self: *TcpConn) void {
        self.client = .{ .ptr = self, .vtable = &AClient.VTable{
            .send = aClientSend,
            .close = aClientClose,
        } };
    }

    /// 初始化嵌入的 CSender（传入 setCSender 时用 &self.c_sender）
    pub fn initCSender(self: *TcpConn) void {
        self.c_sender = .{ .ptr = self, .vtable = &CSender.VTable{
            .send = cSenderSend,
            .close = cSenderClose,
        } };
    }

    // ── AClient 实现：PC 客户端方向，发送时追加 '\n' 行分隔符 ──

    fn aClientSend(ptr: *anyopaque, io: Io, data: []const u8) !void {
        const self: *TcpConn = @ptrCast(@alignCast(ptr));
        try self.write_mutex.lock(io);
        defer self.write_mutex.unlock(io);
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        try writer.interface.writeAll(data);
        try writer.interface.writeByte('\n'); // TCP 行分隔符
        try writer.interface.flush();
    }

    fn aClientClose(ptr: *anyopaque, io: Io) void {
        const self: *TcpConn = @ptrCast(@alignCast(ptr));
        self.stream_closed = true;
        self.stream.close(io);
    }

    // ── CSender 实现：HW 设备方向，发送原始字节（无分隔符）──

    fn cSenderSend(ptr: *anyopaque, io: Io, data: []const u8) !void {
        const self: *TcpConn = @ptrCast(@alignCast(ptr));
        try self.write_mutex.lock(io);
        defer self.write_mutex.unlock(io);
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    fn cSenderClose(ptr: *anyopaque, io: Io) void {
        const self: *TcpConn = @ptrCast(@alignCast(ptr));
        self.stream_closed = true;
        self.stream.close(io);
    }
};

// ════════════════════════════════════════════════════════════════════
//  传输层接口（从 config/state.zig 移出，避免 config 依赖传输实现）
//  业务层通过这两个 vtable 接口与传输层解耦。
// ════════════════════════════════════════════════════════════════════

/// AClient：业务层向 A 端（PC 客户端）发送数据的抽象接口。
pub const AClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: Io, data: []const u8) anyerror!void,
        close: *const fn (ptr: *anyopaque, io: Io) void,
    };

    pub fn send(self: *const AClient, io: Io, data: []const u8) !void {
        return self.vtable.send(self.ptr, io, data);
    }

    pub fn close(self: *const AClient, io: Io) void {
        return self.vtable.close(self.ptr, io);
    }
};

/// CSender：业务层向 C 端（HW 设备）发送数据的抽象接口。
pub const CSender = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: Io, data: []const u8) anyerror!void,
        close: *const fn (ptr: *anyopaque, io: Io) void,
    };

    pub fn send(self: *CSender, io: Io, data: []const u8) !void {
        return self.vtable.send(self.ptr, io, data);
    }

    pub fn close(self: *CSender, io: Io) void {
        return self.vtable.close(self.ptr, io);
    }
};
