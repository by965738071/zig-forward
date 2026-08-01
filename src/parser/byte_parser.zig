const std = @import("std");

/// 二进制协议 Parser，用于 HwServer。
///
/// 帧格式：
///   [55 AA] [type:1] [length:4 LE] [payload:N] [checksum:2]
///
/// checksum：累加和（所有之前字节的 wrapping sum）
pub fn ByteParser() type {
    return struct {
        pub const Frame = struct {
            id: u8,
            addrs: []const []const u8,
            data: []const u8,
            allocator: std.mem.Allocator,

            pub fn deinit(self: *@This()) void {
                for (self.addrs) |a| self.allocator.free(a);
                self.allocator.free(self.addrs);
                self.allocator.free(self.data);
            }
        };

        allocator: std.mem.Allocator,
        buf: std.ArrayList(u8),
        read_buf: [4096]u8 = undefined,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .buf = .empty };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
        }

        /// 从硬件流读取数据并解析出一个完整帧。
        /// 返回 `null` 表示 EOF（连接关闭）。
        pub fn parse(self: *Self, reader: *std.Io.Reader, allocator: std.mem.Allocator) !?Frame {
            while (true) {
                if (try self.tryExtractFrame(allocator)) |frame| return frame;

                // 需要更多数据
                var iov: [1][]u8 = .{self.read_buf[0..]};
                const n = reader.readVec(&iov) catch |err| switch (err) {
                    error.EndOfStream => return null,
                    else => |e| return e,
                };
                if (n == 0) return null; // EOF
                try self.buf.appendSlice(allocator, self.read_buf[0..n]);
            }
        }

        /// 尝试从缓冲区提取一个完整帧。返回 null 表示数据不足。
        fn tryExtractFrame(self: *Self, allocator: std.mem.Allocator) !?Frame {
            // 循环扫描：checksum 失败或帧前存在垃圾字节时，丢弃头部字节后重试，
            // 用循环而非递归，避免损坏/恶意流触发 O(n²) 或深层递归。
            while (true) {
                const data = self.buf.items;
                if (data.len < 2) return null;

                const header_pos = findHeader(data) orelse {
                    // 没找到 55AA，清空缓冲区（保留最后一个字节 0x55 以防跨边界）
                    if (data.len > 0 and data[data.len - 1] == 0x55) {
                        self.buf.items[0] = 0x55;
                        self.buf.shrinkRetainingCapacity(1);
                    } else {
                        self.buf.clearRetainingCapacity();
                    }
                    return null;
                };

                // 丢弃 header 前的垃圾字节
                if (header_pos > 0) {
                    std.mem.copyForwards(u8, data[0 .. data.len - header_pos], data[header_pos..]);
                    self.buf.shrinkRetainingCapacity(data.len - header_pos);
                }

                // 最少需要：header(2) + type(1) + length(4) + checksum(2) = 9
                if (self.buf.items.len < 9) return null;

                const packet_type = self.buf.items[2];
                const payload_len = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(self.buf.items.ptr + 3)), .little);
                const total_len = 2 + 1 + 4 + payload_len + 2; // header + type + len + payload + checksum

                if (self.buf.items.len < total_len) return null;

                // 校验 checksum（累加和，wrapping）
                var sum: u16 = 0;
                for (self.buf.items[0 .. total_len - 2]) |b| {
                    sum +%= b;
                }
                const checksum = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(self.buf.items.ptr + total_len - 2)), .little);
                if (sum != checksum) {
                    // checksum 不匹配：跳过第一个字节，回到帧边界重新搜索。
                    _ = self.buf.orderedRemove(0);
                    continue;
                }

                // 提取 addrs（payload 中以空字符分隔的多个地址）
                const payload_start = 2 + 1 + 4; // header + type + length
                const payload = self.buf.items[payload_start .. payload_start + payload_len];

                var addrs_list = std.ArrayList([]const u8).empty;
                defer addrs_list.deinit(allocator);
                {
                    var offset: usize = 0;
                    while (offset < payload.len and payload[offset] != 0) {
                        const end = std.mem.indexOfScalar(u8, payload[offset..], 0) orelse payload.len;
                        try addrs_list.append(allocator, try allocator.dupe(u8, payload[offset..end]));
                        offset = end + 1;
                    }
                }
                const addrs = try addrs_list.toOwnedSlice(allocator);

                // data = 完整包数据
                const packet = try allocator.dupe(u8, self.buf.items[0..total_len]);

                // 移除已消耗的字节
                if (self.buf.items.len > total_len) {
                    std.mem.copyForwards(u8, self.buf.items[0 .. self.buf.items.len - total_len], self.buf.items[total_len..]);
                }
                self.buf.shrinkRetainingCapacity(self.buf.items.len - total_len);

                return Frame{ .id = packet_type, .addrs = addrs, .data = packet, .allocator = allocator };
            }
        }
    };
}

/// 在数据中搜索 55AA 包头
fn findHeader(data: []const u8) ?usize {
    if (data.len < 2) return null;
    var i: usize = 0;
    while (i < data.len - 1) : (i += 1) {
        if (data[i] == 0x55 and data[i + 1] == 0xAA) return i;
    }
    return null;
}

const testing = std.testing;

/// Helper to create a ByteParser instance for testing.
fn createParser(alloc: std.mem.Allocator) ByteParser() {
    return ByteParser().init(alloc);
}

const ParserType = ByteParser();

