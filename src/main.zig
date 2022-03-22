const std = @import("std");
const win32 = @import("./win32_wrapper.zig");
const deflate = @import("./deflate.zig");

var running = true;
var graphicsBuffer: GraphicsBuffer = undefined;
var window: win32.HWND = undefined;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const instance = try win32.getCurrentInstance();
    window = try win32.createWindow(600, 600, "Test Window", windowsProcedure, instance);

    graphicsBuffer = try generateGraphicsBuffer(&allocator, 600, 600);
    @memset(graphicsBuffer.buffer.ptr, 0xA2, graphicsBuffer.width * graphicsBuffer.height * 4);
    defer allocator.free(graphicsBuffer.buffer);

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
