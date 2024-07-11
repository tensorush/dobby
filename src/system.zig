const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/user.h");
});

pub const PC_REGISTER: Register = switch (builtin.cpu.arch) {
    .x86_64 => .rip,
    .aarch64 => .pc,
    else => unreachable,
};

const Register = switch (builtin.cpu.arch) {
    .x86_64 => enum {
        rax,
        rdx,
        rcx,
        rbx,
        rsi,
        rdi,
        rbp,
        rsp,
        r8,
        r9,
        r10,
        r11,
        r12,
        r13,
        r14,
        r15,
        rip,
        eflags,
        cs,
        ss,
        fs_base,
        gs_base,
        ds,
        es,
        fs,
        gs,
        orig_rax,
    },
    .aarch64 => enum {
        r0,
        r1,
        r2,
        r3,
        r4,
        r5,
        r6,
        r7,
        r8,
        r9,
        r10,
        r11,
        r12,
        r13,
        r14,
        r15,
        r16,
        r17,
        r18,
        r19,
        r20,
        r21,
        r22,
        r23,
        r24,
        r25,
        r26,
        r27,
        r28,
        fp,
        lr,
        sp,
        pc,
    },
    else => unreachable,
};

pub fn getRegisterValue(pid: std.posix.pid_t, comptime reg: Register) !u64 {
    var c_regs: c.user_regs_struct = undefined;
    try std.posix.ptrace(std.os.linux.PTRACE.GETREGS, pid, 0, @intFromPtr(&c_regs));
    return @field(c_regs, @tagName(reg));
}

pub fn setRegisterValue(pid: std.posix.pid_t, comptime reg: Register, value: u64) !void {
    var c_regs: c.user_regs_struct = undefined;
    try std.posix.ptrace(std.os.linux.PTRACE.GETREGS, pid, 0, @intFromPtr(&c_regs));
    @field(c_regs, @tagName(reg)) = value;
    try std.posix.ptrace(std.os.linux.PTRACE.SETREGS, pid, 0, @intFromPtr(&c_regs));
}
