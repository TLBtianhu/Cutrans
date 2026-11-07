//! Verification-only executable; never distributed as a public product entry.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingProbeLibrary;
    if (args.next() != null) return error.InvalidArguments;
    var library = try @import("ports").library.Library.open(init.gpa, path);
    defer library.close();
    const Function = *const fn () callconv(.c) c_int;
    const probe = library.lookup(Function, "cutrans_probe") orelse return error.MissingProbeSymbol;
    std.debug.print("CUTRANS_LIBRARY_PROBE value={d}\n", .{probe()});
}
