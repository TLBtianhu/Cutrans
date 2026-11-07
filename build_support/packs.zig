const std = @import("std");

/// Immutable, cache-backed pack inputs. Install prefixes never become inputs.
pub const Files = struct {
    b: *std.Build,
    write: *std.Build.Step.WriteFile,

    pub fn init(b: *std.Build) Files {
        return .{ .b = b, .write = b.addWriteFiles() };
    }

    pub fn add(self: *Files, source: std.Build.LazyPath, destination: []const u8) void {
        _ = self.write.addCopyFile(source, destination);
    }

    pub fn directory(self: *Files, source: std.Build.LazyPath, destination: []const u8) void {
        _ = self.write.addCopyDirectory(source, destination, .{});
    }

    pub fn finish(self: *Files, script: []const u8, manifest_name: []const u8, args: []const []const u8) std.Build.LazyPath {
        const run = self.b.addSystemCommand(&.{"python"});
        run.addFileArg2(self.b.path(script), .{});
        run.addFileInput(self.b.path("tools/build_vm_pack.py"));
        run.addFileInput(self.b.path("runtime/capabilities.zig"));
        run.addFileInput(self.b.path("build.zig.zon"));
        run.addFileInput(self.b.path("tools/product.py"));
        run.addFileInput(self.b.path("vne/product.zig"));
        run.addFileInput(self.b.path("vne/abi.zig"));
        run.addArg("--root");
        run.addDirectoryArg2(self.write.getDirectory(), .{});
        run.addArgs(args);
        run.addArg("--output");
        const manifest = run.addOutputFileArg2(manifest_name, .{});
        const sealed = self.b.addWriteFiles();
        _ = sealed.addCopyDirectory(self.write.getDirectory(), "", .{});
        _ = sealed.addCopyFile(manifest, manifest_name);
        return sealed.getDirectory();
    }
};

/// Install locations are resolved by the maker, after --prefix is known.
pub fn installed(sub_path: []const u8) std.Build.LazyPath {
    return .{ .relative = .{ .base = .install_prefix, .sub_path = sub_path } };
}

/// Each form hashes its own launch declaration against the same immutable files.
pub fn vmManifestForContext(b: *std.Build, pack_root: std.Build.LazyPath, context: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{"python"});
    run.addFileArg2(b.path("tools/build_vm_pack.py"), .{});
    inline for (.{ "tools/product.py", "vne/product.zig", "vne/abi.zig", "build.zig.zon", "runtime/capabilities.zig" }) |input|
        run.addFileInput(b.path(input));
    run.addArg("--root");
    run.addDirectoryArg2(pack_root, .{});
    run.addArg("--context");
    run.addFileArg2(context, .{});
    run.addArg("--output");
    return run.addOutputFileArg2("vm-pack.json", .{});
}

pub fn action(b: *std.Build, name: []const u8, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python"});
    run.addFileArg2(b.path("tools/build_actions.py"), .{});
    run.addFileInput(b.path("tools/build_paths.py"));
    run.addFileInput(b.path("tools/automation_process.py"));
    run.addFileInput(b.path("tools/verification_paths.py"));
    run.addFileInput(b.path("tools/verification_context.py"));
    run.addFileInput(b.path("tools/product.py"));
    run.addFileInput(b.path("vne/product.zig"));
    run.addFileInput(b.path("vne/abi.zig"));
    run.addFileInput(b.path("build.zig.zon"));
    run.addArg("--prefix");
    run.addDirectoryArg2(installed(""), .{ .make_absolute = true });
    run.addArg(name);
    run.addArgs(args);
    return run;
}

pub fn verify(b: *std.Build, script: []const u8, args: []const []const u8) *std.Build.Step.Run {
    const run = action(b, "run-python", &.{});
    run.addFileArg2(b.path(script), .{});
    run.addArgs(args);
    return run;
}
