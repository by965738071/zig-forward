const std = @import("std");

/// 统一的流式读取原语，供各 Parser 复用。
///
/// 内部维护一个累积缓冲区 + `start` 读偏移量。`consume` 只前进 `start`，
/// **不移动内存**，保证 `peek` 返回的切片在下次 `readMore` 前始终有效。
/// 当 `start` 超过阈值时才压缩（把未读数据移回开头），避免内存无限增长。
///
/// 这解决了旧实现 `consume` 用 `copyForwards` 破坏 `peek` 切片的问题——
/// `byte_parser` 在 `consume(total_len)` 后返回借用 `peek` 切片的 Frame，
/// 旧实现的 `copyForwards` 会覆盖该切片，导致 payload 乱码。
pub const FrameReader = struct {
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    const Self = @This();
    /// 当 start 超过此值时压缩缓冲区（把未读数据移回开头）。
    const COMPACT_THRESHOLD: usize = 4096;

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    /// **仅供测试**：向缓冲区注入数据，模拟"后续数据到达"。
    pub fn injectForTest(self: *Self, allocator: std.mem.Allocator, data: []const u8) !void {
        try self.buf.appendSlice(allocator, data);
    }

    /// 当前未读数据长度。
    fn pending(self: *const Self) usize {
        return self.buf.items.len - self.start;
    }

    /// 未读数据切片。
    fn pendingSlice(self: *Self) []u8 {
        return self.buf.items[self.start..];
    }

    /// 读取直到未读数据至少包含 `n` 字节。
    /// 返回 `false` 表示 EOF（连接关闭）。
    pub fn ensure(self: *Self, reader: *std.Io.Reader, allocator: std.mem.Allocator, n: usize, max_total: usize) !bool {
        while (self.pending() < n) {
            if (!try self.readMore(reader, allocator, max_total)) return false;
        }
        return true;
    }

    /// 丢弃 `magic` 之前的垃圾字节，使未读数据以 `magic` 开头（若存在）。
    /// 返回 `false` 表示 EOF（未找到 magic 且连接关闭）。
    pub fn readUntilMagic(self: *Self, reader: *std.Io.Reader, allocator: std.mem.Allocator, magic: []const u8, max_total: usize) !bool {
        while (true) {
            const data = self.pendingSlice();
            if (std.mem.indexOf(u8, data, magic)) |pos| {
                if (pos > 0) self.consume(pos);
                return true;
            }

            // 保留末尾可能匹配 magic 前缀的部分
            var keep: usize = 0;
            var k: usize = @min(magic.len - 1, data.len);
            while (k > 0) : (k -= 1) {
                if (std.mem.eql(u8, data[data.len - k ..], magic[0..k])) {
                    keep = k;
                    break;
                }
            }
            if (keep < data.len) {
                self.consume(data.len - keep);
            }

            if (!try self.readMore(reader, allocator, max_total)) return false;
        }
    }

    /// 读取一行（`\n` 结尾，兼容 `\r\n`，去除行尾换行符）。
    /// 返回 owned 副本；`null` 表示 EOF。行超长返回 `error.StreamTooLong`。
    pub fn readLine(self: *Self, reader: *std.Io.Reader, allocator: std.mem.Allocator, max_len: usize) !?[]u8 {
        while (true) {
            const data = self.pendingSlice();
            if (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
                if (nl > max_len) return error.StreamTooLong;
                var end = nl;
                if (end > 0 and data[end - 1] == '\r') end -= 1;
                const line = try allocator.dupe(u8, data[0..end]);
                self.consume(nl + 1);
                return line;
            }
            if (data.len > max_len) return error.StreamTooLong;
            if (!try self.readMore(reader, allocator, max_len)) {
                if (data.len == 0) return null;
                const line = try allocator.dupe(u8, data);
                self.consume(data.len);
                return line;
            }
        }
    }

    /// 查看未读数据前 `n` 字节（不消费）。
    /// 返回的切片在下次 `readMore` 前始终有效（`consume` 不移动内存）。
    pub fn peek(self: *Self, n: usize) []const u8 {
        return self.buf.items[self.start .. self.start + n];
    }

    /// 消费（丢弃）未读数据前 `n` 字节。只前进 `start`，不移动/释放内存。
    /// **关键**：不调 clearRetainingCapacity/shrinkRetainingCapacity——
    /// ArrayList 的 shrink 会释放底层内存，DebugAllocator 随即用 0xAA poison 填充，
    /// 导致 parse() 返回的借用切片（指向同一块内存）读到全 0xAA。
    pub fn consume(self: *Self, n: usize) void {
        std.debug.assert(n <= self.pending());
        self.start += n;
        // 不动 buf.items.len / capacity——保留物理内存供借用切片使用。
        // pending() = len - start，当 start 追上 len 时 pending()=0，逻辑上空。
        // 下次 readMore 开头的 compact 会把 start 归零。
        // start 过大时压缩，避免 buf 无限增长（此时借用切片已不再使用）。
        if (self.start > COMPACT_THRESHOLD and self.start < self.buf.items.len) {
            const remaining = self.buf.items.len - self.start;
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.start..]);
            self.buf.shrinkRetainingCapacity(remaining);
            self.start = 0;
        }
    }

    fn readMore(self: *Self, reader: *std.Io.Reader, allocator: std.mem.Allocator, max_total: usize) !bool {
        // 先尝试压缩：如果 start 较大，把未读数据移回开头，腾出尾部空间
        if (self.start > 0) {
            const remaining = self.buf.items.len - self.start;
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.start..]);
            self.buf.shrinkRetainingCapacity(remaining);
            self.start = 0;
        }

        var tmp: [4096]u8 = undefined;
        var iov: [1][]u8 = .{tmp[0..]};
        const n = reader.readVec(&iov) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => |e| {
                std.log.warn("readMore: readVec error: {s}", .{@errorName(e)});
                return e;
            },
        };
        if (n == 0) return false;
        try self.buf.appendSlice(allocator, tmp[0..n]);
        if (self.buf.items.len > max_total) return error.StreamTooLong;
        return true;
    }
};

