const std = @import("std");
const builtin = @import("builtin");

pub const PC: Register = switch (builtin.cpu.arch) {
    .x86_64 => .rip,
    .aarch64 => .pc,
    else => unreachable,
};

pub const BP_INST: bp_inst_width_t = switch (builtin.cpu.arch) {
    .x86_64 => 0xCC, // "int3"
    .aarch64 => 0xD420_0000, // "brk #0"
    else => unreachable,
};

pub const BP_INST_MASK: usize = ~@as(usize, std.math.maxInt(bp_inst_width_t));

pub const bp_inst_width_t = switch (builtin.cpu.arch) {
    .x86_64 => u8,
    .aarch64 => u32,
    else => unreachable,
};

pub const Register = switch (builtin.cpu.arch) {
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
