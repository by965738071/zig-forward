const std = @import("std");
const Frame = @import("frame.zig").Frame;
const FrameReader = @import("frame_reader.zig").FrameReader;
const Parser = @import("interface.zig").Parser;
const codec = @import("codec");

/// 二进制协议 Parser，用于 PC（上位机）连接。
///
/// 帧格式（与 `codec/codec.zig` 的编码严格一致）：
///   [55 AA] [type:1] [length:4 LE] [payload:N] [checksum:2 LE]
///
/// 实现 `Parser` 接口（vtable），可被 `PcServer` 以运行时方式持有。
/// 新增协议只需照此实现 vtable + `create` 工厂。
pub const MAGIC: [2]u8 = .{ 0x55, 0xAA };
pub const HEADER_LEN = codec.HEADER_LEN;
pub const MAX_PAYLOAD_LEN = codec.MAX_PAYLOAD_LEN;
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

    const frame_bytes = try codec.encode(alloc, 0x1B, "hello");
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

    const frame_bytes = try codec.encode(alloc, 0x01, "hello");
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

    const frame_bytes = try codec.encode(alloc, 0x1B, "dev1");
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

    const f1 = try codec.encode(alloc, 0x01, "a");
    defer alloc.free(f1);
    const f2 = try codec.encode(alloc, 0x02, "bb");
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

test "byte_parser Frame dup" {
    const alloc = testing.allocator;
    var parser = try createByteParser(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    const frame_bytes = try codec.encode(alloc, 0x1B, "world");
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
