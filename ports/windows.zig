//! Win32 实现:所有 IMM/DWM/known-folder 句柄与 C ABI 只许留在这里

const std = @import("std");
const Rect = @import("window.zig").Rect;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const CANDIDATEFORM = extern struct { dwIndex: u32, dwStyle: u32, ptCurrentPos: POINT, rcArea: RECT };
const CFS_POINT: u32 = 1;

extern fn ImmGetContext(hwnd: ?*anyopaque) ?*anyopaque;
extern fn ImmSetCandidateWindow(himc: ?*anyopaque, lpCandidate: *const CANDIDATEFORM) i32;
extern fn ImmReleaseContext(hwnd: ?*anyopaque, himc: ?*anyopaque) i32;
extern fn DwmSetWindowAttribute(hwnd: ?*anyopaque, dwAttribute: u32, pvAttribute: *const anyopaque, cbAttribute: u32) i32;
extern fn SHGetKnownFolderPath(rfid: *const Guid, dwFlags: u32, hToken: ?*anyopaque, ppszPath: *?[*:0]u16) i32;
extern fn CoTaskMemFree(pv: ?*anyopaque) void;

const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const DWMWCP_ROUND: u32 = 2;

const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const folder_local_app_data = Guid{
    .data1 = 0xF1B32785,
    .data2 = 0x6FBA,
    .data3 = 0x4FCF,
    .data4 = .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 },
};

pub fn applyImeAnchor(native_window: ?*anyopaque, anchor: ?Rect) void {
    const value = anchor orelse return;
    const himc = ImmGetContext(native_window) orelse return;
    const candidate = CANDIDATEFORM{
        .dwIndex = 0,
        .dwStyle = CFS_POINT,
        .ptCurrentPos = .{ .x = value.x, .y = value.y },
        .rcArea = std.mem.zeroes(RECT),
    };
    _ = ImmSetCandidateWindow(himc, &candidate);
    _ = ImmReleaseContext(native_window, himc);
}

pub fn configureNativeWindow(native_window: ?*anyopaque) void {
    var preference: u32 = DWMWCP_ROUND;
    _ = DwmSetWindowAttribute(native_window, DWMWA_WINDOW_CORNER_PREFERENCE, &preference, @sizeOf(u32));
}

pub fn localAppData(allocator: std.mem.Allocator) ![]u8 {
    var path_ptr: ?[*:0]u16 = null;
    const result = SHGetKnownFolderPath(&folder_local_app_data, 0, null, &path_ptr);
    if (result != 0 or path_ptr == null) return error.KnownFolderFailed;
    defer CoTaskMemFree(@ptrCast(path_ptr));
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(path_ptr.?));
}

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: u32,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: u32,
    Affinity: usize,
    PriorityClass: u32,
    SchedulingClass: u32,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

pub const job_basic_limit_size = @sizeOf(JOBOBJECT_BASIC_LIMIT_INFORMATION);
pub const job_extended_limit_size = @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: u32,
    dwY: u32,
    dwXSize: u32,
    dwYSize: u32,
    dwXCountChars: u32,
    dwYCountChars: u32,
    dwFillAttribute: u32,
    dwFlags: u32,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*anyopaque,
    hStdInput: ?*anyopaque,
    hStdOutput: ?*anyopaque,
    hStdError: ?*anyopaque,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: ?*anyopaque,
    hThread: ?*anyopaque,
    dwProcessId: u32,
    dwThreadId: u32,
};

