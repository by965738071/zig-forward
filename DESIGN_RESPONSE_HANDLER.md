# ResponseHandler 接口设计

## 目标

硬件的二进制协议解析现在固定在 `common_response.zig` + `buildFallbackJson` 两条路径，用户无法扩展。目标是提供一个「接口 + 责任链」机制，让用户自定义协议解析。

## 接口定义

```zig
// ── config/response_handler.zig ──

const std = @import("std");

/// 用户实现的协议解析器。
/// 与 std.Io.Reader/Writer 相同的 vtable 风格。
pub const ResponseHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 尝试解析一个二进制包。
        /// 返回 `null` 表示不处理此包（传给下一个 handler）。
        /// 返回 `[]u8` 表示解析成功（所有权移给调用者）。
        /// 返回 `error` 表示解析失败（跳过此包，直接发 fallback hex）。
        handle: *const fn (ctx: *anyopaque, packet: []const u8, allocator: std.mem.Allocator) !?[]u8,

        /// 可选：handler 生命周期结束时的清理。
        deinit: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub fn handle(self: ResponseHandler, packet: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        return self.vtable.handle(self.ptr, packet, allocator);
    }

    pub fn deinit(self: ResponseHandler, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |d| d(self.ptr, allocator);
    }
};
```

## 用户实现示例

### 1. 最简单：直接覆盖某个 type

```zig
// ── 用户代码 ──
const SensorAHandler = struct {
    pub fn handle(_: *anyopaque, packet: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        if (packet.len < 3 or packet[2] != 0x1B) return null; // 不是我

        const value = std.mem.readInt(u32, packet[8..12], .little);
        return std.fmt.allocPrint(allocator,
            "{{\"code\":0,\"body\":{{\"sensor_a\":{d}}}}}\n", .{value}
        );
    }
};
```

### 2. 带状态：解析不同类型的传感器

```zig
// ── 用户代码 ──
const MultiSensorHandler = struct {
    sensor_name: []const u8,
    scale: f64,

    pub fn init(name: []const u8, scale: f64) MultiSensorHandler {
        return .{ .sensor_name = name, .scale = scale };
    }

    fn handle(ctx: *anyopaque, packet: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const self = @as(*MultiSensorHandler, @alignCast(@ptrCast(ctx)));

        if (packet.len < 8) return null;
        const value = std.mem.readInt(u32, packet[4..8], .little);
        const scaled = @as(f64, @floatFromInt(value)) * self.scale;

        return std.fmt.allocPrint(allocator,
            "\\{\"sensor\":\"{s}\",\"value\":{d:.2}\\}\n",
            .{ self.sensor_name, scaled }
        );
    }

    pub fn handler(self: *MultiSensorHandler) ResponseHandler {
        return .{
            .ptr = self,
            .vtable = &.{ .handle = handle },
        };
    }
};
```

### 3. 带清理：从外部库解析

```zig
const ProtobufHandler = struct {
    parser: *ProtobufParser,
    arena: std.heap.ArenaAllocator,

    fn handle(ctx: *anyopaque, packet: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const self = @as(*ProtobufHandler, @alignCast(@ptrCast(ctx)));
        const parsed = try self.parser.parse(packet);
        return try parsed.toJson(allocator);
    }

    fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self = @as(*ProtobufHandler, @alignCast(@ptrCast(ctx)));
        self.parser.deinit();
        allocator.destroy(self);
    }
};
```

## 框架集成

### hardware_server 改动

```zig
// ── model/hardware/hardware_server.zig ──

pub const HardwareServer = struct {
    allocator: std.mem.Allocator,
    state: *GlobalState,
    io: Io,
    host: []const u8,
    port: u16,
    // ✨ 可选：全局默认 handlers（适用于所有硬件连接）
    default_handlers: []const ResponseHandler = &.{},

    pub fn init(...) HardwareServer { ... }

    /// ✨ 注册默认 handler
    pub fn addHandler(self: *HardwareServer, handler: ResponseHandler) void {
        // 追加到 default_handlers（需要 ArrayList 或固定数组）
    }
};
```

### handleHardwareInner 处理链

```zig
// ── 处理链（替换原 parseResponseJson + buildFallbackJson）──

// 用户可以在创建连接时传入自定义 handlers
const handlers: []const ResponseHandler = hw_server.default_handlers;

// 循环中每拿到一个 packet:
const json = resolve: {
    // 1. 用户自定义 handler 链
    for (handlers) |h| {
        if (try h.handle(packet, allocator)) |json| break :resolve json;
    }

    // 2. 内置结构化解析
    if (parseResponseJson(allocator, io, packet)) |json| break :resolve json;

    // 3. 最后的 fallback：hex 直出
    break :resolve try buildFallbackJson(allocator, io, packet);
};
defer allocator.free(json);

try state.broadcastToA(io, hw_id, json);
```

## 用户使用示例

```zig
// ── main.zig ──

var server = HardwareServer.init(allocator, &state, io, "0.0.0.0", hw_port);

// 注册自定义 handler
var temp_sensor = MultiSensorHandler.init("temperature", 0.01);
server.addHandler(temp_sensor.handler());

var pressure_sensor = MultiSensorHandler.init("pressure", 0.001);
server.addHandler(pressure_sensor.handler());

server.start();
```

## 可选扩展

| 扩展点 | 说明 |
|--------|------|
| 按硬件粒度注册 | 不同硬件可以有不同的 handler 链（在 setCSender / addAClient 时传入） |
| 包过滤 | handler 可以返回 `error.DropPacket` 来静默丢弃（不广播也不 fallback） |
| 异步 handler | vtable 可加 `handleAsync` 用于耗时解析（暂不需要） |
| 优先级排序 | 多个 handler 之间可以按优先级排序，避免 for 循环遍历全部 |

## 当前代码兼容

- 不修改现有 parseResponseJson / buildFallbackJson
- 不修改 custom_codec 协议
- 不修改 state.zig 的广播逻辑
- `handle` 返回 `?[]u8`（null = 跳过）而不是 `error.NotMyPacket`，避免异常开销
