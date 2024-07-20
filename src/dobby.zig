const std = @import("std");
const abi = @import("abi.zig");
const ptrace = @import("ptrace.zig");
const config = @import("config.zig");
const LineTable = @import("LineTable.zig");
const Breakpoint = @import("Breakpoint.zig");

const HELP =
    \\  b <str>:<uint> - toggle breakpoint in file <str> at line <uint>
    \\  TODO: w <str> - toggle watchpoint at variable <str>
    \\  TODO: l - list breakpoints, watchpoints, threads
    \\  TODO: t <uint> - switch to thread <uint>
    \\  a - assembly-level single step
    \\  TODO: s - source-level single step
    \\  TODO: p - print variables
    \\  d - dump registers
    \\  TODO: v - step over
    \\  o - step out
    \\  c - continue
    \\  r - restart
    \\  h - help
    \\  q - quit
    \\
;

pub fn debug(allocator: std.mem.Allocator, reader: anytype, writer: anytype, elf_file_path: []const u8) !void {
    // Trace debuggee
    var pid = try ptrace.traceDebuggee(elf_file_path);

    // Read user program's DWARF information
    var sections: std.dwarf.DwarfInfo.SectionArray = std.dwarf.DwarfInfo.null_section_array;
    var debug_info = try std.debug.readElfDebugInfo(allocator, elf_file_path, null, null, &sections, null);
    const dwarf_info = &debug_info.dwarf;
    defer debug_info.deinit(allocator);

    // Initialize breakpoints hash map
    var bps = std.AutoHashMapUnmanaged(usize, Breakpoint){};
    try bps.ensureTotalCapacity(allocator, config.MAX_NUM_BPS);
    defer bps.deinit(allocator);

    // Display help
    try writer.writeAll(HELP);

    // Prompt user for input
    try writer.writeAll("<dobby> ");

    // Handle user commands
    var line_buf: [config.MAX_LINE_LEN]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(line_buf[0..], '\n')) |line| {
        switch (line[0]) {
            'b' => {
                const bp_loc: Breakpoint.Location = blk: {
                    var line_iter = std.mem.tokenizeScalar(u8, line[2..], ' ');
                    const file_path = line_iter.next().?;
                    if (file_path.len > config.MAX_LINE_LEN) {
                        return error.FileNameTooLong;
                    }
                    var file_path_buf: [config.MAX_LINE_LEN]u8 = undefined;
                    @memcpy(file_path_buf[0..], file_path);
                    const line_num = try std.fmt.parseUnsigned(u8, line_iter.next().?, 10);
                    break :blk .{
                        .file_path_buf = file_path_buf,
                        .file_path_len = @truncate(file_path.len),
                        .line_num = line_num,
                    };
                };
                const bp_addr = try LineTable.getLineAddress(dwarf_info, allocator, bp_loc);

                if (bps.fetchRemove(bp_addr)) |kv| {
                    var bp = kv.value;
                    try bp.unset();
                } else {
                    bps.putAssumeCapacity(
                        try ptrace.readRegister(pid, abi.PC),
                        try Breakpoint.initLocation(pid, bp_addr, bp_loc),
                    );
                }
            },
            'w' => @panic("TODO"),
            'l' => {
                var bps_iter = bps.valueIterator();
                while (bps_iter.next()) |bp| {
                    try writer.print("{}\n", .{bp.loc.?});
                }
                //TODO: Add watchpoints
                //TODO: Add threads
            },
            't' => @panic("TODO"),
            'a' => {
                const pc = try ptrace.readRegister(pid, abi.PC);
                if (bps.getPtr(pc)) |bp| {
                    try bp.reset();
                } else {
                    try ptrace.singleStep(pid);
                }
                try LineTable.printSource(dwarf_info, allocator, writer, pc);
            },
            's' => @panic("TODO"),
            'p' => @panic("TODO"),
            'd' => {
                inline for (comptime std.enums.values(abi.Register)) |reg| {
                    try writer.print("{} = {}", .{ reg, try ptrace.readRegister(pid, reg) });
                }
            },
            'v' => @panic("TODO"),
            'o' => {
                const fp = try ptrace.readRegister(pid, .rbp);
                var ret_addr: usize = undefined;
                try ptrace.readMemory(pid, fp + @sizeOf(usize), &ret_addr);

                var some_bp: Breakpoint = undefined;
                var is_temp_bp = false;
                if (bps.get(ret_addr)) |bp| {
                    some_bp = bp;
                } else {
                    some_bp = try Breakpoint.init(pid, ret_addr);
                    is_temp_bp = true;
                }

                try some_bp.reset();
                const pc = try ptrace.continueExecution(pid);
                try LineTable.printSource(dwarf_info, allocator, writer, pc);

                if (is_temp_bp) {
                    try some_bp.unset();
                }
            },
            'c' => {
                if (bps.getPtr(try ptrace.readRegister(pid, abi.PC))) |bp| {
                    if (bp.is_set) {
                        try bp.reset();
                    }
                }
                const pc = try ptrace.continueExecution(pid);
                try LineTable.printSource(dwarf_info, allocator, writer, pc);
            },
            'r' => {
                try std.posix.kill(pid, std.posix.SIG.KILL);
                pid = try ptrace.traceDebuggee(elf_file_path);

                var bps_iter = bps.valueIterator();
                while (bps_iter.next()) |bp| {
                    bp.pid = pid;
                }
            },
            'h' => try writer.writeAll(HELP),
            'q' => break,
            else => |command| try writer.print("Unknown command: '{c}'\n", .{command}),
        }

        try writer.writeAll("<dobby> ");
    }
}
