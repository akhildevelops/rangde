const std = @import("std");
max_socket_queue: u16 = 4096,
stack_size: u16 = 1024 * 32,

const Self = @This();
pub fn default() Self {
    return .{};
}

fn format(self: Self, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) void {
    writer.print("{d}", .{self.max_socket_queue});
}
