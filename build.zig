const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terms: []const u8 = b.option(
        []const u8,
        "terms",
        "Specify extra terminals",
    ) orelse "";
    var enable_aquaterm: bool = false;
    var enable_latex: bool = false;

    const vc_ltl_dir: ?[]const u8 = b.option(
        []const u8,
        "vc-ltl-dir",
        "The special TargetPlatform directory of VC-LTL",
    );

    const xwin_dir: ?[]const u8 = b.option(
        []const u8,
        "xwin-dir",
        "The directory output by xwin splat",
    );

    const mimalloc: bool = b.option(
        bool,
        "mimalloc",
        "Enable mimalloc",
    ) orelse false;

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "libgnuplot",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    if (optimize != .Debug) {
        lib.want_lto = target.result.ofmt != .macho;
        lib.root_module.strip = true;
        if (target.result.os.tag != .windows)
            lib.root_module.unwind_tables = .none;
    }

    const upstream = b.dependency("gnuplot", .{ .target = target, .optimize = optimize });

    lib.root_module.addCMacro("HAVE_CONFIG_H", "");

    const config_h_wf = blk: {
        const required_headers = .{
            "string",    "stdlib",   "unistd",    "errno",
            "sys/param", "sys/time", "sys/types", "limits",
            "float",     "locale",   "math",      "malloc",
            "time",      "stdbool",  "inttypes",  "fenv",
            "complex",   "dirent",   "values",
        };

        var array_list: std.ArrayList(u8) = .empty;

        inline for (required_headers) |header| {
            const upper = try std.ascii.allocUpperString(b.allocator, header);
            std.mem.replaceScalar(u8, upper, '/', '_');

            try array_list.appendSlice(b.allocator, "#if __has_include(<" ++ header ++ ".h>)\n#define HAVE_");
            try array_list.appendSlice(b.allocator, upper);
            try array_list.appendSlice(b.allocator, "_H 1\n#endif\n");
        }

        try array_list.appendSlice(b.allocator, "#include \"extra_config.h\"\n");

        if (target.result.abi == .msvc) {
            inline for (.{
                "isatty",   "stricmp", "strnicmp", "strdup",
                "wcsnicmp", "read",    "fileno",   "setmode",
            }) |sym| try array_list.appendSlice(b.allocator, "#define " ++ sym ++ " _" ++ sym ++ "\n");

            // MSVC does not support C99 complex number
            // See https://learn.microsoft.com/cpp/c-runtime-library/complex-math-support
            try array_list.appendSlice(b.allocator, "#undef HAVE_COMPLEX_H\n");
        }

        if (mimalloc)
            try array_list.appendSlice(b.allocator, "#include \"mimalloc-override.h\"\n");

        const wf = b.addWriteFile("config.h", array_list.items);
        lib.addIncludePath(wf.getDirectory());
        break :blk wf;
    };

    const extra_config = addExtraConfigHeader(b, target.result, "extra_config.h");
    lib.addConfigHeader(extra_config);

    if (target.result.abi == .msvc)
        lib.root_module.addCMacro("__MSC__", "");

    if (target.result.os.tag == .wasi) {
        lib.root_module.addCMacro("_WASI_EMULATED_SIGNAL", "");
        lib.root_module.addCMacro("__wasm_exception_handling__", "");
        lib.addCSourceFile(.{
            .file = b.path("src/wasm_stub.c"),
            .flags = &.{"-std=gnu23"},
        });
    }

    {
        // Custom terminals
        const wf = b.addWriteFiles();

        {
            var array_list: std.ArrayList(u8) = .empty;

            // Unset default drivers
            inline for (.{ "POSTSCRIPT", "PSLATEX" }) |driver|
                try array_list.appendSlice(b.allocator, "#undef " ++ driver ++ "_DRIVER\n");

            if (target.result.os.tag == .wasi) {
                extra_config.addValues(.{
                    // Disable bitmap support only without the block terminal
                    .NO_BITMAP_SUPPORT = true,
                });
            } else {
                try array_list.appendSlice(b.allocator,
                    \\#include_next "dumb.trm"
                    \\
                );

                inline for (.{ "block.trm", "emf.trm", "pict2e.trm" }) |driver|
                    try array_list.appendSlice(b.allocator, "#include \"" ++ driver ++ "\"\n");
            }

            // Common terminals
            try array_list.appendSlice(b.allocator,
                \\#include "svg.trm"
                \\
            );

            var term_list = std.mem.tokenizeScalar(u8, terms, ',');
            while (term_list.next()) |term| {
                if (std.mem.eql(u8, term, "aquaterm")) {
                    if (target.result.os.tag != .macos) continue;
                    enable_aquaterm = true;
                    extra_config.addValues(.{
                        .HAVE_FRAMEWORK_AQUATERM = true,
                    });
                    lib.linkFramework("Foundation");
                    lib.linkFramework("AquaTerm");
                } else if (std.mem.eql(u8, term, "cetz")) {
                    enable_latex = true;
                } else if (!std.mem.eql(u8, term, "debug")) continue;
                try array_list.appendSlice(b.allocator, "#include \"");
                try array_list.appendSlice(b.allocator, term);
                try array_list.appendSlice(b.allocator, ".trm\"\n");
            }
            _ = wf.add("dumb.trm", array_list.items);
        }

        {
            // Minify `svg.trm`
            const upstream_dir = upstream.builder.build_root.handle;
            const file = try upstream_dir.openFile("term/svg.trm", .{});
            defer file.close();

            const stat = try file.stat();
            var file_reader = file.reader(&.{});
            const bytes = try file_reader.interface.allocRemaining(b.allocator, .limited(stat.size + 1));

            var size = stat.size;
            inline for (.{
                .{ "TERM_TABLE_START (domterm_driver)", "#if 0\n" },
                .{ "#define LAST_TERM domterm_driver", "\n#endif" },
                .{ "SVG_emit_doctype)", "0)" },
                .{ "SVG_hypertext\t", "0" },
            }) |pair| {
                const diff = pair[0].len - pair[1].len;
                const times = std.mem.replace(u8, bytes[0..size], pair[0], pair[1], bytes);
                size -= diff * times;
            }

            inline for (.{
                "strcmp(term->name, \"domterm\") == ",
                "SVG_mouseable = TRUE;",
                "SVG_standalone = TRUE;",
            }) |str| {
                const times = std.mem.replace(u8, bytes[0..size], str, "", bytes);
                size -= str.len * times;
            }
            _ = wf.add("svg.trm", bytes[0..size]);
        }

        lib.addIncludePath(wf.getDirectory());
    }

    {
        // Minify `term_api.h`
        const upstream_dir = upstream.builder.build_root.handle;
        const file = try upstream_dir.openFile("src/term_api.h", .{});
        defer file.close();

        const stat = try file.stat();
        var file_reader = file.reader(&.{});
        const bytes = try file_reader.interface.allocRemaining(b.allocator, .limited(stat.size + 1));

        var array_list: std.ArrayList(u8) = .empty;
        try array_list.appendSlice(b.allocator, &.{
            // `TERM_IS_POSTSCRIPT` is used by `lua.trm`, `post.trm` and `pslatex.trm`
            4,
            // `TERM_REUSES_BOXTEXT` is used by `cairo.trm` and `pslatex.trm`
            18,
            // `TERM_COLORBOX_IMAGE` is used by `cairo.trm` and `qt.trm`
            19,
        });
        if (!enable_latex)
            // `TERM_IS_LATEX`
            try array_list.append(b.allocator, 14);

        var size = stat.size;
        for (array_list.items) |num| {
            const needle = b.fmt("(1<<{d})", .{num});
            const diff = needle.len - 1;
            const times = std.mem.replace(u8, bytes[0..size], needle, "0", bytes);
            size -= diff * times;
        }

        const wf = b.addWriteFile("term_api.h", bytes[0..size]);
        lib.addIncludePath(wf.getDirectory());
    }

    lib.addIncludePath(upstream.path("src"));
    lib.addIncludePath(b.path("term"));
    lib.addIncludePath(upstream.path("term"));

    {
        const srcs = .{
            "alloc.c",    "amos_airy.c",  "axis.c",      "bitmap.c",
            "boundary.c", "breaders.c",   "color.c",     "command.c",
            "contour.c",  "complexfun.c", "datablock.c", "datafile.c",
            "dynarray.c", "encoding.c",   "eval.c",      "filters.c",
            "fit.c",      "gadgets.c",    "getcolor.c",  "gplocale.c",
            "graph3d.c",  "graphics.c",   "help.c",      "hidden3d.c",
            "history.c",  "internal.c",   "interpol.c",  "jitter.c",
            "libcerf.c",  "loadpath.c",   "marks.c",     "matrix.c",
            "misc.c",     "multiplot.c",  "parse.c",     "plot2d.c",
            "plot3d.c",   "pm3d.c",       "save.c",      "scanner.c",
            "set.c",      "show.c",       "specfun.c",   "standard.c",
            "stats.c",    "stdfn.c",      "tables.c",    "tabulate.c",
            "term.c",     "time.c",       "unset.c",     "util.c",
            "util3d.c",   "version.c",    "voxelgrid.c", "vplot.c",
            "watch.c",
        };

        // Avoid depending on original headers
        const wf = b.addWriteFiles();
        inline for (srcs) |source| {
            if (!std.mem.eql(u8, source, "command.c") and
                !std.mem.eql(u8, source, "save.c"))
                _ = wf.addCopyFile(upstream.path(b.pathJoin(&.{ "src", source })), source);
        }

        {
            // Modify `command.c` to disable help in Windows as well
            const upstream_dir = upstream.builder.build_root.handle;
            const file = try upstream_dir.openFile("src/command.c", .{});
            defer file.close();

            const stat = try file.stat();
            var file_reader = file.reader(&.{});
            const bytes = try file_reader.interface.allocRemaining(b.allocator, .limited(stat.size + 1));

            var size = stat.size;
            const pair = .{ "#ifdef NO_GIH\n#ifdef _WIN32", "#ifdef NO_GIH\n#if 0" };
            const diff = pair[0].len - pair[1].len;
            const times = std.mem.replace(u8, bytes, pair[0], pair[1], bytes);
            size -= diff * times;

            _ = wf.add("command.c", bytes[0..size]);
        }

        {
            // Modify `save.c` to disable save changes in Wasm
            const upstream_dir = upstream.builder.build_root.handle;
            const file = try upstream_dir.openFile("src/save.c", .{});
            defer file.close();

            const stat = try file.stat();
            var file_reader = file.reader(&.{});
            const bytes = try file_reader.interface.allocRemaining(b.allocator, .limited(stat.size + 1));

            const pair = .{
                "!defined(MSDOS)",
                "!defined(MSDOS) && !defined(__wasm__)",
            };
            const save_c = try std.mem.replaceOwned(u8, b.allocator, bytes, pair[0], pair[1]);

            _ = wf.add("save.c", save_c);
        }

        lib.addCSourceFiles(.{
            .language = if (enable_aquaterm) .objective_c else .c,
            .root = wf.getDirectory(),
            .files = &srcs,
            .flags = &.{"-fno-sanitize=undefined"},
        });
    }

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "gnuplot",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    if (mimalloc) {
        if (b.lazyDependency("mimalloc", .{
            .target = target,
            .optimize = optimize,
            .override = false,
        })) |mimalloc_dep| {
            inline for (.{ lib, exe }) |compile|
                compile.linkLibrary(mimalloc_dep.artifact("mimalloc"));
        }
    }

    exe.linkLibrary(lib);
    exe.root_module.addCMacro("HAVE_CONFIG_H", "");
    exe.addConfigHeader(extra_config);
    exe.addIncludePath(config_h_wf.getDirectory());
    exe.addIncludePath(upstream.path("src"));
    exe.addIncludePath(upstream.path("term"));

    const use_llvm = b.option(bool, "use-llvm", "Use Zig's LLVM backend");
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    if (optimize != .Debug) {
        exe.want_lto = target.result.ofmt != .macho;
        exe.root_module.strip = true;
        if (target.result.os.tag != .windows)
            exe.root_module.unwind_tables = .none;
    }

    {
        // Set information of the distribution
        exe.root_module.addCMacro("DEVELOPMENT_VERSION", "");
        exe.root_module.addCMacro("DIST_CONTACT", "\"https://github.com/KNnut/ziguplot\"");
    }

    {
        const srcs = .{ "gpexecute.c", "mouse.c", "plot.c", "readline.c", "xdg.c" };

        const wf = b.addWriteFiles();
        inline for (srcs) |source| {
            if (!std.mem.eql(u8, source, "mouse.c") and
                !std.mem.eql(u8, source, "plot.c"))
                _ = wf.addCopyFile(upstream.path(b.pathJoin(&.{ "src", source })), source);
        }

        {
            // Minify `mouse.c`
            const upstream_dir = upstream.builder.build_root.handle;
            const file = try upstream_dir.openFile("src/mouse.c", .{});
            defer file.close();

            const stat = try file.stat();
            var file_reader = file.reader(&.{});
            const bytes = try file_reader.interface.allocRemaining(b.allocator, .limited(stat.size + 1));

            var size = stat.size;
            inline for (.{
                .{
                    \\fprintf(stderr, "`%s:%d oops.'\n", __FILE__, __LINE__)
                    ,
                    \\FPRINTF((stderr,"`%s:%d oops.'\n",__FILE__,__LINE__))
                },
                .{
                    \\fprintf(stderr, "%s:%d unrecognized event type %d\n", __FILE__, __LINE__, ge->type)
                    ,
                    \\FPRINTF((stderr,"%s:%d unrecognized event type %d\n",__FILE__,__LINE__,ge->type))
                },
            }) |pair| {
                const diff = pair[0].len - pair[1].len;
                const times = std.mem.replace(u8, bytes, pair[0], pair[1], bytes);
                size -= diff * times;
            }

            _ = wf.add("mouse.c", bytes[0..size]);
        }

        {
            // Modify `plot.c` to disable save changes in Wasm
            const upstream_dir = upstream.builder.build_root.handle;
            const file = try upstream_dir.openFile("src/plot.c", .{});
            defer file.close();

            const stat = try file.stat();
            var file_reader = file.reader(&.{});
            const bytes = try file_reader.interface.allocRemaining(b.allocator, .limited(stat.size + 1));

            const pair = .{
                "!defined(MSDOS)",
                "!defined(MSDOS) && !defined(__wasm__)",
            };
            const plot_c = try std.mem.replaceOwned(u8, b.allocator, bytes, pair[0], pair[1]);

            _ = wf.add("plot.c", plot_c);
        }
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &srcs,
            .flags = &.{"-fno-sanitize=undefined"},
        });
    }

    if (enable_aquaterm) {
        if (b.lazyDependency("aquaterm", .{ .target = target })) |aquaterm| {
            const framework_dir = aquaterm.namedWriteFiles("framework").getDirectory();
            inline for (.{ lib, exe }) |compile|
                compile.addFrameworkPath(framework_dir);
        }
    }

    if (target.result.os.tag == .wasi) {
        exe.root_module.addCMacro("_WASI_EMULATED_SIGNAL", "");
        exe.root_module.addCMacro("__wasm_exception_handling__", "");
        exe.addCSourceFile(.{
            .file = b.path("src/wasm_stub_sjlj.c"),
            .flags = &.{"-std=c23"},
        });
    }

    if (target.result.os.tag == .windows) {
        // Windows
        const win_srcs = .{
            "wd2d.cpp",  "wgdiplus.cpp", "wgnuplib.c", "wgraph.c",
            "winmain.c", "wpause.c",     "wprinter.c",
        };
        exe.addCSourceFiles(.{
            .root = upstream.path("src/win"),
            .files = &win_srcs,
            .flags = &.{"-fno-sanitize=undefined"},
        });

        inline for (.{
            "comctl32", "comdlg32", "ole32",  "msimg32",
            "shlwapi",  "winspool", "gdi32",  "gdiplus",
            "d2d1",     "d3d11",    "dwrite", "prntvpt",
        }) |dll| exe.linkSystemLibrary(dll);

        exe.subsystem = .Console;
        if (target.result.abi == .msvc) {
            // Setup MSVC
            exe.root_module.addCMacro("__MSC__", "");
            inline for (.{ "user32", "shell32" }) |dll|
                exe.linkSystemLibrary(dll);
        } else {
            // Setup MinGW
            exe.mingw_unicode_entry_point = true;
            exe.linkLibCpp();
        }
        {
            // Add the rc file
            const wf = b.addWriteFiles();
            const rc = wf.add("gnuplot.rc",
                \\#include <windows.h>
                \\GRPICON ICON "grpicon.ico"
                \\CREATEPROCESS_MANIFEST_RESOURCE_ID RT_MANIFEST "gnuplot.exe.manifest"
            );
            _ = wf.add("gnuplot.exe.manifest",
                \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                \\<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
                \\<asmv3:application>
                \\<asmv3:windowsSettings>
                \\<dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
                \\<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
                \\</asmv3:windowsSettings>
                \\</asmv3:application>
                \\</assembly>
            );
            exe.addWin32ResourceFile(.{
                .file = rc,
                .include_paths = &.{
                    upstream.path("src/win"),
                },
            });
        }
    }
    b.installArtifact(exe);

    // Setup cross-compilation
    const compiles = blk: {
        var array_list: std.ArrayList(*std.Build.Step.Compile) = .empty;
        try array_list.appendSlice(b.allocator, &.{ lib, exe });
        if (mimalloc) {
            if (b.lazyDependency("mimalloc", .{
                .target = target,
                .optimize = optimize,
                .override = false,
            })) |mimalloc_dep| try array_list.append(b.allocator, mimalloc_dep.artifact("mimalloc"));
        }
        break :blk try array_list.toOwnedSlice(b.allocator);
    };

    if (target.result.abi == .msvc) {
        for (compiles) |compile| {
            inline for (.{
                "_CRT_SECURE_NO_WARNINGS",
                "_CRT_NONSTDC_NO_WARNINGS",
            }) |macro| compile.root_module.addCMacro(macro, "");
        }

        const vc_ltl_arch = switch (target.result.cpu.arch) {
            .aarch64 => "ARM64",
            .x86 => "Win32",
            .x86_64 => "x64",
            else => unreachable,
        };
        const xwin_arch = switch (target.result.cpu.arch) {
            .aarch64 => "arm64",
            .x86 => "x86",
            .x86_64 => "x64",
            else => unreachable,
        };

        if (vc_ltl_dir) |vc_ltl|
            exe.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ vc_ltl, "lib", vc_ltl_arch }) });

        if (xwin_dir) |xwin| {
            const xwin_include_dir = b.pathJoin(&.{ xwin, "sdk", "include", "ucrt" });
            const xwin_sys_include_dir = b.pathJoin(&.{ xwin, "crt", "include" });
            for (compiles) |compile| {
                inline for (.{
                    xwin_sys_include_dir,
                    xwin_include_dir,
                }) |include| compile.addSystemIncludePath(.{ .cwd_relative = include });
                inline for (.{ "um", "shared" }) |dir|
                    compile.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ xwin, "sdk", "include", dir }) });
            }

            const xwin_crt_dir = b.pathJoin(&.{ xwin, "sdk", "lib", "ucrt", xwin_arch });
            const xwin_msvc_lib_dir = b.pathJoin(&.{ xwin, "crt", "lib", xwin_arch });
            const kernel32_lib_dir = b.pathJoin(&.{ xwin, "sdk", "lib", "um", xwin_arch });
            inline for (.{
                xwin_msvc_lib_dir,
                xwin_crt_dir,
                kernel32_lib_dir,
            }) |library| exe.addLibraryPath(.{ .cwd_relative = library });

            {
                // Set LibC file
                const include_dir = if (vc_ltl_dir) |vc_ltl| b.pathJoin(&.{ vc_ltl, "..", "header" }) else xwin_include_dir;
                const sys_include_dir = if (vc_ltl_dir) |vc_ltl| b.pathJoin(&.{ vc_ltl, "header" }) else xwin_sys_include_dir;
                const crt_dir = if (vc_ltl_dir) |vc_ltl| b.pathJoin(&.{ vc_ltl, "lib", vc_ltl_arch }) else xwin_crt_dir;
                const msvc_lib_dir = if (vc_ltl_dir) |_| crt_dir else xwin_msvc_lib_dir;
                const wf = b.addWriteFiles();
                const libc_txt = wf.add("libc.txt", b.fmt(
                    \\include_dir={s}
                    \\sys_include_dir={s}
                    \\crt_dir={s}
                    \\msvc_lib_dir={s}
                    \\kernel32_lib_dir={s}
                    \\gcc_dir=
                , .{
                    include_dir,
                    sys_include_dir,
                    crt_dir,
                    msvc_lib_dir,
                    kernel32_lib_dir,
                }));
                for (compiles) |compile|
                    compile.setLibCFile(libc_txt);
            }
        }
    }
    if (b.sysroot) |sysroot| {
        // Set LibC file
        const include_dir = b.pathJoin(&.{ sysroot, "usr", "include" });
        const sys_include_dir = include_dir;
        const crt_dir = b.pathJoin(&.{ sysroot, "usr", "lib" });

        const wf = b.addWriteFiles();
        const libc_txt = wf.add("libc.txt", b.fmt(
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\gcc_dir=
        , .{
            include_dir,
            sys_include_dir,
            crt_dir,
        }));
        for (compiles) |compile|
            compile.setLibCFile(libc_txt);

        if (enable_aquaterm) {
            const sys_frameworks_dir = b.pathJoin(&.{ sysroot, "System", "Library", "Frameworks" });
            inline for (.{ lib, exe }) |compile|
                compile.addSystemFrameworkPath(.{ .cwd_relative = sys_frameworks_dir });
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn addExtraConfigHeader(b: *std.Build, target: std.Target, include_path: []const u8) *std.Build.Step.ConfigHeader {
    const extra_config = b.addConfigHeader(
        .{ .include_path = include_path },
        .{
            .STDC_HEADERS = true,
            .HAVE_ATEXIT = true,
            .HAVE_VFPRINTF = true,
            .HAVE_STRERROR = true,
            .HAVE_STRCSPN = true,
            .HAVE_STRDUP = true,
            .HAVE_STRICMP = true,
            .HAVE_STRNICMP = true,
            .HAVE_STRNLEN = true,
            .HAVE_STRCHR = true,
            .HAVE_STRSTR = true,
            .HAVE_GETCWD = true,
            .HAVE_USLEEP = true,
            .HAVE_SLEEP = true,
            .HAVE_CSQRT = true,
            .HAVE_CABS = true,
            .HAVE_CLOG = true,
            .HAVE_CEXP = true,
            .HAVE_LGAMMA = true,
            .HAVE_TGAMMA = true,
            .HAVE_ERF = true,
            .HAVE_ERFC = true,
            .HAVE_DECL_SIGNGAM = true,
            .HAVE_MEMCPY = true,
            .HAVE_MEMMOVE = true,
            .HAVE_MEMSET = true,
            .HAVE_TIME_T_IN_TIME_H = true,

            .USE_POLAR_GRID = true,
            .USE_STATS = true,
            .USE_WATCHPOINTS = true,
            .USE_FUNCTIONBLOCKS = true,
            .WITH_CHI_SHAPES = true,
            .WITH_EXTRA_COORDINATE = true,

            .NO_GIH = true,
            .HELPFILE = "",
            .SHORT_TERMLIST = true,
            .DEFAULTTERM = switch (target.os.tag) {
                .wasi => "svg",
                .windows => "windows",
                else => "dumb",
            },
        },
    );

    if (target.os.tag != .wasi)
        extra_config.addValues(.{
            .PIPES = true,
            .USE_MOUSE = true,
            .READLINE = true,
            .GNUPLOT_HISTORY = true,
        });

    if (target.os.tag != .windows) {
        extra_config.addValues(.{
            .HAVE_STPCPY = true,
            .HAVE_STRNDUP = true,
            .HAVE_STRLCPY = true,
        });
    }

    if (target.abi == .msvc)
        extra_config.addValues(.{
            .USE_FAKEPIPES = true,
        })
    else
        extra_config.addValues(.{
            .HAVE_STRCASECMP = true,
            .HAVE_STRNCASECMP = true,
        });

    if (target.os.tag == .windows)
        extra_config.addValues(.{
            .UNICODE = true,
            ._UNICODE = true,
            .WIN_IPC = true,
            .HAVE_GDIPLUS = true,
            .HAVE_D2D = true,
            .HAVE_D2D11 = true,
            .HAVE_PRNTVPT = true,
            .WGP_CONSOLE = true,
            .USE_WINGDI = true,
        })
    else
        // Non-Windows
        extra_config.addValues(.{
            .PIPE_IPC = true,
        });

    return extra_config;
}
