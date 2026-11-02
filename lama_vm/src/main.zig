const std = @import("std");

comptime {
    if (@sizeOf(usize) != 8 or @sizeOf(isize) != 8) {
        @compileError("VM requires a 64-bit target");
    }
}

extern fn LtagHash(name: [*:0]const u8) Value;
extern fn Lread() Value;
extern fn Lwrite(value: Value) Value;
extern fn Llength(value: Value) Value;
extern fn Lstring(args: [*]Value) Value;
extern fn Bstring(args: [*]Value) Value;
extern fn Barray(args: [*]Value, count: Value) Value;
extern fn Bsexp(args: [*]Value, count: Value) Value;
extern fn Bclosure(args: [*]Value, count: Value) Value;
extern fn Belem(object: Value, index: Value) Value;
extern fn Bsta(object: Value, index: Value, value: Value) Value;
extern fn Btag(object: Value, tag: Value, count: Value) Value;
extern fn Barray_patt(object: Value, count: Value) Value;
extern fn Bstring_patt(left: Value, right: Value) Value;
extern fn Bstring_tag_patt(value: Value) Value;
extern fn Barray_tag_patt(value: Value) Value;
extern fn Bsexp_tag_patt(value: Value) Value;
extern fn Bclosure_tag_patt(value: Value) Value;
extern fn Bboxed_patt(value: Value) Value;
extern fn Bunboxed_patt(value: Value) Value;
extern fn __init() void;
extern fn __shutdown() void;
extern var __gc_stack_top: usize;
extern var __gc_stack_bottom: usize;

export var gc_anchor: usize linksection("custom_data") = 1;

const stack_size = 1 << 15;
const buffer_size = 64 * 1024 * 1024;
const bytecode_header_size = 3 * @sizeOf(i32);
const public_symbol_size = 2 * @sizeOf(i32) + @sizeOf(u8);
var file_buffer: [buffer_size]u8 = undefined;
var vm: Vm = undefined;
const Value = usize;

