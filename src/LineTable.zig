const std = @import("std");
const config = @import("config.zig");
const Breakpoint = @import("Breakpoint.zig");

pub fn printSource(self: *std.dwarf.DwarfInfo, allocator: std.mem.Allocator, writer: anytype, pc: usize) !void {
    const compile_unit = try self.findCompileUnit(pc);
    const bp_line_info = try self.getLineNumberInfo(allocator, compile_unit.*, pc);
    defer bp_line_info.deinit(allocator);

    var file = try std.fs.cwd().openFile(bp_line_info.file_name, .{});
    const reader = file.reader();
    defer file.close();

    var cur_line_buf: [config.MAX_LINE_LEN]u8 = undefined;
    var cur_line_stream = std.io.fixedBufferStream(cur_line_buf[0..]);
    var cur_line: u32 = 1;
    while (cur_line < bp_line_info.line - 1) : (cur_line += 1) {
        try reader.streamUntilDelimiter(cur_line_stream.writer(), '\n', config.MAX_LINE_LEN);
        cur_line_stream.reset();
    }

    for (bp_line_info.line - 1..bp_line_info.line + 2) |line| {
        try reader.streamUntilDelimiter(cur_line_stream.writer(), '\n', config.MAX_LINE_LEN);
        try writer.print("{} {s}\n", .{ line, cur_line_stream.getWritten() });
        cur_line_stream.reset();
    }
}

