//! This ring buffer stores read and write indices while being able to utilise
//! the full backing slice by incrementing the indices modulo twice the slice's
//! length and reducing indices modulo the slice's length on slice access. This
//! means that whether the ring buffer is full or empty can be distinguished by
//! looking at the difference between the read and write indices without adding
//! an extra boolean flag or having to reserve a slot in the buffer.
//!
//! This ring buffer has not been implemented with thread safety in mind, and
//! therefore should not be assumed to be suitable for use cases involving
//! separate reader and writer threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const copyForwards = std.mem.copyForwards;

/// If atomic is true, this ringbuffer will use atomic operations
/// for manipulating `read_index` and `write_index`.
pub fn RingBuffer(SampleType: type, comptime atomic: bool) type {
    return struct {
        data: []SampleType,
        read_index: if (atomic) std.atomic.Value(usize) else usize,
        write_index: if (atomic) std.atomic.Value(usize) else usize,

        const Self = @This();
        pub const Error = error{ Full, ReadLengthInvalid };

        pub fn init(bytes: []SampleType) Self {
            assert(@popCount(bytes.len) < 2); // buffer is not a power of 2
            return Self{
                .data = bytes,
                .write_index = if (atomic) .init(0) else 0,
                .read_index = if (atomic) .init(0) else 0,
            };
        }

        /// Returns `index` modulo the length of the backing slice.
        pub fn mask(self: Self, index: usize) usize {
            return index % self.data.len;
        }

        /// Returns `index` modulo twice the length of the backing slice.
        pub fn mask2(self: Self, index: usize) usize {
            return index % (2 * self.data.len);
        }

        /// Write a sample into the ring buffer. Returns `error.Full` if the ring
        /// buffer is full.
        pub fn write(self: *Self, sample: SampleType) Error!void {
            if (self.isFull()) return error.Full;
            self.writeImpl(sample);
        }

        /// Write a sample into the ring buffer. If the ring buffer is full, the
        /// oldest sample is overwritten.
        pub fn writeAssumeCapacity(self: *Self, sample: SampleType) void {
            if (atomic) @compileError("not supported in atomic mode");
            self.writeImpl(sample);
        }

        fn writeImpl(self: *Self, sample: SampleType) void {
            const idx = if (atomic) self.write_index.load(.acquire) else self.write_index;

            self.data[self.mask(idx)] = sample;
            const new_idx = self.mask2(idx + 1);

            if (atomic) {
                self.write_index.store(new_idx, .release);
            } else {
                self.write_index = new_idx;
            }
        }

        /// Write samples into the ring buffer. Returns `error.Full` if the ring
        /// buffer does not have enough space, without writing any data.
        /// Uses memcpy and so 'samples' must not overlap ring buffer data.
        pub fn writeSlice(self: *Self, samples: []const SampleType) Error!void {
            if (self.len() + samples.len > self.data.len) return error.Full;
            self.writeSliceImpl(samples);
        }

        /// Write samples into the ring buffer. If there is not enough space, older
        /// samples will be overwritten.
        /// Uses memcpy and so 'samples' must not overlap ring buffer data.
        pub fn writeSliceAssumeCapacity(self: *Self, samples: []const SampleType) void {
            if (atomic) @compileError("not supported in atomic mode");
            self.writeSliceImpl(samples);
        }

        fn writeSliceImpl(self: *Self, samples: []const SampleType) void {
            assert(samples.len <= self.data.len);

            const idx = if (atomic) self.write_index.load(.acquire) else self.write_index;

            const data_start = self.mask(idx);
            const part1_data_end = @min(data_start + samples.len, self.data.len);
            const part1_len = part1_data_end - data_start;
            @memcpy(self.data[data_start..part1_data_end], samples[0..part1_len]);

            const remaining = samples.len - part1_len;
            const to_write = @min(remaining, remaining % self.data.len + self.data.len);
            const part2_bytes_start = samples.len - to_write;
            const part2_bytes_end = @min(part2_bytes_start + self.data.len, samples.len);
            const part2_len = part2_bytes_end - part2_bytes_start;
            @memcpy(self.data[0..part2_len], samples[part2_bytes_start..part2_bytes_end]);
            if (part2_bytes_end != samples.len) {
                const part3_len = samples.len - part2_bytes_end;
                @memcpy(self.data[0..part3_len], samples[part2_bytes_end..samples.len]);
            }

            const new_idx = self.mask2(idx + samples.len);
            if (atomic) {
                self.write_index.store(new_idx, .release);
            } else {
                self.write_index = new_idx;
            }
        }

        pub fn writeZeroesAssumeCapacity(self: *Self, count: usize) void {
            if (atomic) @compileError("not supported in atomic mode");
            assert(count <= self.data.len);

            const data_start = self.mask(self.write_index);
            const part1_data_end = @min(data_start + count, self.data.len);
            const part1_len = part1_data_end - data_start;
            @memset(self.data[data_start..part1_data_end], 0);

            const remaining = count - part1_len;
            const to_write = @min(remaining, remaining % self.data.len + self.data.len);
            const part2_bytes_start = count - to_write;
            const part2_bytes_end = @min(part2_bytes_start + self.data.len, count);
            const part2_len = part2_bytes_end - part2_bytes_start;
            @memset(self.data[0..part2_len], 0);

            if (part2_bytes_end != count) {
                const part3_len = count - part2_bytes_end;
                @memset(self.data[0..part3_len], 0);
            }

            self.write_index = self.mask2(self.write_index + count);
        }

        /// Write samples into the ring buffer. Returns `error.Full` if the ring
        /// buffer does not have enough space, without writing any data.
        /// Uses copyForwards and can write slices from this RingBuffer into itself.
        pub fn writeSliceForwards(self: *Self, samples: []const SampleType) Error!void {
            if (atomic) @compileError("not supported in atomic mode");
            if (self.len() + samples.len > self.data.len) return error.Full;
            self.writeSliceForwardsAssumeCapacity(samples);
        }

        /// Write samples into the ring buffer. If there is not enough space, older
        /// samples will be overwritten.
        /// Uses copyForwards and can write slices from this RingBuffer into itself.
        pub fn writeSliceForwardsAssumeCapacity(self: *Self, samples: []const SampleType) void {
            if (atomic) @compileError("not supported in atomic mode");
            assert(samples.len <= self.data.len);
            const data_start = self.mask(self.write_index);
            const part1_data_end = @min(data_start + samples.len, self.data.len);
            const part1_len = part1_data_end - data_start;
            copyForwards(u8, self.data[data_start..], samples[0..part1_len]);

            const remaining = samples.len - part1_len;
            const to_write = @min(remaining, remaining % self.data.len + self.data.len);
            const part2_bytes_start = samples.len - to_write;
            const part2_bytes_end = @min(part2_bytes_start + self.data.len, samples.len);
            copyForwards(u8, self.data[0..], samples[part2_bytes_start..part2_bytes_end]);
            if (part2_bytes_end != samples.len)
                copyForwards(u8, self.data[0..], samples[part2_bytes_end..samples.len]);
            self.write_index = self.mask2(self.write_index + samples.len);
        }

        /// Consume a sample from the ring buffer and return it. Returns `null` if the
        /// ring buffer is empty.
        pub fn read(self: *Self) ?SampleType {
            if (self.isEmpty()) return null;
            return self.readImpl();
        }

        /// Consume a sample from the ring buffer and return it; asserts that the buffer
        /// is not empty.
        pub fn readAssumeLength(self: *Self) SampleType {
            if (atomic) @compileError("not supported in atomic mode");
            return self.readImpl();
        }

        fn readImpl(self: *Self) SampleType {
            assert(!self.isEmpty());
            const idx = if (atomic) self.read_index.load(.release) else self.read_index;
            const byte = self.data[self.mask(idx)];
            const new_idx = self.mask2(idx + 1);
            if (atomic) {
                self.read_index.store(new_idx, .release);
            } else {
                self.read_index = new_idx;
            }
            return byte;
        }

        /// Reads first 'count' samples written to the ring buffer into `dest`; Returns
        /// Error.ReadLengthInvalid if count greater than ring or dest length
        /// Uses memcpy and so `dest` must not overlap ring buffer data.
        pub fn readFirst(self: *Self, dest: []SampleType, count: usize) Error!void {
            if (atomic) @compileError("not supported in atomic mode");
            if (count > self.len() or count > dest.len) return error.ReadLengthInvalid;
            self.readFirstAssumeCount(dest, count);
        }

        /// Reads first 'count' samples written to the ring buffer into `dest`;
        /// Asserts that count not greater than ring buffer or dest length
        /// Uses memcpy and so `dest` must not overlap ring buffer data.
        pub fn readFirstAssumeCount(self: *Self, dest: []SampleType, count: usize) void {
            if (atomic) @compileError("not supported in atomic mode");
            assert(count <= self.len() and count <= dest.len);
            const s = self.sliceAt(self.read_index, count);
            s.copyTo(dest);
            self.read_index = self.mask2(self.read_index + count);
        }

        /// Reads last 'count' samples written to the ring buffer into `dest`; Returns
        /// Error.ReadLengthInvalid if count greater than ring or dest length
        /// Uses memcpy and so `dest` must not overlap ring buffer data.
        /// Reduces write index by 'count'.
        pub fn readLast(self: *Self, dest: []SampleType, count: usize) Error!void {
            if (atomic) @compileError("not supported in atomic mode");
            if (count > self.len() or count > dest.len) return error.ReadLengthInvalid;
            self.readLastAssumeCount(dest, count);
        }

        /// Reads last `length` bytes written to the ring buffer into `dest`;
        /// Asserts that length not greater than ring buffer or dest length
        /// Uses memcpy and so `dest` must not overlap ring buffer data.
        /// Reduces write index by `length`.
        pub fn readLastAssumeCount(self: *Self, dest: []SampleType, count: usize) void {
            if (atomic) @compileError("not supported in atomic mode");
            assert(count <= self.len() and count <= dest.len);
            const s = self.sliceLast(count);
            s.copyTo(dest);
            self.write_index = if (self.write_index >= self.data.len)
                self.write_index - count
            else
                self.mask(self.write_index + self.data.len - count);
        }

        /// Returns `true` if the ring buffer is empty and `false` otherwise.
        pub fn isEmpty(self: Self) bool {
            const w = if (atomic) self.write_index.load(.acquire) else self.write_index;
            const r = if (atomic) self.read_index.load(.acquire) else self.read_index;
            return w == r;
        }

        /// Returns `true` if the ring buffer is full and `false` otherwise.
        pub fn isFull(self: Self) bool {
            const w = if (atomic) self.write_index.load(.acquire) else self.write_index;
            const r = if (atomic) self.read_index.load(.acquire) else self.read_index;
            return self.mask2(w + self.data.len) == r;
        }

        /// Returns the count of data available for reading
        pub fn len(self: Self) usize {
            const w = if (atomic) self.write_index.load(.acquire) else self.write_index;
            const r = if (atomic) self.read_index.load(.acquire) else self.read_index;
            return self.lenImpl(w, r);
        }

        pub fn lenImpl(self: Self, w: usize, r: usize) usize {
            const wrap_offset = 2 * self.data.len * @intFromBool(w < r);
            const adjusted_write_index = w + wrap_offset;
            return adjusted_write_index - r;
        }

        /// A `Slice` represents a region of a ring buffer. The region is split into two
        /// sections as the ring buffer data will not be contiguous if the desired
        /// region wraps to the start of the backing slice.
        pub const Slice = struct {
            first: []SampleType,
            second: []SampleType,

            pub fn len(self: Slice) usize {
                return self.first.len + self.second.len;
            }

            /// Copy data from `self` into `dest`
            pub fn copyTo(self: Slice, dest: []SampleType) void {
                @memcpy(dest[0..self.first.len], self.first);
                @memcpy(dest[self.first.len..][0..self.second.len], self.second);
            }
        };

        /// Returns a `Slice` for the region of the ring buffer starting at
        /// `self.mask(start_unmasked)` with the specified count.
        pub fn sliceAt(self: Self, start_unmasked: usize, count: usize) Slice {
            assert(count <= self.data.len);
            const slice1_start = self.mask(start_unmasked);
            const slice1_end = @min(self.data.len, slice1_start + count);
            const slice1 = self.data[slice1_start..slice1_end];
            const slice2 = self.data[0 .. count - slice1.len];
            return Slice{
                .first = slice1,
                .second = slice2,
            };
        }

        /// Returns a slice to the written region.
        pub fn slice(self: Self) Slice {
            const w = if (atomic) self.write_index.load(.acquire) else self.write_index;
            const r = if (atomic) self.read_index.load(.acquire) else self.read_index;
            const l = self.lenImpl(w, r);
            return self.sliceAt(r, l);
        }

        pub fn readIndices(self: Self) struct { usize, usize } {
            const w = if (atomic) self.write_index.load(.acquire) else self.write_index;
            const r = if (atomic) self.read_index.load(.acquire) else self.read_index;
            const l = self.lenImpl(w, r);
            return .{ r, l };
        }

        /// Returns a `Slice` for the last `length` items written to the ring buffer.
        /// Does not check that any  data has been written into the region.
        pub fn sliceLast(self: Self, length: usize) Slice {
            const idx = if (atomic) self.write_index.load(.acquire) else self.write_index;
            return self.sliceAt(idx + self.data.len - length, length);
        }
    };
}
