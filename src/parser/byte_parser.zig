const std = @import("std");
const Frame = @import("frame.zig").Frame;
const FrameReader = @import("frame_reader.zig").FrameReader;
const Parser = @import("interface.zig").Parser;

/// 二进制协议编解码。
///
/// 帧格式：
///   [55 AA] [type:1] [length:4 LE] [payload:N] [checksum:2 LE]
///
/// - Header: 固定 `0x55 0xAA`
/// - Type: 包类型（1 字节）
/// - Length: payload 长度，小端 u32（不含 header/type/length/checksum 自身）
/// - Payload: 变长数据
/// - Checksum: 从 header 开始到 payload 结束所有字节的 wrapping 累加和（u16 低 16 位）
pub const MAGIC: [2]u8 = .{ 0x55, 0xAA };
pub const HEADER: [2]u8 = .{ 0x55, 0xAA };
pub const HEADER_LEN: usize = 2 + 1 + 4 + 2; // magic + type + length + checksum
pub const MAX_PAYLOAD_LEN: usize = 1024 * 1024;
pub const MAX_FRAME_LEN = HEADER_LEN + MAX_PAYLOAD_LEN;

pub const ByteParser = struct {
    allocator: std.mem.Allocator,
    fr: FrameReader = .{},

    pub fn create(allocator: std.mem.Allocator) !*Parser {
        const self = try allocator.create(ByteParser);
        self.* = .{ .allocator = allocator };
        const parser = try allocator.create(Parser);
        parser.* = .{ .ptr = self, .vtable = &vtable };
        return parser;
    }

    fn parseImpl(ptr: *anyopaque, reader: *std.Io.Reader, allocator: std.mem.Allocator) anyerror!?Frame {
        const self: *ByteParser = @ptrCast(@alignCast(ptr));
        while (true) {
            if (!try self.fr.readUntilMagic(reader, allocator, &MAGIC, MAX_FRAME_LEN)) return null;

            if (!try self.fr.ensure(reader, allocator, HEADER_LEN, MAX_FRAME_LEN)) return null;
            const head = self.fr.peek(HEADER_LEN);

            const payload_len: usize = @intCast(std.mem.readInt(u32, head[3..7], .little));
            if (payload_len > MAX_PAYLOAD_LEN) return error.FrameTooLarge;

            const total_len = HEADER_LEN + payload_len;
            if (!try self.fr.ensure(reader, allocator, total_len, MAX_FRAME_LEN)) return null;
            const frame_bytes = self.fr.peek(total_len);

            var sum: u16 = 0;
            for (frame_bytes[0 .. total_len - 2]) |b| sum +%= b;
            const checksum = std.mem.readInt(u16, frame_bytes[total_len - 2 ..][0..2], .little);
            if (sum != checksum) {
                self.fr.consume(1);
                continue;
            }

            const payload = frame_bytes[7 .. 7 + payload_len];
            self.fr.consume(total_len);

            return Frame{
                .id = .{ .int = frame_bytes[2] },
                .raw = frame_bytes,
                .payload = payload,
            };
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ByteParser = @ptrCast(@alignCast(ptr));
        self.fr.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    const vtable = Parser.VTable{
        .parse = parseImpl,
        .deinit = deinitImpl,
    };
};

/// 编码一帧完整数据包。
/// `payload` 为业务载荷；调用方拥有返回的切片，需自行 `allocator.free`。
pub fn encode(allocator: std.mem.Allocator, packet_type: u8, payload: []const u8) ![]u8 {
    const total_len = HEADER_LEN + payload.len;
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

fn createByteParser(alloc: std.mem.Allocator) !*Parser {
    return ByteParser.create(alloc);
}

/// 测试辅助：直接创建 ByteParser 实例（绕过 Parser 接口），便于测试内部状态。
fn createRaw(alloc: std.mem.Allocator) *ByteParser {
    const self = alloc.create(ByteParser) catch unreachable;
    self.* = .{ .allocator = alloc };
    return self;
}

test "byte_parser valid frame" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    const frame_bytes = try encode(alloc, 0x1B, "hello");
    defer alloc.free(frame_bytes);

    var reader = std.Io.Reader.fixed(frame_bytes);
    const fv = (try parser.parse(&reader, alloc)).?;

    try testing.expectEqual(@as(u64, 0x1B), fv.id.int);
    try testing.expectEqualStrings("hello", fv.payload);
    try testing.expectEqualSlices(u8, frame_bytes, fv.raw);
}

test "byte_parser partial frame then complete" {
    const alloc = testing.allocator;
    const raw_parser = createRaw(alloc);
    defer {
        raw_parser.fr.deinit(alloc);
        alloc.destroy(raw_parser);
    }
    var parser = Parser{ .ptr = raw_parser, .vtable = &ByteParser.vtable };

    var reader = std.Io.Reader.fixed(&.{ 0x55, 0xAA, 0x01 });
    try testing.expect((try parser.parse(&reader, alloc)) == null);

    const frame_bytes = try encode(alloc, 0x01, "hello");
    defer alloc.free(frame_bytes);
    try raw_parser.fr.injectForTest(alloc, frame_bytes[3..]);

    var reader2 = std.Io.Reader.fixed(&.{});
    const fv = (try parser.parse(&reader2, alloc)).?;
    try testing.expectEqual(@as(u64, 0x01), fv.id.int);
    try testing.expectEqualStrings("hello", fv.payload);
}

test "byte_parser garbage before header" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    const frame_bytes = try encode(alloc, 0x1B, "dev1");
    defer alloc.free(frame_bytes);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(alloc);
    try buffer.appendSlice(alloc, &.{ 0x00, 0x01, 0x02 });
    try buffer.appendSlice(alloc, frame_bytes);

    var reader = std.Io.Reader.fixed(buffer.items);
    const fv = (try parser.parse(&reader, alloc)).?;
    try testing.expectEqual(@as(u64, 0x1B), fv.id.int);
    try testing.expectEqualStrings("dev1", fv.payload);
}

test "byte_parser checksum mismatch returns null" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var bad: [HEADER_LEN + 1]u8 = undefined;
    bad[0] = 0x55;
    bad[1] = 0xAA;
    bad[2] = 0x01;
    std.mem.writeInt(u32, bad[3..7], 1, .little);
    bad[7] = 0x42;
    std.mem.writeInt(u16, bad[8..10], 0xFFFF, .little);

    var reader = std.Io.Reader.fixed(&bad);
    try testing.expect((try parser.parse(&reader, alloc)) == null);
}

