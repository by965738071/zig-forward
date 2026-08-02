const std = @import("std");
const http_framework = @import("http_framework");

/// 发送成功 JSON 响应
pub fn jsonOk(res: *http_framework.Response, data: anytype) !void {
    try res.json(.{ .success = true, .data = data });
}

/// 发送错误 JSON 响应（带 HTTP 状态码）
pub fn jsonError(res: *http_framework.Response, status: std.http.Status, msg: []const u8) !void {
    _ = res.statusCode(status);
    try res.json(.{ .success = false, .message = msg });
}

// ── API 响应类型 ─────────────────────────────────────────────────

/// 健康检查响应
pub const HealthInfo = struct {
    status: []const u8,
};

/// 服务器统计信息
pub const StatsInfo = struct {
    groups: usize,
    hw_devices: usize,
    pc_clients: usize,
    active_leases: usize,
};

/// 组列表中的单个组信息
pub const GroupInfo = struct {
    addr: []const u8,
    client_count: usize,
    owner: ?[]const u8,
    lease_expiry: i64,
};

/// 组的详细信息（含客户端列表）
pub const GroupDetail = struct {
    addr: []const u8,
    clients: []const ClientInfo,
    owner: ?[]const u8,
    lease_expiry: i64,
};

/// PC 客户端信息
pub const ClientInfo = struct {
    id: []const u8,
    hw_addr: []const u8,
};

/// 控制权信息
pub const ControlInfo = struct {
    owner: ?[]const u8,
    lease_expiry: i64,
    granted: ?bool,
};

/// 控制权请求结果
pub const ControlResult = struct {
    granted: bool,
};
