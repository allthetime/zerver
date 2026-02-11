const std = @import("std");
const assert = std.debug.assert;

pub fn RingBuffer(comptime size: usize) type {
    // Ensure size is a power of 2 for potential mask optimization,
    // though we'll use modulo here for clarity.
    return struct {
        const Self = @This();

        data: [size]u8 = undefined,
        read_idx: usize = 0,
        write_idx: usize = 0,
        is_full: bool = false,

        pub fn len(self: Self) usize {
            if (self.is_full) return size;
            if (self.write_idx >= self.read_idx) {
                return self.write_idx - self.read_idx;
            }
            return size - self.read_idx + self.write_idx;
        }

        pub fn available(self: Self) usize {
            return size - self.len();
        }

        /// Returns two slices representing the writable space.
        /// The second slice will be empty if the space doesn't wrap.
        pub fn getWriteSlices(self: *Self) [2][]u8 {
            if (self.is_full) return .{ &[_]u8{}, &[_]u8{} };

            if (self.write_idx >= self.read_idx) {
                // Space from write_idx to end, and start to read_idx
                return .{
                    self.data[self.write_idx..size],
                    self.data[0..self.read_idx],
                };
            } else {
                // Space is contiguous between write and read
                return .{
                    self.data[self.write_idx..self.read_idx],
                    &[_]u8{},
                };
            }
        }

        pub fn advanceWrite(self: *Self, amount: usize) void {
            assert(amount <= self.available());
            self.write_idx = (self.write_idx + amount) % size;
            // if amount is a power of 2, we could optimize the modulo with a bitwise AND:
            // why? Because if size is a power of 2, then size - 1 will be a bitmask that wraps around correctly.
            // For example, if size is 8 (which is 2^3), then size - 1 is 7 (which is 0b111 in binary).
            // This means that when we do (self.write_idx + amount) & (size - 1), it will automatically wrap around
            // to the beginning of the buffer when it exceeds the size. This is a common optimization for ring buffers
            // when the size is a power of 2.
            //
            // self.write_idx = (self.write_idx + amount) & (size - 1);
            if (self.write_idx == self.read_idx and amount > 0) {
                self.is_full = true;
            }
        }

        pub fn advanceRead(self: *Self, amount: usize) void {
            assert(amount <= self.len());
            if (amount > 0) self.is_full = false;
            self.read_idx = (self.read_idx + amount) % size;
        }

        /// Copies data into dest without advancing the read pointer.
        pub fn peek(self: Self, dest: []u8) usize {
            const copy_amt = @min(dest.len, self.len());
            if (copy_amt == 0) return 0;

            if (self.read_idx + copy_amt <= size) {
                // Single linear copy
                @memcpy(dest[0..copy_amt], self.data[self.read_idx .. self.read_idx + copy_amt]);
            } else {
                // Wrapped copy
                const first_part = size - self.read_idx;
                @memcpy(dest[0..first_part], self.data[self.read_idx..size]);
                @memcpy(dest[first_part..copy_amt], self.data[0 .. copy_amt - first_part]);
            }
            return copy_amt;
        }

        pub fn findDelimiter(self: Self, delimiter: u8) ?usize {
            const length = self.len();
            var i: usize = 0;
            while (i < length) : (i += 1) {
                // Map logical index to the physical array index using modulo
                const actual_idx = (self.read_idx + i) % size;
                if (self.data[actual_idx] == delimiter) {
                    return i;
                }
            }
            return null;
        }
    };
}
