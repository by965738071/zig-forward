const std = @import("std");

/// Generic response that wraps the raw hardware packet.
/// Represents a parsed hardware response — always a generic hex response.
/// The 0x01 (HardwareClosed) special case has been removed in favor of
/// the dynamic HandlerRegistry (see config/handler_registry.zig).
///
/// This file is kept for backward compatibility; new code should register
/// custom handlers directly via `HardwareServer.packet_registry.register()`.
pub const GenericResponse = struct {
    packet_type: u8,
    board_id: u8,
    hex: []const u8,
    raw_bytes: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GenericResponse) void {
        self.allocator.free(self.hex);
        self.allocator.free(self.raw_bytes);
    }
};
