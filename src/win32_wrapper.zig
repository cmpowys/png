const win32 = @import("win32").everything;
const std = @import("std");

pub const WindowsError = error{Win32Error};
pub const HWND = win32.HWND;
pub const WNDPROC = win32.WNDPROC;
pub const LPARAM = win32.LPARAM;
pub const WPARAM = win32.WPARAM;
pub const WINAPI = std.os.windows.WINAPI;
pub const LRESULT = win32.LPARAM;
pub const HINSTANCE = win32.HINSTANCE;
pub const MSG = win32.MSG;

pub const WM_CLOSE = win32.WM_CLOSE;

pub const defaultWindowProcedure = win32.DefWindowProcW;

pub fn getCurrentInstance() !win32.HINSTANCE {
    return win32.GetModuleHandleW(null) orelse printAndReturnError("Getting current instance");
}

pub fn showWindow(window: HWND) void {
    _ = win32.ShowWindow(window, win32.SHOW_WINDOW_CMD.SHOWNORMAL);
}

pub fn createWindow(clientWidth: u16, clientHeight: u16, comptime windowTitle: [:0]const u8, winProc: win32.WNDPROC, instance: win32.HINSTANCE) !HWND {
    comptime var windowTitleW = win32.L(windowTitle);
    comptime var styleFlags = @enumToInt(win32.CS_HREDRAW) | @enumToInt(win32.CS_VREDRAW) | @enumToInt(win32.CS_OWNDC);
    comptime var menuNameW = win32.L("");

    const wc = win32.WNDCLASSEXW{ .cbSize = @sizeOf(win32.WNDCLASSEXW), .style = @intToEnum(win32.WNDCLASS_STYLES, styleFlags), .lpfnWndProc = winProc, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = instance, .hIcon = null, .hCursor = null, .hbrBackground = null, .lpszMenuName = menuNameW, .lpszClassName = windowTitleW, .hIconSm = null };

    if (win32.RegisterClassExW(&wc) == 0) {
        return printAndReturnError("Registering Window Class");
    }
    errdefer {
        if (win32.UnregisterClassW(windowTitleW, instance) == 0) {
            printError("UnRegisterring window class");
        }
    }

    const window = win32.CreateWindowExW(win32.WINDOW_EX_STYLE.CLIENTEDGE, windowTitleW, windowTitleW, win32.WINDOW_STYLE.TILEDWINDOW, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, @intCast(i32, clientWidth), @intCast(i32, clientHeight), null, null, instance, null) orelse return printAndReturnError("Creating window");

    try resizeWindowExactly(window, clientWidth, clientHeight);

    return window;
}

const Dimensions = struct {
    width: i64,
    height: i64,
};

fn getClientDimensions(window: HWND) !Dimensions {
    var rect: win32.RECT = undefined;
    if (win32.GetClientRect(window, &rect) == 0) {
        return printAndReturnError("Determining client dimensions");
    }

    return Dimensions{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
}

pub fn resizeWindowExactly(window: HWND, desiredWidth: u16, desiredHeight: u16) !void {
    const initialClientArea = try getClientDimensions(window);

    const deltaWidth: i64 = -(initialClientArea.width - desiredWidth);
    const deltaHeight: i64 = -(initialClientArea.height - desiredHeight);
    const actualWidth: i64 = desiredWidth + deltaWidth;
    const actualHeight: i64 = desiredHeight + deltaHeight;

    try resizeWindow(window, @intCast(i32, actualWidth), @intCast(i32, actualHeight));

    const finalClientArea = try getClientDimensions(window);
    if ((finalClientArea.width != desiredWidth) or (finalClientArea.height != desiredHeight)) {
        std.log.err("Unable to resize exactly to ({},{}) got ({},{}) instead.", .{ desiredWidth, desiredHeight, finalClientArea.width, finalClientArea.height });
        return WindowsError.Win32Error;
    }
}

fn resizeWindow(window: HWND, width: i32, height: i32) !void {
    comptime var swp_flags = @enumToInt(win32.SWP_NOREPOSITION) | @enumToInt(win32.SWP_NOSENDCHANGING);
    if (win32.SetWindowPos(window, null, 0, 0, @intCast(i32, width), @intCast(i32, height), @intToEnum(win32.SET_WINDOW_POS_FLAGS, swp_flags)) == 0) {
        return printAndReturnError("Resizing window");
    }
}

pub fn postQuitMessage() void {
    win32.PostQuitMessage(0);
}

pub fn peekMessage(message: ?*MSG) bool {
    return win32.PeekMessageW(message, null, 0, 0, win32.PM_REMOVE) != 0;
}

pub fn translateMessage(message: ?*MSG) void {
    _ = win32.TranslateMessage(message);
}

pub fn dispatchMessage(message: ?*MSG) void {
    _ = win32.DispatchMessageW(message);
}

fn printAndReturnError(locationString: []const u8) WindowsError {
    const errorCode = win32.GetLastError();
    std.log.err("Win32Api Error: {s}: Code: {}", .{ locationString, errorCode });
    return WindowsError.Win32Error;
}

fn printError(locationString: []const u8) void {
    const errorCode = win32.GetLastError();
    std.log.err("Win32Api Error: {s}: Code: {}", .{ locationString, errorCode });
}
