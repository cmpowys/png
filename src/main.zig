const std = @import("std");
const win32 = @import("./win32_wrapper.zig");

pub fn main() !void {
    const instance = try win32.getCurrentInstance();
    const window = try win32.createWindow(600, 600, "Test Window", windowsProcedure, instance);
    win32.showWindow(window);

    while (true) {
        var msg: win32.MSG = undefined;
        while (win32.peekMessage(&msg)) {
            win32.translateMessage(&msg);
            win32.dispatchMessage(&msg);
        }
    }
}

fn windowsProcedure(
    windowHandle: win32.HWND,
    message: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(win32.WINAPI) win32.LRESULT {
    switch (message) {
        else => {
            return win32.defaultWindowProcedure(windowHandle, message, wParam, lParam);
        },
    }
}
