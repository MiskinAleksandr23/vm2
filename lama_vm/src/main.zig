const std = @import("std");
const Io = std.Io;

comptime {
    if (@sizeOf(usize) != 8 or @sizeOf(isize) != 8) {
        @compileError("VM requires a 64-bit target");
    }
}

const StackSize = 1 << 10; // TODO
const Value = usize;

pub fn boxInt(n: isize) Value {
    const bits: usize = @bitCast(n);
    return (bits << 1) | 1;
}

pub inline fn unboxIntUnchecked(value: Value) isize {
    const signed: isize = @bitCast(value);
    return signed >> 1;
}

pub inline fn unboxIntChecked(value: Value) !isize {
    if ((value & 1) == 0) {
        @branchHint(.unlikely);
        return error.ExpectedInteger;
    }
    const signed: isize = @bitCast(value);
    return signed >> 1;
}

fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();
        data: [StackSize]T = undefined,
        len: usize = 0,

        pub fn init() Self {
            return Self{
                .len = 0,
                .data = undefined,
            };
        }

        pub fn head(self: *Self) !T {
            if (self.len == 0) {
                @branchHint(.unlikely);
                return error.StackUnderflow;
            }
            return self.data[self.len - 1];
        }

        pub fn push(self: *Self, element: T) !void {
            if (self.len >= StackSize) {
                @branchHint(.unlikely);
                return error.StackOverflow;
            }
            self.data[self.len] = element;
            self.len += 1;
        }
        pub fn pop(self: *Self) !T {
            if (self.len == 0) {
                @branchHint(.unlikely);
                return error.StackUnderflow;
            }
            const element = self.data[self.len - 1];
            self.len -= 1;
            return element;
        }
    };
}

const Frame = struct {
    args: []Value,
    locals: []Value,
    closure: []Value,
    stack_base: usize,
};

const SavedFrame = struct {
    return_ip: usize,
    frame: Frame,
};

const ByteCode = struct {
    code: []const u8,
    strings: []const u8,
    globals_count: usize,
};

fn markInstructionStarts(alloc: std.mem.Allocator, code: []const u8) ![]bool {
    const starts = try alloc.alloc(bool, code.len);
    errdefer alloc.free(starts);
    @memset(starts, false);

    var offset: usize = 0;
    while (offset < code.len) {
        if (code[offset] == 0xFF) {
            if (offset != code.len - 1) {
                return error.TrailingBytesAfterBytecodeTerminator;
            }
            return starts;
        }

        const size: usize = switch (code[offset]) {
            0x01...0x03, 0x06...0x0B, 0x16, 0x17, 0x18...0x1A, 0x71, 0x04, 0x05, 0x0C, 0x0D, 0x70 => 1,
            0x10, 0x15, 0x20, 0x21, 0x22, 0x40, 0x41, 0x42, 0x50, 0x51, 0x5A => 5,
            0x52, 0x56 => 9,
            else => return error.InvalidOpcode,
        };
        if (size > code.len - offset) {
            return error.TruncatedInstruction;
        }
        starts[offset] = true;
        offset += size;
    }
    return error.MissingBytecodeTerminator;
}

