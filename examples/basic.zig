const std = @import("std");

pub fn main() void {
    var a: u8 = 1;
    a += 1;
    std.debug.print("{d}: All your codebase are belong to us.\n", .{a});
}
