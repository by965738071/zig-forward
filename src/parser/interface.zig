const std = @import("std");
const Frame = @import("frame.zig").Frame;

/// Parser 运行时接口（vtable）。
///
/// 与 `AClient`/`CSender` 的设计一致：业务层（Server）持有 `Parser` 接口，
/// 不关心底层是 ByteParser、JsonLineParser 还是其它协议实现。
/// 新增解析器只需实现这个 vtable 并提供 `create` 工厂，无需改动 Server/App。
///
/// 生命周期：
/// - `create(allocator)` → 堆分配 parser 实例，返回 `*Parser`
/// - `parse(reader, allocator)` → 返回借用缓冲区的 `?Frame`（null=EOF）
/// - `deinit()` → 释放 parser 实例自身（由调用方随后 destroy）
pub const Parser = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        parse: *const fn (ptr: *anyopaque, reader: *std.Io.Reader, allocator: std.mem.Allocator) anyerror!?Frame,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn parse(self: *Parser, reader: *std.Io.Reader, allocator: std.mem.Allocator) !?Frame {
        return self.vtable.parse(self.ptr, reader, allocator);
    }

    pub fn deinit(self: *Parser) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Parser 工厂函数签名。每种协议的 parser 实现提供一个此类型的函数，
/// 由配置注入 Server，实现运行时协议选择。
pub const Factory = *const fn (allocator: std.mem.Allocator) anyerror!*Parser;
