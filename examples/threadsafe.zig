const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Buddy2Allocator = @import("buddy2").Buddy2Allocator;

const heap_size = 1024 * 1024;
var heap: [heap_size]u8 = undefined;

fn job(allocator: Allocator) !void {
    var a = std.ArrayList(usize).init(allocator);
    defer a.deinit();
    for (0..1000) |i| {
        try a.append(i);
    }
    std.debug.print("[{}] len: {}\n", .{ std.Thread.getCurrentId(), a.items.len });
}

pub fn main() !void {
    var buddy2 = Buddy2Allocator(.{ .verbose_log = true }).init(heap[0..]);
    defer assert(buddy2.deinit() == .ok);
    var allocator = buddy2.allocator();
    var wrap = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    var threadSafeAllocator = wrap.allocator();

    // job1
    const thread = try std.Thread.spawn(.{}, job, .{threadSafeAllocator});
    // job2
    try job(threadSafeAllocator);
    thread.join();
}
