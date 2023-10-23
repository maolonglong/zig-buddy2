const std = @import("std");
const assert = std.debug.assert;
const Buddy2Allocator = @import("buddy2").Buddy2Allocator;

const heap_size = 1024 * 1024;
var heap: [heap_size]u8 = undefined;

pub fn main() !void {
    var buddy2 = Buddy2Allocator(.{ .verbose_log = true }).init(heap[0..]);
    defer assert(buddy2.deinit() == .ok);
    var allocator = buddy2.allocator();

    var a = std.ArrayList(usize).init(allocator);
    defer a.deinit();
    for (0..42) |i| {
        try a.append(i);
    }
    std.debug.print("len: {}\n", .{a.items.len});
}
