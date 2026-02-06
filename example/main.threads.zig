const std = @import("std");
const net = std.net;
const Server = net.Server;

const ADDRESS = .{ 127, 0, 0, 1 };
const PORT = 8081;

//
// implement with xev like this
// https://github.com/Dg0230/libxev-http/blob/main/src/lib.zig
//

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const address = net.Address.initIp4(ADDRESS, PORT);
    const listener = try address.listen(.{
        .force_nonblocking = false,
        .reuse_address = true,
    });
    var server: Server = .{
        .listen_address = address,
        .stream = listener.stream,
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var id: usize = 0;
    while (true) : (id +%= 1) {
        const connection = server.accept() catch |err| {
            std.debug.print("Failed to accept client connection: {}\n", .{err});
            continue;
        };
        std.debug.print("Client connected: {f}\n", .{connection.address.in});
        try pool.spawn(handleClient, .{ connection, id });
    }
}

fn handleClient(conn: net.Server.Connection, id: usize) void {
    _handleClient(conn, id) catch |err| {
        std.debug.print("Error in client handler: {}\n", .{err});
    };
    std.debug.print("Client disconnected: {d}\n", .{id});
}

fn _handleClient(conn: net.Server.Connection, id: usize) !void {
    defer conn.stream.close();
    var out_buf: [1024]u8 = undefined;
    var writer = conn.stream.writer(&out_buf);
    try writer.file_writer.interface.print("Hello {d}\n", .{id});

    var in_buf: [1024]u8 = undefined;
    var reader = conn.stream.reader(&in_buf);

    // while (true) {
    //     const message = try reader.file_reader.interface.takeDelimiter('\n') orelse break;
    //     std.debug.print("Received from {d}: {s}\n", .{ id, message });
    //     try writer.file_writer.interface.print("{s}\n", .{message});
    // }

    while (try reader.file_reader.interface.takeDelimiter('\n')) |b| {
        std.debug.print("{d}: {s} : {x}\n", .{ id, b, b });
    }
}
