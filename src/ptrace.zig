const std = @import("std");
const abi = @import("abi.zig");

const c = @cImport({
    @cInclude("sys/user.h");
    @cInclude("sys/personality.h");
});

pub fn traceDebuggee(elf_file_path: []const u8) !std.posix.pid_t {
    const pid = try std.posix.fork();
    if (pid == 0) {
        _ = c.personality(c.ADDR_NO_RANDOMIZE);
        try std.posix.ptrace(std.os.linux.PTRACE.TRACEME, pid, 0, 0);
        const posix_exe_file_path = try std.posix.toPosixPath(elf_file_path);
        std.posix.execveZ(
            &posix_exe_file_path,
            @ptrCast(std.os.argv.ptr),
            @ptrCast(std.os.environ.ptr),
        ) catch @panic("Failed to execute debuggee!");
    }
    waitForTrapSignal(pid);
    try killOnExit(pid);
    return pid;
}

pub fn continueExecution(pid: std.posix.pid_t) !usize {
    try std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0);
    waitForTrapSignal(pid);
    return try restorePc(pid);
}

pub fn singleStep(pid: std.posix.pid_t) !void {
    try std.posix.ptrace(std.os.linux.PTRACE.SINGLESTEP, pid, 0, 0);
    waitForTrapSignal(pid);
}

pub fn waitForTrapSignal(pid: std.posix.pid_t) void {
    std.debug.assert((std.posix.waitpid(pid, 0).status & 0xFF00) >> 8 == std.posix.SIG.TRAP);
}

pub fn killOnExit(pid: std.posix.pid_t) !void {
    try std.posix.ptrace(std.os.linux.PTRACE.SETOPTIONS, pid, 0, 0x0010_0000);
}

pub fn readAddress(pid: std.posix.pid_t, addr: usize, inst: *usize) !void {
    try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, pid, addr, @intFromPtr(inst));
}

pub fn writeAddress(pid: std.posix.pid_t, addr: usize, inst: usize) !void {
    try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, pid, addr, inst);
}

pub fn readMemory(pid: std.posix.pid_t, addr: usize, data: *usize) !void {
    try std.posix.ptrace(std.os.linux.PTRACE.PEEKDATA, pid, addr, @intFromPtr(data));
}

pub fn writeMemory(pid: std.posix.pid_t, addr: usize, data: usize) !void {
    try std.posix.ptrace(std.os.linux.PTRACE.PEEKDATA, pid, addr, data);
}

pub fn readRegister(pid: std.posix.pid_t, comptime reg: abi.Register) !usize {
    var c_regs: c.user_regs_struct = undefined;
    try std.posix.ptrace(std.os.linux.PTRACE.GETREGS, pid, 0, @intFromPtr(&c_regs));
    return @field(c_regs, @tagName(reg));
}

pub fn writeRegister(pid: std.posix.pid_t, comptime reg: abi.Register, value: usize) !void {
    var c_regs: c.user_regs_struct = undefined;
    try std.posix.ptrace(std.os.linux.PTRACE.GETREGS, pid, 0, @intFromPtr(&c_regs));
    @field(c_regs, @tagName(reg)) = value;
    try std.posix.ptrace(std.os.linux.PTRACE.SETREGS, pid, 0, @intFromPtr(&c_regs));
}

pub fn restorePc(pid: std.posix.pid_t) !usize {
    const pc = try readRegister(pid, abi.PC) - 1;
    try writeRegister(pid, abi.PC, pc);
    return pc;
}
