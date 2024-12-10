const std = @import("std");
const ddui = @import("ddui");
const win32 = @import("win32").everything;

const HResultError = ddui.HResultError;

threadlocal var thread_is_panicing = false;
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            arena.allocator(),
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "Panic!", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}
fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const msg = std.fmt.allocPrintZ(arena.allocator(), fmt, args) catch @panic(
        "OutOfMemory while allocating fatal error message",
    );
    _ = win32.MessageBoxA(null, msg, "Fatal Error", .{ .ICONASTERISK = 1 });
    win32.ExitProcess(1);
}

fn u32FromHr(hr: win32.HRESULT) u32 {
    return @bitCast(hr);
}
const ErrorCode = union(enum) {
    win32: win32.WIN32_ERROR,
    hresult: i32,
};
fn apiFailNoreturn(comptime function_name: []const u8, ec: ErrorCode) noreturn {
    switch (ec) {
        .win32 => |e| std.debug.panic(function_name ++ " unexpectedly failed with {}", .{e.fmt()}),
        .hresult => |hr| std.debug.panic(function_name ++ " unexpectedly failed, hresult=0x{x}", .{u32FromHr(hr)}),
    }
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const Dpi = struct {
    value: u32,
    pub fn eql(self: Dpi, other: Dpi) bool {
        return self.value == other.value;
    }
};
fn createTextFormatCenter18pt(dpi: Dpi) *win32.IDWriteTextFormat {
    var err: HResultError = undefined;
    return ddui.createTextFormat(global.dwrite_factory, &err, .{
        .size = win32.scaleDpi(f32, 18, dpi.value),
        .family_name = win32.L("Segoe UI Emoji"),
        .center_x = true,
        .center_y = true,
    }) catch std.debug.panic("{s} failed, hresult=0x{x}", .{ err.context, err.hr });
}

const global = struct {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const gpa = gpa_instance.allocator();
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    var d2d_factory: *win32.ID2D1Factory = undefined;
    var state: State = .{};
};

const Layout = struct {
    cell_size: i32,
    grid: win32.RECT,
    cursor_size: XY(u16),
    color_areas: [5]win32.RECT,
    pub fn update(self: *Layout, dpi: u32, client_size: XY(i32), cursor: *const Cursor) void {
        const margin = win32.scaleDpi(i32, 10, dpi);

        const max_grid_height = client_size.y - 2 * margin;
        const cell_size = @divTrunc(max_grid_height, 2 * cursor.size.y);
        const grid_size: XY(i32) = .{
            .x = cell_size * cursor.size.x,
            .y = cell_size * 2 * cursor.size.y,
        };

        const grid = ddui.rectIntFromSize(.{
            .left = margin,
            .top = margin + @divTrunc(max_grid_height - grid_size.y, 2),
            .width = grid_size.x,
            .height = grid_size.y,
        });
        self.* = .{
            .cell_size = cell_size,
            .grid = grid,
            .cursor_size = cursor.size,
            .color_areas = undefined,
        };

        {
            const area_size = win32.scaleDpi(i32, 40, dpi);
            const left = grid.right + win32.scaleDpi(i32, 30, dpi);
            var y: i32 = margin;
            for (&self.color_areas) |*area| {
                area.* = ddui.rectIntFromSize(.{
                    .left = left,
                    .top = y,
                    .width = area_size,
                    .height = area_size,
                });
                y = area.bottom;
            }
        }
    }
};

const MouseTarget = union(enum) {
    static: enum {
        some_button,
    },
    grid: XY(u16),
    pub fn eql(self: MouseTarget, other: MouseTarget) bool {
        return switch (self) {
            .static => |self_static| switch (other) {
                .static => |other_static| self_static == other_static,
                .grid => false,
            },
            .grid => |self_grid| switch (other) {
                .static => false,
                .grid => |other_grid| self_grid.eql(other_grid),
            },
        };
    }
};

pub fn targetFromPoint(layout: *const Layout, point: win32.POINT) ?MouseTarget {
    if (ddui.rectContainsPoint(layout.grid, point)) {
        const relative: XY(i32) = .{
            .x = point.x - layout.grid.left,
            .y = point.y - layout.grid.top,
        };
        const cell = .{
            .x = @divTrunc(relative.x, layout.cell_size),
            .y = @divTrunc(relative.y, layout.cell_size),
        };
        if (cell.x >= 0 and
            cell.x < layout.cursor_size.x and
            cell.y >= 0 and
            cell.y < 2 * layout.cursor_size.y)
        {
            return .{ .grid = .{
                .x = @intCast(cell.x),
                .y = @intCast(cell.y),
            } };
        }
    }
    return null;
}

const D2d = struct {
    target: *win32.ID2D1HwndRenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    pub fn init(hwnd: win32.HWND, err: *HResultError) error{HResult}!D2d {
        var target: *win32.ID2D1HwndRenderTarget = undefined;
        const target_props = win32.D2D1_RENDER_TARGET_PROPERTIES{
            .type = .DEFAULT,
            .pixelFormat = .{
                .format = .B8G8R8A8_UNORM,
                .alphaMode = .PREMULTIPLIED,
            },
            .dpiX = 0,
            .dpiY = 0,
            .usage = .{},
            .minLevel = .DEFAULT,
        };
        const hwnd_target_props = win32.D2D1_HWND_RENDER_TARGET_PROPERTIES{
            .hwnd = hwnd,
            .pixelSize = .{ .width = 0, .height = 0 },
            .presentOptions = .{},
        };

        {
            const hr = global.d2d_factory.CreateHwndRenderTarget(
                &target_props,
                &hwnd_target_props,
                &target,
            );
            if (hr < 0) return err.set(hr, "CreateHwndRenderTarget");
        }
        errdefer _ = target.IUnknown.Release();

        {
            var dc: *win32.ID2D1DeviceContext = undefined;
            {
                const hr = target.IUnknown.QueryInterface(win32.IID_ID2D1DeviceContext, @ptrCast(&dc));
                if (hr < 0) return err.set(hr, "GetDeviceContext");
            }
            defer _ = dc.IUnknown.Release();
            // just make everything DPI aware, all applications should just do this
            dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);
        }

        var brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const hr = target.ID2D1RenderTarget.CreateSolidColorBrush(&color, null, @ptrCast(&brush));
            if (hr < 0) return err.set(hr, "CreateSolidBrush");
        }
        errdefer _ = brush.IUnknown.Release();

        return .{
            .target = @ptrCast(target),
            .brush = brush,
        };
    }
    pub fn deinit(self: *D2d) void {
        _ = self.brush.IUnknown.Release();
        _ = self.target.IUnknown.Release();
    }
    pub fn solid(self: *const D2d, color: win32.D2D_COLOR_F) *win32.ID2D1Brush {
        self.brush.SetColor(&color);
        return &self.brush.ID2D1Brush;
    }
};

