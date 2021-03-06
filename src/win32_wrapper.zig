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
pub const HDC = win32.HDC;
pub const PAINTSTRUCT = win32.PAINTSTRUCT;

pub const WM_CLOSE = win32.WM_CLOSE;
pub const WM_PAINT = win32.WM_PAINT;

pub const defaultWindowProcedure = win32.DefWindowProcW;

pub fn beginPaint(window: HWND, paint: *win32.PAINTSTRUCT) void {
    _ = win32.EndPaint(window, paint);
}

pub fn endPaint(window: HWND, paint: *win32.PAINTSTRUCT) void {
    _ = win32.BeginPaint(window, paint);
}

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

    resizeWindowExactly(window, clientWidth, clientHeight) catch |err| {
        if (win32.DestroyWindow(window) == 0) {
            std.log.err("Unable to destroy window after an error was raised trying to resize it.", .{});
        }
        return err;
    };

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

pub fn blitToWindow(window: HWND, buffer: []u8, bufferWidth: u64, bufferHeight: u64) !void {
    const clientDimensions = try getClientDimensions(window);
    const deviceContext = try getDeviceContext(window);
    const bitmapInfo = win32.BITMAPINFO{ .bmiHeader = win32.BITMAPINFOHEADER{
        .biSize = @sizeOf(win32.BITMAPINFOHEADER),
        .biWidth = @intCast(i32, bufferWidth),
        .biHeight = @intCast(i32, bufferHeight),
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = win32.BI_RGB,
        .biSizeImage = 0,
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    }, .bmiColors = undefined };

    if (win32.StretchDIBits(deviceContext, 0, 0, @intCast(i32, clientDimensions.width), @intCast(i32, clientDimensions.height), 0, 0, @intCast(i32, bufferWidth), @intCast(i32, bufferHeight), buffer.ptr, &bitmapInfo, win32.DIB_RGB_COLORS, win32.SRCCOPY) == 0) {
        return printAndReturnError("Blitting graphics buffer to window");
    }
}

pub fn getDeviceContext(window: HWND) !HDC {
    return win32.GetDC(window) orelse return printAndReturnError("Getting window device context");
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
        std.log.warn("Unable to resize exactly to ({},{}) got ({},{}) instead.", .{ desiredWidth, desiredHeight, finalClientArea.width, finalClientArea.height });
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
