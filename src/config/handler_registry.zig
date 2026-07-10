const std = @import("std");

pub fn HandlerRegistry(comptime IdType: type) type {
    return struct {
        pub const Handler = *const fn (id: IdType, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8;

        allocator: std.mem.Allocator,
        entries: std.ArrayListUnmanaged(struct { id: IdType, handler: Handler }),
        default_handler: ?Handler = null,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .entries = .empty,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (comptime IdType == []const u8) {
                for (self.entries.items) |*e| self.allocator.free(e.id);
            }
            self.entries.deinit(self.allocator);
        }

        pub fn register(self: *@This(), id: IdType, handler: Handler) !void {
            const owned_id = if (comptime IdType == []const u8)
                try self.allocator.dupe(u8, id)
            else
                id;
            errdefer if (comptime IdType == []const u8) self.allocator.free(owned_id);
            try self.entries.append(self.allocator, .{ .id = owned_id, .handler = handler });
        }

        pub fn setDefault(self: *@This(), handler: Handler) void {
            self.default_handler = handler;
        }

        pub fn dispatch(self: *@This(), id: IdType, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
            for (self.entries.items) |entry| {
                if (idsMatch(entry.id, id)) {
                    if (try entry.handler(id, data, allocator)) |result| {
                        return result;
                    }
                    return null;
                }
            }
            if (self.default_handler) |h| {
                return h(id, data, allocator);
            }
            return null;
        }

        fn idsMatch(a: IdType, b: IdType) bool {
            if (comptime IdType == []const u8) return std.mem.eql(u8, a, b);
            return a == b;
        }
    };
}