const testing = std.testing;

test "frame_reader readLine basic" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    var reader = std.Io.Reader.fixed("hello\nworld\n");
    const l1 = (try fr.readLine(&reader, alloc, 1024)).?;
    defer alloc.free(l1);
    try testing.expectEqualStrings("hello", l1);

    const l2 = (try fr.readLine(&reader, alloc, 1024)).?;
    defer alloc.free(l2);
    try testing.expectEqualStrings("world", l2);

    try testing.expect((try fr.readLine(&reader, alloc, 1024)) == null);
}

test "frame_reader readLine crlf" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    var reader = std.Io.Reader.fixed("hello\r\n");
    const line = (try fr.readLine(&reader, alloc, 1024)).?;
    defer alloc.free(line);
    try testing.expectEqualStrings("hello", line);
}

test "frame_reader readLine eof without newline" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    var reader = std.Io.Reader.fixed("hello");
    const line = (try fr.readLine(&reader, alloc, 1024)).?;
    defer alloc.free(line);
    try testing.expectEqualStrings("hello", line);

    try testing.expect((try fr.readLine(&reader, alloc, 1024)) == null);
}

test "frame_reader readLine exceeds max_len" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    var reader = std.Io.Reader.fixed("this is a very long line without newline");
    try testing.expectError(error.StreamTooLong, fr.readLine(&reader, alloc, 8));
}

test "frame_reader ensure + peek + consume" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    var reader = std.Io.Reader.fixed("abcdef");
    try testing.expect(try fr.ensure(&reader, alloc, 3, 1024));
    try testing.expectEqualStrings("abc", fr.peek(3));
    fr.consume(3);
    try testing.expectEqualStrings("def", fr.peek(3));
}

test "frame_reader peek valid after consume (key regression test)" {
    // 回归测试：consume 后 peek 返回的切片必须仍有效。
    // 旧实现 copyForwards 会破坏切片，导致 payload 乱码。
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    var reader = std.Io.Reader.fixed("AAAABBBB");
    try fr.ensure(&reader, alloc, 8, 1024);
    const first4 = fr.peek(4);
    try testing.expectEqualStrings("AAAA", first4);
    fr.consume(4);
    // first4 指向的内存必须仍为 "AAAA"（未被 consume 破坏）
    try testing.expectEqualStrings("AAAA", first4);
    const next4 = fr.peek(4);
    try testing.expectEqualStrings("BBBB", next4);
}

test "frame_reader readUntilMagic discards garbage" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    const magic = [_]u8{ 0x55, 0xAA };
    var reader = std.Io.Reader.fixed(&.{ 0x11, 0x22, 0x55, 0xAA, 0x33 });
    try testing.expect(try fr.readUntilMagic(&reader, alloc, &magic, 1024));
    try testing.expectEqualSlices(u8, &.{ 0x55, 0xAA, 0x33 }, fr.peek(3));
}

test "frame_reader readUntilMagic partial magic across boundary" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    const magic = [_]u8{ 0x55, 0xAA };
    try fr.injectForTest(alloc, &.{ 0x11, 0x55 });
    var reader = std.Io.Reader.fixed(&.{ 0xAA, 0x22 });
    try testing.expect(try fr.readUntilMagic(&reader, alloc, &magic, 1024));
    try testing.expectEqualSlices(u8, &.{ 0x55, 0xAA, 0x22 }, fr.peek(3));
}

test "frame_reader readUntilMagic eof with garbage" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    const magic = [_]u8{ 0x55, 0xAA };
    var reader = std.Io.Reader.fixed(&.{ 0x11, 0x22 });
    try testing.expect(!try fr.readUntilMagic(&reader, alloc, &magic, 1024));
    try testing.expectEqual(@as(usize, 0), fr.pending());
}

test "frame_reader readUntilMagic garbage exceeds max_total" {
    const alloc = testing.allocator;
    var fr = FrameReader{};
    defer fr.deinit(alloc);

    const magic = [_]u8{ 0x55, 0xAA };
    var garbage: [4000]u8 = @splat(0x11);
    var reader = std.Io.Reader.fixed(&garbage);
    try testing.expectError(error.StreamTooLong, fr.readUntilMagic(&reader, alloc, &magic, 8192));
}
