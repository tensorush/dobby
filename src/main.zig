const std = @import("std");
const clap = @import("clap");
const dobby = @import("dobby.zig");

const PARAMS = clap.parseParamsComptime(
    \\-a, --args <str>   Debuggee CLI arguments.
    \\-h, --help         Display help.
    \\<str>              Debugee ELF file path.
    \\
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Memory leak has occurred!");
    };

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    const allocator = arena.allocator();
    defer arena.deinit();

    const std_in = std.io.getStdIn();
    const reader = std_in.reader();

    const std_out = std.io.getStdOut();
    const writer = std_out.writer();

    var res = try clap.parse(clap.Help, &PARAMS, clap.parsers.default, .{ .allocator = allocator });
    defer res.deinit();

    var elf_file_path: []const u8 = "zig-out/bin/basic";

    if (res.positionals.len > 0) {
        elf_file_path = res.positionals[0];
    }

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &PARAMS, .{});
    }

    try dobby.debug(allocator, reader, writer, elf_file_path);
}
