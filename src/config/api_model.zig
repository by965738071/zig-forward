const std = @import("std");
const currentTimestamp = @import("util.zig").currentTimestamp;

/// JSON response model matching the Rust `ApiModel<T>`.
pub const ApiModel = struct {
    code: i8,
    msg: []const u8,
    body: ?std.json.Value,
    timestamp: i64,

    pub fn ok(io: std.Io, body: ?std.json.Value) ApiModel {
        return .{ .code = 0, .msg = "ok", .body = body, .timestamp = currentTimestamp(io) };
    }

    pub fn err(io: std.Io, msg: []const u8) ApiModel {
        return .{ .code = -1, .msg = msg, .body = null, .timestamp = currentTimestamp(io) };
    }

    pub fn new(io: std.Io, code: i8, msg: []const u8, body: ?std.json.Value) ApiModel {
        return .{ .code = code, .msg = msg, .body = body, .timestamp = currentTimestamp(io) };
    }

    /// Write JSON directly to a writer (no intermediate allocation).
    pub fn writeJson(self: *const ApiModel, w: *std.Io.Writer) !void {
        try std.json.Stringify.value(self.*, .{}, w);
        try w.writeAll("\n");
    }

    /// Serialize to an allocated []u8.
    /// Useful when you need a pre-built JSON string (e.g., for broadcastToA).
    pub fn toJsonAlloc(self: *const ApiModel, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }
};
