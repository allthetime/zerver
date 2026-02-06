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