pub const VM = struct {
    const Self = @This();
    code: []const u8,
    instruction_starts: []const bool,
    strings: []const u8,
    ip: usize, // invariant: 0 <= ip <= code.len

    globals: []Value,
    stack: Stack(Value),

    frame: Frame,
    call_stack: Stack(SavedFrame),

    current_line: ?i32,

    alloc: std.mem.Allocator,
    io: std.Io,
    input_data: ?[]const u8 = null,
    input_pos: usize = 0,

    pub fn readInputInteger(self: *Self) !isize {
        if (self.input_data == null) {
            var reader = std.Io.File.stdin().readerStreaming(self.io, &.{});
            self.input_data = reader.interface.allocRemaining(self.alloc, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
                error.ReadFailed => return reader.err.?,
                error.StreamTooLong => return error.InputTooLarge,
                else => return err,
            };
        }
        const input = self.input_data.?;
        while (self.input_pos < input.len and std.ascii.isWhitespace(input[self.input_pos])) {
            self.input_pos += 1;
        }
        if (self.input_pos == input.len) {
            return error.UnexpectedEndOfInput;
        }

        const start = self.input_pos;
        while (self.input_pos < input.len and !std.ascii.isWhitespace(input[self.input_pos])) {
            self.input_pos += 1;
        }
        const token = input[start..self.input_pos];
        const digits = if (token[0] == '+' or token[0] == '-') token[1..] else token;
        if (digits.len == 0) {
            return error.InvalidIntegerInput;
        }
        for (digits) |digit| {
            if (!std.ascii.isDigit(digit)) {
                return error.InvalidIntegerInput;
            }
        }
        return std.fmt.parseInt(i63, token, 10) catch |err| switch (err) {
            error.InvalidCharacter => return error.InvalidIntegerInput,
            error.Overflow => return error.InputIntegerOutOfRange,
        };
    }

    pub inline fn ensureEnoughBytes(self: *Self, need: usize) !void {
        if (need > self.code.len - self.ip) {
            @branchHint(.unlikely);
            std.debug.print(
                "Not enough bytes to read: need {d}, have: {}\n",
                .{ need, self.code.len - self.ip },
            );
            return error.UnexpectedEndOfBytecode;
        }
    }
    pub fn readByte(self: *Self) !u8 {
        try self.ensureEnoughBytes(1);
        const byte = self.code[self.ip];
        self.ip += 1;
        return byte;
    }
    pub fn readI32(self: *Self) !i32 {
        try self.ensureEnoughBytes(4);
        const value = std.mem.readInt(i32, self.code[self.ip..][0..4], .little);
        self.ip += 4;
        return value;
    }

    pub inline fn CheckAddress(self: *Self, addr: usize) !void {
        if (addr >= self.code.len) {
            @branchHint(.unlikely);
            return error.JumpAddressOutOfBounds;
        }
        if (!self.instruction_starts[addr]) {
            return error.JumpTargetNotInstructionStart;
        }
    }

    pub fn stackPop(self: *Self) !Value {
        if (self.stack.len <= self.frame.stack_base) {
            return error.StackUnderflow;
        }
        return try self.stack.pop();
    }

    pub fn stackHead(self: *Self) !Value {
        if (self.stack.len <= self.frame.stack_base) {
            return error.StackUnderflow;
        }
        return try self.stack.head();
    }

    pub fn run(self: *Self) !void {
        // TODO: next() in cycle
        while (true) {
            const opcode = try self.readByte();
            switch (opcode) {
                // TODO: optimize some operations inplace
                0x01 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(left +% right));
                },
                0x02 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(left -% right));
                },
                0x03 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(left *% right));
                },

                0x04 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    if (right == 0) {
                        return error.DivisionByZero;
                    }
                    try self.stack.push(boxInt(@divTrunc(left, right)));
                },
                0x05 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    if (right == 0) {
                        return error.DivisionByZero;
                    }
                    try self.stack.push(boxInt(@rem(left, right)));
                },
                0x06 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left < right)));
                },
                0x07 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left <= right)));
                },
                0x08 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left > right)));
                },
                0x09 => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left >= right)));
                },
                0x0A => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left == right)));
                },
                0x0B => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left != right)));
                },
                0x0C => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool((left != 0) and (right != 0))));
                },
                0x0D => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool((left != 0) or (right != 0))));
                },
                0x15 => {
                    const addr = try self.readI32();
                    if (addr < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeJumpAddress;
                    }
                    const uaddr: usize = @intCast(addr);
                    try self.CheckAddress(uaddr);
                    self.ip = uaddr;
                },
                0x22 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArgumentIndex;
                    }
                    const udx: usize = @intCast(idx);
                    if (udx >= self.frame.args.len) {
                        @branchHint(.unlikely);
                        return error.ArgumentIndexOutOfBounds;
                    }
                    try self.stack.push(self.frame.args[udx]);
                },
                0x42 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArgumentIndex;
                    }
                    const udx: usize = @intCast(idx);
                    if (udx >= self.frame.args.len) {
                        @branchHint(.unlikely);
                        return error.ArgumentIndexOutOfBounds;
                    }
                    self.frame.args[udx] = try self.stackHead();
                },
                0x50 => {
                    const addr = try self.readI32();
                    if (addr < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeJumpAddress;
                    }
                    const uaddr: usize = @intCast(addr);
                    try self.CheckAddress(uaddr);
                    if (0 == try unboxIntChecked(try self.stackPop())) {
                        self.ip = uaddr;
                    }
                },
                0x51 => {
                    const addr = try self.readI32();
                    if (addr < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeJumpAddress;
                    }
                    const uaddr: usize = @intCast(addr);
                    try self.CheckAddress(uaddr);
                    if (0 != try unboxIntChecked(try self.stackPop())) {
                        self.ip = uaddr;
                    }
                },
                0x52 => {
                    const args_count = try self.readI32();
                    const locals_count = try self.readI32();

                    if (args_count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArgumentCount;
                    }
                    if (locals_count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeLocalCount;
                    }

                    const uargs_count: usize = @intCast(args_count);
                    const ulocals_count: usize = @intCast(locals_count);

                    if (self.call_stack.len == 0) {
                        self.frame.args = try self.alloc.alloc(Value, uargs_count);
                        @memset(self.frame.args, 0);
                    } else {
                        if (uargs_count != self.frame.args.len) {
                            return error.ArgumentCountMismatch;
                        }
                    }

                    self.frame.locals = try self.alloc.alloc(Value, ulocals_count);
                    @memset(self.frame.locals, 0);

                    std.debug.print("BEGIN args={d} locals={d}\n", .{
                        args_count, locals_count,
                    });
                },
                0x5A => {
                    const line = try self.readI32();
                    self.current_line = line;
                },

                0x56 => {
                    const addr = try self.readI32();
                    const args_cnt = try self.readI32();

                    if (addr < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeJumpAddress;
                    }
                    const uaddr: usize = @intCast(addr);
                    try self.CheckAddress(uaddr);

                    if (args_cnt < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArgumentCount;
                    }
                    const uargs_cnt: usize = @intCast(args_cnt);
                    if (self.code[uaddr] != 0x52) {
                        return error.CallTargetNotFunction;
                    }
                    if (self.code.len - uaddr < 9) {
                        return error.TruncatedInstruction;
                    }
                    const declared_args = std.mem.readInt(
                        i32,
                        self.code[uaddr + 1 ..][0..4],
                        .little,
                    );
                    if (declared_args < 0) {
                        return error.NegativeArgumentCount;
                    }
                    if (args_cnt != declared_args) {
                        return error.ArgumentCountMismatch;
                    }
                    if (self.stack.len < self.frame.stack_base or
                        uargs_cnt > self.stack.len - self.frame.stack_base)
                    {
                        return error.StackUnderflow;
                    }
                    if (self.call_stack.len >= self.call_stack.data.len) {
                        return error.CallStackOverflow;
                    }

                    var new_frame: Frame = undefined;
                    new_frame.args = try self.alloc.alloc(Value, uargs_cnt);
                    for (0..uargs_cnt) |idx| {
                        new_frame.args[uargs_cnt - 1 - idx] = try self.stackPop();
                    }
                    const saved = SavedFrame{ .frame = self.frame, .return_ip = self.ip };
                    try self.call_stack.push(saved);

                    new_frame.locals = &.{};
                    new_frame.closure = &.{};
                    new_frame.stack_base = self.stack.len;

                    self.frame = new_frame;
                    self.ip = uaddr;
                },
                0x10 => {
                    const element = try self.readI32();
                    try self.stack.push(boxInt(element));
                },
                0x16, 0x17 => {
                    if (self.call_stack.len == 0) {
                        return;
                    }
                    const last_frame = try self.call_stack.pop();
                    var possibleReturnValue: ?Value = null;
                    if (self.stack.len > self.frame.stack_base) {
                        possibleReturnValue = try self.stackPop();
                    }
                    self.stack.len = self.frame.stack_base;
                    self.ip = last_frame.return_ip;
                    self.frame = last_frame.frame;
                    if (possibleReturnValue) |v| {
                        try self.stack.push(v);
                    }
                },
                0x18 => {
                    _ = try self.stackPop();
                },

                0x19 => {
                    const value = try self.stackHead();
                    try self.stack.push(value);
                },
                0x1A => {
                    const right = try self.stackPop();
                    const left = try self.stackPop();

                    try self.stack.push(right);
                    try self.stack.push(left);
                },
                0x20 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeGlobalIndex;
                    }
                    const udx: usize = @intCast(idx);
                    if (udx >= self.globals.len) {
                        @branchHint(.unlikely);
                        return error.GlobalIndexOutOfBounds;
                    }
                    try self.stack.push(self.globals[udx]);
                },
                0x21 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeLocalIndex;
                    }
                    const udx: usize = @intCast(idx);
                    if (udx >= self.frame.locals.len) {
                        @branchHint(.unlikely);
                        return error.LocalIndexOutOfBounds;
                    }
                    try self.stack.push(self.frame.locals[udx]);
                },
                0x40 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeGlobalIndex;
                    }
                    const udx: usize = @intCast(idx);
                    if (udx >= self.globals.len) {
                        @branchHint(.unlikely);
                        return error.GlobalIndexOutOfBounds;
                    }
                    self.globals[udx] = try self.stackHead();
                },
                0x41 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeLocalIndex;
                    }
                    const udx: usize = @intCast(idx);
                    if (udx >= self.frame.locals.len) {
                        @branchHint(.unlikely);
                        return error.LocalIndexOutOfBounds;
                    }
                    self.frame.locals[udx] = try self.stackHead();
                },
                0x70 => {
                    try self.stack.push(boxInt(try self.readInputInteger()));
                },
                0x71 => {
                    const value = try self.stackPop();
                    if ((value & 1) == 0) {
                        @branchHint(.unlikely);
                        return error.ExpectedInteger;
                    }
                    var buffer: [64]u8 = undefined;
                    const text = try std.fmt.bufPrint(
                        &buffer,
                        "{d}\n",
                        .{try unboxIntChecked(value)},
                    );
                    try std.Io.File.stdout().writeStreamingAll(self.io, text);
                    try self.stack.push(0);
                },
                else => return error.InvalidOpcode,
            }
        }
    }
};

