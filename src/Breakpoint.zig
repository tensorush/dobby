const std = @import("std");
const builtin = @import("builtin");

const Breakpoint = @This();

saved_inst: u8 = undefined,
is_set: bool = false,
pid: std.posix.pid_t,
address: usize,

pub fn init(pid: std.posix.pid_t, address: usize) !Breakpoint {
    var breakpoint = Breakpoint{ .pid = pid, .address = address };
    try breakpoint.set();
    return breakpoint;
}

pub fn set(self: *Breakpoint) !void {
    // Read instruction at breakpoint address
    var inst: usize = undefined;
    try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, self.address, @intFromPtr(&inst));

    // Write software breakpoint instruction at breakpoint address
    switch (builtin.cpu.arch) {
        // "int3" (0xCC)
        .x86_64 => try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, self.address, (inst & 0xFFFF_FFFF_FFFF_FF00) | 0xCC),
        // "brk #0" (0xD420_0000)
        .aarch64 => try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, self.address, (inst & 0xFFFF_FFFF_0000_0000) | 0xD420_0000),
        else => unreachable,
    }

    // Save read instruction
    self.saved_inst = @truncate(inst);

    // Set breakpoint
    self.is_set = true;
}

pub fn unset(self: *Breakpoint) !void {
    // Read instruction at breakpoint address
    var inst: usize = undefined;
    try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, self.address, @intFromPtr(&inst));

    // Restore saved instruction at breakpoint address
    try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, self.address, (inst & 0xFFFF_FFFF_FFFF_FF00) | self.saved_inst);

    // Unset breakpoint
    self.is_set = false;
}

pub fn reset(self: *Breakpoint) !void {
    // Unset breakpoint
    try self.unset();

    // Trap debuggee after single step
    try std.posix.ptrace(std.os.linux.PTRACE.SINGLESTEP, self.pid, 0, 0);

    // Wait for debuggee to be trapped after single step
    std.debug.assert((std.posix.waitpid(self.pid, 0).status & 0xFF00) >> 8 == std.posix.SIG.TRAP);

    // Set breakpoint again
    try self.set();
}
