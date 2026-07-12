const std = @import("std");
const readLine = @import("config").util.readLine;

pub fn JsonLineParser(comptime IdType: type) type {
    return struct {
        pub const Frame = struct {
            id: IdType,
            addrs: []const []const u8,
            data: []const u8,
            allocator: std.mem.Allocator,

            pub fn deinit(self: *@This()) void {
                if (comptime IdType == []const u8) self.allocator.free(self.id);
                for (self.addrs) |a| self.allocator.free(a);
                self.allocator.free(self.addrs);
                self.allocator.free(self.data);
            }
        };

        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn parse(_: *@This(), reader: *std.Io.Reader, allocator: std.mem.Allocator) !?Frame {
            const raw = readLine(reader, allocator) catch |err| {
                if (err == error.EndOfStream) return null;
                return err;
            };
            errdefer allocator.free(raw);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) return error.InvalidJson;

            const obj = root.object;

            const cmd_val = obj.get("cmd") orelse return error.MissingField;
            const addr_val = obj.get("addr") orelse return error.MissingField;

            const id: IdType = try parseCmd(cmd_val, allocator);

            var addrs_list = std.ArrayList([]const u8).empty;
            defer addrs_list.deinit(allocator);
            switch (addr_val) {
                .string => |s| {
                    if (s.len == 0) return error.InvalidAddr;
                    try addrs_list.append(allocator, try allocator.dupe(u8, s));
                },
                .array => |arr| {
                    if (arr.items.len == 0) return error.InvalidAddr;
                    for (arr.items) |item| {
                        const s = item.string;
                        if (s.len == 0) return error.InvalidAddr;
                        try addrs_list.append(allocator, try allocator.dupe(u8, s));
                    }
                },
                else => return error.InvalidAddr,
            }
            const addrs = try addrs_list.toOwnedSlice(allocator);

            return Frame{
                .id = id,
                .addrs = addrs,
                .data = raw,
                .allocator = allocator,
            };
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
