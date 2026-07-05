const std = @import("std");

/// Response for hardware connection closed.
///
/// When the hardware device disconnects, this response is broadcast to
/// all connected PC clients so they can react accordingly.
pub const HardwareClosedResponse = struct {
    pub const PACKET_TYPE: u8 = 0x01;

    pub fn parse(_: []const u8) !HardwareClosedResponse {
        return HardwareClosedResponse{};
    }

    /// Return the body as a JSON Value (consumed by ApiModel).
    pub fn toJsonValue(self: *const HardwareClosedResponse, allocator: std.mem.Allocator) !std.json.Value {
        _ = self;
        const map = try std.json.ObjectMap.init(
            allocator,
            &.{ "status", "clazz" },
            &.{
                std.json.Value{ .string = "HardwareClosed" },
                std.json.Value{ .string = "HardwareClosed" },
            },
        );
        return std.json.Value{ .object = map };
    }

    pub fn isHardwareClose(_: *const HardwareClosedResponse) bool {
        return true;
    }
};
