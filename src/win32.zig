const std = @import("std");
const win32_error = @import("./win32_error.zig");

pub const InstanceHandle = *opaque {};
pub const WindowHandle = *opaque{};
pub const winapi_calling_conv = std.os.windows.WINAPI;
pub const WindowsResult = isize;


pub const WindowsProcedure = fn(
    window: WindowHandle,
    message: u32,
    wParam: usize,
    lParam: isize,
) callconv(winapi_calling_conv) isize;

pub fn getModuleHandleA(module_name: ?[*:0]const u8) !InstanceHandle {
    return GetModuleHandleA(module_name) orelse win32_error.getErrorFromCode(getLastError());
}

pub fn getLastError() win32_error.Win32ErrorCode {
    return @intToEnum(win32_error.Win32ErrorCode, GetLastError()); // TODO how do I handle an error value not represented by the std lib Enum?
}

pub fn createWindow(instance: InstanceHandle, windProc: WindowsProcedure, width: i32, height: i32, title: [*:0]const u8) !WindowHandle {
    const CS_HREDRAW_FLAG = 2;
    const CS_VREDRAW_FLAG = 1;
    const CS_OWNDC_FLAG = 32;
    const className = "PNGViewerClassName";

    const wc = WNDCLASSEXA {
        .cbSize = @sizeOf(WNDCLASSEXA),
        .style = CS_HREDRAW_FLAG | CS_VREDRAW_FLAG | CS_OWNDC_FLAG,
        .lpfnWndProc = windProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = "",
        .lpszClassName = className,   
        .hIconSm = null
    };

    if (RegisterClassExA(&wc) == 0){
        return win32_error.getErrorFromCode(getLastError());
    }
    errdefer { // TODO issue with error reporting system because error code can be cleared when any cleanup code like this gets called into win32 API
        _ = UnregisterClassA(className, instance);
    }

    const WS_EX_CLIENTEDGE_FLAG = 512;
    const WS_OVERLAPPED = 0x00000000;
    const WS_CAPTION = 0x00C00000;
    const WS_SYSMENU = 0x00080000;
    const WS_THICKFRAME = 0x00040000;
    const WS_MINIMIZEBOX = 0x00020000;
    const WS_MAXMIMIZEBOX = 0x00010000;
    const WS_OVERLAPPEDWINDOW_FLAG = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXMIMIZEBOX;
    const CW_USEDEFAULT_FLAG = @as(i32, -2147483648);

    var windowHandle = CreateWindowExA(
        WS_EX_CLIENTEDGE_FLAG,
        className,
        title,
        WS_OVERLAPPEDWINDOW_FLAG,
        CW_USEDEFAULT_FLAG,
        CW_USEDEFAULT_FLAG,
        width,
        height,
        null,
        null,
        instance,
        null) orelse return win32_error.getErrorFromCode(getLastError());
    // TODO errdefer destroy window
    // TODO resize window to get exact client area

    return windowHandle;
}

pub fn defaultWindowsProcedure(
    windowHandle: ?WindowHandle,
    message: u32,
    wParam: usize,
    lParam: isize,
) WindowsResult {
   return DefWindowProcA(windowHandle, message, wParam, lParam); 
}

pub fn showWindow(window: WindowHandle) void{
    const SHOW_NORMAL_FLAG = 1;
    _ = ShowWindow(window, SHOW_NORMAL_FLAG);
}

const DWORD = c_ulong;
const BOOL = i32;

const WNDCLASSEXA = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: ?WindowsProcedure,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?InstanceHandle,
    hIcon: ?*opaque {},
    hCursor: ?*opaque {},
    hbrBackground: ?*opaque {},
    lpszMenuName: ?[*:0]const u8,
    lpszClassName: ?[*:0]const u8,
    hIconSm: ?*opaque {},
};

extern "KERNEL32" fn GetModuleHandleA(
    module_name: ?[*:0]const u8,
) callconv(winapi_calling_conv) ?InstanceHandle;

extern "KERNEL32" fn GetLastError() callconv(winapi_calling_conv) DWORD;

extern "KERNEL32" fn FormatMessageA(
    dwFlags: DWORD,
    lpSource: ?*const anyopaque,
    dwMessageId: win32_error.Win32ErrorCode,
    dwLanguageId: u32,
    lpBuffer: ?[*:0]u8,
    nSize: u32,
    Arguments: ?*?*i8,
) callconv(winapi_calling_conv) u32;

extern "USER32" fn RegisterClassExA(
    param0: ?*const WNDCLASSEXA,
) callconv(winapi_calling_conv) u16;

extern "USER32" fn UnregisterClassA(
    lpClassName: ?[*:0]const u8,
    hInstance: ?InstanceHandle,
) callconv(winapi_calling_conv)BOOL;

extern "USER32" fn CreateWindowExA(
    dwExStyle: u32,
    lpClassName: ?[*:0]const u8,
    lpWindowName: ?[*:0]const u8,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?WindowHandle,
    hMenu: ?*opaque {},
    hInstance: ?InstanceHandle,
    lpParam: ?*opaque {},
) callconv(winapi_calling_conv) ?WindowHandle;

extern "USER32" fn DefWindowProcA(
    hWnd: ?WindowHandle,
    Msg: u32,
    wParam: usize,
    lParam: isize,
) callconv(winapi_calling_conv) WindowsResult;

extern "USER32" fn ShowWindow(
    hWnd: ?WindowHandle,
    nCmdShow: u32,
) callconv(@import("std").os.windows.WINAPI) BOOL;