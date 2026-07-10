
const std = @import("std");
const HandlerRegistry = @import("handler_registry.zig").HandlerRegistry;

// 用户的所有 handler
pub const MyHandlers = struct {
    pub fn register(_: []const u8, data: []const u8, alloc: std.mem.Allocator) !?[]u8 {
        // 解析注册数据，返回 JSON
    }
    pub fn boxStatus(_: []const u8, data: []const u8, alloc: std.mem.Allocator) !?[]u8 {
        // 只解析，不转发
    }
};

// 命令表：一眼看完所有命令映射
pub const commands = &[_]CommandEntry{
    .{ "Register", MyHandlers.register },
    .{ "BoxStatus", MyHandlers.boxStatus },
};

pub const CommandEntry = struct {
    cmd: []const u8,
    handler: HandlerRegistry([]const u8).Handler,
};
