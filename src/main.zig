const std = @import("std");
const win32 = @import("./win32_wrapper.zig");
const png = @import("./png.zig");

var running = true;
var graphicsBuffer: GraphicsBuffer = undefined;
var window: win32.HWND = undefined;

const PngViewerError = error{InvalidUsage};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // var argIterator = try std.process.ArgIterator.initWithAllocator(allocator);
    // defer argIterator.deinit();

    // var pngFileName = argIterator.next() orelse {
    //     return PngViewerError.InvalidUsage;
    // };

    var pngFileName = "D:\\code\\game\\data\\heart.png";

    var pngStream = try readPngFile(allocator, pngFileName);
    defer allocator.free(pngStream);

    var image = try png.Image.initFromPngFile(allocator, pngStream);
    defer image.deinit();

    const instance = try win32.getCurrentInstance();
    window = try win32.createWindow(@intCast(u16, image.width), @intCast(u16, image.height), "Test Window", windowsProcedure, instance);

    graphicsBuffer = try generateGraphicsBuffer(&allocator, image.width, image.height);
    @memset(graphicsBuffer.buffer.ptr, 0xFF, graphicsBuffer.width * graphicsBuffer.height * 4);
    defer allocator.free(graphicsBuffer.buffer);

    renderImageToBuffer(image, graphicsBuffer);

    try updateWindow();

    win32.showWindow(window);

    while (running) {
        var msg: win32.MSG = undefined;
        while (win32.peekMessage(&msg)) {
            win32.translateMessage(&msg);
            win32.dispatchMessage(&msg);
        }
    }
}

// TODO have to deal with endianess?
fn renderImageToBuffer(image: png.Image, buffer: GraphicsBuffer) void {
    const bytesPerPixel = 4;
    var y: isize = image.height - 1;
    while (y >= 0) : (y -= 1) {
        var x: isize = 0;
        while (x < image.width) : (x += 1) {
            const textureIndex = @intCast(usize, (y * image.width) + x);
            const bufferIndex = @intCast(usize, ((image.height - y - 1) * image.width) + x);
            const imageColour = image.rgba[textureIndex];

            var a = (imageColour & 0xff000000) >> 24;
            var b = (imageColour & 0x00ff0000) >> 16;
            var g = (imageColour & 0x0000ff00) >> 8;
            var r = imageColour & 0x000000ff;

            const bufferR = buffer.buffer[bufferIndex * bytesPerPixel];
            const bufferG = buffer.buffer[bufferIndex * bytesPerPixel + 1];
            const bufferB = buffer.buffer[bufferIndex * bytesPerPixel + 2];

            const alpha: f32 = @intToFloat(f32, a) / 255.0;
            const oneMinusAlpha = 1 - alpha;

            if (alpha == 0.0) {
                r = bufferR;
                g = bufferG;
                b = bufferB;
            } else if (alpha != 1.0) {
                r = @floatToInt(u32, std.math.floor((@intToFloat(f32, r) * alpha) + (@intToFloat(f32, bufferR) * oneMinusAlpha)));
                g = @floatToInt(u32, std.math.floor((@intToFloat(f32, g) * alpha) + (@intToFloat(f32, bufferG) * oneMinusAlpha)));
                b = @floatToInt(u32, std.math.floor((@intToFloat(f32, b) * alpha) + (@intToFloat(f32, bufferB) * oneMinusAlpha)));
            }

            buffer.buffer[bufferIndex * bytesPerPixel] = @intCast(u8, b % 255);
            buffer.buffer[bufferIndex * bytesPerPixel + 1] = @intCast(u8, g % 255);
            buffer.buffer[bufferIndex * bytesPerPixel + 2] = @intCast(u8, r % 255);
            buffer.buffer[bufferIndex * bytesPerPixel + 3] = 0;
        }
    }
}

fn readPngFile(allocator: std.mem.Allocator, filePath: [:0]const u8) ![]u8 {
    const maxBytes = 1024 * 1024 * 10;
    var file = try std.fs.cwd().openFile(filePath, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, maxBytes);
}

fn updateWindow() !void {
    try win32.blitToWindow(window, graphicsBuffer.buffer, graphicsBuffer.width, graphicsBuffer.height);
}

fn windowsProcedure(
    windowHandle: win32.HWND,
    message: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(win32.WINAPI) win32.LRESULT {
    switch (message) {
        win32.WM_PAINT => {
            var paint: win32.PAINTSTRUCT = undefined;
            win32.beginPaint(window, &paint);
            updateWindow() catch {};
            win32.endPaint(window, &paint);
            return 0;
        },
        win32.WM_CLOSE => {
            running = false;
            return win32.defaultWindowProcedure(windowHandle, message, wParam, lParam);
        },
        else => {
            return win32.defaultWindowProcedure(windowHandle, message, wParam, lParam);
        },
    }
}

const GraphicsBuffer = struct {
    width: u64,
    height: u64,
    buffer: []u8,
};

fn generateGraphicsBuffer(allocator: *const std.mem.Allocator, width: u64, height: u64) !GraphicsBuffer {
    var buffer = try allocator.alloc(u8, width * height * 4);
    return GraphicsBuffer{ .width = width, .height = height, .buffer = buffer };
}
