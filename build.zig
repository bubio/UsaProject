const std = @import("std");
const builtin = @import("builtin");
const np2_sources = @import("src/np2_sources.zig");

pub fn build(b: *std.Build) void {
    const target_query = b.standardTargetOptionsQueryOnly(.{});
    var resolved_target_query = target_query;

    // Pin minimum OS versions to keep release compatibility policy stable.
    const is_macos_target = if (resolved_target_query.os_tag) |os_tag|
        os_tag == .macos
    else
        builtin.os.tag == .macos;
    if (resolved_target_query.os_version_min == null) {
        if (is_macos_target) {
            resolved_target_query.os_version_min = .{
                .semver = .{ .major = 13, .minor = 5, .patch = 0 },
            };
        } else {
            const is_windows_target = if (resolved_target_query.os_tag) |os_tag|
                os_tag == .windows
            else
                builtin.os.tag == .windows;
            if (is_windows_target) {
                // Windows support policy: require Windows 11 or later.
                resolved_target_query.os_version_min = .{
                    .windows = .win11_zn,
                };
            }
        }
    }

    const target = b.resolveTargetQuery(resolved_target_query);
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "UsaProject",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("sokol", dep_sokol.module("sokol"));

    // 日本語 GUI フォント (M PLUS 1p Regular, OFL)。.ttf を匿名 import すると
    // `@import("ja_font")` が埋め込みバイト列 ([]const u8) を返す。
    exe.root_module.addAnonymousImport("ja_font", .{
        .root_source_file = b.path("assets/fonts/MPLUS1p-Regular.ttf"),
    });

    // NFD-extended (native file dialogs). We pull the C/Obj-C sources via
    // build.zig.zon and compile only the backend matching the target OS.
    const dep_nfd = b.dependency("nfd_extended", .{});
    exe.root_module.addIncludePath(dep_nfd.path("src/include"));
    const nfd_cflags = &[_][]const u8{ "-fno-sanitize=all" };
    switch (target.result.os.tag) {
        .macos => {
            exe.root_module.addCSourceFile(.{
                .file = dep_nfd.path("src/nfd_cocoa.m"),
                .flags = nfd_cflags,
            });
            exe.root_module.linkFramework("AppKit", .{});
            exe.root_module.linkFramework("UniformTypeIdentifiers", .{});
        },
        .windows => {
            exe.root_module.addCSourceFile(.{
                .file = dep_nfd.path("src/nfd_win.cpp"),
                .flags = nfd_cflags,
            });
            exe.root_module.linkSystemLibrary("ole32", .{});
            exe.root_module.linkSystemLibrary("uuid", .{});
            exe.root_module.linkSystemLibrary("shell32", .{});
            // Link as a GUI app (not console) so launching the .exe does not
            // also spawn a console ("DOS") window alongside the main window.
            exe.subsystem = .Windows;
            // Embed a manifest that sets the process ACP to UTF-8 so
            // C runtime fopen()/CRT path APIs round-trip non-ASCII paths.
            exe.root_module.addWin32ResourceFile(.{
                .file = b.path("assets/UsaProject.rc"),
            });
        },
        .linux => {
            exe.root_module.addCSourceFile(.{
                .file = dep_nfd.path("src/nfd_portal.cpp"),
                .flags = nfd_cflags,
            });
            exe.root_module.linkSystemLibrary("dbus-1", .{});
        },
        else => {},
    }

    // NP2kai Core Integration
    const np2_includes = &[_][]const u8{
        "src",
        "core/np2kai",
        "core/np2kai/common",
        "core/np2kai/i386c",
        "core/np2kai/i386c/ia32",
        "core/np2kai/mem",
        "core/np2kai/io",
        "core/np2kai/vram",
        "core/np2kai/sound",
        "core/np2kai/fdd",
        "core/np2kai/diskimage",
        "core/np2kai/bios",
        "core/np2kai/cbus",
        "core/np2kai/font",
        "core/np2kai/generic",
        "core/np2kai/trap",
        "core/np2kai/codecnv",
        "core/np2kai/embed",
        "core/np2kai/wab",
    };

    for (np2_includes) |include| {
        exe.root_module.addIncludePath(b.path(include));
    }

    const common_defines = &[_][]const u8{
        "BIOS_IO_EMULATION",
        "OSLANG_UTF8",
        "SUPPORT_8BPP",
        "SUPPORT_16BPP",
        "SUPPORT_24BPP",
        "SUPPORT_32BPP",
        "SUPPORT_CRT15KHZ",
        "SUPPORT_FAST_MEMORYCHECK",
        "SUPPORT_FMGEN",
        "SUPPORT_GPIB",
        "SUPPORT_HRTIMER",
        "SUPPORT_KAI_IMAGES",
        "SUPPORT_LARGE_HDD",
        "SUPPORT_NORMALDISP",
        "SUPPORT_PC9861K",
        "SUPPORT_PX",
        "SUPPORT_RESUME",
        "SUPPORT_RS232C_FIFO",
        "SUPPORT_S98",
        "SUPPORT_SCSI",
        "SUPPORT_SMPU98",
        "SUPPORT_SOFTKBD=0",
        "SUPPORT_SOUND_SB16",
        "SUPPORT_STATSAVE=10",
        "SUPPORT_UTF8",
        "SUPPORT_V30EXT",
        "SUPPORT_V30ORIGINAL",
        "SUPPORT_VIDEOFILTER",
        "SUPPORT_VPCVHD",
        "USE_MAME",
        "USE_MAME_BSD",
        "VAEG_FIX",
        "VERMOUTH_LIB",
        "CPUCORE_IA32",
        "IA32_PAGING_EACHSIZE",
        "IA32_REBOOT_ON_PANIC",
        "SUPPORT_CRT31KHZ",
        "SUPPORT_PC9801_119",
        "SUPPORT_PC9821",
        "SUPPORT_IDEIO",
        "SUPPORT_LARGE_MEMORY",
        "SUPPORT_FPU_DOSBOX2_COMPATIBLE",
        "SUPPORT_PEGC",
        "SUPPORT_GAMEPORT",
        "SUPPORT_IDEIO_48BIT",
        "SUPPORT_FPU_SOFTFLOAT3",
        "SUPPORT_PCI",
        "USE_FPU",
        "USE_MMX",
        "USE_3DNOW",
        "USE_SSE",
        "USE_SSE2",
        "USE_SSE3",
        "USE_SSSE3",
        "USE_SSE4_1",
        "USE_SSE4_2",
        "USE_SSE4A",
        "USE_TSC",
        "USE_FASTPAGING",
        "USE_VME",
        "SUPPORT_MEMDBG32",
        "SUPPORT_HOSTDRV",
        "OSLINEBREAK_LF",
        "__LIBRETRO__",
        "NP2KAI_GIT_TAG=\"v0.86\"",
        "NP2KAI_GIT_HASH=\"zig\"",
        "DOSIOCALL=",
        "_snprintf=snprintf",
    };

    const os_define: []const u8 = switch (target.result.os.tag) {
        .macos => "MACOS",
        .windows => "_WINDOWS",
        .linux => "LINUX",
        else => "UNKNOWN_OS",
    };

    const np2_defines = b.allocator.alloc([]const u8, common_defines.len + 1) catch unreachable;
    @memcpy(np2_defines[0..common_defines.len], common_defines);
    np2_defines[common_defines.len] = os_define;

    const warning_flags = &[_][]const u8{
        "-Wno-implicit-function-declaration",
        "-Wno-incompatible-pointer-types",
        "-Wno-int-conversion",
        "-Wno-return-type",
        "-Wno-parentheses",
        "-Wno-format",
        "-Wno-switch",
        "-Wno-tautological-constant-out-of-range-compare",
        "-fno-sanitize=all",
    };

    const full_flags = b.allocator.alloc([]const u8, np2_defines.len + warning_flags.len) catch unreachable;
    for (np2_defines, 0..) |define, i| {
        full_flags[i] = b.fmt("-D{s}", .{define});
        const eq_idx = std.mem.indexOfScalar(u8, define, '=');
        if (eq_idx) |idx| {
            exe.root_module.addCMacro(define[0..idx], define[idx + 1 ..]);
        } else {
            exe.root_module.addCMacro(define, "1");
        }
    }
    for (warning_flags, 0..) |flag, i| {
        full_flags[np2_defines.len + i] = flag;
    }

    exe.root_module.addCSourceFiles(.{
        .files = np2_sources.sources,
        .flags = full_flags,
    });

    const platform_sources = &[_][]const u8{
        "src/np2_glue.c",
        "src/np2_path.c",
    };
    exe.root_module.addCSourceFiles(.{
        .files = platform_sources,
        .flags = full_flags,
    });

    // Nuklear GUI (via sokol_nuklear)
    exe.root_module.addIncludePath(b.path("third_party/nuklear"));
    exe.root_module.addIncludePath(b.path("third_party/sokol"));
    exe.root_module.addIncludePath(dep_sokol.path("src/sokol/c"));
    const nk_backend_define: []const u8 = switch (target.result.os.tag) {
        .macos => "SOKOL_METAL",
        .windows => "SOKOL_D3D11",
        .linux => "SOKOL_GLCORE",
        else => "SOKOL_GLCORE",
    };
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/nuklear_impl.c"),
        .flags = &.{ "-fno-sanitize=all", b.fmt("-D{s}", .{nk_backend_define}) },
    });

    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;

    b.installArtifact(exe);

    // macOS App Bundle Support
    if (target.result.os.tag == .macos) {
        const bundle_step = b.step("bundle", "Create macOS App Bundle (.app)");

        const app_name = "UsaProject.app";
        const contents_dir = b.fmt("{s}/Contents", .{app_name});
        const macos_dir = b.fmt("{s}/MacOS", .{contents_dir});
        const resources_dir = b.fmt("{s}/Resources", .{contents_dir});

        // 1. Create directory structure
        const mkdir = b.addSystemCommand(&.{ "mkdir", "-p" });
        mkdir.addArgs(&.{
            b.getInstallPath(.prefix, macos_dir),
            b.getInstallPath(.prefix, resources_dir),
        });
        bundle_step.dependOn(&mkdir.step);

        // 2. Copy the executable
        const cp_exe = b.addSystemCommand(&.{ "cp" });
        cp_exe.addArtifactArg(exe);
        cp_exe.addArg(b.getInstallPath(.prefix, macos_dir));
        cp_exe.step.dependOn(&mkdir.step);
        bundle_step.dependOn(&cp_exe.step);

        // 3. Copy Info.plist
        const cp_plist = b.addSystemCommand(&.{ "cp", "assets/Info.plist" });
        cp_plist.addArg(b.getInstallPath(.prefix, b.fmt("{s}/Info.plist", .{contents_dir})));
        cp_plist.step.dependOn(&mkdir.step);
        bundle_step.dependOn(&cp_plist.step);

        // 4. Copy AppIcon.icns
        const cp_icon = b.addSystemCommand(&.{ "cp", "assets/AppIcon.icns" });
        cp_icon.addArg(b.getInstallPath(.prefix, b.fmt("{s}/AppIcon.icns", .{resources_dir})));
        cp_icon.step.dependOn(&mkdir.step);
        bundle_step.dependOn(&cp_icon.step);

        // 5. Copy the bundled font's OFL license text. M PLUS 1p is embedded in
        // the binary, so the SIL Open Font License 1.1 + copyright notice must
        // travel with the distributed .app per the OFL's redistribution terms.
        const cp_ofl = b.addSystemCommand(&.{ "cp", "assets/fonts/OFL.txt" });
        cp_ofl.addArg(b.getInstallPath(.prefix, b.fmt("{s}/MPLUS1p-OFL.txt", .{resources_dir})));
        cp_ofl.step.dependOn(&mkdir.step);
        bundle_step.dependOn(&cp_ofl.step);

        // 6. Touch the bundle to refresh Finder cache
        const touch = b.addSystemCommand(&.{ "touch" });
        touch.addArg(b.getInstallPath(.prefix, app_name));
        touch.step.dependOn(&cp_exe.step);
        touch.step.dependOn(&cp_plist.step);
        touch.step.dependOn(&cp_icon.step);
        touch.step.dependOn(&cp_ofl.step);
        bundle_step.dependOn(&touch.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ----- Tests -----
    const test_step = b.step("test", "Run unit tests");

    // Pure-Zig tests (pixel conversion, datadir resolution)
    const zig_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zig_tests.root_module.addImport("sokol", dep_sokol.module("sokol"));
    for (np2_includes) |include| {
        zig_tests.root_module.addIncludePath(b.path(include));
    }
    for (np2_defines) |define| {
        const eq_idx = std.mem.indexOfScalar(u8, define, '=');
        if (eq_idx) |idx| {
            zig_tests.root_module.addCMacro(define[0..idx], define[idx + 1 ..]);
        } else {
            zig_tests.root_module.addCMacro(define, "1");
        }
    }
    // NFD
    zig_tests.root_module.addIncludePath(dep_nfd.path("src/include"));

    // archive.zig's decodeName calls codecnv_sjistoutf8 (CP932 → UTF-8). The
    // function is self-contained in sjisucs2.c (table-driven, no NP2kai globals),
    // so we link just that one source — like path_tests' minimal C linkage.
    zig_tests.root_module.addCSourceFiles(.{
        .files = &.{"core/np2kai/codecnv/sjisucs2.c"},
        .flags = full_flags,
    });

    zig_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(zig_tests).step);

    // C-path tests (exercises np2_path.c via Zig externs).
    // We link only np2_path.c + milstr.c so tests don't drag in NP2kai globals.
    const path_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    path_tests.root_module.addImport("sokol", dep_sokol.module("sokol"));
    for (np2_includes) |include| {
        path_tests.root_module.addIncludePath(b.path(include));
    }
    path_tests.root_module.addCSourceFiles(.{
        .files = &.{ "src/np2_path.c", "core/np2kai/common/milstr.c" },
        .flags = full_flags,
    });
    for (np2_defines) |define| {
        const eq_idx = std.mem.indexOfScalar(u8, define, '=');
        if (eq_idx) |idx| {
            path_tests.root_module.addCMacro(define[0..idx], define[idx + 1 ..]);
        } else {
            path_tests.root_module.addCMacro(define, "1");
        }
    }
    path_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(path_tests).step);
}
