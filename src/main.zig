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
    // 传入 io 供信号处理函数通过 Io.Event.set() 唤醒主线程
    util.setupShutdownHandler(init.io);

    // ── Parse CLI arguments ──
    var runtime_config = util.parseCliArgs(allocator, init.minimal.args) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    defer runtime_config.deinit(allocator);

    // ── 构造 App（工厂模式，所有子组件在 create 内完成初始化）──
    // App 持有 config 的值拷贝，但 host/port 切片仍借用 runtime_config，
    // 由 main 的 defer 顺序保证：app.deinit() 先于 runtime_config.deinit()。
    const app = try App.create(allocator, init.io, runtime_config.config);
    defer app.deinit();

    try app.run();

    std.debug.print("\n", .{});
}
