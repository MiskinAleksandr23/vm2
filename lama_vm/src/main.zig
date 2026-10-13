const std = @import("std");
const Io = std.Io;

comptime {
    if (@sizeOf(usize) != 8 or @sizeOf(isize) != 8) {
        @compileError("VM requires a 64-bit target");
    }
}

extern fn LtagHash(name: [*:0]const u8) i64;
extern fn de_hash(tag: i64) [*:0]const u8;

const stack_size = 1 << 15;
const Value = usize;

inline fn boxInt(n: isize) Value {
    return (@as(usize, @bitCast(n)) << 1) | 1;
}

inline fn unboxIntUnchecked(value: Value) isize {
    return @as(isize, @bitCast(value)) >> 1;
}

inline fn unboxIntChecked(value: Value) !isize {
    if ((value & 1) == 0) {
        @branchHint(.unlikely);
        return error.ExpectedInteger;
    }
    return @as(isize, @bitCast(value)) >> 1;
}

pub fn Stack(comptime T: type, comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0);
    }
    return struct {
        const Self = @This();
        data: [capacity]T = undefined,
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
            if (self.len >= capacity) {
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

const ObjectHeader = extern struct {
    data_header: usize,
    forward_address: usize,
};

const Op = enum(u8) {
    Add = 0x01,
    Sub = 0x02,
    Mul = 0x03,
    Div = 0x04,
    Rem = 0x05,
    Less = 0x06,
    LessEqual = 0x07,
    Greater = 0x08,
    GreaterEqual = 0x09,
    Equal = 0x0A,
    NotEqual = 0x0B,
    And = 0x0C,
    Or = 0x0D,

    Const = 0x10,
    String = 0x11,
    Sexp = 0x12,
    StoreIndirect = 0x13,
    StoreElement = 0x14,
    Jump = 0x15,
    End = 0x16,
    Ret = 0x17,
    Drop = 0x18,
    Dup = 0x19,
    Swap = 0x1A,
    Elem = 0x1B,

    LoadGlobal = 0x20,
    LoadLocal = 0x21,
    LoadArg = 0x22,
    LoadClosure = 0x23,

    LoadAddressGlobal = 0x30,
    LoadAddressLocal = 0x31,
    LoadAddressArg = 0x32,
    LoadAddressClosure = 0x33,

    StoreGlobal = 0x40,
    StoreLocal = 0x41,
    StoreArg = 0x42,
    StoreClosure = 0x43,

    JumpZero = 0x50,
    JumpNonZero = 0x51,
    Begin = 0x52,
    CBegin = 0x53,
    Closure = 0x54,
    CallClosure = 0x55,
    Call = 0x56,
    Tag = 0x57,
    ArrayPattern = 0x58,
    Fail = 0x59,
    Line = 0x5A,

    StringEqual = 0x60,
    IsString = 0x61,
    IsArray = 0x62,
    IsSexp = 0x63,
    IsBoxed = 0x64,
    IsUnboxed = 0x65,
    IsClosure = 0x66,

    Read = 0x70,
    Write = 0x71,
    Length = 0x72,
    ToString = 0x73,
    Array = 0x74,

    Terminator = 0xFF,
    _,
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
            0x01...0x0D, 0x13...0x14, 0x16...0x1B, 0x60...0x66, 0x70...0x73 => 1,
            0x10...0x11, 0x15, 0x20...0x23, 0x30...0x33, 0x40...0x43, 0x50...0x51, 0x55, 0x58, 0x5A, 0x74 => 5,
            0x12, 0x52...0x53, 0x56...0x57, 0x59 => 9,
            0x54 => blk: {
                if (code.len - offset < 9) return error.TruncatedInstruction;
                const count = std.mem.readInt(i32, code[offset + 5 ..][0..4], .little);
                if (count < 0) return error.NegativeClosureCaptureCount;
                break :blk 9 + @as(usize, @intCast(count)) * 5;
            },
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

pub const Vm = struct {
    const Self = @This();

    code: []const u8,
    instruction_starts: []const bool,
    strings: []const u8,
    ip: usize,

    globals: []Value,
    stack: Stack(Value, stack_size),

    frame: Frame,
    call_stack: Stack(SavedFrame, stack_size),

    current_line: ?i32,

    alloc: std.mem.Allocator,
    io: std.Io,
    input_data: ?[]const u8 = null,
    input_pos: usize = 0,
    objects: std.AutoHashMapUnmanaged(Value, void) = .empty,

    fn createString(self: *Self, bytes: []const u8) !Value {
        const size = @sizeOf(ObjectHeader) + bytes.len + 1;
        const buff = try self.alloc.alignedAlloc(u8, std.mem.Alignment.of(ObjectHeader), size);

        const header: *ObjectHeader = @ptrCast(buff.ptr);
        header.data_header = (bytes.len << 3) | 1;
        header.forward_address = 0;

        @memcpy(buff[@sizeOf(ObjectHeader) .. @sizeOf(ObjectHeader) + bytes.len], bytes);
        buff[@sizeOf(ObjectHeader) + bytes.len] = 0;

        const value = @intFromPtr(buff.ptr + @sizeOf(ObjectHeader));
        try self.objects.put(self.alloc, value, {});
        return value;
    }

    fn readInputInteger(self: *Self) !isize {
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

    fn ensureEnoughBytes(self: *Self, need: usize) !void {
        if (need > self.code.len - self.ip) {
            @branchHint(.unlikely);
            std.debug.print(
                "Not enough bytes to read: need {d}, have: {}\n",
                .{ need, self.code.len - self.ip },
            );
            return error.UnexpectedEndOfBytecode;
        }
    }
    fn readByte(self: *Self) !u8 {
        try self.ensureEnoughBytes(1);
        const byte = self.code[self.ip];
        self.ip += 1;
        return byte;
    }
    fn readI32(self: *Self) !i32 {
        try self.ensureEnoughBytes(4);
        const value = std.mem.readInt(i32, self.code[self.ip..][0..4], .little);
        self.ip += 4;
        return value;
    }

    fn CheckAddress(self: *Self, addr: usize) !void {
        if (addr >= self.code.len) {
            @branchHint(.unlikely);
            return error.JumpAddressOutOfBounds;
        }
        if (!self.instruction_starts[addr]) {
            return error.JumpTargetNotInstructionStart;
        }
    }

    inline fn stackPop(self: *Self) !Value {
        if (self.stack.len <= self.frame.stack_base) {
            return error.StackUnderflow;
        }
        return try self.stack.pop();
    }

    inline fn stackHead(self: *Self) !Value {
        if (self.stack.len <= self.frame.stack_base) {
            return error.StackUnderflow;
        }
        return try self.stack.head();
    }

    fn readNonNegativeI32(self: *Self, comptime negative_error: anyerror) !usize {
        const value = try self.readI32();
        if (value < 0) {
            @branchHint(.unlikely);
            return negative_error;
        }
        return @intCast(value);
    }

    fn referenceInSlice(ref: Value, values: []Value) ?*Value {
        if (values.len == 0) return null;

        const start = @intFromPtr(values.ptr);
        if (ref < start) return null;

        const offset = ref - start;
        if (offset % @sizeOf(Value) != 0) return null;

        const index = offset / @sizeOf(Value);
        if (index >= values.len) return null;

        return &values[index];
    }

    fn appendValueText(self: *Self, value: Value, buff: *std.ArrayList(u8), path: *std.ArrayList(Value)) anyerror!void {
        if ((value & 1) != 0) {
            const number = try unboxIntChecked(value);
            var buffer: [32]u8 = undefined;
            const bytes = try std.fmt.bufPrint(&buffer, "{d}", .{number});
            try buff.appendSlice(self.alloc, bytes);
        } else {
            const header = try self.objectHeaderChecked(value);
            const tag = header.data_header & 7;
            if (tag == 1) {
                const length = header.data_header >> 3;
                const data: [*]const u8 = @ptrFromInt(value);
                try buff.append(self.alloc, '"');
                try buff.appendSlice(self.alloc, data[0..length]);
                try buff.append(self.alloc, '"');
            } else if (tag == 3) {
                if (std.mem.findScalar(Value, path.items, value) != null) {
                    return error.CyclicValue;
                }
                if (path.items.len >= 256) {
                    return error.StringConversionTooDeep;
                }
                try path.append(self.alloc, value);
                defer path.items.len -= 1;

                const length = header.data_header >> 3;
                const data: [*]const Value = @ptrFromInt(value);
                try buff.append(self.alloc, '[');
                for (0..length) |i| {
                    if (i != 0) {
                        try buff.appendSlice(self.alloc, ", ");
                    }
                    try self.appendValueText(data[i], buff, path);
                }
                try buff.append(self.alloc, ']');
            } else if (tag == 5) {
                const constructor_tag: *const usize = @ptrFromInt(value);
                const id = constructor_tag.*;
                const name = std.mem.span(de_hash(@intCast(id)));
                try buff.appendSlice(self.alloc, name);

                const count = header.data_header >> 3;
                if (std.mem.findScalar(Value, path.items, value) != null) {
                    return error.CyclicValue;
                }
                if (path.items.len >= 256) {
                    return error.StringConversionTooDeep;
                }
                try path.append(self.alloc, value);
                defer path.items.len -= 1;
                if (count > 0) {
                    try buff.appendSlice(self.alloc, " (");
                    const data: [*]const Value = @ptrFromInt(value + 8);
                    for (0..count) |idx| {
                        if (idx != 0) {
                            try buff.appendSlice(self.alloc, ", ");
                        }
                        try self.appendValueText(data[idx], buff, path);
                    }
                    try buff.append(self.alloc, ')');
                }
            } else {
                return error.UnsupportedStringConversion;
            }
        }
    }

    fn referenceChecked(self: *Self, ref: Value) !*Value {
        const current = [_][]Value{
            self.globals,
            self.frame.locals,
            self.frame.args,
            self.frame.closure,
        };
        for (current) |values| {
            if (referenceInSlice(ref, values)) |ptr| {
                return ptr;
            }
        }

        for (self.call_stack.data[0..self.call_stack.len]) |saved| {
            const values = [_][]Value{
                saved.frame.locals,
                saved.frame.args,
                saved.frame.closure,
            };
            for (values) |slice| {
                if (referenceInSlice(ref, slice)) |ptr| {
                    return ptr;
                }
            }
        }

        return error.InvalidReference;
    }

    fn objectHeaderChecked(self: *Self, value: Value) !*const ObjectHeader {
        if (value == 0 or (value & 1) != 0 or
            !self.objects.contains(value))
        {
            @branchHint(.unlikely);
            return error.ExpectedStringOrArray;
        }
        return @ptrFromInt(value - @sizeOf(ObjectHeader));
    }

    pub fn run(self: *Self) !void {
        while (true) {
            const opcode: Op = @enumFromInt(try self.readByte());
            switch (opcode) {
                Op.Add => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(left +% right));
                },
                Op.Sub => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(left -% right));
                },
                Op.Mul => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(left *% right));
                },

                Op.Div => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    if (right == 0) {
                        return error.DivisionByZero;
                    }
                    try self.stack.push(boxInt(@divTrunc(left, right)));
                },
                Op.Rem => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    if (right == 0) {
                        return error.DivisionByZero;
                    }
                    try self.stack.push(boxInt(@rem(left, right)));
                },
                Op.Less => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left < right)));
                },
                Op.LessEqual => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left <= right)));
                },
                Op.Greater => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left > right)));
                },
                Op.GreaterEqual => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left >= right)));
                },
                Op.Sexp => {
                    const offset = try self.readNonNegativeI32(error.NegativeStringOffset);
                    if (offset >= self.strings.len) {
                        @branchHint(.unlikely);
                        return error.StringOffsetOutOfBounds;
                    }

                    const count = try self.readNonNegativeI32(error.NegativeSexpFieldCount);
                    if (self.stack.len < self.frame.stack_base or
                        count > self.stack.len - self.frame.stack_base)
                    {
                        @branchHint(.unlikely);
                        return error.StackUnderflow;
                    }

                    const tail = self.strings[offset..];
                    const end = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;
                    const constructor_name = tail[0..end];
                    const name = try self.alloc.dupeZ(u8, constructor_name);
                    const encoded: Value = @intCast(LtagHash(name.ptr));
                    const tag = try unboxIntChecked(encoded);

                    const buff = try self.alloc.alignedAlloc(u8, std.mem.Alignment.of(ObjectHeader), 24 + count * 8);

                    const header: *ObjectHeader = @ptrCast(buff.ptr);
                    header.data_header = (count << 3) | 5;
                    header.forward_address = 0;

                    const constructor_tag: *usize = @ptrCast(@alignCast(buff.ptr + 16));
                    constructor_tag.* = @intCast(tag);
                    const elements: [*]Value = @ptrCast(@alignCast(buff.ptr + 24));
                    for (0..count) |i| {
                        elements[count - 1 - i] = try self.stackPop();
                    }
                    const object = @intFromPtr(buff.ptr + @sizeOf(ObjectHeader));
                    try self.objects.put(self.alloc, object, {});
                    try self.stack.push(object);
                },
                Op.String => {
                    const offset = try self.readNonNegativeI32(error.NegativeStringOffset);
                    if (offset >= self.strings.len) {
                        @branchHint(.unlikely);
                        return error.StringOffsetOutOfBounds;
                    }
                    const tail = self.strings[offset..];
                    const end = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;
                    const bytes = tail[0..end];
                    const value = try self.createString(bytes);
                    try self.stack.push(value);
                },
                Op.Length => {
                    const value = try self.stackPop();
                    const header = try self.objectHeaderChecked(value);
                    const tag = header.data_header & 7;
                    const length = header.data_header >> 3;

                    if (tag == 1 or tag == 3 or tag == 5) {
                        @branchHint(.likely);
                        try self.stack.push(boxInt(@intCast(length)));
                    } else {
                        @branchHint(.unlikely);
                        return error.ExpectedStringOrArray;
                    }
                },
                Op.Array => {
                    const elem_cnt = try self.readNonNegativeI32(error.NegativeArrayLength);
                    if (self.stack.len < self.frame.stack_base or
                        elem_cnt > self.stack.len - self.frame.stack_base)
                    {
                        @branchHint(.unlikely);
                        return error.StackUnderflow;
                    }
                    const len = @sizeOf(ObjectHeader) + @sizeOf(Value) * elem_cnt;
                    const buff = try self.alloc.alignedAlloc(u8, std.mem.Alignment.of(ObjectHeader), len);

                    const header: *ObjectHeader = @ptrCast(buff.ptr);
                    header.data_header = (elem_cnt << 3) | 3;
                    header.forward_address = 0;

                    for (0..elem_cnt) |i| {
                        const value: [*]Value = @ptrCast(@alignCast(buff.ptr + @sizeOf(ObjectHeader)));
                        value[elem_cnt - 1 - i] = try self.stackPop();
                    }
                    const object = @intFromPtr(buff.ptr) + @sizeOf(ObjectHeader);
                    try self.objects.put(self.alloc, object, {});
                    try self.stack.push(object);
                },
                Op.ArrayPattern => {
                    const args_cnt = try self.readNonNegativeI32(error.NegativeArrayLength);
                    const value = try self.stackPop();

                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = ((header.data_header & 7) == 3) and
                            ((header.data_header >> 3) == args_cnt);
                    }

                    try self.stack.push(boxInt(@intFromBool(matches)));
                },

                Op.Elem => {
                    const index = try unboxIntChecked(try self.stackPop());
                    if (index < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeElementIndex;
                    }
                    const uindex: usize = @intCast(index);
                    const object = try self.stackPop();

                    const header = try self.objectHeaderChecked(object);
                    const tag = header.data_header & 7;
                    const length = header.data_header >> 3;

                    if (tag != 1 and tag != 3 and tag != 5) {
                        return error.ExpectedStringOrArray;
                    }

                    if (uindex >= length) {
                        @branchHint(.unlikely);
                        return error.ElementIndexOutOfBounds;
                    }
                    if (tag == 1) {
                        const elements: [*]const u8 = @ptrFromInt(object);
                        const value: u8 = elements[uindex];
                        try self.stack.push(boxInt(@intCast(value)));
                    } else if (tag == 3) {
                        const elements: [*]const Value = @ptrFromInt(object);
                        const value = elements[uindex];
                        try self.stack.push(value);
                    } else if (tag == 5) {
                        const elements: [*]const Value = @ptrFromInt(object + @sizeOf(Value));
                        try self.stack.push(elements[uindex]);
                    }
                },
                Op.StoreElement => {
                    const new_value = try self.stackPop();
                    const index_or_ref = try self.stackPop();
                    if ((index_or_ref & 1) == 0) {
                        const ptr = try self.referenceChecked(index_or_ref);
                        ptr.* = new_value;
                        try self.stack.push(new_value);
                        continue;
                    }
                    const index = try unboxIntChecked(index_or_ref);
                    if (index < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeElementIndex;
                    }
                    const uindex: usize = @intCast(index);
                    const object = try self.stackPop();

                    const header = try self.objectHeaderChecked(object);
                    const tag = header.data_header & 7;
                    const length = header.data_header >> 3;

                    if (tag != 1 and tag != 3 and tag != 5) {
                        return error.ExpectedStringOrArray;
                    }

                    if (uindex >= length) {
                        @branchHint(.unlikely);
                        return error.ElementIndexOutOfBounds;
                    }
                    if (tag == 1) {
                        const elements: [*]u8 = @ptrFromInt(object);
                        const unew_value = try unboxIntChecked(new_value);
                        if (unew_value < 0 or unew_value > 255) {
                            @branchHint(.unlikely);
                            return error.StringByteOutOfRange;
                        }
                        elements[uindex] = @intCast(unew_value);
                        try self.stack.push(new_value);
                    } else if (tag == 3) {
                        const elements: [*]Value = @ptrFromInt(object);
                        elements[uindex] = new_value;
                        try self.stack.push(new_value);
                    } else if (tag == 5) {
                        const elements: [*]Value = @ptrFromInt(object + @sizeOf(Value));
                        elements[uindex] = new_value;
                        try self.stack.push(new_value);
                    }
                },
                Op.LoadAddressGlobal => {
                    const idx = try self.readNonNegativeI32(error.NegativeGlobalIndex);
                    if (idx >= self.globals.len) {
                        return error.GlobalIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.globals[idx]));
                },
                Op.LoadAddressLocal => {
                    const idx = try self.readNonNegativeI32(error.NegativeLocalIndex);
                    if (idx >= self.frame.locals.len) {
                        return error.LocalIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.frame.locals[idx]));
                },
                Op.LoadAddressArg => {
                    const idx = try self.readNonNegativeI32(error.NegativeArgumentIndex);
                    if (idx >= self.frame.args.len) {
                        return error.ArgumentIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.frame.args[idx]));
                },
                Op.StoreIndirect => {
                    const new_value = try self.stackPop();
                    const ref = try self.stackPop();

                    const ptr = try self.referenceChecked(ref);
                    ptr.* = new_value;

                    try self.stack.push(new_value);
                },
                Op.Equal => {
                    const right = try self.stackPop();
                    const left = try self.stackPop();
                    if ((left & 1) == 1 and (right & 1) == 1) {
                        try self.stack.push(boxInt(@intFromBool(left == right)));
                    } else if ((left & 1) == 1 or (right & 1) == 1) {
                        try self.stack.push(boxInt(0));
                    } else {
                        return error.ExpectedInteger;
                    }
                },
                Op.NotEqual => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool(left != right)));
                },
                Op.And => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool((left != 0) and (right != 0))));
                },
                Op.Or => {
                    const right = try unboxIntChecked(try self.stackPop());
                    const left = try unboxIntChecked(try self.stackPop());
                    try self.stack.push(boxInt(@intFromBool((left != 0) or (right != 0))));
                },
                Op.Jump => {
                    const addr = try self.readNonNegativeI32(error.NegativeJumpAddress);
                    try self.CheckAddress(addr);
                    self.ip = addr;
                },
                Op.LoadArg => {
                    const idx = try self.readNonNegativeI32(error.NegativeArgumentIndex);
                    if (idx >= self.frame.args.len) {
                        @branchHint(.unlikely);
                        return error.ArgumentIndexOutOfBounds;
                    }
                    try self.stack.push(self.frame.args[idx]);
                },
                Op.StoreArg => {
                    const idx = try self.readNonNegativeI32(error.NegativeArgumentIndex);
                    if (idx >= self.frame.args.len) {
                        @branchHint(.unlikely);
                        return error.ArgumentIndexOutOfBounds;
                    }
                    self.frame.args[idx] = try self.stackHead();
                },
                Op.JumpZero => {
                    const addr = try self.readNonNegativeI32(error.NegativeJumpAddress);
                    try self.CheckAddress(addr);
                    if (0 == try unboxIntChecked(try self.stackPop())) {
                        self.ip = addr;
                    }
                },
                Op.JumpNonZero => {
                    const addr = try self.readNonNegativeI32(error.NegativeJumpAddress);
                    try self.CheckAddress(addr);
                    if (0 != try unboxIntChecked(try self.stackPop())) {
                        self.ip = addr;
                    }
                },
                Op.LoadClosure => {
                    const idx = try self.readNonNegativeI32(error.NegativeClosureIndex);
                    if (idx >= self.frame.closure.len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    try self.stack.push(self.frame.closure[idx]);
                },
                Op.LoadAddressClosure => {
                    const idx = try self.readNonNegativeI32(error.NegativeClosureIndex);
                    if (idx >= self.frame.closure.len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.frame.closure[idx]));
                },
                Op.StoreClosure => {
                    const idx = try self.readNonNegativeI32(error.NegativeClosureIndex);
                    if (idx >= self.frame.closure.len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    self.frame.closure[idx] = try self.stackHead();
                },
                Op.Begin, Op.CBegin => {
                    const args_count = try self.readNonNegativeI32(error.NegativeArgumentCount);
                    const locals_count = try self.readNonNegativeI32(error.NegativeLocalCount);

                    if (self.call_stack.len == 0) {
                        self.frame.args = try self.alloc.alloc(Value, args_count);
                        @memset(self.frame.args, 0);
                    } else {
                        if (args_count != self.frame.args.len) {
                            @branchHint(.unlikely);
                            return error.ArgumentCountMismatch;
                        }
                    }

                    self.frame.locals = try self.alloc.alloc(Value, locals_count);
                    @memset(self.frame.locals, 0);
                },
                Op.Closure => {
                    const addr = try self.readNonNegativeI32(error.NegativeClosureAddress);
                    const count = try self.readNonNegativeI32(error.NegativeClosureCaptureCount);

                    try self.CheckAddress(addr);
                    if (self.code[addr] != 0x52 and self.code[addr] != 0x53) {
                        return error.ClosureTargetNotFunction;
                    }

                    const buff = try self.alloc.alignedAlloc(
                        u8,
                        std.mem.Alignment.of(ObjectHeader),
                        24 + count * @sizeOf(Value),
                    );

                    const header: *ObjectHeader = @ptrCast(buff.ptr);
                    header.data_header = ((count + 1) << 3) | 7;
                    header.forward_address = 0;

                    const function_addr: *usize = @ptrCast(@alignCast(buff.ptr + 16));
                    function_addr.* = addr;

                    const captures: [*]Value = @ptrCast(@alignCast(buff.ptr + 24));

                    for (0..count) |idx| {
                        const d: usize = @intCast(try self.readByte());
                        const id = try self.readNonNegativeI32(error.NegativeClosureCaptureIndex);

                        switch (d) {
                            0 => {
                                if (id >= self.globals.len) {
                                    @branchHint(.unlikely);
                                    return error.GlobalIndexOutOfBounds;
                                }
                                captures[idx] = self.globals[id];
                            },
                            1 => {
                                if (id >= self.frame.locals.len) {
                                    @branchHint(.unlikely);
                                    return error.LocalIndexOutOfBounds;
                                }
                                captures[idx] = self.frame.locals[id];
                            },
                            2 => {
                                if (id >= self.frame.args.len) {
                                    @branchHint(.unlikely);
                                    return error.ArgumentIndexOutOfBounds;
                                }
                                captures[idx] = self.frame.args[id];
                            },
                            3 => {
                                if (id >= self.frame.closure.len) {
                                    @branchHint(.unlikely);
                                    return error.ClosureIndexOutOfBounds;
                                }
                                captures[idx] = self.frame.closure[id];
                            },
                            else => return error.InvalidClosureCaptureScope,
                        }
                    }
                    const object = @intFromPtr(buff.ptr + 16);
                    try self.objects.put(self.alloc, object, {});
                    try self.stack.push(object);
                },
                Op.Line => {
                    self.current_line = try self.readI32();
                },
                Op.CallClosure => {
                    const count = try self.readNonNegativeI32(error.NegativeArgumentCount);
                    if (self.stack.len < self.frame.stack_base or
                        count + 1 > self.stack.len - self.frame.stack_base)
                    {
                        return error.StackUnderflow;
                    }
                    if (self.call_stack.len >= self.call_stack.data.len) return error.CallStackOverflow;

                    var new_frame: Frame = undefined;
                    const args = try self.alloc.alloc(Value, count);
                    for (0..count) |i| {
                        args[count - 1 - i] = try self.stackPop();
                    }

                    const object = try self.stackPop();
                    if (!self.objects.contains(object)) return error.ExpectedClosure;
                    const header = try self.objectHeaderChecked(object);
                    const length = header.data_header >> 3;
                    if ((header.data_header & 7) != 7) return error.ExpectedClosure;
                    if (length == 0) return error.InvalidClosure;
                    const function_addr: *const usize = @ptrFromInt(object);
                    const uaddr = function_addr.*;
                    try self.CheckAddress(uaddr);
                    if (self.code[uaddr] != 0x52 and self.code[uaddr] != 0x53) return error.CallTargetNotFunction;
                    if (self.code.len - uaddr < 9) return error.TruncatedInstruction;
                    const declared_args = std.mem.readInt(i32, self.code[uaddr + 1 ..][0..4], .little);
                    if (declared_args < 0) return error.NegativeArgumentCount;
                    if (count != declared_args) return error.ArgumentCountMismatch;

                    const captures: [*]Value = @ptrFromInt(object + @sizeOf(Value));
                    new_frame.args = args;
                    new_frame.locals = &.{};
                    new_frame.closure = captures[0 .. length - 1];
                    new_frame.stack_base = self.stack.len;

                    const saved = SavedFrame{ .frame = self.frame, .return_ip = self.ip };
                    try self.call_stack.push(saved);
                    self.frame = new_frame;
                    self.ip = uaddr;
                },

                Op.Call => {
                    const addr = try self.readNonNegativeI32(error.NegativeJumpAddress);
                    try self.CheckAddress(addr);

                    const args_cnt = try self.readNonNegativeI32(error.NegativeArgumentCount);
                    if (self.code[addr] != 0x52) return error.CallTargetNotFunction;
                    if (self.code.len - addr < 9) return error.TruncatedInstruction;
                    const declared_args = std.mem.readInt(
                        i32,
                        self.code[addr + 1 ..][0..4],
                        .little,
                    );
                    if (declared_args < 0) return error.NegativeArgumentCount;
                    if (args_cnt != declared_args) return error.ArgumentCountMismatch;
                    if (self.stack.len < self.frame.stack_base or
                        args_cnt > self.stack.len - self.frame.stack_base)
                    {
                        return error.StackUnderflow;
                    }
                    if (self.call_stack.len >= self.call_stack.data.len) return error.CallStackOverflow;

                    var new_frame: Frame = undefined;
                    new_frame.args = try self.alloc.alloc(Value, args_cnt);
                    for (0..args_cnt) |idx| {
                        new_frame.args[args_cnt - 1 - idx] = try self.stackPop();
                    }
                    const saved = SavedFrame{ .frame = self.frame, .return_ip = self.ip };
                    try self.call_stack.push(saved);

                    new_frame.locals = &.{};
                    new_frame.closure = &.{};
                    new_frame.stack_base = self.stack.len;

                    self.frame = new_frame;
                    self.ip = addr;
                },
                Op.Tag => {
                    const offset = try self.readNonNegativeI32(error.NegativeStringOffset);
                    const count = try self.readNonNegativeI32(error.NegativeSexpFieldCount);

                    if (offset >= self.strings.len) return error.StringOffsetOutOfBounds;

                    const tail = self.strings[offset..];
                    const end = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;

                    const constructor_name = tail[0..end];
                    const name = try self.alloc.dupeZ(u8, constructor_name);
                    const encoded: Value = @intCast(LtagHash(name.ptr));
                    const tag = try unboxIntChecked(encoded);
                    const value = try self.stackPop();

                    var matches = false;
                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        if ((header.data_header & 7) == 5) {
                            const constructor_tag: *const usize = @ptrFromInt(value);
                            const expected_tag: usize = @intCast(tag);

                            matches = ((header.data_header >> 3) == count) and
                                (constructor_tag.* == expected_tag);
                        }
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.StringEqual => {
                    const right = try self.stackPop();
                    const left = try self.stackPop();

                    var matches = false;
                    if (self.objects.contains(left) and self.objects.contains(right)) {
                        const header_l = try self.objectHeaderChecked(left);
                        const header_r = try self.objectHeaderChecked(right);

                        if ((header_l.data_header & 7) == 1 and
                            (header_r.data_header & 7) == 1)
                        {
                            const data_l: [*]const u8 = @ptrFromInt(left);
                            const data_r: [*]const u8 = @ptrFromInt(right);

                            const bytes_l = data_l[0 .. header_l.data_header >> 3];
                            const bytes_r = data_r[0 .. header_r.data_header >> 3];

                            if (std.mem.eql(u8, bytes_l, bytes_r)) {
                                matches = true;
                            }
                        }
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsString => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 1;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsArray => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 3;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsSexp => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 5;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsClosure => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 7;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsBoxed => {
                    const value = try self.stackPop();
                    try self.stack.push(boxInt(@intFromBool((value & 1) == 0)));
                },
                Op.IsUnboxed => {
                    const value = try self.stackPop();
                    try self.stack.push(boxInt(@intFromBool((value & 1) != 0)));
                },
                Op.Fail => {
                    const row = try self.readNonNegativeI32(error.InvalidSourceLocation);
                    const column = try self.readNonNegativeI32(error.InvalidSourceLocation);

                    _ = try self.stackHead();
                    std.debug.print("Pattern matching failed: row = {d}, column = {d}\n", .{ row, column });
                    return error.MatchFailure;
                },
                Op.Const => {
                    const element = try self.readI32();
                    try self.stack.push(boxInt(element));
                },
                Op.End, Op.Ret => {
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
                Op.Drop => {
                    _ = try self.stackPop();
                },

                Op.Dup => {
                    const value = try self.stackHead();
                    try self.stack.push(value);
                },
                Op.Swap => {
                    const right = try self.stackPop();
                    const left = try self.stackPop();

                    try self.stack.push(right);
                    try self.stack.push(left);
                },
                Op.LoadGlobal => {
                    const idx = try self.readNonNegativeI32(error.NegativeGlobalIndex);
                    if (idx >= self.globals.len) {
                        @branchHint(.unlikely);
                        return error.GlobalIndexOutOfBounds;
                    }
                    try self.stack.push(self.globals[idx]);
                },
                Op.LoadLocal => {
                    const idx = try self.readNonNegativeI32(error.NegativeLocalIndex);
                    if (idx >= self.frame.locals.len) {
                        @branchHint(.unlikely);
                        return error.LocalIndexOutOfBounds;
                    }
                    try self.stack.push(self.frame.locals[idx]);
                },
                Op.StoreGlobal => {
                    const idx = try self.readNonNegativeI32(error.NegativeGlobalIndex);
                    if (idx >= self.globals.len) {
                        @branchHint(.unlikely);
                        return error.GlobalIndexOutOfBounds;
                    }
                    self.globals[idx] = try self.stackHead();
                },
                Op.StoreLocal => {
                    const idx = try self.readNonNegativeI32(error.NegativeLocalIndex);
                    if (idx >= self.frame.locals.len) {
                        @branchHint(.unlikely);
                        return error.LocalIndexOutOfBounds;
                    }
                    self.frame.locals[idx] = try self.stackHead();
                },
                Op.Read => {
                    try self.stack.push(boxInt(try self.readInputInteger()));
                },
                Op.Write => {
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
                Op.ToString => {
                    const value = try self.stackPop();
                    var buff: std.ArrayList(u8) = .empty;
                    defer buff.deinit(self.alloc);
                    var path: std.ArrayList(Value) = .empty;
                    defer path.deinit(self.alloc);
                    try self.appendValueText(value, &buff, &path);
                    const str = try self.createString(buff.items);
                    try self.stack.push(str);
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

    const byteCode = try checkBytecodeHeaders(bytes);

    const instruction_starts = try markInstructionStarts(init.arena.allocator(), byteCode.code);
    const public_count: usize = @intCast(std.mem.readInt(i32, bytes[8..12], .little));
    for (0..public_count) |idx| {
        const offset = 12 + idx * 9;
        if (bytes[offset + 8] != 0) continue;
        const addr: usize = @intCast(std.mem.readInt(i32, bytes[offset + 4 ..][0..4], .little));
        if (!instruction_starts[addr]) {
            return error.PublicFunctionTargetNotInstructionStart;
        }
        if (byteCode.code[addr] != 0x52 and byteCode.code[addr] != 0x53) {
            return error.PublicFunctionTargetNotFunction;
        }
    }

    var vm = Vm{
        .code = byteCode.code,
        .instruction_starts = instruction_starts,
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
