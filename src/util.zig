const std = @import("std");
const cfg = @import("config");
const ConfigType = cfg.ConfigType;

/// Parse CLI arguments and return a runtime config.
/// Returns `error.HelpRequested` if `--help` or `-h` is present (caller should return
/// gracefully from main).
pub fn parseCliArgs(allocator: std.mem.Allocator, args: std.process.Args) !ConfigType {
    var runtime_config: ConfigType = .{};
    var args_iter = std.process.Args.Iterator.init(args);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pc-port")) {
            runtime_config.pc.port = try std.fmt.parseInt(u16, args_iter.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, arg, "--hw-port")) {
            runtime_config.hw.port = try std.fmt.parseInt(u16, args_iter.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, arg, "--pc-host")) {
            runtime_config.pc.host = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--hw-host")) {
            runtime_config.hw.host = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return error.HelpRequested;
        } else {
            std.log.warn("Unknown argument: {s}", .{arg});
        }
    }
    return runtime_config;
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
            "  --help, -h          Show this help message\n",
        .{},
    );
}
