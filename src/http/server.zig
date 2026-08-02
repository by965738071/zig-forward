const std = @import("std");
const http_framework = @import("http_framework");
const GlobalState = @import("app_config").state.GlobalState;
const handlers = @import("handlers.zig");

/// 创建并配置 API 路由，绑定 GlobalState。
pub fn setupRoutes(allocator: std.mem.Allocator, state: *GlobalState) !http_framework.Router {
    var router = http_framework.Router.init(allocator);
    errdefer router.deinit();

    // ── 健康检查 ──
    try router.route(.GET, "/api/health", handlers.makeHandler(handlers.health, state));

    // ── 服务器统计 ──
    try router.route(.GET, "/api/stats", handlers.makeHandler(handlers.stats, state));

    // ── HW 组管理 ──
    try router.route(.GET, "/api/groups", handlers.makeHandler(handlers.listGroups, state));
    try router.route(.GET, "/api/groups/:addr", handlers.makeHandler(handlers.getGroup, state));
    try router.route(.DELETE, "/api/groups/:addr", handlers.makeHandler(handlers.removeGroup, state));

    // ── PC 客户端管理 ──
    try router.route(.GET, "/api/groups/:addr/clients", handlers.makeHandler(handlers.listClients, state));
    try router.route(.DELETE, "/api/groups/:addr/clients/:id", handlers.makeHandler(handlers.removeClient, state));

    // ── 控制权管理 ──
    try router.route(.GET, "/api/groups/:addr/owner", handlers.makeHandler(handlers.getOwnerSimple, state));
    try router.route(.POST, "/api/groups/:addr/control", handlers.makeHandler(handlers.requestControl, state));
    try router.route(.DELETE, "/api/groups/:addr/control", handlers.makeHandler(handlers.releaseControl, state));

    // ── 兼容旧版 /health ──
    try router.route(.GET, "/health", handlers.makeHandler(handlers.health, state));

    return router;
}

/// 启动 HTTP 服务器（阻塞直到服务器关闭）。
///
/// 所有权说明：
/// - `router` 会被移入 Server，函数返回前自动释放。
pub fn start(allocator: std.mem.Allocator, io: std.Io, address: []const u8, port: u16, router: http_framework.Router) void {
    const config = http_framework.Config{
        .address = address,
        .port = port,
        .server_name = "ZigForward",
        .access_log_enabled = false,
        .idle_timeout_ns = 30_000_000_000,
    };
    var server = http_framework.Server.init(allocator, io, config, router) catch |err| {
        std.log.err("HTTP server init failed: {}", .{err});
        return;
    };
    defer {
        server.deinit();
        server.router.deinit();
    }
    server.run() catch |err| {
        std.log.err("HTTP server exited: {}", .{err});
    };
}
