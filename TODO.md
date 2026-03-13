# Game Server Implementation Plan

This document outlines the roadmap to refactor the current basic TCP server into a high-performance, real-time game server using a hybrid TCP/UDP architecture and efficient memory management.

## 1. Core Data Structures

### 1.1 Ring Buffer (`src/ringbuffer.zig`)
Implement a fixed-size Ring Buffer to handle TCP stream parsing without O(N) memory shifting.

- [ ] Create generic `RingBuffer(comptime size: usize)` struct.
- [ ] Implement `getWriteSlices() -> [2][]u8` to support wrapping writes.
    - *Math:* If `write >= read`: `[write..size]` and `[0..read-1]`.
    - *Math:* If `write < read`: `[write..read-1]`.
- [ ] Implement `advanceWrite(amount: usize)` to commit incoming data.
    - *Math:* `write_index = (write_index + amount) % size`.
- [ ] Implement `peek(dest: []u8)` to read data without consuming it (for headers).
    - *Logic:* Handle wrapping copy if data crosses the end of the buffer.
- [ ] Implement `advanceRead(amount: usize)` to consume processed messages.
    - *Math:* `read_index = (read_index + amount) % size`.

### 1.2 Enhanced Client (`src/client.zig`)
Encapsulate transport logic and buffering inside the Client struct to clean up the main loop.

- [ ] Add `rb: RingBuffer(16384)` to `Client` struct.
- [ ] Add `id: u32` for identifying clients across UDP/TCP.
- [ ] Add `udp_address: ?net.Address` to store the client's UDP endpoint.
- [ ] Implement `notifyRead(bytes)`: Wraps `rb.advanceWrite`.
- [ ] Implement `nextMessage(out_buf) -> ?[]u8`: 
    - Checks for 2-byte length header.
    - Checks if full body is present.
    - Peeks body into `out_buf`.
    - Advances read index.
- [ ] Implement `waitNext(loop, callback)`: calls `conn.read` using `rb.getWriteSlices`.

### 1.3 TCP Write Queue (`src/client.zig`)
Implement a robust output system to handle backpressure and broadcasting without blocking.

- [ ] Add `write_queue: std.ArrayList(u8)` to `Client` struct (dynamic outbox).
- [ ] Add `write_buf: [4096]u8` to `Client` struct (stable buffer for xev).
- [ ] Add `is_writing: bool` flag to prevent concurrent writes on the same socket.
- [ ] Implement `queueData(data: []u8)`: Appends data to `write_queue` and calls `tryFlush`.
- [ ] Implement `tryFlush(loop)`:
    - Checks if `is_writing` is true (returns if so).
    - Checks if queue is empty.
    - Copies chunk from `write_queue` to `write_buf`.
    - Calls `conn.write` with `writeCallback`.
- [ ] Implement `writeCallback`:
    - Clears `is_writing`.
    - Removes sent bytes from `write_queue` using `replaceRange`.
    - Calls `tryFlush` again if data remains.
- [ ] Implement `deinit()`: Ensure `write_queue.deinit()` is called to prevent leaks.

## 2. Server Architecture (Hybrid TCP/UDP)

### 2.1 Initialization (`src/main.zig`)
- [ ] Initialize `GeneralPurposeAllocator`.
- [ ] Setup `xev.TCP` listener on port 8083 (Reliable: Login, Chat, Item pick ups).
- [ ] Setup `xev.UDP` socket on port 8084 (Unreliable: Movement, Position updates).
- [ ] **Important:** Set `TCP_NODELAY` on the TCP socket to disable Nagle's algorithm.

### 2.2 Global State
- [ ] Create `clients: AutoHashMap(u32, *Client)` to map IDs to client instances.
- [ ] Create `ServerState` struct to hold the UDP socket and the global Timer.
- [ ] Add `next_client_id: u32` global counter.

## 3. The Game Loop (Timer)

Games require a fixed tick rate (e.g., 20Hz) rather than purely reactive broadcasts.

- [ ] Initialize `xev.Timer`.
- [ ] Create `gameTickCallback` that runs every 50ms (20Hz).
- [ ] **Step 1:** Iterate through `clients`.
- [ ] **Step 2:** Prepare a "World State" packet (containing positions of relevant players).
- [ ] **Step 3:** Send World State via UDP to each client's `udp_address` (if known).
- [ ] **Step 4:** Reschedule timer.

## 4. Protocol & Logic

### 4.1 Packet Format
Define a binary protocol. Do not use strings. Use Little Endian for all numbers.

**TCP (Stream):** `[Length: u16] [Type: u8] [Payload...]`
**UDP (Datagram):** `[ClientID: u32] [Seq: u32] [Type: u8] [Payload...]`

### 4.2 TCP Handling (`tcpReadCallback`)
- [ ] Call `client.notifyRead()`.
- [ ] Loop `while (client.nextMessage(&buf))` to process coalesced packets.
- [ ] Handle "Reliable" events (Login, Chat).
- [ ] Call `client.waitNext()`.

