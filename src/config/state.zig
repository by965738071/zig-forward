const std = @import("std");
const Io = std.Io;
const net = Io.net;
const currentTimestamp = @import("util.zig").currentTimestamp;

/// Lease duration for control rights (milliseconds).
pub const LEASE_DURATION_MS: i64 = 5000;

// ════════════════════════════════════════════════════════════════════
//  AClient 接口：业务层与传输层之间的契约
// ════════════════════════════════════════════════════════════════════

/// AClient 是业务层（GlobalState/Group）向客户端发送数据的抽象接口。
/// 业务层不关心底层是 TCP、WebSocket、MQTT 还是其他协议。
/// 每加一种传输协议，只需要实现 send/close 两个函数，业务层零改动。
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

// ════════════════════════════════════════════════════════════════════
//  TCP 传输层实现
// ════════════════════════════════════════════════════════════════════

/// Per-connection state shared via GlobalState.
/// Used for both PC clients and HW connections.
pub const PcClientState = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    write_mutex: Io.Mutex = .init,
    pc_id: []const u8,
    /// Set to true when the stream has been closed by removeGroup.
    /// Used to prevent double-close with handlePcClientInner's defer block.
    stream_closed: bool = false,
    /// 嵌入的 AClient 接口（指针稳定，可传给 addAClient）
    client: AClient = undefined,

    /// 初始化嵌入的 AClient（传入 addAClient 时用 &self.client）
    pub fn initClient(self: *PcClientState) void {
        self.client = .{ .ptr = self, .vtable = &tcp_vtable };
    }

    /// 将此 TCP 客户端包装为 AClient 接口（临时值，不能取地址传）
    pub fn asClient(self: *PcClientState) AClient {
        return .{ .ptr = self, .vtable = &tcp_vtable };
    }

    fn tcpSend(ptr: *anyopaque, io: Io, data: []const u8) !void {
        const self: *PcClientState = @ptrCast(@alignCast(ptr));
        try self.write_mutex.lock(io);
        defer self.write_mutex.unlock(io);
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        try writer.interface.writeAll(data);
        try writer.interface.writeByte('\n'); // TCP 行分隔符
        try writer.interface.flush();
    }

    fn tcpClose(ptr: *anyopaque, io: Io) void {
        const self: *PcClientState = @ptrCast(@alignCast(ptr));
        self.stream_closed = true;
        self.stream.close(io);
    }

    const tcp_vtable = AClient.VTable{
        .send = tcpSend,
        .close = tcpClose,
    };
};

// ════════════════════════════════════════════════════════════════════
//  业务层
// ════════════════════════════════════════════════════════════════════

/// A group associates one HW device (C-side) with zero or more PC
/// control clients (A-side).
pub const Group = struct {
    /// a_clients 存储 *AClient 接口指针，不关心底层传输协议。
    /// TCP 客户端传 &PcClientState.asClient()，WS 客户端传 &WsClientState.client。
    a_clients: std.StringHashMap(*AClient),
    c_sender: *PcClientState,

    // Layer 1+2: Control rights with lease
    owner: ?[]const u8 = null,
    lease_expiry: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, c_sender: *PcClientState) Group {
        return .{
            .a_clients = std.StringHashMap(*AClient).init(allocator),
            .c_sender = c_sender,
            .owner = null,
            .lease_expiry = 0,
        };
    }

    pub fn deinit(self: *Group, allocator: std.mem.Allocator) void {
        var it = self.a_clients.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.a_clients.deinit();
        if (self.owner) |o| allocator.free(o);
    }
};

