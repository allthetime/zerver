const std = @import("std");
const xev = @import("xev");
const net = std.net;
const Server = net.Server;

const ADDRESS = .{ 127, 0, 0, 1 };
const PORT = 8083;

//
// implement with xev like this
// https://github.com/Dg0230/libxev-http/blob/main/src/lib.zig
//

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const Client = struct {
    conn: xev.TCP,
    id: usize = undefined,
    read_buf: [4096]u8 = undefined,
    read_c: xev.Completion = undefined,
    close_c: xev.Completion = undefined,
    write_c: xev.Completion = undefined, // Added for future broadcasting

};

const Server = *xev.TCP;

pub fn main() !void {
    defer {
        const check = gpa.deinit();
        if (check == .leak) std.debug.print("Memory leak detected!\n", .{});
    }

    var loop: xev.Loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const address = net.Address.initIp4(ADDRESS, PORT);
    var server = try xev.TCP.init(address);
    try server.bind(address);
    try server.listen(1024);

    var accept_completion: xev.Completion = .{};
    server.accept(&loop, &accept_completion, xev.TCP, &server, acceptCallback);

    try loop.run(.until_done);
}

fn acceptCallback(
    userdata: ?TCPServer,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const server = userdata.?;

    const client_connection: xev.TCP = result catch |err| {
        std.debug.print("Failed to accept client connection: {}\n", .{err});
        server.accept(loop, completion, xev.TCP, server, acceptCallback);
        return .disarm;
    };

    std.debug.print("New connection accepted!\n", .{});

    // 2. Use the GPA allocator here
    const client = allocator.create(Client) catch |err| {
        std.debug.print("Allocation failed: {}\n", .{err});
        // If we can't allocate memory for the client object, we must close the socket immediately
        // Note: In a real app we might need a sync close or a dummy loop,
        // but for now we just panic or drop it.
        return .disarm;
    };
    client.* = .{ .conn = client_connection };

    client.conn.read(loop, &client.read_c, .{ .slice = &client.read_buf }, Client, client, readCallback);

    server.accept(loop, completion, xev.TCP, server, acceptCallback);
    return .disarm;
    // return .rearm;
}

fn readCallback(
    ud: ?*Client,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const client = ud.?;

    const num_bytes = r catch |err| {
        std.debug.print("Read error: {}\n", .{err});
        closeClient(loop, client);
        return .disarm;
    };

    // If 0 bytes are read, it means the client closed the connection (EOF)
    if (num_bytes == 0) {
        std.debug.print("Client disconnected (EOF)\n", .{});
        closeClient(loop, client);
        return .disarm;
    }

    // Print what we received
    const data = client.read_buf[0 .. num_bytes - 1];
    std.debug.print("Received {} bytes: {s}\n", .{ num_bytes, data });

    // Read again (loop)
    client.conn.read(loop, &client.read_c, .{ .slice = &client.read_buf }, Client, client, readCallback);
    return .disarm;
}

fn closeClient(loop: *xev.Loop, client: *Client) void {
    // We use a separate completion for closing, stored in the client struct
    client.conn.close(loop, &client.close_c, Client, client, closeCallback);
}

// Callback triggered when the connection is fully closed
fn closeCallback(
    ud: ?*Client,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    // Free the heap memory we allocated for this client
    const client = ud.?;
    std.heap.page_allocator.destroy(client);
    return .disarm;
}
