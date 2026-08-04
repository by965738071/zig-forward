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

    pub fn init(self: *App, allocator: std.mem.Allocator, io: Io, cfg_ptr: *const ConfigType) !void {
        self.allocator = allocator;
        self.io = io;
        self.config = cfg_ptr.*;

        self.state = GlobalState.init(allocator);
        errdefer self.state.deinit();

        self.pc_server = PcServer(u8, ByteParser()).init(allocator, &self.state, io, self.config);
        errdefer self.pc_server.deinit();
        for (cfg_ptr.commands) |cmd| {
            try self.pc_server.registerCommand(cmd.id, cmd.handler);
        }

        self.hw_server = HwServer([]const u8, JsonLineParser([]const u8))
            .init(allocator, &self.state, io, cfg_ptr.hw.host, cfg_ptr.hw.port);
        errdefer self.hw_server.deinit();
        for (cfg_ptr.hw_commands) |cmd| {
            try self.hw_server.registerCommand(cmd.name, cmd.handler);
        }
        if (cfg_ptr.hw_default_handler) |h| {
            self.hw_server.setDefault(h);
        }

        self.ws_app = ws_server.App.init(allocator, io, &self.state);
        errdefer self.ws_app.deinit();
    }

    pub fn deinit(self: *App) void {
        self.ws_app.deinit();
        self.hw_server.deinit();
        self.pc_server.deinit();
        self.state.deinit();
    }

    /// 启动三个服务器并阻塞等待关闭信号（Ctrl+C / SIGTERM）。
    /// 收到信号后通过 Io.Group.cancel() 优雅关闭所有服务器协程。
    pub fn run(self: *App) void {
        const rc = &self.config;
        std.log.info("Zig Forward starting — PC:{s}:{d}  HW:{s}:{d}  WS:{s}:{d}", .{ rc.pc.host, rc.pc.port, rc.hw.host, rc.hw.port, rc.ws.host, rc.ws.port });

        // ── 使用 Io.Group 管理三个服务器协程 ──
        // Group.cancel() 通过 Io vtable 的 alertable 路径取消 pending 的 accept()
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

        // ── 等待关闭信号 ──
        std.log.info("Server started. Press Ctrl+C to stop.", .{});
        while (!util.shutdownRequested()) {
            Io.sleep(self.io, .{ .nanoseconds = 200_000_000 }, .real) catch {};
        }

        // ── 优雅关闭 ──
        std.log.info("Shutting down...", .{});
        // WS 服务器使用原始 posix.accept（不走 Io vtable），需要先显式 stop()
        self.ws_app.stop();
        // 取消 accept 循环（PC/HW 服务器通过 Io vtable 的 alertable 路径取消）
        group.cancel(self.io);

        // 取消所有 handler 协程（Group.cancel 会发送取消信号并等待所有任务完成）
        self.pc_server.handler_group.cancel(self.io);
        self.hw_server.handler_group.cancel(self.io);
        std.log.info("所有 handler 已退出", .{});

        // 安全网：清理任何残留的组状态
        self.state.closeAllGroups(self.io);
    }
};
