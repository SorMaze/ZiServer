const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const artifact = b.option(
        []const u8,
        "artifact",
        "Build artifact: server, bench, or all",
    ) orelse "server";
    const static_mode = b.option(
        []const u8,
        "static",
        "Static assets mode: filesystem or embedded",
    ) orelse "filesystem";
    const configured_tls_provider = b.option(
        []const u8,
        "tls",
        "TLS provider: none, openssl, or schannel (default openssl)",
    );
    const tls_provider = configured_tls_provider orelse "openssl";
    const http2_provider = b.option(
        []const u8,
        "http2",
        "HTTP/2 provider: none or nghttp2 (default nghttp2 with OpenSSL)",
    ) orelse if (std.mem.eql(u8, tls_provider, "openssl")) "nghttp2" else "none";
    const http3_provider = b.option(
        []const u8,
        "http3",
        "HTTP/3 provider: none or nghttp3 (default none; experimental single-connection transport)",
    ) orelse "none";
    const configured_vcpkg_root = b.option(
        []const u8,
        "vcpkg-root",
        "vcpkg root directory used to locate installed packages",
    ) orelse "";
    const vcpkg_root = resolveVcpkgRoot(b, configured_vcpkg_root);
    const vcpkg_triplet = b.option(
        []const u8,
        "vcpkg-triplet",
        "vcpkg triplet used for TLS dependencies",
    ) orelse resolveVcpkgTriplet(b, target);
    const openssl_include = b.option(
        []const u8,
        "openssl-include",
        "OpenSSL include directory; overrides vcpkg-root when set",
    ) orelse "";
    const openssl_lib_dir = b.option(
        []const u8,
        "openssl-lib-dir",
        "OpenSSL library directory; overrides vcpkg-root when set",
    ) orelse "";
    const openssl_ssl_lib = b.option(
        []const u8,
        "openssl-ssl-lib",
        "OpenSSL SSL library name",
    ) orelse if (target.result.os.tag == .windows) "libssl" else "ssl";
    const openssl_crypto_lib = b.option(
        []const u8,
        "openssl-crypto-lib",
        "OpenSSL crypto library name",
    ) orelse if (target.result.os.tag == .windows) "libcrypto" else "crypto";
    const nghttp2_include = b.option(
        []const u8,
        "nghttp2-include",
        "nghttp2 include directory; overrides vcpkg-root when set",
    ) orelse "";
    const nghttp2_lib_dir = b.option(
        []const u8,
        "nghttp2-lib-dir",
        "nghttp2 library directory; overrides vcpkg-root when set",
    ) orelse "";
    const nghttp2_lib = b.option(
        []const u8,
        "nghttp2-lib",
        "nghttp2 library name",
    ) orelse "nghttp2";

    const build_server = std.mem.eql(u8, artifact, "server") or std.mem.eql(u8, artifact, "all");
    const build_bench = std.mem.eql(u8, artifact, "bench") or std.mem.eql(u8, artifact, "all");
    const static_filesystem = std.mem.eql(u8, static_mode, "filesystem");
    const static_embedded = std.mem.eql(u8, static_mode, "embedded");
    const tls_none = std.mem.eql(u8, tls_provider, "none");
    const tls_openssl = std.mem.eql(u8, tls_provider, "openssl");
    const tls_schannel = std.mem.eql(u8, tls_provider, "schannel");
    const http2_none = std.mem.eql(u8, http2_provider, "none");
    const http2_nghttp2 = std.mem.eql(u8, http2_provider, "nghttp2");
    const http3_none = std.mem.eql(u8, http3_provider, "none");
    const http3_nghttp3 = std.mem.eql(u8, http3_provider, "nghttp3");

    if (!build_server and !build_bench) {
        std.debug.panic("invalid -Dartifact={s}; expected server, bench, or all", .{artifact});
    }
    if (!static_filesystem and !static_embedded) {
        std.debug.panic("invalid -Dstatic={s}; expected filesystem or embedded", .{static_mode});
    }
    if (!tls_none and !tls_openssl and !tls_schannel) {
        std.debug.panic("invalid -Dtls={s}; expected none, openssl, or schannel", .{tls_provider});
    }
    if (!http2_none and !http2_nghttp2) {
        std.debug.panic("invalid -Dhttp2={s}; expected none or nghttp2", .{http2_provider});
    }
    if (!http3_none and !http3_nghttp3) {
        std.debug.panic("invalid -Dhttp3={s}; expected none or nghttp3", .{http3_provider});
    }
    if (http2_nghttp2 and !tls_openssl) {
        std.debug.panic(
            "-Dhttp2=nghttp2 currently requires -Dtls=openssl; omit -Dhttp2 when selecting -Dtls=none or schannel",
            .{},
        );
    }
    if (http3_nghttp3 and !tls_openssl) {
        std.debug.panic(
            "-Dhttp3=nghttp3 currently requires -Dtls=openssl",
            .{},
        );
    }

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_options = b.addOptions();
    server_options.addOption([]const u8, "static_mode", static_mode);
    server_options.addOption([]const u8, "tls_provider", tls_provider);
    server_options.addOption([]const u8, "http2_provider", http2_provider);
    server_options.addOption([]const u8, "http3_provider", http3_provider);
    server_mod.addOptions("build_options", server_options);
    applyTlsProvider(
        b,
        server_mod,
        tls_provider,
        vcpkg_root,
        vcpkg_triplet,
        openssl_include,
        openssl_lib_dir,
        openssl_ssl_lib,
        openssl_crypto_lib,
    );
    applyHttp2Provider(b, server_mod, http2_provider, vcpkg_root, vcpkg_triplet, nghttp2_include, nghttp2_lib_dir, nghttp2_lib);
    applyHttp3Provider(b, server_mod, http3_provider, vcpkg_root, vcpkg_triplet);

    const server_exe = b.addExecutable(.{
        .name = "ziserver",
        .root_module = server_mod,
    });

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addOptions("build_options", server_options);
    applyTlsProvider(
        b,
        bench_mod,
        tls_provider,
        vcpkg_root,
        vcpkg_triplet,
        openssl_include,
        openssl_lib_dir,
        openssl_ssl_lib,
        openssl_crypto_lib,
    );
    const bench_exe = b.addExecutable(.{
        .name = "zibench",
        .root_module = bench_mod,
    });

    const install_static_mod = b.createModule(.{
        .root_source_file = b.path("src/install_static.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const install_static_exe = b.addExecutable(.{
        .name = "install-static",
        .root_module = install_static_mod,
    });

    if (build_server) b.installArtifact(server_exe);
    if (build_server or build_bench) installTlsRuntimeFiles(b, target, tls_provider, vcpkg_root, vcpkg_triplet);
    if (build_server) installHttp2RuntimeFiles(b, target, http2_provider, vcpkg_root, vcpkg_triplet);
    if (build_server) installHttp3RuntimeFiles(b, target, http3_provider, vcpkg_root, vcpkg_triplet);
    const legal_files = [_][]const u8{
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "LICENSES/Apache-2.0.txt",
        "LICENSES/nghttp2.txt",
        "LICENSES/ngtcp2.txt",
        "LICENSES/nghttp3.txt",
        "LICENSES/GSAP-3.12.5.txt",
    };
    for (legal_files) |file| b.installFile(file, file);
    if (build_server and static_filesystem) {
        const install_static_cmd = b.addRunArtifact(install_static_exe);
        install_static_cmd.addArg("src/public");
        install_static_cmd.addArg("zig-out/public");
        b.getInstallStep().dependOn(&install_static_cmd.step);
    }
    if (build_bench) b.installArtifact(bench_exe);

    const run_cmd = b.addRunArtifact(server_exe);
    configureTlsRuntimeEnv(b, run_cmd, tls_provider, vcpkg_root, vcpkg_triplet);
    forwardZiServerRuntimeEnv(b, run_cmd);
    addZiServerRuntimeArgs(b, run_cmd);
    if (static_filesystem) {
        run_cmd.addArg("--static-dir=src/public");
    }
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the HTML server");
    run_step.dependOn(&run_cmd.step);

    const bench_cmd = b.addRunArtifact(bench_exe);
    configureTlsRuntimeEnv(b, bench_cmd, tls_provider, vcpkg_root, vcpkg_triplet);
    bench_cmd.addPassthruArgs();

    const bench_step = b.step("bench", "Run the HTTP benchmark client");
    bench_step.dependOn(&bench_cmd.step);

    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/core_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_test_mod.addOptions("build_options", server_options);
    applyTlsProvider(b, core_test_mod, tls_provider, vcpkg_root, vcpkg_triplet, openssl_include, openssl_lib_dir, openssl_ssl_lib, openssl_crypto_lib);
    const core_tests = b.addTest(.{
        .name = "core-tests",
        .root_module = core_test_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    configureTlsRuntimeEnv(b, run_core_tests, tls_provider, vcpkg_root, vcpkg_triplet);

    const form_test_mod = b.createModule(.{
        .root_source_file = b.path("src/compose/form.zig"),
        .target = target,
        .optimize = optimize,
    });
    const form_tests = b.addTest(.{
        .name = "form-tests",
        .root_module = form_test_mod,
    });
    const run_form_tests = b.addRunArtifact(form_tests);

    const xss_test_mod = b.createModule(.{
        .root_source_file = b.path("src/xss_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    xss_test_mod.addOptions("build_options", server_options);
    const xss_tests = b.addTest(.{
        .name = "xss-tests",
        .root_module = xss_test_mod,
    });
    const run_xss_tests = b.addRunArtifact(xss_tests);
    configureTlsRuntimeEnv(b, run_xss_tests, tls_provider, vcpkg_root, vcpkg_triplet);

    const query_test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/query.zig"),
        .target = target,
        .optimize = optimize,
    });
    const query_tests = b.addTest(.{
        .name = "query-tests",
        .root_module = query_test_mod,
    });
    const run_query_tests = b.addRunArtifact(query_tests);

    const auth_test_mod = b.createModule(.{
        .root_source_file = b.path("src/auth_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth_test_mod.addOptions("build_options", server_options);
    const auth_tests = b.addTest(.{
        .name = "auth-tests",
        .root_module = auth_test_mod,
    });
    const run_auth_tests = b.addRunArtifact(auth_tests);
    configureTlsRuntimeEnv(b, run_auth_tests, tls_provider, vcpkg_root, vcpkg_triplet);

    const rate_limit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/rate_limit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    rate_limit_test_mod.addOptions("build_options", server_options);
    const rate_limit_tests = b.addTest(.{
        .name = "rate-limit-tests",
        .root_module = rate_limit_test_mod,
    });
    const run_rate_limit_tests = b.addRunArtifact(rate_limit_tests);
    configureTlsRuntimeEnv(b, run_rate_limit_tests, tls_provider, vcpkg_root, vcpkg_triplet);

    const compose_test_mod = b.createModule(.{
        .root_source_file = b.path("src/compose_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    compose_test_mod.addOptions("build_options", server_options);
    applyTlsProvider(b, compose_test_mod, tls_provider, vcpkg_root, vcpkg_triplet, openssl_include, openssl_lib_dir, openssl_ssl_lib, openssl_crypto_lib);
    applyHttp2Provider(b, compose_test_mod, http2_provider, vcpkg_root, vcpkg_triplet, nghttp2_include, nghttp2_lib_dir, nghttp2_lib);
    const compose_tests = b.addTest(.{
        .name = "compose-tests",
        .root_module = compose_test_mod,
    });
    const run_compose_tests = b.addRunArtifact(compose_tests);
    configureTlsRuntimeEnv(b, run_compose_tests, tls_provider, vcpkg_root, vcpkg_triplet);

    const app_test_mod = b.createModule(.{
        .root_source_file = b.path("src/app_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_test_mod.addOptions("build_options", server_options);
    applyTlsProvider(b, app_test_mod, tls_provider, vcpkg_root, vcpkg_triplet, openssl_include, openssl_lib_dir, openssl_ssl_lib, openssl_crypto_lib);
    applyHttp2Provider(b, app_test_mod, http2_provider, vcpkg_root, vcpkg_triplet, nghttp2_include, nghttp2_lib_dir, nghttp2_lib);
    const app_tests = b.addTest(.{
        .name = "app-tests",
        .root_module = app_test_mod,
    });
    const run_app_tests = b.addRunArtifact(app_tests);
    configureTlsRuntimeEnv(b, run_app_tests, tls_provider, vcpkg_root, vcpkg_triplet);

    const bench_tests = b.addTest(.{
        .name = "bench-tests",
        .root_module = bench_mod,
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    configureTlsRuntimeEnv(b, run_bench_tests, tls_provider, vcpkg_root, vcpkg_triplet);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_form_tests.step);
    test_step.dependOn(&run_xss_tests.step);
    test_step.dependOn(&run_query_tests.step);
    test_step.dependOn(&run_auth_tests.step);
    test_step.dependOn(&run_rate_limit_tests.step);
    test_step.dependOn(&run_compose_tests.step);
    test_step.dependOn(&run_app_tests.step);
    test_step.dependOn(&run_bench_tests.step);
}

fn resolveVcpkgRoot(b: *std.Build, configured: []const u8) []const u8 {
    if (configured.len != 0) return configured;
    const names = [_][]const u8{
        "VCPKG_ROOT",
        "VCPKG_INSTALLATION_ROOT",
        "VCPKG_HOME",
        "Vcpkg_home",
    };
    for (names) |name| {
        if (b.graph.environ_map.get(name)) |value| {
            if (value.len != 0) return value;
        }
    }
    return "";
}

fn resolveVcpkgTriplet(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    if (b.graph.environ_map.get("VCPKG_DEFAULT_TRIPLET")) |value| {
        if (value.len != 0) return value;
    }
    const architecture = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        .arm => "arm",
        else => @tagName(target.result.cpu.arch),
    };
    const operating_system = switch (target.result.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "osx",
        else => @tagName(target.result.os.tag),
    };
    return b.fmt("{s}-{s}", .{ architecture, operating_system });
}

fn applyTlsProvider(
    b: *std.Build,
    module: *std.Build.Module,
    tls_provider: []const u8,
    vcpkg_root: []const u8,
    vcpkg_triplet: []const u8,
    openssl_include: []const u8,
    openssl_lib_dir: []const u8,
    openssl_ssl_lib: []const u8,
    openssl_crypto_lib: []const u8,
) void {
    if (std.mem.eql(u8, tls_provider, "openssl")) {
        const resolved_include = if (openssl_include.len != 0)
            openssl_include
        else if (vcpkg_root.len != 0)
            b.fmt("{s}/installed/{s}/include", .{ vcpkg_root, vcpkg_triplet })
        else
            "";
        const resolved_lib_dir = if (openssl_lib_dir.len != 0)
            openssl_lib_dir
        else if (vcpkg_root.len != 0)
            b.fmt("{s}/installed/{s}/lib", .{ vcpkg_root, vcpkg_triplet })
        else
            "";

        if (resolved_include.len != 0) module.addIncludePath(optionPath(b, resolved_include));
        if (resolved_lib_dir.len != 0) module.addLibraryPath(optionPath(b, resolved_lib_dir));
        module.addCSourceFile(.{
            .file = b.path("src/core/tls_openssl_adapter.c"),
            .flags = &.{ "-Wall", "-Wextra", "-Wpedantic" },
        });
        module.linkSystemLibrary("c", .{});
        module.linkSystemLibrary(openssl_ssl_lib, .{});
        module.linkSystemLibrary(openssl_crypto_lib, .{});
    }
}

fn optionPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    if (std.fs.path.isAbsolute(path)) return b.graph.cwdRelativePath(path);
    return b.path(path);
}

fn applyHttp2Provider(
    b: *std.Build,
    module: *std.Build.Module,
    http2_provider: []const u8,
    vcpkg_root: []const u8,
    vcpkg_triplet: []const u8,
    nghttp2_include: []const u8,
    nghttp2_lib_dir: []const u8,
    nghttp2_lib: []const u8,
) void {
    if (!std.mem.eql(u8, http2_provider, "nghttp2")) return;

    const resolved_include = if (nghttp2_include.len != 0)
        nghttp2_include
    else if (vcpkg_root.len != 0)
        b.fmt("{s}/installed/{s}/include", .{ vcpkg_root, vcpkg_triplet })
    else
        "";
    const resolved_lib_dir = if (nghttp2_lib_dir.len != 0)
        nghttp2_lib_dir
    else if (vcpkg_root.len != 0)
        b.fmt("{s}/installed/{s}/lib", .{ vcpkg_root, vcpkg_triplet })
    else
        "";

    if (resolved_include.len != 0) module.addIncludePath(optionPath(b, resolved_include));
    if (resolved_lib_dir.len != 0) module.addLibraryPath(optionPath(b, resolved_lib_dir));
    module.addCSourceFile(.{
        .file = b.path("src/core/http2_nghttp2_adapter.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Wpedantic" },
    });
    module.linkSystemLibrary("c", .{});
    module.linkSystemLibrary(nghttp2_lib, .{});
}

fn installHttp2RuntimeFiles(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    http2_provider: []const u8,
    vcpkg_root: []const u8,
    vcpkg_triplet: []const u8,
) void {
    if (target.result.os.tag != .windows or !std.mem.eql(u8, http2_provider, "nghttp2") or vcpkg_root.len == 0) return;
    const dll = b.fmt("{s}/installed/{s}/bin/nghttp2.dll", .{ vcpkg_root, vcpkg_triplet });
    b.getInstallStep().dependOn(&b.addInstallBinFile(optionPath(b, dll), "nghttp2.dll").step);
}

fn applyHttp3Provider(
    b: *std.Build,
    module: *std.Build.Module,
    http3_provider: []const u8,
    vcpkg_root: []const u8,
    vcpkg_triplet: []const u8,
) void {
    if (!std.mem.eql(u8, http3_provider, "nghttp3")) return;

    const resolved_include = if (vcpkg_root.len != 0)
        b.fmt("{s}/installed/{s}/include", .{ vcpkg_root, vcpkg_triplet })
    else
        "";
    const resolved_lib_dir = if (vcpkg_root.len != 0)
        b.fmt("{s}/installed/{s}/lib", .{ vcpkg_root, vcpkg_triplet })
    else
        "";

    if (resolved_include.len != 0) module.addIncludePath(optionPath(b, resolved_include));
    if (resolved_lib_dir.len != 0) module.addLibraryPath(optionPath(b, resolved_lib_dir));
    module.addCSourceFile(.{
        .file = b.path("src/core/http3_nghttp3_adapter.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Wpedantic" },
    });
    module.linkSystemLibrary("c", .{});
    module.linkSystemLibrary("ngtcp2", .{});
    module.linkSystemLibrary("ngtcp2_crypto_ossl", .{});
    module.linkSystemLibrary("nghttp3", .{});
}

fn installHttp3RuntimeFiles(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    http3_provider: []const u8,
    vcpkg_root: []const u8,
    vcpkg_triplet: []const u8,
) void {
    if (target.result.os.tag != .windows or !std.mem.eql(u8, http3_provider, "nghttp3") or vcpkg_root.len == 0) return;
    const bin_dir = b.fmt("{s}/installed/{s}/bin", .{ vcpkg_root, vcpkg_triplet });
    const ngtcp2_dll = b.fmt("{s}/ngtcp2.dll", .{bin_dir});
    const ngtcp2_crypto_dll = b.fmt("{s}/ngtcp2_crypto_ossl.dll", .{bin_dir});
    const nghttp3_dll = b.fmt("{s}/nghttp3.dll", .{bin_dir});
    b.getInstallStep().dependOn(&b.addInstallBinFile(optionPath(b, ngtcp2_dll), "ngtcp2.dll").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(optionPath(b, ngtcp2_crypto_dll), "ngtcp2_crypto_ossl.dll").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(optionPath(b, nghttp3_dll), "nghttp3.dll").step);
}

fn installTlsRuntimeFiles(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    tls_provider: []const u8,
    vcpkg_root: []const u8,
    vcpkg_triplet: []const u8,
) void {
    if (target.result.os.tag != .windows or !std.mem.eql(u8, tls_provider, "openssl") or vcpkg_root.len == 0) return;
    const bin_dir = b.fmt("{s}/installed/{s}/bin", .{ vcpkg_root, vcpkg_triplet });
    const ssl_dll = b.fmt("{s}/libssl-3-x64.dll", .{bin_dir});
    const crypto_dll = b.fmt("{s}/libcrypto-3-x64.dll", .{bin_dir});
    b.getInstallStep().dependOn(&b.addInstallBinFile(optionPath(b, ssl_dll), "libssl-3-x64.dll").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(optionPath(b, crypto_dll), "libcrypto-3-x64.dll").step);
}

fn configureTlsRuntimeEnv(
    b: *std.Build,
    run: *std.Build.Step.Run,
    tls_provider: []const u8,
    vcpkg_root: []const u8,
    vcpkg_triplet: []const u8,
) void {
    if (!std.mem.eql(u8, tls_provider, "openssl") or vcpkg_root.len == 0) return;
    const bin_dir = b.fmt("{s}/installed/{s}/bin", .{ vcpkg_root, vcpkg_triplet });
    const inherited_path = b.graph.environ_map.get("PATH") orelse b.graph.environ_map.get("Path") orelse "";
    const path_separator = if (builtin.os.tag == .windows) ";" else ":";
    const path_value = if (inherited_path.len == 0)
        bin_dir
    else
        b.fmt("{s}{s}{s}", .{ bin_dir, path_separator, inherited_path });
    run.setEnvironmentVariable("PATH", path_value);
}

fn forwardZiServerRuntimeEnv(b: *std.Build, run: *std.Build.Step.Run) void {
    const names = [_][]const u8{
        "ZISERVER_TLS",
        "ZISERVER_TLS_CERT",
        "ZISERVER_TLS_KEY",
        "ZISERVER_HTTP2",
        "ZISERVER_BEARER_TOKEN",
        "ZISERVER_API_KEY",
        "ZISERVER_CANONICAL_HOST",
        "ZISERVER_ALLOWED_HOSTS",
    };
    for (names) |name| {
        if (b.graph.environ_map.get(name)) |value| {
            run.setEnvironmentVariable(name, value);
        }
    }
}

fn addZiServerRuntimeArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    const mappings = [_]struct { env: []const u8, argument: []const u8 }{
        .{ .env = "ZISERVER_TLS", .argument = "--tls=" },
        .{ .env = "ZISERVER_TLS_CERT", .argument = "--tls-cert=" },
        .{ .env = "ZISERVER_TLS_KEY", .argument = "--tls-key=" },
        .{ .env = "ZISERVER_HTTP2", .argument = "--http2=" },
    };
    for (mappings) |mapping| {
        if (b.graph.environ_map.get(mapping.env)) |value| {
            if (value.len != 0) run.addArg(b.fmt("{s}{s}", .{ mapping.argument, value }));
        }
    }
}
