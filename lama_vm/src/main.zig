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
                return error.StackUnderfloor;
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
                return error.StackUnderfloor;
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

pub const VM = struct {
    const Self = @This();
    code: []const u8,
    strings: []const u8,
    ip: usize, // invariant: 0 <= ip <= code.len

    globals: []Value,
    stack: Stack(Value),

    frame: Frame,
    call_stack: Stack(SavedFrame),

    current_line: ?i32,

    alloc: std.mem.Allocator,
    io: std.Io,

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

    pub fn run(self: *Self) !void {
        while (true) {
            const opcode = try self.readByte();
            switch (opcode) {
                // TODO: optimize some operations inplace
                0x01 => {
                    const right = try unboxIntChecked(try self.stack.pop());
                    const left = try unboxIntChecked(try self.stack.pop());
                    try self.stack.push(boxInt(left +% right));
                },
                0x02 => {
                    const right = try unboxIntChecked(try self.stack.pop());
                    const left = try unboxIntChecked(try self.stack.pop());
                    try self.stack.push(boxInt(left -% right));
                },
                0x03 => {
                    const right = try unboxIntChecked(try self.stack.pop());
                    const left = try unboxIntChecked(try self.stack.pop());
                    try self.stack.push(boxInt(left *% right));
                },
                0x52 => {
                    const args_count = try self.readI32();
                    const locals_count = try self.readI32();

                    if (args_count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArgsCount;
                    }
                    if (locals_count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeLocalsCount;
                    }

                    self.frame.locals = try self.alloc.alloc(Value, @intCast(locals_count));
                    self.frame.args = try self.alloc.alloc(Value, @intCast(args_count));

                    std.debug.print("BEGIN args={d} locals={d}\n", .{
                        args_count, locals_count,
                    });
                },
                0x5A => {
                    const line = try self.readI32();
                    self.current_line = line;
                },
                0x10 => {
                    const element = try self.readI32();
                    try self.stack.push(boxInt(element));
                },
                0x16 => {
                    return;
                },
                0x18 => {
                    _ = try self.stack.pop();
                },

                0x19 => {
                    const value = try self.stack.head();
                    try self.stack.push(value);
                },
                0x1A => {
                    const right = try self.stack.pop();
                    const left = try self.stack.pop();

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
                        return error.GlobalIndexOverflow;
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
                        return error.LocalIndexOverflow;
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
                        return error.GlobalIndexOverflow;
                    }
                    self.globals[udx] = try self.stack.head();
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
                        return error.LocalIndexOverflow;
                    }
                    self.frame.locals[udx] = try self.stack.head();
                },
                0x71 => {
                    const value = try self.stack.pop();
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
                else => return error.InvalideOpcode,
            }
        }
    }
};

pub fn checkBytecodeHeaders(bytes: []const u8) !ByteCode {
    if (bytes.len < 12) {
        return error.InvalidHeader;
    }

    const strings_size = std.mem.readInt(i32, bytes[0..4], .little);
    const globals_count = std.mem.readInt(i32, bytes[4..8], .little);
    const public_count = std.mem.readInt(i32, bytes[8..12], .little);

    if (strings_size < 0 or globals_count < 0 or public_count < 0) {
        return error.InvalidHeader;
    }

    const pubs: usize = @intCast(public_count);
    const strs: usize = @intCast(strings_size);
    const remaining = bytes.len - 12;

    if (pubs > remaining / 9) {
        return error.InvalidHeader;
    }

    const public_size = pubs * 9;
    if (strs > remaining - public_size) {
        return error.InvalidHeader;
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
            return error.InvalidSymbolType;
        }

        if (string_idx < 0 or string_idx >= strings_size) {
            return error.InvalidStringOffset;
        }
        if (std.mem.findScalar(u8, strings[@intCast(string_idx)..], 0) == null) {
            return error.UnterminatedString;
        }

        if (global_or_fun_idx < 0) {
            return error.InvalidSymbolOffset;
        }
        if (symb_type == 0) {
            if (@as(usize, @intCast(global_or_fun_idx)) >= code_size) {
                return error.InvalidSymbolOffset;
            }
        } else if (global_or_fun_idx >= globals_count) {
            return error.InvalidSymbolOffset;
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
        return error.InvalidArguments;
    }
    const filename = args[1];
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, filename, init.arena.allocator(), .limited(64 * 1024 * 1024));

    std.debug.print("Bytes: {s}\n", .{bytes});
    const byteCode = try checkBytecodeHeaders(bytes);
    std.debug.print("byteCode = {any}\n", .{byteCode});

    var vm = VM{
        .code = byteCode.code,
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
