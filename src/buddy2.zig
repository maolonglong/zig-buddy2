const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const isPowerOfTwo = math.isPowerOfTwo;
const testing = std.testing;
const Allocator = mem.Allocator;

pub const Buddy2Allocator = struct {
    const Self = @This();

    manager: *Buddy2,
    heap: []u8,

    pub fn init(heap: []u8) Self {
        var ctx_len = heap.len / 3 * 2;
        if (!isPowerOfTwo(ctx_len)) {
            ctx_len = fixLen(ctx_len) >> 1;
        }
        return Self{
            .manager = Buddy2.init(heap[0..ctx_len]),
            .heap = heap[ctx_len..],
        };
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
        return self.alignedAlloc(len, log2_ptr_align);
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
        return @ptrFromInt(@intFromPtr(self.heap.ptr) + offset);
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_old_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = log2_old_align;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return new_len <= self.alignedAllocSize(buf.ptr);
    }

    fn alignedAllocSize(self: *Self, ptr: [*]u8) usize {
        const aligned_offset = @intFromPtr(ptr) - @intFromPtr(self.heap.ptr);
        const index = self.manager.backward(aligned_offset);

        const unaligned_offset = self.manager.indexToOffset(index);
        const unaligned_size = self.manager.indexToSize(index);

        return unaligned_size - (aligned_offset - unaligned_offset);
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_old_align: u8, ret_addr: usize) void {
        _ = log2_old_align;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.alignedFree(buf.ptr);
    }

    fn alignedFree(self: *Self, ptr: [*]u8) void {
        self.manager.free(@intFromPtr(ptr) - @intFromPtr(self.heap.ptr));
    }
};

pub const Buddy2 = struct {
    const Self = @This();

    len: usize,
    _longest: [1]u8,

    pub fn init(ctx: []u8) *Self {
        const len = ctx.len / 2;
        assert(isPowerOfTwo(len));

        const self: *Self = @ptrCast(@alignCast(ctx));
        self.len = len;
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

        if (self.longest(index) < new_len) {
            return null;
        }

        var node_size = self.len;
        while (node_size != new_len) : (node_size /= 2) {
            if (self.longest(left(index)) >= new_len) {
                index = left(index);
            } else {
                index = right(index);
            }
        }

        self.setLongest(index, 0);
        // const offset = self.indexToOffset(index);
        const offset = (index + 1) * node_size - self.len;

        while (index != 0) {
            index = parent(index);
            self.setLongest(index, @max(self.longest(left(index)), self.longest(right(index))));
        }

        return offset;
    }

    pub fn free(self: *Self, offset: usize) void {
        assert(offset >= 0 and offset < self.len);

        var node_size: usize = 1;
        var index = offset + self.len - 1;

        while (self.longest(index) != 0) : (index = parent(index)) {
            node_size *= 2;
            if (index == 0) {
                return;
            }
        }
        self.setLongest(index, node_size);

        while (index != 0) {
            index = parent(index);
            node_size *= 2;

            const left_longest = self.longest(left(index));
            const right_longest = self.longest(right(index));

            if (left_longest + right_longest == node_size) {
                self.setLongest(index, node_size);
            } else {
                self.setLongest(index, @max(left_longest, right_longest));
            }
        }
    }

    pub fn size(self: *const Self, offset: usize) usize {
        assert(offset >= 0 and offset < self.len);
        return self.indexToSize(self.backward(offset));
    }

    fn backward(self: *const Self, offset: usize) usize {
        assert(offset >= 0 and offset < self.len);

        var index = offset + self.len - 1;
        while (self.longest(index) != 0) {
            index = parent(index);
        }

        return index;
    }

    fn indexToSize(self: *const Self, index: usize) usize {
        return self.len >> math.log2_int(usize, index + 1);
    }

    fn indexToOffset(self: *const Self, index: usize) usize {
        // return (index + 1) * node_size - self.len;
        return (index + 1) * self.indexToSize(index) - self.len;
    }

    fn longest(self: *const Self, index: usize) usize {
        const ptr: [*]const u8 = @ptrCast(&self._longest);
        const node_size = ptr[index];
        // if (node_size == 0) {
        //     return 0;
        // }
        // return @as(usize, 1) << @truncate(node_size - 1);
        return (@as(usize, 1) << @as(math.Log2Int(usize), @intCast(node_size))) >> 1;
    }

    fn setLongest(self: *Self, index: usize, node_size: usize) void {
        const ptr: [*]u8 = @ptrCast(&self._longest);
        // if (node_size == 0) {
        //     ptr[index] = 0;
        //     return;
        // }
        // ptr[index] = math.log2_int(usize, node_size) + 1;
        ptr[index] = math.log2_int(usize, (node_size << 1) | 1);
    }

    fn left(index: usize) usize {
        return index * 2 + 1;
    }

    fn right(index: usize) usize {
        return index * 2 + 2;
    }

    fn parent(index: usize) usize {
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

    var buddy2 = Buddy2Allocator.init(S.heap[0..]);
    var allocator = buddy2.allocator();

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
}
