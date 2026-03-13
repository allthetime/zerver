const std = @import("std");
const net = std.net;
const posix = std.posix;

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

pub fn main() !void {
    const server_addr = try net.Address.parseIp4("127.0.0.1", 8083);

    // 1. TCP Connection to get ID
    const tcp_stream = try net.tcpConnectToAddress(server_addr);
    defer tcp_stream.close();

    var id_buf: [8]u8 = undefined;
    _ = try tcp_stream.read(&id_buf);
    const my_id = std.mem.readInt(u64, &id_buf, .little);
    std.debug.print("Connected! My ID: {d}\n", .{my_id});

    // 2. Setup UDP Socket
    const udp_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(udp_fd);

    // Set a very short timeout so we can "poll" both sending and receiving
    const timeout = posix.timeval{ .sec = 0, .usec = 10000 };
    try posix.setsockopt(udp_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

    // 3. Handshake (Link the UDP port)
    _ = try posix.sendto(udp_fd, &id_buf, 0, &server_addr.any, server_addr.getOsSockLen());

    var timer = try std.time.Timer.start();
    // var tick_count: u32 = 0;

    std.debug.print("Auto-sending packets every 1s...\n", .{});

    var x: f32 = 0.0;

    // ADD THIS DEFER:
    // This ensures that when the client program exits, it tells the server to stop broadcasting to us.
    defer {
        const leave_packet = MovePacket{
            .id = my_id,
            .type = .disconnect, // Tell the server we are out!
            .x = 0,
            .y = 0,
        };
        _ = posix.sendto(udp_fd, std.mem.asBytes(&leave_packet), 0, &server_addr.any, server_addr.getOsSockLen()) catch {};
        std.debug.print("Sent disconnect packet. Goodbye!\n", .{});
    }

    while (true) {
        if (timer.read() >= std.time.ns_per_s) {
            x += 1.5; // Simulate moving

            // Create the struct
            const move = MovePacket{
                .id = my_id,
                .type = .move,
                .x = x,
                .y = 10.0,
            };

            // Send the raw bytes of the struct
            const bytes = std.mem.asBytes(&move);
            _ = try posix.sendto(udp_fd, bytes, 0, &server_addr.any, server_addr.getOsSockLen());

            timer.reset();
        }

        // Receive Logic (parsing the struct)
        var recv_buf: [1024]u8 = undefined;
        if (posix.recvfrom(udp_fd, &recv_buf, 0, null, null)) |n| {
            if (n >= @sizeOf(MovePacket)) {
                // const p = @as(*const MovePacket, @ptrCast(@alignCast(&recv_buf)));
                // std.debug.print("BROADCAST: Player {d} is at {d:.2}, {d:.2}\n", .{ p.id, p.x, p.y });
                var p: MovePacket = undefined;
                @memcpy(std.mem.asBytes(&p), recv_buf[0..@sizeOf(MovePacket)]);
                std.debug.print("BROADCAST: Player {d} is at {d:.2}, {d:.2}\n", .{ p.id, p.x, p.y });
            }
        } else |_| {}
    }
}
