const std = @import("std");

pub fn build(b: *std.Build) !void {
    _ = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});
}

pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const env = std.process.getEnvMap(b.allocator) catch @panic("OOM");
    const sdk = env.get("NIX_APPLE_SDK_PATH") orelse
        return error.DarwinSdkNotFound;

    const framework_path = std.fs.path.join(b.allocator, &.{
        sdk, "System/Library/Frameworks",
    }) catch @panic("OOM");
    const sys_include = std.fs.path.join(b.allocator, &.{
        sdk, "usr/include",
    }) catch @panic("OOM");
    const library_path = std.fs.path.join(b.allocator, &.{
        sdk, "usr/lib",
    }) catch @panic("OOM");

    const libc_content = std.fmt.allocPrint(b.allocator,
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir=
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
    , .{ sys_include, sys_include }) catch @panic("OOM");

    const wf = b.addWriteFiles();
    step.setLibCFile(wf.add("libc.txt", libc_content));
    step.root_module.addSystemFrameworkPath(.{ .cwd_relative = framework_path });
    step.root_module.addSystemIncludePath(.{ .cwd_relative = sys_include });
    step.root_module.addLibraryPath(.{ .cwd_relative = library_path });
}
