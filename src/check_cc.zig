const std = @import("std");

pub fn main() !void {
    @compileError("Enum type info fields: " ++ @typeName(@TypeOf(@typeInfo(std.os.windows.BOOL).@"enum")));
}
