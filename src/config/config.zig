const std = @import("std");
const HandlerRegistry = @import("handler_registry.zig").HandlerRegistry;

// ── PC 端 ────────────────────────────────

/// PC 命令处理函数签名（void context：纯函数）
pub const HandlerFn = HandlerRegistry([]const u8, void).Handler;

/// PC 命令条目
pub const CommandEntry = struct {
    name: []const u8,
    handler: HandlerFn,
};

// ── 处理函数 ─────────────────────────────

// PC handler
fn handleBoxStatus(_: void, cmd: []const u8, data: []const u8, alloc: std.mem.Allocator) anyerror!?[]u8 {
    _ = data;
    const result = try std.fmt.allocPrint(alloc, "{{\"status\":\"ok\",\"cmd\":\"{s}\"}}", .{cmd});
    return @as(?[]u8, result);
}

fn handleBoxVoltage(_: void, cmd: []const u8, data: []const u8, alloc: std.mem.Allocator) anyerror!?[]u8 {
    _ = data;
    const result = try std.fmt.allocPrint(alloc, "{{\"status\":\"ok\",\"cmd\":\"{s}\"}}", .{cmd});
    return @as(?[]u8, result);
}

// ── 配置字段 ─────────────────────────────

/// PC 服务器设置
pc: struct {
    host: []const u8,
    port: u16,
} = .{ .host = "0.0.0.0", .port = 9000 },

/// 硬件服务器设置
hw: struct {
    host: []const u8,
    port: u16,
} = .{ .host = "0.0.0.0", .port = 9001 },

/// PC 命令路由表（在这里添加/删除命令映射）
commands: []const CommandEntry = &.{
    .{ .name = "BoxStatus", .handler = handleBoxStatus },
    .{ .name = "BoxVoltage", .handler = handleBoxVoltage },
},