pub fn getLineAddress(
    dwarf_info: *std.dwarf.DwarfInfo,
    allocator: std.mem.Allocator,
    bp_loc: Breakpoint.Location,
) !usize {
    const compile_unit = dwarf_info.compile_unit_list.items[0];
    const compile_unit_cwd = try compile_unit.die.getAttrString(dwarf_info, std.dwarf.AT.comp_dir, dwarf_info.section(.debug_line_str), compile_unit);
    const line_info_offset = try compile_unit.die.getAttrSecOffset(std.dwarf.AT.stmt_list);

    var fbr = std.dwarf.FixedBufferReader{ .buf = dwarf_info.section(.debug_line).?, .endian = dwarf_info.endian };
    try fbr.seekTo(line_info_offset);

    const unit_header = try std.dwarf.readUnitHeader(&fbr, null);
    if (unit_header.unit_length == 0) return std.dwarf.missingDwarf();
    const next_offset = unit_header.header_length + unit_header.unit_length;

    const version = try fbr.readInt(u16);
    if (version < 2) return std.dwarf.badDwarf();

    var addr_size: u8 = switch (unit_header.format) {
        .@"32" => 4,
        .@"64" => 8,
    };
    var seg_size: u8 = 0;
    if (version >= 5) {
        addr_size = try fbr.readByte();
        seg_size = try fbr.readByte();
    }

    const prologue_length = try fbr.readAddress(unit_header.format);
    const prog_start_offset = fbr.pos + prologue_length;

    const minimum_instruction_length = try fbr.readByte();
    if (minimum_instruction_length == 0) return std.dwarf.badDwarf();

    if (version >= 4) {
        _ = try fbr.readByte();
    }

    const default_is_stmt = (try fbr.readByte()) != 0;
    const line_base = try fbr.readByteSigned();

    const line_range = try fbr.readByte();
    if (line_range == 0) return std.dwarf.badDwarf();

    const opcode_base = try fbr.readByte();

    const standard_opcode_lengths = try fbr.readBytes(opcode_base - 1);

    var include_directories = std.ArrayList(std.dwarf.FileEntry).init(allocator);
    defer include_directories.deinit();
    var file_entries = std.ArrayList(std.dwarf.FileEntry).init(allocator);
    defer file_entries.deinit();

    if (version < 5) {
        try include_directories.append(.{ .path = compile_unit_cwd });

        while (true) {
            const dir = try fbr.readBytesTo(0);
            if (dir.len == 0) break;
            try include_directories.append(.{ .path = dir });
        }

        while (true) {
            const file_name = try fbr.readBytesTo(0);
            if (file_name.len == 0) break;
            const dir_index = try fbr.readUleb128(u32);
            const mtime = try fbr.readUleb128(u64);
            const size = try fbr.readUleb128(u64);
            try file_entries.append(.{
                .path = file_name,
                .dir_index = dir_index,
                .mtime = mtime,
                .size = size,
            });
        }
    } else {
        const FileEntFmt = struct {
            content_type_code: u8,
            form_code: u16,
        };
        {
            var dir_ent_fmt_buf: [10]FileEntFmt = undefined;
            const directory_entry_format_count = try fbr.readByte();
            if (directory_entry_format_count > dir_ent_fmt_buf.len) return std.dwarf.badDwarf();
            for (dir_ent_fmt_buf[0..directory_entry_format_count]) |*ent_fmt| {
                ent_fmt.* = .{
                    .content_type_code = try fbr.readUleb128(u8),
                    .form_code = try fbr.readUleb128(u16),
                };
            }

            const directories_count = try fbr.readUleb128(usize);
            try include_directories.ensureUnusedCapacity(directories_count);
            {
                var i: usize = 0;
                while (i < directories_count) : (i += 1) {
                    var e = std.dwarf.FileEntry{ .path = &.{} };
                    for (dir_ent_fmt_buf[0..directory_entry_format_count]) |ent_fmt| {
                        const form_value = try std.dwarf.parseFormValue(
                            &fbr,
                            ent_fmt.form_code,
                            unit_header.format,
                            null,
                        );
                        switch (ent_fmt.content_type_code) {
                            std.dwarf.LNCT.path => e.path = try form_value.getString(dwarf_info.*),
                            std.dwarf.LNCT.directory_index => e.dir_index = try form_value.getUInt(u32),
                            std.dwarf.LNCT.timestamp => e.mtime = try form_value.getUInt(u64),
                            std.dwarf.LNCT.size => e.size = try form_value.getUInt(u64),
                            std.dwarf.LNCT.MD5 => e.md5 = switch (form_value) {
                                .data16 => |data16| data16.*,
                                else => return std.dwarf.badDwarf(),
                            },
                            else => continue,
                        }
                    }
                    include_directories.appendAssumeCapacity(e);
                }
            }
        }

        var file_ent_fmt_buf: [10]FileEntFmt = undefined;
        const file_name_entry_format_count = try fbr.readByte();
        if (file_name_entry_format_count > file_ent_fmt_buf.len) return std.dwarf.badDwarf();
        for (file_ent_fmt_buf[0..file_name_entry_format_count]) |*ent_fmt| {
            ent_fmt.* = .{
                .content_type_code = try fbr.readUleb128(u8),
                .form_code = try fbr.readUleb128(u16),
            };
        }

        const file_names_count = try fbr.readUleb128(usize);
        try file_entries.ensureUnusedCapacity(file_names_count);
        {
            var i: usize = 0;
            while (i < file_names_count) : (i += 1) {
                var e = std.dwarf.FileEntry{ .path = &.{} };
                for (file_ent_fmt_buf[0..file_name_entry_format_count]) |ent_fmt| {
                    const form_value = try std.dwarf.parseFormValue(
                        &fbr,
                        ent_fmt.form_code,
                        unit_header.format,
                        null,
                    );
                    switch (ent_fmt.content_type_code) {
                        std.dwarf.LNCT.path => e.path = try form_value.getString(dwarf_info.*),
                        std.dwarf.LNCT.directory_index => e.dir_index = try form_value.getUInt(u32),
                        std.dwarf.LNCT.timestamp => e.mtime = try form_value.getUInt(u64),
                        std.dwarf.LNCT.size => e.size = try form_value.getUInt(u64),
                        std.dwarf.LNCT.MD5 => e.md5 = switch (form_value) {
                            .data16 => |data16| data16.*,
                            else => return std.dwarf.badDwarf(),
                        },
                        else => continue,
                    }
                }
                file_entries.appendAssumeCapacity(e);
            }
        }
    }

    var prog = std.dwarf.LineNumberProgram.init(
        default_is_stmt,
        include_directories.items,
        undefined,
        version,
    );

    try fbr.seekTo(prog_start_offset);

    const next_unit_pos = line_info_offset + next_offset;

    while (fbr.pos < next_unit_pos) {
        const opcode = try fbr.readByte();

        if (opcode == std.dwarf.LNS.extended_op) {
            const op_size = try fbr.readUleb128(u64);
            if (op_size < 1) return std.dwarf.badDwarf();
            const sub_op = try fbr.readByte();
            switch (sub_op) {
                std.dwarf.LNE.end_sequence => {
                    prog.end_sequence = true;
                    if (try checkLineMatch(&prog, allocator, file_entries.items, bp_loc)) |address| return address;
                    prog.reset();
                },
                std.dwarf.LNE.set_address => {
                    const addr = try fbr.readInt(usize);
                    prog.address = addr;
                },
                std.dwarf.LNE.define_file => {
                    const path = try fbr.readBytesTo(0);
                    const dir_index = try fbr.readUleb128(u32);
                    const mtime = try fbr.readUleb128(u64);
                    const size = try fbr.readUleb128(u64);
                    try file_entries.append(.{
                        .path = path,
                        .dir_index = dir_index,
                        .mtime = mtime,
                        .size = size,
                    });
                },
                else => try fbr.seekForward(op_size - 1),
            }
        } else if (opcode >= opcode_base) {
            const adjusted_opcode = opcode - opcode_base;
            const inc_addr = minimum_instruction_length * (adjusted_opcode / line_range);
            const inc_line = @as(i32, line_base) + @as(i32, adjusted_opcode % line_range);
            prog.line += inc_line;
            prog.address += inc_addr;
            if (try checkLineMatch(&prog, allocator, file_entries.items, bp_loc)) |address| return address;
            prog.basic_block = false;
        } else {
            switch (opcode) {
                std.dwarf.LNS.copy => {
                    if (try checkLineMatch(&prog, allocator, file_entries.items, bp_loc)) |address| return address;
                    prog.basic_block = false;
                },
                std.dwarf.LNS.advance_pc => {
                    const arg = try fbr.readUleb128(usize);
                    prog.address += arg * minimum_instruction_length;
                },
                std.dwarf.LNS.advance_line => {
                    const arg = try fbr.readIleb128(i64);
                    prog.line += arg;
                },
                std.dwarf.LNS.set_file => {
                    const arg = try fbr.readUleb128(usize);
                    prog.file = arg;
                },
                std.dwarf.LNS.set_column => {
                    const arg = try fbr.readUleb128(u64);
                    prog.column = arg;
                },
                std.dwarf.LNS.negate_stmt => {
                    prog.is_stmt = !prog.is_stmt;
                },
                std.dwarf.LNS.set_basic_block => {
                    prog.basic_block = true;
                },
                std.dwarf.LNS.const_add_pc => {
                    const inc_addr = minimum_instruction_length * ((255 - opcode_base) / line_range);
                    prog.address += inc_addr;
                },
                std.dwarf.LNS.fixed_advance_pc => {
                    const arg = try fbr.readInt(u16);
                    prog.address += arg;
                },
                std.dwarf.LNS.set_prologue_end => {},
                else => {
                    if (opcode - 1 >= standard_opcode_lengths.len) return std.dwarf.badDwarf();
                    try fbr.seekForward(standard_opcode_lengths[opcode - 1]);
                },
            }
        }
    }

    return std.dwarf.missingDwarf();
}

