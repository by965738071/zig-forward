const std = @import("std");
const HandlerRegistry = @import("handler_registry.zig").HandlerRegistry;

// ── PC 端 ────────────────────────────────

/// PC 命令处理函数签名（IdType = u8，二进制协议）
pub const HandlerFn = HandlerRegistry(u8, void).Handler;

/// PC 命令条目
pub const CommandEntry = struct {
    id: u8,
    handler: HandlerFn,
};

// ── HW 端 ────────────────────────────────

/// HW 命令处理函数签名
pub const HwHandlerFn = HandlerRegistry([]const u8, void).Handler;

/// HW 命令条目
pub const HwCommandEntry = struct {
    name: []const u8,
    handler: HwHandlerFn,
};

// ── 处理函数 ─────────────────────────────

// PC handler
fn handleBoxStatus(_: void, cmd: u8, data: []const u8, alloc: std.mem.Allocator) anyerror!?[]u8 {
    _ = data;
    const result = try std.fmt.allocPrint(alloc, "boxStatus ok cmd={}", .{cmd});
    return @as(?[]u8, result);
}

fn handleBoxVoltage(_: void, cmd: u8, data: []const u8, alloc: std.mem.Allocator) anyerror!?[]u8 {
    _ = data;
    const result = try std.fmt.allocPrint(alloc, "boxVoltage ok cmd={}", .{cmd});
    return @as(?[]u8, result);
}

// HW 默认处理：收到啥广播啥
fn hwDefaultHandler(_: void, _: []const u8, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
    const result = try allocator.dupe(u8, data);
    return @as(?[]u8, result);
}

fn handleHwBox(_: void, _: []const u8, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
    const result = try std.fmt.allocPrint(allocator, "{{\"from\":\"hw\",\"data\":\"{s}\"}}", .{data});
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
    .{ .id = 0x01, .handler = handleBoxStatus },
    .{ .id = 0x02, .handler = handleBoxVoltage },
},

/// HW 命令路由表
hw_commands: []const HwCommandEntry = &.{
    .{ .name = "box", .handler = handleHwBox },
},

/// HW 默认处理函数（没有匹配命令时使用，null 表示丢弃）
hw_default_handler: ?HwHandlerFn = hwDefaultHandler,
