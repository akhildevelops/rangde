const rangde = @import("rangde");
const xev = rangde.xev;
const coro = rangde.coro;
const aio = coro.asyncio;
const http = rangde.http;
const std = @import("std");
const Config = rangde.config;
pub fn main() !void {
    const config = Config.default();
    std.log.info("{}", .{config});
    std.log.info("{s}", .{"Initializing the application"});
    std.log.info("{s}", .{"initializing the loop"});

    // Event loop that provides utility methods for network interaction in async way.
    var loop = try xev.Loop.init(.{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    std.log.info("{s}", .{"Initializing the executor"});

    // Co-routines executor that suspends and resumes.
    const executor = aio.Executor.init(&loop);
    var _http: http = .{ .executor = executor, .allocator = allocator, .config = config };
    std.log.info("{s}", .{"Running the server"});
    try _http.run("127.0.0.1", 8080);
}
