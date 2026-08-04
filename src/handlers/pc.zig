const std = @import("std");
const Id = @import("app_config").Id;
const Handler = @import("app_config").config.Handler;
const CommandEntry = @import("app_config").config.CommandEntry;

// ── PC 端 handler 实现 ──────────────────────────────────
// 签名统一为 `Handler = *const fn (id: Id, data, allocator) !?[]u8`，
// 对 int id 通过 `id.int` 取值。

fn handleBoxStatus(id: Id, data: []const u8, alloc: std.mem.Allocator) anyerror!?[]u8 {
    _ = data;
    const cmd: u8 = @intCast(id.int);
    const result = try std.fmt.allocPrint(alloc, "boxStatus ok cmd={}", .{cmd});
    return @as(?[]u8, result);
}

fn handleBoxVoltage(id: Id, data: []const u8, alloc: std.mem.Allocator) anyerror!?[]u8 {
    _ = data;
    const cmd: u8 = @intCast(id.int);
    const result = try std.fmt.allocPrint(alloc, "boxVoltage ok cmd={}", .{cmd});
    return @as(?[]u8, result);
}

/// PC 命令路由表。控制权命令（0x10-0x13）由 pc_server 内部拦截，不在此表。
pub const commands: []const CommandEntry = &.{
    .{ .id = .{ .int = 0x01 }, .handler = handleBoxStatus },
    .{ .id = .{ .int = 0x02 }, .handler = handleBoxVoltage },
};

pub const HandlerFn = Handler;
