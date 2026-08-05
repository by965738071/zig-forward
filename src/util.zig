const std = @import("std");
const builtin = @import("builtin");
const cfg = @import("app_config");
const ConfigType = cfg.ConfigType;
const log = std.log.scoped(.util);
/// CLI 解析结果的包装体，跟踪哪些字段被覆写，方便释放。
pub const ParsedConfig = struct {
    config: ConfigType,
    /// 以下字段标记对应的 host 是否被 CLI 参数覆写（堆分配，需要 free）
    pc_host_owned: bool = false,
    hw_host_owned: bool = false,
    ws_host_owned: bool = false,

    pub fn deinit(self: *ParsedConfig, allocator: std.mem.Allocator) void {
        if (self.pc_host_owned) allocator.free(self.config.pc.host);
        if (self.hw_host_owned) allocator.free(self.config.hw.host);
        if (self.ws_host_owned) allocator.free(self.config.ws.host);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 关闭信号处理（Ctrl+C / SIGTERM）
// ─────────────────────────────────────────────────────────────────────────────

// ── 全局关闭标志（信号处理器中设置，主循环中检查）──
var g_shutdown = std.atomic.Value(bool).init(false);
/// 信号计数：第一次 Ctrl+C 请求优雅关闭，第二次强制退出。
var g_signal_count = std.atomic.Value(u32).init(0);

/// 基于 futex 的事件对象，用于替代 sleep 轮询。
/// 信号处理函数中调用 event.set(io) 唤醒主线程，主线程阻塞在 event.wait(io) 上。
var g_shutdown_event: std.Io.Event = .unset;
/// 全局 Io 引用，供信号处理函数调用 event.set()。
var g_shutdown_io: std.Io = undefined;

/// 注册 Ctrl+C / SIGTERM 处理：
/// - 第一次：置位关闭标志，唤醒主线程走优雅关闭。
/// - 第二次：直接 _exit(130)，避免优雅关闭卡住时终端无响应。
///
/// 需要传入 io 参数，供信号处理函数通过 Io.Event.set() 唤醒主线程。
pub fn setupShutdownHandler(io: std.Io) void {
    g_shutdown_io = io;
    if (builtin.os.tag == .windows) {
        const HandlerRoutine = *const fn (dwCtrlType: u32) callconv(.c) std.os.windows.BOOL;

        const handler: HandlerRoutine = struct {
            fn ctrlHandler(dwCtrlType: u32) callconv(.c) std.os.windows.BOOL {
                if (dwCtrlType == 0) { // CTRL_C_EVENT
                    const count = g_signal_count.fetchAdd(1, .monotonic);
                    if (count == 0) {
                        g_shutdown.store(true, .monotonic);
                        g_shutdown_event.set(g_shutdown_io);
                    } else {
                        // 第二次 Ctrl+C：强制退出
                        std.process.exit(130);
                    }
                    return @fromBackingInt(@intCast(1));
                }
                return @fromBackingInt(@intCast(0));
            }
        }.ctrlHandler;

        const SetConsoleCtrlHandler = @extern(*const fn (h: HandlerRoutine, add: c_int) callconv(.c) std.os.windows.BOOL, .{ .name = "SetConsoleCtrlHandler" });
        _ = SetConsoleCtrlHandler(handler, 1);
    } else {
        const posix = std.posix;

        const Handler = struct {
            fn handler(sig: posix.SIG) callconv(.c) void {
                _ = sig;
                const count = g_signal_count.fetchAdd(1, .monotonic);
                if (count == 0) {
                    // 第一次：请求优雅关闭。
                    g_shutdown.store(true, .monotonic);
                    // 唤醒主线程（futex/__ulock_wake 是系统调用，信号上下文安全）。
                    g_shutdown_event.set(g_shutdown_io);
                } else {
                    // 第二次 Ctrl+C：用裸 _exit 跳过所有清理（信号上下文不安全）。
                    // std.process.exit 会走 defer/flush，在 signal handler 中可能死锁。
                    std.c._exit(130);
                }
            }
        };

        const mask = posix.sigemptyset();

        var sa: posix.Sigaction = .{
            .handler = .{ .handler = Handler.handler },
            .mask = mask,
            .flags = 0,
        };

        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
    }
}

/// 阻塞直到收到关闭信号（零轮询，基于 futex 的真正阻塞等待）。
/// 信号处理函数中调用 g_shutdown_event.set(io) 唤醒此等待。
pub fn waitForShutdown(io: std.Io) void {
    g_shutdown_event.wait(io) catch {};
}

/// Parse CLI arguments and return a runtime config.
/// Returns `error.HelpRequested` if `--help` or `-h` is present (caller should return
/// gracefully from main).
pub fn parseCliArgs(allocator: std.mem.Allocator, args: std.process.Args) !ParsedConfig {
    var result = ParsedConfig{ .config = .{} };
    var args_iter = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pc-port")) {
            result.config.pc.port = try std.fmt.parseInt(u16, args_iter.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, arg, "--hw-port")) {
            result.config.hw.port = try std.fmt.parseInt(u16, args_iter.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, arg, "--pc-host")) {
            result.config.pc.host = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
            result.pc_host_owned = true;
        } else if (std.mem.eql(u8, arg, "--hw-host")) {
            result.config.hw.host = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
            result.hw_host_owned = true;
        } else if (std.mem.eql(u8, arg, "--ws-port")) {
            result.config.ws.port = try std.fmt.parseInt(u16, args_iter.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, arg, "--ws-host")) {
            result.config.ws.host = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
            result.ws_host_owned = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return error.HelpRequested;
        } else {
            log.err("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    return result;
}

fn printHelp() void {
    std.debug.print(
        "Zig Forward: TCP message broker\n" ++
            "\n" ++
            "USAGE: zig_forward [OPTIONS]\n" ++
            "\n" ++
            "OPTIONS:\n" ++
            "  --pc-port <PORT>    PC server port (default: 9000)\n" ++
            "  --hw-port <PORT>    HW server port (default: 9001)\n" ++
            "  --pc-host <HOST>    PC server bind address (default: 0.0.0.0)\n" ++
            "  --hw-host <HOST>    HW server bind address (default: 0.0.0.0)\n" ++
            "  --ws-port <PORT>    WebSocket server port (default: 9224)\n" ++
            "  --ws-host <HOST>    WebSocket server bind address (default: 0.0.0.0)\n" ++
            "  --help, -h          Show this help message\n",
        .{},
    );
}
