const std = @import("std");
const Id = @import("app_config").Id;
const Handler = @import("app_config").config.Handler;
const CommandEntry = @import("app_config").config.CommandEntry;

// ── HW 端 handler 实现 ──────────────────────────────────
// 签名统一为 `Handler = *const fn (id: Id, data, allocator) !?[]u8`，
// 对 str id 通过 `id.str` 取值。

fn hwDefaultHandler(id: Id, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
    _ = id;
    const result = try allocator.dupe(u8, data);
    return @as(?[]u8, result);
}

fn handleHwBox(id: Id, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
    _ = id;
    const result = try std.fmt.allocPrint(allocator, "{{\"from\":\"hw\",\"data\":\"{s}\"}}", .{data});
    return @as(?[]u8, result);
}

/// HW 命令路由表。
pub const commands: []const CommandEntry = &.{
    .{ .id = .{ .str = "box" }, .handler = handleHwBox },
};

/// HW 默认 handler。
pub const default_handler: ?Handler = hwDefaultHandler;
