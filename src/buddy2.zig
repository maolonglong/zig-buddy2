const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.buddy2);
const assert = std.debug.assert;
const testing = std.testing;
const math = std.math;
const mem = std.mem;
const isPowerOfTwo = math.isPowerOfTwo;
const Allocator = mem.Allocator;

pub const Log2Size = math.Log2Int(usize);

pub const Config = struct {
    /// Enables emitting info messages with the size and address of every allocation.
    verbose_log: bool = false,
};

pub const Check = std.heap.Check;

pub fn Buddy2Allocator(comptime config: Config) type {
    return struct {
        const Self = @This();

        manager: *Buddy2,
        bytes: []u8,

        pub fn init(bytes: []u8) Self {
            var ctx_len = bytes.len / 3 * 2;
            if (!isPowerOfTwo(ctx_len)) {
                ctx_len = fixLen(ctx_len) >> 1;
            }
            return Self{
                .manager = Buddy2.init(bytes[0..ctx_len]),
                .bytes = bytes[ctx_len..],
            };
        }

        pub fn detectLeaks(self: *const Self) bool {
            const slice: []u8 = @as([*]u8, @ptrCast(&self.manager._longest))[0 .. self.manager.getLen() * 2 - 1];
            var leaks = false;
            for (slice, 0..) |longest, i| {
                if (longest == 0) {
                    if (!builtin.is_test) {
                        log.err("memory address 0x{x} leaked", .{@intFromPtr(self.bytes.ptr) + self.manager.indexToOffset(i)});
                    }
                    leaks = true;
                }
            }
            return leaks;
        }

        pub fn deinit(self: *Self) Check {
            const leaks = self.detectLeaks();
            self.* = undefined;
            return @as(Check, @enumFromInt(@intFromBool(leaks)));
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ret_addr: usize) ?[*]u8 {
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const ptr = self.alignedAlloc(len, log2_ptr_align);
            if (config.verbose_log and ptr != null) {
                log.info("alloc {d} bytes at {*}", .{ len, ptr.? });
            }
            return ptr;
        }

        fn alignedAlloc(self: *Self, len: usize, log2_ptr_align: u8) ?[*]u8 {
            const alignment = @as(usize, 1) << @as(Allocator.Log2Align, @intCast(log2_ptr_align));

            var unaligned_ptr = @as([*]u8, @ptrCast(self.unalignedAlloc(len + alignment - 1) orelse return null));
            const unaligned_addr = @intFromPtr(unaligned_ptr);
            const aligned_addr = mem.alignForward(usize, unaligned_addr, alignment);

            return unaligned_ptr + (aligned_addr - unaligned_addr);
        }

        fn unalignedAlloc(self: *Self, len: usize) ?[*]u8 {
            const offset = self.manager.alloc(len) orelse return null;
            return @ptrFromInt(@intFromPtr(self.bytes.ptr) + offset);
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_old_align: u8, new_len: usize, ret_addr: usize) bool {
            _ = log2_old_align;
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const ok = new_len <= self.alignedAllocSize(buf.ptr);
            if (config.verbose_log and ok) {
                log.info("resize {d} bytes at {*} to {d}", .{
                    buf.len, buf.ptr, new_len,
                });
            }
            return ok;
        }

        fn alignedAllocSize(self: *Self, ptr: [*]u8) usize {
            const aligned_offset = @intFromPtr(ptr) - @intFromPtr(self.bytes.ptr);
            const index = self.manager.backward(aligned_offset);

            const unaligned_offset = self.manager.indexToOffset(index);
            const unaligned_size = self.manager.indexToSize(index);

            return unaligned_size - (aligned_offset - unaligned_offset);
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_old_align: u8, ret_addr: usize) void {
            _ = log2_old_align;
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (config.verbose_log) {
                log.info("free {d} bytes at {*}", .{ buf.len, buf.ptr });
            }
            self.alignedFree(buf.ptr);
        }

        fn alignedFree(self: *Self, ptr: [*]u8) void {
            self.manager.free(@intFromPtr(ptr) - @intFromPtr(self.bytes.ptr));
        }
    };
}

