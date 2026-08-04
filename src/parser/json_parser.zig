const std = @import("std");
const Frame = @import("frame.zig").Frame;
const Id = @import("frame.zig").Id;
const FrameReader = @import("frame_reader.zig").FrameReader;
const Parser = @import("interface.zig").Parser;

/// JSON 行协议 Parser，用于 HW（硬件）连接。
///
/// 每行一个 JSON 对象，例如：
///   {"cmd": "on", "addr": "dev1"}
///   {"cmd": "on", "addr": ["dev1", "dev2"]}
///
/// 实现 `Parser` 接口（vtable）。字符串 `id` 借用 `raw` 中的 JSON 文本，
/// 通过 `locateJsonValue` 定位（不依赖 std.json arena）。
pub const MAX_LINE_LEN: usize = 64 * 1024;

pub const JsonLineParser = struct {
    allocator: std.mem.Allocator,
    fr: FrameReader = .{},
    /// 上一行的 owned 副本。`parse` 返回的 `Frame.raw` 借用此字段，
    /// 下次 `parse` 时释放。这样 `Frame.raw` 的所有权语义与 ByteParser 一致
    /// （都是借用，调用方无需 free）。
    last_line: []u8 = &.{},

    pub fn create(allocator: std.mem.Allocator) !*Parser {
        const self = try allocator.create(JsonLineParser);
        self.* = .{ .allocator = allocator };
        const parser = try allocator.create(Parser);
        parser.* = .{ .ptr = self, .vtable = &vtable };
        return parser;
    }

    fn parseImpl(ptr: *anyopaque, reader: *std.Io.Reader, allocator: std.mem.Allocator) anyerror!?Frame {
        const self: *JsonLineParser = @ptrCast(@alignCast(ptr));
        // 释放上一行的 owned 副本（上次 parse 返回的 Frame.raw 借用它，现已用完）
        if (self.last_line.len > 0) {
            allocator.free(self.last_line);
            self.last_line = &.{};
        }

        const raw = try self.fr.readLine(reader, allocator, MAX_LINE_LEN) orelse return null;
        errdefer allocator.free(raw);
        self.last_line = raw; // 保存 owned 副本，raw 借用它的内存

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJson;

        const cmd_val = root.object.get("cmd") orelse return error.MissingField;

        const id: Id = switch (cmd_val) {
            .string => |s| blk: {
                if (s.len == 0) return error.InvalidCmd;
                const id_slice = locateJsonValue(raw, "cmd", s) orelse return error.InvalidCmd;
                break :blk .{ .str = id_slice };
            },
            .integer => |n| .{ .int = @intCast(n) },
            else => return error.InvalidCmd,
        };

        return Frame{
            .id = id,
            .raw = raw,
            .payload = raw,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *JsonLineParser = @ptrCast(@alignCast(ptr));
        if (self.last_line.len > 0) {
            self.allocator.free(self.last_line);
        }
        self.fr.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    const vtable = Parser.VTable{
        .parse = parseImpl,
        .deinit = deinitImpl,
    };
};

/// 在 JSON 文本 `raw` 中定位 `"key":"value"` 的 value 子串。
/// `expected` 用于校验找到的值与 json 解析结果一致。
/// 不处理转义——协议级标识符不应包含转义字符。
fn locateJsonValue(raw: []const u8, key: []const u8, expected: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (search_start < raw.len) {
        const quote_pos = std.mem.indexOfScalarPos(u8, raw, search_start, '"') orelse return null;
        const key_end = quote_pos + 1 + key.len;
        if (key_end >= raw.len or raw[key_end] != '"') {
            search_start = quote_pos + 1;
            continue;
        }
        if (std.mem.eql(u8, raw[quote_pos + 1 .. key_end], key)) {
            var p = key_end + 1;
            while (p < raw.len and (raw[p] == ' ' or raw[p] == ':' or raw[p] == '\t')) p += 1;
            if (p >= raw.len or raw[p] != '"') return null;
            const val_start = p + 1;
            const val_end = std.mem.indexOfScalarPos(u8, raw, val_start, '"') orelse return null;
            const found = raw[val_start..val_end];
            if (std.mem.eql(u8, found, expected)) return found;
            return null;
        }
        search_start = quote_pos + 1;
    }
    return null;
}

const testing = std.testing;

test "json_parser parse full frame" {
    const alloc = testing.allocator;
    var parser = try JsonLineParser.create(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var reader = std.Io.Reader.fixed("{\"cmd\":\"hi\",\"addr\":\"dev1\"}\n");
    const fv = (try parser.parse(&reader, alloc)).?;

    try testing.expectEqualStrings("hi", fv.id.str);
    try testing.expectEqualStrings("{\"cmd\":\"hi\",\"addr\":\"dev1\"}", fv.raw);
    try testing.expectEqualStrings(fv.raw, fv.payload);
    // raw 借用 parser 内部 last_line，无需调用方 free
}

test "json_parser parse integer id" {
    const alloc = testing.allocator;
    var parser = try JsonLineParser.create(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var reader = std.Io.Reader.fixed("{\"cmd\":42,\"addr\":\"dev1\"}\n");
    const fv = (try parser.parse(&reader, alloc)).?;
    try testing.expectEqual(@as(u64, 42), fv.id.int);
    // raw 借用 parser 内部 last_line，无需调用方 free
}

test "json_parser line exceeds max_len" {
    const alloc = testing.allocator;
    var parser = try JsonLineParser.create(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var long: [100_000]u8 = @splat('a');
    var reader = std.Io.Reader.fixed(&long);
    try testing.expectError(error.StreamTooLong, parser.parse(&reader, alloc));
}

test "json_parser invalid json" {
    const alloc = testing.allocator;
    var parser = try JsonLineParser.create(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var reader = std.Io.Reader.fixed("not json\n");
    try testing.expectError(error.InvalidJson, parser.parse(&reader, alloc));
}

test "json_parser missing cmd" {
    const alloc = testing.allocator;
    var parser = try JsonLineParser.create(alloc);
    defer {
        parser.deinit();
        alloc.destroy(parser);
    }

    var reader = std.Io.Reader.fixed("{\"addr\":\"dev1\"}\n");
    try testing.expectError(error.MissingField, parser.parse(&reader, alloc));
}

test "json_parser locateJsonValue" {
    try testing.expectEqualStrings("hi", locateJsonValue("{\"cmd\":\"hi\"}", "cmd", "hi").?);
    try testing.expectEqualStrings("box", locateJsonValue("{\"a\":1,\"cmd\":\"box\"}", "cmd", "box").?);
    try testing.expectEqualStrings("on", locateJsonValue("{\"cmd\" : \"on\"}", "cmd", "on").?);
    try testing.expect(locateJsonValue("{\"cmd\":\"hi\"}", "cmd", "no") == null);
}
