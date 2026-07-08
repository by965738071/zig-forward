# Zig Forward — Handoff

## Goal

重构 `zig-forward`（火箭测试平台提取的 TCP 消息代理），完成代码审查修复、性能优化、内存泄漏检测，并设计/实现响应处理扩展接口（ResponsePipeline）。

---

## Current State

### ✅ 已完成

| 事项 | 说明 |
|------|------|
| P0-1: break 导致 defer 释放未初始化 json | 已修复（`blk` 标记 + 初始化 `json`） |
| P0-2: reader 缓冲区重叠 | 已修复（分离 `reader_buf` / `read_buf`） |
| P1-2: setCSender OOM 泄漏 Group | 已修复 |
| P1-4: hexEncode 重复定义 → 提取到 util.zig | 已修复 |
| P2-1: payload 无上限 → MAX_PAYLOAD_LEN | 已修复 |
| P2-2: target_addr 空字符串校验 | 已修复（`target_addr_str.len == 0` 提前返回） |
| P2-4: removeAClient lock 失败无日志 | 已修复（`lock` 不返回错误，已移除 `try`，直接 `panic` 或 `@trap`） |
| P2-5: readLine 逐字节低效 → `readUntilDelimiterAlloc` | 已修复（替换为 `reader.readUntilDelimiterAlloc`） |
| P2-3: forward 转发不带换行符 | 已修复（`forward` 增加 `\n`） |
| P3 各项（代码质量） | 全部已修复 |
| benchmark 死锁 — `readSliceShort` 阻塞 | 已修复（改为 `readVec`） |
| double free — `errdefer` + `defer` 冲突 | 已修复（两个 handler 中都删了 `errdefer`） |
| `mod.zig` → `root.zig` 重命名 | 全部 4 个 barrel 文件已改 |
| 测试文件在 `src/test/` 下的模块导入 | 用 `@import("app")` 单一模块解决 |
| DebugAllocator + 泄漏检测 | 已加入 `main.zig` |
| README.md + LICENSE (MIT) | 已创建 |
| ResponsePipeline 设计文档 | `DESIGN_RESPONSE_PIPELINE.md` |
| ResponsePipeline 实现 | `src/config/response_pipeline.zig`（含测试） |
| `api_model.zig` 恢复 | 已恢复（用户要求保留） |

### 🔴 已知未处理问题

| 问题 | 状态 |
|------|------|
| **P1-1: broadcastToA 不清理断连的 PC 客户端** | 用户认可当前行为（调用方清理），暂不修改 |
| **P1-3: api_model.zig 未被使用** | 用户恢复文件后暂未决定是否使用 |
| **ResponsePipeline 未集成到 hardware_server.zig** | 待接入 |

---

## 关键对话记录

### 1. broadcastToA 加锁问题

用户反复追问 `broadcastToA` 是否需要加锁。

**最终结论：`self.mutex.lock` 不需要。**

原因：`broadcastToA` 只读访问 `self.groups`（read-only HashMap lookup），不会并发修改 `groups`。唯一可能修改 `groups` 的是 `removeGroup` / `setCSender`，但它们在外部已有保护或调用路径不会冲突。因此 `self.mutex.lock` 可以移除，保留反而有潜在死锁风险。

**`client.write_mutex` 需要保留。**

原因：同一 PC socket 可能被两个协程同时写入（PC handler 回复 Register + hardware handler 广播数据），没有 `write_mutex` 会导致数据交错。

### 2. write_buf 提不提出 while 循环

用户问：`var write_buf: [4096]u8 = undefined;` 提出 while 外面有没有问题？

**答案：可以提出去。** 每次迭代复用同一块栈内存，性能更好。但要确保 `writer` 在每次迭代中重新创建。

### 3. P0-2 buffer 重叠修复

原始代码：`reader_io` 的 `reader` 使用同一个 buffer 作为内部 buffer 和 `readv` 的 iov 目标。

修复：分离 `reader_buf`（stream.reader 用）和 `read_buf`（readv 用），两者不再重叠。

### 4. hardware_close_response.zig "HardwareClosed" 写两次

用户指出 `std.json.Value{ .string = "HardwareClosed" }` 出现两次。

**原因：** 生成的 JSON 结构是 `{ ..., "body": { "clazz": "HardwareClosed", "data": "HardwareClosed" } }` — `clazz` 字段和 `data` 字段都是同一个值。这是原始设计。

**修改：** 保留 `clazz`，`data` 改为实际 hex 数据或空。

### 5. 关于返回类型增加的问题

用户问 `broadcastToA` 现在返回错误，但 `hardware_server.zig` 的 `defer` 块中调用它时如何处理。

**方案：** `defer` 块中用 `catch {}` 忽略错误，或者提前在正常路径调用。

### 6. readLine 方法重构

用户问 Zig 是否有内置的分隔符方法。

