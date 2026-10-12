const std = @import("std");
const Io = std.Io;

comptime {
    if (@sizeOf(usize) != 8 or @sizeOf(isize) != 8) {
        @compileError("VM requires a 64-bit target");
    }
}

extern fn LtagHash(name: [*:0]const u8) i64;
extern fn de_hash(tag: i64) [*:0]const u8;

const StackSize = 1 << 15; // TODO
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

const ObjectHeader = extern struct {
    data_header: usize,
    forward_address: usize,
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
            0x01...0x03, 0x06...0x0B, 0x16, 0x17, 0x18...0x1A, 0x71, 0x04, 0x05, 0x0C, 0x0D, 0x70, 0x72, 0x1B, 0x14, 0x13, 0x73, 0x64, 0x65, 0x60, 0x61, 0x62, 0x63, 0x66 => 1,
            0x10, 0x15, 0x20, 0x21, 0x22, 0x40, 0x41, 0x42, 0x50, 0x51, 0x5A, 0x11, 0x74, 0x30, 0x31, 0x32, 0x58, 0x23, 0x33, 0x43, 0x55 => 5,
            0x52, 0x53, 0x56, 0x12, 0x57, 0x59 => 9,
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
    objects: std.AutoHashMapUnmanaged(Value, void) = .empty,

    pub fn createString(self: *Self, bytes: []const u8) !Value {
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

    pub fn appendValueText(self: *Self, value: Value, buff: *std.ArrayList(u8), path: *std.ArrayList(Value)) anyerror!void {
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

    pub fn referenceChecked(self: *Self, ref: Value) !*Value {
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

    pub fn objectHeaderChecked(self: *Self, value: Value) !*const ObjectHeader {
        if (value == 0 or (value & 1) != 0 or
            !self.objects.contains(value))
        {
            return error.ExpectedStringOrArray;
        }
        return @ptrFromInt(value - @sizeOf(ObjectHeader));
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
                0x12 => {
                    const offset = try self.readI32();
                    const count = try self.readI32();

                    if (offset < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeStringOffset;
                    }
                    const uoffset: usize = @intCast(offset);
                    if (uoffset >= self.strings.len) {
                        return error.StringOffsetOutOfBounds;
                    }
                    const tail = self.strings[uoffset..];
                    const end = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;
                    const constructor_name = tail[0..end];

                    if (count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeSexpFieldCount;
                    }
                    const ucount: usize = @intCast(count);
                    if (self.stack.len < self.frame.stack_base or
                        ucount > self.stack.len - self.frame.stack_base)
                    {
                        @branchHint(.unlikely);
                        return error.StackUnderflow;
                    }
                    const name = try self.alloc.dupeZ(u8, constructor_name);
                    const encoded: Value = @intCast(LtagHash(name.ptr));
                    const tag = try unboxIntChecked(encoded);

                    const buff = try self.alloc.alignedAlloc(u8, std.mem.Alignment.of(ObjectHeader), 24 + ucount * 8);

                    const header: *ObjectHeader = @ptrCast(buff.ptr);
                    header.data_header = (ucount << 3) | 5;
                    header.forward_address = 0;

                    const constructor_tag: *usize = @ptrCast(@alignCast(buff.ptr + 16));
                    constructor_tag.* = @intCast(tag);
                    const elements: [*]Value = @ptrCast(@alignCast(buff.ptr + 24));
                    for (0..ucount) |i| {
                        elements[ucount - 1 - i] = try self.stackPop();
                    }
                    const object = @intFromPtr(buff.ptr + @sizeOf(ObjectHeader));
                    try self.objects.put(self.alloc, object, {});
                    try self.stack.push(object);
                },
                0x11 => {
                    const offset = try self.readI32();
                    if (offset < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeStringOffset;
                    }
                    const udx: usize = @intCast(offset);
                    if (udx >= self.strings.len) {
                        @branchHint(.unlikely);
                        return error.StringOffsetOutOfBounds;
                    }
                    const tail = self.strings[udx..];
                    const end = std.mem.findScalar(u8, tail, 0) orelse return error.UnterminatedString;
                    const bytes = tail[0..end];
                    const value = try self.createString(bytes);
                    try self.stack.push(value);
                },
                0x72 => {
                    const value = try self.stackPop();
                    const header = try self.objectHeaderChecked(value);
                    const tag = header.data_header & 7;
                    const length = header.data_header >> 3;

                    if (tag == 1 or tag == 3 or tag == 5) {
                        @branchHint(.likely);
                        try self.stack.push(boxInt(@intCast(length)));
                    } else {
                        return error.ExpectedStringOrArray;
                    }
                },
                0x74 => {
                    const elem_cnt = try self.readI32();
                    if (elem_cnt < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArrayLength;
                    }
                    const ucnt: usize = @intCast(elem_cnt);
                    if (self.stack.len < self.frame.stack_base or
                        ucnt > self.stack.len - self.frame.stack_base)
                    {
                        @branchHint(.unlikely);
                        return error.StackUnderflow;
                    }
                    const len = @sizeOf(ObjectHeader) + @sizeOf(Value) * ucnt;
                    const buff = try self.alloc.alignedAlloc(u8, std.mem.Alignment.of(ObjectHeader), len);

                    const header: *ObjectHeader = @ptrCast(buff.ptr);
                    header.data_header = (ucnt << 3) | 3;
                    header.forward_address = 0;

                    for (0..ucnt) |i| {
                        const value: [*]Value = @ptrCast(@alignCast(buff.ptr + @sizeOf(ObjectHeader)));
                        value[ucnt - 1 - i] = try self.stackPop();
                    }
                    const object = @intFromPtr(buff.ptr) + @sizeOf(ObjectHeader);
                    try self.objects.put(self.alloc, object, {});
                    try self.stack.push(object);
                },
                0x58 => {
                    const args_cnt = try self.readI32();
                    if (args_cnt < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArrayLength;
                    }
                    const uargs_cnt: usize = @intCast(args_cnt);
                    const value = try self.stackPop();

                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = ((header.data_header & 7) == 3) and
                            ((header.data_header >> 3) == uargs_cnt);
                    }

                    try self.stack.push(boxInt(@intFromBool(matches)));
                },

                0x1B => {
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
                0x14 => {
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
                0x30 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeGlobalIndex;
                    }
                    const uidx: usize = @intCast(idx);
                    if (uidx >= self.globals.len) {
                        return error.GlobalIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.globals[uidx]));
                },
                0x31 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeLocalIndex;
                    }
                    const uidx: usize = @intCast(idx);
                    if (uidx >= self.frame.locals.len) {
                        return error.LocalIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.frame.locals[uidx]));
                },
                0x32 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArgumentIndex;
                    }
                    const uidx: usize = @intCast(idx);
                    if (uidx >= self.frame.args.len) {
                        return error.ArgumentIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.frame.args[uidx]));
                },
                0x13 => {
                    const new_value = try self.stackPop();
                    const ref = try self.stackPop();

                    const ptr = try self.referenceChecked(ref);
                    ptr.* = new_value;

                    try self.stack.push(new_value);
                },
                0x0A => {
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
                0x23 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeClosureIndex;
                    }
                    const uidx: usize = @intCast(idx);
                    if (uidx >= self.frame.closure.len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    try self.stack.push(self.frame.closure[uidx]);
                },
                0x33 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeClosureIndex;
                    }
                    const uidx: usize = @intCast(idx);
                    if (uidx >= self.frame.closure.len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    try self.stack.push(@intFromPtr(&self.frame.closure[uidx]));
                },
                0x43 => {
                    const idx = try self.readI32();
                    if (idx < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeClosureIndex;
                    }
                    const uidx: usize = @intCast(idx);
                    if (uidx >= self.frame.closure.len) {
                        return error.ClosureIndexOutOfBounds;
                    }
                    self.frame.closure[uidx] = try self.stackHead();
                },
                0x52, 0x53 => {
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

                    // std.debug.print("BEGIN args={d} locals={d}\n", .{
                    //     args_count, locals_count,
                    // });
                },
                0x54 => {
                    const addr = try self.readI32();
                    const count = try self.readI32();

                    if (addr < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeClosureAddress;
                    }
                    if (count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeClosureCaptureCount;
                    }
                    const uaddr: usize = @intCast(addr);
                    const ucount: usize = @intCast(count);

                    try self.CheckAddress(uaddr);
                    if (self.code[uaddr] != 0x52 and self.code[uaddr] != 0x53) {
                        return error.ClosureTargetNotFunction;
                    }

                    const buff = try self.alloc.alignedAlloc(
                        u8,
                        std.mem.Alignment.of(ObjectHeader),
                        24 + ucount * @sizeOf(Value),
                    );

                    const header: *ObjectHeader = @ptrCast(buff.ptr);
                    header.data_header = ((ucount + 1) << 3) | 7;
                    header.forward_address = 0;

                    const function_addr: *usize = @ptrCast(@alignCast(buff.ptr + 16));
                    function_addr.* = uaddr;

                    const captures: [*]Value = @ptrCast(@alignCast(buff.ptr + 24));

                    for (0..ucount) |idx| {
                        const d = try self.readByte();
                        const id = try self.readI32();
                        if (id < 0) {
                            @branchHint(.unlikely);
                            return error.NegativeClosureCaptureIndex;
                        }

                        const ud: usize = @intCast(d);
                        const uid: usize = @intCast(id);

                        if (ud == 0) {
                            if (uid >= self.globals.len) {
                                @branchHint(.unlikely);
                                return error.GlobalIndexOutOfBounds;
                            }
                            captures[idx] = self.globals[uid];
                        } else if (ud == 1) {
                            if (uid >= self.frame.locals.len) {
                                @branchHint(.unlikely);
                                return error.LocalIndexOutOfBounds;
                            }
                            captures[idx] = self.frame.locals[uid];
                        } else if (ud == 2) {
                            if (uid >= self.frame.args.len) {
                                @branchHint(.unlikely);
                                return error.ArgumentIndexOutOfBounds;
                            }
                            captures[idx] = self.frame.args[uid];
                        } else if (ud == 3) {
                            if (uid >= self.frame.closure.len) {
                                @branchHint(.unlikely);
                                return error.ClosureIndexOutOfBounds;
                            }
                            captures[idx] = self.frame.closure[uid];
                        } else {
                            return error.InvalidClosureCaptureScope;
                        }
                    }
                    const object = @intFromPtr(buff.ptr + 16);
                    try self.objects.put(self.alloc, object, {});
                    try self.stack.push(object);
                },
                0x5A => {
                    const line = try self.readI32();
                    self.current_line = line;
                },
                0x55 => {
                    const count = try self.readI32();
                    if (count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeArgumentCount;
                    }
                    const ucount: usize = @intCast(count);
                    if (self.stack.len < self.frame.stack_base or
                        ucount + 1 > self.stack.len - self.frame.stack_base)
                    {
                        return error.StackUnderflow;
                    }
                    if (self.call_stack.len >= self.call_stack.data.len) {
                        return error.CallStackOverflow;
                    }

                    var new_frame: Frame = undefined;
                    const args = try self.alloc.alloc(Value, ucount);
                    for (0..ucount) |i| {
                        args[ucount - 1 - i] = try self.stackPop();
                    }

                    const object = try self.stackPop();
                    if (!self.objects.contains(object)) {
                        return error.ExpectedClosure;
                    }
                    const header = try self.objectHeaderChecked(object);
                    const length = header.data_header >> 3;
                    if ((header.data_header & 7) != 7) return error.ExpectedClosure;
                    if (length == 0) return error.InvalidClosure;
                    const function_addr: *const usize = @ptrFromInt(object);
                    const uaddr = function_addr.*;
                    try self.CheckAddress(uaddr);
                    if (self.code[uaddr] != 0x52 and self.code[uaddr] != 0x53) {
                        return error.CallTargetNotFunction;
                    }
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
                0x57 => {
                    const offset = try self.readI32();
                    const count = try self.readI32();

                    if (offset < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeStringOffset;
                    }
                    if (count < 0) {
                        @branchHint(.unlikely);
                        return error.NegativeSexpFieldCount;
                    }
                    const uoffset: usize = @intCast(offset);
                    const ucount: usize = @intCast(count);

                    if (uoffset >= self.strings.len) {
                        return error.StringOffsetOutOfBounds;
                    }

                    const tail = self.strings[uoffset..];
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

                            matches = ((header.data_header >> 3) == ucount) and
                                (constructor_tag.* == expected_tag);
                        }
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                0x60 => {
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
                0x61 => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 1;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                0x62 => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 3;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                0x63 => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 5;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                0x66 => {
                    const value = try self.stackPop();
                    var matches = false;

                    if (self.objects.contains(value)) {
                        const header = try self.objectHeaderChecked(value);
                        matches = (header.data_header & 7) == 7;
                    }
                    try self.stack.push(boxInt(@intFromBool(matches)));
                },
                0x64 => {
                    const value = try self.stackPop();
                    try self.stack.push(boxInt(@intFromBool((value & 1) == 0)));
                },
                0x65 => {
                    const value = try self.stackPop();
                    try self.stack.push(boxInt(@intFromBool((value & 1) != 0)));
                },
                0x59 => {
                    const row = try self.readI32();
                    const column = try self.readI32();

                    if (row < 0 or column < 0) {
                        @branchHint(.unlikely);
                        return error.InvalidSourceLocation;
                    }
                    _ = try self.stackHead();
                    std.debug.print("Pattern matching failed: row = {d}, column = {d}\n", .{ row, column });
                    return error.MatchFailure;
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
                0x73 => {
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

    var vm = VM{
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
