const std = @import("std");
const http_framework = @import("http_framework");

const GlobalState = @import("app_config").state.GlobalState;
const PcClientState = @import("app_config").state.PcClientState;
const types = @import("types.zig");

/// 创建一个 Handler，将 `*GlobalState` 注入到 handler 函数中。
///
/// 使用 `Handler` 的 VTable 多态机制，将 `handlerFn` 包装为 `handle` 回调，
/// 同时将 `state` 指针作为 `create` 的返回值（单例模式）。
pub fn makeHandler(
    comptime handlerFn: fn (*GlobalState, *http_framework.RequestContext, *http_framework.Response) anyerror!void,
    state: *GlobalState,
) http_framework.Handler {
    const VTable = struct {
        fn create(ctx: *anyopaque) anyerror!*anyopaque {
            return ctx;
        }
        fn handle(instance: *anyopaque, c: *http_framework.RequestContext, r: *http_framework.Response) anyerror!void {
            return handlerFn(@ptrCast(@alignCast(instance)), c, r);
        }
        fn destroy(_: *anyopaque, _: *anyopaque) void {}
    };
    return .{
        .ptr = @ptrCast(state),
        .vtable = &.{
            .create = VTable.create,
            .handle = VTable.handle,
            .destroy = VTable.destroy,
        },
    };
}

// ── Handler 函数 ─────────────────────────────────────────────────

/// GET /api/health
pub fn health(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    _ = state;
    _ = ctx;
    try types.jsonOk(res, types.HealthInfo{ .status = "ok" });
}

/// GET /api/stats
pub fn stats(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    var group_count: usize = 0;
    var hw_count: usize = 0;
    var client_count: usize = 0;
    var active_leases: usize = 0;

    var it = state.groups.iterator();
    while (it.next()) |entry| {
        group_count += 1;
        hw_count += 1; // 每个组有一个 HW 设备
        client_count += entry.value_ptr.*.a_clients.count();
        if (entry.value_ptr.*.owner != null) {
            active_leases += 1;
        }
    }

    try types.jsonOk(res, types.StatsInfo{
        .groups = group_count,
        .hw_devices = hw_count,
        .pc_clients = client_count,
        .active_leases = active_leases,
    });
}

/// GET /api/groups — 获取所有 HW 组列表
pub fn listGroups(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    var list = std.ArrayList(types.GroupInfo).empty;
    defer list.deinit(ctx.allocator);

    var it = state.groups.iterator();
    while (it.next()) |entry| {
        try list.append(ctx.allocator, .{
            .addr = entry.key_ptr.*,
            .client_count = entry.value_ptr.*.a_clients.count(),
            .owner = entry.value_ptr.*.owner,
            .lease_expiry = entry.value_ptr.*.lease_expiry,
        });
    }

    try types.jsonOk(res, list.items);
}

/// GET /api/groups/:addr — 获取单个 HW 组详情
pub fn getGroup(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };

    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    const group = state.groups.get(addr) orelse {
        try types.jsonError(res, .not_found, "group not found");
        return;
    };

    var client_list = std.ArrayList(types.ClientInfo).empty;
    defer client_list.deinit(ctx.allocator);

    var it = group.a_clients.iterator();
    while (it.next()) |entry| {
        try client_list.append(ctx.allocator, .{
            .id = entry.key_ptr.*,
            .hw_addr = addr,
        });
    }

    try types.jsonOk(res, types.GroupDetail{
        .addr = addr,
        .clients = try client_list.toOwnedSlice(ctx.allocator),
        .owner = group.owner,
        .lease_expiry = group.lease_expiry,
    });
}

/// DELETE /api/groups/:addr — 删除一个 HW 组
pub fn removeGroup(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };

    state.removeGroup(ctx.io, addr);
    try types.jsonOk(res, .{ .removed = true });
}

/// GET /api/groups/:addr/clients — 获取组内的 PC 客户端列表
pub fn listClients(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };

    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    const group = state.groups.get(addr) orelse {
        try types.jsonError(res, .not_found, "group not found");
        return;
    };

    var client_list = std.ArrayList(types.ClientInfo).empty;
    defer client_list.deinit(ctx.allocator);

    var it = group.a_clients.iterator();
    while (it.next()) |entry| {
        try client_list.append(ctx.allocator, .{
            .id = entry.key_ptr.*,
            .hw_addr = addr,
        });
    }

    try types.jsonOk(res, client_list.items);
}

/// DELETE /api/groups/:addr/clients/:id — 从组中移除一个 PC 客户端
pub fn removeClient(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };
    const client_id = ctx.getParam("id") orelse {
        try types.jsonError(res, .bad_request, "missing id parameter");
        return;
    };

    state.removeAClient(ctx.io, addr, client_id) catch {
        try types.jsonError(res, .not_found, "group not found");
        return;
    };
    try types.jsonOk(res, .{ .removed = true });
}

/// GET /api/groups/:addr/owner — 获取当前控制权所有者
pub fn getOwner(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };

    const owner = state.getOwner(ctx.io, addr) catch {
        try types.jsonError(res, .not_found, "group not found");
        return;
    };

    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    const group = state.groups.get(addr) orelse unreachable;
    try types.jsonOk(res, types.ControlInfo{
        .owner = owner,
        .lease_expiry = group.lease_expiry,
        .granted = null,
    });
}

/// POST /api/groups/:addr/control — 请求控制权
///
/// 请求体：`{ "pc_id": "..." }`
pub fn requestControl(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };

    // 解析请求体 JSON
    const body = try ctx.readBody();
    const parsed = try std.json.parseFromSlice(struct { pc_id: []const u8 }, ctx.allocator, body, .{});
    defer parsed.deinit();

    const granted = state.requestControl(ctx.io, addr, parsed.value.pc_id) catch {
        try types.jsonError(res, .not_found, "group not found");
        return;
    };

    try types.jsonOk(res, types.ControlResult{ .granted = granted });
}

/// DELETE /api/groups/:addr/control — 释放控制权
pub fn releaseControl(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };

    state.releaseControl(ctx.io, addr);
    try types.jsonOk(res, .{ .released = true });
}

/// GET /api/groups/:addr/owner — 查看控制权（简化版，不用锁两次）
pub fn getOwnerSimple(state: *GlobalState, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const addr = ctx.getParam("addr") orelse {
        try types.jsonError(res, .bad_request, "missing addr parameter");
        return;
    };

    try state.mutex.lock(ctx.io);
    defer state.mutex.unlock(ctx.io);

    const group = state.groups.get(addr) orelse {
        try types.jsonError(res, .not_found, "group not found");
        return;
    };

    try types.jsonOk(res, types.ControlInfo{
        .owner = group.owner,
        .lease_expiry = group.lease_expiry,
        .granted = null,
    });
}
