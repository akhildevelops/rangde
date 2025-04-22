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
    // FIXME: This is inefficient everytime allocating the memory. Instead create a global buffer and pull in free subset buffer from there.
    const _buffer = try self.allocator.alloc(u8, self.config.read_buffer);
    defer self.allocator.free(_buffer);
    const buffer: xev.ReadBuffer = .{ .slice = _buffer };
    const bytes_read = try connection.read(buffer);
    var request = try Request.parse(_buffer[0..bytes_read], self.allocator);
    defer request.deinit();
    std.log.info("Received request is {}", .{request});
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

    // const read_buffer = try self.allocator.alloc(u8, self.config.max_socket_queue * self.config.read_buffer);

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

const RequestType = enum { get, post };
const Headers = struct {
    inner: std.StringHashMap([]const u8),
    owned: bool,
    allocator: std.mem.Allocator,
    fn deinit(self: *@This()) void {
        if (!self.owned) {
            return {};
        }
        var headers_iter = self.inner.iterator();
        while (headers_iter.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
    }
    fn format(self: @This(), _: []const u8, _: std.fmt.FormatOptions, writer: anytype) void {
        writer.print("Headers(", .{});
        var kv_iter = self.inner.iterator();
        while (kv_iter.next()) |kv| {
            writer.print("{s}={s},", .{ kv.key_ptr.*, kv.value_ptr.* });
        }
        writer.print(")", .{});
    }
};

inline fn log_buffer(buffer: []const u8) void {
    std.log.debug("The received buffer is {s}", .{buffer});
}

inline fn parse_request_type(request_type: []const u8) !RequestType {
    if (std.mem.eql(u8, request_type, "GET")) {
        return RequestType.get;
    }
    if (std.mem.eql(u8, request_type, "POST")) {
        return RequestType.post;
    }
    std.log.err("Received request type is not one of GET/POST. Received {s}", .{request_type});
    return error.Request;
}

const Request = struct {
    owned: bool,
    route: []const u8,
    request_type: RequestType,
    headers: Headers,
    allocator: std.mem.Allocator,

    fn format(self: @This(), _: []const u8, _: std.fmt.FormatOptions, writer: anytype) void {
        writer.print("Request(owned={s}, route={s}, request_type={s}, headers={})", .{ self.owned, self.route, @tagName(self.request_type), self.headers });
    }

    fn deinit(self: *@This()) void {
        if (!self.owned) {
            return {};
        }
        self.allocator.free(self.route);
        self.headers.deinit();
    }
    // FIXME: treating buffer contains all the required header details request
    fn parse(buffer: []const u8, allocator: std.mem.Allocator) !Request {
        var splits = std.mem.splitSequence(u8, buffer, "\r\n");
        const first_line = splits.next() orelse {
            std.log.err("Cannot find the first line in the received Request\n", .{});
            log_buffer(buffer);
            return error.Request;
        };
        var first_line_iterator = std.mem.splitScalar(u8, first_line, ' ');
        const request_type_str = first_line_iterator.next() orelse {
            std.log.err("Cannot find the Request type in the received Request\n", .{});
            log_buffer(buffer);
            return error.Request;
        };
        const request_type = try parse_request_type(request_type_str);
        const route = first_line_iterator.next() orelse {
            std.log.err("Cannot find the route\n", .{});
            log_buffer(buffer);
            return error.Request;
        };
        const owned_route = try allocator.dupe(u8, route);
        // Will be executed only if there's a failure in function.
        errdefer allocator.free(owned_route);
        var headers = Headers{ .allocator = allocator, .inner = std.StringHashMap([]const u8).init(allocator), .owned = true };
        errdefer headers.deinit();
        while (splits.next()) |each_line| {
            if (std.mem.eql(u8, each_line, "")) {
                break;
            }
            //FIXME: what if the header kv is of this sort "Sec-Fetch-Mode: navigate: to_north: and_south"
            var each_line_iter = std.mem.splitSequence(u8, each_line, ": ");
            const key = each_line_iter.next() orelse {
                std.log.err("Cannot find the  header key in {s}", .{each_line});
                return error.Request;
            };
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);

            const value = each_line_iter.next() orelse {
                std.log.err("Cannot find the header value in {s}", .{each_line});
                return error.Request;
            };
            const owned_value = try allocator.dupe(u8, value);
            errdefer allocator.free(owned_value);

            try headers.inner.put(owned_key, owned_value);
        }
        return .{ .owned = true, .route = owned_route, .headers = headers, .allocator = allocator, .request_type = request_type };
    }
};
