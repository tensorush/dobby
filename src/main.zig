const std = @import("std");
const clap = @import("clap");
const dobby = @import("dobby.zig");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help   Display help menu.
    \\<str>        ELF file path.
    \\
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Memory leak has occurred!");
    };

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const std_in = std.io.getStdIn();
    const reader = std_in.reader();

    const std_out = std.io.getStdOut();
    var buf_writer = std.io.bufferedWriter(std_out.writer());
    const writer = buf_writer.writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &PARAMS, clap.parsers.default, .{ .allocator = allocator, .diagnostic = &diag }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    var elf_file_path: []const u8 = "zig-out/bin/example";

    if (res.positionals.len > 0) {
        elf_file_path = res.positionals[0];
    }

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &PARAMS, .{});
    }

    try dobby.debug(allocator, reader, writer, elf_file_path);

    try buf_writer.flush();
}