test "byte_parser empty buffer eof" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var reader = std.Io.Reader.fixed(&.{});
    try testing.expect((try parser.parse(&reader, alloc)) == null);
}

test "byte_parser two frames back to back" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    const f1 = try encode(alloc, 0x01, "a");
    defer alloc.free(f1);
    const f2 = try encode(alloc, 0x02, "bb");
    defer alloc.free(f2);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(alloc);
    try buffer.appendSlice(alloc, f1);
    try buffer.appendSlice(alloc, f2);

    var reader = std.Io.Reader.fixed(buffer.items);
    const fv1 = (try parser.parse(&reader, alloc)).?;
    try testing.expectEqual(@as(u64, 0x01), fv1.id.int);

    const fv2 = (try parser.parse(&reader, alloc)).?;
    try testing.expectEqual(@as(u64, 0x02), fv2.id.int);

    try testing.expect((try parser.parse(&reader, alloc)) == null);
}

test "byte_parser payload too large returns FrameTooLarge" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var head: [HEADER_LEN]u8 = undefined;
    head[0] = 0x55;
    head[1] = 0xAA;
    head[2] = 0x01;
    std.mem.writeInt(u32, head[3..7], @as(u32, @intCast(MAX_PAYLOAD_LEN + 1)), .little);
    std.mem.writeInt(u16, head[7..9], 0, .little);

    var reader = std.Io.Reader.fixed(&head);
    try testing.expectError(error.FrameTooLarge, parser.parse(&reader, alloc));
}

test "byte_parser large frame stays valid after consume" {
    // 回归测试：payload 超过 FrameReader.COMPACT_THRESHOLD（4096）时，
    // consume 若触发内存移动会破坏借用缓冲区，导致返回的 Frame.payload 悬垂。
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    const payload1 = try alloc.alloc(u8, 5000);
    defer alloc.free(payload1);
    @memset(payload1, 0x41); // 'A'
    const payload2 = try alloc.alloc(u8, 5000);
    defer alloc.free(payload2);
    @memset(payload2, 0x42); // 'B'

    const f1 = try encode(alloc, 0x01, payload1);
    defer alloc.free(f1);
    const f2 = try encode(alloc, 0x02, payload2);
    defer alloc.free(f2);

    // 两帧连在一起：parse 第一帧时 consume(total_len) 会让 start>4096 触发 compact
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(alloc);
    try buffer.appendSlice(alloc, f1);
    try buffer.appendSlice(alloc, f2);

    var reader = std.Io.Reader.fixed(buffer.items);
    const fv1 = (try parser.parse(&reader, alloc)).?;
    // 若 consume compact 破坏了借用缓冲区，此处 payload 内容不再是 'A' 串
    try testing.expectEqualSlices(u8, payload1, fv1.payload);

    const fv2 = (try parser.parse(&reader, alloc)).?;
    try testing.expectEqualSlices(u8, payload2, fv2.payload);
}

test "byte_parser Frame dup" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    const frame_bytes = try encode(alloc, 0x1B, "world");
    defer alloc.free(frame_bytes);

    var reader = std.Io.Reader.fixed(frame_bytes);
    const fv = (try parser.parse(&reader, alloc)).?;
    var owned = try fv.dup(alloc);
    defer owned.deinit(alloc);

    try testing.expect((try parser.parse(&reader, alloc)) == null);
    try testing.expectEqual(@as(u64, 0x1B), owned.id.int);
    try testing.expectEqualStrings("world", owned.payload);
    try testing.expectEqualSlices(u8, frame_bytes, owned.raw);
}
