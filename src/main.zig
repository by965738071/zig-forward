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

    // ── 构造 App（工厂模式，所有子组件在 create 内完成初始化）──
    // App 持有 config 的值拷贝，但 host/port 切片仍借用 runtime_config，
    // 由 main 的 defer 顺序保证：app.deinit() 先于 runtime_config.deinit()。
    const app = try App.create(allocator, init.io, runtime_config.config);
    defer app.deinit();

    app.run();

    // 程序退出前输出换行，确保 shell 提示符在新行显示。
    // Ctrl+C 的 ^C 字符无换行，日志输出接在其后，导致提示符需回车才重绘。
    std.debug.print("\n", .{});
}
