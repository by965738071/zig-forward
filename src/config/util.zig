const std = @import("std");
const net = std.Io.net;

/// Hex-encode bytes to uppercase hex string.
/// Caller owns the returned memory.
pub fn hexEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const hex_chars = "0123456789ABCDEF";
    var result = try std.ArrayList(u8).initCapacity(allocator, data.len * 2);
    for (data) |byte| {
        result.appendAssumeCapacity(hex_chars[byte >> 4]);
        result.appendAssumeCapacity(hex_chars[byte & 0x0F]);
    }
    return result.toOwnedSlice(allocator);
}

/// Millisecond timestamp since Unix epoch for JSON API responses.
/// Cross-platform: uses Io.Clock, not posix.
pub fn currentTimestamp(io: std.Io) i64 {
    const ts = std.Io.Clock.now(.real, io);
    // Convert nanoseconds to milliseconds
    return @divFloor(@as(i64, @intCast(ts.nanoseconds)), 1_000_000);
}

/// Read a single line (\n-terminated) from a buffered reader.
/// Returns `error.EndOfStream` when the connection is closed before any data.
/// Caller owns the returned memory.
///
/// Uses `Io.Reader.takeDelimiter` internally (buffer-capacity-limited).
pub fn readLine(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    const line = try reader.takeDelimiter('\n') orelse return error.EndOfStream;
    // Strip trailing \r (e.g. from \r\n line endings)
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return try allocator.dupe(u8, line[0 .. line.len - 1]);
    }
    return try allocator.dupe(u8, line);
}

test "currentTimestamp returns plausible value" {
    // 需要一个 Io 后端来获取时间戳
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    const ts = currentTimestamp(io);
    try std.testing.expect(ts > 0);
    // 2025-01-01 00:00:00 UTC ≈ 1735689600000 ms
    try std.testing.expect(ts > 1_700_000_000_000);
}
