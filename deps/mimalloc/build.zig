const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const override = b.option(
        bool,
        "override",
        "Static override with the object file",
    ) orelse true;

    const compile = if (override)
        b.addObject(.{
            .name = "mimalloc",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        })
    else
        b.addLibrary(.{
            .linkage = .static,
            .name = "mimalloc",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

    const upstream = b.dependency("mimalloc", .{ .target = target, .optimize = optimize });

    var cflags: std.ArrayList([]const u8) = .empty;
    try cflags.appendSlice(b.allocator, &.{
        "-Wno-unknown-pragmas",
        "-fvisibility=hidden",
        "-Wstrict-prototypes",
        "-Wno-static-in-inline",
        "-fno-builtin-malloc",
    });

    if (target.result.abi.isMusl())
        try cflags.append(b.allocator, "-ftls-model=local-dynamic")
    else
        try cflags.append(b.allocator, "-ftls-model=initial-exec");

    compile.addCSourceFile(.{
        .language = .c,
        .file = upstream.path("src/static.c"),
        .flags = cflags.items,
    });
    compile.addIncludePath(upstream.path("include"));

    if (optimize != .Debug)
        compile.root_module.addCMacro("NDEBUG", "");

    if (target.result.abi.isMusl())
        compile.root_module.addCMacro("MI_LIBC_MUSL", "");

    if (override) {
        compile.root_module.addCMacro("MI_MALLOC_OVERRIDE", "");
        const install_artifact = b.addInstallArtifact(compile, .{
            .dest_dir = .{ .override = .{ .custom = "obj" } },
        });
        b.getInstallStep().dependOn(&install_artifact.step);
    } else {
        inline for (.{ "mimalloc.h", "mimalloc-override.h" }) |header|
            compile.installHeader(upstream.path("include/" ++ header), header);
        b.installArtifact(compile);
    }
}
