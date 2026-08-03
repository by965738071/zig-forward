const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const cfg = @import("app_config");
// 暴露 config 模块（config/root.zig）给集成测试：测试通过 `@import("app").config.*` 访问它。
pub const config = cfg;

const GlobalState = cfg.state.GlobalState;
const PcServer = @import("pc_server").pc_server.PcServer;
const HwServer = @import("hw_server").hw_server.HwServer;
const ByteParser = @import("parser").byte_parser.ByteParser;
const JsonLineParser = @import("parser").json_parser.JsonLineParser;
const util = @import("util");
const ws_server = @import("ws_server");

// ── 全局关闭标志（信号处理器中设置，主循环中检查）──
var g_shutdown = std.atomic.Value(bool).init(false);

extern fn SetConsoleCtrlHandler(h: *const fn (u32) callconv(.c) c_int, add: c_int) callconv(.c) c_int;

fn setupShutdownHandler() !void {
    if (builtin.os.tag == .windows) {
        // Windows 用 SetConsoleCtrlHandler 捕获 Ctrl+C
        const HandlerRoutine = *const fn (dwCtrlType: u32) callconv(.c) c_int;

        const handler: HandlerRoutine = struct {
            fn ctrlHandler(dwCtrlType: u32) callconv(.c) c_int {
                if (dwCtrlType == 0) { // CTRL_C_EVENT
                    g_shutdown.store(true, .monotonic);
                    return 1;
                }
                return 0;
            }
        }.ctrlHandler;

        _ = SetConsoleCtrlHandler(handler, 1);
    } else {
        // POSIX 用 sigaction 捕获 SIGINT/SIGTERM
        const posix = std.posix;

        const Handler = struct {
            fn handler(sig: c_int) callconv(.c) void {
                _ = sig;
                g_shutdown.store(true, .monotonic);
            }
        };

        var mask: posix.sigset_t = undefined;
        posix.sigemptyset(&mask);

        var sa: posix.Sigaction = .{
            .handler = .{ .handler = Handler.handler },
            .mask = mask,
            .flags = 0,
        };

        _ = posix.sigaction(posix.SIG.INT, &sa, null);
        _ = posix.sigaction(posix.SIG.TERM, &sa, null);
    }
}

pub fn main(init: std.process.Init) !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = debug_allocator.allocator();

    // ── 设置信号处理（Ctrl+C）──
    try setupShutdownHandler();

    // ── Parse CLI arguments ──
    var runtime_config = try util.parseCliArgs(allocator, init.minimal.args);
    defer runtime_config.deinit(allocator);

    // ── Global state ──
    var state = GlobalState.init(allocator);
    defer state.deinit();

    const rc = &runtime_config.config;

    std.log.info("Zig Forward starting — PC:{s}:{d}  HW:{s}:{d}  WS:{s}:{d}", .{ rc.pc.host, rc.pc.port, rc.hw.host, rc.hw.port, rc.ws.host, rc.ws.port });

    // ── PC server ──
    var pc_server = PcServer(u8, ByteParser())
        .init(allocator, &state, init.io, rc.*);
    defer pc_server.deinit();

    for (rc.commands) |cmd| {
        try pc_server.registerCommand(cmd.id, cmd.handler);
    }

    // ── HW server ──
    var hw_server = HwServer([]const u8, JsonLineParser([]const u8))
        .init(allocator, &state, init.io, rc.hw.host, rc.hw.port);
    defer hw_server.deinit();

    for (rc.hw_commands) |cmd| {
        try hw_server.registerCommand(cmd.name, cmd.handler);
    }
    if (rc.hw_default_handler) |h| {
        hw_server.setDefault(h);
    }

    // ── WebSocket 共享状态 ──
    var ws_app = ws_server.App.init(allocator, init.io, &state);
    defer ws_app.deinit();

    // ── 在三个 Io.async 协程中启动服务器 ──
    var pc_future = Io.async(init.io, struct {
        fn run(pc: *PcServer(u8, ByteParser())) void {
            pc.start() catch |err| std.log.err("PC server exited: {}", .{err});
        }
    }.run, .{&pc_server});

    var hw_future = Io.async(init.io, struct {
        fn run(hw: *HwServer([]const u8, JsonLineParser([]const u8))) void {
            hw.start() catch |err| std.log.err("HW server exited: {}", .{err});
        }
    }.run, .{&hw_server});

    var ws_future = Io.async(init.io, struct {
        fn run(app: *ws_server.App, host: []const u8, port: u16) void {
            ws_server.startWithApp(app, host, port) catch |err| std.log.err("WS server exited: {}", .{err});
        }
    }.run, .{ &ws_app, rc.ws.host, rc.ws.port });

    // ── 等待关闭信号 ──
    std.log.info("Server started. Press Ctrl+C to stop.", .{});
    while (!g_shutdown.load(.monotonic)) {
        Io.sleep(init.io, .{ .nanoseconds = 200_000_000 }, .real) catch {};
    }

    // ── 优雅关闭 ──
    std.log.info("Shutting down...", .{});
    pc_server.stop();
    hw_server.stop();
    ws_app.stop();

    // 等待服务器协程退出（它们检测到 stop 后应很快返回）
    pc_future.await(init.io);
    hw_future.await(init.io);
    ws_future.await(init.io);

    std.log.info("Server stopped, cleaning up...", .{});
    // defer 链依次执行：
    //   ws_app.deinit()     → 释放 WS server 资源
    //   hw_server.deinit()  → 释放 HW server 资源
    //   pc_server.deinit()  → 释放 PC server 资源
    //   state.deinit()      → 释放 GlobalState
    //   runtime_config.deinit(allocator) → 释放 CLI 分配的 host 字符串
    //   debug_allocator.deinit() → 检查 leak（现在应该干净了）
}
