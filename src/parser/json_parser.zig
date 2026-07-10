const std = @import("std");
const readLine = @import("config").util.readLine;

pub fn JsonLineParser(comptime IdType: type) type {
    return struct {
        cmd: IdType,
        addr: []const u8,
        data: []const u8,
        allocator: std.mem.Allocator,

        pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !@This() {
            const raw = try readLine(reader, allocator);
            errdefer allocator.free(raw);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) return error.InvalidJson;

            const obj = root.object;

            const cmd_val = obj.get("cmd") orelse return error.MissingField;
            const addr_val = obj.get("addr") orelse return error.MissingField;
            if (addr_val.string.len == 0) return error.InvalidAddr;

            const cmd: IdType = try parseCmd(cmd_val, allocator);

            return .{
                .cmd = cmd,
                .addr = try allocator.dupe(u8, addr_val.string),
                .data = raw,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (comptime IdType == []const u8) self.allocator.free(self.cmd);
            self.allocator.free(self.addr);
            self.allocator.free(self.data);
        }

        fn parseCmd(val: std.json.Value, allocator: std.mem.Allocator) !IdType {
            if (comptime IdType == []const u8) {
                if (val.string.len == 0) return error.InvalidCmd;
                return try allocator.dupe(u8, val.string);
            }
            if (comptime std.meta.trait.isInteger(IdType)) {
                return @as(IdType, @intCast(val.integer));
            }
            @compileError("unsupported IdType: " ++ @typeName(IdType));
        }
    };
}
