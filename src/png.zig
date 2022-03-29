const std = @import("std");
const byte_stream = @import("./byte_stream.zig");

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
    stream: byte_stream.Stream,
    dataChunks: std.ArrayList([]u8),
    headerChunk: ?HeaderChunk,
};

fn decodePng(allocator: std.mem.Allocator, bytes: []u8) !Image {
    var arenaAllocator = std.heap.ArenaAllocator.init(allocator);
    defer arenaAllocator.deinit();

    var context = PngContext{
        .bytes = bytes,
        .stream = byte_stream.Stream.init(bytes),
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
                    std.log.err("Unsupported bith depth {}, requires 8", .{headerChunk.bitDepth});
                    return PngError.UnSupported;
                }

                // TODO rest of validation here

                context.headerChunk = headerChunk;
            },
            .IDat => {
                if (context.headerChunk == null) {
                    std.log.warn("Encountered data chunk before data chunk in PNG stream", .{});
                }
                var data = context.stream.getNBytes(chunkHeader.length) orelse return PngError.InvalidFormat;
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

    return undefined;
}