const std = @import("std");

pub fn addModuleTests(b: *std.Build, step: *std.Build.Step, tests: *std.Build.Step.Compile) void {
    const run = b.addRunArtifact(tests);
    step.dependOn(&run.step);
}

pub fn addModule(b: *std.Build, step: *std.Build.Step, module: *std.Build.Module) void {
    addModuleTests(b, step, b.addTest(.{ .root_module = module }));
}

pub fn addSource(b: *std.Build, step: *std.Build.Step, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, imports: []const std.Build.Module.Import) void {
    addModule(b, step, b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }));
}

/// Runtime integration tests share the same explicit imports and native closure.
/// Pure protocol/document tests use addSource instead.
pub const RuntimeSuites = struct {
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    vne: *std.Build.Module,
    runtime: *std.Build.Module,
    imaging: *std.Build.Module,
    assets: *std.Build.Module,
    ports: *std.Build.Module,
    stb: *std.Build.Step.Compile,

    pub fn add(self: RuntimeSuites, path: []const u8) void {
        const module = self.b.createModule(.{
            .root_source_file = self.b.path(path),
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vne", .module = self.vne },       .{ .name = "runtime", .module = self.runtime },
                .{ .name = "imaging", .module = self.imaging }, .{ .name = "assets", .module = self.assets },
                .{ .name = "ports", .module = self.ports },
            },
        });
        module.linkLibrary(self.stb);
        if (self.target.result.os.tag == .windows) {
            module.linkSystemLibrary("shell32", .{});
            module.linkSystemLibrary("ole32", .{});
        }
        addModule(self.b, self.step, module);
    }
};

/// Runs on the build host, independently of the Windows distribution target.
/// No desktop, OS Port, C codec, or GPU module is configured for this suite.
pub fn addCore(b: *std.Build, optimize: std.lang.Optimize) void {
    const step = b.step("test-core", "Run native semantic, document, history and task tests without a desktop");
    const target = b.graph.host;
    const vne = b.createModule(.{ .root_source_file = b.path("vne/root.zig"), .target = target, .optimize = optimize });
    addModule(b, step, vne);
    addSource(b, step, "vne/environment.zig", target, optimize, &.{});
    inline for (.{ "command", "documents", "tasks", "task_journal", "history", "history_journal" }) |name|
        addSource(b, step, "runtime/" ++ name ++ ".zig", target, optimize, &.{.{ .name = "vne", .module = vne }});
}
