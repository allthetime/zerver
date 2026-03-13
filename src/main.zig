const std = @import("std");
const xev = @import("xev");
const net = std.net;
const Server = net.Server;
const RingBuffer = @import("./ring_buffer.zig").RingBuffer;

const ADDRESS = .{ 127, 0, 0, 1 };
const PORT = 8083;

var clients: std.ArrayList(*Client) = undefined;
var udp_map: std.HashMap(std.net.Address, *Client, AddressContext, std.hash_map.default_max_load_percentage) = undefined;
var clients_mutex = std.Thread.Mutex{}; // To keep it thread-safe if needed

var udp_socket: xev.UDP = undefined;
// We'll need a pool of completions/states for outgoing UDP writes
// but for a simple test, we can use one.

//
// implement with xev like this
// https://github.com/Dg0230/libxev-http/blob/main/src/lib.zig
//
pub const PacketType = enum(u8) {
    handshake = 0,
    move = 1,
    chat = 2,
    disconnect = 3, // New
};

pub const MovePacket = extern struct {
    id: u64,
    type: PacketType = .move,
    x: f32,
    y: f32,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var next_player_id: usize = 1;

const AddressContext = struct {
    pub fn hash(self: AddressContext, addr: std.net.Address) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0);
        // We hash the internal representation of the address
        std.hash.autoHashStrat(&h, addr.any, .DeepRecursive);
        return h.final();
    }

    pub fn eql(self: AddressContext, a: std.net.Address, b: std.net.Address) bool {
        _ = self;
        // Compare the raw bytes of the addresses
        const a_bytes = std.mem.asBytes(&a.any);
        const b_bytes = std.mem.asBytes(&b.any);
        return std.mem.eql(u8, a_bytes, b_bytes);
    }
};

const Client = struct {
    conn: xev.TCP,
    id: usize = undefined,
    rb: RingBuffer(4096) = .{}, // Our custom RingBuffer

    udp_address: ?std.net.Address = null,

    read_c: xev.Completion = undefined,

    write_c: xev.Completion = undefined, // Added for future broadcasting
    write_buf: [4096]u8 = undefined, // Buffer to hold the outgoing message
    is_writing: bool = false, // To track if a write is in progress
    close_c: xev.Completion = undefined,

    send_queue: [16][]u8 = undefined,
    queue_read: usize = 0,
    queue_write: usize = 0,
    queue_len: usize = 0,

    last_udp_ts: i64 = 0, // Standard unix timestamp in milliseconds
};

fn reapTimedOutClients(loop: *xev.Loop) void {
    const now = std.time.milliTimestamp();
    const timeout_ms = 10_000; // 10 seconds

    clients_mutex.lock();
    defer clients_mutex.unlock();

    // Use a while loop because we are removing items during iteration
    var i: usize = 0;
    while (i < clients.items.len) {
        const client = clients.items[i];

        // Only check clients who have actually linked their UDP
        if (client.udp_address != null) {
            if (now - client.last_udp_ts > timeout_ms) {
                std.debug.print("Player {d} timed out. Reaping...\n", .{client.id});

                // This will trigger the closeCallback and cleanup the maps
                closeClient(loop, client);

                // Don't increment 'i' because swapRemove moved a new item here
                continue;
            }
        }
        i += 1;
    }
}

var reaper_timer: xev.Timer = undefined;
var reaper_completion: xev.Completion = .{};

