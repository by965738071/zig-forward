const std = @import("std");
const ws = @import("websocket");
const GlobalState = @import("app_config").state.GlobalState;
const AClient = @import("app_config").state.AClient;

/// WebSocket 应用上下文，传递给每个 Handler
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *GlobalState,
    /// 指向堆分配的 ws.Server，用于 stop() 时关闭
    ws_server: ?*ws.Server(Handler) = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, state: *GlobalState) App {
        return .{
            .allocator = allocator,
            .io = io,
            .state = state,
        };
    }

    /// 停止 WebSocket 服务器（仅发信号，不销毁资源）。
    /// 销毁由 deinit() 在 await() 之后执行。
    pub fn stop(self: *App) void {
        if (self.ws_server) |s| {
            s.stop();
        }
    }

    pub fn deinit(self: *App) void {
        if (self.ws_server) |s| {
            s.deinit();
            self.allocator.destroy(s);
            self.ws_server = null;
        }
    }
};

// ════════════════════════════════════════════════════════════════════
//  WebSocket 传输层实现（AClient 接口）
// ════════════════════════════════════════════════════════════════════

/// WebSocket 客户端的 AClient 实现。
/// 由 Handler 创建并拥有，通过 `&state.client` 注册到 Group.a_clients。
pub const WsClientState = struct {
    conn: *ws.Conn,
    allocator: std.mem.Allocator,
    pc_id: []const u8,
    client: AClient,

    pub fn init(self: *WsClientState, conn: *ws.Conn, allocator: std.mem.Allocator, pc_id: []const u8) void {
        self.* = .{
            .conn = conn,
            .allocator = allocator,
            .pc_id = pc_id,
            .client = .{ .ptr = self, .vtable = &ws_vtable },
        };
    }

    fn wsSend(ptr: *anyopaque, io: std.Io, data: []const u8) !void {
        _ = io;
        const self: *WsClientState = @ptrCast(@alignCast(ptr));
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

// ════════════════════════════════════════════════════════════════════
//  WebSocket 连接 Handler（公开，因为 ws.Server(Handler) 需要类型可见）
// ════════════════════════════════════════════════════════════════════

/// 单个 WebSocket 连接的 Handler
pub const Handler = struct {
    app: *App,
    conn: *ws.Conn,
    pc_id: []const u8,
    /// 该连接注册的 HW 地址列表（用于在 clientClose 时统一清理）
    registered_hw: std.StringHashMap(void) = undefined,
    /// WebSocket 传输层状态（嵌入 AClient，注册到 Group.a_clients）
    ws_state: *WsClientState,

    pub fn init(h: *ws.Handshake, conn: *ws.Conn, app: *App) !Handler {
        _ = h;
        const pc_id = try std.fmt.allocPrint(app.allocator, "ws:{*}", .{conn});
        errdefer app.allocator.free(pc_id);

        const ws_state = try app.allocator.create(WsClientState);
        errdefer app.allocator.destroy(ws_state);
        ws_state.init(conn, app.allocator, pc_id);

        return .{
            .app = app,
            .conn = conn,
            .pc_id = pc_id,
            .registered_hw = std.StringHashMap(void).init(app.allocator),
            .ws_state = ws_state,
        };
    }

    pub fn clientClose(self: *Handler, data: []const u8) !void {
        _ = data;
        var it = self.registered_hw.iterator();
        while (it.next()) |entry| {
            self.app.state.removeAClient(self.app.io, entry.key_ptr.*, self.pc_id) catch {};
            self.app.allocator.free(entry.key_ptr.*);
        }
        self.registered_hw.deinit();
        self.app.allocator.destroy(self.ws_state);
        self.app.allocator.free(self.pc_id);
    }

    pub fn clientMessage(self: *Handler, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.app.allocator, data, .{}) catch |err| {
            std.log.warn("ws: invalid json: {s}", .{@errorName(err)});
            try self.conn.writeText("{\"error\":\"invalid json\"}");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const clazz = root.object.get("clazz") orelse {
            try self.conn.writeText("{\"error\":\"missing clazz\"}");
            return;
        };

        if (std.mem.eql(u8, clazz.string, "Register")) {
            try self.handleRegister(root);
        } else if (std.mem.eql(u8, clazz.string, "Unregister")) {
            try self.handleUnregister(root);
        } else if (std.mem.eql(u8, clazz.string, "SendToHw")) {
            try self.handleSendToHw(root);
        } else if (std.mem.eql(u8, clazz.string, "RequestControl")) {
            try self.handleRequestControl(root);
        } else if (std.mem.eql(u8, clazz.string, "ReleaseControl")) {
            try self.handleReleaseControl(root);
        } else if (std.mem.eql(u8, clazz.string, "Heartbeat")) {
            try self.handleHeartbeat(root);
        } else if (std.mem.eql(u8, clazz.string, "GetStatus")) {
            try self.handleGetStatus();
        } else {
            try self.conn.writeText("{\"error\":\"unknown clazz\"}");
        }
    }

    fn handleRegister(self: *Handler, root: std.json.Value) !void {
        const target_addr = root.object.get("target_addr") orelse {
            try self.conn.writeText("{\"error\":\"missing target_addr\"}");
            return;
        };

        const addr = try self.app.allocator.dupe(u8, target_addr.string);
        errdefer self.app.allocator.free(addr);

        // 通过 AClient 接口注册到 Group.a_clients，HW 的广播会通过 wsSend 推送过来
        try self.app.state.addAClient(self.app.io, addr, self.pc_id, &self.ws_state.client);
        try self.registered_hw.put(addr, {});

        try self.conn.writeText("{\"clazz\":\"Register\",\"status\":\"ok\"}");
    }

    fn handleUnregister(self: *Handler, root: std.json.Value) !void {
        const target_addr = root.object.get("target_addr") orelse {
            try self.conn.writeText("{\"error\":\"missing target_addr\"}");
            return;
        };

        if (self.registered_hw.fetchRemove(target_addr.string)) |kv| {
            self.app.state.removeAClient(self.app.io, target_addr.string, self.pc_id) catch {};
            self.app.allocator.free(kv.key);
            try self.conn.writeText("{\"clazz\":\"Unregister\",\"status\":\"ok\"}");
        } else {
            try self.conn.writeText("{\"clazz\":\"Unregister\",\"status\":\"not_registered\"}");
        }
    }

    fn handleSendToHw(self: *Handler, root: std.json.Value) !void {
        const target_addr = root.object.get("target_addr") orelse {
            try self.conn.writeText("{\"error\":\"missing target_addr\"}");
            return;
        };
        const data_val = root.object.get("data") orelse {
            try self.conn.writeText("{\"error\":\"missing data\"}");
            return;
        };

        self.app.state.sendToC(self.app.io, target_addr.string, data_val.string) catch |err| {
            const msg = std.fmt.allocPrint(self.app.allocator, "{{\"clazz\":\"SendToHw\",\"status\":\"error\",\"msg\":\"{s}\"}}", .{@errorName(err)}) catch unreachable;
            defer self.app.allocator.free(msg);
            try self.conn.writeText(msg);
            return;
        };

        try self.conn.writeText("{\"clazz\":\"SendToHw\",\"status\":\"ok\"}");
    }

    fn handleRequestControl(self: *Handler, root: std.json.Value) !void {
        const target_addr = root.object.get("target_addr") orelse {
            try self.conn.writeText("{\"error\":\"missing target_addr\"}");
            return;
        };
        const pc_id = root.object.get("pc_id") orelse {
            try self.conn.writeText("{\"error\":\"missing pc_id\"}");
            return;
        };

        const result = self.app.state.requestControl(self.app.io, target_addr.string, pc_id.string) catch |err| {
            const msg = std.fmt.allocPrint(self.app.allocator, "{{\"clazz\":\"RequestControl\",\"status\":\"error\",\"msg\":\"{s}\"}}", .{@errorName(err)}) catch unreachable;
            defer self.app.allocator.free(msg);
            try self.conn.writeText(msg);
            return;
        };

        if (result) {
            try self.conn.writeText("{\"clazz\":\"RequestControl\",\"status\":\"granted\"}");
        } else {
            try self.conn.writeText("{\"clazz\":\"RequestControl\",\"status\":\"denied\"}");
        }
    }

    fn handleReleaseControl(self: *Handler, root: std.json.Value) !void {
        const target_addr = root.object.get("target_addr") orelse {
            try self.conn.writeText("{\"error\":\"missing target_addr\"}");
            return;
        };

        self.app.state.releaseControl(self.app.io, target_addr.string);
        try self.conn.writeText("{\"clazz\":\"ReleaseControl\",\"status\":\"ok\"}");
    }

    fn handleHeartbeat(self: *Handler, root: std.json.Value) !void {
        const target_addr = root.object.get("target_addr") orelse {
            try self.conn.writeText("{\"error\":\"missing target_addr\"}");
            return;
        };
        const pc_id = root.object.get("pc_id") orelse {
            try self.conn.writeText("{\"error\":\"missing pc_id\"}");
            return;
        };

        const result = self.app.state.heartbeat(self.app.io, target_addr.string, pc_id.string) catch |err| {
            const msg = std.fmt.allocPrint(self.app.allocator, "{{\"clazz\":\"Heartbeat\",\"status\":\"error\",\"msg\":\"{s}\"}}", .{@errorName(err)}) catch unreachable;
            defer self.app.allocator.free(msg);
            try self.conn.writeText(msg);
            return;
        };

        if (result) {
            try self.conn.writeText("{\"clazz\":\"Heartbeat\",\"status\":\"renewed\"}");
        } else {
            try self.conn.writeText("{\"clazz\":\"Heartbeat\",\"status\":\"not_owner\"}");
        }
    }

    fn handleGetStatus(self: *Handler) !void {
        try self.conn.writeText("{\"clazz\":\"GetStatus\",\"status\":\"ok\"}");
    }
};

/// 启动 WebSocket 服务器（阻塞调用，需放在 Io.async 中运行）。
/// 服务器实例存储在 app.ws_server 中，可通过 app.stop() 停止。
pub fn startWithApp(app: *App, host: []const u8, port: u16) !void {
    const server = try app.allocator.create(ws.Server(Handler));
    errdefer app.allocator.destroy(server);
    server.* = try ws.Server(Handler).init(app.io, app.allocator, .{
        .port = port,
        .address = host,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 0,
        },
    });

    app.ws_server = server;
    std.log.info("WebSocket server listening on {s}:{d}", .{ host, port });
    try server.listen(app);
}

/// 启动 WebSocket 服务器（阻塞调用，需放在 Io.async 中运行）
pub fn start(io: std.Io, allocator: std.mem.Allocator, state: *GlobalState, host: []const u8, port: u16) !void {
    var app = App.init(allocator, io, state);
    defer app.deinit();
    try startWithApp(&app, host, port);
}
