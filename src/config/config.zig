const std = @import("std");
const Id = @import("parser").Id;
const HandlerRegistry = @import("handler_registry.zig").HandlerRegistry;

// ── 命令条目 ─────────────────────────────
// 统一使用 Frame.Id 作为命令标识，不再为每种 IdType 定义不同类型。

pub const Handler = HandlerRegistry.Handler;

pub const CommandEntry = struct {
    id: Id,
    handler: Handler,
};

pub const HwCommandEntry = CommandEntry; // PC/HW 共用同一结构

// ── PC 二进制协议命令码 ─────────────────────────────
// 业务数据命令（0x01-0x0F）走 HandlerRegistry dispatch。
// 控制权命令（0x10-0x13）由 pc_server 内部拦截，直接调用 state.* API。

pub const CMD_REQUEST_CONTROL: u8 = 0x10;
pub const CMD_RELEASE_CONTROL: u8 = 0x11;
pub const CMD_HEARTBEAT: u8 = 0x12;
pub const CMD_GET_STATUS: u8 = 0x13;

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

/// WebSocket 服务器设置
ws: struct {
    host: []const u8,
    port: u16,
} = .{ .host = "0.0.0.0", .port = 9224 },
