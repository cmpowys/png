const std = @import("std");
const byte_stream = @import("./byte_stream.zig");
const Allocator = std.mem.Allocator;

pub const DeflateError = error{ InvalidStream, UnSupported, UnExpected };

pub fn decompress(allocator: *Allocator, bytes: anytype) ![]u8 { // TODO make output a stream?
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();

    const header = try getDeflateHeader(bytes);

    if (header.compressionMethod != 8) {
        std.log.err("Compression method = {}, expected 8", .{header.compressionMethod});
        return DeflateError.UnSupported;
    }

    if (header.fDict == 1) {
        std.log.err("FDict flag = 1, not supported", .{});
        return DeflateError.UnSupported;
    }

    // TODO check the other header fields

    var output = std.ArrayList(u8).init(allocator.*);
    errdefer output.clearAndFree();

    while (try processBlock(bytes, &output, &arena)) {}

    return output.toOwnedSlice();
}

const BlockType = enum(u8) { UnCompressed = 0, Fixed = 1, Dynamic = 2, Err = 3 };

const BlockHeader = struct { isFinal: bool, blockType: BlockType };

const DeflateHeader = struct { compressionMethod: u8, log2WindowSize: u8, fCheck: u8, fDict: u8, fLevel: u8 };

const HuffTrees = struct { litCodes: *HuffNode, distCodes: *HuffNode };

const HuffNode = struct {
    value: i16,
    left: ?*HuffNode,
    right: ?*HuffNode,

    fn new(allocator: std.mem.Allocator) !*HuffNode {
        var result = try allocator.create(HuffNode);
        result.left = null;
        result.right = null;
        result.value = -1;
        return result;
    }

    // TODO put the other huffnode related methods in here like getnextcode etc.addHuffNode
};

const max_code_length_table_length = 19;
const max_lit_length_table_length = 286;
const max_dist_length_table_length = 32;

fn getDeflateHeader(bits: anytype) !DeflateHeader { // TODO could just make the DeflateHeader a packed struct and cast it to the first two bytes of the byte stream
    var compressionMethod = try getNextBitsWithError(bits, 4, "Compression Method");
    var log2WindowSize = try getNextBitsWithError(bits, 4, "Log 2 Window Size");
    var fCheck = try getNextBitsWithError(bits, 5, "fCheck");
    var fDict = try getNextBitsWithError(bits, 1, "fDict");
    var fLevel = try getNextBitsWithError(bits, 2, "fLevel");

    return DeflateHeader{ .compressionMethod = @intCast(u8, compressionMethod), .log2WindowSize = @intCast(u8, log2WindowSize), .fCheck = @intCast(u8, fCheck), .fDict = @intCast(u8, fDict), .fLevel = @intCast(u8, fLevel) };
}

fn getBlockHeader(bits: anytype) !BlockHeader {
    var isFinal = try getNextBitsWithError(bits, 1, "IsFinalBlock");
    var blockType = try getNextBitsWithError(bits, 2, "BlockType");
    return BlockHeader{ .isFinal = isFinal == 1, .blockType = @intToEnum(BlockType, blockType) };
}

fn processBlock(bits: anytype, output: *std.ArrayList(u8), arena: *std.heap.ArenaAllocator) !bool {
    _ = output;
    const blockHeader = try getBlockHeader(bits);

    switch (blockHeader.blockType) {
        BlockType.UnCompressed => {},
        BlockType.Fixed => {
            const huffTrees = try getFixedHuffTrees(arena);
            try decompressRestOfBlock(bits, output, huffTrees);
        },
        BlockType.Dynamic => {
            const huffTrees = try getDynamicHuffTrees(arena, bits);
            try decompressRestOfBlock(bits, output, huffTrees);
        },
        else => {
            std.log.err("Deflate block header has block type : 3, which is an error", .{});
            return DeflateError.InvalidStream;
        },
    }

    return !blockHeader.isFinal;
}

