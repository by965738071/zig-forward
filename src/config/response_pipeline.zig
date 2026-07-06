const std = @import("std");

/// 三层响应处理管线。
///
/// 硬件二进制 packet 按以下顺序处理，直到某一层返回 JSON：
///   1. comptime handler（编译期，零开销）
///   2. VTable handler（运行时注册，插件式）
///   3. Built-in Mode（内置模式，零配置）
///
/// 每层返回 `null` = "跳过我"，穿过到下一层。
///
/// # 使用示例
///
/// ```zig
/// var pipeline = ResponsePipeline.init(.auto);
///
/// // 可选：注入内置模式的回调（由 hardware_server 在初始化时设置）
/// pipeline.builtin_ops = .{
///     .parseStructured = myParseStructured,
///     .buildHex = myBuildHex,
/// };
///
/// // 处理一个 packet
/// const json = try pipeline.process(void, {}, packet, allocator);
/// defer allocator.free(json);
/// ```
pub const ResponsePipeline = struct {
    /// 内置模式（第3层）
    mode: Mode = .auto,

    /// VTable 扩展列表（第2层）
    vtable_extensions: std.ArrayListUnmanaged(Extension) = .{},

    /// 内置模式使用的回调函数——由创建者注入。
    /// 不直接依赖 hardware 模块，保持 pipeline 通用。
    builtin_ops: BuiltinOps = .{},

    pub const Mode = union(enum) {
        /// 先尝试 structured，失败则 hex fallback（≡ 当前默认行为）
        auto: void,
        /// 只 hex 输出
        hex_only: void,
        /// 只结构化解析，没有就报错
        structured: void,
        /// 原样透传（packet 直接当 body）
        passthrough: void,
    };

    /// 内置模式回调集合
    pub const BuiltinOps = struct {
        /// mode = auto / structured 时调用，返回 null 表示"不处理"
        parseStructured: ?*const fn (packet: []const u8, allocator: std.mem.Allocator) !?[]u8 = null,
        /// mode = auto / hex_only 时调用
        buildHex: ?*const fn (packet: []const u8, allocator: std.mem.Allocator) ![]u8 = null,
    };

    /// 运行时注册的扩展（VTable 风格）
    pub const Extension = struct {
        name: []const u8,
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            handle: *const fn (ctx: *anyopaque, packet: []const u8, allocator: std.mem.Allocator) !?[]u8,
            deinit: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,
        };

        pub fn handle(self: Extension, packet: []const u8, allocator: std.mem.Allocator) !?[]u8 {
            return self.vtable.handle(self.ptr, packet, allocator);
        }

        pub fn deinit(self: Extension, allocator: std.mem.Allocator) void {
            if (self.vtable.deinit) |d| d(self.ptr, allocator);
        }
    };

    pub fn init(mode: Mode) ResponsePipeline {
        return .{ .mode = mode };
    }

    /// 处理一个二进制 packet。
    ///
    /// `comptime CustomHandler` — 编译期 handler 类型。
    ///   传 `void` 表示不使用 comptime 层。
    ///   要求该类型有 `handle(packet, allocator) !?[]u8` 方法。
    ///
    /// 链式顺序：comptime → VTable → built-in mode
    pub fn process(
        self: *ResponsePipeline,
        comptime CustomHandler: type,
        custom: CustomHandler,
        packet: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // ── 第1层：comptime handler ──
        if (comptime CustomHandler != void) {
            if (try custom.handle(packet, allocator)) |json| return json;
        }

        // ── 第2层：VTable extension ──
        for (self.vtable_extensions.items) |ext| {
            if (try ext.handle(packet, allocator)) |json| return json;
        }

        // ── 第3层：built-in mode ──
        return switch (self.mode) {
            .auto => blk: {
                if (self.builtin_ops.parseStructured) |fn_| {
                    if (try fn_(packet, allocator)) |json| break :blk json;
                }
                if (self.builtin_ops.buildHex) |fn_| {
                    break :blk try fn_(packet, allocator);
                }
                return error.NoBuiltinOps;
            },
            .structured => blk: {
                if (self.builtin_ops.parseStructured) |fn_| {
                    if (try fn_(packet, allocator)) |json| break :blk json;
                }
                return error.ParseFailed;
            },
            .hex_only => blk: {
                if (self.builtin_ops.buildHex) |fn_| {
                    break :blk try fn_(packet, allocator);
                }
                return error.NoBuiltinOps;
            },
            .passthrough => try allocator.dupe(u8, packet),
        };
    }

    /// 清理所有 VTable extension
    pub fn deinit(self: *ResponsePipeline, allocator: std.mem.Allocator) void {
        for (self.vtable_extensions.items) |*ext| {
            ext.deinit(allocator);
        }
        self.vtable_extensions.deinit(allocator);
    }
};

