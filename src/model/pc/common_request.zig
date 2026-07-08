const std = @import("std");

/// Result of parsing a PC client command.
pub const ParsedCommand = union(enum) {
    register: RegisterInfo,
    forward: ForwardInfo,
    request_control: TargetInfo,
    release_control: TargetInfo,
    heartbeat: TargetInfo,
};

pub const RegisterInfo = struct {
    target_addr: []const u8,
};

pub const ForwardInfo = struct {
    target_addr: []const u8,
};

pub const TargetInfo = struct {
    target_addr: []const u8,
};

/// Minimal parse result — just the clazz and target_addr.
/// The caller owns `target_addr`.
pub const ClazzAndTarget = struct {
    clazz: []const u8, // borrowed from input JSON
    target_addr: []const u8, // owned, must be freed
};

/// Quick-parse a JSON command to extract `clazz` and `target_addr`.
/// Caller owns the returned `target_addr`.
pub fn parseClazzAndTarget(json_str: []const u8, allocator: std.mem.Allocator) !ClazzAndTarget {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const obj = &root.object;
    const clazz_val = obj.get("clazz") orelse return error.MissingField;
    if (clazz_val != .string) return error.InvalidJson;

    const target_val = obj.get("target_addr") orelse return error.MissingField;
    if (target_val != .string) return error.InvalidJson;
    if (target_val.string.len == 0) return error.InvalidTargetAddr;

    return .{
        .clazz = clazz_val.string,
        .target_addr = try allocator.dupe(u8, target_val.string),
    };
}

/// Full parse into a tagged union.
///
/// Deprecated: prefer `parseClazzAndTarget` + HandlerRegistry dispatch.
/// Kept for backward compatibility.
pub fn parseCommand(json_str: []const u8, allocator: std.mem.Allocator) !ParsedCommand {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const obj = &root.object;
    const clazz_val = obj.get("clazz") orelse return error.MissingField;
    if (clazz_val != .string) return error.InvalidJson;
    const clazz = clazz_val.string;

    const target_val = obj.get("target_addr") orelse return error.MissingField;
    if (target_val != .string) return error.InvalidJson;
    if (target_val.string.len == 0) return error.InvalidTargetAddr;
    const target_addr = try allocator.dupe(u8, target_val.string);

    if (std.mem.eql(u8, clazz, "Register")) {
        return ParsedCommand{ .register = .{ .target_addr = target_addr } };
    }
    if (std.mem.eql(u8, clazz, "RequestControl")) {
        return ParsedCommand{ .request_control = .{ .target_addr = target_addr } };
    }
    if (std.mem.eql(u8, clazz, "ReleaseControl")) {
        return ParsedCommand{ .release_control = .{ .target_addr = target_addr } };
    }
    if (std.mem.eql(u8, clazz, "Heartbeat")) {
        return ParsedCommand{ .heartbeat = .{ .target_addr = target_addr } };
    }

    return ParsedCommand{ .forward = .{ .target_addr = target_addr } };
}

test "parse Register" {
    const alloc = std.testing.allocator;
    const json = "{\"clazz\":\"Register\",\"target_addr\":\"10.0.0.1:9000\"}";
    const cmd = try parseCommand(json, alloc);
    defer alloc.free(cmd.register.target_addr);

    try std.testing.expect(cmd == .register);
    try std.testing.expectEqualStrings("10.0.0.1:9000", cmd.register.target_addr);
}

test "parse forward command" {
    const alloc = std.testing.allocator;
    const json = "{\"clazz\":\"BoxStatus\",\"target_addr\":\"10.0.0.1:9000\"}";
    const cmd = try parseCommand(json, alloc);
    defer alloc.free(cmd.forward.target_addr);

    try std.testing.expect(cmd == .forward);
    try std.testing.expectEqualStrings("10.0.0.1:9000", cmd.forward.target_addr);
}