fn decompressRestOfBlock(bits: anytype, output: *std.ArrayList(u8), huffTrees: HuffTrees) !void {

    // TODO simplify table with a 2d array
    const baseLengthsForDistanceCodes = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const extraLengthsForDistanceCodes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    const baseDistanceForDistanceCodes = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
    const extraDistanceForDistanceCodes = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

    while (true) {
        const litCode = try getNextCode(huffTrees.litCodes, bits);

        if (litCode < 256) {
            try output.append(@intCast(u8, litCode));
        } else if (litCode == 256) {
            return;
        } else {
            const litIndex = litCode - 257;
            const baseLength = baseLengthsForDistanceCodes[litIndex];
            const numExtraLengthBits = extraLengthsForDistanceCodes[litIndex];
            const extraLength = try getNextBitsWithError(bits, numExtraLengthBits, "LitCode Extra Length Bits");
            const length = baseLength + extraLength;

            const distCode = try getNextCode(huffTrees.distCodes, bits);
            const baseDistance = baseDistanceForDistanceCodes[distCode];
            const numExtraDistanceBits = extraDistanceForDistanceCodes[distCode];
            const extraDistance = try getNextBitsWithError(bits, numExtraDistanceBits, "DistCode Extra Distance Bits");
            const distance = baseDistance + extraDistance;

            const outputSize = output.items.len;
            if (outputSize - distance < 0) {
                std.log.err("Unexpected ditance calculated decompressing block, current output size is {}, distance calculated is {}", .{ outputSize, distance });
                return DeflateError.UnExpected;
            }

            var outputPosition: usize = 0;
            while (outputPosition < length) : (outputPosition += 1) {
                const literal: u8 = output.items[outputSize - distance + outputPosition];
                try output.append(literal);
            }
        }
    }
}

fn getDynamicHuffTrees(arena: *std.heap.ArenaAllocator, bits: anytype) !HuffTrees {
    const numberOfLiteralLengthCodes = (try getNextBitsWithError(bits, 5, "Number Of Literal Length Codes")) + 257;
    const numberOfDistanceCodes = (try getNextBitsWithError(bits, 5, "Number Of Distance Codes")) + 1;
    const numberOfCodeLengthCodes = (try getNextBitsWithError(bits, 4, "Number Of Code Length Codes")) + 4;

    const codeLengthEncoding = try getCodeLengthCodes(arena, bits, numberOfCodeLengthCodes);
    const codeHuffTree = try generateHuffmanTree(arena, codeLengthEncoding);

    const encodedLitCodes = try getEncodedHuffCodes(bits, arena, codeHuffTree, numberOfLiteralLengthCodes);
    const litCodeTree = try generateHuffmanTree(arena, encodedLitCodes);

    const encodedDistCodes = try getEncodedHuffCodes(bits, arena, codeHuffTree, numberOfDistanceCodes);
    const distCodeTree = try generateHuffmanTree(arena, encodedDistCodes);

    return HuffTrees{
        .litCodes = litCodeTree,
        .distCodes = distCodeTree,
    };
}