const PaintOp = enum { off, on };

const State = struct {
    bg_erased: bool = false,
    layout: Layout = undefined,
    maybe_d2d: ?D2d = null,
    text_format_center_18pt: ddui.TextFormatCache(Dpi, createTextFormatCenter18pt) = .{},
    mouse_left: ddui.mouse.ButtonState = .up,
    mouse_right: ddui.mouse.ButtonState = .up,
    mouse: ddui.mouse.State(MouseTarget) = .{},
    cursor: Cursor = .{
        .size = .{ .x = 8, .y = 8 },
        .bits = [_]u8{0} ** max_bits_len,
    },
    hcursor: ?win32.HCURSOR = null,

    pub fn deinit(self: *State) void {
        if (self.maybe_d2d) |*d2d| d2d.deinit();
        self.* = undefined;
    }

    fn cursorBitsChanged(state: *State) void {
        if (state.hcursor) |c| {
            const replaced: ?win32.HCURSOR = blk: {
                const cursor = win32.GetCursor();
                if (cursor == c) break :blk win32.SetCursor(
                    win32.LoadCursorW(
                        null,
                        win32.IDC_ARROW,
                    ),
                );
                break :blk null;
            };
            if (0 == win32.DestroyIcon(c)) apiFailNoreturn(
                "DestroyIcon",
                .{ .win32 = win32.GetLastError() },
            );
            state.hcursor = null;
            if (replaced == c) {
                _ = win32.SetCursor(state.getHcursor());
            }
        }
    }

    pub fn updatePixel(state: *State, cell: XY(u16), op: PaintOp) bool {
        if (state.cursor.updatePixel(cell, op)) {
            state.cursorBitsChanged();
            return true;
        }
        return false;
    }

    pub fn getMouseButtonsPaintOp(state: *const State) ?PaintOp {
        return switch (state.mouse_left) {
            .up => switch (state.mouse_right) {
                .up => null,
                .down => .off,
            },
            .down => switch (state.mouse_right) {
                .up => .on,
                .down => null,
            },
        };
    }

    pub fn getHcursor(state: *State) win32.HCURSOR {
        if (state.hcursor == null) {
            state.hcursor = state.cursor.makeHcursor();
        }
        return state.hcursor.?;
    }
};

