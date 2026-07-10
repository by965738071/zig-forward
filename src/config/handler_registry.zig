const std = @import("std");

pub fn HandlerRegistry(comptime IdType: type, comptime Context: type) type {
    return struct {
        pub const Handler = *const fn (ctx: Context, id: IdType, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8;
        pub const Map = if (IdType == []const u8) std.StringHashMap(Handler) else std.AutoHashMap(IdType, Handler);

        allocator: std.mem.Allocator,
        map: Map,
        default_handler: ?Handler = null,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .map = Map.init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            if (comptime IdType == []const u8) {
                var it = self.map.keyIterator();
                while (it.next()) |key| self.allocator.free(key.*);
            }
            self.map.deinit();
        }

        pub fn register(self: *@This(), id: IdType, handler: Handler) !void {
            if (comptime IdType == []const u8) {
                const owned_id = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(owned_id);
                const gop = try self.map.getOrPut(owned_id);
                if (gop.found_existing) self.allocator.free(owned_id);
                gop.value_ptr.* = handler;
            } else {
                try self.map.put(id, handler);
            }
        }

        pub fn setDefault(self: *@This(), handler: Handler) void {
            self.default_handler = handler;
        }

        pub fn dispatch(self: *@This(), ctx: Context, id: IdType, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
            if (self.map.get(id)) |handler| return handler(ctx, id, data, allocator);
            if (self.default_handler) |h| return h(ctx, id, data, allocator);
            return null;
        }
    };
}