pub fn main() !void {
    defer {
        const check = gpa.deinit();
        if (check == .leak) std.debug.print("Memory leak detected!\n", .{});
    }

    clients = .empty;
    defer clients.deinit(allocator);

    // udp_map = std.AutoHashMap(std.net.Address, *Client).init(allocator);
    // udp_map = std.HashMap(std.net.Address, *Client, AddressContext, std.hash_map.default_max_load_percentage).init(allocator, AddressContext{});
    udp_map = std.HashMap(std.net.Address, *Client, AddressContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer udp_map.deinit();

    var loop: xev.Loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const address = net.Address.initIp4(ADDRESS, PORT);
    var server = try xev.TCP.init(address);
    try server.bind(address);
    try server.listen(1024);
    var accept_completion: xev.Completion = .{};
    server.accept(&loop, &accept_completion, xev.TCP, &server, acceptCallback);

    udp_socket = try xev.UDP.init(address);
    try udp_socket.bind(address);

    // Add this: The persistent state for the UDP read operation
    var udp_state: xev.UDP.State = undefined;

    var udp_completion: xev.Completion = .{};
    var udp_buffer: [2048]u8 = undefined;

    // Use &udp_state as the 3rd argument
    udp_socket.read(
        &loop,
        &udp_completion,
        &udp_state, // Corrected: Pointer to State, not Socket
        .{ .slice = &udp_buffer },
        anyopaque,
        null,
        udpReadCallback,
    );

    reaper_timer = try xev.Timer.init();
    reaper_timer.run(&loop, &reaper_completion, 5000, anyopaque, null, reaperCallback);

    try loop.run(.until_done);
}

fn reaperCallback(
    _: ?*anyopaque,
    loop: *xev.Loop,
    c: *xev.Completion,
    res: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = res catch return .disarm;

    reapTimedOutClients(loop);

    // Re-arm the timer for another 5 seconds
    reaper_timer.run(loop, c, 5000, anyopaque, null, reaperCallback);
    return .disarm;
}

fn udpReadCallback(
    _: ?*anyopaque,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: *xev.UDP.State,
    addr: std.net.Address,
    _: xev.UDP,
    buf: xev.ReadBuffer,
    res: xev.ReadError!usize,
) xev.CallbackAction {
    const read_len = res catch |err| {
        std.debug.print("UDP Read Error: {}\n", .{err});
        return .rearm;
    };

    const data = buf.slice[0..read_len];
    if (data.len < 8) return .rearm; // Ignore tiny junk packets

    clients_mutex.lock();
    defer clients_mutex.unlock();

    if (udp_map.get(addr)) |client| {
        client.last_udp_ts = std.time.milliTimestamp();

        // Use @sizeOf to ensure we have enough bytes for the struct
        if (data.len >= @sizeOf(MovePacket)) {
            // FIX: Create a local, aligned struct and copy bytes into it
            var packet: MovePacket = undefined;
            @memcpy(std.mem.asBytes(&packet), data[0..@sizeOf(MovePacket)]);

            if (packet.type == .move) {
                std.debug.print("Player {d} moved: X:{d:.2} Y:{d:.2}\n", .{ client.id, packet.x, packet.y });

                // Broadcast the original raw bytes to others
                broadcastUdp(client, data[0..@sizeOf(MovePacket)], loop);
            }

            if (packet.type == .disconnect) {
                std.debug.print("Player {d} requested disconnect.\n", .{client.id});
                closeClient(loop, client);
                return .rearm;
            }
        }
    } else if (data.len >= 8) {
        // FIX: Use readInt to safely extract the u64 ID from potentially unaligned bytes
        const claimed_id = std.mem.readInt(u64, data[0..8], .little);

        for (clients.items) |client| {
            if (client.id == claimed_id) {
                client.udp_address = addr;
                udp_map.put(addr, client) catch {};
                std.debug.print("Linked UDP for Player {d}\n", .{claimed_id});
                break;
            }
        }
    }

    return .rearm;
}

fn broadcastUdp(sender: *Client, message: []const u8, loop: *xev.Loop) void {
    // clients_mutex.lock();
    // defer clients_mutex.unlock();

    for (clients.items) |recipient| {
        if (recipient == sender) continue;
        const target_addr = recipient.udp_address orelse continue;

        const c = allocator.create(xev.Completion) catch continue;
        const s = allocator.create(xev.UDP.State) catch continue;

        // Copy the message so it stays valid until the async write finishes
        const msg_copy = allocator.alloc(u8, message.len) catch continue;
        @memcpy(msg_copy, message);

        udp_socket.write(loop, c, s, target_addr, .{ .slice = msg_copy }, anyopaque, msg_copy.ptr, struct {
            fn callback(
                ud: ?*anyopaque,
                _: *xev.Loop,
                comp: *xev.Completion,
                state: *xev.UDP.State,
                _: xev.UDP, // <--- Error fix: The compiler wants the Watcher here, not Address
                buf: xev.WriteBuffer, // The buffer we sent
                res: xev.WriteError!usize,
            ) xev.CallbackAction {
                // Cleanup
                if (ud) |ptr| {
                    // We passed msg_copy.ptr as userdata to free the memory
                    const bytes = @as([*]u8, @ptrCast(ptr));
                    allocator.free(bytes[0..buf.slice.len]);
                }
                allocator.destroy(comp);
                allocator.destroy(state);
                _ = res catch {};
                return .disarm;
            }
        }.callback);
    }
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
        .id = next_player_id, // Assign the IDid_msg
        .last_udp_ts = std.time.milliTimestamp(),
    };
    std.debug.print("Player {d} connected via TCP\n", .{client.id});

    next_player_id += 1;

    clients_mutex.lock();
    clients.append(allocator, client) catch |err| {
        std.debug.print("Failed to add client to list: {}\n", .{err});
    };
    clients_mutex.unlock();

    // Send the ID to the client immediately so they can handshake on UDP
    // We'll just send it as a raw 8-byte message
    const id_msg = allocator.alloc(u8, 8) catch return .rearm;
    std.mem.writeInt(u64, id_msg[0..8], client.id, .little);

    // We reuse our broadcast logic's queueing system to send this safely
    client.send_queue[client.queue_write] = id_msg;
    client.queue_write = (client.queue_write + 1) % client.send_queue.len;
    client.queue_len += 1;
    if (!client.is_writing) writeNext(client, loop);

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
        if (recipient == sender) continue;

        // 1. Allocate memory for this specific broadcast message
        // (so it doesn't disappear when the sender's buffer changes)
        const msg_copy = allocator.alloc(u8, message.len) catch continue;
        @memcpy(msg_copy, message);

        // 2. Push to recipient queue
        if (recipient.queue_len >= recipient.send_queue.len) {
            allocator.free(msg_copy); // Queue full, drop message
            continue;
        }

        recipient.send_queue[recipient.queue_write] = msg_copy;
        recipient.queue_write = (recipient.queue_write + 1) % recipient.send_queue.len;
        recipient.queue_len += 1;

        // 3. If not busy, start the engine
        if (!recipient.is_writing) {
            writeNext(recipient, loop);
        }
    }
}