fn getPixelWithStride(bits: []const u8, x: usize, y: usize, stride: usize) bool {
    const byte_offset = (stride * y) + x / 8;
    const shift: u3 = @intCast(7 - (x % 8));
    return 1 == (1 & bits[byte_offset] >> shift);
}
fn setPixelWithStride(bits: []u8, x: usize, y: usize, stride: usize, on: bool) void {
    const byte_offset = (stride * y) + x / 8;
    const shift: u3 = @intCast(7 - (x % 8));
    if (on) {
        bits[byte_offset] |= (@as(u8, 1) << shift);
    } else {
        bits[byte_offset] &= ~(@as(u8, 1) << shift);
    }
}

fn getStride(width: anytype) @TypeOf(width) {
    return ((width + 15) >> 4) << 1;
}

const max_cursor_size = 128;
const max_bits_len = getStride(max_cursor_size) * 2 * max_cursor_size;
const Cursor = struct {
    size: XY(u16),
    bits: [max_bits_len]u8,
    pub fn getPixel(self: *const Cursor, cell: XY(u16)) bool {
        return getPixelWithStride(&self.bits, cell.x, cell.y, getStride(max_cursor_size));
    }
    pub fn setPixel(self: *Cursor, cell: XY(u16), on: bool) void {
        setPixelWithStride(&self.bits, cell.x, cell.y, getStride(max_cursor_size), on);
    }
    fn updatePixel(self: *Cursor, cell: XY(u16), op: PaintOp) bool {
        const current_on = self.getPixel(cell);
        const wanted_on = (op == .on);
        if (current_on == wanted_on) return false;
        self.setPixel(cell, wanted_on);
        return true;
    }
    fn makeHcursor(cursor: *Cursor) win32.HCURSOR {
        var bits: [max_bits_len]u8 = undefined;
        const stride = getStride(cursor.size.x);
        for (0..cursor.size.y * 2) |y| {
            for (0..cursor.size.x) |x| {
                setPixelWithStride(
                    &bits,
                    x,
                    y,
                    stride,
                    cursor.getPixel(.{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    }),
                );
            }
        }
        const bitmap = win32.CreateBitmap(
            cursor.size.x,
            cursor.size.y * 2,
            1, // plane count
            1, // bits per pixel
            &bits,
        ) orelse apiFailNoreturn("CreateBitmap", .{ .win32 = win32.GetLastError() });
        defer deleteObject(bitmap);

        var info: win32.ICONINFO = .{
            .fIcon = 0, // 0 for a cursor
            .xHotspot = 0,
            .yHotspot = 0,
            .hbmMask = bitmap,
            .hbmColor = null,
        };
        return win32.CreateIconIndirect(&info) orelse apiFailNoreturn("CreateIconIndirect", .{ .win32 = win32.GetLastError() });
    }
};

pub fn getMouseRelativePoint(rect: win32.RECT, mouse_point: ?XY(i32)) XY(i32) {
    const p = mouse_point orelse return null;
    if (!ddui.rectContainsPoint(rect, p)) return null;
    return .{
        .x = p.x - rect.left,
        .y = p.y - rect.top,
    };
}