/// Thread-safe global state, protected by `Io.Mutex`.
pub const GlobalState = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    groups: std.StringHashMap(*Group),

    pub fn init(allocator: std.mem.Allocator) GlobalState {
        return .{
            .allocator = allocator,
            .groups = std.StringHashMap(*Group).init(allocator),
        };
    }

    pub fn deinit(self: *GlobalState) void {
        var it = self.groups.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.groups.deinit();
    }

    /// Register (or replace) a HW device (C-side).
    pub fn setCSender(self: *GlobalState, io: Io, addr: []const u8, sender: *PcClientState) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        if (self.groups.fetchRemove(addr)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }

        const key = try self.allocator.dupe(u8, addr);
        errdefer self.allocator.free(key);
        const group = try self.allocator.create(Group);
        errdefer {
            group.deinit(self.allocator);
            self.allocator.destroy(group);
        }
        group.* = Group.init(self.allocator, sender);
        try self.groups.put(key, group);
    }

    /// Add an A-side client to an existing HW group.
    /// client 是 *AClient 接口，TCP/WS/MQTT 客户端均可注册。
    pub fn addAClient(
        self: *GlobalState,
        io: Io,
        target_addr: []const u8,
        a_id: []const u8,
        client: *AClient,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const group_ptr = self.groups.get(target_addr) orelse {
            std.log.warn("hw not connected: {s}", .{target_addr});
            return error.HwNotConnected;
        };

        const key = try self.allocator.dupe(u8, a_id);
        errdefer self.allocator.free(key);
        try group_ptr.a_clients.put(key, client);
        std.log.info("A-client {s} -> hw {s}", .{ a_id, target_addr });
    }

    /// Remove an A-side client from a specific HW group.
    /// If the removed client was the control owner, control is released.
    pub fn removeAClient(self: *GlobalState, io: Io, target_addr: []const u8, a_id: []const u8) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const group = self.groups.get(target_addr) orelse return;

        if (group.a_clients.fetchRemove(a_id)) |kv| {
            self.allocator.free(kv.key);
        }

        if (group.owner) |o| {
            if (std.mem.eql(u8, o, a_id)) {
                self.allocator.free(o);
                group.owner = null;
                group.lease_expiry = 0;
            }
        }
    }

    /// Broadcast a pre-built JSON string to all A-side clients in a group.
    /// 先收集客户端快照再释放锁，逐个通过 AClient.send() 发送。
    /// 传输层细节（TCP 换行符、WS 帧格式）由各协议的 send 实现处理。
    pub fn broadcastToA(self: *GlobalState, io: Io, hw_addr: []const u8, json: []const u8) !void {
        // 1. 持锁收集客户端快照
        const clients = blk: {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const group = self.groups.get(hw_addr) orelse return;

            var list: std.ArrayList(*AClient) = .empty;
            var it = group.a_clients.iterator();
            while (it.next()) |entry| {
                try list.append(self.allocator, entry.value_ptr.*);
            }
            break :blk try list.toOwnedSlice(self.allocator);
        };
        defer self.allocator.free(clients);

        // 2. 无锁逐个发送（通过 AClient 接口，不关心底层协议）
        for (clients) |client| {
            client.send(io, json) catch |err| {
                std.log.warn("broadcastToA: send failed: {s}", .{@errorName(err)});
                continue;
            };
        }
    }

    /// Request control of a HW group (Layer 1+2).
    /// Returns `true` if control granted, `false` if already taken.
    /// Automatically releases expired leases.
    pub fn requestControl(self: *GlobalState, io: Io, target_addr: []const u8, pc_id: []const u8) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const group = self.groups.get(target_addr) orelse return error.HwNotConnected;

        if (group.owner) |o| {
            if (currentTimestamp(io) < group.lease_expiry) {
                return false;
            }
            self.allocator.free(o);
            group.owner = null;
            group.lease_expiry = 0;
        }

        group.owner = try self.allocator.dupe(u8, pc_id);
        group.lease_expiry = currentTimestamp(io) + LEASE_DURATION_MS;
        return true;
    }

    /// Release control of a HW group (Layer 1).
    pub fn releaseControl(self: *GlobalState, io: Io, target_addr: []const u8) void {
        self.mutex.lock(io) catch |err| {
            std.log.warn("releaseControl: lock failed ({s}), target {s}", .{ @errorName(err), target_addr });
            return;
        };
        defer self.mutex.unlock(io);

        const group = self.groups.get(target_addr) orelse return;
        if (group.owner) |o| {
            self.allocator.free(o);
            group.owner = null;
        }
        group.lease_expiry = 0;
    }

    /// Heartbeat — renew lease for the current owner (Layer 2).
    /// Returns `true` if accepted, `false` if caller is not the owner.
    pub fn heartbeat(self: *GlobalState, io: Io, target_addr: []const u8, pc_id: []const u8) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const group = self.groups.get(target_addr) orelse return error.HwNotConnected;

        if (group.owner) |o| {
            if (std.mem.eql(u8, o, pc_id)) {
                group.lease_expiry = currentTimestamp(io) + LEASE_DURATION_MS;
                return true;
            }
        }
        return false;
    }

    /// Get the current owner's pc_id for a group.
    pub fn getOwner(self: *GlobalState, io: Io, target_addr: []const u8) !?[]const u8 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const group = self.groups.get(target_addr) orelse return error.HwNotConnected;

        if (group.owner) |o| {
            if (currentTimestamp(io) >= group.lease_expiry) {
                self.allocator.free(o);
                group.owner = null;
                group.lease_expiry = 0;
            }
        }

        return group.owner;
    }

    /// Forward a message from a PC client to the HW device.
    pub fn sendToC(self: *GlobalState, io: Io, target_addr: []const u8, msg: []const u8) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const group = self.groups.get(target_addr) orelse return error.HwNotConnected;

        const hw = group.c_sender;
        try hw.write_mutex.lock(io);
        defer hw.write_mutex.unlock(io);

        var write_buf: [4096]u8 = undefined;
        var writer = hw.stream.writer(io, &write_buf);
        const w = &writer.interface;
        try w.writeAll(msg);
        try w.flush();
    }

    /// Remove an entire HW group (when the HW device disconnects).
    /// Closes all A-side client connections through AClient.close().
    /// The close is done *after* releasing the lock to avoid deadlock.
    pub fn removeGroup(self: *GlobalState, io: Io, addr: []const u8) void {
        self.mutex.lock(io) catch |err| {
            std.log.warn("removeGroup: lock failed ({s}), group {s} may leak", .{ @errorName(err), addr });
            return;
        };

        // Collect AClient pointers before freeing the group,
        // so we can close them outside the lock.
        var clients_to_close: [64]*AClient = undefined;
        var clients_to_close_count: usize = 0;

        if (self.groups.fetchRemove(addr)) |kv| {
            var it = kv.value.a_clients.iterator();
            while (it.next()) |entry| {
                if (clients_to_close_count < clients_to_close.len) {
                    clients_to_close[clients_to_close_count] = entry.value_ptr.*;
                    clients_to_close_count += 1;
                }
            }
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }

        self.mutex.unlock(io);

        // 通过 AClient.close() 关闭所有客户端连接（不关心传输协议）
        // TCP 实现会设置 stream_closed=true 并关闭 stream，触发 PC 端的 defer 清理
        // WS 实现是空操作，WS 生命周期由 websocket 库管理
        for (clients_to_close[0..clients_to_close_count]) |client| {
            client.close(io);
        }
    }
};
