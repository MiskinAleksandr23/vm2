const std = @import("std");
const Io = std.Io;

comptime {
    if (@sizeOf(usize) != 8 or @sizeOf(isize) != 8) {
        @compileError("VM requires a 64-bit target");
    }
}

extern fn LtagHash(name: [*:0]const u8) i64;
extern fn de_hash(tag: i64) [*:0]const u8;

extern fn __init() void;
extern fn __shutdown() void;
extern var __gc_stack_top: usize;
extern var __gc_stack_bottom: usize;
extern fn alloc_string(length: usize) ?*ObjectHeader;
extern fn alloc_array(length: usize) ?*ObjectHeader;
extern fn alloc_sexp(length: usize) ?*ObjectHeader;
extern fn alloc_closure(length: usize) ?*ObjectHeader;
extern fn is_valid_heap_pointer(pointer: *const anyopaque) bool;

export var gc_anchor: usize linksection("custom_data") = 1;

const stack_size = 1 << 15;
const buffer_size = 64 * 1024 * 1024;
var file_buffer: [buffer_size]u8 = undefined;
var input_buffer: [buffer_size]u8 = undefined;
var string_buffer: [buffer_size]u8 = undefined;
var instruction_buffer: [buffer_size]bool = undefined;
var reference_marker: usize = 0;
var vm: Vm = undefined;
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
        data: [capacity]T align(16) = undefined,
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
    closure: ?usize,
    stack_base: usize,
    frame_start: usize,
    id: usize,
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