pub fn paint(
    d2d: *const D2d,
    dpi: u32,
    layout: *const Layout,
    paint_op: ?PaintOp,
    mouse: *const ddui.mouse.State(MouseTarget),
    cursor: *const Cursor,
    text_format_center_18pt: *win32.IDWriteTextFormat,
) void {
    _ = dpi;
    {
        const color = ddui.shade8(window_bg_shade);
        d2d.target.ID2D1RenderTarget.Clear(&color);
    }

    _ = text_format_center_18pt;
    // ddui.DrawText(
    //     &d2d.target.ID2D1RenderTarget,
    //     win32.L("TODO: render the UI"),
    //     text_format_center_18pt,
    //     ddui.rectFloatFromInt(layout.title),
    //     d2d.solid(ddui.shade8(255)),
    //     .{},
    //     .NATURAL,
    // );

    {
        const grid_size: XY(i32) = .{
            .x = layout.grid.right - layout.grid.left,
            .y = layout.grid.bottom - layout.grid.top,
        };
        const cell_size: i32 = @min(
            @divTrunc(grid_size.x, cursor.size.x),
            @divTrunc(grid_size.y, 2 * cursor.size.y),
        );
        for (0..cursor.size.y * 2) |y| {
            for (0..cursor.size.x) |x| {
                const on = cursor.getPixel(.{ .x = @intCast(x), .y = @intCast(y) });
                ddui.FillRectangle(
                    &d2d.target.ID2D1RenderTarget,
                    ddui.rectIntFromSize(.{
                        .left = layout.grid.left + cell_size * @as(i32, @intCast(x)),
                        .top = layout.grid.top + cell_size * @as(i32, @intCast(y)),
                        .width = cell_size,
                        .height = cell_size,
                    }),
                    d2d.solid(ddui.shade8(if (on) 255 else 0)),
                );
            }
        }

        if (mouse.getTarget()) |mouse_target| switch (mouse_target) {
            .static => {},
            .grid => |cell| {
                const alpha: u8 = if (paint_op != null) 255 else 200;
                const rect = ddui.rectFloatFromInt(ddui.rectIntFromSize(.{
                    .left = layout.grid.left + cell_size * cell.x,
                    .top = layout.grid.top + cell_size * cell.y,
                    .width = cell_size,
                    .height = cell_size,
                }));
                d2d.target.ID2D1RenderTarget.DrawRectangle(
                    &rect,
                    d2d.solid(ddui.rgba8(52, 240, 223, alpha)),
                    @as(f32, @floatFromInt(cell_size)) * 0.2,
                    null,
                );
            },
        };
    }

    for (layout.color_areas, 0..) |area, i| {
        ddui.FillRectangle(
            &d2d.target.ID2D1RenderTarget,
            area,
            d2d.solid(switch (i) {
                0 => ddui.rgb8(255, 0, 0),
                1 => ddui.rgb8(0, 255, 0),
                2 => ddui.rgb8(0, 0, 255),
                3 => ddui.rgb8(0, 0, 0),
                4 => ddui.rgb8(255, 255, 255),
                else => ddui.rgb8(0, 255, 0),
            }),
        );
    }
}

const window_bg_shade = 29;