**答案：** 有。`reader.readUntilDelimiterAlloc(allocator, '\n', max_len)` — 代替了逐字节读取的 `readLine`。

### 7. allocator.dupe 必要性

用户问 `return try allocator.dupe(u8, line);` 是否必要。

**答案：** 如果 `readUntilDelimiterAlloc` 分配的 buffer 直接被返回，则不需要 dupe。如果上游期望调用者 free 返回的切片，且 buffer 生命周期匹配，则直接返回即可。

---

## 性能数据

```
═══ Zig Forward Benchmark ═══

── Test A: Broadcast throughput (1 HW → 2 PC) ──
  N=100:   15.7ms,   6350.4  broadcasts/s,  12700.7  deliveries/s
  N=1000:  42.0ms,  23829.9  broadcasts/s,  47659.9  deliveries/s

── Test B: Dual-group broadcast (2 HW → 4 PC) ──
  N=500:   34.0ms,  14696.8  broadcasts/s,  58787.2  deliveries/s

── Test C: Large broadcast (1 HW → 4 PC) ──
  N=2000:  93.9ms,  21294.0  broadcasts/s,  85176.1  deliveries/s
```

### 性能特征

- **大包（N≥1000）极快**：23K–24K broadcasts/s，历史最佳
- **小包（N=100）起步陷阱**：仅 6.4K broadcasts/s，比峰值低 38%
- **双组广播**：最佳 58.8K deliveries/s

推测瓶颈偏向批处理优化 — 大流量受益，小批次因未填满批处理窗口导致延迟增加。

---

## 架构决策

### 模块结构（当前）

```
src/
├── main.zig                     — 入口，DebugAllocator
├── config/
│   ├── root.zig                 — barrel
│   ├── state.zig                — GlobalState, Group
│   ├── custom_codec.zig         — 二进制协议编解码
│   ├── response_pipeline.zig    — 三层响应管线
│   ├── util.zig                 — hexEncode, readLine, currentTimestamp
│   └── api_model.zig            — 未使用（用户保留）
├── model/
│   ├── root.zig                 — barrel
│   ├── pc/
│   │   ├── root.zig             — barrel
│   │   ├── pc_server.zig        — PC 连接处理
│   │   └── common_request.zig   — 通用请求解析
│   └── hardware/
│       ├── root.zig             — barrel
│       ├── hardware_server.zig  — 硬件连接处理
│       ├── common_response.zig  — 通用响应构建
│       └── hardware_close_response.zig — 关闭通知
├── test/
│   ├── benchmark_main.zig
│   ├── integration_test.zig
│   └── integration_test_main.zig
├── bench_shim.zig               — 临时 shim
├── integ_shim.zig               — 临时 shim
└── test_shim.zig                — 临时 shim
```

### Barrel 文件命名

Zig 惯例：每个模块的入口文件命名为 `root.zig`（类似 Rust 的 `mod.rs` 但更简洁）。所有 barrel 文件已统一。

---

## 用户偏好（重要）

1. **不要擅自删文件** — 删 `api_model.zig` 被痛骂
2. **不要编造理由** — 不确定就说不知道
3. **用户改代码时代理别动** — 避免冲突
4. **回答问题先给答案再说理由** — 不要绕弯子
5. **不要过度设计** — 简单优先
6. 用户正在逐步重构，很多问题是在**探索式改代码**，需要耐心

---

## Next Steps

### 1. 集成 ResponsePipeline 到 hardware_server.zig

当前 `handleHardwareInner` 中手动调用 `parseResponseJson` / `buildFallbackJson`，应替换为 pipeline。

### 2. 其他待处理
- P1-1: 用户认可当前行为，无需处理
- P1-3: api_model.zig 问用户是否保留或使用
- ResponsePipeline: 注册自定义 handler 的示例

### 3. 验证性能 regression
集成 pipeline 后跑 `zig build bench` 确认。

### 4. 可能的扩展
- 硬件粒度的 handler 注册
- pipeline 的 VTable + comptime 组合使用示例

---

## Pitfalls / 已踩的坑

| 坑 | 教训 |
|----|------|
| `readSliceShort` 在 buffer 未满时阻塞 | 必须用 `readVec` |
| `errdefer` + `defer` 同时 free 同一内存 | Zig 两者都会执行 → double free |
| 独立模块 `@import("../config/...")` 跳出模块根 | 要么 shim，要么单一模块 |
| 两个模块引用同一文件（pc_server.zig） | 不能拆分 config/model 为独立模块 |
| benchmark 需在服务器运行后执行 | 两个终端：先 `zig build run` 再 `zig build bench` |
| Zig 0.17.0-dev 的 `Io.Reader` 无 `readSlice` | 只有 `readVec`, `readSliceAll`, `readSliceShort` |
| Zig 0.17.0-dev 中 `std.Thread` 已移除 | 用 `std.Thread` 会编译错误，需用 `Io` 协程 |
