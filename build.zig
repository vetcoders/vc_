const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const buildpkg = @import("src/build/main.zig");

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// Libghostty version. We use a separate version from the app.
const lib_version = "0.1.0-dev";

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    buildpkg.requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    // If we have a VERSION file (present in source tarballs) then we
    // use that as the version source of truth. Otherwise we fall back
    // to what is in the build.zig.zon.
    const file_version: ?[]const u8 = if (b.build_root.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        std.Io.Limit.limited(128),
    )) |content| std.mem.trim(
        u8,
        content,
        &std.ascii.whitespace,
    ) else |_| null;

    const config = try buildpkg.Config.init(
        b,
        file_version orelse app_zon_version,
        lib_version,
    );
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    // Ghostty dependencies used by many artifacts.
    const deps = try buildpkg.SharedDeps.init(b, &config);

    // The modules exported for Zig consumers of libghostty. If you're
    // writing a Zig program that uses libghostty, read this file.
    const mod = try buildpkg.GhosttyZig.init(
        b,
        &config,
        &deps,
    );

    // All our steps which we'll hook up later. The steps are shown
    // up here just so that they are more self-documenting.
    const run_step = b.step("run", "Run the app");
    const run_valgrind_step = b.step(
        "run-valgrind",
        "Run the app under valgrind",
    );
    const test_step = b.step("test", "Run tests");
    const test_panels_step = b.step(
        "test-panels",
        "Run vibecrafted panels contract tests",
    );
    const test_lib_vt_step = b.step(
        "test-lib-vt",
        "Run libghostty-vt tests",
    );
    const test_valgrind_step = b.step(
        "test-valgrind",
        "Run tests under valgrind",
    );
    const translations_step = b.step(
        "update-translations",
        "Update translation files",
    );
    const vc_board_app_step: ?*std.Build.Step = if (config.target.result.os.tag.isDarwin() and
        config.app_runtime == .vibecrafted)
        b.step(
            "vc-board-app",
            "Build and install the vc-board macOS app bundle",
        )
    else
        null;

    // Ghostty resources like terminfo, shell integration, themes, etc.
    const resources = try buildpkg.GhosttyResources.init(b, &config, &deps);
    const i18n = if (config.i18n) try buildpkg.GhosttyI18n.init(b, &config) else null;

    const exe = try buildpkg.GhosttyExe.init(b, &config, &deps);

    // vc-mux
    const vc_mux_exe = b.addExecutable(.{
        .name = "vc-mux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_vc_mux.zig"),
            .target = config.target,
            .optimize = config.optimize,
        }),
    });
    const mux_step = b.step("mux", "Build the vc-mux tool");
    mux_step.dependOn(&b.addInstallArtifact(vc_mux_exe, .{}).step);

    const mux_monitor_step = b.step("mux-monitor", "Build the macOS vc-mux status-bar observer");
    if (config.target.result.os.tag.isDarwin()) {
        const mux_monitor_cmd = b.addSystemCommand(&.{
            "swiftc",
            "-swift-version",
            "5",
            "-Osize",
            "-framework",
            "AppKit",
            "-o",
        });
        const mux_monitor_bin = mux_monitor_cmd.addOutputFileArg("vc-mux-monitor");
        mux_monitor_cmd.addFileArg(b.path("tools/vc-mux-monitor/VcMuxMonitor.swift"));
        mux_monitor_step.dependOn(&b.addInstallBinFile(mux_monitor_bin, "vc-mux-monitor").step);
    }

    const vc_mux_mock_server_exe = b.addExecutable(.{
        .name = "vc-mux-mock-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mux/mock_server.zig"),
            .target = config.baselineTarget(b),
            .optimize = .Debug,
        }),
    });
    const vc_mux_integration_test = b.addTest(.{
        .name = "vc-mux-integration-test",
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mux/test_integration.zig"),
            .target = config.baselineTarget(b),
            .optimize = .Debug,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
        .use_llvm = true,
    });
    const vc_mux_integration_run = b.addRunArtifact(vc_mux_integration_test);

    // The test spawns the mux and mock-server binaries over a temporary unix
    // socket. Install them to stable zig-out/bin paths so the test can locate
    // them via env vars without resolving a LazyPath at script-eval time.
    const vc_mux_install = b.addInstallArtifact(vc_mux_exe, .{});
    const vc_mux_mock_install = b.addInstallArtifact(vc_mux_mock_server_exe, .{});
    vc_mux_integration_run.step.dependOn(&vc_mux_install.step);
    vc_mux_integration_run.step.dependOn(&vc_mux_mock_install.step);

    vc_mux_integration_run.setEnvironmentVariable(
        "VC_MUX_TEST_BIN",
        b.getInstallPath(.bin, vc_mux_exe.name),
    );
    vc_mux_integration_run.setEnvironmentVariable(
        "VC_MUX_MOCK_BIN",
        b.getInstallPath(.bin, vc_mux_mock_server_exe.name),
    );
    test_step.dependOn(&vc_mux_integration_run.step);

    // Dedicated step for running just the vc-mux integration test without
    // dragging in the whole Ghostty test pipeline. Useful while iterating on
    // the mux runtime.
    const test_mux_step = b.step(
        "test-mux",
        "Run the vc-mux integration test",
    );
    test_mux_step.dependOn(&vc_mux_integration_run.step);

    // Ghostty docs
    const docs = try buildpkg.GhosttyDocs.init(b, &deps);
    if (config.emit_docs) {
        docs.install();
    } else if (config.target.result.os.tag.isDarwin()) {
        // If we aren't emitting docs we need to emit a placeholder so
        // our macOS xcodeproject builds since it expects the `share/man`
        // directory to exist to copy into the app bundle.
        docs.installDummy(b.getInstallStep());
    }

    // Ghostty webdata
    const webdata = try buildpkg.GhosttyWebdata.init(b, &deps);
    if (config.emit_webdata) webdata.install();

    // Ghostty bench tools
    const bench = try buildpkg.GhosttyBench.init(b, &deps);
    if (config.emit_bench) bench.install();

    // Ghostty dist tarball
    const dist = try buildpkg.GhosttyDist.init(b, &config);
    {
        const step = b.step("dist", "Build the dist tarball");
        step.dependOn(dist.install_step);
        const check_step = b.step("distcheck", "Install and validate the dist tarball");
        check_step.dependOn(dist.check_step);
        check_step.dependOn(dist.install_step);
    }

    // libghostty-vt
    const libghostty_vt_shared = shared: {
        if (config.target.result.cpu.arch.isWasm()) {
            break :shared try buildpkg.GhosttyLibVt.initWasm(
                b,
                &mod,
            );
        }

        break :shared try buildpkg.GhosttyLibVt.initShared(
            b,
            &mod,
        );
    };
    libghostty_vt_shared.install(b.getInstallStep());

    // libghostty-vt static lib
    const libghostty_vt_static = try buildpkg.GhosttyLibVt.initStatic(
        b,
        &mod,
    );
    if (config.is_dep) {
        // If we're a dependency, we need to install everything as-is
        // so that dep.artifact("ghostty-vt-static") works.
        libghostty_vt_static.install(b.getInstallStep());
    } else {
        // If we're not a dependency, we rename the static lib to
        // be idiomatic. On Windows, we use a distinct name to avoid
        // colliding with the DLL import library (ghostty-vt.lib).
        const static_lib_name = if (config.target.result.os.tag == .windows)
            "ghostty-vt-static.lib"
        else
            "libghostty-vt.a";
        b.getInstallStep().dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            static_lib_name,
        ).step);
    }

    // libghostty-vt xcframework (Apple only, universal binary).
    // Only when building on macOS (not cross-compiling) since
    // xcodebuild is required.
    if (builtin.os.tag.isDarwin() and config.target.result.os.tag.isDarwin()) {
        const apple_libs = try buildpkg.GhosttyLibVt.initStaticAppleUniversal(
            b,
            &config,
            &deps,
            &mod,
        );
        const xcframework = buildpkg.GhosttyLibVt.xcframework(&apple_libs, b);
        b.getInstallStep().dependOn(xcframework.step);
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    // Runtime "none" is libghostty, anything else is an executable.
    if (config.app_runtime != .none) {
        if (config.emit_exe) {
            exe.install();
            resources.install();
            if (i18n) |v| v.install();
        }
    } else if (!config.emit_lib_vt) {
        // The macOS Ghostty Library
        //
        // This is NOT libghostty (even though its named that for historical
        // reasons). It is just the glue between Ghostty GUI on macOS and
        // the full Ghostty GUI core.
        const lib_shared = try buildpkg.GhosttyLib.initShared(b, &deps);
        const lib_static = try buildpkg.GhosttyLib.initStatic(b, &deps);

        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader(); // Only need one header
            if (config.target.result.os.tag == .windows) {
                lib_shared.install("ghostty-internal.dll");
                lib_static.install("ghostty-internal-static.lib");
            } else {
                lib_shared.install("ghostty-internal.so");
                lib_static.install("ghostty-internal.a");
            }
        }
    }

    // macOS only artifacts. These will error if they're initialized for
    // other targets.
    if (config.target.result.os.tag.isDarwin() and
        (config.emit_xcframework or config.emit_macos_app))
    {
        // Ghostty xcframework
        const xcframework = try buildpkg.GhosttyXCFramework.init(
            b,
            &deps,
            config.xcframework_target,
        );
        if (config.emit_xcframework) {
            xcframework.install();

            // The xcframework build always installs resources because our
            // macOS xcode project contains references to them.
            resources.install();
            if (i18n) |v| v.install();
        }

        // Ghostty macOS app
        const macos_app = try buildpkg.GhosttyXcodebuild.init(
            b,
            &config,
            .{
                .xcframework = &xcframework,
                .docs = &docs,
                .i18n = if (i18n) |v| &v else null,
                .resources = &resources,
            },
        );
        if (config.emit_macos_app) {
            macos_app.install();
        }
    }

    if (vc_board_app_step) |step| {
        const vc_board_xc_config = switch (config.optimize) {
            .Debug => "Debug",
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => "ReleaseLocal",
        };
        const env_map = try b.allocator.create(std.process.Environ.Map);
        env_map.* = std.process.Environ.Map.init(b.allocator);
        if (b.graph.environ_map.get("PATH")) |v| try env_map.put("PATH", v);

        const build_app = RunStep.create(b, "xcodebuild vc-board app shell");
        build_app.has_side_effects = true;
        build_app.cwd = b.path("macos");
        build_app.environ_map = env_map;
        build_app.addArgs(&.{
            "xcodebuild",
            "-project",
            "Ghostty.xcodeproj",
            "-scheme",
            "Ghostty",
            "-configuration",
            vc_board_xc_config,
            "SYMROOT=build",
            "build",
        });
        build_app.expectExitCode(0);

        const stage_app = RunStep.create(b, "stage vc-board app shell");
        stage_app.has_side_effects = true;
        stage_app.cwd = b.path("");
        stage_app.addArgs(&.{
            "sh",
            b.pathFromRoot("distribution/macos/stage-vc-board-app.sh"),
            b.install_path,
            b.pathFromRoot(b.fmt("macos/build/{s}/Ghostty.app", .{vc_board_xc_config})),
            b.getInstallPath(.bin, "vc-board"),
            file_version orelse app_zon_version,
        });
        stage_app.step.dependOn(&build_app.step);
        stage_app.step.dependOn(b.getInstallStep());

        step.dependOn(&stage_app.step);
    }

    // Run step
    run: {
        if (config.app_runtime != .none) {
            const run_cmd = b.addRunArtifact(exe.exe);
            if (b.args) |args| run_cmd.addArgs(args);

            // Set the proper resources dir so things like shell integration
            // work correctly. If we're running `zig build run` in Ghostty,
            // this also ensures it overwrites the release one with our debug
            // build.
            run_cmd.setEnvironmentVariable(
                "GHOSTTY_RESOURCES_DIR",
                b.getInstallPath(.prefix, "share/ghostty"),
            );

            run_step.dependOn(&run_cmd.step);
            break :run;
        }

        assert(config.app_runtime == .none);

        // On macOS we can run the macOS app. For "run" we always force
        // a native-only build so that we can run as quickly as possible.
        if (config.target.result.os.tag.isDarwin() and
            (config.emit_xcframework or config.emit_macos_app))
        {
            const xcframework_native = try buildpkg.GhosttyXCFramework.init(
                b,
                &deps,
                .native,
            );
            const macos_app_native_only = try buildpkg.GhosttyXcodebuild.init(
                b,
                &config,
                .{
                    .xcframework = &xcframework_native,
                    .docs = &docs,
                    .i18n = if (i18n) |v| &v else null,
                    .resources = &resources,
                },
            );

            // Run uses the native macOS app
            run_step.dependOn(&macos_app_native_only.open.step);

            // If we have no test filters, install the tests too
            if (test_filters.len == 0) {
                macos_app_native_only.addTestStepDependencies(test_step);
            }
        }
    }

    // Valgrind
    if (config.app_runtime != .none) {
        // We need to rebuild Ghostty with a baseline CPU target.
        const valgrind_exe = exe: {
            var valgrind_config = config;
            valgrind_config.target = valgrind_config.baselineTarget(b);
            break :exe try buildpkg.GhosttyExe.init(
                b,
                &valgrind_config,
                &deps,
            );
        };

        const run_cmd = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        run_cmd.addArtifactArg(valgrind_exe.exe);
        if (b.args) |args| run_cmd.addArgs(args);
        run_valgrind_step.dependOn(&run_cmd.step);
    }

    // Zig module tests
    {
        const mod_vt_test = b.addTest(.{
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);

        const mod_vt_c_test = b.addTest(.{
            .root_module = mod.vt_c,
            .filters = test_filters,
        });
        const mod_vt_c_test_run = b.addRunArtifact(mod_vt_c_test);
        test_lib_vt_step.dependOn(&mod_vt_c_test_run.step);
    }

    // Tests (skip when building libghostty-vt)
    if (!config.emit_lib_vt) {
        // Full unit tests
        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(b),
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = true,
        });
        if (config.emit_test_exe) b.installArtifact(test_exe);
        _ = try deps.add(test_exe);

        // Verify our internal libghostty header.
        const ghostty_h = b.addTranslateC(.{
            .root_source_file = b.path("include/ghostty.h"),
            .target = config.baselineTarget(b),
            .optimize = .Debug,
        });
        test_exe.root_module.addImport("ghostty.h", ghostty_h.createModule());

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_run.step);

        const panels_test_exe = b.addTest(.{
            .name = "panels-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/panels_test.zig"),
                .target = config.baselineTarget(b),
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            .use_llvm = true,
        });
        _ = try deps.add(panels_test_exe);
        panels_test_exe.root_module.addImport("ghostty.h", ghostty_h.createModule());

        const panels_test_run = b.addRunArtifact(panels_test_exe);
        test_step.dependOn(&panels_test_run.step);
        test_panels_step.dependOn(&panels_test_run.step);

        // Normal tests always test our libghostty modules
        //test_step.dependOn(test_lib_vt_step);

        // Valgrind test running
        const valgrind_run = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        valgrind_run.addArtifactArg(test_exe);
        test_valgrind_step.dependOn(&valgrind_run.step);
    }

    // Standalone Track T3 Phase 1 demo: vc-board-tui-mock exercises the
    // operator TUI state machines (apprt/vibecrafted/tui/*) with hardcoded
    // sample data. Pure presenter — no Ghostty deps, no apprt scaffolding,
    // builds clean independent of the workspace test gate so the gate can be
    // smoke-tested end-to-end via `zig build vc-board-tui-mock`.
    {
        const tui_mock_step = b.step(
            "vc-board-tui-mock",
            "Build the standalone vibecrafted operator TUI demo (Track T3 P1)",
        );
        const tui_mock_exe = b.addExecutable(.{
            .name = "vc-board-tui-mock",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_vc_board_tui_mock.zig"),
                .target = config.baselineTarget(b),
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        const tui_mock_install = b.addInstallArtifact(tui_mock_exe, .{});
        tui_mock_step.dependOn(&tui_mock_install.step);
    }

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    if (i18n) |v| {
        translations_step.dependOn(v.update_step);
    } else {
        try translations_step.addError("cannot update translations when i18n is disabled", .{});
    }
}
