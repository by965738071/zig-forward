# Zig Forward

![Zig](https://img.shields.io/badge/Zig-0.17.0--dev-F7A41D?logo=zig&labelColor=000)
![License](https://img.shields.io/badge/license-MIT-green)
![TCP](https://img.shields.io/badge/protocol-TCP-blue)
[![CI](https://github.com/by/zig-forward/actions/workflows/ci.yml/badge.svg)](https://github.com/by/zig-forward/actions/workflows/ci.yml)

一个基于 Zig 实现的高性能 TCP 转发/代理服务，提取自火箭测试平台硬件通信中间件。

## 背景

本项目源自某火箭测试平台中的硬件通信模块。在该平台中：

- **硬件设备**（传感器、采集器等）通过自定义二进制协议上报测试数据
- **PC 控制端**（上位机）需要实时接收这些数据并发送控制指令
- 硬件和 PC 之间通过一个中间转发服务解耦，支持一对多、多对多的拓扑关系

本项目的核心作用是将这个中间转发服务独立出来，作为一个通用的 TCP 消息代理。

## 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Zig Forward                          │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  Hardware 1   │    │  Hardware 2   │    │  Hardware N   │  │
│  │  (C-side)     │    │  (C-side)     │    │  (C-side)     │  │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘  │
│         │  TCP :9001        │  TCP :9001        │  TCP :9001 │
│         ▼                   ▼                   ▼           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                 GlobalState (groups)                 │   │
│  │  ┌─ Group(HW1) ─┐    ┌─ Group(HW2) ─┐              │   │
│  │  │  PC1  PC2    │    │  PC3  PC4    │              │   │
│  │  └──────────────┘    └──────────────┘              │   │
│  └─────────────────────────────────────────────────────┘   │
│         │                   │                               │
│         │  TCP :9000        │  TCP :9000                    │
│         ▼                   ▼                               │
│  ┌──────────────┐    ┌──────────────┐                      │
│  │   PC 1       │    │   PC 2       │    ...               │
│  │  (A-side)    │    │  (A-side)    │                      │
│  └──────────────┘    └──────────────┘                      │
└─────────────────────────────────────────────────────────────┘
```

### 角色定义

| 角色 | 连接端口 | 描述 |
|------|---------|------|
| **C-side** (硬件) | `:9001` | 硬件设备，发送二进制协议包，接收 PC 转发指令 |
| **A-side** (PC) | `:9000` | 控制端，接收硬件数据广播，发送控制命令 |

### 数据流

**上行（硬件 → PC）：**
```
硬件 → 二进制 packet → Decoder 解析 → JSON 构建 → broadcastToA → PC1, PC2, ...
```

**下行（PC → 硬件）：**
```
PC → JSON 命令 → parseCommand → sendToC → 硬件 socket
```

## 核心模块

| 模块 | 路径 | 职责 |
|------|------|------|
| `GlobalState` | `config/state.zig` | 全局状态管理，硬件-PC 分组，线程安全 |
| `PcServer` | `model/pc/pc_server.zig` | PC 连接管理，JSON 命令处理，指令转发 |
| `HwServer` | `model/hw/hw_server.zig` | 硬件连接管理，二进制协议解析，JSON 广播 |
| `custom_codec` | `config/custom_codec.zig` | 自定义二进制协议编码/解码 |
| `ByteParser` | `parser/byte_parser.zig` | 二进制协议流式解析 |
| `JsonLineParser` | `parser/json_parser.zig` | JSON 行协议解析 |
| `HandlerRegistry` | `config/handler_registry.zig` | 泛型命令路由注册/分发 |
| `util` | `config/util.zig` | hexEncode、currentTimestamp、readLine 工具 |

### 自定义二进制协议

```
┌────────┬────────┬──────────────┬──────────────────┬──────────┐
│ Header │  Type  │ Payload Len  │     Payload      │ Checksum │
│ (2 B)  │ (1 B)  │   (4 B LE)   │    (Variable)    │  (2 B)   │
└────────┴────────┴──────────────┴──────────────────┴──────────┘
```

- **Header**: `0x55 0xAA` (Magic Number)
- **Type**: 包类型（如 `0x1B` 表示数据帧）
- **Payload Len**: Little-endian u32
- **Checksum**: 所有前面字节的 wrapping 累加和（u16）

> **注意**：早期设计文档中的 `Board` 单字节字段在解析端并未实现，board 信息应并入 Payload。

### 线程安全设计

- `GlobalState.mutex` — 保护分组状态的读写
- `PcClientState.write_mutex` — 保护单个 socket 的并发写入
- `broadcastToA` 采用"快照 + 无锁写"模式：先持锁收集客户端列表，释放锁后逐个无锁写入，避免持锁阻塞全局状态

## 快速开始

```bash
# 启动服务
zig build run

# 另一个终端运行性能基准测试
zig build bench

# 运行单元测试
zig build test
```

## 基准测试

benchmark 模拟 2 个硬件 + 4 个 PC 的场景，测试三种场景（`releaseFast` 模式）：

| 场景 | 描述 | 典型性能 |
|------|------|---------|
| A: 单组广播 | 1 HW → 2 PC, N=1000 | ~10.9K broadcasts/s (~21.9K deliveries/s) |
| B: 两组并发 | 2×500 包同时广播 | ~25.2K deliveries/s |
| C: 流水线突发 | 2000 包持续负载 | ~10.5K broadcasts/s (~21.0K deliveries/s) |

### 详细数据（N=1000 广播）

```
═══ Test A: Broadcast throughput (N=1000) ═══
  10946.9 broadcasts/s  |  21893.8 deliveries/s

═══ Test B: Two-group broadcast (2×500) ═══
  25213.7 deliveries/s

═══ Test C: Pipeline burst (N=2000) ═══
  10503.0 broadcasts/s  |  21006.0 deliveries/s
```

## 开发

### 构建

```bash
zig build              # 编译（Debug）
zig build -Doptimize=ReleaseFast  # 编译（ReleaseFast，建议用于基准测试）
zig build run          # 运行（PC:9000, HW:9001）
zig build test         # 测试
zig build bench        # 基准测试（需先运行服务）
```

### 依赖

- Zig 0.17.0-dev (std.Io 异步框架)
- 无外部依赖

## 项目结构

```
src/
├── main.zig                    # 入口，DebugAllocator + 泄漏检测
├── config/                     # 核心配置与状态
│   ├── root.zig                # 模块导出
│   ├── config.zig              # 编译期配置常量（端口、命令路由表）
│   ├── state.zig               # GlobalState, Group, 分组管理
│   ├── custom_codec.zig        # 二进制协议编解码
│   ├── handler_registry.zig    # 泛型命令路由注册/分发
│   └── util.zig                # hexEncode, readLine 工具
├── model/                      # 业务模型
│   ├── root.zig                # 模块导出
│   ├── pc/                     # PC 控制端
│   │   ├── root.zig            # 模块导出
│   │   └── pc_server.zig       # PC 连接处理
│   └── hw/                     # 硬件端
│       ├── root.zig            # 模块导出
│       └── hw_server.zig       # 硬件连接处理
├── parser/                     # 协议解析器
│   ├── root.zig                # 模块导出
│   ├── byte_parser.zig         # 二进制协议流式解析
│   └── json_parser.zig         # JSON 行协议解析
└── test/                       # 测试与基准
    ├── benchmark_main.zig      # 性能基准测试
    ├── integration_test.zig    # 集成测试（单测）
    └── integration_test_main.zig  # 集成测试（可执行，需先运行服务）
```
