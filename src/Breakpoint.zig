const std = @import("std");
const abi = @import("abi.zig");
const config = @import("config.zig");
const ptrace = @import("ptrace.zig");

const Breakpoint = @This();

pub const Location = struct {
    file_path_buf: [config.MAX_LINE_LEN]u8,
    file_path_len: u8,
    line_num: u32,
};

saved_inst: abi.trap_inst_width_t = undefined,
loc: ?Location = null,
is_set: bool = false,
pid: std.posix.pid_t,
addr: usize,

pub fn init(pid: std.posix.pid_t, addr: usize) !Breakpoint {
    var bp = Breakpoint{ .pid = pid, .addr = addr };
    try bp.set();
    return bp;
}

pub fn initLocation(pid: std.posix.pid_t, addr: usize, loc: Location) !Breakpoint {
    var bp = Breakpoint{ .pid = pid, .addr = addr, .loc = loc };
    try bp.set();
    return bp;
}

pub fn set(self: *Breakpoint) !void {
    var inst: usize = undefined;
    try ptrace.readAddress(self.pid, self.addr, &inst);
    try ptrace.writeAddress(self.pid, self.addr, (inst & abi.TRAP_INST_MASK) | abi.TRAP_INST);
    self.saved_inst = @truncate(inst);
    self.is_set = true;
}

pub fn unset(self: *Breakpoint) !void {
    var inst: usize = undefined;
    try ptrace.readAddress(self.pid, self.addr, &inst);
    try ptrace.writeAddress(self.pid, self.addr, (inst & abi.TRAP_INST_MASK) | self.saved_inst);
    self.saved_inst = undefined;
    self.is_set = false;
}

pub fn reset(self: *Breakpoint) !void {
    try self.unset();
    try ptrace.singleStep(self.pid);
    try self.set();
}