pub export fn wWinMain(
    hinstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    cmdline: [*:0]u16,
    cmdshow: c_int,
) c_int {
    _ = hinstance;
    _ = cmdline;
    _ = cmdshow;

    {
        const hr = win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory,
            @ptrCast(&global.dwrite_factory),
        );
        if (hr < 0) apiFailNoreturn("DWriteCreateFactory", .{ .hresult = hr });
    }
    {
        var err: HResultError = undefined;
        global.d2d_factory = ddui.createFactory(
            .SINGLE_THREADED,
            .{},
            &err,
        ) catch std.debug.panic("{}", .{err});
    }

    if (false) {
        var random_instance = std.Random.DefaultPrng.init(win32.GetTickCount());
        const random = random_instance.random();
        for (&global.state.cursor.bits) |*b| {
            b.* = random.int(u8);
        }
    } else {
        const cursor = &global.state.cursor;
        for (0..cursor.size.y * 2) |y| {
            for (0..cursor.size.x) |x| {
                const on = if (y < cursor.size.y)
                    (y >= cursor.size.y / 2)
                else
                    (x >= cursor.size.x / 2);
                cursor.setPixel(.{ .x = @intCast(x), .y = @intCast(y) }, on);
            }
        }
    }

    const CLASS_NAME = win32.L("MonoCursorsWnd");

    {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .lpfnWndProc = WndProc,
            .cbClsExtra = 0,
            .cbWndExtra = @sizeOf(*State),
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = null,
        };
        if (0 == win32.RegisterClassExW(&wc)) apiFailNoreturn("RegisterClass", .{ .win32 = win32.GetLastError() });
    }

    const hwnd = win32.CreateWindowExW(
        .{},
        CLASS_NAME,
        win32.L("MonoCursors"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT, // x
        win32.CW_USEDEFAULT, // y
        // TODO: scale window based on DPI and/or monitor size?
        win32.CW_USEDEFAULT, // width
        win32.CW_USEDEFAULT, // height
        null, // parent window
        null, // menu
        win32.GetModuleHandleW(null),
        null, // WM_CREATE user data
    ) orelse apiFailNoreturn("CreateWindow", .{ .win32 = win32.GetLastError() });

    {
        // TODO: maybe use DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 if applicable
        // see https://stackoverflow.com/questions/57124243/winforms-dark-title-bar-on-windows-10
        //int attribute = DWMWA_USE_IMMERSIVE_DARK_MODE;
        const dark_value: c_int = 1;
        const hr = win32.DwmSetWindowAttribute(
            hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value,
            @sizeOf(@TypeOf(dark_value)),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute for dark={} failed, error={}",
            .{ dark_value, win32.GetLastError() },
        );
    }

    if (0 == win32.UpdateWindow(hwnd)) apiFailNoreturn("UpdateWindow", .{ .win32 = win32.GetLastError() });

    // for some reason this causes the window to paint before being shown so we
    // don't get a white flicker when the window shows up
    if (0 == win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, .{
        .NOMOVE = 1,
        .NOSIZE = 1,
        .NOOWNERZORDER = 1,
    })) apiFailNoreturn("SetWindowPos", .{ .win32 = win32.GetLastError() });
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    return @intCast(msg.wParam);
}

