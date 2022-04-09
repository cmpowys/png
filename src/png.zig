const std = @import("std");
const byte_stream = @import("./byte_stream.zig");
const deflate = @import("./deflate.zig");

pub const PngError = error{ UnExpected, InvalidFormat, UnSupported };

pub const Image = struct {
    rgba: []u32,
    width: u32,
    height: u32,
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
    ToBeDetermined1 = 0x63614E76,
    ToBeDetermined2 = 0x624B4744,
};

const FilterMethod = enum(u8) { None = 0, Left = 1, Up = 2, Average = 3, Paeth = 4 };

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

const PalletEntry = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn new() PalletEntry {
        return PalletEntry{
            .r = 0,
            .g = 0,
            .b = 0,
            .a = 255,
        };
    }

    fn insertFromBytes(self: *PalletEntry, colour: u24) void {
        self.r = @intCast(u8, colour & 0xff0000 >> 16);
        self.g = @intCast(u8, colour & 0x00ff00 >> 8);
        self.b = @intCast(u8, colour & 0x0000ff);
    }
};

const max_pallet_size = 256;

const PalletInformation = struct {
    entries: [max_pallet_size]PalletEntry,
    palletSize: u32,
    transparencySize: u32,
    palletUsesAlpha: bool,

    fn new() PalletInformation {
        var info = PalletInformation{
            .palletSize = 0,
            .transparencySize = 0,
            .palletUsesAlpha = false,
            .entries = undefined,
        };

        for (info.entries) |*entry| {
            entry.* = PalletEntry.new();
        }

        return info;
    }
};

const PngContext = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    arenaAllocator: std.mem.Allocator, // Memory is assumed to be freed in bulk after image is decoded
    stream: byte_stream.Stream([]u8),
    dataChunks: std.ArrayList([]u8),
    headerChunk: ?HeaderChunk,
    palletInformation: PalletInformation,
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
        .palletInformation = PalletInformation.new(),
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
                if (context.headerChunk == null) {
                    std.log.warn("Encountered end chunk before header chunk in PNG stream", .{});
                }

                if (context.dataChunks.items.len == 0) {
                    std.log.warn("Encountered end chunk before data chunk in PNG stream", .{});
                }
                stillProcessing = false;
            },
            .Plte => {
                const palletSizeInBytes = chunkHeader.length;
                if (palletSizeInBytes % 3 != 0) {
                    std.log.err("In PNG pallet chunk: got {} pallet size not divisible by 3", .{palletSizeInBytes});
                    return PngError.InvalidFormat;
                }

                context.palletInformation.palletSize = palletSizeInBytes / 3;
                const palletEntries = context.stream.getBytesAsConstSlice(u24, context.palletInformation.palletSize) orelse unreachable;
                for (palletEntries) |entryAsU24, i| {
                    context.palletInformation.entries[i].insertFromBytes(entryAsU24);
                }
            },
            .Trns => {
                context.palletInformation.transparencySize = chunkHeader.length;
                const alphaBytes = context.stream.getBytesAsConstSlice(u8, chunkHeader.length) orelse return PngError.InvalidFormat;
                var index: usize = 0;
                while (index < context.palletInformation.transparencySize) : (index += 1) {
                    context.palletInformation.entries[index].a = alphaBytes[index];
                }
                context.palletInformation.palletUsesAlpha = true;
            },
            else => {
                std.log.warn("Unsupported PNG chunk type, {}, skipping ...", .{chunkHeader.type});
                context.stream.bytes = context.stream.bytes[chunkHeader.length..];
            },
        }
        var crc = context.stream.get(u32) orelse return PngError.InvalidFormat;
        _ = crc; // TODO use CRC to check data integrity
    }

    var deflateStream = byte_stream.Stream(ArrayOfByteSlices).init(ArrayOfByteSlices.init(context.dataChunks));
    var deflateOutput = try deflate.decompress(&context.allocator, &deflateStream);
    return unfilter(&context, &byte_stream.Stream([]u8).init(deflateOutput));
}

