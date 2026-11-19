const std = @import("std");

// Apple Silicon only.
//
// The engine (llama.cpp + libmtmd + ggml-metal + the C++ shim) is built by
// CMake with Apple clang into one static archive, so every C++ object shares
// the system libc++; Zig only sees the C ABI in engine/talk_engine.h.
//
// Final links go through Apple's toolchain (`xcrun clang++` → ld), not Zig's
// self-hosted Mach-O linker: the latter fails on the llama.cpp archive with
// "failed to resolve relocations and write atoms: Overflow". Zig code is
// emitted as an object (or, later, libtalk.a for the Xcode app) and linked
// there — the same way the Swift shell will consume it.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    if (target.result.cpu.arch != .aarch64 or target.result.os.tag != .macos) {
        std.debug.panic("talk-to-me targets aarch64-macos only", .{});
    }

    const engine_build_dir = ".build/engine";
    const engine_lib = engine_build_dir ++ "/libtalk_engine_all.a";

    const cmake_configure = b.addSystemCommand(&.{
        "cmake", "-S", "engine", "-B", engine_build_dir, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
    });
    cmake_configure.has_side_effects = true;

    const cmake_build = b.addSystemCommand(&.{
        "cmake", "--build", engine_build_dir, "--target", "talk_engine_all",
    });
    cmake_build.has_side_effects = true;
    cmake_build.step.dependOn(&cmake_configure.step);

    const engine_step = b.step("engine", "Build the llama.cpp engine archive");
    engine_step.dependOn(&cmake_build.step);

    const engine_c = b.addTranslateC(.{
        .root_source_file = b.path("engine/c_api.h"),
        .target = target,
        .optimize = optimize,
    });
    engine_c.addIncludePath(b.path("engine"));
    engine_c.addIncludePath(b.path("vendor/md4c/src"));
    const c_mod = engine_c.createModule();

    // Unit tests: pure Zig + md4c (compiled here), no engine archive needed.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("c", c_mod);
    test_mod.addCSourceFile(.{ .file = b.path("vendor/md4c/src/md4c.c") });
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Phase 0: engine spike — synthesize text to WAV and report timings.
    const spike_mod = b.createModule(.{
        .root_source_file = b.path("src/spike.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    spike_mod.addImport("c", c_mod);

    const spike_bin = appleLink(b, "spike", spike_mod, engine_lib, &cmake_build.step);
    const install_spike = b.addInstallBinFile(spike_bin, "spike");
    b.getInstallStep().dependOn(&install_spike.step);

    // talktome: server + CLI.
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_mod.addImport("c", c_mod);
    const talktome_bin = appleLink(b, "talktome", main_mod, engine_lib, &cmake_build.step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(talktome_bin, "talktome").step);
    const run_talktome = b.addRunFile(talktome_bin);
    run_talktome.addPassthruArgs();
    b.step("run", "Run talktome").dependOn(&run_talktome.step);

    const run_spike = b.addRunFile(spike_bin);
    run_spike.addPassthruArgs();
    b.step("spike", "Run the engine spike").dependOn(&run_spike.step);
}

/// Compile `root` to an object and link it with the engine archive using
/// Apple's clang++/ld. Returns the linked executable.
fn appleLink(
    b: *std.Build,
    name: []const u8,
    root: *std.Build.Module,
    engine_lib: []const u8,
    engine_step: *std.Build.Step,
) std.Build.LazyPath {
    const obj = b.addObject(.{ .name = name, .root_module = root });
    obj.bundle_compiler_rt = true;

    const link = b.addSystemCommand(&.{ "xcrun", "clang++", "-arch", "arm64", "-mmacosx-version-min=14.0" });
    link.addFileArg(obj.getEmittedBin());
    link.addFileArg(b.path(engine_lib));
    link.addArgs(&.{
        "-framework", "Foundation",
        "-framework", "Metal",
        "-framework", "MetalKit",
        "-framework", "Accelerate",
        "-framework", "AudioToolbox",
        "-framework", "CoreAudio",
        "-o",
    });
    const out = link.addOutputFileArg(name);
    link.step.dependOn(engine_step);
    return out;
}