inline fn boxInt(n: isize) Value {
    return (@as(usize, @bitCast(n)) << 1) | 1;
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

const OperandStack = struct {
    const Self = @This();

    data: []Value,

    fn init(data: []Value) Self {
        data[0] = 0;
        __gc_stack_top = @intFromPtr(data.ptr);
        __gc_stack_bottom = __gc_stack_top + @sizeOf(Value);
        return .{ .data = data };
    }

    inline fn count(_: *const Self) usize {
        return (__gc_stack_bottom - __gc_stack_top) / @sizeOf(Value);
    }

    inline fn push(self: *Self, value: Value) !void {
        if (__gc_stack_bottom == @intFromPtr(self.data.ptr + self.data.len)) return error.StackOverflow;
        const slot: *Value = @ptrFromInt(__gc_stack_bottom);
        slot.* = value;
        __gc_stack_bottom += @sizeOf(Value);
    }

    inline fn pop(_: *Self) Value {
        __gc_stack_bottom -= @sizeOf(Value);
        const slot: *Value = @ptrFromInt(__gc_stack_bottom);
        return slot.*;
    }

    inline fn head(_: *const Self) Value {
        const slot: *const Value = @ptrFromInt(__gc_stack_bottom - @sizeOf(Value));
        return slot.*;
    }

    fn reserve(self: *Self, amount: usize) ![]Value {
        const start = self.count();
        if (amount > self.data.len - start) return error.StackOverflow;
        const values = self.data[start..][0..amount];
        @memset(values, 0);
        __gc_stack_bottom += amount * @sizeOf(Value);
        return values;
    }

    inline fn truncate(_: *Self, new_count: usize) void {
        __gc_stack_bottom = __gc_stack_top + new_count * @sizeOf(Value);
    }
};

const Reference = extern struct {
    captured: Value,
    owner: Value,
    index: Value,
};

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
    entry_point: usize,
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
    strings: []const u8,
    ip: usize,

    globals: []Value,
    stack: OperandStack,

    frame: Frame,
    call_stack: Stack(SavedFrame, stack_size),

    current_line: ?i32,

    next_frame_id: usize = 2,

    fn closureValues(self: *Self, frame: Frame) []Value {
        const slot = frame.closure orelse return &.{};
        const value = self.stack.data[slot];
        const header: *const ObjectHeader = @ptrFromInt(value - @sizeOf(ObjectHeader));
        const data: [*]Value = @ptrFromInt(value + @sizeOf(Value));
        return data[0 .. (header.data_header >> 3) - 1];
    }

    fn createReference(self: *Self, owner: Value, index: usize, captured: bool) !Value {
        const start = self.stack.count();
        const fields = try self.stack.reserve(@sizeOf(Reference) / @sizeOf(Value));
        const reference: *Reference = @ptrCast(@alignCast(fields.ptr));
        reference.* = .{ .captured = boxInt(@intFromBool(captured)), .owner = owner, .index = boxInt(@intCast(index)) };
        const result = Barray(fields.ptr, boxInt(@intCast(fields.len)));
        self.stack.truncate(start);
        return result;
    }

    fn unary(self: *Self, comptime operation: anytype) !void {
        const value = try self.stackHead();
        const index = self.stack.count() - 1;
        self.stack.data[index] = operation(value);
    }

    fn binary(self: *Self, comptime operation: anytype) !void {
        if (self.stack.count() - self.frame.stack_base < 2) return error.StackUnderflow;
        const index = self.stack.count() - 2;
        const result = operation(self.stack.data[index], self.stack.data[index + 1]);
        self.stack.truncate(index + 1);
        self.stack.data[index] = result;
    }

    fn nextFrameId(self: *Self) !usize {
        if (self.next_frame_id > std.math.maxInt(i63)) return error.FrameIdOverflow;
        const id = self.next_frame_id;
        self.next_frame_id += 1;
        return id;
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
    }

    inline fn stackPop(self: *Self) !Value {
        if (self.stack.count() <= self.frame.stack_base) {
            return error.StackUnderflow;
        }
        return self.stack.pop();
    }

    inline fn stackHead(self: *Self) !Value {
        if (self.stack.count() <= self.frame.stack_base) {
            return error.StackUnderflow;
        }
        return self.stack.head();
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

    fn referenceChecked(self: *Self, ref: Value) !*Value {
        const reference: *const Reference = @ptrFromInt(ref);
        const owner = reference.owner;
        const index: usize = @intCast(try unboxIntChecked(reference.index));
        if (reference.captured != boxInt(0)) {
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
                    const count = try self.readNonNegativeI32(error.NegativeSexpFieldCount);
                    if (offset >= self.strings.len) return error.StringOffsetOutOfBounds;
                    if (count > self.stack.count() - self.frame.stack_base) return error.StackUnderflow;
                    const tail = self.strings[offset..];
                    const end = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;
                    const name: [:0]const u8 = tail[0..end :0];
                    const start = self.stack.count() - count;
                    try self.stack.push(LtagHash(name.ptr));
                    const object = Bsexp(self.stack.data[start..].ptr, boxInt(@intCast(count + 1)));
                    self.stack.truncate(start);
                    try self.stack.push(object);
                },
                Op.String => {
                    const offset = try self.readNonNegativeI32(error.NegativeStringOffset);
                    if (offset >= self.strings.len) return error.StringOffsetOutOfBounds;
                    const tail = self.strings[offset..];
                    _ = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;
                    const start = self.stack.count();
                    try self.stack.push(@intFromPtr(tail.ptr));
                    const object = Bstring(self.stack.data[start..].ptr);
                    self.stack.data[start] = object;
                },
                Op.Length => {
                    try self.unary(Llength);
                },
                Op.Array => {
                    const count = try self.readNonNegativeI32(error.NegativeArrayLength);
                    if (count > self.stack.count() - self.frame.stack_base) return error.StackUnderflow;
                    const start = self.stack.count() - count;
                    const object = Barray(self.stack.data[start..].ptr, boxInt(@intCast(count)));
                    self.stack.truncate(start);
                    try self.stack.push(object);
                },
                Op.ArrayPattern => {
                    const count = try self.readNonNegativeI32(error.NegativeArrayLength);
                    const value = try self.stackHead();
                    const index = self.stack.count() - 1;
                    self.stack.data[index] = Barray_patt(value, boxInt(@intCast(count)));
                },
                Op.Elem => {
                    try self.binary(Belem);
                },
                Op.StoreElement => {
                    if (self.stack.count() - self.frame.stack_base < 2) return error.StackUnderflow;
                    const index_or_ref = self.stack.data[self.stack.count() - 2];
                    if ((index_or_ref & 1) == 0) {
                        const new_value = try self.stackPop();
                        _ = try self.stackPop();
                        const ptr = try self.referenceChecked(index_or_ref);
                        ptr.* = new_value;
                        try self.stack.push(new_value);
                    } else {
                        if (self.stack.count() - self.frame.stack_base < 3) return error.StackUnderflow;
                        const start = self.stack.count() - 3;
                        const result = Bsta(self.stack.data[start], index_or_ref, self.stack.data[start + 2]);
                        self.stack.truncate(start);
                        try self.stack.push(result);
                    }
                },
                Op.LoadAddressGlobal => {
                    const idx = try self.readNonNegativeI32(error.NegativeGlobalIndex);
                    if (idx >= self.globals.len) {
                        return error.GlobalIndexOutOfBounds;
                    }
                    try self.stack.push(try self.createReference(@intFromPtr(&self.globals[idx]), 0, false));
                },
                Op.LoadAddressLocal => {
                    const idx = try self.readNonNegativeI32(error.NegativeLocalIndex);
                    if (idx >= self.frame.locals.len) {
                        return error.LocalIndexOutOfBounds;
                    }
                    try self.stack.push(try self.createReference(@intFromPtr(&self.frame.locals[idx]), self.frame.id, false));
                },
                Op.LoadAddressArg => {
                    const idx = try self.readNonNegativeI32(error.NegativeArgumentIndex);
                    if (idx >= self.frame.args.len) {
                        return error.ArgumentIndexOutOfBounds;
                    }
                    try self.stack.push(try self.createReference(@intFromPtr(&self.frame.args[idx]), self.frame.id, false));
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
                    try self.stack.push(try self.createReference(self.stack.data[self.frame.closure.?], idx, true));
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
                        self.frame.args = try self.stack.reserve(args_count);
                    } else if (args_count != self.frame.args.len) {
                        return error.ArgumentCountMismatch;
                    }
                    self.frame.locals = try self.stack.reserve(locals_count);
                    self.frame.stack_base = self.stack.count();
                },
                Op.Closure => {
                    const addr = try self.readNonNegativeI32(error.NegativeClosureAddress);
                    const count = try self.readNonNegativeI32(error.NegativeClosureCaptureCount);

                    try self.CheckAddress(addr);
                    if (self.code[addr] != 0x52 and self.code[addr] != 0x53) {
                        return error.ClosureTargetNotFunction;
                    }

                    const start = self.stack.count();
                    const fields = try self.stack.reserve(count + 1);
                    fields[0] = addr;
                    const captures = fields[1..];

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
                    const object = Bclosure(fields.ptr, boxInt(@intCast(count)));
                    self.stack.truncate(start);
                    try self.stack.push(object);
                },
                Op.Line => {
                    self.current_line = try self.readI32();
                },
                Op.CallClosure => {
                    const count = try self.readNonNegativeI32(error.NegativeArgumentCount);
                    if (self.stack.count() < self.frame.stack_base or
                        count + 1 > self.stack.count() - self.frame.stack_base)
                    {
                        return error.StackUnderflow;
                    }
                    if (self.call_stack.len >= self.call_stack.data.len) return error.CallStackOverflow;

                    const slot = self.stack.count() - count - 1;
                    if (Bclosure_tag_patt(self.stack.data[slot]) == boxInt(0)) return error.ExpectedClosure;
                    const object = self.stack.data[slot];
                    const header: *const ObjectHeader = @ptrFromInt(object - @sizeOf(ObjectHeader));
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
                        .args = self.stack.data[slot + 1 .. self.stack.count()],
                        .locals = &.{},
                        .closure = slot,
                        .stack_base = self.stack.count(),
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
                    if (self.stack.count() < self.frame.stack_base or
                        args_cnt > self.stack.count() - self.frame.stack_base)
                    {
                        return error.StackUnderflow;
                    }
                    if (self.call_stack.len >= self.call_stack.data.len) return error.CallStackOverflow;

                    const start = self.stack.count() - args_cnt;
                    const new_frame = Frame{
                        .args = self.stack.data[start..self.stack.count()],
                        .locals = &.{},
                        .closure = null,
                        .stack_base = self.stack.count(),
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
                    const tag = LtagHash(name.ptr);
                    const value = try self.stackHead();
                    const index = self.stack.count() - 1;
                    self.stack.data[index] = Btag(value, tag, boxInt(@intCast(count)));
                },
                Op.StringEqual => {
                    try self.binary(Bstring_patt);
                },
                Op.IsString => {
                    try self.unary(Bstring_tag_patt);
                },
                Op.IsArray => {
                    try self.unary(Barray_tag_patt);
                },
                Op.IsSexp => {
                    try self.unary(Bsexp_tag_patt);
                },
                Op.IsClosure => {
                    try self.unary(Bclosure_tag_patt);
                },
                Op.IsBoxed => {
                    try self.unary(Bboxed_patt);
                },
                Op.IsUnboxed => {
                    try self.unary(Bunboxed_patt);
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
                    if (self.stack.count() > self.frame.stack_base) {
                        possibleReturnValue = try self.stackPop();
                    }
                    self.stack.truncate(self.frame.frame_start);
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
                    try self.stack.push(Lread());
                },
                Op.Write => {
                    try self.unary(Lwrite);
                },
                Op.ToString => {
                    _ = try self.stackHead();
                    const index = self.stack.count() - 1;
                    self.stack.data[index] = Lstring(self.stack.data[index..].ptr);
                },
                else => return error.InvalidOpcode,
            }
        }
    }
};

