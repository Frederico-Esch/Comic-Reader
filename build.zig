const std = @import("std");

pub fn build(b: *std.Build) void {
    //const target = b.standardTargetOptions(.{.default_target = std.Target.Query{.os_tag = .windows, .cpu_arch = .x86_64, .abi = .msvc}});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            //.{ .name = "raylib", .module = raylib },
        },
        .link_libc = true
    });
    const open_file = b.addTranslateC(.{
        .root_source_file = b.path("vendor/include/open_file.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true
    }).createModule();
    open_file.addLibraryPath(b.path("vendor/lib/"));
    open_file.linkSystemLibrary("Comdlg32", .{});
    open_file.linkSystemLibrary("open_file", .{ .preferred_link_mode = .static});
    const raylib  = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("vendor/include/raylib.h"),
        .link_libc = true,
    }).createModule();
    raylib.addLibraryPath(b.path("vendor/lib/"));
    raylib.linkSystemLibrary("raylib", .{ .preferred_link_mode = .static});
    raylib.linkSystemLibrary("Gdi32", .{});
    raylib.linkSystemLibrary("opengl32", .{});
    raylib.linkSystemLibrary("Shell32", .{});
    raylib.linkSystemLibrary("winMM", .{});
    raylib.linkSystemLibrary("kernel32", .{});
    raylib.linkSystemLibrary("User32", .{});
    main.addImport("raylib", raylib);
    main.addIncludePath(b.path("vendor/include"));

    const raygui_c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("vendor/include/raygui.h"),
        .link_libc = true,
    });
    const raygui = raygui_c.createModule();
    //raygui.addLibraryPath(b.path("vendor/lib/"));
    //raygui.linkSystemLibrary("raygui", .{});
    //raygui.linkSystemLibrary("raylib", .{});
    main.addImport("raygui", raygui);
    main.addImport("open-file", open_file); //maybe open_file should become win??

    const exe = b.addExecutable(.{
        .name = "comic_decode",
        .root_module = main,
    });

    b.installArtifact(exe);
    //b.installBinFile("vendor/lib/raylib.dll", "raylib.dll");

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
