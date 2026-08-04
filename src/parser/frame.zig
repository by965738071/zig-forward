const std = @import("std");

/// 统一的命令标识。所有 parser 产出的 Frame 都用这一种 id 类型，
/// 消除 `FrameView(comptime IdType)` 导致的泛型传染。
///
/// - `.int`：二进制协议的数值 id（u64 足够覆盖 u8/u16/u32）
/// - `.str`：JSON/文本协议的字符串 id（借用 raw，不持有）
pub const Id = union(enum) {
    int: u64,
    str: []const u8,

    pub fn eql(self: Id, other: Id) bool {
        return switch (self) {
            .int => |a| switch (other) {
                .int => |b| a == b,
                else => false,
            },
            .str => |a| switch (other) {
                .str => |b| std.mem.eql(u8, a, b),
                else => false,
            },
        };
    }
};

/// 解析出的帧视图——**借用** parser 内部缓冲区，不持有任何堆分配。
///
/// 调用方必须在下一次 `parse()` 之前用完，或调用 `dup()` 取得独立副本。
/// - `raw`：完整帧字节（含协议头尾），借用缓冲区。
/// - `payload`：`raw` 中载荷部分（零拷贝切片）。
/// - `id`：命令标识（int 为值拷贝，str 借用 raw 内部）。
pub const Frame = struct {
    id: Id,
    raw: []const u8,
    payload: []const u8,

    /// 复制为独立拥有的 Frame（调用方负责 `deinit`）。
    pub fn dup(self: Frame, allocator: std.mem.Allocator) !OwnedFrame {
        const raw_owned = try allocator.dupe(u8, self.raw);
        errdefer allocator.free(raw_owned);
        const id_owned: Id = switch (self.id) {
            .int => self.id,
            .str => |s| .{ .str = raw_owned[s.ptr - self.raw.ptr ..][0..s.len] },
        };
        const payload_offset = self.payload.ptr - self.raw.ptr;
        return .{
            .id = id_owned,
            .raw = raw_owned,
            .payload = raw_owned[payload_offset..][0..self.payload.len],
        };
    }
};

/// 拥有独立堆副本的帧，`deinit` 释放 `raw`（id.str / payload 都是其切片）。
pub const OwnedFrame = struct {
    id: Id,
    raw: []const u8,
    payload: []const u8,

    pub fn deinit(self: *OwnedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};
