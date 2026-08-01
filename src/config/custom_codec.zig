const std = @import("std");

/// 自定义二进制协议编解码。
///
/// 帧格式（与 `parser/byte_parser.zig` 的解析逻辑严格一致）：
///
///   [55 AA] [type:1] [length:4 LE] [payload:N] [checksum:2 LE]
///
/// - Header: 固定 `0x55 0xAA`（注意：README 旧版写的是 `0xEB90`，实现以后者为准）
/// - Type: 包类型（1 字节）
/// - Length: payload 长度，小端 u32（**不含** header/type/length/checksum 自身）
/// - Payload: 变长数据
/// - Checksum: 从 header 开始到 payload 结束所有字节的 wrapping 累加和（u16 低 16 位）
///
/// 注：早期设计文档里的 `Board` 单字节字段在解析端并未实现，此处也不单独编码，
/// 如有需要请将 board 信息并入 payload。
pub const HEADER: [2]u8 = .{ 0x55, 0xAA };

/// 编码一帧完整数据包。
/// `payload` 为业务载荷；调用方拥有返回的切片，需自行 `allocator.free`。
pub fn encode(allocator: std.mem.Allocator, packet_type: u8, payload: []const u8) ![]u8 {
    const total_len = HEADER.len + 1 + 4 + payload.len + 2;
    const out = try allocator.alloc(u8, total_len);

    var off: usize = 0;
    out[off..][0..HEADER.len].* = HEADER;
    off += HEADER.len;
    out[off] = packet_type;
    off += 1;
    std.mem.writeInt(u32, out[off..][0..4], @intCast(payload.len), .little);
    off += 4;
    @memcpy(out[off..][0..payload.len], payload);
    off += payload.len;

    // checksum：header + type + length + payload 的 wrapping 累加和
    var sum: u16 = 0;
    for (out[0..off]) |b| sum +%= b;
    std.mem.writeInt(u16, out[off..][0..2], sum, .little);

    return out;
}

/// 校验一帧（不含 header 匹配，调用方已完成）的 checksum 是否正确。
pub fn verifyChecksum(frame: []const u8) bool {
    if (frame.len < 2) return false;
    var sum: u16 = 0;
    for (frame[0 .. frame.len - 2]) |b| sum +%= b;
    const checksum = std.mem.readInt(u16, frame[frame.len - 2 ..][0..2], .little);
    return sum == checksum;
}

const testing = std.testing;

test "custom_codec encode round-trip checksum" {
    const alloc = testing.allocator;
    const payload = [_]u8{ 0x01, 0xAA, 0xBB };
    const frame = try encode(alloc, 0x1B, &payload);
    defer alloc.free(frame);

    try testing.expectEqual(@as(usize, 2 + 1 + 4 + payload.len + 2), frame.len);
    try testing.expectEqual(@as(u8, 0x55), frame[0]);
    try testing.expectEqual(@as(u8, 0xAA), frame[1]);
    try testing.expectEqual(@as(u8, 0x1B), frame[2]);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, frame[3..][0..4], .little));
    try testing.expect(verifyChecksum(frame));
}