pub fn checkBytecodeHeaders(bytes: []const u8) !ByteCode {
    if (bytes.len < 12) {
        return error.TruncatedBytecodeHeader;
    }

    const strings_size = std.mem.readInt(i32, bytes[0..4], .little);
    const globals_count = std.mem.readInt(i32, bytes[4..8], .little);
    const public_count = std.mem.readInt(i32, bytes[8..12], .little);

    if (strings_size < 0 or globals_count < 0 or public_count < 0) {
        return error.NegativeHeaderField;
    }

    const pubs: usize = @intCast(public_count);
    const strs: usize = @intCast(strings_size);
    const remaining = bytes.len - 12;

    if (pubs > remaining / 9) {
        return error.TruncatedPublicSymbolTable;
    }

    const public_size = pubs * 9;
    if (strs > remaining - public_size) {
        return error.TruncatedStringTable;
    }

    const strings_start = 12 + public_size;
    const strings = bytes[strings_start .. strings_start + strs];
    const code_size = remaining - public_size - strs;

    for (0..pubs) |idx| {
        const offset = 12 + idx * 9;
        const string_idx = std.mem.readInt(i32, bytes[offset..][0..4], .little);
        const global_or_fun_idx = std.mem.readInt(i32, bytes[offset + 4 ..][0..4], .little);
        const symb_type = std.mem.readInt(u8, bytes[offset + 8 ..][0..1], .little);

        if (symb_type > 1) {
            std.debug.print("Invalid header: symbol_type must be 0 or 1, got {d}\n", .{symb_type});
            return error.InvalidPublicSymbolType;
        }

        if (string_idx < 0 or string_idx >= strings_size) {
            return error.PublicSymbolNameOffsetOutOfBounds;
        }
        if (std.mem.findScalar(u8, strings[@intCast(string_idx)..], 0) == null) {
            return error.UnterminatedPublicSymbolName;
        }

        if (global_or_fun_idx < 0) {
            return error.NegativePublicSymbolOffset;
        }
        if (symb_type == 0) {
            if (@as(usize, @intCast(global_or_fun_idx)) >= code_size) {
                return error.PublicFunctionAddressOutOfBounds;
            }
        } else if (global_or_fun_idx >= globals_count) {
            return error.PublicGlobalIndexOutOfBounds;
        }
        std.debug.print("string_idx = {d}, global_or_fun_idx = {d}, symb_type = {d}\n", .{ string_idx, global_or_fun_idx, symb_type });
    }
    const code_start = 12 + pubs * 9 + strs;
    return ByteCode{ .code = bytes[code_start..], .globals_count = @intCast(globals_count), .strings = strings };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 2) {
        std.debug.print("Usage: lama_vm <file.bc>\n", .{});
        return error.InvalidCommandLineArguments;
    }
    const filename = args[1];
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, filename, init.arena.allocator(), .limited(64 * 1024 * 1024));

    std.debug.print("Bytes: {s}\n", .{bytes});
    const byteCode = try checkBytecodeHeaders(bytes);
    std.debug.print("byteCode = {any}\n", .{byteCode});

    var vm = VM{
        .code = byteCode.code,
        .instruction_starts = try markInstructionStarts(init.arena.allocator(), byteCode.code),
        .strings = byteCode.strings,
        .ip = 0,
        .globals = try init.arena.allocator().alloc(Value, byteCode.globals_count),
        .current_line = null,
        .io = init.io,
        .stack = .init(),
        .call_stack = .init(),
        .frame = .{
            .args = &.{},
            .locals = &.{},
            .closure = &.{},
            .stack_base = 0,
        },
        .alloc = init.arena.allocator(),
    };
    @memset(vm.globals, 0);
    try vm.run();
}
