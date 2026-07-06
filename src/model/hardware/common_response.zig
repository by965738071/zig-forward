const std = @import("std");
const custom_codec = @import("../../config/custom_codec.zig");
const hexEncode = @import("../../config/util.zig").hexEncode;
const HardwareClosedResponse = @import("hardware_close_response.zig").HardwareClosedResponse;

/// Dynamic response type representing any hardware response.
pub const DynResponse = union(enum) {
    closed: HardwareClosedResponse,
    generic: GenericResponse,

    pub fn isHardwareClose(self: *const DynResponse) bool {
        return switch (self.*) {
            .closed => true,
            .generic => false,
        };
    }

    /// Free all allocated fields.
    pub fn deinit(self: *DynResponse, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .closed => {},
            .generic => |*g| g.deinit(allocator),
        }
    }
};

/// Generic response that wraps the raw hardware packet.
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

/// Parse a binary hardware packet and produce a dynamic response.
pub fn parseResponse(packet: []const u8, allocator: std.mem.Allocator) !DynResponse {
    if (packet.len < custom_codec.MIN_PACKET_LEN) return error.PacketTooShort;

    const hdr = std.mem.readInt(u16, packet[0..2], .big);
    if (hdr != custom_codec.HEADER) return error.InvalidHeader;

    const packet_type = packet[2];
    const board_id = packet[3];

    switch (packet_type) {
        0x01 => {
            const resp = try HardwareClosedResponse.parse(packet);
            return DynResponse{ .closed = resp };
        },
        else => {
            const hex = try hexEncode(allocator, packet);
            const raw = try allocator.dupe(u8, packet);
            return DynResponse{
                .generic = .{
                    .allocator = allocator,
                    .packet_type = packet_type,
                    .board_id = board_id,
                    .hex = hex,
                    .raw_bytes = raw,
                },
            };
        },
    }
}