fn mouseButton(
    hwnd: win32.HWND,
    button: ddui.mouse.Button,
    button_state: ddui.mouse.ButtonState,
    lparam: win32.LPARAM,
) void {
    const point = ddui.pointFromLparam(lparam);
    const state = &global.state;
    switch (button) {
        .left => state.mouse_left = button_state,
        .right => state.mouse_right = button_state,
    }
    _ = state.mouse.updateTarget(targetFromPoint(&state.layout, point));
    _ = state.mouse.set(button, button_state);
    if (state.getMouseButtonsPaintOp()) |paint_op| {
        if (state.mouse.getTarget()) |target| switch (target) {
            .static => {},
            .grid => |cell| _ = state.updatePixel(cell, paint_op),
        };
    }
    win32.invalidateHwnd(hwnd);
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (msg) {
        win32.WM_SETCURSOR => {
            const state = &global.state;
            _ = win32.SetCursor(state.getHcursor());
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            const point = ddui.pointFromLparam(lparam);
            const state = &global.state;
            if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
                win32.invalidateHwnd(hwnd);
            }

            if (state.getMouseButtonsPaintOp()) |paint_op| {
                if (state.mouse.getTarget()) |target| switch (target) {
                    .static => {},
                    .grid => |cell| if (state.updatePixel(cell, paint_op)) {
                        win32.invalidateHwnd(hwnd);
                    },
                };
            }
        },
        win32.WM_LBUTTONDOWN => mouseButton(hwnd, .left, .down, lparam),
        win32.WM_LBUTTONUP => mouseButton(hwnd, .left, .up, lparam),
        win32.WM_RBUTTONDOWN => mouseButton(hwnd, .right, .down, lparam),
        win32.WM_RBUTTONUP => mouseButton(hwnd, .right, .up, lparam),
        win32.WM_DISPLAYCHANGE => {
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_PAINT => {
            const dpi = win32.dpiFromHwnd(hwnd);
            const client_size = getClientSize(hwnd);
            const state = &global.state;

            const err: HResultError = blk: {
                var ps: win32.PAINTSTRUCT = undefined;
                _ = win32.BeginPaint(hwnd, &ps) orelse return apiFailNoreturn(
                    "BeginPaint",
                    .{ .win32 = win32.GetLastError() },
                );
                defer if (0 == win32.EndPaint(hwnd, &ps)) apiFailNoreturn(
                    "EndPaint",
                    .{ .win32 = win32.GetLastError() },
                );

                if (state.maybe_d2d == null) {
                    var err: HResultError = undefined;
                    state.maybe_d2d = D2d.init(hwnd, &err) catch break :blk err;
                }

                state.layout.update(dpi, client_size, &state.cursor);

                {
                    const size: win32.D2D_SIZE_U = .{
                        .width = @intCast(client_size.x),
                        .height = @intCast(client_size.y),
                    };
                    const hr = state.maybe_d2d.?.target.Resize(&size);
                    if (hr < 0) break :blk HResultError{ .context = "D2dResize", .hr = hr };
                }
                state.maybe_d2d.?.target.ID2D1RenderTarget.BeginDraw();

                paint(
                    &state.maybe_d2d.?,
                    dpi,
                    &state.layout,
                    state.getMouseButtonsPaintOp(),
                    &state.mouse,
                    &state.cursor,
                    state.text_format_center_18pt.getOrCreate(Dpi{ .value = dpi }),
                );

                break :blk HResultError{
                    .context = "D2dEndDraw",
                    .hr = state.maybe_d2d.?.target.ID2D1RenderTarget.EndDraw(null, null),
                };
            };

            if (err.hr == win32.D2DERR_RECREATE_TARGET) {
                std.log.debug("D2DERR_RECREATE_TARGET", .{});
                state.maybe_d2d.?.deinit();
                state.maybe_d2d = null;
                win32.invalidateHwnd(hwnd);
            } else if (err.hr < 0) std.debug.panic("paint error: {}", .{err});

            return 0;
        },
        win32.WM_ERASEBKGND => {
            const state = &global.state;
            if (!state.bg_erased) {
                state.bg_erased = true;
                const hdc: win32.HDC = @ptrFromInt(wparam);
                const client_size = getClientSize(hwnd);
                const brush = win32.CreateSolidBrush(
                    colorrefFromShade(window_bg_shade),
                ) orelse apiFailNoreturn("CreateSolidBrush", .{ .win32 = win32.GetLastError() });
                deleteObject(brush);
                const client_rect: win32.RECT = .{
                    .left = 0,
                    .top = 0,
                    .right = client_size.x,
                    .bottom = client_size.y,
                };
                if (0 == win32.FillRect(hdc, &client_rect, brush)) apiFailNoreturn(
                    "FillRect",
                    .{ .win32 = win32.GetLastError() },
                );
            }
            return 1;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,

        pub fn init(x: T, y: T) @This() {
            return .{ .x = x, .y = y };
        }

        const Self = @This();
        pub fn eql(a: Self, b: Self) bool {
            return a.x == b.x and a.y == b.y;
        }
    };
}

fn getClientSize(hwnd: win32.HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect)) apiFailNoreturn("GetClientRect", .{ .win32 = win32.GetLastError() });
    if (rect.left != 0) std.debug.panic("client rect non-zero left {}", .{rect.left});
    if (rect.top != 0) std.debug.panic("client rect non-zero top {}", .{rect.top});
    return .{ .x = rect.right, .y = rect.bottom };
}

fn colorrefFromShade(shade: u8) u32 {
    return (@as(u32, shade) << 0) | (@as(u32, shade) << 8) | (@as(u32, shade) << 16);
}
fn deleteObject(obj: win32.HGDIOBJ) void {
    if (0 == win32.DeleteObject(obj)) apiFailNoreturn(
        "DeleteObject",
        .{ .win32 = win32.GetLastError() },
    );
}