fn checkLineMatch(
    prog: *std.dwarf.LineNumberProgram,
    allocator: std.mem.Allocator,
    file_entries: []const std.dwarf.FileEntry,
    bp_loc: Breakpoint.Location,
) !?usize {
    if (prog.prev_valid and
        bp_loc.line == prog.prev_line)
    {
        const file_index = if (prog.version >= 5) prog.prev_file else i: {
            if (prog.prev_file == 0) return std.dwarf.missingDwarf();
            break :i prog.prev_file - 1;
        };

        if (file_index >= file_entries.len) return std.dwarf.badDwarf();
        const file_entry = &file_entries[file_index];

        if (file_entry.dir_index >= prog.include_dirs.len) return std.dwarf.badDwarf();
        const dir_name = prog.include_dirs[file_entry.dir_index].path;

        const file_name = try std.fs.path.join(allocator, &.{ dir_name, file_entry.path });

        if (std.mem.eql(u8, file_name, bp_loc.file_path_buf[0..bp_loc.file_path_len])) {
            return prog.prev_address;
        }
    }

    prog.prev_valid = true;
    prog.prev_address = prog.address;
    prog.prev_file = prog.file;
    prog.prev_line = prog.line;
    prog.prev_column = prog.column;
    prog.prev_is_stmt = prog.is_stmt;
    prog.prev_basic_block = prog.basic_block;
    prog.prev_end_sequence = prog.end_sequence;

    return null;
}
