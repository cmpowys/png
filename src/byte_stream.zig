const std = @import("std");

pub const Stream = struct {
    bytes: []u8, // TODO maybe have this be a generic byte stream

    pub fn init(bytes: []u8) Stream {
        return Stream{ .bytes = bytes };
    }

    pub fn getNBytes(self: *Stream, n: usize) ?[]u8 {
        if (self.bytes.len < n) {
            return null;
        }

        const result = self.bytes[0..n];
        self.bytes = self.bytes[n..];
        return result;
    }

    pub fn get(self: *Stream, comptime T: type) ?T {
        if (self.bytes.len < @sizeOf(T)) {
            return null;
        }

        return self.getUnchecked(T);
    }

    fn getUnchecked(self: *Stream, comptime T: type) T {
        var result: T = undefined;
        switch (@typeInfo(T)) {
            .Struct => {
                result = self.getStruct(T);
            },
            .Int => {
                result = self.getInt(T);
            },
            .Enum => {
                result = self.getEnum(T);
            },
            else => {
                unreachable;
            },
        }

        self.bytes = self.bytes[@sizeOf(T)..];
        return result;
    }

    fn getStruct(self: *Stream, comptime S: type) S {
        if (@typeInfo(S) != .Struct) @compileError("unexpected type, wanted Struct");

        var result: S = undefined;
        var resultPtr = &result;

        inline for (std.meta.fields(S)) |f| {
            @field(resultPtr, f.name) = self.getUnchecked(f.field_type);
        }

        return result;
    }

    fn getInt(self: *Stream, comptime I: type) I {
        if (@typeInfo(I) != .Int) @compileError("unexpected type, wanted Int");
        const result = std.mem.bytesToValue(I, self.bytes[0..@sizeOf(I)]);

        if (@import("builtin").target.cpu.arch.endian() == .Little) {
            return @byteSwap(I, result);
        } else {
            return result;
        }
    }

    fn getEnum(self: *Stream, comptime E: type) E {
        if (@typeInfo(E) != .Enum) @compileError("unexpected type wanted Enum");
        const tagTypeValue = self.getUnchecked(@typeInfo(E).Enum.tag_type);
        return @intToEnum(E, tagTypeValue); // TODO check that tag type value can be converted to enum E
    }
};
