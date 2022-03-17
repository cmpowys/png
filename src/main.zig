const std = @import("std");
const win32 = @import("./win32.zig");

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var allocator = &std.heap.FixedBufferAllocator.init(&buffer).allocator();

    unwrappedMain() catch |e| {
        if (e == error.WindowsError) {
            printWindowsError(allocator);
            return;
        } else {
            return e;
        }
    };
}

fn unwrappedMain() anyerror!void {
    const instance = try getWindowsInstance();
    const window = try win32.createWindow(instance, windowsProcedure, 400, 400, "PNG Viewer");
    win32.showWindow(window);

    while (true) {}
}

fn getWindowsInstance() !win32.InstanceHandle {
    return try win32.getModuleHandleA(null);
}

fn printWindowsError(allocator: *std.mem.Allocator) void {
    const errorCode = win32.getLastError();

    std.debug.assert(errorCode != win32.Win32ErrorCode.SUCCESS);

    const errorMessage = win32.getErrorMessage(errorCode, allocator) catch |e| switch (e) {
        error.WindowsError => {
            std.log.err("Windows Error Code: {}", .{errorCode});
            return;
        },
        error.OutOfMemory => {
            std.log.err("Windows Error Code: {}, buffer too small to contain system message", .{errorCode});
            return;
        },
    };
    defer (allocator.free(errorMessage));
    std.log.err("Windows Error: {s}", .{errorMessage});
}

fn windowsProcedure(
    window: win32.WindowHandle,
    message: u32,
    wParam: usize,
    lParam: isize,
) callconv(win32.winapi_calling_conv) isize {
    return win32.defaultWindowsProcedure(window, message, wParam, lParam);
}
