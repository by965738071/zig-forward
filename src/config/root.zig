pub const state = @import("state.zig");
pub const util = @import("util.zig");
pub const handler_registry = @import("handler_registry.zig");

pub const ConfigType = @import("config.zig");
pub const config = @import("config.zig");

/// 从 parser 模块 re-export `Id`，使 handlers/app 能通过 `@import("app_config").Id` 访问，
/// 避免下层模块直接依赖 parser（统一从 app_config 取）。
pub const Id = @import("parser").Id;
pub const Frame = @import("parser").Frame;
pub const Parser = @import("parser").Parser;
pub const Factory = @import("parser").Factory;