fn writeNext(client: *Client, loop: *xev.Loop) void {
    if (client.queue_len == 0) {
        client.is_writing = false;
        return;
    }

    client.is_writing = true;
    const next_msg = client.send_queue[client.queue_read];

    client.conn.write(
        loop,
        &client.write_c,
        .{ .slice = next_msg },
        Client,
        client,
        writeCallback,
    );
}

fn writeCallback(
    ud: ?*Client,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.WriteBuffer,
    res: xev.WriteError!usize,
) xev.CallbackAction {
    const client = ud.?;

    // 1. Clean up the message we just sent
    const finished_msg = client.send_queue[client.queue_read];
    allocator.free(finished_msg);

    // 2. Advance queue
    client.queue_read = (client.queue_read + 1) % client.send_queue.len;
    client.queue_len -= 1;

    _ = res catch |err| {
        std.debug.print("Write error: {}\n", .{err});
        // On error, maybe stop writing
        client.is_writing = false;
        return .disarm;
    };

    // 3. Keep the chain going if there are more messages
    writeNext(client, loop);

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
        clients_mutex.lock();
        defer clients_mutex.unlock();

        // 1. Remove from the UDP Map so we don't try to route packets to a dead client
        if (client.udp_address) |addr| {
            _ = udp_map.remove(addr);
            std.debug.print("Unlinked UDP for Player {d}\n", .{client.id});
        }

        // 2. Clear the TCP send queue
        while (client.queue_len > 0) {
            allocator.free(client.send_queue[client.queue_read]);
            client.queue_read = (client.queue_read + 1) % client.send_queue.len;
            client.queue_len -= 1;
        }

        // 3. Remove from the global list
        for (clients.items, 0..) |c, i| {
            if (c == client) {
                _ = clients.swapRemove(i);
                break;
            }
        }

        allocator.destroy(client);
    }
    return .disarm;
}
