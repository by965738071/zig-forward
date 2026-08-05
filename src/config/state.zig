const std = @import("std");
const Io = std.Io;
const AClient = @import("transport").tcp.AClient;
const CSender = @import("transport").tcp.CSender;
const currentTimestamp = @import("util.zig").currentTimestamp;

/// Lease duration for control rights (milliseconds).
pub const LEASE_DURATION_MS: i64 = 5000;

// ════════════════════════════════════════════════════════════════════
//  业务层：Group / GlobalState
//  传输层细节（TCP/WS）通过 AClient / CSender 接口隔离，定义在 transport/ 模块。
// ════════════════════════════════════════════════════════════════════

/// A group associates one HW device (C-side) with zero or more PC
/// control clients (A-side).
pub const Group = struct {
    /// a_clients 存储 *AClient 接口指针，不关心底层传输协议。
    a_clients: std.StringHashMap(*AClient),
    /// c_sender 是向 HW 设备（C 端）发送数据的接口，不关心底层传输协议。
    c_sender: *CSender,

    // Layer 1+2: Control rights with lease
    owner: ?[]const u8 = null,
    lease_expiry: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, c_sender: *CSender) Group {
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
    pub fn setCSender(self: *GlobalState, io: Io, addr: []const u8, sender: *CSender) !void {
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
    /// 持锁遍历并发送：客户端（*AClient）由各自的 handler 拥有，可能在锁外被
    /// disconnect 的 defer 块释放。若先做指针快照再解锁逐个发送，解锁后指针
    /// 可能已 use-after-free。本地硬件管理规模下，在锁内发送（与 sendToC 一致）。
    /// 传输层细节（TCP 换行符、WS 帧格式）由各协议的 send 实现处理。
    pub fn broadcastToA(self: *GlobalState, io: Io, hw_addr: []const u8, json: []const u8) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const group = self.groups.get(hw_addr) orelse return;

        var it = group.a_clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr.*;
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
    pub fn releaseControl(self: *GlobalState, io: Io, target_addr: []const u8) !void {
        try self.mutex.lock(io);
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
        try group.c_sender.send(io, msg);
    }

    /// Remove an entire HW group (when the HW device disconnects).
    /// Closes both A-side and C-side connections through their respective interfaces.
    /// The close is done *after* releasing the lock to avoid deadlock.
    pub fn removeGroup(self: *GlobalState, io: Io, addr: []const u8) void {
        self.mutex.lock(io) catch |err| {
            std.log.warn("removeGroup: lock failed ({s}), group {s} may leak", .{ @errorName(err), addr });
            return;
        };

        // 动态收集 AClient/CSender 指针，避免固定数组容量上限
        var clients_to_close: std.ArrayList(*AClient) = .empty;
        defer clients_to_close.deinit(self.allocator);
        var c_sender_to_close: ?*CSender = null;

        if (self.groups.fetchRemove(addr)) |kv| {
            var it = kv.value.a_clients.iterator();
            while (it.next()) |entry| {
                clients_to_close.append(self.allocator, entry.value_ptr.*) catch continue;
            }
            c_sender_to_close = kv.value.c_sender;
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }

        self.mutex.unlock(io);

        // 关闭 C-side（HW）连接 — 解阻塞 handler 线程的 parser.parse()
        if (c_sender_to_close) |s| {
            s.close(io);
        }

        // 通过 AClient.close() 关闭所有客户端连接（不关心传输协议）
        for (clients_to_close.items) |client| {
            client.close(io);
        }
    }

    /// 关闭所有 HW 组（关机时调用，解阻塞所有 handler 线程）。
    pub fn closeAllGroups(self: *GlobalState, io: Io) !void {
        try self.mutex.lock(io);
        var addrs: std.ArrayList([]const u8) = .empty;
        var it = self.groups.iterator();
        while (it.next()) |entry| {
            try addrs.append(self.allocator, entry.key_ptr.*);
        }
        self.mutex.unlock(io);
        defer addrs.deinit(self.allocator);

        for (addrs.items) |addr| {
            self.removeGroup(io, addr);
        }
    }
};
