const std = @import("std");
const win32 = @import("./win32.zig");

pub fn main() !void {
    const instance = try getWindowsInstance();
    const window = try win32.createWindow(instance, windowsProcedure, 400, 400, "PNG Viewer");
    win32.showWindow(window);
    while (true) {}
}

fn getWindowsInstance() !win32.InstanceHandle {
    return try win32.getModuleHandleA(null);
}

fn windowsProcedure(
    window: win32.WindowHandle,
    message: u32,
    wParam: usize,
    lParam: isize,
) callconv(win32.winapi_calling_conv) isize {
    return win32.defaultWindowsProcedure(window, message, wParam, lParam);
}
