const std = @import("std");
const readLine = @import("../../config/util.zig").readLine;

pub const PcDataInfo = struct {
    cmd: []const u8,
    addr: []const u8,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(reader: *std.Io.Reader, allocator: std.mem.Allocator) !@This() {
        const raw = try readLine(reader, allocator);
        errdefer allocator.free(raw);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJson;

        const obj = root.object;

        const cmd_val = obj.get("cmd") orelse return error.MissingField;
        if (cmd_val.string.len == 0) return error.InvalidClass;
        const addr_val = obj.get("addr") orelse return error.MissingField;
        if (addr_val.string.len == 0) return error.InvalidAddr;

        return .{
            .cmd = cmd_val.string,
            .addr = addr_val.string,
            .data = raw,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.raw);
    }
};