pub const Buddy2 = struct {
    const Self = @This();

    _len: u8,
    _longest: [1]u8,

    pub fn init(ctx: []u8) *Self {
        const len = ctx.len / 2;
        assert(isPowerOfTwo(len));

        const self: *Self = @ptrCast(@alignCast(ctx));
        self.setLen(len);
        var node_size = len * 2;

        for (0..2 * len - 1) |i| {
            if (isPowerOfTwo(i + 1)) {
                node_size /= 2;
            }
            self.setLongest(i, node_size);
        }
        return self;
    }

    pub fn alloc(self: *Self, len: usize) ?usize {
        const new_len = fixLen(len);
        var index: usize = 0;

        if (self.getLongest(index) < new_len) {
            return null;
        }

        var node_size = self.getLen();
        while (node_size != new_len) : (node_size /= 2) {
            const left_longest = self.getLongest(left(index));
            const right_longest = self.getLongest(right(index));
            if (left_longest >= new_len and (right_longest < new_len or right_longest >= left_longest)) {
                index = left(index);
            } else {
                index = right(index);
            }
        }

        self.setLongest(index, 0);
        // const offset = self.indexToOffset(index);
        const offset = (index + 1) * node_size - self.getLen();

        while (index != 0) {
            index = parent(index);
            self.setLongest(index, @max(self.getLongest(left(index)), self.getLongest(right(index))));
        }

        return offset;
    }

    pub fn free(self: *Self, offset: usize) void {
        assert(offset >= 0 and offset < self.getLen());

        var node_size: usize = 1;
        var index = offset + self.getLen() - 1;

        while (self.getLongest(index) != 0) : (index = parent(index)) {
            node_size *= 2;
            if (index == 0) {
                return;
            }
        }
        self.setLongest(index, node_size);

        while (index != 0) {
            index = parent(index);
            node_size *= 2;

            const left_longest = self.getLongest(left(index));
            const right_longest = self.getLongest(right(index));

            if (left_longest + right_longest == node_size) {
                self.setLongest(index, node_size);
            } else {
                self.setLongest(index, @max(left_longest, right_longest));
            }
        }
    }

    pub fn size(self: *const Self, offset: usize) usize {
        return self.indexToSize(self.backward(offset));
    }

    fn backward(self: *const Self, offset: usize) usize {
        assert(offset >= 0 and offset < self.getLen());

        var index = offset + self.getLen() - 1;
        while (self.getLongest(index) != 0) {
            index = parent(index);
        }

        return index;
    }

    inline fn getLen(self: *const Self) usize {
        return @as(usize, 1) << @as(Log2Size, @intCast(self._len));
    }

    inline fn setLen(self: *Self, len: usize) void {
        self._len = math.log2_int(usize, len);
    }

    inline fn indexToSize(self: *const Self, index: usize) usize {
        return self.getLen() >> math.log2_int(usize, index + 1);
    }

    inline fn indexToOffset(self: *const Self, index: usize) usize {
        // return (index + 1) * node_size - self.len;
        return (index + 1) * self.indexToSize(index) - self.getLen();
    }

    inline fn getLongest(self: *const Self, index: usize) usize {
        const ptr: [*]const u8 = @ptrCast(&self._longest);
        const node_size = ptr[index];
        // if (node_size == 0) {
        //     return 0;
        // }
        // return @as(usize, 1) << @truncate(node_size - 1);
        return (@as(usize, 1) << @as(Log2Size, @intCast(node_size))) >> 1;
    }

    inline fn setLongest(self: *Self, index: usize, node_size: usize) void {
        const ptr: [*]u8 = @ptrCast(&self._longest);
        // if (node_size == 0) {
        //     ptr[index] = 0;
        //     return;
        // }
        // ptr[index] = math.log2_int(usize, node_size) + 1;
        ptr[index] = math.log2_int(usize, (node_size << 1) | 1);
    }

    inline fn left(index: usize) usize {
        return index * 2 + 1;
    }

    inline fn right(index: usize) usize {
        return index * 2 + 2;
    }

    inline fn parent(index: usize) usize {
        return (index + 1) / 2 - 1;
    }
};

