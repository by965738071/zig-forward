const std = @import("std");

/// Generic chain-of-responsibility handler registry.
///
/// Maps typed IDs to handler functions. Dispatch order:
///   1. Exact ID match among registered handlers
///   2. Default handler (fallback), if set
///
/// Each handler returns `?[]u8`:
///   - `null` = "skip me, try next"
///   - some = "I handled this" (caller must free returned memory)
///
/// # Type Parameters
///
/// - `IdType`: The key type. Use `u8` for hardware packet types, `[]const u8`
///   for PC command clazz strings. String keys are **cloned** on registration.
/// - `ContextType`: User-defined context passed to every handler invocation.
///   Use `void` if no context is needed.
///
/// # Usage (Hardware — packet_type → JSON string)
///
/// ```zig
/// var reg = HandlerRegistry(u8, void).init(allocator);
/// try reg.register(0x1B, myPacketHandler);
/// reg.setDefault(hexFallbackHandler);
/// const json = try reg.dispatch(&ctx, 0x1B, packet, allocator);
/// ```
///
/// # Usage (PC — clazz → command handler)
///
/// ```zig
/// var reg = HandlerRegistry([]const u8, PcContext).init(allocator);
/// try reg.register("Register", registerHandler);
/// try reg.register("Forward", forwardHandler);
/// ```
pub fn HandlerRegistry(comptime IdType: type, comptime ContextType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        entries: std.ArrayListUnmanaged(Entry),
        default_handler: ?Handler = null,

        pub const Handler = *const fn (
            ctx: *ContextType,
            id: IdType,
            data: []const u8,
            allocator: std.mem.Allocator,
        ) anyerror!?[]u8;

        const Entry = struct {
            id: IdType,
            handler: Handler,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .entries = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free owned string keys
            if (comptime IdType == []const u8) {
                for (self.entries.items) |*e| self.allocator.free(e.id);
            }
            self.entries.deinit(self.allocator);
        }

        /// Register a handler for a specific ID.
        /// If `IdType` is `[]const u8`, the key is cloned internally.
        pub fn register(self: *Self, id: IdType, handler: Handler) !void {
            const owned_id = if (comptime IdType == []const u8)
                try self.allocator.dupe(u8, id)
            else
                id;
            errdefer if (comptime IdType == []const u8) self.allocator.free(owned_id);
            try self.entries.append(self.allocator, .{ .id = owned_id, .handler = handler });
        }

        /// Set the default handler (called when no handler registers a match).
        pub fn setDefault(self: *Self, handler: Handler) void {
            self.default_handler = handler;
        }

        /// Dispatch a value to the appropriate handler.
        ///
        /// Returns the result of the **first** handler that returns non-null.
        /// Returns `null` if no handler (including default) handled the value.
        pub fn dispatch(
            self: *Self,
            ctx: *ContextType,
            id: IdType,
            data: []const u8,
            allocator: std.mem.Allocator,
        ) anyerror!?[]u8 {
            for (self.entries.items) |entry| {
                if (idsMatch(entry.id, id)) {
                    if (try entry.handler(ctx, id, data, allocator)) |result| {
                        return result; // handled with JSON response
                    }
                    return null; // handled but no response needed
                }
            }
            if (self.default_handler) |h| {
                return h(ctx, id, data, allocator);
            }
            return null; // no handler matched
        }

        fn idsMatch(a: IdType, b: IdType) bool {
            if (comptime IdType == []const u8) return std.mem.eql(u8, a, b);
            return a == b;
        }
    };
}

// ══════════════════════════════════════════
// Tests
// ══════════════════════════════════════════

test "HandlerRegistry(u8, void) — dispatch by packet type" {
    const alloc = std.testing.allocator;
    var reg = HandlerRegistry(u8, void).init(alloc);
    defer reg.deinit();

    const HandlerA = struct {
        fn h(_: *void, _: u8, data: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
            return try std.fmt.allocPrint(a, "A:{s}", .{data});
        }
    };
    const HandlerB = struct {
        fn h(_: *void, _: u8, _: []const u8, _: std.mem.Allocator) anyerror!?[]u8 {
            return null; // handled but no response
        }
    };

    try reg.register(0x01, HandlerA.h);
    try reg.register(0x02, HandlerB.h);
    reg.setDefault(HandlerA.h);

    var ctx: void = {};

    // exact match
    const r1 = try reg.dispatch(&ctx, 0x01, "hello", alloc);
    defer alloc.free(r1.?);
    try std.testing.expectEqualStrings("A:hello", r1.?);

    // B matches 0x02 and returns null → dispatch returns null
    const r2 = try reg.dispatch(&ctx, 0x02, "world", alloc);
    try std.testing.expect(r2 == null);

    // no match -> default
    const r3 = try reg.dispatch(&ctx, 0xFF, "foo", alloc);
    defer alloc.free(r3.?);
    try std.testing.expectEqualStrings("A:foo", r3.?);
}

test "HandlerRegistry([]const u8, void) — dispatch by clazz" {
    const alloc = std.testing.allocator;
    var reg = HandlerRegistry([]const u8, void).init(alloc);
    defer reg.deinit();

    const RegisterH = struct {
        fn h(_: *void, _: []const u8, _: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "register_ok");
        }
    };
    const ForwardH = struct {
        fn h(_: *void, _: []const u8, _: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "forward_ok");
        }
    };

    try reg.register("Register", RegisterH.h);
    try reg.register("Forward", ForwardH.h);

    var ctx: void = {};

    const r1 = try reg.dispatch(&ctx, "Register", "{}", alloc);
    defer alloc.free(r1.?);
    try std.testing.expectEqualStrings("register_ok", r1.?);

    const r2 = try reg.dispatch(&ctx, "Forward", "{}", alloc);
    defer alloc.free(r2.?);
    try std.testing.expectEqualStrings("forward_ok", r2.?);

    // Unknown -> null (no default set)
    const r3 = try reg.dispatch(&ctx, "Unknown", "{}", alloc);
    try std.testing.expect(r3 == null);
}

test "HandlerRegistry — no default, no match returns null" {
    const alloc = std.testing.allocator;
    var reg = HandlerRegistry(u8, void).init(alloc);
    defer reg.deinit();

    var ctx: void = {};
    const r = try reg.dispatch(&ctx, 0x01, "data", alloc);
    try std.testing.expect(r == null);
}