// ══════════════════════════════════════════
// 测试
// ══════════════════════════════════════════

test "auto mode calls structured then hex" {
    const alloc = std.testing.allocator;
    var pipeline = ResponsePipeline.init(.auto);

    // 模拟结构化：返回 null（不处理）
    pipeline.builtin_ops.parseStructured = struct {
        fn f(_: []const u8, _: std.mem.Allocator) !?[]u8 {
            return null;
        }
    }.f;

    // 模拟 hex fallback
    pipeline.builtin_ops.buildHex = struct {
        fn f(_: []const u8, a: std.mem.Allocator) ![]u8 {
            return try a.dupe(u8, "hex_fallback");
        }
    }.f;

    const json = try pipeline.process(void, {}, &.{0xEB}, alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings("hex_fallback", json);
}

test "structured returns first" {
    const alloc = std.testing.allocator;
    var pipeline = ResponsePipeline.init(.auto);

    pipeline.builtin_ops.parseStructured = struct {
        fn f(_: []const u8, a: std.mem.Allocator) !?[]u8 {
            return try a.dupe(u8, "structured_ok");
        }
    }.f;
    pipeline.builtin_ops.buildHex = struct {
        fn f(_: []const u8, _: std.mem.Allocator) ![]u8 {
            unreachable;
        }
    }.f;

    const json = try pipeline.process(void, {}, &.{0xEB}, alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings("structured_ok", json);
}

test "comptime handler runs before builtin" {
    const alloc = std.testing.allocator;
    var pipeline = ResponsePipeline.init(.hex_only);

    // comptime handler 截获
    const MyHandler = struct {
        fn handle(_: *@This(), _: []const u8, a: std.mem.Allocator) !?[]u8 {
            return try a.dupe(u8, "comptime_ok");
        }
    };

    // hex_only 如果执行到这里会 unreachable
    pipeline.builtin_ops.buildHex = struct {
        fn f(_: []const u8, _: std.mem.Allocator) ![]u8 {
            unreachable;
        }
    }.f;

    const json = try pipeline.process(MyHandler, MyHandler{}, &.{0xEB}, alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings("comptime_ok", json);
}

test "VTable extension runs between comptime and builtin" {
    const alloc = std.testing.allocator;
    var pipeline = ResponsePipeline.init(.auto);

    // VTable 扩展
    const Ext = struct {
        fn handle(_: *anyopaque, _: []const u8, a: std.mem.Allocator) !?[]u8 {
            return try a.dupe(u8, "vtable_ok");
        }
    };
    var dummy: usize = 0;
    try pipeline.vtable_extensions.append(alloc, .{
        .name = "test_ext",
        .ptr = &dummy,
        .vtable = &.{ .handle = Ext.handle },
    });

    // builtin 不应该执行
    pipeline.builtin_ops.buildHex = struct {
        fn f(_: []const u8, _: std.mem.Allocator) ![]u8 {
            unreachable;
        }
    }.f;

    const json = try pipeline.process(void, {}, &.{0xEB}, alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings("vtable_ok", json);
}

test "VTable returns null falls through to builtin" {
    const alloc = std.testing.allocator;
    var pipeline = ResponsePipeline.init(.hex_only);

    const Ext = struct {
        fn handle(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !?[]u8 {
            return null; // 跳过
        }
    };
    var dummy: usize = 0;
    try pipeline.vtable_extensions.append(alloc, .{
        .name = "skip_ext",
        .ptr = &dummy,
        .vtable = &.{ .handle = Ext.handle },
    });

    pipeline.builtin_ops.buildHex = struct {
        fn f(_: []const u8, a: std.mem.Allocator) ![]u8 {
            return try a.dupe(u8, "hex_ok");
        }
    }.f;

    const json = try pipeline.process(void, {}, &.{0xEB}, alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings("hex_ok", json);
}

test "passthrough mode returns raw packet" {
    const alloc = std.testing.allocator;
    var pipeline = ResponsePipeline.init(.passthrough);

    const input = &.{ 0xEB, 0x90, 0x01 };
    const json = try pipeline.process(void, {}, input, alloc);
    defer alloc.free(json);
    try std.testing.expectEqualSlices(u8, input, json);
}