fn unfilter(context: *PngContext, stream: *byte_stream.Stream([]u8)) !Image {
    _ = context;
    _ = stream;

    const header = context.headerChunk orelse unreachable;
    const width = header.width;
    const height = header.height;

    if (width == 0 or height == 0) { // TODO apply validation earlier
        return PngError.InvalidFormat;
    }

    const rgba = try context.allocator.alloc(u32, width * height);
    errdefer context.allocator.free(rgba);

    const image = Image{
        .rgba = rgba,
        .width = width,
        .height = height,
        .allocator = context.allocator,
    };

    // TODO performance and cleanup/refactor
    const numScanLines = height;
    var scanLineIndex: usize = 0;
    var prevRow: []u8 = undefined;
    const usesPalletData = header.colourType == 3; // TODO use enum
    const usesDefaultAlpha = (header.colourType == 2) or (header.colourType == 3 and !context.palletInformation.palletUsesAlpha);

    while (scanLineIndex < numScanLines) : (scanLineIndex += 1) {
        const filterMethod = stream.get(FilterMethod) orelse return PngError.InvalidFormat;
        const imageRow = std.mem.sliceAsBytes(image.rgba[(scanLineIndex * width)..((scanLineIndex + 1) * width)]);
        var colourPosition: usize = 0;

        while (colourPosition < width) : (colourPosition += 1) {
            var palletEntry: PalletEntry = undefined;

            if (usesPalletData) {
                const palletEntryIndex = stream.get(u8) orelse return PngError.InvalidFormat;
                palletEntry = context.palletInformation.entries[palletEntryIndex];
            }

            var bytePosition: usize = 0;
            while (bytePosition < 4) : (bytePosition += 1) {
                var toAdd: u8 = 0;
                const byteIndex = (colourPosition * 4) + bytePosition;
                const prevByte = if (byteIndex < 4) 0 else imageRow[byteIndex - 4];
                const upByte = if (scanLineIndex == 0) 0 else prevRow[byteIndex];

                if (usesDefaultAlpha and bytePosition == 3) {
                    imageRow[byteIndex] = 255;
                } else {
                    switch (filterMethod) {
                        .None => {},
                        .Up => {
                            toAdd = upByte;
                        },
                        .Left => {
                            toAdd = prevByte;
                        },
                        .Average => {
                            toAdd = @intCast(u8, (((@intCast(u16, prevByte) + @intCast(u16, upByte)) >> 1) % 256));
                        },
                        .Paeth => {
                            const aboveLeft: u8 = if (scanLineIndex == 0 or byteIndex < 4) 0 else prevRow[(byteIndex - 4)];
                            toAdd = paethPredictor(prevByte, upByte, aboveLeft);
                        },
                    }

                    var filteredByte : u8 = undefined;
                    if (usesPalletData) {
                        filteredByte = switch (bytePosition) {
                            0 => palletEntry.r,
                            1 => palletEntry.g,
                            2 => palletEntry.b,
                            3 => palletEntry.a,
                            else => unreachable,
                        };
                    } else {
                        filteredByte = stream.get(u8) orelse return PngError.InvalidFormat;
                    }

                    const byteToInsert = filteredByte +% toAdd;
                    imageRow[byteIndex] = @intCast(u8, byteToInsert);
                }
            }
        }

        prevRow = imageRow;
    }

    return image;
}

fn paethPredictor(left: u8, up: u8, aboveLeft: u8) u8 {
    const p: i64 = @intCast(i64, left) + @intCast(i64, up) - @intCast(i64, aboveLeft);
    const pa: u64 = std.math.absCast(p - @intCast(i64, left));
    const pb: u64 = std.math.absCast(p - @intCast(i64, up));
    const pc: u64 = std.math.absCast(p - @intCast(i64, aboveLeft));

    return if (pa <= pb and pa <= pc) left else if (pb <= pc) up else aboveLeft;
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

            for (currentSlice.*[self.sliceIndex .. self.sliceIndex + bytesToCopyFromCurrentSlice]) |b| {
                buffer[bytesCopied] = b;
                bytesCopied += 1;
            }

            if (bytesToCopyFromCurrentSlice == bytesLeftInSlice) {
                self.sliceIndex = 0;
                self.arrayIndex += 1;
            } else {
                currentSlice.* = currentSlice.*[self.sliceIndex + bytesToCopyFromCurrentSlice ..];
            }
        }

        return bytesCopied;
    }
};