pub fn checkBytecodeHeaders(bytes: []const u8) !ByteCode {
    if (bytes.len < bytecode_header_size) {
        return error.TruncatedBytecodeHeader;
    }

    const strings_size = std.mem.readInt(i32, bytes[0..4], .little);
    const globals_count = std.mem.readInt(i32, bytes[4..8], .little);
    const public_count = std.mem.readInt(i32, bytes[8..bytecode_header_size], .little);

    if (strings_size < 0 or globals_count < 0 or public_count < 0) {
        return error.NegativeHeaderField;
    }

    const pubs: usize = @intCast(public_count);
    const strs: usize = @intCast(strings_size);
    const remaining = bytes.len - bytecode_header_size;

    if (pubs > remaining / public_symbol_size) {
        return error.TruncatedPublicSymbolTable;
    }

    const public_size = pubs * public_symbol_size;
    if (strs > remaining - public_size) {
        return error.TruncatedStringTable;
    }

    const strings_start = bytecode_header_size + public_size;
    const strings = bytes[strings_start .. strings_start + strs];
    const code_size = remaining - public_size - strs;
    var entry_point: usize = 0;

    for (0..pubs) |idx| {
        const offset = bytecode_header_size + idx * public_symbol_size;
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
        const name = strings[@intCast(string_idx)..];
        const name_end = std.mem.findScalar(u8, name, 0) orelse return error.UnterminatedPublicSymbolName;

        if (global_or_fun_idx < 0) {
            return error.NegativePublicSymbolOffset;
        }
        if (symb_type == 0) {
            if (@as(usize, @intCast(global_or_fun_idx)) >= code_size) {
                return error.PublicFunctionAddressOutOfBounds;
            }
            if (std.mem.eql(u8, name[0..name_end], "main")) entry_point = @intCast(global_or_fun_idx);
        } else if (global_or_fun_idx >= globals_count) {
            return error.PublicGlobalIndexOutOfBounds;
        }
    }
    const code_start = bytecode_header_size + public_size + strs;
    return ByteCode{ .code = bytes[code_start..], .globals_count = @intCast(globals_count), .strings = strings, .entry_point = entry_point };
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

    const anchor: *volatile usize = &gc_anchor;
    _ = anchor.*;
    __init();
    defer __shutdown();
    var operand_storage: [stack_size * 8]Value align(16) = undefined;
    vm = Vm{
        .code = byteCode.code,
        .strings = byteCode.strings,
        .ip = byteCode.entry_point,
        .globals = &.{},
        .current_line = null,
        .stack = .init(&operand_storage),
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
    vm.globals = try vm.stack.reserve(byteCode.globals_count);
    vm.frame.frame_start = vm.stack.count();
    vm.frame.stack_base = vm.stack.count();
    try vm.run();
}
