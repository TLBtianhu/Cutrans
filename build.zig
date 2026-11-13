const std = @import("std");
const test_support = @import("build_support/tests.zig");
const pack_support = @import("build_support/packs.zig");
const context_support = @import("build_support/context.zig");

pub fn build(b: *std.Build) void {
    const baseline = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
    };
    const target = b.standardTargetOptions(.{ .default_target = baseline });
    const optimize = b.standardOptimizeOption(.{});

    test_support.addCore(b, optimize);
    const automation_step = b.step("verify-automation", "Verify automation console policy and preserved process results");
    const automation_verify = pack_support.verify(b, "tools/test_automation_process.py", &.{});
    automation_step.dependOn(&automation_verify.step);
    const repository_step = b.step("verify-repository", "Audit source package coverage and repository boundaries");
    const repository_verify = pack_support.verify(b, "tools/repository_audit.py", &.{});
    repository_step.dependOn(&repository_verify.step);
    const repository_tests = pack_support.verify(b, "tools/test_repository_audit.py", &.{});
    repository_step.dependOn(&repository_tests.step);
    const architecture_step = b.step("verify-architecture", "Reject direct cross-layer imports at the Shell/VM boundary");
    const architecture_verify = pack_support.verify(b, "tools/verify_architecture.py", &.{});
    architecture_step.dependOn(&architecture_verify.step);
    // Native semantic tests configure no desktop, native DLLs or UI dependencies.
    const core_only = b.option(bool, "core-only", "Configure only native semantic tests") orelse (b.graph.host.result.os.tag != .windows);
    if (core_only or target.result.os.tag != .windows) {
        const unavailable = b.addFail("Full Cutrans application builds currently require the Windows target; use zig build test-core -Dcore-only for native semantic tests.");
        b.getInstallStep().dependOn(&unavailable.step);
        return;
    }
    const channel = b.option([]const u8, "channel", "Artifact channel: development, preview or stable") orelse @import("vne/product.zig").default_channel;
    const dev_context = context_support.generate(b, "development", channel);
    const portable_context = context_support.generate(b, "portable", channel);
    const installed_context = context_support.generate(b, "installed", channel);
    const context_embed_run = b.addSystemCommand(&.{"python"});
    context_embed_run.addFileArg2(b.path("tools/build_context_embed.py"), .{});
    context_embed_run.addArg("--out-dir");
    const context_embed_dir = context_embed_run.addOutputDirectoryArg("context-embed");
    context_embed_run.addArg("--portable");
    context_embed_run.addFileArg2(portable_context.manifest, .{});
    context_embed_run.addArg("--installed");
    context_embed_run.addFileArg2(installed_context.manifest, .{});
    const context_blob_module = b.createModule(.{
        .root_source_file = context_embed_dir.path(b, "context_blob.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.getInstallStep().dependOn(&b.addInstallFile(dev_context.manifest, "bin/cutrans-context.json").step);
    const build_context_install = b.addInstallFile(dev_context.manifest, "cutrans-context.json");
    b.getInstallStep().dependOn(&build_context_install.step);
    b.getInstallStep().dependOn(&b.addInstallFile(installed_context.manifest, "installation/cutrans-context.json").step);

    const nanoui_dep = b.dependency("nanoui", .{
        .target = target,
        .optimize = optimize,
        .webview2 = "none",
    });

    // 多应用共享模块:依赖关系显式进构建图,禁止用 ../../ 绕过模块边界
    const assets = b.createModule(.{ .root_source_file = b.path("assets/root.zig"), .target = target, .optimize = optimize });
    const ports = b.createModule(.{ .root_source_file = b.path("ports/root.zig"), .target = target, .optimize = optimize });
    const library_probe = b.addExecutable(.{
        .name = "cutrans_library_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/library_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ports", .module = ports }},
        }),
    });
    const probe_install = b.addInstallArtifact(library_probe, .{ .dest_dir = .{ .override = .{ .custom = "verification-tools" } } });
    const library_probe_step = b.step("library-probe", "Build the verification-only native library isolation probe");
    library_probe_step.dependOn(&probe_install.step);
    const vne = b.createModule(.{ .root_source_file = b.path("vne/root.zig"), .target = target, .optimize = optimize });
    vne.addImport("context_blob", context_blob_module);
    const imaging = b.createModule(.{ .root_source_file = b.path("imaging/image.zig"), .target = target, .optimize = optimize });
    imaging.addImport("vne", vne);
    const runtime = b.createModule(.{ .root_source_file = b.path("runtime/root.zig"), .target = target, .optimize = optimize });
    runtime.addImport("vne", vne);
    runtime.addImport("imaging", imaging);
    runtime.addImport("assets", assets);
    runtime.addImport("ports", ports);
    const palette = b.createModule(.{ .root_source_file = b.path("uikit/palette.zig"), .target = target, .optimize = optimize });
    const shell_client_module = b.createModule(.{ .root_source_file = b.path("shell/root.zig"), .target = target, .optimize = optimize });
    shell_client_module.addImport("vne", vne);
    shell_client_module.addImport("ports", ports);
    const activation_module = b.createModule(.{ .root_source_file = b.path("bootstrap/activation.zig"), .target = target, .optimize = optimize });
    activation_module.addImport("vne", vne);
    activation_module.addImport("ports", ports);

    // Output directory and blob module are declared before the bootstrap
    // module is used; the payload inputs are attached after the pack steps
    // exist below. Zig resolves the whole graph after build() returns.
    const payload_embed_run = b.addSystemCommand(&.{"python"});
    payload_embed_run.addFileArg2(b.path("tools/build_payload_embed.py"), .{});
    payload_embed_run.addArg("--out-dir");
    const payload_embed_dir = payload_embed_run.addOutputDirectoryArg("payload-embed");

    const bootstrap_module = b.createModule(.{ .root_source_file = b.path("bootstrap/root.zig"), .target = target, .optimize = optimize });
    bootstrap_module.addImport("vne", vne);
    bootstrap_module.addImport("ports", ports);
    bootstrap_module.addAnonymousImport("payload_blob", .{
        .root_source_file = payload_embed_dir.path(b, "payload_blob.zig"),
        .target = target,
        .optimize = optimize,
    });
    bootstrap_module.addImport("activation", activation_module);
    const dynamic_runtime_provider = b.createModule(.{ .root_source_file = b.path("bootstrap/runtime_provider_dynamic.zig"), .target = target, .optimize = optimize });
    dynamic_runtime_provider.addImport("activation", activation_module);
    bootstrap_module.addImport("runtime_provider", dynamic_runtime_provider);
    const vm_client = b.createModule(.{ .root_source_file = b.path("consoles/gui/vm_client.zig"), .target = target, .optimize = optimize });
    vm_client.addImport("imaging", imaging);
    vm_client.addImport("vne", vne);
    vm_client.addImport("shell", shell_client_module);
    const input_bridge = b.createModule(.{ .root_source_file = b.path("consoles/gui/nanoui_input.zig"), .target = target, .optimize = optimize });
    input_bridge.addImport("vne", vne);
    input_bridge.addImport("nanoui", nanoui_dep.module("nanoui"));
    const editor = b.createModule(.{ .root_source_file = b.path("apps/editor/nanoui.zig"), .target = target, .optimize = optimize });
    editor.addImport("vne", vne);
    editor.addImport("vm_client", vm_client);
    editor.addImport("palette", palette);
    editor.addImport("nanoui", nanoui_dep.module("nanoui"));
    const nanoui_library_app = b.createModule(.{ .root_source_file = b.path("apps/library/nanoui.zig"), .target = target, .optimize = optimize });
    nanoui_library_app.addImport("palette", palette);
    nanoui_library_app.addImport("vne", vne);
    nanoui_library_app.addImport("shell", shell_client_module);
    nanoui_library_app.addImport("nanoui", nanoui_dep.module("nanoui"));
    const nanoui_console = b.createModule(.{ .root_source_file = b.path("consoles/cli/nanoui.zig"), .target = target, .optimize = optimize });
    nanoui_console.addImport("vm_client", vm_client);
    nanoui_console.addImport("vne", vne);
    nanoui_console.addImport("nanoui", nanoui_dep.module("nanoui"));
    const local_files = b.createModule(.{ .root_source_file = b.path("apps/files/nanoui.zig"), .target = target, .optimize = optimize });
    local_files.addImport("vne", vne);
    local_files.addImport("ports", ports);
    local_files.addImport("palette", palette);
    local_files.addImport("nanoui", nanoui_dep.module("nanoui"));
    const desktop_app = b.createModule(.{ .root_source_file = b.path("apps/desktop/nanoui.zig"), .target = target, .optimize = optimize });
    desktop_app.addImport("vne", vne);
    desktop_app.addImport("vm_client", vm_client);
    desktop_app.addImport("nanoui_input", input_bridge);
    desktop_app.addImport("editor", editor);
    desktop_app.addImport("nanoui_library", nanoui_library_app);
    desktop_app.addImport("nanoui_console", nanoui_console);
    desktop_app.addImport("local_files", local_files);
    desktop_app.addImport("palette", palette);
    desktop_app.addImport("nanoui", nanoui_dep.module("nanoui"));
    const stb = b.addLibrary(.{
        .name = "cutrans_stb",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    stb.root_module.link_libc = true;
    stb.root_module.addCSourceFile(.{ .file = b.path("runtime/stb_image_impl.c"), .flags = &.{"-std=c99"} });
    stb.root_module.addIncludePath(b.path("third_party/stb"));
    const static_runtime = b.addLibrary(.{
        .name = "cutrans_vm_static",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/native_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vne", .module = vne },
                .{ .name = "imaging", .module = imaging },
                .{ .name = "assets", .module = assets },
                .{ .name = "ports", .module = ports },
            },
        }),
    });
    static_runtime.root_module.linkLibrary(stb);
    static_runtime.root_module.linkSystemLibrary("shell32", .{});
    static_runtime.root_module.linkSystemLibrary("ole32", .{});
    const native_runtime = b.createModule(.{
        .root_source_file = b.path("runtime/static_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vne", .module = vne }},
    });
    const static_runtime_provider = b.createModule(.{ .root_source_file = b.path("bootstrap/runtime_provider_static.zig"), .target = target, .optimize = optimize });
    static_runtime_provider.addImport("activation", activation_module);
    static_runtime_provider.addImport("vne", vne);
    static_runtime_provider.addImport("runtime", runtime);
    static_runtime_provider.addImport("native_runtime", native_runtime);
    const unified_bootstrap = b.createModule(.{ .root_source_file = b.path("bootstrap/root.zig"), .target = target, .optimize = optimize });
    unified_bootstrap.addImport("vne", vne);
    unified_bootstrap.addImport("ports", ports);
    unified_bootstrap.addAnonymousImport("payload_blob", .{
        .root_source_file = payload_embed_dir.path(b, "payload_blob.zig"),
        .target = target,
        .optimize = optimize,
    });
    unified_bootstrap.addImport("activation", activation_module);
    unified_bootstrap.addImport("runtime_provider", static_runtime_provider);
    const unified_launcher = b.addExecutable(.{
        .name = "cutrans",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/gui/launcher.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bootstrap", .module = unified_bootstrap },
                .{ .name = "vne", .module = vne },
                .{ .name = "nanoui_desktop", .module = desktop_app },
                .{ .name = "nanoui_library", .module = nanoui_library_app },
            },
        }),
    });
    unified_launcher.root_module.linkLibrary(stb);
    unified_launcher.root_module.linkLibrary(static_runtime);
    unified_launcher.root_module.linkSystemLibrary("shell32", .{});
    unified_launcher.root_module.linkSystemLibrary("ole32", .{});
    unified_launcher.root_module.linkSystemLibrary("d3d11", .{});
    unified_launcher.root_module.linkSystemLibrary("dxgi", .{});
    unified_launcher.root_module.linkSystemLibrary("d3dcompiler_47", .{});
    b.installArtifact(unified_launcher);
    // 启动清单先由文本源码编成 CCB,再随 exe 安装;runtime 只执行二进制
    const startup_compile = b.addSystemCommand(&.{"python"});
    startup_compile.addFileArg2(b.path("config/compile_startup.py"), .{});
    startup_compile.addArg("--source");
    startup_compile.addFileArg2(b.path("config/startup.ccmd"), .{});
    startup_compile.addArg("--output");
    const startup_binary = startup_compile.addOutputFileArg2("startup.ccb", .{});
    const installed_startup = b.addInstallFile(startup_binary, "bin/config/startup.ccb");
    b.getInstallStep().dependOn(&installed_startup.step);
    b.installFile("config/startup.ccmd", "bin/config/startup.ccmd");
    b.getInstallStep().dependOn(&startup_compile.step);
    b.installDirectory(.{
        .source_dir = b.path("assets/commands"),
        .install_dir = .bin,
        .install_subdir = "assets/commands",
    });
    b.installDirectory(.{
        .source_dir = b.path("assets/examples"),
        .install_dir = .bin,
        .install_subdir = "assets/examples",
    });

    const diagnostics = b.addExecutable(.{
        .name = "cutrans_diag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/cli/diagnostics.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "runtime", .module = runtime }, .{ .name = "vne", .module = vne } },
        }),
    });
    diagnostics.root_module.linkLibrary(stb);
    diagnostics.root_module.linkSystemLibrary("shell32", .{});
    diagnostics.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(diagnostics);

    const vm_runtime = b.addLibrary(.{
        .name = "cutrans_vm_runtime",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/native_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vne", .module = vne },
                .{ .name = "runtime", .module = runtime },
                .{ .name = "imaging", .module = imaging },
                .{ .name = "assets", .module = assets },
                .{ .name = "ports", .module = ports },
            },
        }),
    });
    vm_runtime.root_module.linkLibrary(stb);
    vm_runtime.root_module.linkSystemLibrary("shell32", .{});
    vm_runtime.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(vm_runtime);

    const bootstrap = b.addExecutable(.{
        .name = "cutrans_bootstrap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/cli/vm_bootstrap.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bootstrap", .module = bootstrap_module }},
        }),
    });
    bootstrap.root_module.linkSystemLibrary("shell32", .{});
    bootstrap.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(bootstrap);

    const runtime_files_step = b.step("runtime-files", "Stage independent VM Runtime files");
    const runtime_pack_step = b.step("runtime-pack", "Create an independently loadable VM Runtime Pack");
    var runtime_files = pack_support.Files.init(b);
    runtime_files.add(vm_runtime.getEmittedBin(), "cutrans_vm_runtime.dll");
    const runtime_sources = .{
        .{ "config/startup.ccb", "vm-runtime/config/startup.ccb" },
        .{ "assets/examples/minimal.cut", "vm-runtime/assets/examples/minimal.cut" },
        .{ "assets/examples/replay.cvr", "vm-runtime/assets/examples/replay.cvr" },
        .{ "assets/examples/input.cvr", "vm-runtime/assets/examples/input.cvr" },
        .{ "assets/examples/pngtest.png", "vm-runtime/assets/examples/pngtest.png" },
        .{ "assets/examples/SOURCES.md", "vm-runtime/assets/examples/SOURCES.md" },
        .{ "assets/examples/libpng-LICENSE.txt", "vm-runtime/licenses/libpng.txt" },
        .{ "third_party/stb/LICENSE", "vm-runtime/licenses/stb.txt" },
        .{ "LICENSE", "vm-runtime/licenses/Cutrans.txt" },
    };
    inline for (runtime_sources) |source| {
        runtime_files.add(if (comptime std.mem.eql(u8, source[0], "config/startup.ccb")) startup_binary else b.path(source[0]), source[1]["vm-runtime/".len..]);
    }
    runtime_files_step.dependOn(&runtime_files.write.step);
    const runtime_pack_dir = runtime_files.finish("tools/build_runtime_pack.py", "runtime-pack.json", &.{ "--abi", "windows-x64", "--entry", "cutrans_vm_runtime.dll" });
    const runtime_install = b.addInstallDirectory(.{ .source_dir = runtime_pack_dir, .install_dir = .prefix, .install_subdir = "vm-runtime" });
    runtime_pack_step.dependOn(&runtime_install.step);
    b.getInstallStep().dependOn(&runtime_install.step);

    const shell_sources = .{
        .{ "config/startup.ccb", "vm-shell/config/startup.ccb" },
        .{ "assets/commands/00-example.ccmd", "vm-shell/assets/commands/00-example.ccmd" },
        .{ "assets/examples/minimal.cut", "vm-shell/assets/examples/minimal.cut" },
        .{ "assets/examples/replay.cvr", "vm-shell/assets/examples/replay.cvr" },
        .{ "assets/examples/input.cvr", "vm-shell/assets/examples/input.cvr" },
        .{ "assets/examples/pngtest.png", "vm-shell/assets/examples/pngtest.png" },
        .{ "assets/examples/SOURCES.md", "vm-shell/assets/examples/SOURCES.md" },
        .{ "assets/examples/libpng-LICENSE.txt", "vm-shell/assets/examples/libpng-LICENSE.txt" },
        .{ "LICENSE", "vm-shell/licenses/Cutrans.txt" },
        .{ "third_party/stb/LICENSE", "vm-shell/licenses/stb.txt" },
        .{ "third_party/nanoui/LICENSE", "vm-shell/licenses/nanoui.txt" },
        .{ "third_party/nanoui/THIRD_PARTY_NOTICES.md", "vm-shell/licenses/nanoui-THIRD_PARTY_NOTICES.md" },
        .{ "third_party/nanoui/third_party/licenses/GPUI-Apache-2.0.txt", "vm-shell/licenses/GPUI-Apache-2.0.txt" },
        .{ "third_party/nanoui/third_party/licenses/GPUI-Kit-Apache-2.0.txt", "vm-shell/licenses/GPUI-Kit-Apache-2.0.txt" },
        .{ "third_party/nanoui/third_party/licenses/gpui-motion-MIT.txt", "vm-shell/licenses/gpui-motion-MIT.txt" },
        .{ "third_party/nanoui/third_party/licenses/mygo-MIT.txt", "vm-shell/licenses/mygo-MIT.txt" },
        .{ "third_party/nanoui/third_party/licenses/Windows-Terminal-MIT.txt", "vm-shell/licenses/Windows-Terminal-MIT.txt" },
        .{ "assets/fonts/OFL.txt", "vm-shell/licenses/NotoSansSC-OFL.txt" },
        .{ "assets/fonts/RemixIcons-LICENSE.txt", "vm-shell/licenses/RemixIcons.txt" },
    };
    const nanoui_sources = .{
        .{ "assets/examples/pngtest.png", "nanoui-library/assets/examples/pngtest.png" },
        .{ "assets/examples/SOURCES.md", "nanoui-library/assets/examples/SOURCES.md" },
        .{ "assets/examples/libpng-LICENSE.txt", "nanoui-library/assets/examples/libpng-LICENSE.txt" },
        .{ "LICENSE", "nanoui-library/licenses/Cutrans.txt" },
        .{ "third_party/nanoui/LICENSE", "nanoui-library/licenses/nanoui.txt" },
        .{ "third_party/nanoui/THIRD_PARTY_NOTICES.md", "nanoui-library/licenses/nanoui-THIRD_PARTY_NOTICES.md" },
        .{ "third_party/nanoui/third_party/licenses/GPUI-Apache-2.0.txt", "nanoui-library/licenses/GPUI-Apache-2.0.txt" },
        .{ "third_party/nanoui/third_party/licenses/GPUI-Kit-Apache-2.0.txt", "nanoui-library/licenses/GPUI-Kit-Apache-2.0.txt" },
        .{ "third_party/nanoui/third_party/licenses/gpui-motion-MIT.txt", "nanoui-library/licenses/gpui-motion-MIT.txt" },
        .{ "third_party/nanoui/third_party/licenses/mygo-MIT.txt", "nanoui-library/licenses/mygo-MIT.txt" },
        .{ "third_party/nanoui/third_party/licenses/Windows-Terminal-MIT.txt", "nanoui-library/licenses/Windows-Terminal-MIT.txt" },
        .{ "assets/fonts/OFL.txt", "nanoui-library/licenses/NotoSansSC-OFL.txt" },
        .{ "assets/fonts/RemixIcons-LICENSE.txt", "nanoui-library/licenses/RemixIcons.txt" },
    };
    const payload_pack_step = b.step("payload-pack", "Create builtin NanoUI payload directories without legacy executables");
    var payload_desktop_files = pack_support.Files.init(b);
    inline for (shell_sources) |source| {
        payload_desktop_files.add(if (comptime std.mem.eql(u8, source[0], "config/startup.ccb")) startup_binary else b.path(source[0]), source[1]["vm-shell/".len..]);
    }
    const payload_desktop_dir = payload_desktop_files.finish("tools/build_shell_pack.py", "payload.json", &.{ "--abi", "windows-x64", "--entry", "builtin", "--all-files" });
    const payload_desktop_install = b.addInstallDirectory(.{ .source_dir = payload_desktop_dir, .install_dir = .prefix, .install_subdir = "payload/desktop" });
    payload_pack_step.dependOn(&payload_desktop_install.step);
    b.getInstallStep().dependOn(&payload_desktop_install.step);
    var payload_library_files = pack_support.Files.init(b);
    inline for (nanoui_sources) |source| payload_library_files.add(b.path(source[0]), source[1]["nanoui-library/".len..]);
    const payload_library_dir = payload_library_files.finish("tools/build_shell_pack.py", "payload.json", &.{ "--abi", "windows-x64", "--entry", "builtin", "--id", "nanoui-library", "--all-files" });
    const payload_library_install = b.addInstallDirectory(.{ .source_dir = payload_library_dir, .install_dir = .prefix, .install_subdir = "payload/nanoui-library" });
    payload_pack_step.dependOn(&payload_library_install.step);
    b.getInstallStep().dependOn(&payload_library_install.step);

    // The output directory and module were declared before bootstrap_module;
    // attach the pack inputs now that they exist.
    payload_embed_run.addArg("--desktop");
    payload_embed_run.addDirectoryArg(payload_desktop_dir);
    payload_embed_run.addArg("--library");
    payload_embed_run.addDirectoryArg(payload_library_dir);

    const verify_runtime_step = b.step("verify-runtime", "Load an independent VM Runtime and verify document restoration");
    const clean_runtime_data = pack_support.action(b, "clean", &.{"verification/runtime-data"});
    clean_runtime_data.step.dependOn(b.getInstallStep());
    clean_runtime_data.step.dependOn(runtime_pack_step);
    const verify_runtime = pack_support.action(b, "diag-runtime", &.{});
    verify_runtime.step.dependOn(&clean_runtime_data.step);
    verify_runtime_step.dependOn(&verify_runtime.step);

    const pack_files_step = b.step("pack-files", "Stage portable content before manifest generation");
    const portable_step = b.step("portable", "Create a self-contained portable directory");
    portable_step.dependOn(&build_context_install.step);
    var portable_files = pack_support.Files.init(b);
    portable_files.add(portable_context.manifest, "cutrans-context.json");
    portable_files.add(unified_launcher.getEmittedBin(), "cutrans.exe");
    portable_files.add(diagnostics.getEmittedBin(), "cutrans_diag.exe");
    portable_files.add(bootstrap.getEmittedBin(), "cutrans_bootstrap.exe");
    portable_files.directory(runtime_pack_dir, "runtime");
    portable_files.directory(payload_desktop_dir, "payload/desktop");
    portable_files.directory(payload_library_dir, "payload/nanoui-library");
    portable_files.add(startup_binary, "config/startup.ccb");
    portable_files.add(b.path("config/startup.ccmd"), "config/startup.ccmd");
    portable_files.directory(b.path("assets/commands"), "assets/commands");
    portable_files.directory(b.path("assets/examples"), "assets/examples");
    portable_files.add(b.path("packaging/README-portable.md"), "README.md");
    const portable_notices = .{
        .{ "LICENSE", "portable/licenses/Cutrans.txt" },
        .{ "third_party/stb/LICENSE", "portable/licenses/stb.txt" },
        .{ "third_party/nanoui/LICENSE", "portable/licenses/nanoui.txt" },
        .{ "third_party/nanoui/THIRD_PARTY_NOTICES.md", "portable/licenses/nanoui-THIRD_PARTY_NOTICES.md" },
        .{ "third_party/nanoui/third_party/licenses/GPUI-Apache-2.0.txt", "portable/licenses/GPUI-Apache-2.0.txt" },
        .{ "third_party/nanoui/third_party/licenses/GPUI-Kit-Apache-2.0.txt", "portable/licenses/GPUI-Kit-Apache-2.0.txt" },
        .{ "third_party/nanoui/third_party/licenses/gpui-motion-MIT.txt", "portable/licenses/gpui-motion-MIT.txt" },
        .{ "third_party/nanoui/third_party/licenses/mygo-MIT.txt", "portable/licenses/mygo-MIT.txt" },
        .{ "third_party/nanoui/third_party/licenses/Windows-Terminal-MIT.txt", "portable/licenses/Windows-Terminal-MIT.txt" },
    };
    inline for (portable_notices) |notice| portable_files.add(b.path(notice[0]), notice[1]["portable/".len..]);
    pack_files_step.dependOn(&portable_files.write.step);
    const portable_dir = portable_files.finish("tools/build_vm_pack.py", "vm-pack.json", &.{});
    const portable_install = b.addInstallDirectory(.{ .source_dir = portable_dir, .install_dir = .prefix, .install_subdir = "portable" });
    portable_step.dependOn(&portable_install.step);

    const single_step = b.step("portable-single", "Stage the one-executable portable payload (context and payload embedded)");
    single_step.dependOn(&b.addInstallFile(unified_launcher.getEmittedBin(), "single/cutrans.exe").step);
    const single_verify_step = b.step("verify-single-exe", "Verify the one-executable portable artifact end to end");
    const single_verify = pack_support.verify(b, "tools/verify_single_exe.py", &.{});
    single_verify.step.dependOn(single_step);
    single_verify_step.dependOn(&single_verify.step);

    const development_vm_manifest = pack_support.vmManifestForContext(b, portable_dir, dev_context.manifest);
    b.getInstallStep().dependOn(&b.addInstallFile(development_vm_manifest, "bin/vm-pack.json").step);

    const installer_step = b.step("installer", "Build the Windows x64 installer with portable Inno Setup");
    const installer_compile = b.addSystemCommand(&.{ "tools/InnoSetup/ISCC.exe", "--no-ide-signtools", "packaging/windows/installer.iss" });
    installer_compile.addFileArg2(installed_context.inno.?, .{ .prefix = "/DProductConfigFile=", .make_absolute = true });
    installer_compile.addDirectoryArg2(pack_support.installed("portable"), .{ .prefix = "/DPortableRoot=", .make_absolute = true });
    installer_compile.addDirectoryArg2(pack_support.installed("installer"), .{ .prefix = "/O", .make_absolute = true });
    installer_compile.step.dependOn(portable_step);
    installer_step.dependOn(&installer_compile.step);
    const isolation_step = b.step("verify-isolation", "Verify launch and native-library isolation without system registration");
    const isolation_verify = pack_support.verify(b, "tools/verify_isolation.py", &.{});
    isolation_verify.step.dependOn(portable_step);
    isolation_verify.step.dependOn(b.getInstallStep());
    isolation_verify.step.dependOn(library_probe_step);
    isolation_step.dependOn(&isolation_verify.step);
    const edit_commit_step = b.step("verify-edit-commit", "Verify distributed edit failure atomicity and stable node identity");
    const edit_commit_verify = pack_support.verify(b, "tools/verify_edit_commit.py", &.{});
    edit_commit_verify.step.dependOn(portable_step);
    edit_commit_step.dependOn(&edit_commit_verify.step);
    const workspace_step = b.step("verify-workspace", "Verify distributed document versions, receipts and coherent snapshots");
    const workspace_verify = pack_support.verify(b, "tools/verify_workspace.py", &.{});
    workspace_verify.step.dependOn(portable_step);
    workspace_step.dependOn(&workspace_verify.step);
    const jobs_step = b.step("verify-jobs", "Verify durable export jobs and autonomous Host scheduling");
    const jobs_verify = pack_support.verify(b, "tools/verify_jobs.py", &.{});
    jobs_verify.step.dependOn(portable_step);
    jobs_step.dependOn(&jobs_verify.step);
    const jobs_async_step = b.step("verify-jobs-async", "Verify unlocked export work, durable cancellation and explicit retries");
    const jobs_async_verify = pack_support.verify(b, "tools/verify_jobs_async.py", &.{});
    jobs_async_verify.step.dependOn(portable_step);
    jobs_async_step.dependOn(&jobs_async_verify.step);
    const resource_versions_step = b.step("verify-resource-versions", "Verify retained Source versions across edits, jobs and restarts");
    const resource_versions_verify = pack_support.verify(b, "tools/verify_resource_versions.py", &.{});
    resource_versions_verify.step.dependOn(portable_step);
    resource_versions_step.dependOn(&resource_versions_verify.step);
    const source_identity_step = b.step("verify-source-identity", "Verify real file identities and explicit legacy authorization confirmation");
    const source_identity_verify = pack_support.verify(b, "tools/verify_source_identity.py", &.{});
    source_identity_verify.step.dependOn(portable_step);
    source_identity_step.dependOn(&source_identity_verify.step);
    const resource_operations_step = b.step("verify-resource-operations", "Verify resource relocation, adoption, CAS and retry receipts on actual artifacts");
    const resource_operations_verify = pack_support.verify(b, "tools/verify_resource_operations.py", &.{});
    resource_operations_verify.step.dependOn(portable_step);
    resource_operations_step.dependOn(&resource_operations_verify.step);
    const resident_resources_step = b.step("verify-resident-resources", "Verify cache-first registered resources and complete RAM independent saves");
    const resident_resources_verify = pack_support.verify(b, "tools/verify_resident_resources.py", &.{});
    resident_resources_verify.step.dependOn(portable_step);
    resident_resources_step.dependOn(&resident_resources_verify.step);
    const registration_step = b.step("verify-resource-registration", "Verify generic read-only registration and independent consumer delivery");
    const registration_verify = pack_support.verify(b, "tools/verify_resource_registration.py", &.{});
    registration_verify.step.dependOn(portable_step);
    registration_step.dependOn(&registration_verify.step);
    const work_documents_step = b.step("verify-work-documents", "Verify working drafts, fixed inputs and persistent receipts on actual artifacts");
    const work_documents_verify = pack_support.verify(b, "tools/verify_work_documents.py", &.{});
    work_documents_verify.step.dependOn(portable_step);
    work_documents_step.dependOn(&work_documents_verify.step);
    const local_sources_step = b.step("verify-local-sources", "Verify one-level local browsing, preview and explicit registration");
    const local_sources_verify = pack_support.verify(b, "tools/verify_local_sources.py", &.{});
    local_sources_verify.step.dependOn(portable_step);
    local_sources_step.dependOn(&local_sources_verify.step);
    const static_runtime_step = b.step("verify-static-runtime", "Verify the built-in Runtime without a Runtime directory and retain dynamic fallback");
    const static_runtime_verify = pack_support.verify(b, "tools/verify_static_runtime.py", &.{});
    static_runtime_verify.step.dependOn(portable_step);
    static_runtime_step.dependOn(&static_runtime_verify.step);
    const payload_step = b.step("verify-payload", "Verify builtin NanoUI payload without legacy Shell files and explicit fallback");
    const payload_verify = pack_support.verify(b, "tools/verify_payload.py", &.{});
    payload_verify.step.dependOn(portable_step);
    payload_step.dependOn(&payload_verify.step);
    const preview_step = b.step("verify-preview", "Verify VM preview frames through a real Host and hidden Desktop Shell");
    const preview_verify = pack_support.verify(b, "tools/verify_preview.py", &.{});
    preview_verify.step.dependOn(portable_step);
    preview_step.dependOn(&preview_verify.step);
    const write_order_step = b.step("verify-write-order", "Verify canonical document tails and the save recovery marker");
    const write_order_verify = pack_support.verify(b, "tools/verify_write_order.py", &.{});
    write_order_verify.step.dependOn(portable_step);
    write_order_step.dependOn(&write_order_verify.step);
    const safe_exit_step = b.step("verify-safe-exit", "Verify environment exit admission, job draining, retry and NanoUI draft protection");
    const safe_exit_verify = pack_support.verify(b, "tools/verify_safe_exit.py", &.{});
    safe_exit_verify.step.dependOn(portable_step);
    safe_exit_step.dependOn(&safe_exit_verify.step);
    const artifact_step = b.step("verify-installer-artifact", "Probe the actual installer preflight without registering an installation");
    const artifact_verify = pack_support.verify(b, "tools/verify_windows_installer.py", &.{"--artifact-check"});
    artifact_verify.step.dependOn(installer_step);
    artifact_step.dependOn(&artifact_verify.step);

    const verify_installer_step = b.step("verify-installer", "Verify isolated install, update, document opening, and uninstall");
    const verify_installer = pack_support.verify(b, "tools/verify_windows_installer.py", &.{});
    verify_installer.step.dependOn(installer_step);
    verify_installer_step.dependOn(&verify_installer.step);

    const verify_installer_headless_step = b.step("verify-installer-headless", "Verify isolated install, NanoUI, update and uninstall without opening the legacy GUI");
    const verify_installer_headless = pack_support.verify(b, "tools/verify_windows_installer.py", &.{"--skip-gui"});
    verify_installer_headless.step.dependOn(installer_step);
    verify_installer_headless_step.dependOn(&verify_installer_headless.step);

    const diag_step = b.step("diag", "Run the development document diagnostic");
    const diag_run = pack_support.action(b, "diag-development", &.{});
    diag_run.step.dependOn(b.getInstallStep());
    diag_step.dependOn(&diag_run.step);

    const diag_user_step = b.step("diag-user", "Verify a clean portable user environment");
    const clean_verification_data = pack_support.action(b, "clean", &.{"verification/portable-data"});
    clean_verification_data.step.dependOn(portable_step);
    const diag_user = pack_support.action(b, "diag-portable", &.{});
    diag_user.step.dependOn(&clean_verification_data.step);
    const assert_portable_pure = pack_support.action(b, "assert-portable-pure", &.{});
    assert_portable_pure.step.dependOn(&diag_user.step);
    diag_user_step.dependOn(&assert_portable_pure.step);

    const clean_runtime_user = pack_support.action(b, "clean", &.{"verification/runtime-user"});
    clean_runtime_user.step.dependOn(portable_step);
    clean_runtime_user.step.dependOn(&verify_runtime.step);
    const verify_runtime_user = pack_support.verify(b, "tools/verify_runtime.py", &.{});
    verify_runtime_user.step.dependOn(&clean_runtime_user.step);
    verify_runtime_step.dependOn(&verify_runtime_user.step);

    const verify_replay_step = b.step("verify-replay", "Verify deterministic VM replay in isolated user environments");
    const clean_replay_user = pack_support.action(b, "clean", &.{"verification/replay-user"});
    clean_replay_user.step.dependOn(portable_step);
    const verify_replay = pack_support.verify(b, "tools/verify_replay.py", &.{});
    verify_replay.step.dependOn(&clean_replay_user.step);
    verify_replay_step.dependOn(&verify_replay.step);

    const verify_input_step = b.step("verify-input", "Verify semantic input recording and replay through the distributed Runtime");
    const clean_input_user = pack_support.action(b, "clean", &.{"verification/input-user"});
    clean_input_user.step.dependOn(portable_step);
    const verify_input = pack_support.verify(b, "tools/verify_input.py", &.{});
    verify_input.step.dependOn(&clean_input_user.step);
    verify_input_step.dependOn(&verify_input.step);

    const verify_playback_step = b.step("verify-playback", "Drive distributed Runtime playback with the real monotonic clock");
    const clean_playback_user = pack_support.action(b, "clean", &.{"verification/playback-user"});
    clean_playback_user.step.dependOn(portable_step);
    const verify_playback = pack_support.verify(b, "tools/verify_playback.py", &.{});
    verify_playback.step.dependOn(&clean_playback_user.step);
    verify_playback_step.dependOn(&verify_playback.step);

    const verify_assets_step = b.step("verify-assets", "Verify ephemeral assets and independent Content Snapshots");
    const clean_asset_user = pack_support.action(b, "clean", &.{"verification/asset-user"});
    clean_asset_user.step.dependOn(portable_step);
    const verify_assets = pack_support.verify(b, "tools/verify_assets.py", &.{});
    verify_assets.step.dependOn(&clean_asset_user.step);
    verify_assets_step.dependOn(&verify_assets.step);

    const nanoui_test_step = b.step("test-nanoui", "Run independently vendored NanoUI tests without WebView2");
    const nanoui_tests = b.addTest(.{ .root_module = nanoui_dep.module("nanoui") });
    const run_nanoui_tests = b.addRunArtifact(nanoui_tests);
    nanoui_test_step.dependOn(&run_nanoui_tests.step);
    const nanoui_chrome_step = b.step("verify-nanoui-chrome", "Run the hidden-window custom chrome/native frame regression through test-nanoui");
    nanoui_chrome_step.dependOn(nanoui_test_step);

    const nanoui_library_test_step = b.step("test-nanoui-library", "Compile the NanoUI resource library frontend");
    const nanoui_library_tests = b.addTest(.{ .root_module = nanoui_library_app });
    const run_nanoui_library_tests = b.addRunArtifact(nanoui_library_tests);
    nanoui_library_test_step.dependOn(&run_nanoui_library_tests.step);
    nanoui_library_test_step.dependOn(&unified_launcher.step);

    const test_step = b.step("test", "Run headless runtime and UI model tests");
    test_support.addModule(b, test_step, vne);
    // A module root alone discovers no tests: Zig only analyses reachable
    // declarations, so vne/root.zig re-exports contributed nothing. Canonical
    // .cut and atomic-write invariants are asserted here explicitly.
    test_support.addSource(b, test_step, "vne/documents.zig", target, optimize, &.{});
    test_support.addSource(b, test_step, "vne/lifecycle.zig", target, optimize, &.{});
    test_support.addSource(b, test_step, "vne/environment_control.zig", target, optimize, &.{});
    test_support.addSource(b, test_step, "vne/job_driver.zig", target, optimize, &.{});
    const runtime_suites = test_support.RuntimeSuites{
        .b = b,
        .step = test_step,
        .target = target,
        .optimize = optimize,
        .vne = vne,
        .runtime = runtime,
        .imaging = imaging,
        .assets = assets,
        .ports = ports,
        .stb = stb,
    };
    inline for (.{
        "native_api",        "replay",          "input_replay",  "input_actions",     "input_recording",
        "escapement",        "playback",        "assets",        "external_sources",  "resource_library",
        "apps",              "render",          "capabilities",  "vm_pack",           "document_commands",
        "document_requests", "job_ledger",      "export_inputs", "resource_versions", "resource_requests",
        "request_receipts",  "source_boundary", "work_files",    "work_requests",     "local_sources",
    }) |name| runtime_suites.add("runtime/" ++ name ++ ".zig");
    inline for (.{ "tasks", "task_journal", "history", "history_journal" }) |name|
        test_support.addSource(b, test_step, "runtime/" ++ name ++ ".zig", target, optimize, &.{.{ .name = "vne", .module = vne }});
    test_support.addSource(b, test_step, "runtime/startup.zig", target, optimize, &.{ .{ .name = "assets", .module = assets }, .{ .name = "ports", .module = ports } });
    runtime_suites.add("runtime/paths.zig");
    inline for (.{ "paths", "file_identity", "file_dialog", "process", "library", "instance_lock" }) |name| runtime_suites.add("ports/" ++ name ++ ".zig");
    test_support.addModule(b, test_step, bootstrap_module);
    test_support.addModule(b, test_step, shell_client_module);
    test_support.addSource(b, test_step, "shell/library_client.zig", target, optimize, &.{.{ .name = "vne", .module = vne }});
    test_support.addSource(b, test_step, "shell/mirror.zig", target, optimize, &.{.{ .name = "vne", .module = vne }});
    test_support.addSource(b, test_step, "shell/resource_delivery.zig", target, optimize, &.{.{ .name = "vne", .module = vne }});
    test_support.addSource(b, test_step, "apps/library/nanoui_model.zig", target, optimize, &.{
        .{ .name = "vne", .module = vne },
        .{ .name = "shell", .module = shell_client_module },
        .{ .name = "nanoui", .module = nanoui_dep.module("nanoui") },
    });
    const vm_client_tests = b.addTest(.{ .root_module = vm_client });
    vm_client_tests.root_module.linkLibrary(stb);
    vm_client_tests.root_module.linkSystemLibrary("shell32", .{});
    vm_client_tests.root_module.linkSystemLibrary("ole32", .{});
    test_support.addModuleTests(b, test_step, vm_client_tests);
    const image_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("imaging/image.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vne", .module = vne }},
    }) });
    image_tests.root_module.linkLibrary(stb);
    test_support.addModuleTests(b, test_step, image_tests);
    const editor_tests = b.addTest(.{ .root_module = editor });
    editor_tests.root_module.linkLibrary(stb);
    test_support.addModuleTests(b, test_step, editor_tests);
    const console_tests = b.addTest(.{ .root_module = nanoui_console });
    test_support.addModuleTests(b, test_step, console_tests);
    const input_tests = b.addTest(.{ .root_module = input_bridge });
    test_support.addModuleTests(b, test_step, input_tests);
    const local_file_tests = b.addTest(.{ .root_module = local_files });
    test_support.addModuleTests(b, test_step, local_file_tests);
    const desktop_tests = b.addTest(.{ .root_module = desktop_app });
    desktop_tests.root_module.linkLibrary(stb);
    test_support.addModuleTests(b, test_step, desktop_tests);
    const nanoui_desktop_test_step = b.step("test-nanoui-desktop", "Compile the unified NanoUI desktop frontend");
    nanoui_desktop_test_step.dependOn(&desktop_tests.step);
    nanoui_desktop_test_step.dependOn(&unified_launcher.step);

    const portable_run_step = b.step("run-portable", "Run the portable Cutrans VM");
    const portable_run = pack_support.action(b, "run-portable", &.{});
    portable_run.step.dependOn(portable_step);
    portable_run_step.dependOn(&portable_run.step);

    const vm_run_step = b.step("run-vm", "Run the Cutrans VM desktop");
    const vm_run = b.addRunArtifact(unified_launcher);
    vm_run_step.dependOn(&vm_run.step);
    vm_run.step.dependOn(b.getInstallStep());
}
