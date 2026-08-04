const std = @import("std");

const App = @import("app").App;
const util = @import("util");

pub fn main(init: std.process.Init) !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.log.err("memory leak", .{});
            std.debug.panic("memory leak", .{});
        } else {
            std.log.info("success exit", .{});
        }
    }
    const allocator = debug_allocator.allocator();

    // ── 设置信号处理（Ctrl+C / SIGTERM）──
    util.setupShutdownHandler();

    // ── Parse CLI arguments ──
    var runtime_config = try util.parseCliArgs(allocator, init.minimal.args);
    defer runtime_config.deinit(allocator);

    // ── 初始化三个服务器并运行（阻塞到 Ctrl+C）──
    var app: App = undefined;
    try app.init(allocator, init.io, &runtime_config.config);
    defer app.deinit();

    app.run();
}
