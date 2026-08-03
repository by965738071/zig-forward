const std = @import("std");
const builtin = @import("builtin");
const cfg = @import("app_config");
const ConfigType = cfg.ConfigType;

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

extern fn SetConsoleCtrlHandler(h: *const fn (u32) callconv(.c) c_int, add: c_int) callconv(.c) c_int;

/// 注册 Ctrl+C / SIGTERM 处理：收到信号时置位关闭标志。
/// 主循环通过 `shutdownRequested()` 轮询。
pub fn setupShutdownHandler() void {
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
            fn handler(sig: posix.SIG) callconv(.c) void {
                _ = sig;
                g_shutdown.store(true, .monotonic);
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

/// 是否已收到关闭信号（Ctrl+C / SIGTERM）
pub fn shutdownRequested() bool {
    return g_shutdown.load(.monotonic);
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
            std.log.warn("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    return result;
}

pub fn printHelp() void {
    std.debug.print(
        "Zig Forward — TCP message broker\n" ++
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