test "byte_parser findHeader" {
    // Basic: header at start
    try testing.expectEqual(@as(?usize, 0), findHeader(&.{ 0x55, 0xAA, 0x01 }));
    // Header at offset 3
    try testing.expectEqual(@as(?usize, 3), findHeader(&.{ 0x00, 0x01, 0x02, 0x55, 0xAA, 0x03 }));
    // No header
    try testing.expectEqual(@as(?usize, null), findHeader(&.{ 0x55, 0x01, 0xAA, 0x02 }));
    // Too short
    try testing.expectEqual(@as(?usize, null), findHeader(&.{0x55}));
    // Empty
    try testing.expectEqual(@as(?usize, null), findHeader(&.{}));
    // Trailing 0x55 (partial header at end)
    try testing.expectEqual(@as(?usize, null), findHeader(&.{ 0x01, 0x02, 0x55 }));
}

test "byte_parser tryExtractFrame valid" {
    const alloc = testing.allocator;
    var parser = createParser(alloc);
    defer parser.deinit();

    // Manually construct a valid frame: [55 AA] [type=1B] [len=3 LE] [payload=01 AA BB] [checksum=sum]
    var frame_buf: [2 + 1 + 4 + 3 + 2]u8 = undefined;
    frame_buf[0] = 0x55;
    frame_buf[1] = 0xAA;
    frame_buf[2] = 0x1B; // type
    std.mem.writeInt(u32, frame_buf[3..7], 3, .little); // payload length = 3
    frame_buf[7] = 0x01;
    frame_buf[8] = 0xAA;
    frame_buf[9] = 0xBB;
    // Calculate checksum (wrapping sum of all bytes up to payload)
    var sum: u16 = 0;
    for (frame_buf[0..10]) |b| sum +%= b;
    std.mem.writeInt(u16, frame_buf[10..12], sum, .little);

    // Feed into parser buffer
    parser.buf.appendSlice(alloc, &frame_buf) catch unreachable;

    const result = try parser.tryExtractFrame(alloc);
    try testing.expect(result != null);
    const frame = result.?;
    defer frame.deinit();

    try testing.expectEqual(@as(u8, 0x1B), frame.id);
    // Payload [01 AA BB] has no null bytes → one address of 3 bytes
    try testing.expectEqual(@as(usize, 1), frame.addrs.len);
    try testing.expectEqual(@as(usize, 3), frame.addrs[0].len);
    try testing.expectEqual(@as(usize, 12), frame.data.len);
}

test "byte_parser tryExtractFrame partial data" {
    const alloc = testing.allocator;
    var parser = createParser(alloc);
    defer parser.deinit();

    // Feed only header + type (not enough for a full frame)
    parser.buf.appendSlice(alloc, &.{ 0x55, 0xAA, 0x01 }) catch unreachable;
    try testing.expectEqual(@as(?ParserType.Frame, null), try parser.tryExtractFrame(alloc));

    // Now add the rest: length(4) + payload(3) + checksum(2)
    var rest: [4 + 3 + 2]u8 = undefined;
    std.mem.writeInt(u32, rest[0..4], 3, .little);
    rest[4] = 0x01;
    rest[5] = 0xAA;
    rest[6] = 0xBB;
    var sum: u16 = 0;
    for ([_]u8{ 0x55, 0xAA, 0x01 }) |b| sum +%= b;
    for (rest[0..7]) |b| sum +%= b;
    std.mem.writeInt(u16, rest[7..9], sum, .little);
    parser.buf.appendSlice(alloc, &rest) catch unreachable;

    const result = try parser.tryExtractFrame(alloc);
    try testing.expect(result != null);
    result.?.deinit();
}

test "byte_parser tryExtractFrame garbage before header" {
    const alloc = testing.allocator;
    var parser = createParser(alloc);
    defer parser.deinit();

    // Garbage + valid frame
    const garbage = [_]u8{ 0x00, 0x01, 0x02, 0x55, 0xAA, 0x01 };
    var frame_buf: [garbage.len + 4 + 3 + 2]u8 = undefined;
    @memcpy(frame_buf[0..garbage.len], &garbage);
    std.mem.writeInt(u32, frame_buf[garbage.len..][0..4], 3, .little);
    frame_buf[garbage.len + 4] = 0x01;
    frame_buf[garbage.len + 5] = 0xAA;
    frame_buf[garbage.len + 6] = 0xBB;
    var sum: u16 = 0;
    for (frame_buf[0 .. frame_buf.len - 2]) |b| sum +%= b;
    std.mem.writeInt(u16, frame_buf[frame_buf.len - 2 ..][0..2], sum, .little);

    parser.buf.appendSlice(alloc, &frame_buf) catch unreachable;

    const result = try parser.tryExtractFrame(alloc);
    try testing.expect(result != null);
    result.?.deinit();
}

test "byte_parser tryExtractFrame checksum mismatch skips byte" {
    const alloc = testing.allocator;
    var parser = createParser(alloc);
    defer parser.deinit();

    // Corrupt frame: bad checksum byte
    var frame_buf: [2 + 1 + 4 + 1 + 2]u8 = undefined;
    frame_buf[0] = 0x55;
    frame_buf[1] = 0xAA;
    frame_buf[2] = 0x01;
    std.mem.writeInt(u32, frame_buf[3..7], 1, .little);
    frame_buf[7] = 0x42;
    std.mem.writeInt(u16, frame_buf[8..10], 0xFFFF, .little); // bad checksum

    parser.buf.appendSlice(alloc, &frame_buf) catch unreachable;

    // Should not return a frame (checksum fails, byte skipped, still no valid frame)
    const result = try parser.tryExtractFrame(alloc);
    try testing.expect(result == null);
    // But the buffer should have been consumed (first byte skipped)
    try testing.expect(parser.buf.items.len < frame_buf.len);
}

test "byte_parser tryExtractFrame empty buffer" {
    const alloc = testing.allocator;
    var parser = createParser(alloc);
    defer parser.deinit();

    try testing.expectEqual(@as(?ParserType.Frame, null), try parser.tryExtractFrame(alloc));
}
