const std = @import("std");
const Io = std.Io;

const cfg = @import("app_config");
const ConfigType = cfg.ConfigType;
const GlobalState = cfg.state.GlobalState;
const PcServer = @import("pc_server").pc_server.PcServer;
const HwServer = @import("hw_server").hw_server.HwServer;
const ByteParser = @import("parser").byte_parser.ByteParser;
const JsonLineParser = @import("parser").json_parser.JsonLineParser;
const ws_server = @import("ws_server");
const util = @import("util");
const handlers = @import("handlers");

// 暴露 config 模块（config/root.zig）给测试/benchmark
pub const config = cfg;

/// 应用组装：持有三个服务器 + 共享状态。
/// Server 均为非泛型，parser 通过 factory 注入——新增协议只需提供新 Factory。
pub const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: ConfigType,
    state: GlobalState,
    pc_server: PcServer,
    hw_server: HwServer,
    ws_app: ws_server.App,

    pub fn create(allocator: std.mem.Allocator, io: Io, cfg_value: ConfigType) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .config = cfg_value,
            .state = GlobalState.init(allocator),
            .pc_server = PcServer.init(allocator, &self.state, io, cfg_value, ByteParser.create),
            .hw_server = HwServer.init(allocator, &self.state, io, cfg_value.hw.host, cfg_value.hw.port, JsonLineParser.create),
            .ws_app = ws_server.App.init(allocator, io, &self.state),
        };
        errdefer self.deinitFields();

        // 注册 PC 命令（业务 handler 来自 handlers 模块）
        for (handlers.pc.commands) |cmd| {
            try self.pc_server.registerCommand(cmd.id, cmd.handler);
        }
        // 注册 HW 命令
        for (handlers.hw.commands) |cmd| {
            try self.hw_server.registerCommand(cmd.id, cmd.handler);
        }
        if (handlers.hw.default_handler) |h| {
            self.hw_server.setDefault(h);
        }

        return self;
    }

    fn deinitFields(self: *App) void {
        self.ws_app.deinit();
        self.hw_server.deinit();
        self.pc_server.deinit();
        self.state.deinit();
    }

    pub fn deinit(self: *App) void {
        self.deinitFields();
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        const rc = &self.config;
        std.log.info("Zig Forward starting: PC:{s}:{d}  HW:{s}:{d}  WS:{s}:{d}", .{ rc.pc.host, rc.pc.port, rc.hw.host, rc.hw.port, rc.ws.host, rc.ws.port });

        var group: std.Io.Group = .init;

        group.async(self.io, struct {
            fn run(app: *App) void {
                app.pc_server.start() catch |err| switch (err) {
                    error.Canceled => {},
                    else => std.log.err("PC server exited: {}", .{err}),
                };
            }
        }.run, .{self});

        group.async(self.io, struct {
            fn run(app: *App) void {
                app.hw_server.start() catch |err| switch (err) {
                    error.Canceled => {},
                    else => std.log.err("HW server exited: {}", .{err}),
                };
            }
        }.run, .{self});

        group.async(self.io, struct {
            fn run(app: *App) void {
                ws_server.startWithApp(&app.ws_app, app.config.ws.host, app.config.ws.port) catch |err| std.log.err("WS server exited: {}", .{err});
            }
        }.run, .{self});

        std.log.info("Server started. Press Ctrl+C to stop.", .{});
        util.waitForShutdown(self.io);

        std.log.info("Shutting down...", .{});
        self.ws_app.stop();
        group.cancel(self.io);

        self.pc_server.handler_group.cancel(self.io);
        self.hw_server.handler_group.cancel(self.io);

        // 等待所有协程实际退出，避免端口/连接在进程退出前仍未释放。
        // group.cancel 是异步的（发信号不等待），若无 await，run() 返回后
        // main 退出、进程被 OS 回收——正常情况可行，但若某协程卡在不可取消
        // 的阻塞点（如第三方 websocket listen），会导致端口残留。
        try group.await(self.io);
        try self.pc_server.handler_group.await(self.io);
        try self.hw_server.handler_group.await(self.io);
        std.log.info("all handler exit", .{});
        try self.state.closeAllGroups(self.io);
    }
};
