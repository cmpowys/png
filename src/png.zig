const std = @import("std");
const byte_stream = @import("./byte_stream.zig");
const deflate = @import("./deflate.zig");

pub const PngError = error{ UnExpected, InvalidFormat, UnSupported };

pub const Image = struct {
    rgba: []u32,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Image) void {
        self.allocator.free(self.rgba);
    }

    pub fn initFromPngFile(allocator: std.mem.Allocator, bytes: []u8) !Image {
        return decodePng(allocator, bytes);
    }
};

const header_sequence: u64 = 0x89504e470d0a1a0a;

const ChunkType = enum(u32) {
    Hdr = 0x49484452,
    Plte = 0x504C5445,
    IDat = 0x49444154,
    IEnd = 0x49454E44,
    Gamma = 0x67414d41,
    Srgb = 0x73524742,
    Trns = 0x74524e53,
    Text = 0x74455874,
    ZText = 0x7A545874,
    IText = 0x69545874,
    Phys = 0x70485973,
    Chrm = 0x6348524D,
    Time = 0x74494d45,
};

const ChunkHeader = packed struct {
    length: u32,
    type: ChunkType,
};

const HeaderChunk = packed struct {
    width: u32,
    height: u32,
    //TODO these below can all be enums
    bitDepth: u8,
    colourType: u8,
    compressionMethod: u8,
    filterMethod: u8,
    interlaceMethod: u8,
};

const PngContext = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    arenaAllocator: std.mem.Allocator, // Memory is assumed to be freed in bulk after image is decoded
    stream: byte_stream.Stream([]u8),
    dataChunks: std.ArrayList([]u8),
    headerChunk: ?HeaderChunk,
};

fn decodePng(allocator: std.mem.Allocator, bytes: []u8) !Image {
    var arenaAllocator = std.heap.ArenaAllocator.init(allocator);
    defer arenaAllocator.deinit();

    var context = PngContext{
        .bytes = bytes,
        .stream = byte_stream.Stream([]u8).init(bytes),
        .dataChunks = std.ArrayList([]u8).init(arenaAllocator.allocator()),
        .allocator = allocator,
        .arenaAllocator = arenaAllocator.allocator(),
        .headerChunk = null,
    };

    var headerBytes = context.stream.get(u64) orelse return PngError.InvalidFormat;

    if (headerBytes != header_sequence) {
        std.log.err("Invalid header sequence in stream, expected {}, got {}", .{ header_sequence, headerBytes });
        return PngError.InvalidFormat;
    }

    var stillProcessing = true;
    while (stillProcessing) {
        var chunkHeader = context.stream.get(ChunkHeader) orelse return PngError.InvalidFormat;

        switch (chunkHeader.type) {
            .Hdr => {
                if (context.headerChunk != null) {
                    std.log.err("Multiple header chunks in PNG stream", .{});
                    return PngError.InvalidFormat;
                }

                const headerChunk = context.stream.get(HeaderChunk) orelse return PngError.InvalidFormat;

                if (headerChunk.bitDepth != 8) {
                    std.log.err("Unsupported bit depth {}, requires 8", .{headerChunk.bitDepth});
                    return PngError.UnSupported;
                }

                // TODO rest of validation here

                context.headerChunk = headerChunk;
            },
            .IDat => {
                if (context.headerChunk == null) {
                    std.log.warn("Encountered data chunk before header chunk in PNG stream", .{});
                }
                if (context.stream.bytes.len < chunkHeader.length) {
                    return PngError.InvalidFormat;
                }

                var data = context.stream.bytes[0..chunkHeader.length];
                context.stream.bytes = context.stream.bytes[chunkHeader.length..];
                try context.dataChunks.append(data);
            },
            .IEnd => {
                stillProcessing = false;
            },
            else => {
                std.log.warn("Unsupported PNG chunk type, {}, skipping ...", .{chunkHeader.type});
            },
        }
        var crc = context.stream.get(u32) orelse return PngError.InvalidFormat;
        _ = crc; // TODO use CRC to check data integrity
    }

    var deflateStream = byte_stream.Stream(ArrayOfByteSlices).init(ArrayOfByteSlices.init(context.dataChunks));
    _ = try deflate.decompress(&context.allocator, &deflateStream);
    return undefined;
}

const ArrayOfByteSlices = struct {
    bytes: std.ArrayList([]u8),
    arrayIndex: usize,
    sliceIndex: usize,

    pub fn init(bytes: std.ArrayList([]u8)) ArrayOfByteSlices {
        return ArrayOfByteSlices{
            .bytes = bytes,
            .arrayIndex = 0,
            .sliceIndex = 0,
        };
    }

    pub fn getBytes(self: *ArrayOfByteSlices, buffer: []u8) usize {

        var bytesCopied: usize = 0;
        while (bytesCopied < buffer.len and self.arrayIndex < self.bytes.items.len) {
            const bytesLeftToCopy = buffer.len - bytesCopied;
            const currentSlice = &self.bytes.items[self.arrayIndex];
            const bytesLeftInSlice = currentSlice.len - self.sliceIndex;
            const bytesToCopyFromCurrentSlice = @minimum(bytesLeftToCopy, bytesLeftInSlice);

            for(currentSlice.*[self.sliceIndex..self.sliceIndex + bytesToCopyFromCurrentSlice]) |b| {
                buffer[bytesCopied] = b;
                bytesCopied += 1;
            }
            
            if (bytesToCopyFromCurrentSlice == bytesLeftInSlice){
                self.sliceIndex = 0;
                self.arrayIndex += 1;
            } else {
                currentSlice.* = currentSlice.*[self.sliceIndex + bytesToCopyFromCurrentSlice..];
            }
        }

        return bytesCopied;
    }
};
