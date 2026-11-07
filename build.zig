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
    b.getInstallStep().dependOn(&b.addInstallFile(dev_context.manifest, "bin/cutrans-context.json").step);
    const build_context_install = b.addInstallFile(dev_context.manifest, "cutrans-context.json");
    b.getInstallStep().dependOn(&build_context_install.step);
    b.getInstallStep().dependOn(&b.addInstallFile(installed_context.manifest, "installation/cutrans-context.json").step);

    // ── VM 桌面:zglfw 窗口 + wgpu-native 呈现 + zgui 控件(no_backend)──
    // ImGui 的 glfw/wgpu 后端从 zgui 捆绑源码自编译,链接我们自己的 wgpu_native
    // ——全工程只有一套 WebGPU 实现,不引入 Dawn。
    const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    const zgui_dep = b.dependency("zgui", .{ .target = target, .optimize = optimize, .backend = .no_backend });
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
    const runtime = b.createModule(.{ .root_source_file = b.path("runtime/root.zig"), .target = target, .optimize = optimize });
    runtime.addImport("vne", vne);
    runtime.addImport("assets", assets);
    runtime.addImport("ports", ports);
    const palette = b.createModule(.{ .root_source_file = b.path("uikit/palette.zig"), .target = target, .optimize = optimize });
    const uikit = b.createModule(.{ .root_source_file = b.path("uikit/root.zig"), .target = target, .optimize = optimize });
    uikit.addImport("palette", palette);
    uikit.addImport("runtime", runtime);
    uikit.addImport("zgui", zgui_dep.module("root"));
    const gpu = b.createModule(.{ .root_source_file = b.path("gpu/root.zig"), .target = target, .optimize = optimize });
    gpu.addImport("zgui", zgui_dep.module("root"));
    const vm_client = b.createModule(.{ .root_source_file = b.path("consoles/gui/vm_client.zig"), .target = target, .optimize = optimize });
    vm_client.addImport("runtime", runtime);
    vm_client.addImport("vne", vne);
    const editor = b.createModule(.{ .root_source_file = b.path("apps/editor/editor.zig"), .target = target, .optimize = optimize });
    editor.addImport("runtime", runtime);
    editor.addImport("vne", vne);
    editor.addImport("uikit", uikit);
    editor.addImport("ports", ports);
    editor.addImport("vm_client", vm_client);
    editor.addImport("zgui", zgui_dep.module("root"));
    const library_app = b.createModule(.{ .root_source_file = b.path("apps/library/library.zig"), .target = target, .optimize = optimize });
    library_app.addImport("runtime", runtime);
    library_app.addImport("vne", vne);
    library_app.addImport("uikit", uikit);
    library_app.addImport("ports", ports);
    library_app.addImport("vm_client", vm_client);
    library_app.addImport("zgui", zgui_dep.module("root"));
    const cli = b.createModule(.{ .root_source_file = b.path("consoles/cli/cli.zig"), .target = target, .optimize = optimize });
    cli.addImport("runtime", runtime);
    cli.addImport("uikit", uikit);
    cli.addImport("zgui", zgui_dep.module("root"));
    const system_workspace = b.createModule(.{ .root_source_file = b.path("consoles/gui/workspace.zig"), .target = target, .optimize = optimize });
    system_workspace.addImport("runtime", runtime);
    system_workspace.addImport("uikit", uikit);
    system_workspace.addImport("zgui", zgui_dep.module("root"));
    cli.addImport("system_workspace", system_workspace);
    const desktop = b.createModule(.{ .root_source_file = b.path("apps/desktop/desktop.zig"), .target = target, .optimize = optimize });
    desktop.addImport("runtime", runtime);
    desktop.addImport("uikit", uikit);
    desktop.addImport("zgui", zgui_dep.module("root"));
    desktop.addImport("system_workspace", system_workspace);
    const desktop_shell = b.addLibrary(.{
        .name = "cutrans_desktop",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "zglfw", .module = zglfw_dep.module("root") },
                .{ .name = "zgui", .module = zgui_dep.module("root") },
                .{ .name = "assets", .module = assets },
                .{ .name = "ports", .module = ports },
                .{ .name = "vne", .module = vne },
                .{ .name = "runtime", .module = runtime },
                .{ .name = "uikit", .module = uikit },
                .{ .name = "gpu", .module = gpu },
                .{ .name = "editor", .module = editor },
                .{ .name = "library", .module = library_app },
                .{ .name = "vm_client", .module = vm_client },
                .{ .name = "cli", .module = cli },
                .{ .name = "desktop", .module = desktop },
                .{ .name = "system_workspace", .module = system_workspace },
            },
        }),
    });
    desktop_shell.root_module.linkLibrary(zglfw_dep.artifact("glfw"));
    desktop_shell.root_module.linkLibrary(zgui_dep.artifact("imgui"));
    desktop_shell.root_module.addIncludePath(zgui_dep.path("libs/imgui"));
    desktop_shell.root_module.addIncludePath(zgui_dep.path("libs/imgui/backends"));
    desktop_shell.root_module.addIncludePath(b.path("third_party/wgpu/include"));
    desktop_shell.root_module.addCMacro("IMGUI_IMPL_API", "extern \"C\"");
    desktop_shell.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "");
    desktop_shell.root_module.addCSourceFile(.{
        .file = zgui_dep.path("libs/imgui/backends/imgui_impl_glfw.cpp"),
        .flags = &.{"-std=c++17"},
    });
    desktop_shell.root_module.addLibraryPath(b.path("third_party/wgpu/lib"));
    desktop_shell.root_module.linkSystemLibrary("wgpu_native.dll", .{});
    desktop_shell.root_module.linkSystemLibrary("imm32", .{});
    desktop_shell.root_module.linkSystemLibrary("dwmapi", .{});
    desktop_shell.root_module.linkSystemLibrary("ole32", .{});
    const desktop_ui_compile = b.addSystemCommand(&.{"python"});
    desktop_ui_compile.addFileArg2(b.path("apps/desktop/assets/ui/compile_ui.py"), .{});
    desktop_ui_compile.addArg("--source");
    desktop_ui_compile.addFileArg2(b.path("apps/desktop/assets/ui/desktop.json"), .{});
    desktop_ui_compile.addArg("--output");
    const desktop_ui_binary = desktop_ui_compile.addOutputFileArg2("desktop.cui", .{});
    desktop.addAnonymousImport("desktop_cui", .{ .root_source_file = desktop_ui_binary });
    b.installArtifact(desktop_shell);

    const shell_client_module = b.createModule(.{ .root_source_file = b.path("shell/root.zig"), .target = target, .optimize = optimize });
    shell_client_module.addImport("vne", vne);
    shell_client_module.addImport("ports", ports);
    vm_client.addImport("shell", shell_client_module);
    const host_module = b.createModule(.{ .root_source_file = b.path("host/root.zig"), .target = target, .optimize = optimize });
    host_module.addImport("vne", vne);
    host_module.addImport("ports", ports);
    host_module.addImport("shell", shell_client_module);
    const bootstrap_module = b.createModule(.{ .root_source_file = b.path("bootstrap/root.zig"), .target = target, .optimize = optimize });
    bootstrap_module.addImport("vne", vne);
    bootstrap_module.addImport("ports", ports);
    bootstrap_module.addImport("host", host_module);
    bootstrap_module.addImport("shell_client", shell_client_module);
    const nanoui_library_app = b.createModule(.{ .root_source_file = b.path("apps/library/nanoui.zig"), .target = target, .optimize = optimize });
    nanoui_library_app.addImport("palette", palette);
    nanoui_library_app.addImport("vne", vne);
    nanoui_library_app.addImport("shell", shell_client_module);
    nanoui_library_app.addImport("nanoui", nanoui_dep.module("nanoui"));
    const nanoui_library = b.addExecutable(.{
        .name = "cutrans_library_nanoui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/cli/nanoui_library.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bootstrap", .module = bootstrap_module },
                .{ .name = "vne", .module = vne },
                .{ .name = "nanoui_library", .module = nanoui_library_app },
            },
        }),
    });
    b.installArtifact(nanoui_library);
    const launcher = b.addExecutable(.{
        .name = "cutrans_vm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/gui/launcher.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bootstrap", .module = bootstrap_module }},
        }),
    });
    launcher.root_module.linkSystemLibrary("shell32", .{});
    launcher.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(launcher);
    b.installBinFile("third_party/wgpu/lib/wgpu_native.dll", "wgpu_native.dll");
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
    const stb = b.addLibrary(.{
        .name = "cutrans_stb",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    stb.root_module.link_libc = true;
    stb.root_module.addCSourceFile(.{ .file = b.path("runtime/stb_image_impl.c"), .flags = &.{"-std=c99"} });
    stb.root_module.addIncludePath(b.path("third_party/stb"));
    stb.root_module.addIncludePath(b.path("third_party/zgui/libs/imgui_test_engine/thirdparty/stb"));
    desktop_shell.root_module.linkLibrary(stb);
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
            .root_source_file = b.path("bootstrap/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vne", .module = vne },
                .{ .name = "ports", .module = ports },
                .{ .name = "host", .module = host_module },
                .{ .name = "shell_client", .module = shell_client_module },
            },
        }),
    });
    bootstrap.root_module.linkSystemLibrary("shell32", .{});
    bootstrap.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(bootstrap);

    const vm_host = b.addExecutable(.{
        .name = "cutrans_vm_host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/cli/vm_host.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bootstrap", .module = bootstrap_module }},
        }),
    });
    vm_host.root_module.linkSystemLibrary("shell32", .{});
    vm_host.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(vm_host);

    const vm_shell = b.addExecutable(.{
        .name = "cutrans_shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consoles/cli/vm_shell.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bootstrap", .module = bootstrap_module }},
        }),
    });
    vm_shell.root_module.linkSystemLibrary("shell32", .{});
    vm_shell.root_module.linkSystemLibrary("ole32", .{});
    b.installArtifact(vm_shell);

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

    const shell_files_step = b.step("shell-files", "Stage desktop Shell files");
    const shell_pack_step = b.step("shell-pack", "Create a desktop Shell Pack");
    var shell_files = pack_support.Files.init(b);
    shell_files.add(desktop_shell.getEmittedBin(), "cutrans_desktop.dll");
    shell_files.add(b.path("third_party/wgpu/lib/wgpu_native.dll"), "wgpu_native.dll");
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
        .{ "third_party/wgpu/LICENSE.MIT", "vm-shell/licenses/wgpu-native.txt" },
        .{ "third_party/zglfw/LICENSE", "vm-shell/licenses/zglfw.txt" },
        .{ "third_party/zglfw/libs/glfw/LICENSE.md", "vm-shell/licenses/glfw.txt" },
        .{ "third_party/zgui/LICENSE", "vm-shell/licenses/zgui.txt" },
        .{ "third_party/zgui/libs/imgui/LICENSE.txt", "vm-shell/licenses/imgui.txt" },
        .{ "third_party/stb/LICENSE", "vm-shell/licenses/stb.txt" },
        .{ "third_party/system_sdk/LICENSE", "vm-shell/licenses/system_sdk.txt" },
        .{ "assets/fonts/OFL.txt", "vm-shell/licenses/NotoSansSC-OFL.txt" },
        .{ "assets/fonts/RemixIcons-LICENSE.txt", "vm-shell/licenses/RemixIcons.txt" },
    };
    inline for (shell_sources) |source| {
        shell_files.add(if (comptime std.mem.eql(u8, source[0], "config/startup.ccb")) startup_binary else b.path(source[0]), source[1]["vm-shell/".len..]);
    }
    shell_files_step.dependOn(&shell_files.write.step);
    const shell_pack_dir = shell_files.finish("tools/build_shell_pack.py", "shell-pack.json", &.{ "--abi", "windows-x64", "--entry", "cutrans_desktop.dll" });
    const shell_install = b.addInstallDirectory(.{ .source_dir = shell_pack_dir, .install_dir = .prefix, .install_subdir = "vm-shell" });
    shell_pack_step.dependOn(&shell_install.step);
    b.getInstallStep().dependOn(&shell_install.step);

    const nanoui_files_step = b.step("nanoui-library-files", "Stage the independent NanoUI resource library Shell");
    const nanoui_pack_step = b.step("nanoui-library-pack", "Create the NanoUI resource library Shell Pack");
    var nanoui_files = pack_support.Files.init(b);
    nanoui_files.add(nanoui_library.getEmittedBin(), "cutrans_library_nanoui.exe");
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
    };
    inline for (nanoui_sources) |source| nanoui_files.add(b.path(source[0]), source[1]["nanoui-library/".len..]);
    nanoui_files_step.dependOn(&nanoui_files.write.step);
    const nanoui_pack_dir = nanoui_files.finish("tools/build_shell_pack.py", "shell-pack.json", &.{ "--abi", "windows-x64", "--entry", "cutrans_library_nanoui.exe", "--id", "nanoui-library", "--all-files" });
    const nanoui_install = b.addInstallDirectory(.{ .source_dir = nanoui_pack_dir, .install_dir = .prefix, .install_subdir = "nanoui-library" });
    nanoui_pack_step.dependOn(&nanoui_install.step);
    b.getInstallStep().dependOn(&nanoui_install.step);

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
    portable_files.add(launcher.getEmittedBin(), "cutrans_vm.exe");
    portable_files.add(diagnostics.getEmittedBin(), "cutrans_diag.exe");
    portable_files.add(bootstrap.getEmittedBin(), "cutrans_bootstrap.exe");
    portable_files.add(vm_host.getEmittedBin(), "cutrans_vm_host.exe");
    portable_files.add(vm_shell.getEmittedBin(), "cutrans_shell.exe");
    portable_files.add(b.path("third_party/wgpu/lib/wgpu_native.dll"), "wgpu_native.dll");
    portable_files.directory(runtime_pack_dir, "runtime");
    portable_files.directory(shell_pack_dir, "shell");
    portable_files.directory(nanoui_pack_dir, "nanoui-library");
    portable_files.add(startup_binary, "config/startup.ccb");
    portable_files.add(b.path("config/startup.ccmd"), "config/startup.ccmd");
    portable_files.directory(b.path("assets/commands"), "assets/commands");
    portable_files.directory(b.path("assets/examples"), "assets/examples");
    portable_files.add(b.path("packaging/README-portable.md"), "README.md");
    const portable_notices = .{
        .{ "LICENSE", "portable/licenses/Cutrans.txt" },
        .{ "third_party/wgpu/LICENSE.MIT", "portable/licenses/wgpu-native.txt" },
        .{ "third_party/zglfw/LICENSE", "portable/licenses/zglfw.txt" },
        .{ "third_party/zglfw/libs/glfw/LICENSE.md", "portable/licenses/glfw.txt" },
        .{ "third_party/zgui/LICENSE", "portable/licenses/zgui.txt" },
        .{ "third_party/zgui/libs/imgui/LICENSE.txt", "portable/licenses/imgui.txt" },
        .{ "third_party/stb/LICENSE", "portable/licenses/stb.txt" },
        .{ "third_party/system_sdk/LICENSE", "portable/licenses/system_sdk.txt" },
        .{ "assets/fonts/OFL.txt", "portable/licenses/NotoSansSC-OFL.txt" },
        .{ "assets/fonts/RemixIcons-LICENSE.txt", "portable/licenses/RemixIcons.txt" },
    };
    inline for (portable_notices) |notice| portable_files.add(b.path(notice[0]), notice[1]["portable/".len..]);
    pack_files_step.dependOn(&portable_files.write.step);
    const portable_dir = portable_files.finish("tools/build_vm_pack.py", "vm-pack.json", &.{});
    const portable_install = b.addInstallDirectory(.{ .source_dir = portable_dir, .install_dir = .prefix, .install_subdir = "portable" });
    portable_step.dependOn(&portable_install.step);

    const development_vm_manifest = pack_support.vmManifestForContext(b, portable_dir, dev_context.manifest);
    b.getInstallStep().dependOn(&b.addInstallFile(development_vm_manifest, "bin/vm-pack.json").step);

    const installer_step = b.step("installer", "Build the Windows x64 installer with portable Inno Setup");
    const installed_vm_manifest = pack_support.vmManifestForContext(b, portable_dir, installed_context.manifest);
    b.getInstallStep().dependOn(&b.addInstallFile(installed_vm_manifest, "installation/vm-pack.json").step);
    const installer_compile = b.addSystemCommand(&.{ "tools/InnoSetup/ISCC.exe", "--no-ide-signtools", "packaging/windows/installer.iss" });
    installer_compile.addFileArg2(installed_context.inno.?, .{ .prefix = "/DProductConfigFile=", .make_absolute = true });
    installer_compile.addFileArg2(installed_context.manifest, .{ .prefix = "/DInstalledContextFile=", .make_absolute = true });
    installer_compile.addFileArg2(installed_vm_manifest, .{ .prefix = "/DInstalledVMManifestFile=", .make_absolute = true });
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
    const workspace_rpc_step = b.step("verify-workspace-rpc", "Verify document requests through the distributed Host pipe");
    const workspace_rpc_verify = pack_support.verify(b, "tools/verify_workspace_rpc.py", &.{});
    workspace_rpc_verify.step.dependOn(portable_step);
    workspace_rpc_step.dependOn(&workspace_rpc_verify.step);
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
    const host_transport_step = b.step("verify-host-transport", "Verify Host pipe cancellation and stalled peer recovery");
    const host_transport_verify = pack_support.verify(b, "tools/verify_host_transport.py", &.{});
    host_transport_verify.step.dependOn(portable_step);
    host_transport_step.dependOn(&host_transport_verify.step);
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

    const verify_host_step = b.step("verify-host", "Verify independent VM Host lifecycle and recovery");
    const clean_host_user = pack_support.action(b, "clean", &.{"verification/host-user"});
    clean_host_user.step.dependOn(portable_step);
    const verify_host = pack_support.verify(b, "tools/verify_host.py", &.{});
    verify_host.step.dependOn(&clean_host_user.step);
    verify_host_step.dependOn(&verify_host.step);

    const verify_attach_step = b.step("verify-attach", "Verify Shell reattachment while the VM Host stays alive");
    const clean_attach_user = pack_support.action(b, "clean", &.{"verification/attach-user"});
    clean_attach_user.step.dependOn(portable_step);
    const verify_attach = pack_support.verify(b, "tools/verify_attach.py", &.{});
    verify_attach.step.dependOn(&clean_attach_user.step);
    verify_attach_step.dependOn(&verify_attach.step);

    const verify_assets_step = b.step("verify-assets", "Verify ephemeral assets and independent Content Snapshots");
    const clean_asset_user = pack_support.action(b, "clean", &.{"verification/asset-user"});
    clean_asset_user.step.dependOn(portable_step);
    const verify_assets = pack_support.verify(b, "tools/verify_assets.py", &.{});
    verify_assets.step.dependOn(&clean_asset_user.step);
    verify_assets_step.dependOn(&verify_assets.step);

    const verify_shell_step = b.step("verify-shell", "Start the desktop through the VM and verify startup logs");
    const clean_shell_user = pack_support.action(b, "clean", &.{"verification/shell-user"});
    clean_shell_user.step.dependOn(portable_step);
    const verify_shell = pack_support.verify(b, "tools/verify_shell.py", &.{});
    verify_shell.step.dependOn(&clean_shell_user.step);
    verify_shell_step.dependOn(&verify_shell.step);

    const nanoui_test_step = b.step("test-nanoui", "Run independently vendored NanoUI tests without WebView2");
    const nanoui_tests = b.addTest(.{ .root_module = nanoui_dep.module("nanoui") });
    const run_nanoui_tests = b.addRunArtifact(nanoui_tests);
    nanoui_test_step.dependOn(&run_nanoui_tests.step);

    const nanoui_library_test_step = b.step("test-nanoui-library", "Compile the NanoUI resource library frontend");
    const nanoui_library_tests = b.addTest(.{ .root_module = nanoui_library_app });
    const run_nanoui_library_tests = b.addRunArtifact(nanoui_library_tests);
    nanoui_library_test_step.dependOn(&run_nanoui_library_tests.step);
    nanoui_library_test_step.dependOn(&nanoui_library.step);

    const verify_nanoui_library_step = b.step("verify-nanoui-library", "Verify the NanoUI resource library through a real attached Host");
    const clean_nanoui_library = pack_support.action(b, "clean", &.{"verification/nanoui-library"});
    clean_nanoui_library.step.dependOn(b.getInstallStep());
    clean_nanoui_library.step.dependOn(runtime_pack_step);
    clean_nanoui_library.step.dependOn(nanoui_pack_step);
    const verify_nanoui_library = pack_support.verify(b, "tools/verify_nanoui_library.py", &.{});
    verify_nanoui_library.step.dependOn(&clean_nanoui_library.step);
    verify_nanoui_library_step.dependOn(&verify_nanoui_library.step);

    const verify_nanoui_portable_step = b.step("verify-nanoui-portable", "Verify the packaged NanoUI Shell in an isolated portable copy");
    const clean_nanoui_portable = pack_support.action(b, "clean", &.{"verification/nanoui-portable"});
    clean_nanoui_portable.step.dependOn(portable_step);
    const verify_nanoui_portable = pack_support.verify(b, "tools/verify_nanoui_library.py", &.{"--distribution=portable"});
    verify_nanoui_portable.step.dependOn(&clean_nanoui_portable.step);
    verify_nanoui_portable_step.dependOn(&verify_nanoui_portable.step);

    const test_step = b.step("test", "Run headless runtime and UI model tests");
    test_support.addModule(b, test_step, vne);
    const runtime_suites = test_support.RuntimeSuites{
        .b = b,
        .step = test_step,
        .target = target,
        .optimize = optimize,
        .vne = vne,
        .runtime = runtime,
        .assets = assets,
        .ports = ports,
        .stb = stb,
    };
    inline for (.{
        "native_api",        "replay",          "input_replay",  "input_actions",     "input_recording",
        "escapement",        "playback",        "assets",        "external_sources",  "resource_library",
        "apps",              "render",          "capabilities",  "vm_pack",           "document_commands",
        "document_requests", "job_ledger",      "export_inputs", "resource_versions", "resource_requests",
        "request_receipts",  "source_boundary",
    }) |name| runtime_suites.add("runtime/" ++ name ++ ".zig");
    inline for (.{ "command", "tasks", "task_journal", "history", "history_journal", "documents" }) |name|
        test_support.addSource(b, test_step, "runtime/" ++ name ++ ".zig", target, optimize, &.{.{ .name = "vne", .module = vne }});
    test_support.addSource(b, test_step, "runtime/startup.zig", target, optimize, &.{ .{ .name = "assets", .module = assets }, .{ .name = "ports", .module = ports } });
    runtime_suites.add("runtime/paths.zig");
    inline for (.{ "paths", "file_identity", "file_dialog", "process", "library" }) |name| runtime_suites.add("ports/" ++ name ++ ".zig");
    test_support.addModule(b, test_step, host_module);
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
        .root_source_file = b.path("runtime/image.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vne", .module = vne }},
    }) });
    image_tests.root_module.linkLibrary(stb);
    test_support.addModuleTests(b, test_step, image_tests);
    const workspace_tests = b.addTest(.{ .root_module = system_workspace });
    workspace_tests.root_module.linkLibrary(zgui_dep.artifact("imgui"));
    workspace_tests.root_module.link_libcpp = true;
    const run_workspace_tests = b.addRunArtifact(workspace_tests);
    test_step.dependOn(&run_workspace_tests.step);
    const cli_tests = b.addTest(.{ .root_module = cli });
    cli_tests.root_module.linkLibrary(zgui_dep.artifact("imgui"));
    cli_tests.root_module.link_libcpp = true;
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);
    const uikit_tests = b.addTest(.{ .root_module = uikit });
    uikit_tests.root_module.linkLibrary(zgui_dep.artifact("imgui"));
    uikit_tests.root_module.link_libcpp = true;
    const run_uikit_tests = b.addRunArtifact(uikit_tests);
    test_step.dependOn(&run_uikit_tests.step);
    const backend_tests = b.addTest(.{ .root_module = desktop_shell.root_module });
    const run_backend_tests = b.addRunArtifact(backend_tests);
    run_backend_tests.setCwd(b.path(""));
    run_backend_tests.setEnvironmentVariable("PATH", b.fmt("third_party/wgpu/lib;{s}", .{b.graph.environ_map.get("PATH") orelse ""}));
    test_step.dependOn(&run_backend_tests.step);

    const portable_run_step = b.step("run-portable", "Run the portable Cutrans VM");
    const portable_run = pack_support.action(b, "run-portable", &.{});
    portable_run.step.dependOn(portable_step);
    portable_run_step.dependOn(&portable_run.step);

    const vm_run_step = b.step("run-vm", "Run the Cutrans VM desktop");
    const vm_run = b.addRunArtifact(launcher);
    vm_run_step.dependOn(&vm_run.step);
    vm_run.step.dependOn(b.getInstallStep());
}
