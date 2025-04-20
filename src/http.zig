const std = @import("std");
const xev = @import("xev");
const libcoro = @import("coro");
const aio = @import("coro").asyncio;
const Config = @import("./lib.zig").config;
/// Run the http server binding to a host and port
executor: aio.Executor,
config: Config,
allocator: std.mem.Allocator,
const Self = @This();

fn _async_conn(self: *Self, connection: aio.TCP) !void {
    defer connection.close() catch unreachable;
    var _buffer: [32]u8 = undefined;
    const buffer: xev.ReadBuffer = .{ .slice = &_buffer };
    std.log.info("Sleeping for 20secs", .{});
    try aio.sleep(&self.executor, 20000);
    const bytes_read = try connection.read(buffer);
    std.log.info("bytes_read: {d} and the bytes are {s}\n", .{ bytes_read, _buffer });
}

fn _async_run(self: *Self, host: []const u8, port: u16) !void {

    // Binds the server to an ip address and port
    const address = try std.net.Address.parseIp(host, port);
    const server = try xev.TCP.init(address);
    try server.bind(address);
    const Frame = libcoro.FrameT(_async_conn, .{ .ArgsT = struct { *Self, aio.TCP } });
    var connections = std.HashMap(Frame, void, struct {
        pub fn hash(_: @This(), value: Frame) u64 {
            return @as(u64, @intFromPtr(value.frame()));
        }
        pub fn eql(_self: @This(), value1: Frame, value2: Frame) bool {
            return _self.hash(value1) == _self.hash(value2);
        }
    }, std.hash_map.default_max_load_percentage).init(self.allocator);
    defer connections.deinit();
    // Max Queue to buffer incoming connections. If more than these connections the requests get dropped.
    try server.listen(self.config.max_socket_queue);

    // Wrap server with aio to suspend and resume.
    const async_server = aio.TCP.init(&self.executor, server);
    defer async_server.close() catch unreachable;

    // Loop  for serving all client requests upto max queue
    while (connections.count() < self.config.max_socket_queue) {
        std.debug.print("Np: connections: {d}\n", .{connections.count()});
        var connection_iter = connections.keyIterator();
        while (connection_iter.next()) |connection| {
            switch (connection.status()) {
                .Done => {
                    std.debug.print("Coroutine: {*}\n", .{connection.frame()});
                    self.allocator.free(connection.frame().stack);
                    _ = connections.removeByPtr(connection);
                },
                else => {},
            }
        }
        const connection = try async_server.accept();
        // SHouldn't await otherwise it blocks until _async_conn is finished. But there will be a limit on no: of acceptable connections.
        const stack = try libcoro.stackAlloc(self.allocator, self.config.stack_size);
        const connection_frame = try aio.xasync(_async_conn, .{ self, connection }, stack);
        try connections.put(connection_frame, {});
    }
}

pub fn run(self: *Self, host: []const u8, port: u16) !void {
    // Allocates heap to store the state of _async_run when suspended.
    const stack = try libcoro.stackAlloc(self.allocator, self.config.stack_size);

    // Eventloop will exit only when _async_run successfully finishes otherwise keeps on looping.
    try aio.run(&self.executor, _async_run, .{ self, host, port }, stack);
}