fn getCodeLengthCodes(arena: *std.heap.ArenaAllocator, bits: anytype, numberOfCodeLengthCodes: usize) ![]u32 {
    const codeLengthTableOrdering = [_]usize{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

    var codeLengthEncoding = try arena.allocator().alloc(u32, max_code_length_table_length);
    for (codeLengthEncoding) |*code| {
        code.* = 0;
    }

    var codeLengthIndex: usize = 0;
    while (codeLengthIndex < numberOfCodeLengthCodes) : (codeLengthIndex += 1) {
        const actualCodeLengthIndex = codeLengthTableOrdering[codeLengthIndex];
        const codeLength = @intCast(u32, try getNextBitsWithError(bits, 3, "Code Length"));
        codeLengthEncoding[actualCodeLengthIndex] = codeLength;
    }

    return codeLengthEncoding;
}

fn getEncodedHuffCodes(bits: anytype, arena: *std.heap.ArenaAllocator, huffTree: *HuffNode, numCodesExpected: usize) ![]u32 {
    std.debug.assert(numCodesExpected > 0);

    var codes = try std.ArrayList(u32).initCapacity(arena.allocator(), numCodesExpected);
    var prevCode: u32 = 0;

    while (codes.items.len < numCodesExpected) {
        var code: u32 = try getNextCode(huffTree, bits);
        var repeats: u64 = 1;

        if (code > 15) {
            switch (code) {
                16 => {
                    code = prevCode;
                    repeats = (try getNextBitsWithError(bits, 2, "HuffMan Repeats")) + 3;
                },
                17 => {
                    code = 0;
                    repeats = (try getNextBitsWithError(bits, 3, "HuffMan Repeats")) + 3;
                },
                18 => {
                    code = 0;
                    repeats = (try getNextBitsWithError(bits, 7, "HuffMan Repeats")) + 11;
                },
                else => {
                    std.log.debug("Unexpected code generated from huffman tree {}, should be < 19", .{code});
                    return DeflateError.UnExpected;
                },
            }
        }
        try codes.appendNTimes(code, repeats);
        prevCode = code;
    }

    if (codes.items.len > numCodesExpected) {
        std.log.err("When trying to decode a dynamic huffman tree, we processed {} codes but expected {}", .{ codes.items.len, numCodesExpected });
        return DeflateError.UnExpected;
    }

    return codes.toOwnedSlice();
}

fn getFixedHuffTrees(arena: *std.heap.ArenaAllocator) !HuffTrees {
    var huffTrees: HuffTrees = undefined;
    comptime var encodedLitCodes: [max_lit_length_table_length]u32 = undefined;
    comptime var encodedDistCodes: [max_dist_length_table_length]u32 = undefined;

    comptime {
        for (encodedLitCodes[0..144]) |*val| {
            val.* = 8;
        }

        for (encodedLitCodes[144..256]) |*val| {
            val.* = 9;
        }

        for (encodedLitCodes[256..280]) |*val| {
            val.* = 7;
        }

        for (encodedLitCodes[280..]) |*val| {
            val.* = 8;
        }

        for (encodedDistCodes[0..]) |*val| {
            val.* = 5;
        }
    }

    // TODO need a comptime allocator so this can all be done in comptime
    huffTrees.litCodes = try generateHuffmanTree(arena, encodedLitCodes[0..]);
    huffTrees.distCodes = try generateHuffmanTree(arena, encodedDistCodes[0..]);

    return huffTrees;
}

fn generateHuffmanTree(arena: *std.heap.ArenaAllocator, codes: []u32) !*HuffNode {
    std.debug.assert(codes.len > 0);

    var codeCounts = try getCodeCounts(arena, codes);

    var huffTree = try arena.allocator().create(HuffNode);
    huffTree = try HuffNode.new(arena.allocator());

    var codeLength: u32 = 1;
    while (codeLength < codeCounts.maxCodeLength + 1) : (codeLength += 1) {
        if (codeCounts.codeCount[codeLength] == 0)
            continue;

        for (codes) |code, codeIndex| {
            if (code != codeLength)
                continue;

            try addHuffNode(huffTree, arena, codeLength, codeCounts.nextCode[codeLength], @intCast(i16, codeIndex));
            codeCounts.nextCode[codeLength] += 1;
        }
    }

    return huffTree;
}

const CodeCounts = struct {
    codeCount: []u32,
    nextCode: []u32,
    maxCodeLength: u32,
};

fn getCodeCounts(arena: *std.heap.ArenaAllocator, codes: []u32) !CodeCounts {
    var maxCodeLength: u32 = codes[0];

    for (codes) |encodingLength| {
        maxCodeLength = @maximum(maxCodeLength, encodingLength);
    }

    var codeCount = try arena.allocator().alloc(u32, maxCodeLength + 1);
    for (codeCount) |*count| {
        count.* = 0;
    }

    for (codes) |encodingLength| {
        if (encodingLength > 0) {
            codeCount[encodingLength] += 1;
        }
    }

    var nextCode = try arena.allocator().alloc(u32, maxCodeLength + 1);
    for (nextCode) |*code| {
        code.* = 0;
    }

    var codeLength: usize = 1;
    var code: u32 = 0;
    while (codeLength < maxCodeLength + 1) : (codeLength += 1) {
        code = (code + codeCount[codeLength - 1]) << 1;
        nextCode[codeLength] = code;
    }

    return CodeCounts{ .codeCount = codeCount, .nextCode = nextCode, .maxCodeLength = maxCodeLength };
}

fn getNextCode(huffTree: *HuffNode, bits: anytype) !u16 {
    var root = huffTree;
    while (true) {
        if (root.value >= 0) {
            return @intCast(u16, root.value);
        } else if (root.right == null and root.left == null) {
            std.log.err("Unexepcted error when generating huffman codes", .{});
            return DeflateError.UnExpected;
        }

        const nextBit = bits.getNBits(1) orelse {
            std.log.err("Unexepcted end of deflate stream", .{});
            return DeflateError.UnExpected;
        };

        std.debug.assert(nextBit < 2);
        const isZero = nextBit == 0;

        if (isZero) {
            root = root.left orelse {
                std.log.err("Unexpected bit value when generate huffman codes in deflate stream", .{});
                return DeflateError.UnExpected;
            };
        } else {
            root = root.right orelse {
                std.log.err("Unexpected bit value when generate huffman codes in deflate stream", .{});
                return DeflateError.UnExpected;
            };
        }
    }
}

fn addHuffNode(huffTree: *HuffNode, arena: *std.heap.ArenaAllocator, codeLength: u32, code: u32, value: i16) !void {
    std.debug.assert(codeLength > 0);
    std.debug.assert(value >= 0);

    var depth: u64 = 0;
    var root = huffTree;
    while (depth < codeLength) {
        if (root.value != -1) {
            std.log.err("Error when trying to add code {}, with length {}, value {}, reached unexpected terminal node {}", .{ code, codeLength, value, root.value });
            return DeflateError.UnExpected;
        }

        const one: u64 = 1;
        const isZero = (code & (one << (@intCast(u6, codeLength - depth - 1)))) == 0; // TODO clean up these integer widths and messy casts

        if (isZero) {
            if (root.left == null) {
                root.left = try HuffNode.new(arena.allocator());
            }
            root = root.left orelse unreachable;
        } else {
            if (root.right == null) {
                root.right = try HuffNode.new(arena.allocator());
            }
            root = root.right orelse unreachable;
        }

        depth += 1;
    }

    if (root.left != null or root.right != null or root.value != -1) {
        std.log.err("Error when trying to create huffman tree for code  {}, length {}, value {} expected terminal node", .{ code, codeLength, value });
        return DeflateError.UnExpected;
    }

    root.value = value;
}

fn getNextBitsWithError(bits: anytype, numBits: u32, fieldName: []const u8) !u64 {
    return bits.getNBits(numBits) orelse {
        std.log.err("Invalid deflate header, not enough bits for '{s}'", .{fieldName});
        return DeflateError.InvalidStream;
    };
}

test "simple deflate stream" {
    try runTestCase();
}

fn runTestCase() !void {
    comptime var testData = [_]u8{ 0b00011110, 0b11111000, 0b10111100, 0b01100011, 0b10011100, 0b10001000, 0b00000000, 0b00000000, 0b00110000, 0b01000000, 0b00001100, 0b11010100, 0b10101101, 0b01001010, 0b01111000, 0b11111111, 0b01101001, 0b00011100, 0b01101000, 0b01101001, 0b00111010, 0b01111000, 0b00101001, 0b11010011, 0b10110110, 0b10000000 };

    comptime { // can't be asked rewriting the above array to have the bits in the right order
        for (testData[0..]) |*byte| {
            byte.* = @bitReverse(u8, byte.*);
        }
    }

    const expectedString = [_]u8{ 'A', 'B', 'C', 'D', 'E', 'A', 'B', 'C', 'D', ' ', 'A', 'B', 'C', 'D', 'E', 'A', 'B', 'C', 'D' };

    var inputStream = byte_stream.Stream([]u8).init(testData[0..]);

    var allocator = std.testing.allocator;

    var outputStream = try decompress(&allocator, &inputStream);
    defer allocator.free(outputStream);

    try std.testing.expect(outputStream.len == expectedString.len);
    try std.testing.expectEqualSlices(u8, outputStream, expectedString[0..]);
}
