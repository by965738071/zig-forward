const std = @import("std");

/// 二进制协议 Parser，用于 HardwareServer。
///
/// 帧格式：
///   [55 AA] [type:1] [length:4 LE] [payload:N] [checksum:2]
///
/// checksum：累加和（所有之前字节的 wrapping sum）
pub fn ByteParser() type {
    return struct {
        pub const Frame = struct {
            id: u8,
            data: []const u8,
            allocator: std.mem.Allocator,

            pub fn deinit(self: *@This()) void {
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
                const n = try reader.readVec(&iov);
                if (n == 0) return null; // EOF
                try self.buf.appendSlice(allocator, self.read_buf[0..n]);
            }
        }

        /// 尝试从缓冲区提取一个完整帧。返回 null 表示数据不足。
        fn tryExtractFrame(self: *Self, allocator: std.mem.Allocator) !?Frame {
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
                // checksum 不匹配，跳过第一个字节继续找
                _ = self.buf.orderedRemove(0);
                return try self.tryExtractFrame(allocator);
            }

            // 提取完整帧
            const packet = try allocator.dupe(u8, self.buf.items[0..total_len]);

            // 移除已消耗的字节
            if (self.buf.items.len > total_len) {
                std.mem.copyForwards(u8, self.buf.items[0 .. self.buf.items.len - total_len], self.buf.items[total_len..]);
            }
            self.buf.shrinkRetainingCapacity(self.buf.items.len - total_len);

            return Frame{ .id = packet_type, .data = packet, .allocator = allocator };
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
