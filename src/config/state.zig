const std = @import("std");
const Io = std.Io;
const net = Io.net;
const currentTimestamp = @import("util.zig").currentTimestamp;

/// Lease duration for control rights (milliseconds).
pub const LEASE_DURATION_MS: i64 = 5000;

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
};

/// A group associates one HW device (C-side) with zero or more PC
/// control clients (A-side).
pub const Group = struct {
    a_clients: std.StringHashMap(*PcClientState),
    c_sender: *PcClientState,

    // Layer 1+2: Control rights with lease
    owner: ?[]const u8 = null,
    lease_expiry: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, c_sender: *PcClientState) Group {
        return .{
            .a_clients = std.StringHashMap(*PcClientState).init(allocator),
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

    /// Add a PC client to an existing HW group.
    pub fn addAClient(
        self: *GlobalState,
        io: Io,
        target_addr: []const u8,
        a_id: []const u8,
        client: *PcClientState,
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
        std.log.info("PC {s} -> hw {s}", .{ a_id, target_addr });
    }

    /// Remove a PC client from a specific HW group.
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

    /// Broadcast a pre-built JSON string to all PC clients in a group.
    /// 先收集客户端快照再释放锁，逐个无锁写入，避免持锁阻塞整个 GlobalState。
    pub fn broadcastToA(self: *GlobalState, io: Io, hw_addr: []const u8, json: []const u8) !void {
        // 1. 持锁收集客户端快照
        const clients = blk: {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const group = self.groups.get(hw_addr) orelse return;

            var list: std.ArrayList(*PcClientState) = .empty;
            var it = group.a_clients.iterator();
            while (it.next()) |entry| {
                try list.append(self.allocator, entry.value_ptr.*);
            }
            break :blk try list.toOwnedSlice(self.allocator);
        };
        defer self.allocator.free(clients);

        // 2. 无锁逐个写入（末尾加换行，支持 line-based 读取）
        var write_buf: [4096]u8 = undefined;
        for (clients) |client| {
            var writer = client.stream.writer(io, &write_buf);
            writer.interface.writeAll(json) catch |err| {
                std.log.warn("broadcastToA: write to {s} failed: {s}", .{ client.pc_id, @errorName(err) });
                continue;
            };
            writer.interface.writeByte('\n') catch continue;
            writer.interface.flush() catch continue;
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
    /// Closes all PC client streams in the group so they don't remain
    /// blocked on reads. The streams are closed *after* releasing the
    /// lock to avoid a deadlock with a PC client's deferred cleanup
    /// (which also acquires this lock).
    pub fn removeGroup(self: *GlobalState, io: Io, addr: []const u8) void {
        self.mutex.lock(io) catch |err| {
            std.log.warn("removeGroup: lock failed ({s}), group {s} may leak", .{ @errorName(err), addr });
            return;
        };

        // Collect PC client state pointers before freeing the group,
        // so we can close their streams outside the lock.
        var clients_to_close: [64]*PcClientState = undefined;
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

        // Close PC client streams (outside the lock) to unblock their
        // read loops, causing them to clean up naturally.
        // Set stream_closed = true first so the deferred cleanup in
        // handlePcClientInner won't double-close the stream.
        for (clients_to_close[0..clients_to_close_count]) |client| {
            client.stream_closed = true;
            client.stream.close(io);
        }
    }
};
