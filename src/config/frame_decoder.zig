const std = @import("std");

/// 帧解码器接口 —— 把"从字节流中提取完整帧"的逻辑抽象为 VTable 风格接口。
///
/// 每个硬件连接使用一个独立的 `FrameDecoder` 实例。
/// 使用 `DecoderFactory` 创建实例（heap allocated）。
///
/// # 内置实现
///
/// `custom_codec.decoder_factory` — 默认的二进制帧协议实现（基于 `custom_codec.Decoder`）。
///
/// # 自定义实现示例
///
/// ```zig
/// const MyDecoder = struct {
///     buf: std.ArrayList(u8),
///
///     fn create(allocator: std.mem.Allocator) !FrameDecoder {
///         const self = try allocator.create(MyDecoder);
///         self.* = .{ .buf = .empty };
///         return .{
///             .ptr = self,
///             .vtable = &.{
///                 .feed = impl.feed,
///                 .decode = impl.decode,
///                 .deinit = impl.deinit,
///             },
///         };
///     }
///
///     const impl = struct {
///         fn feed(ctx: *anyopaque, data: []const u8) anyerror!void {
///             const dec: *MyDecoder = @ptrCast(@alignCast(ctx));
///             try dec.buf.appendSlice(data);
///         }
///         fn decode(ctx: *anyopaque) anyerror!?[]u8 {
///             const dec: *MyDecoder = @ptrCast(@alignCast(ctx));
///             // ... custom framing logic
///             return null;
///         }
///         fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
///             const dec: *MyDecoder = @ptrCast(@alignCast(ctx));
///             dec.buf.deinit(allocator);
///             allocator.destroy(dec);
///         }
///     };
/// };
/// ```
///
/// # 集成到 HardwareServer
///
/// ```zig
/// var server = HardwareServer.init(allocator, state, io, "0.0.0.0", 9001);
/// server.setDecoderFactory(.{ .create = MyDecoder.create });
/// try server.start();
/// ```
pub const FrameDecoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Feed raw bytes into the decoder buffer.
        feed: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
        /// Try to extract one complete frame.
        /// Returns `null` if more data is needed.
        decode: *const fn (ctx: *anyopaque) anyerror!?[]u8,
        /// Destroy the decoder instance.
        /// `allocator` is the same allocator passed to the factory's `create`.
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn feed(self: FrameDecoder, data: []const u8) !void {
        return self.vtable.feed(self.ptr, data);
    }

    pub fn decode(self: FrameDecoder) !?[]u8 {
        return self.vtable.decode(self.ptr);
    }

    pub fn deinit(self: FrameDecoder, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

/// Factory for creating FrameDecoder instances.
/// Each call to `create` allocates a new decoder on the heap.
pub const DecoderFactory = struct {
    create: *const fn (allocator: std.mem.Allocator) anyerror!FrameDecoder,
};