fn markInstructionStarts(code: []const u8) ![]bool {
    const starts = instruction_buffer[0..code.len];
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

fn readBounded(reader: *std.Io.File.Reader, buffer: []u8, comptime too_large: anyerror) ![]const u8 {
    const size = reader.interface.readSliceShort(buffer) catch return reader.err.?;
    if (size == buffer.len) {
        var extra: [1]u8 = undefined;
        const remaining = reader.interface.readSliceShort(&extra) catch return reader.err.?;
        if (remaining != 0) return too_large;
    }
    return buffer[0..size];
}

pub const Vm = struct {
    const Self = @This();

    code: []const u8,
    instruction_starts: []const bool,
    strings: []const u8,
    ip: usize,

    globals: []Value,
    stack: Stack(Value, stack_size * 8),

    frame: Frame,
    call_stack: Stack(SavedFrame, stack_size),

    current_line: ?i32,

    io: std.Io,
    input_data: ?[]const u8 = null,
    input_pos: usize = 0,
    next_frame_id: usize = 2,

    fn reserve(self: *Self, count: usize) ![]Value {
        if (count > self.stack.data.len - self.stack.len) return error.StackOverflow;
        const start = self.stack.len;
        self.stack.len += count;
        const values = self.stack.data[start..self.stack.len];
        @memset(values, 0);
        return values;
    }

    fn closureValues(self: *Self, frame: Frame) []Value {
        const slot = frame.closure orelse return &.{};
        const value = self.stack.data[slot];
        const header: *const ObjectHeader = @ptrFromInt(value - @sizeOf(ObjectHeader));
        const data: [*]Value = @ptrFromInt(value + @sizeOf(Value));
        return data[0 .. (header.data_header >> 3) - 1];
    }

    fn allocateObject(self: *Self, comptime kind: enum { string, array, sexp, closure }, count: usize) !Value {
        __gc_stack_top = @intFromPtr(&self.stack.data[0]);
        __gc_stack_bottom = @intFromPtr(self.stack.data[0..self.stack.len].ptr + self.stack.len);
        const header = (switch (kind) {
            .string => alloc_string(count),
            .array => alloc_array(count),
            .sexp => alloc_sexp(count),
            .closure => alloc_closure(count),
        }) orelse return error.OutOfMemory;
        return @intFromPtr(header) + @sizeOf(ObjectHeader);
    }

    fn inHeap(value: Value) bool {
        return value != 0 and (value & 7) == 0 and is_valid_heap_pointer(@ptrFromInt(value));
    }

    fn isReference(value: Value) bool {
        if (!inHeap(value)) return false;
        const header: *const ObjectHeader = @ptrFromInt(value - @sizeOf(ObjectHeader));
        if (header.data_header != ((3 << 3) | 3)) return false;
        const fields: [*]const Value = @ptrFromInt(value);
        return fields[0] == @intFromPtr(&reference_marker);
    }

    fn isObject(value: Value) bool {
        return inHeap(value) and !isReference(value);
    }

    fn createReference(self: *Self, owner: Value, index: usize) !Value {
        try self.stack.push(owner);
        const value = try self.allocateObject(.array, 3);
        const fields: [*]Value = @ptrFromInt(value);
        fields[0] = @intFromPtr(&reference_marker);
        fields[1] = try self.stack.pop();
        fields[2] = boxInt(@intCast(index));
        return value;
    }

    fn nextFrameId(self: *Self) !usize {
        if (self.next_frame_id > std.math.maxInt(i63)) return error.FrameIdOverflow;
        const id = self.next_frame_id;
        self.next_frame_id += 1;
        return id;
    }

    fn createString(self: *Self, bytes: []const u8) !Value {
        const value = try self.allocateObject(.string, bytes.len);
        const data: [*]u8 = @ptrFromInt(value);
        @memcpy(data[0..bytes.len], bytes);
        data[bytes.len] = 0;
        return value;
    }

    fn readInputInteger(self: *Self) !isize {
        if (self.input_data == null) {
            var reader = std.Io.File.stdin().readerStreaming(self.io, &.{});
            self.input_data = try readBounded(&reader, &input_buffer, error.InputTooLarge);
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

    fn appendValueText(self: *Self, value: Value, buff: *std.Io.Writer, path: *Stack(Value, 256)) anyerror!void {
        if ((value & 1) != 0) {
            const number = try unboxIntChecked(value);
            var buffer: [32]u8 = undefined;
            const bytes = try std.fmt.bufPrint(&buffer, "{d}", .{number});
            try buff.writeAll(bytes);
        } else {
            const header = try self.objectHeaderChecked(value);
            const tag = header.data_header & 7;
            if (tag == 1) {
                const length = header.data_header >> 3;
                const data: [*]const u8 = @ptrFromInt(value);
                try buff.writeByte('"');
                try buff.writeAll(data[0..length]);
                try buff.writeByte('"');
            } else if (tag == 3) {
                if (std.mem.findScalar(Value, path.data[0..path.len], value) != null) {
                    return error.CyclicValue;
                }
                if (path.len >= 256) {
                    return error.StringConversionTooDeep;
                }
                try path.push(value);
                defer path.len -= 1;

                const length = header.data_header >> 3;
                const data: [*]const Value = @ptrFromInt(value);
                try buff.writeByte('[');
                for (0..length) |i| {
                    if (i != 0) {
                        try buff.writeAll(", ");
                    }
                    try self.appendValueText(data[i], buff, path);
                }
                try buff.writeByte(']');
            } else if (tag == 5) {
                const constructor_tag: *const usize = @ptrFromInt(value);
                const id = constructor_tag.*;
                const name = std.mem.span(de_hash(@intCast(id)));
                try buff.writeAll(name);

                const count = header.data_header >> 3;
                if (std.mem.findScalar(Value, path.data[0..path.len], value) != null) {
                    return error.CyclicValue;
                }
                if (path.len >= 256) {
                    return error.StringConversionTooDeep;
                }
                try path.push(value);
                defer path.len -= 1;
                if (count > 0) {
                    try buff.writeAll(" (");
                    const data: [*]const Value = @ptrFromInt(value + 8);
                    for (0..count) |idx| {
                        if (idx != 0) {
                            try buff.writeAll(", ");
                        }
                        try self.appendValueText(data[idx], buff, path);
                    }
                    try buff.writeByte(')');
                }
            } else {
                return error.UnsupportedStringConversion;
            }
        }
    }

    fn referenceChecked(self: *Self, ref: Value) !*Value {
        if (!isReference(ref)) return error.InvalidReference;
        const fields: [*]const Value = @ptrFromInt(ref);
        const owner = fields[1];
        const index: usize = @intCast(try unboxIntChecked(fields[2]));
        if (isObject(owner)) {
            const header = try self.objectHeaderChecked(owner);
            if ((header.data_header & 7) != 7 or index >= (header.data_header >> 3) - 1) {
                return error.InvalidReference;
            }
            const captures: [*]Value = @ptrFromInt(owner + @sizeOf(Value));
            return &captures[index];
        }
        if (index == 0) {
            if (referenceInSlice(owner, self.globals)) |ptr| return ptr;
        }
        if (index == self.frame.id) {
            if (referenceInSlice(owner, self.frame.locals)) |ptr| return ptr;
            if (referenceInSlice(owner, self.frame.args)) |ptr| return ptr;
        }
        for (self.call_stack.data[0..self.call_stack.len]) |saved| {
            if (index != saved.frame.id) continue;
            if (referenceInSlice(owner, saved.frame.locals)) |ptr| return ptr;
            if (referenceInSlice(owner, saved.frame.args)) |ptr| return ptr;
        }
        return error.InvalidReference;
    }

    fn objectHeaderChecked(self: *Self, value: Value) !*const ObjectHeader {
        _ = self;
        if (!isObject(value)) return error.ExpectedStringOrArray;
        return @ptrFromInt(value - @sizeOf(ObjectHeader));
    }

    pub fn run(self: *Self) !void {
        while (true) {
            const opcode: Op = @fromBackingInt(@intCast(try self.readByte()));
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
                    const name: [:0]const u8 = tail[0..end :0];
                    const encoded: Value = @intCast(LtagHash(name.ptr));
                    const tag = try unboxIntChecked(encoded);

                    const object = try self.allocateObject(.sexp, count);
                    const constructor_tag: *usize = @ptrFromInt(object);
                    constructor_tag.* = @intCast(tag);
                    const elements: [*]Value = @ptrFromInt(object + @sizeOf(Value));
                    for (0..count) |i| {
                        elements[count - 1 - i] = try self.stackPop();
                    }
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
                    const object = try self.allocateObject(.array, elem_cnt);
                    const values: [*]Value = @ptrFromInt(object);
                    for (0..elem_cnt) |i| {
                        values[elem_cnt - 1 - i] = try self.stackPop();
                    }
                    try self.stack.push(object);
                },
                Op.ArrayPattern => {
                    const args_cnt = try self.readNonNegativeI32(error.NegativeArrayLength);
                    const value = try self.stackPop();

                    var matches = false;

                    if (isObject(value)) {
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
                    try self.stack.push(try self.createReference(@intFromPtr(&self.globals[idx]), 0));
                },
                Op.LoadAddressLocal => {
                    const idx = try self.readNonNegativeI32(error.NegativeLocalIndex);
                    if (idx >= self.frame.locals.len) {
                        return error.LocalIndexOutOfBounds;
                    }
                    try self.stack.push(try self.createReference(@intFromPtr(&self.frame.locals[idx]), self.frame.id));
                },
                Op.LoadAddressArg => {
                    const idx = try self.readNonNegativeI32(error.NegativeArgumentIndex);
                    if (idx >= self.frame.args.len) {
                        return error.ArgumentIndexOutOfBounds;
                    }
                    try self.stack.push(try self.createReference(@intFromPtr(&self.frame.args[idx]), self.frame.id));
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
                    if (idx >= self.closureValues(self.frame).len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    try self.stack.push(self.closureValues(self.frame)[idx]);
                },
                Op.LoadAddressClosure => {
                    const idx = try self.readNonNegativeI32(error.NegativeClosureIndex);
                    if (idx >= self.closureValues(self.frame).len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    try self.stack.push(try self.createReference(self.stack.data[self.frame.closure.?], idx));
                },
                Op.StoreClosure => {
                    const idx = try self.readNonNegativeI32(error.NegativeClosureIndex);
                    if (idx >= self.closureValues(self.frame).len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    self.closureValues(self.frame)[idx] = try self.stackHead();
                },
                Op.Begin, Op.CBegin => {
                    const args_count = try self.readNonNegativeI32(error.NegativeArgumentCount);
                    const locals_count = try self.readNonNegativeI32(error.NegativeLocalCount);

                    if (self.call_stack.len == 0) {
                        self.frame.args = try self.reserve(args_count);
                    } else if (args_count != self.frame.args.len) {
                        return error.ArgumentCountMismatch;
                    }
                    self.frame.locals = try self.reserve(locals_count);
                    self.frame.stack_base = self.stack.len;
                },
                Op.Closure => {
                    const addr = try self.readNonNegativeI32(error.NegativeClosureAddress);
                    const count = try self.readNonNegativeI32(error.NegativeClosureCaptureCount);

                    try self.CheckAddress(addr);
                    if (self.code[addr] != 0x52 and self.code[addr] != 0x53) {
                        return error.ClosureTargetNotFunction;
                    }

                    const object = try self.allocateObject(.closure, count + 1);
                    const function_addr: *usize = @ptrFromInt(object);
                    function_addr.* = addr;
                    const captures: [*]Value = @ptrFromInt(object + @sizeOf(Value));

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
                                if (id >= self.closureValues(self.frame).len) {
                                    @branchHint(.unlikely);
                                    return error.ClosureIndexOutOfBounds;
                                }
                                captures[idx] = self.closureValues(self.frame)[id];
                            },
                            else => return error.InvalidClosureCaptureScope,
                        }
                    }
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

                    const slot = self.stack.len - count - 1;
                    const object = self.stack.data[slot];
                    if (!isObject(object)) return error.ExpectedClosure;
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

                    const new_frame = Frame{
                        .args = self.stack.data[slot + 1 .. self.stack.len],
                        .locals = &.{},
                        .closure = slot,
                        .stack_base = self.stack.len,
                        .frame_start = slot,
                        .id = try self.nextFrameId(),
                    };

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

                    const start = self.stack.len - args_cnt;
                    const new_frame = Frame{
                        .args = self.stack.data[start..self.stack.len],
                        .locals = &.{},
                        .closure = null,
                        .stack_base = self.stack.len,
                        .frame_start = start,
                        .id = try self.nextFrameId(),
                    };
                    const saved = SavedFrame{ .frame = self.frame, .return_ip = self.ip };
                    try self.call_stack.push(saved);

                    self.frame = new_frame;
                    self.ip = addr;
                },
                Op.Tag => {
                    const offset = try self.readNonNegativeI32(error.NegativeStringOffset);
                    const count = try self.readNonNegativeI32(error.NegativeSexpFieldCount);

                    if (offset >= self.strings.len) return error.StringOffsetOutOfBounds;

                    const tail = self.strings[offset..];
                    const end = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;

                    const name: [:0]const u8 = tail[0..end :0];
                    const encoded: Value = @intCast(LtagHash(name.ptr));
                    const tag = try unboxIntChecked(encoded);
                    const value = try self.stackPop();

                    var matches = false;
                    if (isObject(value)) {
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
                    if (isObject(left) and isObject(right)) {
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

                    if (isObject(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 1;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsArray => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (isObject(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 3;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsSexp => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (isObject(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 5;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                Op.IsClosure => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (isObject(value)) {
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
                    self.stack.len = self.frame.frame_start;
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
                    var buff: std.Io.Writer = .fixed(&string_buffer);
                    var path = Stack(Value, 256).init();
                    self.appendValueText(value, &buff, &path) catch |err| {
                        return if (err == error.WriteFailed) error.StringConversionTooLarge else err;
                    };
                    const str = try self.createString(buff.buffered());
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
    var args = init.minimal.args.iterate();
    _ = args.next();
    const filename = args.next() orelse {
        std.debug.print("Usage: lama_vm <file.bc>\n", .{});
        return error.InvalidCommandLineArguments;
    };
    if (args.next() != null) {
        std.debug.print("Usage: lama_vm <file.bc>\n", .{});
        return error.InvalidCommandLineArguments;
    }
    const file = try std.Io.Dir.cwd().openFile(init.io, filename, .{});
    defer file.close(init.io);
    var reader = file.readerStreaming(init.io, &.{});
    const bytes = try readBounded(&reader, &file_buffer, error.BytecodeFileTooLarge);

    const byteCode = try checkBytecodeHeaders(bytes);

    const instruction_starts = try markInstructionStarts(byteCode.code);
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

    const anchor: *volatile usize = &gc_anchor;
    _ = anchor.*;
    __init();
    defer __shutdown();
    vm = Vm{
        .code = byteCode.code,
        .instruction_starts = instruction_starts,
        .strings = byteCode.strings,
        .ip = 0,
        .globals = &.{},
        .current_line = null,
        .io = init.io,
        .stack = .init(),
        .call_stack = .init(),
        .frame = .{
            .args = &.{},
            .locals = &.{},
            .closure = null,
            .stack_base = 1,
            .frame_start = 1,
            .id = 1,
        },
    };
    try vm.stack.push(0);
    vm.globals = try vm.reserve(byteCode.globals_count);
    vm.frame.frame_start = vm.stack.len;
    vm.frame.stack_base = vm.stack.len;
    try vm.run();
}
