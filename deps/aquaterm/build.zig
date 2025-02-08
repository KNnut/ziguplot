const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    if (!target.result.isDarwin()) {
        std.debug.print("The target should be macOS but is {s}.\n", .{@tagName(target.result.os.tag)});
        return error.InvalidOS;
    }

    const wf = b.addNamedWriteFiles("framework");
    _ = wf.addCopyFile(b.path("vendor/lib/AquaTerm.tbd"), "AquaTerm.framework/AquaTerm.tbd");
    _ = wf.addCopyFile(b.path("vendor/include/AQTAdapter.h"), "AquaTerm.framework/Headers/AQTAdapter.h");
    b.getInstallStep().dependOn(&wf.step);
}
