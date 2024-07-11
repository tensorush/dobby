const std = @import("std");
const system = @import("system.zig");
const LineTable = @import("LineTable.zig");
const Breakpoint = @import("Breakpoint.zig");

const HELP =
    \\b <str> <int> - toggle breakpoint in file <str> at line <int>
    \\l - list breakpoints
    \\p - print variables
    \\s - single step
    \\c - continue
    \\r - restart
    \\h - help
    \\q - quit
    \\
;

pub fn debug(allocator: std.mem.Allocator, reader: anytype, writer: anytype, exe_file_path: []const u8) !void {
    _ = reader;
    // Spawn debuggee
    const pid = try std.posix.fork();

    // Branch into debuggee
    if (pid == 0) {
        // Trace debuggee
        try std.posix.ptrace(std.os.linux.PTRACE.TRACEME, pid, 0, 0);

        // Execute user program
        const posix_exe_file_path = try std.posix.toPosixPath(exe_file_path);
        std.posix.execveZ(&posix_exe_file_path, @ptrCast(std.os.argv.ptr), @ptrCast(std.os.environ.ptr)) catch unreachable;
    }

    // Wait for debuggee to be trapped
    std.debug.assert((std.posix.waitpid(pid, 0).status & 0xFF00) >> 8 == std.posix.SIG.TRAP);

    // Kill debuggee when debugger exits
    try std.posix.ptrace(std.os.linux.PTRACE.SETOPTIONS, pid, 0, 0x0010_0000);

    // Initialize user program's DWARF information
    var sections: std.dwarf.DwarfInfo.SectionArray = std.dwarf.DwarfInfo.null_section_array;
    var debug_info = try std.debug.readElfDebugInfo(allocator, exe_file_path, null, null, &sections, null);
    const dwarf_info = &debug_info.dwarf;
    defer debug_info.deinit(allocator);

    // Print help
    try writer.writeAll(HELP);
    try writer.writeAll("> \n");

    // TODO: Handle user commands
    // while (true) {
    //     var input_buf: [1024]u8 = undefined;
    //     var input_buf_stream = std.io.fixedBufferStream(input_buf[0..]);
    //     try reader.streamUntilDelimiter(input_buf_stream.writer(), '\n', input_buf.len);
    //     const input = input_buf_stream.getWritten();

    //     switch (input[0]) {
    //         'b' => try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0),
    //         'l' => try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0),
    //         'p' => try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0),
    //         's' => try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0),
    //         'c' => try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0),
    //         'r' => try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0),
    //         'h' => try writer.writeAll(HELP),
    //         'q' => break,
    //         else => |command| try writer.print("Unknown command: '{}'\n", .{command}),
    //     }

    //     try writer.writeAll("> \n");
    // }

    // Specify breakpoint's source line information
    const line_info = LineTable.LineInfo{ .line = 8, .file_name = "/Users/jora/Repos/lnxs/dbg/examples/basic.zig" };
    const line_addr = try LineTable.getLineAddress(dwarf_info, allocator, line_info);

    // Set breakpoint
    var breakpoint = try Breakpoint.init(pid, line_addr);

    // Continue debuggee execution
    try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0);

    // Wait for debuggee to be trapped at breakpoint address
    std.debug.assert((std.posix.waitpid(pid, 0).status & 0xFF00) >> 8 == std.posix.SIG.TRAP);

    // Restore program counter
    const pc = try system.getRegisterValue(pid, system.PC_REGISTER) - 1;
    try system.setRegisterValue(pid, system.PC_REGISTER, pc);

    // TODO: Print variables
    const compile_unit = try dwarf_info.findCompileUnit(pc);
    for (dwarf_info.func_list.items) |func| {
        if (func.pc_range) |pc_range| {
            if (pc >= pc_range.start and pc < pc_range.end) {
                var line_num_info = try dwarf_info.getLineNumberInfo(allocator, compile_unit.*, pc_range.start);
                defer line_num_info.deinit(allocator);
                try writer.print("{d}, {d}\n", .{ line_num_info.line, line_num_info.column });
            }
        }
    }

    // Reset breakpoint
    try breakpoint.reset();

    // Continue debuggee execution
    try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0);
}
