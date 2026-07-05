const std = @import("std");

pub const HEADER: u16 = 0xEB90;
pub const HEADER_LEN: usize = 2;
pub const TYPE_LEN: usize = 1;
pub const BOARD_ID_LEN: usize = 1;
pub const LENGTH_FIELD_LEN: usize = 4;
pub const CHECKSUM_LEN: usize = 2;
pub const MIN_PACKET_LEN: usize = HEADER_LEN + TYPE_LEN + BOARD_ID_LEN + LENGTH_FIELD_LEN + CHECKSUM_LEN;
pub const MAX_PAYLOAD_LEN: usize = 1024 * 1024 * 1024; // 1024MB

/// Streaming binary protocol decoder.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{
            .allocator = allocator,
            .buf = .empty,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn feed(self: *Decoder, data: []const u8) !void {
        try self.buf.appendSlice(self.allocator, data);
    }

    /// Try to extract one complete packet. Returns `null` if more data is needed.
    /// Invalid data before a valid header is discarded.
    pub fn decode(self: *Decoder) !?[]u8 {
        const data = self.buf.items;
        if (data.len < MIN_PACKET_LEN) return null;

        const start = findHeader(data) orelse {
            // 保留最后一个字节 0xEB（可能是跨 buffer 边界的 header 起始）
            if (data.len > 0 and data[data.len - 1] == 0xEB) {
                self.buf.items[0] = 0xEB;
                self.buf.shrinkRetainingCapacity(1);
            } else {
                self.buf.clearRetainingCapacity();
            }
            return null;
        };

        // Compact: shift remaining data left
        if (start > 0) {
            std.mem.copyForwards(u8, data[0 .. data.len - start], data[start..]);
            self.buf.shrinkRetainingCapacity(data.len - start);
        }

        if (self.buf.items.len < MIN_PACKET_LEN) return null;

        const payload_len = std.mem.readInt(u32, self.buf.items[4..8], .little);
        if (payload_len > MAX_PAYLOAD_LEN) {
            std.log.warn("custom_codec: payload too large: {} > {}", .{ payload_len, MAX_PAYLOAD_LEN });
            self.buf.clearRetainingCapacity();
            return error.PayloadTooLarge;
        }
        const total_len = HEADER_LEN + TYPE_LEN + BOARD_ID_LEN + LENGTH_FIELD_LEN + @as(usize, payload_len) + CHECKSUM_LEN;

        if (self.buf.items.len < total_len) return null;

        const packet = try self.allocator.dupe(u8, self.buf.items[0..total_len]);

        // Remove consumed bytes
        if (self.buf.items.len > total_len) {
            std.mem.copyForwards(u8, self.buf.items[0 .. self.buf.items.len - total_len], self.buf.items[total_len..]);
        }
        self.buf.shrinkRetainingCapacity(self.buf.items.len - total_len);

        return packet;
    }
};

fn findHeader(data: []const u8) ?usize {
    if (data.len < 2) return null;
    var i: usize = 0;
    while (i < data.len - 1) : (i += 1) {
        if (data[i] == 0xEB and data[i + 1] == 0x90) return i;
    }
    return null;
}

pub fn checksum(data: []const u8) u16 {
    var sum: u16 = 0;
    for (data) |b| sum +%= b;
    return sum;
}

pub fn encode(allocator: std.mem.Allocator, packet_type: u8, board_id: u8, payload: []const u8) ![]u8 {
    const total = HEADER_LEN + TYPE_LEN + BOARD_ID_LEN + LENGTH_FIELD_LEN + payload.len + CHECKSUM_LEN;
    var buf = try std.ArrayList(u8).initCapacity(allocator, total);
    defer buf.deinit(allocator);

    buf.appendSliceAssumeCapacity(&.{ 0xEB, 0x90 });
    buf.appendSliceAssumeCapacity(&.{ packet_type, board_id });

    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @as(u32, @intCast(payload.len)), .little);
    buf.appendSliceAssumeCapacity(&len_buf);

    buf.appendSliceAssumeCapacity(payload);

    const cs = checksum(buf.items);
    var cs_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &cs_buf, cs, .little);
    buf.appendSliceAssumeCapacity(&cs_buf);

    return buf.toOwnedSlice(allocator);
}

test "encode/decode roundtrip" {
    const alloc = std.testing.allocator;
    const encoded = try encode(alloc, 0x1B, 0x01, &.{ 0x01, 0x02, 0x03 });
    defer alloc.free(encoded);

    var dec = Decoder.init(alloc);
    defer dec.deinit();
    try dec.feed(encoded);

    const pkt = (try dec.decode()).?;
    defer alloc.free(pkt);
    try std.testing.expectEqualSlices(u8, encoded, pkt);
}

test "decode ignores garbage" {
    const alloc = std.testing.allocator;
    var dec = Decoder.init(alloc);
    defer dec.deinit();

    try dec.feed(&.{ 0x00, 0xFF, 0xAA });
    const encoded = try encode(alloc, 0x01, 0x00, &.{0x10});
    defer alloc.free(encoded);
    try dec.feed(encoded);

    const pkt = try dec.decode();
    defer if (pkt) |p| alloc.free(p);
    try std.testing.expect(pkt != null);
}

test "decode returns null on incomplete" {
    const alloc = std.testing.allocator;
    var dec = Decoder.init(alloc);
    defer dec.deinit();
    try dec.feed(&.{ 0xEB, 0x90, 0x01, 0x00 });
    try std.testing.expect((try dec.decode()) == null);
}