### 4.3 UDP Handling (`udpReadCallback`)
- [ ] Read packet into a reusable server-wide buffer.
- [ ] Extract `ClientID` from header.
- [ ] Look up Client in global HashMap.
- [ ] **Crucial:** Update `client.udp_address` with the sender's address (allows server to reply via UDP).
- [ ] Update Client's internal state (x, y, inputs) based on payload.
- [ ] Do **not** broadcast immediately. Let the `gameTickCallback` handle it.

### 4.4 Broadcasting Logic
- [ ] Implement `broadcast(data: []u8)` function.
- [ ] Iterate over `clients` HashMap.
- [ ] For each client, call `client.queueData(data)`.
- [ ] Ensure broadcast does not block; it just queues data.

## 5. Memory Safety

- [ ] Ensure `gpa.deinit()` is called at shutdown to check for leaks.
- [ ] Use `tcp_server.accept` error handling to prevent server crash on connection failures.
- [ ] Ensure Client is removed from HashMap and `allocator.destroy(client)` is called on TCP disconnect.
- [ ] Ensure `client.write_queue` is freed in `closeCallback`.





https://www.youtube.com/watch?v=hEIBsqP63Pg












You’ve built a solid, working "Vertical Slice" of a game server. To take this from a prototype to something that can handle 100+ players without crashing or lagging, you need to transition from "Doing it the easy way" to "Doing it the efficient way."

Here is your roadmap for production-hardening:
1. Zero-Allocation Game Loop

Currently, your broadcastUdp calls allocator.create and allocator.alloc every time a packet arrives. In production, this will cause "GC-like" stutters and memory fragmentation.

    The Fix: Use a Pool of Completions. Pre-allocate 1,000 xev.Completion and xev.UDP.State objects at startup.

    The Fix: Use a Ring Buffer for outgoing UDP. Instead of alloc, copy outgoing data into a pre-allocated circular byte-buffer.

2. Handling Network Jitter (Client Side)

UDP packets arrive out of order or multiple times. If "Packet 5" arrives after "Packet 6", your player will "teleport" backward.

    The Fix: Add a sequence: u32 or timestamp: u64 to your MovePacket.

    The Fix: The server (and client) should drop any packet where the sequence is lower than the last one received.

3. UDP Heartbeats (Ghosting)

Right now, if a player's internet dies or their router resets, the TCP connection might stay "half-open" for minutes, and the udp_map will stay cluttered.

    The Fix: Store a last_seen: i64 (timestamp) on the Client struct.

    The Fix: Every time a UDP packet arrives, update last_seen.

    The Fix: Run a "Reaper" task every 10 seconds. If a client hasn't sent a UDP packet in 30 seconds, force-close their TCP connection.

4. Security & Validation

In your current code, a hacker could send a UDP packet with Player ID: 1 from a different IP, and the server might believe it.

    The Fix: When a player connects via TCP, generate a Secret Token (random u64).

    The Fix: The UDP Handshake must include this token. The server only links the udp_address if the token matches the TCP session.

    The Fix: Sanitize coordinates. If a player is at X: 0 and the next packet says X: 5000 (teleporting), reject it.

5. Transition to "Bit-Packing"

extern struct is great, but as your game grows, 17 bytes per packet adds up.

    The Fix: Use u16 for coordinates if your world isn't massive.

    The Fix: Use bit-flags for booleans (IsJumping, IsShooting) to pack 8 actions into a single byte.

Summary Table: Where We Are vs. Where We're Going
Feature	Current (Prototype)	Production (Goal)
Memory	Dynamic alloc on every packet	Fixed-size pre-allocated pools
Identity	Incremental ID (easy to guess)	UUID or Random Secret Tokens
Movement	Raw strings/floats	Sequenced, delta-compressed bits
Concurrency	One big clients_mutex	Sharded HashMaps (to reduce lock contention)
Reliability	"Fire and forget"	Heartbeats and Timeout Reapers
Your Next Step

To see the immediate performance gain, you should pre-allocate a pool of completions for your UDP broadcasts so the allocator isn't working overtime.

Would you like me to show you how to implement a simple "Completion Pool" to replace the allocator.create calls in your broadcast function?




Run the Reaper: In a real production server, you’d use a xev.Timer to run this every few seconds. For your current setup, you can simply call reapTimedOutClients(loop) at the start of your acceptCallback or udpReadCallback to "clean as you go."

Final Pro-Tip: The "Graceful Exit"

In your client.zig, if you want to be a "good citizen," you can send a specific PacketType.disconnect before closing the app. The server can then immediately call closeClient instead of waiting for the 10-second timeout.

You've got the full loop now: Connect -> Link -> Broadcast -> Timeout.

Happy coding, and may your latencies be low! Would you like to see how to set up that xev.Timer to automate the Reaper?