const fixLen = switch (@sizeOf(usize)) {
    4 => fixLen32,
    8 => fixLen64,
    else => @panic("unsupported arch"),
};

fn fixLen32(len: usize) usize {
    var n = len - 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    if (n < 0) {
        return 1;
    }
    return n + 1;
}

fn fixLen64(len: usize) usize {
    var n = len - 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    n |= n >> 32;
    if (n < 0) {
        return 1;
    }
    return n + 1;
}

test "Buddy2Allocator" {
    // Copied from std/heap.zig test "FixedBufferAllocator"
    const heap_size = comptime fixLen(800000 * @sizeOf(u64));

    const S = struct {
        var heap: [3 * heap_size + 1024]u8 = undefined;
    };

    var buddy2 = Buddy2Allocator(.{}).init(S.heap[0..]);
    defer testing.expect(buddy2.deinit() == .ok) catch @panic("leak");
    var allocator = buddy2.allocator();

    const slice = try allocator.alloc(u8, 1);
    try testing.expect(buddy2.detectLeaks());
    allocator.free(slice);
    try testing.expect(!buddy2.detectLeaks());

    // TODO: detect double free
    allocator.free(slice);

    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}

test "Buddy2" {
    const heap_size = 16;

    const S = struct {
        var ctx: [2 * heap_size]u8 = undefined;
    };

    var buddy2 = Buddy2.init(S.ctx[0..]);

    for (0..16) |i| {
        const offset = buddy2.alloc(1).?;
        try testing.expectEqual(i, offset);
        try testing.expectEqual(@as(usize, 1), buddy2.size(offset));
    }

    try testing.expect(buddy2.alloc(1) == null);

    for (0..16) |i| {
        buddy2.free(i);
    }

    for (0..16) |i| {
        const offset = buddy2.alloc(1).?;
        try testing.expectEqual(i, offset);
        try testing.expectEqual(@as(usize, 1), buddy2.size(offset));
    }

    try testing.expect(buddy2.alloc(1) == null);

    for (0..16) |i| {
        buddy2.free(i);
    }

    try testing.expectEqual(@as(usize, 0), buddy2.alloc(8).?);
    try testing.expectEqual(@as(usize, 8), buddy2.size(0));
    try testing.expectEqual(@as(usize, 8), buddy2.alloc(8).?);
    try testing.expectEqual(@as(usize, 8), buddy2.size(8));
    try testing.expect(buddy2.alloc(8) == null);
    buddy2.free(8);
    try testing.expectEqual(@as(usize, 8), buddy2.alloc(4).?);
    try testing.expectEqual(@as(usize, 4), buddy2.size(8));
    try testing.expectEqual(@as(usize, 12), buddy2.alloc(4).?);
    try testing.expectEqual(@as(usize, 4), buddy2.size(12));
    buddy2.free(12);
    try testing.expectEqual(@as(usize, 12), buddy2.alloc(3).?);
    try testing.expectEqual(@as(usize, 4), buddy2.size(12));
    buddy2.free(12);
    try testing.expectEqual(@as(usize, 12), buddy2.alloc(2).?);
    try testing.expectEqual(@as(usize, 2), buddy2.size(12));
    try testing.expectEqual(@as(usize, 14), buddy2.alloc(2).?);
    try testing.expectEqual(@as(usize, 2), buddy2.size(14));
    buddy2.free(12);
    buddy2.free(14);
    buddy2.free(0);
    buddy2.free(8);
    try testing.expectEqual(@as(usize, 0), buddy2.alloc(16).?);
    try testing.expectEqual(@as(usize, 16), buddy2.size(0));
    try testing.expect(buddy2.alloc(1) == null);
    buddy2.free(0);

    // Allocate small blocks first.
    try testing.expectEqual(@as(usize, 0), buddy2.alloc(8).?);
    try testing.expectEqual(@as(usize, 8), buddy2.alloc(4).?);
    buddy2.free(0);
    try testing.expectEqual(@as(usize, 12), buddy2.alloc(4).?);
    try testing.expectEqual(@as(usize, 0), buddy2.alloc(8).?);
}
