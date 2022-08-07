const std = @import("std");

pub fn Stream(comptime Bytes: type) type {
    return struct {
        bytes: Bytes,

        pub fn init(bytes: Bytes) Stream(Bytes) {
            return Stream(Bytes){ .bytes = bytes };
        }

        pub fn get(self: *Stream(Bytes), comptime T: type) ?T {
            switch (@typeInfo(T)) {
                .Struct => {
                    return self.getStruct(T);
                },
                .Int => {
                    return self.getInt(T);
                },
                .Enum => {
                    return self.getEnum(T);
                },
                else => {
                    unreachable;
                },
            }
        }

        pub fn getBytes(self: *Stream(Bytes), buffer: []u8) ?void {
            var bytesReturned: usize = undefined;
            if (Bytes == []u8) {
                bytesReturned = getBytesFromSlice(&self.bytes, buffer);
            } else {
                bytesReturned = self.bytes.getBytes(buffer);
            }

            if (bytesReturned != buffer.len) {
                return null;
            }
        }

        pub fn getBytesAsConstSlice(self: *Stream(Bytes), comptime I: type, count: usize) ?[]const align(1) I {
            if (@typeInfo(I) != .Int) {
                @compileError("unexpected type, wanted Int");
            }

            if (Bytes == []u8) {
                const numBytes = (@bitSizeOf(I)/8) * count;
                if (self.bytes.len < numBytes) {
                    return null;
                }
                // TODO there has to be a better way to convert a slice of []u8 to []I?
                const result = self.bytes[0..numBytes];
                self.bytes = self.bytes[numBytes..];
                if (I == u8){
                    return result;
                }

                return std.mem.bytesAsSlice(I, result);
                //return @ptrCast([*]I, result.ptr) [0..count];
            } else {
                @compileError("Not implemented");
            }
        }

        fn getStruct(self: *Stream(Bytes), comptime S: type) ?S {
            if (@typeInfo(S) != .Struct) @compileError("unexpected type, wanted Struct");

            var result: S = undefined;
            var resultPtr = &result;

            inline for (std.meta.fields(S)) |f| {
                @field(resultPtr, f.name) = self.get(f.field_type) orelse return null;
            }

            return result;
        }

        fn getInt(self: *Stream(Bytes), comptime I: type) ?I {
            if (@typeInfo(I) != .Int) @compileError("unexpected type, wanted Int");

            var intBuffer: [@sizeOf(I)]u8 = undefined;
            self.getBytes(intBuffer[0..@sizeOf(I)]) orelse return null;
            const result = std.mem.bytesToValue(I, intBuffer[0..@sizeOf(I)]);

            if (@import("builtin").target.cpu.arch.endian() == .Little) {
                return @byteSwap(I, result);
            } else {
                return result;
            }
        }

        fn getEnum(self: *Stream(Bytes), comptime E: type) ?E {
            if (@typeInfo(E) != .Enum) @compileError("unexpected type wanted Enum");
            const tagTypeValue = self.get(@typeInfo(E).Enum.tag_type) orelse return null;
            return @intToEnum(E, tagTypeValue); // TODO check that tag type value can be converted to enum E
        }
    };
}

fn getBytesFromSlice(stream: *[]u8, buffer: []u8) usize {
    const bytesToCopy = @minimum(buffer.len, stream.len);

    if (bytesToCopy == 0) {
        return 0;
    }

    for (stream.*[0..bytesToCopy]) |b, i| {
        buffer[i] = b;
    }

    stream.* = stream.*[bytesToCopy..];
    return bytesToCopy;
}
