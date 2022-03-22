const std = @import("std");
const Allocator = std.mem.Allocator;

const DeflateError = error{
    InvalidStream,
    UnSupported
};

pub fn decompress(allocator: *Allocator, bytes: []u8) ![]u8 {
    _ = allocator;

    var bits = BitStream.new(bytes);

    var compressionMethod = try getNextBitsWithError(&bits, 4, "Compression Method");

    if (compressionMethod != 8){
        std.log.err("Compression method = {}, expected 8", .{compressionMethod});
        return DeflateError.UnSupported;
    }

    var log2WindowSize = try getNextBitsWithError(&bits, 4, "Log 2 Window Size");
    _ = log2WindowSize; // TODO only needed if we don't store the entire stream output

    var fCheck = try getNextBitsWithError(&bits, 5, "fCheck");
    var fDict = try getNextBitsWithError(&bits, 1, "fDict");
    var fLevel = try getNextBitsWithError(&bits, 2, "fLevel");

    if (fDict == 1){
        std.log.err("FDict flag = 1, not supported", .{});
        return DeflateError.UnSupported;
    }

    // TODO check the other flags
    _ = fCheck;
    _ = fLevel;

    return bytes;
}

fn getNextBitsWithError(bits : *BitStream, numBits: u32, fieldName: []const u8) !u64 {
    return bits.getNBits(numBits) orelse {
        std.log.err("Invalid deflate header, not enough bits for '{s}'", .{fieldName});
        return DeflateError.InvalidStream;
    };
}

const BitStream = struct {
    bytes: []u8,
    bitPosition: u8,

    fn new(bytes : []u8) BitStream {
        return BitStream {
            .bytes = bytes,
            .bitPosition = 0,
        };
    }

    fn getNBits(self: *BitStream, numBits : u32) ?u64 {
        const numBitsRemaining = (self.bytes.len << 3) + (8 - self.bitPosition);
        if(numBitsRemaining < numBits) {
            return null;
        }

        var result : u64 = 0;

        // TODO make performant
        var bitNumber : u64 = 0;
        const one : u64 = 1;

        while(bitNumber < numBits) : ( bitNumber += 1) {

            const byte = self.bytes[0];
            const nextBit : u8 = if ((byte & (one << @intCast(u6, self.bitPosition))) != 0) 1 else 0;
            self.bitPosition += 1;

            result |= (nextBit << @intCast(u3, bitNumber));

            if (self.bitPosition == 8){
                self.bytes = self.bytes[1..];
                self.bitPosition = 0;
            }
        }

        return result;
    }
};

test "simple deflate stream" {
    comptime var testData = [_]u8{ 0b00011110, 0b11111000, 0b10111100, 0b01100011, 0b10011100, 0b10001000, 0b00000000, 0b00000000, 0b00110000, 0b01000000, 0b00001100, 0b11010100, 0b10101101, 0b01001010, 0b01111000, 0b11111111, 0b01101001, 0b00011100, 0b01101000, 0b01101001, 0b00111010, 0b01111000, 0b00101001, 0b11010011, 0b10110110, 0b10000000 };

    comptime { // can't be asked rewriting the above array to have the bits in the right order
        for (testData[0..]) |*byte| {
            byte.* = @bitReverse(u8, byte.*);
        }
    }

    var inputStream = testData[0..];

    var allocator = std.testing.allocator;

    var outputStream = try decompress(&allocator, inputStream);
    
    try std.testing.expect(outputStream.len > 0);
}