extern fn CreateJobObjectW(lpJobObjectAttributes: ?*anyopaque, lpName: ?[*:0]const u16) ?*anyopaque;
extern fn SetInformationJobObject(hJob: ?*anyopaque, JobObjectInformationClass: u32, lpJobObjectInformation: *const anyopaque, cbJobObjectInformationLength: u32) i32;
extern fn AssignProcessToJobObject(hJob: ?*anyopaque, hProcess: ?*anyopaque) i32;
extern fn TerminateJobObject(hJob: ?*anyopaque, uExitCode: u32) i32;
extern fn CreateProcessW(lpApplicationName: ?[*:0]const u16, lpCommandLine: ?[*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: i32, dwCreationFlags: u32, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) i32;
extern fn ResumeThread(hThread: ?*anyopaque) u32;
extern fn WaitForSingleObject(hHandle: ?*anyopaque, dwMilliseconds: u32) u32;
extern fn GetExitCodeProcess(hProcess: ?*anyopaque, lpExitCode: *u32) i32;
extern fn TerminateProcess(hProcess: ?*anyopaque, uExitCode: u32) i32;
extern fn CloseHandle(hObject: ?*anyopaque) i32;

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: u32 = 9;
const CREATE_SUSPENDED: u32 = 0x00000004;
const CREATE_NO_WINDOW: u32 = 0x08000000;
const WAIT_OBJECT_0: u32 = 0;
const INFINITE: u32 = 0xFFFFFFFF;

pub fn createJob() !*anyopaque {
    const handle = CreateJobObjectW(null, null) orelse return error.CreateJobFailed;
    errdefer _ = CloseHandle(handle);
    const information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
        .BasicLimitInformation = .{
            .PerProcessUserTimeLimit = 0,
            .PerJobUserTimeLimit = 0,
            .LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            .MinimumWorkingSetSize = 0,
            .MaximumWorkingSetSize = 0,
            .ActiveProcessLimit = 0,
            .Affinity = 0,
            .PriorityClass = 0,
            .SchedulingClass = 0,
        },
        .IoInfo = std.mem.zeroes(IO_COUNTERS),
        .ProcessMemoryLimit = 0,
        .JobMemoryLimit = 0,
        .PeakProcessMemoryUsed = 0,
        .PeakJobMemoryUsed = 0,
    };
    if (SetInformationJobObject(handle, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS, &information, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0) return error.JobConfigurationFailed;
    return handle;
}

pub fn startProcess(job: ?*anyopaque, allocator: std.mem.Allocator, command_line: []const u8) !*anyopaque {
    const command_line_z = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line);
    defer allocator.free(command_line_z);
    var startup = std.mem.zeroes(STARTUPINFOW);
    startup.cb = @sizeOf(STARTUPINFOW);
    var process = std.mem.zeroes(PROCESS_INFORMATION);
    if (CreateProcessW(null, command_line_z.ptr, null, null, 0, CREATE_SUSPENDED | CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateProcessFailed;
    errdefer {
        _ = TerminateProcess(process.hProcess, 1);
        _ = CloseHandle(process.hProcess);
        _ = CloseHandle(process.hThread);
    }
    if (AssignProcessToJobObject(job, process.hProcess) == 0) return error.AssignProcessFailed;
    if (ResumeThread(process.hThread) == std.math.maxInt(u32)) return error.ResumeProcessFailed;
    _ = CloseHandle(process.hThread);
    return process.hProcess orelse return error.CreateProcessFailed;
}

pub fn waitForProcess(process: ?*anyopaque) !u32 {
    if (WaitForSingleObject(process, INFINITE) != WAIT_OBJECT_0) return error.ProcessWaitFailed;
    var exit_code: u32 = 0;
    if (GetExitCodeProcess(process, &exit_code) == 0) return error.ProcessExitCodeFailed;
    return exit_code;
}

pub fn terminateJob(job: ?*anyopaque) !void {
    if (TerminateJobObject(job, 1) == 0) return error.TerminateJobFailed;
}

pub fn startDetachedProcess(allocator: std.mem.Allocator, command_line: []const u8) !*anyopaque {
    return startDetachedProcessIn(allocator, command_line, null);
}

pub fn startDetachedProcessIn(allocator: std.mem.Allocator, command_line: []const u8, working_dir: ?[]const u8) !*anyopaque {
    const command_line_z = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line);
    defer allocator.free(command_line_z);
    const directory = if (working_dir) |path| try std.unicode.utf8ToUtf16LeAllocZ(allocator, path) else null;
    defer if (directory) |path| allocator.free(path);
    var startup = std.mem.zeroes(STARTUPINFOW);
    startup.cb = @sizeOf(STARTUPINFOW);
    var process = std.mem.zeroes(PROCESS_INFORMATION);
    if (CreateProcessW(null, command_line_z.ptr, null, null, 0, CREATE_NO_WINDOW, null, if (directory) |path| path.ptr else null, &startup, &process) == 0) return error.CreateProcessFailed;
    _ = CloseHandle(process.hThread);
    return process.hProcess orelse return error.CreateProcessFailed;
}

pub fn closeHandle(handle: ?*anyopaque) void {
    _ = CloseHandle(handle);
}
