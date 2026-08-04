const std = @import("std");
const Id = @import("parser").Id;

/// 命令 handler 注册表，统一使用 `Frame.Id` 作为命令标识。
///
/// 内部维护两张 map：int id 和 str id 各一张，对应 `Id` 的两个 union 分支。
/// `dispatch` 根据 `Id` 的 tag 路由到对应 map。
/// 这样所有 parser 产出的 Frame 都能统一分发，无需为不同 IdType 实例化不同的 Registry。
pub const HandlerRegistry = struct {
    pub const Handler = *const fn (id: Id, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8;

    allocator: std.mem.Allocator,
    int_map: std.AutoHashMap(u64, Handler),
    str_map: std.StringHashMap(Handler),
    default_handler: ?Handler = null,

    pub fn init(allocator: std.mem.Allocator) HandlerRegistry {
        return .{
            .allocator = allocator,
            .int_map = std.AutoHashMap(u64, Handler).init(allocator),
            .str_map = std.StringHashMap(Handler).init(allocator),
        };
    }

    pub fn deinit(self: *HandlerRegistry) void {
        var it = self.str_map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.str_map.deinit();
        self.int_map.deinit();
    }

    pub fn register(self: *HandlerRegistry, id: Id, handler: Handler) !void {
        switch (id) {
            .int => |n| try self.int_map.put(n, handler),
            .str => |s| {
                const owned = try self.allocator.dupe(u8, s);
                errdefer self.allocator.free(owned);
                const gop = try self.str_map.getOrPut(owned);
                if (gop.found_existing) self.allocator.free(owned);
                gop.value_ptr.* = handler;
            },
        }
    }

    pub fn setDefault(self: *HandlerRegistry, handler: Handler) void {
        self.default_handler = handler;
    }

    pub fn dispatch(self: *HandlerRegistry, id: Id, data: []const u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const handler: ?Handler = switch (id) {
            .int => |n| self.int_map.get(n),
            .str => |s| self.str_map.get(s),
        };
        if (handler) |h| return h(id, data, allocator);
        if (self.default_handler) |h| return h(id, data, allocator);
        return null;
    }
};
