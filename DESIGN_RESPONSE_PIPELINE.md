# ResponsePipeline 设计（V1 整合版）

## 三层架构

```
                                    ┌──────────────┐
                                    │  1. Comptime  │  ← 零开销，编译期固定的自定义 handler
                                    │    Handler    │
                                    └──────┬───────┘
                                           │ null（不处理）
                                           ▼
                                    ┌──────────────┐
                                    │  2. VTable    │  ← 运行时注册，插件式扩展
                                    │  Handlers[]   │
                                    └──────┬───────┘
                                           │ null（全部跳过）
                                           ▼
                                    ┌──────────────┐
                                    │  3. Built-in  │  ← 标签联合，零配置
                                    │     Mode      │
                                    │ auto/hex/...  │
                                    └──────┬───────┘
                                           │ JSON
                                           ▼
                                    broadcastToA
```

每层返回 `?[]u8`：
- `null` → 跳过，试下一层
- `[]u8` → 直接用它广播，后续层不执行

## 接口定义

```zig
// ── config/response_pipeline.zig ──

const std = @import("std");

/// 三层响应处理管线。
pub const ResponsePipeline = struct {
    /// 模式层（第3层）：最简单的配置式，无需用户代码。
    mode: Mode = .auto,

    /// VTable 层（第2层）：运行时注册的扩展。
    vtable_extensions: std.ArrayListUnmanaged(Extension) = .{},

    pub const Mode = union(enum) {
        /// 先尝试结构化解析，失败则 hex 直出（≡ 当前行为）
        auto: void,
        /// 只 hex 输出，不尝试结构化解析
        hex_only: void,
        /// 只结构化解析，失败就报错
        structured: void,
        /// 原样透传（packet 按 []u8 输出，不转 hex）
        passthrough: void,
    };

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
    };

    /// 处理一个二进制 packet。
    ///
    /// `comptime CustomHandler` — 编译期 handler 类型。
    ///   传入 `void` 表示不使用 comptime 层。
    ///   要求类型有 `handle(packet, allocator) !?[]u8` 方法。
    ///
    /// 链式顺序：comptime → VTable → built-in mode
    pub fn process(
        self: *ResponsePipeline,
        comptime CustomHandler: type,
        custom: CustomHandler,
        packet: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // ── 第1层：comptime handler（零开销）──
        if (comptime CustomHandler != void) {
            if (try custom.handle(packet, allocator)) |json| return json;
        }

        // ── 第2层：VTable 扩展（运行时）──
        for (self.vtable_extensions.items) |ext| {
            if (try ext.handle(packet, allocator)) |json| return json;
        }

        // ── 第3层：内置模式（零开销）──
        switch (self.mode) {
            .auto => {
                if (parseStructured(packet, allocator)) |json| return json;
                return buildHexFallback(packet, allocator);
            },
            .hex_only => return buildHexFallback(packet, allocator),
            .structured => return parseStructured(packet, allocator),
            .passthrough => return allocator.dupe(u8, packet),
        }
    }

    pub fn deinit(self: *ResponsePipeline, allocator: std.mem.Allocator) void {
        for (self.vtable_extensions.items) |ext| {
            if (ext.vtable.deinit) |d| d(ext.ptr, allocator);
        }
        self.vtable_extensions.deinit(allocator);
    }
};

fn parseStructured(packet: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    // 现有 parseResponseJson 逻辑
}

fn buildHexFallback(packet: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // 现有 buildFallbackJson 逻辑
}
```

## 用户使用方式

### 方式 1：内置模式（当前行为，零改动）

```zig
var pipeline = ResponsePipeline{ .mode = .auto };
const json = try pipeline.process(void, {}, packet, allocator);
```

### 方式 2：comptime handler（零开销自定义）

```zig
const MyHandler = struct {
    fn handle(_: *@This(), packet: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        if (packet[2] != 0x1B) return null;
        // 自定义解析...
        return try std.fmt.allocPrint(allocator, "...", .{...});
    }
};

var pipeline = ResponsePipeline{ .mode = .auto };
const json = try pipeline.process(MyHandler, MyHandler{}, packet, allocator);
```

### 方式 3：VTable 扩展（运行时注册）

```zig
var pipeline = ResponsePipeline{ .mode = .hex_only };
try pipeline.vtable_extensions.append(allocator, .{
    .name = "my_sensor",
    .ptr = &my_state,
    .vtable = &.{ .handle = MyExtension.handle },
});
const json = try pipeline.process(void, {}, packet, allocator);
```

### 方式 4：全都要

```zig
var pipeline = ResponsePipeline{ .mode = .auto };
try pipeline.vtable_extensions.append(allocator, plugin_a);
try pipeline.vtable_extensions.append(allocator, plugin_b);
const json = try pipeline.process(MyHandler, MyHandler{}, packet, allocator);
```

## 硬件集成

```zig
// hardware_server 持有 pipeline
pub const HardwareServer = struct {
    pipeline: ResponsePipeline,
    // ...
};

// 读取循环中：
const json = try hw_server.pipeline.process(MyHandler, MyHandler{}, packet, allocator);
defer allocator.free(json);
try state.broadcastToA(io, hw_id, json);
```

## 关键设计决策

| 决策 | 理由 |
|------|------|
| comptime handler 作为函数参数而非 struct 泛型 | 避免 `ResponsePipeline(HandlerType)` 产生不同具体类型，保持 API 一致 |
| `void` 表示"不使用 comptime 层" | 简单、零开销、编译期分支消除 |
| VTable 也是 `?[]u8` 语义 | 与 comptime handler 一致，调用方无认知负担 |
| 每个层返回 `null` 表示"跳过" | 比 error 开销低，语义清晰 |
| 内置模式放在最底层 | 保证用户总是能看到某种结果（不会穿透到底层不处理） |
