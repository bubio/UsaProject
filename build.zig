const std = @import("std");
const np2_sources = @import("src/np2_sources.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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

    const np2_defines = &[_][]const u8{
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
        "SUPPORT_VPCVHD",
        // "SUPPORT_VGA_MODEX", // Disabled for diagnostics
        // "SUPPORT_WAB",
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
        "MACOS",
        "NP2KAI_GIT_TAG=\"v0.86\"",
        "NP2KAI_GIT_HASH=\"zig\"",
        "DOSIOCALL=",
        "_snprintf=snprintf",
    };

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

    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;

    b.installArtifact(exe);

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
