const std = @import("std");
const xev = @import("xev");
const net = std.net;
const Server = net.Server;
const RingBuffer = @import("./ring_buffer.zig").RingBuffer;

const ADDRESS = .{ 127, 0, 0, 1 };
const PORT = 8083;

var clients: std.ArrayList(*Client) = undefined;
var clients_mutex = std.Thread.Mutex{}; // To keep it thread-safe if needed

//
// implement with xev like this
// https://github.com/Dg0230/libxev-http/blob/main/src/lib.zig
//

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const Client = struct {
    conn: xev.TCP,
    id: usize = undefined,
    rb: RingBuffer(4096) = .{}, // Our custom RingBuffer

    read_c: xev.Completion = undefined,

    write_c: xev.Completion = undefined, // Added for future broadcasting
    write_buf: [4096]u8 = undefined, // Buffer to hold the outgoing message

    close_c: xev.Completion = undefined,
};

pub fn main() !void {
    defer {
        const check = gpa.deinit();
        if (check == .leak) std.debug.print("Memory leak detected!\n", .{});
    }

    clients = .empty;
    defer clients.deinit(allocator);

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
    userdata: ?*xev.TCP,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const server = userdata.?;
    const client_connection = result catch |err| {
        std.debug.print("Failed to accept: {}\n", .{err});
        return .rearm;
    };

    const client = allocator.create(Client) catch |err| {
        std.debug.print("Allocation failed: {}\n", .{err});
        // var close_comp: xev.Completion = .{};
        // client_connection.close(loop, &close_comp, anyopaque, null, closeCallback);
        return .rearm;
    };

    // Initialize the client and the RingBuffer
    client.* = .{
        .conn = client_connection,
        .rb = RingBuffer(4096){},
    };

    clients_mutex.lock();
    clients.append(allocator, client) catch |err| {
        std.debug.print("Failed to add client to list: {}\n", .{err});
    };
    clients_mutex.unlock();

    // START HERE: Get the slice from the RingBuffer for the INITIAL read
    const slices = client.rb.getWriteSlices();

    client.conn.read(loop, &client.read_c, .{ .slice = slices[0] }, // Use the RB memory from the start!
        Client, client, readCallback);

    server.accept(loop, completion, xev.TCP, server, acceptCallback);
    return .disarm;
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

    if (num_bytes == 0) {
        closeClient(loop, client);
        return .disarm;
    }

    // CRITICAL: Update the write pointer BEFORE processing
    client.rb.advanceWrite(num_bytes);

    // Debug: Let's see exactly what the indices are
    // std.debug.print("Indices: R:{} W:{} Len:{}\n", .{client.rb.read_idx, client.rb.write_idx, client.rb.len()});

    processBuffer(client, loop);

    // Re-arm the read
    const slices = client.rb.getWriteSlices();
    if (slices[0].len > 0) {
        client.conn.read(loop, &client.read_c, .{ .slice = slices[0] }, Client, client, readCallback);
    }

    return .disarm;
}

fn processBuffer(client: *Client, loop: *xev.Loop) void {
    // Loop in case we received multiple lines in a single TCP packet
    while (client.rb.findDelimiter('\n')) |delim_pos| {
        const msg_len = delim_pos + 1; // Length including the '\n'

        // Use a fixed-size buffer for the "extracted" message
        var line_buf = [_]u8{0} ** 4096;

        // Determine how much we can safely copy
        const copy_amt = @min(msg_len, line_buf.len);

        // Peek the data out into our flat buffer
        const actual_copied = client.rb.peek(line_buf[0..copy_amt]);

        // Print the cleaned-up line
        std.debug.print("Message Received: {s}", .{line_buf[0..actual_copied]});

        broadcast(client, line_buf[0..actual_copied], loop);

        // CRITICAL: Advance the read pointer to consume exactly one line
        client.rb.advanceRead(msg_len);

        // The loop continues if there's another '\n' waiting in the buffer
    }
}

fn broadcast(sender: *Client, message: []const u8, loop: *xev.Loop) void {
    clients_mutex.lock();
    defer clients_mutex.unlock();

    for (clients.items) |recipient| {
        // Option: Don't send the message back to the person who sent it
        if (recipient == sender) continue;

        // Copy message to recipient's write buffer
        const safe_len = @min(message.len, recipient.write_buf.len);
        @memcpy(recipient.write_buf[0..safe_len], message[0..safe_len]);

        // Trigger the async write
        recipient.conn.write(
            loop, // You'll need access to the loop
            &recipient.write_c,
            .{ .slice = recipient.write_buf[0..safe_len] },
            Client,
            recipient,
            writeCallback,
        );
    }
}

fn writeCallback(
    _: ?*Client,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.WriteBuffer,
    res: xev.WriteError!usize,
) xev.CallbackAction {
    _ = res catch |err| {
        std.debug.print("Broadcast write error: {}\n", .{err});
    };
    return .disarm;
}

fn closeClient(loop: *xev.Loop, client: *Client) void {
    client.conn.close(loop, &client.close_c, Client, client, closeCallback);
}

fn closeCallback(
    ud: ?*Client,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    if (ud) |client| {
        allocator.destroy(client); // Match the allocator used in acceptCallback
        clients_mutex.lock();
        for (clients.items, 0..) |c, i| {
            if (c == client) {
                _ = clients.swapRemove(i);
                break;
            }
        }
        clients_mutex.unlock();
    }
    return .disarm;
}
