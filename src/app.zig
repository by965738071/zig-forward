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

// 暴露 config 模块（config/root.zig）给测试/benchmark：通过 `@import("app").config.*` 访问。
pub const config = cfg;

/// 应用组装：持有三个服务器 + 共享状态，负责启动 / 停止 / 等待关闭。
/// main.zig 只负责：解析 CLI → 构造 App → run()。
pub const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// 运行时配置（含命令路由表）。切片数据由 main 的 runtime_config 持有，
    /// 生命周期覆盖整个 App（main 的 defer 顺序保证 config 后释放）。
    config: ConfigType,
    state: GlobalState,
    pc_server: PcServer(u8, ByteParser()),
    hw_server: HwServer([]const u8, JsonLineParser([]const u8)),
    ws_app: ws_server.App,

    pub fn init(allocator: std.mem.Allocator, io: Io, cfg_ptr: *const ConfigType) !App {
        var app: App = undefined;
        app.allocator = allocator;
        app.io = io;
        app.config = cfg_ptr.*;

        app.state = GlobalState.init(allocator);
        errdefer app.state.deinit();

        app.pc_server = PcServer(u8, ByteParser()).init(allocator, &app.state, io, app.config);
        errdefer app.pc_server.deinit();
        for (cfg_ptr.commands) |cmd| {
            try app.pc_server.registerCommand(cmd.id, cmd.handler);
        }

        app.hw_server = HwServer([]const u8, JsonLineParser([]const u8))
            .init(allocator, &app.state, io, cfg_ptr.hw.host, cfg_ptr.hw.port);
        errdefer app.hw_server.deinit();
        for (cfg_ptr.hw_commands) |cmd| {
            try app.hw_server.registerCommand(cmd.name, cmd.handler);
        }
        if (cfg_ptr.hw_default_handler) |h| {
            app.hw_server.setDefault(h);
        }

        app.ws_app = ws_server.App.init(allocator, io, &app.state);
        errdefer app.ws_app.deinit();

        return app;
    }

    pub fn deinit(self: *App) void {
        self.ws_app.deinit();
        self.hw_server.deinit();
        self.pc_server.deinit();
        self.state.deinit();
    }

    /// 启动三个服务器并阻塞等待关闭信号（Ctrl+C / SIGTERM）。
    /// 收到信号后优雅关闭所有服务器，等待协程退出。
    pub fn run(self: *App) void {
        const rc = &self.config;
        std.log.info("Zig Forward starting — PC:{s}:{d}  HW:{s}:{d}  WS:{s}:{d}", .{ rc.pc.host, rc.pc.port, rc.hw.host, rc.hw.port, rc.ws.host, rc.ws.port });

        // ── 在三个 Io.async 协程中启动服务器 ──
        var pc_future = Io.async(self.io, struct {
            fn run(app: *App) void {
                app.pc_server.start() catch |err| std.log.err("PC server exited: {}", .{err});
            }
        }.run, .{self});

        var hw_future = Io.async(self.io, struct {
            fn run(app: *App) void {
                app.hw_server.start() catch |err| std.log.err("HW server exited: {}", .{err});
            }
        }.run, .{self});

        var ws_future = Io.async(self.io, struct {
            fn run(app: *App) void {
                ws_server.startWithApp(&app.ws_app, app.config.ws.host, app.config.ws.port) catch |err| std.log.err("WS server exited: {}", .{err});
            }
        }.run, .{self});

        // ── 等待关闭信号 ──
        std.log.info("Server started. Press Ctrl+C to stop.", .{});
        while (!util.shutdownRequested()) {
            Io.sleep(self.io, .{ .nanoseconds = 200_000_000 }, .real) catch {};
        }

        // ── 优雅关闭 ──
        std.log.info("Shutting down...", .{});
        self.pc_server.stop();
        self.hw_server.stop();
        self.ws_app.stop();

        // 等待服务器协程退出（它们检测到 stop 后应很快返回）
        pc_future.await(self.io);
        hw_future.await(self.io);
        ws_future.await(self.io);
    }
};
